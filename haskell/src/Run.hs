module Run ( SatDict
           , Log
           , runAD
           , runBF
           , runVSMT
           , fst'
           , IncPack
           , smtBool
           , smtInt
           ) where

import qualified Data.Map.Strict as M
import Control.Monad (when)
import Data.Maybe (isJust, fromJust,fromMaybe)
import Control.DeepSeq (force)
import Control.Monad.RWS.Strict
import Control.Monad.State.Strict    as St
import qualified Data.SBV.Internals  as I
import qualified Data.SBV            as S
import qualified Data.SBV.Control    as SC
import           Prelude hiding (LT, GT, EQ)
import Data.Foldable (foldr')
import Data.Text (Text)
import Control.Arrow                 (first, second)

import Data.Maybe                    (catMaybes)

import SAT
import VProp.Types
import VProp.SBV
import VProp.Core
import Utils
import Config
import Result

-- | The satisfiable dictionary, this is actually the "state" keys are configs
-- (an mapping from dimensions to booleans denoting selection) and values are
-- whether that config is satisfiable or not (a bool)
type SatDict a = M.Map (Config a) Bool

-- | Type convenience for Log
type Log = Text

-- | Takes a dimension d, a type for values a, and a result r
type Env d a r = RWST (SMTConf d a a) Log (SatDict d) IO r -- ^ the monad stack

-- | A Ctx is a zipper over the VProp data type. This is used in the vsmtsolve
-- routine to maintain a context when a choice is observed. This way we always
-- have a reference to the rest of the formula we are solving during a
-- variational solve. Its a sum type over the zipper for n-ary operators like
-- And and Or, or its a zipper over binary operators like ==> <=>. For binary
-- operators we keep a prop that is the focus and a context which represents the
-- parent and adjacent child
data Ctx d a b = InBBL BB_B  !(Ctx d a b) !(VProp d a b)
               | InBBR BB_B !S.SBool  !(Ctx d a b)
               | InB B_B !(Ctx d a b)
               | Empty
               deriving Show

-- | a strict tuple type
data Loc d a b = Loc !(VProp d a b) !(Ctx d a b) deriving Show

mkLoc :: (VProp d a b, Ctx d a b) -> Loc d a b
mkLoc (x, y) = Loc x y

-- | An empty reader monad environment, in the future read these from config file
_emptySt :: SatDict d
_emptySt = M.empty

-- | Run the RWS monad with defaults of empty state, reader
_runEnv :: Show a =>
  Env d a r -> SMTConf d a a -> SatDict d -> IO (r, SatDict d,  Log)
_runEnv = runRWST

runEnv :: Show a =>
          (VProp d a a -> Env d a (Result d))
       -> SMTConf d a a
       -> VProp d a a
       -> IO (Result d, SatDict d, Log)
runEnv f conf x = _runEnv (f x') conf _emptySt
  where x' = foldr' ($) x (opts conf)

runAD :: (Show a, Show d, Ord d, Ord a, Resultable d) =>
         SMTConf d a a
      -> VProp d a a
      -> (d -> a)
      -> IO (Result d)
runAD os p f = fst' <$> runEnv (flip runAndDecomp f) os p

runBF :: (Show a, Show d, Ord a, Resultable d,Monoid d) =>
         SMTConf d a a
      -> VProp d a a
      -> IO (Result d)
runBF os p = fst' <$> runEnv runBruteForce os p

-- | Run the VSMT solver given a list of optimizations and a prop
runVSMT :: (Show d, Show a, Ord a, Ord d, Resultable d) =>
           ConfigPool d               ->
           SMTConf d a a              ->
           VProp d a a                ->
           IO (Result d, SatDict d, Log)
runVSMT dimConf = runEnv (runVSMTSolve dimConf)

-- | Given a VProp a term generate the satisfiability map
initSt :: Ord d => VProp d a a -> SatDict d
initSt prop = sats
  where sats = M.fromList . fmap (\x -> (x, False)) $
               M.fromList <$> choices prop

-- | Some logging functions
_logBaseline :: (Show a, MonadWriter [Char] m) => a -> m ()
_logBaseline x = tell $ "Running baseline: " ++ show x

_logCNF :: (Show a, MonadWriter [Char] m) => a -> m ()
_logCNF x = tell $ "Generated CNF: " ++ show x

_logResult :: (Show a, MonadWriter [Char] m) => a -> m ()
_logResult x = tell $ "Got result: " ++ show x

-- | run the sat solver, when we get a satisafiable call get the assignments
-- directly
runForDict :: Resultable d => S.Predicate -> IO (Result d)
runForDict x = S.runSMT $
  do x' <- x
     SC.query $
       do S.constrain x'
          getResultWith (toResultProp . LitB)

-- | Run the brute force baseline case, that is select every plain variant and
-- run them to the sat solver
runBruteForce ::
  (MonadTrans t, Show a,Show d, Ord a, Ord d, Resultable d, Monoid d
  , MonadState (SatDict d) (t IO)) =>
  VProp d a a -> t IO (Result d)
runBruteForce prop = lift $ flip evalStateT (initSt prop) $
  do
  _confs <- get
  let confs = M.keys _confs
      plainProps = if null confs
        then [Just (M.empty, prop)]
        else (\y -> sequence $ (y, selectVariant y prop)) <$> confs
  plainMs <- lift $
             mapM (bitraverse
                   (pure . configToResultProp)
                   (runForDict . symbolicPropExpr)) $ catMaybes plainProps
  return $ foldMap (uncurry helper) plainMs
  where
        helper c as =  insertToSat c as

-- | Run the and decomposition baseline case, that is deconstruct every choice
-- and then run the sat solver
runAndDecomp :: (Show a, Show d, Ord d, Ord a, Resultable d,
                MonadTrans t, Monad (t IO)) =>
  VProp d a a -> (d -> a) -> t IO (Result d)
runAndDecomp prop f =
  lift $ runForDict $ symbolicPropExpr $ andDecomp prop (f . dimName)

runVSMTSolve ::
  (Show d, Show a, Ord a, Ord d, MonadTrans t, Resultable d
  , MonadReader (SMTConf d a a) (t IO)) =>
  ConfigPool d
  -> VProp d a a
  ->  t IO (Result d)
runVSMTSolve configPool prop =
  do cnf <- ask
     -- convert all refs to SBools
     let prop' = St.evalStateT (propToSBool prop) (mempty, mempty)
     -- run the inner driver
     res <- lift . S.runSMTWith (conf cnf) $! vSMTSolve prop' configPool
     lift . return $ res

-- | wrapper around map to keep track of the variable references we've seen, a,
-- and their symbolic type, b, which is eta reduced here
type UsedVars a = M.Map a

-- | a set of dimensions that have been processed and have generated models
type GenModel = Bool

-- | A state monad transformer that holds two usedvar maps, one for booleans and
-- one for doubles
type IncPack a = St.StateT (UsedVars a S.SBool, UsedVars a SNum) S.Symbolic

-- | a pool of configurations used to perform selection. A list is appropriate
-- here because we only use it as a stack, or a single traversal and we require
-- the semantics of a possible infinite (co-inductive for you nerds)
-- data structure
type ConfigPool a = [(Config a)]

-- | a mapping keeping the config and the unsatisfiable core of the config; used
-- in the case of an usat result
type UnSatResult d = M.Map (ResultProp d) UnSatCore

-- | the internal state for the incremental solve algorithm, it holds a result
-- list, and the used dims map, and is parameterized by the types of dimensions,
-- d
data IncState d =
  IncState { result      :: !(ResultMap d)     -- * the result map
           , configPool  :: !(ConfigPool d) -- * the pool of
                                            -- configs that
                                            -- dictate
                                            -- selection
           , runViaPool  :: Bool            -- * Boolean flag dictating whether
                                            -- to inspect the config pool or not
           , config      :: !(Maybe (Config d)) -- * the current config
           , processed   :: GenModel            -- * a flag denoting
                                                -- that a model has been
                                                -- generated during a
                                                -- recursive call
           , unSatResult :: UnSatResult d       -- * a result mapping
                                                -- to store
                                                -- unsatisfiable
                                                -- cores in the case
                                                -- of an unsat call
           } deriving (Eq,Show)

emptySt :: (Resultable d, Monoid d) => IncState d
emptySt = IncState{ result=mempty
                  , configPool=mempty
                  , config=(Just mempty)
                  , processed=False
                  , runViaPool=False
                  , unSatResult=mempty
                  }

isEmptySt :: (Resultable d, Monoid d) => IncState d -> Bool
isEmptySt = (==) emptySt

onResult :: (ResultMap d -> ResultMap d) -> IncState d -> IncState d
onResult f IncState {..} = IncState {result=f result, ..}

onConfig :: (Config d -> Config d) -> IncState d -> IncState d
onConfig f IncState {..} = IncState {config=f <$> config, ..}

onConfigPool :: (ConfigPool d -> ConfigPool d) -> IncState d -> IncState d
onConfigPool f (IncState {..}) = IncState {configPool=f configPool, ..}

onUnSatResult :: (UnSatResult d -> UnSatResult d) -> IncState d -> IncState d
onUnSatResult f (IncState {..}) = IncState {unSatResult=f unSatResult, ..}

setViaPool :: Bool -> IncState d -> IncState d
setViaPool b (IncState {..}) = IncState {runViaPool=b, ..}

deleteFromConfig :: Ord d => (Dim d) -> IncState d -> IncState d
deleteFromConfig = onConfig . M.delete

runWithPool :: IncState d -> IncState d
runWithPool = setViaPool True

runWithoutPool :: IncState d -> IncState d
runWithoutPool = setViaPool False

replacePool :: ConfigPool d -> IncState d -> IncState d
replacePool = onConfigPool . const

insertToConfig :: Ord d => (Dim d) -> Bool -> IncState d -> IncState d
insertToConfig d b = onConfig $ M.insert d b

insertToUnSat :: Ord d => ResultProp d -> [String] -> IncState d -> IncState d
insertToUnSat cfg reason = onUnSatResult $ M.insert cfg reason

replaceConfig :: Config d -> IncState d -> IncState d
replaceConfig = onConfig . const

onProcessed :: (GenModel -> GenModel) -> IncState d -> IncState d
onProcessed f IncState {..} = IncState {processed=f processed, ..}

-- | the incremental solve monad, with the base monad being the query monad so
-- we can pull out sbv models Hardcoding so that I don't have to write the mtl
-- typeclass. I do not expect these to change much
type IncVSMTSolve d = St.StateT (IncState d) SC.Query

-- | Top level wrapper around engine and monad stack, this sets options for the
-- underlying solver, inspects the results to see if they were variational or
-- not, if not then it gets the plain model
vSMTSolve :: (Ord d, Show d, Resultable d) =>
  S.Symbolic (VProp d S.SBool SNum) -> ConfigPool d-> S.Symbolic (Result d)
vSMTSolve prop configPool =
  do prop' <- prop
     SC.query $
       do
         let
           f = if null configPool then runWithoutPool else runWithPool
           startState = f $! replacePool configPool emptySt
         (b,resSt) <- St.runStateT (vSMTSolve_ prop') startState
         if isEmptySt resSt
           then do S.constrain b
                   b' <- isSat
                   if b'
                     then getResultWith (toResultProp . LitB)
                     else return mempty
           else return . Result $ result resSt

-- | This ensures two things: 1st we need all variables to be symbolic before
-- starting query mode. 2nd we cannot allow any duplicates to be called on a
-- string -> symbolic a function or missiles will launch.
propToSBool :: (Show a,Ord a) => VProp d a a -> IncPack a (VProp d S.SBool SNum)
propToSBool (RefB x)     = RefB   <$> smtBool x
propToSBool (OpB o e)    = OpB  o <$> propToSBool e
propToSBool (OpBB o l r) = OpBB o <$> propToSBool l <*> propToSBool r
propToSBool (ChcB d l r) = ChcB d <$> propToSBool l <*> propToSBool r
propToSBool (OpIB o l r) = OpIB o <$> propToSBool' l <*> propToSBool' r
propToSBool (LitB b)     = return $ LitB b

propToSBool' :: (Ord b, Show b) => VIExpr d b -> IncPack b (VIExpr d SNum)
propToSBool' (Ref RefI i) = Ref RefI <$> smtInt i
propToSBool' (Ref RefD d) = Ref RefD <$> smtDouble d
propToSBool' (OpI o e)    = OpI o    <$> propToSBool' e
propToSBool' (OpII o l r) = OpII o <$> propToSBool' l <*> propToSBool' r
propToSBool' (ChcI d l r) = ChcI d <$> propToSBool' l <*> propToSBool' r
propToSBool' (LitI x)     = return $ LitI x

-- | a builder function that abstracts out the packing algorithm for numbers. It
-- takes a function to convert a string to a symbolic variable like S.sInt64, or
-- S.sDouble, a constructor that add the symbolic type to the sum type SNum and
-- produces a function k -> t m SNum, which reifies to k -> IncPack k SNum.
mkSmt :: (Ord k, MonadTrans t, Monad m, Show k,
           MonadState (d, UsedVars k SNum) (t m)) =>
         (String -> m a) -> (a -> SNum) -> k -> t m SNum
mkSmt f g str = do (_,st) <- get
                   case str `M.lookup` st of
                     Nothing -> do b <- lift . f $ show str
                                   let b' = g b
                                   St.modify' (second $ M.insert str b')
                                   return b'
                     Just x  -> return x


-- | convert every reference to a boolean, keeping track of what you've seen
-- before, can't use mkStatement here because its a special case
smtBool :: (Show a, Ord a) => a -> IncPack a S.SBool
smtBool str = do (st,_) <- get
                 case str `M.lookup` st of
                   Nothing -> do b <- lift . S.sBool $ show str
                                 St.modify' (first $ M.insert str b)
                                 return b
                   Just x  -> return x

-- | convert every reference to a Integer, keeping track of what you've seen
-- before
smtInt :: (Show a, Ord a) => a -> IncPack a SNum
smtInt = mkSmt S.sInt64 SI

-- | convert every reference to a Integer, keeping track of what you've seen
-- before
smtDouble :: (Show a, Ord a) =>  a -> IncPack a SNum
smtDouble = mkSmt S.sDouble SD

-- | check if the current context is sat or not
isSat :: SC.Query Bool
isSat = do cs <- SC.checkSat
           return $ case cs of
                      SC.Sat -> True
                      _      -> False


-- | type class needed to avoid lifting for constraints in the IncSolve monad
instance (Monad m, I.SolverContext m) =>
  I.SolverContext (StateT (IncState d) m) where
  constrain = lift . (force S.constrain)
  namedConstraint = (lift .) . S.namedConstraint
  setOption = lift . S.setOption

-- Helper functions for solve routine

store :: (Eq d, Ord d, Resultable d) => Result d -> IncVSMTSolve d ()
store EmptyResult = return ()
store (Result res) = St.modify' $! onResult ((<>) res)
store (UnSatResult res) =
  do cfg' <- gets config
     let cfg = configToResultProp $! fromMaybe mempty cfg'
     St.modify' (onUnSatResult (M.singleton cfg res <>))

setDim :: Ord d => (Dim d) -> Bool -> IncVSMTSolve d ()
setDim = (St.modify' .) . insertToConfig

removeDim :: Ord d => (Dim d) -> IncVSMTSolve d ()
removeDim = St.modify' . deleteFromConfig

setConfigPool :: ConfigPool d -> IncVSMTSolve d ()
setConfigPool = St.modify' . replacePool

setConfig :: Config d -> IncVSMTSolve d ()
setConfig = St.modify' . replaceConfig

resetConfig :: Ord d => IncVSMTSolve d ()
resetConfig = setConfig mempty

setConfig' :: Maybe (Config d) -> IncVSMTSolve d ()
setConfig' c = St.modify' $ helper
  where helper (IncState{..}) = IncState{config=c,..}

hasGenDModel :: IncVSMTSolve d Bool
hasGenDModel = gets processed

setModelGenD :: IncVSMTSolve d ()
setModelGenD = St.modify' $ onProcessed (const True)

setModelNotGenD :: IncVSMTSolve d ()
setModelNotGenD = St.modify' $ onProcessed (const False)

solveVariant :: (Resultable d, Show d) =>
  IncVSMTSolve d S.SBool -> IncVSMTSolve d (Result d)
solveVariant go = do
           setModelNotGenD

           -- the recursive computaton
           lift $! SC.push 1
           go >>= S.constrain

           -- check if the config was satisfiable, and if the recursion
           -- generated a model
           bd <- hasGenDModel

           -- if not generated a model, then construct a -- result
           resMap <- if (not bd)
                     then do prop <- gets (configToResultProp . fromJust . config)
                             lm <- lift $ getResult prop
                             setModelGenD
                             if not $ isResultNull lm
                               -- if not null then sat
                               then return $! insertToSat prop lm
                               -- result was null so unsat
                               else return mempty
                      else -- not sat or have gen'd a model so ignore
                       return mempty

           -- reset stack
           lift $! SC.pop 1
           return resMap

-- handleChc :: (Ord d, Boolean b) =>
--   IncVSMTSolve d (Result d) ->
--   IncVSMTSolve d (Result d) ->
--   Dim d ->
--   IncVSMTSolve d b
handleChc goLeft goRight d =
  do rvp <- gets runViaPool
  -- when we have the flag to run with a pool we manipulate the current config
  -- and pool to generate configs when the config is empty. We denote the end of
  -- processing when the config is Nothing
     when rvp $ do
         st <- get
         let currentCfg' = config st
             cfgPool = configPool st
         if (maybe False M.null currentCfg')
           -- then we aren't solving a config, so check pool
           then if (not $ null cfgPool)
                -- we still have a pool of configs to draw from so pick one
                then do let (cfg:pool) = cfgPool
                        setConfig cfg
                        setConfigPool pool
                -- else we no longer have a pool and a config, so we return Nothing
                -- which denotes being finished processing
                else setConfig' Nothing
           --  we have a current config so we just leave it unchanged
           else return ()

     currentCfg <- gets config
     when (isJust currentCfg) $ do
            case M.lookup d (fromJust currentCfg) of
              Just True  -> do goLeft >>= store
              Just False -> do goRight >>= store
              Nothing    -> do
                --------------------- true variant -----------------------------
                setDim d True
                resMapT <- goLeft

                -------------------- false variant -----------------------------
                setDim d False
                resMapF <- goRight

                -- store results and cleanup config
                store $! resMapT
                store $! resMapF

                -- we remove the Dim from the config so that when the recursion
                -- completes the last false branch of the last choice is not
                -- remembered. For Example if we have A<p,q> /\ B<r,s> then the
                -- recursion starts at A and completes at the right variants of
                -- B, namely s. If we don't remove the dimension from the config
                -- then the config will retain the selection of (B, False) and
                -- therefore on the (A, False) branch of the recursion it'll
                -- miss (B, True)
                removeDim d
                return ()

     -- this return statement should never matter because we've reset the
     -- assertion stack. So I just return true here, this last check is to tie
     -- the know for the recursion. We check that we run with the pool and that
     -- our config is not nothign which means the recursion is complete. If both
     -- are the case then we reset the config and recur, if not then we return
     -- true as we are done
     if (isJust currentCfg &&& rvp)
       then do resetConfig
               handleChc goLeft goRight d
       else return true

-- | Handle a choice in the IncVSMTSolve monad, we check to make sure that if a
-- choice is already selected then the selection is maintained. If not then we
-- solve both branches by first clearing the state, recursively solving, if the
-- recursive answer is plain then we'll get back a model from the solver, if not
-- then we'll get back a variational model, if we get back a variational model
-- then we reconstruct the choice expression representing the model and store it
-- in the state. This works by having a zipper (focus, context) that tracks the
-- recurses through the proposition. When the prop is plain it will simple
-- convert everything to SBools via vSMTSolve and store that is the ctx which is
-- the constrained in runVSMTsolve. If there is a choice then we employ the
-- context to solve recursively by selecting a variant as our new focus and
-- recurring.
handleCtx :: (Ord d, Show d, Resultable d) =>
  Loc d S.SBool SNum -> IncVSMTSolve d S.SBool
  -- when we have no ctx we just solve the unit clause
handleCtx (Loc (OpIB _ _ _) _) = error "what?!?! How did you even get here! Get Jeff on the phone this isn't implemented yet!"
handleCtx (Loc (RefB b) Empty) = return b
handleCtx (Loc (LitB b) Empty) = return $! S.literal b
  -- when we have a context that holds only an accumulator we combine the atomic
  -- with the accum and return the result
handleCtx (Loc (RefB b) (InBBR op acc Empty)) =
  return $! bDispatch op acc b
handleCtx (Loc (LitB b) (InBBR op acc Empty)) =
  return $! bDispatch op acc (S.literal b)

  -- When we see an atomic in a left context we add that atomic to the
  -- accumulator and recur to the rhs of the operator
handleCtx (Loc (RefB b) (InBBL op ctx rbranch)) =
  handleCtx $! mkLoc (rbranch, InBBR op b ctx)
handleCtx (Loc (LitB b) (InBBL op ctx rbranch)) =
  handleCtx $! mkLoc (rbranch, InBBR op (S.literal b) ctx)
handleCtx (Loc (LitB b) (InB _ ctx)) = handleCtx $! mkLoc (LitB $ bnot b, ctx)
handleCtx (Loc (RefB b) (InB _ ctx)) = handleCtx $! mkLoc (RefB $ bnot b, ctx)

  -- when we are in the left side of a context and the right side of a subtree
  -- we add the atomics to the accumulator and swap to the right side of the
  -- parent context with the new accumulator being the result of computing the
  -- left side
handleCtx (Loc (RefB b) (InBBR op acc (InBBL op' ctx r))) =
  do (handleCtx $! mkLoc (r , InBBR op' newAcc ctx))
  where !newAcc = bDispatch op acc b
  -- if we have two rhs contexts then we abuse the focus to
handleCtx (Loc (RefB b) (InBBR op acc ctx)) =
  do (handleCtx $! mkLoc (RefB newAcc, ctx))
  where !newAcc = bDispatch op acc b
handleCtx (Loc (LitB b) (InBBR op acc ctx)) =
  -- we wrap in RefB just to get the types to work out
  do (handleCtx $! mkLoc (RefB newAcc, ctx))
  where !newAcc = bDispatch op acc (S.literal b)

  -- reduce double negations
handleCtx (Loc fcs (InB Not (InB Not ctx))) = handleCtx $! mkLoc (fcs, ctx)
  -- accumulate a negation
handleCtx (Loc fcs (InB Not (InBBR op acc ctx))) =
  handleCtx $! mkLoc (fcs, (InBBR op (bnot acc) ctx))

  -- when we see a choice we describe the computations for each variant and
  -- offload it to a handler function that manipulates the sbv assertion stack
handleCtx (Loc (ChcB d l r) ctx@(InBBR _ acc _)) =
  do
    -- we push onto the assertion and constrain to capture the solver state
    -- before processing the choice. This allows us to cache the state before
    -- the choice
    -- lift $! SC.push 1
    -- constrain current accumulator
    S.constrain acc
    handleChc goLeft goRight d
  where !goLeft  = solveVariant (handleCtx (mkLoc (l, ctx)))
        !goRight = solveVariant (handleCtx (mkLoc (r, ctx)))

  -- this handles the case when the accumulator is one parent node away
handleCtx (Loc (ChcB d l r) ctx@(InBBL _ (InBBR _ acc _) _)) =
  do
    -- push onto assertion stack
    -- lift $! SC.push 1
    -- constrain current accumulator
    S.constrain acc
    handleChc goLeft goRight d
  where !goLeft  = solveVariant (handleCtx (mkLoc (l, ctx)))
        !goRight = solveVariant (handleCtx (mkLoc (r, ctx)))

  -- When we observe the special case of a choice wrapped in a not we
  -- distribute the not into the variants. This makes the zipper semantics
  -- much easier because we don't have a clean way to negate the previous
  -- accumulator in the zipper. Also such a negation would be an O(i) operation
  -- in a hot loop. Best to avoid
handleCtx (Loc (ChcB d l r) (InB Not ctx)) =
    handleCtx $! Loc (ChcB d (bnot l) (bnot r)) ctx

  -- If we see a choice with any other context then the ctx is either empty
  -- or the choice is in the leftmost position of the ast
handleCtx (Loc (ChcB d l r) ctx) =
    handleChc goLeft goRight d
  where !goLeft  = solveVariant (handleCtx (mkLoc (l, ctx)))
        !goRight = solveVariant (handleCtx (mkLoc (r, ctx)))

handleCtx (Loc (OpB Not e) (InB _ ctx)) = handleCtx $! mkLoc (e, ctx)
handleCtx (Loc (OpB op e) ctx) = handleCtx $! mkLoc (e, InB op ctx)

  -- when we have a subtree as our focus we recur as far left as possible until
  -- we hit a choice or an atomic term
handleCtx (Loc (OpBB op l r) ctx) = handleCtx $! mkLoc (l, InBBL op ctx r)


-- | The main solver algorithm. You can think of this as the sem function for
-- the dsl
vSMTSolve_ :: (Ord d, Show d, Resultable d) =>
  VProp d S.SBool SNum -> IncVSMTSolve d S.SBool
vSMTSolve_ (RefB b) = return b
vSMTSolve_ (LitB b) = return $! S.literal b
vSMTSolve_ (OpB Not (OpB Not notchc)) = vSMTSolve_ notchc
vSMTSolve_ (OpB Not e) = handleCtx   . Loc e $! InB Not Empty
vSMTSolve_ (OpBB op l r) = handleCtx . Loc l $! InBBL op Empty r
vSMTSolve_ (OpIB _ _ _) = error "Blame Jeff! This isn't implemented yet!"
-- vSMTSolve_ !(OpIB op l r) = do l' <- vSMTSolve'_ l
--                                r' <- vSMTSolve'_ r
--                                _ <- reifyArithChcs l' r' (handler op)
--   -- this result should, and will never matter the return values from the
--   -- handler are handled in side effects
--                                return true
--   where handler LT  = (.<)
--         handler LTE = (.<=)
--         handler GTE = (.>=)
--         handler GT  = (.>)
--         handler EQ  = (.==)
--         handler NEQ = (./=)
vSMTSolve_ c@(ChcB _ _ _) = handleCtx $! Loc c Empty
