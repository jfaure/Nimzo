-- Type judgements: checking and inferring
-- http://pauillac.inria.fr/~remy/mlf/icfp.pdf
-- https://www.microsoft.com/en-us/research/wp-content/uploads/2016/02/boxy-icfp.pdf

-- The goal is to check and/or infer the types of all top level bindings
-- (and the types (kinds) of the types.. etc)
--   * evaluate (static) dependent types
--   * type-check
--   * inference: reduce every type to an llvm.AST.Type

-- Inference can guess monotypes, but not polytypes

-- skolemization = remove existential quantifiers
--   boxy matching: fill boxes with monotypes
--   (no instantiation/skolemization)

-- Flexible Vs rigid
-- flexible = subsume a type (<=)
-- rigid    = all must be exactly the same type (=)

-- By design, boxy matching is not an equivalence relation:
-- it is not reflexive (that would require guessing polytypes)
-- neither is it transitive |s|~s and s~|s| but not |s|~|s|.
-- similarly, boxy subsumption is neither reflexive nor transitive

module TypeJudge where
import Prim
import CoreSyn as C
import PrettyCore
import qualified CoreUtils as CU

import qualified Data.Vector.Mutable as MV -- mutable vectors
import Control.Monad.ST
import qualified Data.Vector as V
import qualified Data.Map as M
import qualified Data.HashMap.Strict as HM
import qualified Data.IntMap as IM
import qualified Data.Text as T
import Data.Functor
import Control.Monad
import Control.Applicative
import Control.Monad.Trans.State.Strict
import Data.Char (ord)
import Data.List (foldl', intersect)
import GHC.Exts (groupWith)

import Debug.Trace

dump :: TCEnv ()
dump = traceM =<< gets (ppCoreModule . coreModule)

data TCEnvState = TCEnvState { -- type check environment
   coreModule    :: CoreModule
 , errors        :: [TCError]
 , dataInstances :: V.Vector Entity -- specialized data (tyFunctions)
}

type TCEnv a = State TCEnvState a

judgeModule :: CoreModule -> CoreModule
judgeModule cm =
  let startState = TCEnvState
        { coreModule    = cm
        , errors        = []
        , dataInstances = V.empty
        }
      handleErrors :: TCEnvState -> CoreModule
        = \st -> case errors st of
        [] -> (coreModule st) { tyConInstances = dataInstances st }
        errs -> error $ show errs
      go = V.imapM (judgeBind cm) (V.take (nTopBinds cm) (bindings cm))
  in handleErrors $ execState go startState

-- functions used by judgeBind and judgeExpr
lookupBindM :: IName -> TCEnv Binding
 = \n -> CU.lookupBinding n <$> gets (bindings . coreModule)
typeOfM :: IName -> TCEnv Type
 = \n -> CU.typeOfBind n    <$> gets (bindings . coreModule)
lookupHNameM :: IName -> TCEnv (Maybe HName)
 = \n -> named . info . CU.lookupBinding n
          <$> gets (bindings . coreModule)

-- modify a binding's type annotation
_updateBind :: IName -> Binding -> Type -> CoreModule -> CoreModule
_updateBind n b newTy cm =
  let binds = bindings cm
      newBind = b{ info = (info b) { typed=newTy , checked=True } }
      binds' = V.modify (\v->MV.write v n newBind) binds
  in cm { bindings=binds' }

updateBindTy :: IName -> Type -> TCEnv () = \n newTy -> do
   b <- gets $ CU.lookupBinding n . bindings . coreModule
-- traceM $ show (typed $ info b) ++ " => " ++ show newTy
   let isPoly = \case { TyPoly{}->True ; _->False }
-- when (not $ checked $ info $ b) $
   modify (\x->x{ coreModule = _updateBind n b newTy (coreModule x) })

-- Rule lambda: propagate (maybe partial) type annotations downwards
-- let-I, let-S, lambda ABS1, ABS2 (pure inference case)
judgeBind :: CoreModule -> IName -> Binding -> TCEnv ()
 = \cm bindINm ->
  let unVar = CU.unVar (algData cm)
  in \case
  LBind inf args e ->
    let judgeFnBind arrowTys = do
          zipWithM updateBindTy args arrowTys
          -- Careful with splitting off and rebuilding TyArrows
          -- to avoid nesting (TyArrow [TyArrow [..]])
          let retTy = case drop (length args) arrowTys of
                []  -> error "impossible"
                [t] -> t
                tys -> TyArrow tys
          judgedRetTy <- judgeExpr e retTy cm
          argTys      <- mapM typeOfM args
          let fnTy = case judgedRetTy of
                r@(TyArrow rTs) -> TyArrow (argTys ++ rTs)
                r -> TyArrow (argTys ++ [r])
--        traceM (show bindINm ++ " - " ++ show fnTy)
          updateBindTy bindINm fnTy
    in case unVar (typed inf) of
      TyArrow arrowTys -> judgeFnBind arrowTys
      TyInstance _ TyPAp{} -> error "pap" -- judgeFnBind True  arrowTys
      -- notFnTys can still be 'proxy' functions that pass on all args
      notFnTy -> judgeExpr e notFnTy cm >>= \ty -> case args of
        [] -> updateBindTy bindINm ty
        args -> do 
          -- 'proxy' functions eg. `f a = (+) 1 a` just pass on args.
          binds <- mapM lookupBindM args
          let argTys = typed . info <$> binds
              fnTy = TyArrow $ argTys ++ [ty]
          updateBindTy bindINm fnTy
  _ -> pure ()
--LChecked i -> pure ()
--LArg    i uc       -> pure () -- pure $ typed i
--LCon    i          -> pure () -- pure $ typed i
--LClass i decl insts-> pure () -- pure $ traceShowId $ typed i
--LExtern i          -> pure () -- pure $ typed i
--Inline i e         -> pure ()
--LTypeVar{}         -> pure ()

-- type judgements
-- a UserType of TyUnknown needs to be inferred. otherwise check it.
judgeExpr :: CoreExpr -> UserType -> CoreModule -> TCEnv Type
 = \got expected cm ->
  let
  -- local shortcuts ommitting boilerplate arguments
  unVar :: Type -> Type = CU.unVar (algData cm)
  subsume' a b = subsume a b unVar
  judgeExpr' got expected = judgeExpr got expected cm

  (numCls , realCls) =
    let unJ j = case j of { Just x -> TyAlias x ;
          Nothing-> error $ "prim "++ show j ++" not in scope"}
        getClass clsNm = unJ $ T.pack clsNm `HM.lookup` hNameTypes cm
    in (getClass "Num" , getClass "Real")

  -- case expressions have the type of their most general alt
  mostGeneralType :: [Type] -> Maybe Type =
   let mostGeneral :: Type -> Type -> Maybe Type = \t1' t2 ->
         -- directly use parent type if subty found
         let t1 = case unVar t1' of
               TyMono (MonoSubTy r parentTy conIdx) -> TyAlias parentTy
               t -> t
         in if
           | subsume' t1 t2 -> Just t1
           | subsume' t2 t1 -> Just t2
           | True           -> Nothing
   in foldr (\t1 t2 -> mostGeneral t1 =<< t2) (Just TyUnknown)

  fillBoxes :: Type -> Type -> Type
  fillBoxes got TyUnknown = got -- pure inference case
  fillBoxes got known = case unVar got of
    TyUnknown -> known -- trust the annotation
    TyArrow tys ->
      let TyArrow knownTys = unVar known
      in  TyArrow $ zipWith fillBoxes tys knownTys
    t -> got

  -- inference should never return TyUnknown
  -- ('got TyUnknown' fails to subsume)
  checkOrInfer :: Type -> Type
  checkOrInfer gotTy = case expected of
    TyUnknown -> case gotTy of
      TyUnknown -> error ("failed to infer a type for: " ++ show got)
      gotTy     -> gotTy
    _ -> if subsume' gotTy expected
      then gotTy
      else error ("subsumption failure:"
                   ++ "\nExpected: " ++ ppType' expected
                   ++ "\nGot:      " ++ ppType' gotTy
                   ++ "\n" ++ show (unVar gotTy) ++ " <:? " ++ show expected
                   ++ "\nIn the expression: " ++ show got
                   )

  in checkOrInfer <$> case got of

  Lit l    ->
    let ty = case l of
          String{} -> TyMono $ MonoTyPrim $ PtrTo (PrimInt 8) --"CharPtr"
          Array{}  -> TyMono $ MonoTyPrim $ PtrTo (PrimInt 8) --"CharPtr"
          PolyFrac{} -> realCls
          _ -> numCls
    in pure $ ty
  WildCard -> pure expected
  -- prims must have an expected type, exception is made for ExtractVal
  -- since that is autogenerated by patternmatches before type is known.
  Instr p args -> pure $ case p of
    MkNum  -> numCls
    MkReal -> realCls
    _ -> case expected of
      TyUnknown -> error ("primitive has unknown type: " ++ show p)
      t         -> expected
  Var nm ->
    -- 1. lookup type of the var in the environment
    -- 2. in checking mode, update env by filling var's boxes
    do -- TODO this may duplicate work
      bind <- lookupBindM nm
      judgeBind cm nm bind
      bindTy <- typed . info <$> lookupBindM nm
      let newTy = fillBoxes bindTy expected
--    updateBindTy nm newTy -- this is done in App ,
--    since we do not immediately know polymorphism at lookup there
      pure newTy

  -- APP expr: unify argTypes , instantiate and return arrows - args
  App fnName args -> let
    fn = Var fnName -- for printing errors
    -- instanciate: propagate information about instanciated polytypes
    -- eg. if ((neg) : Num -> Num) $ (3 : Int), then Num = Int here.
    instantiate :: IName -> [Type] -> [Type] -> TCEnv [Type]
    instantiate fnName argTys remTys = lookupBindM fnName >>= \case
      LClass classInfo _ allOverloads ->
        let
        isValidOverload candidateTy v
          = all (subsume' $ TyAlias candidateTy) argTys
        candidates = M.filterWithKey isValidOverload allOverloads
        in case M.size candidates of
          1 -> -- TODO return tys change ?
            let instId = head $ M.elems candidates
            in (unVar . typed . info <$> lookupBindM instId)
            <&> \case
            TyArrow tys ->
              [TyInstance (TyArrow remTys) (TyOverload instId)]
            _ -> error "panic, expected function"
          n -> let msg = if n==0 then "no valid types: "
                         else "ambiguous function instance: "
            in error $ msg ++ show argTys ++ "\n<:?\n" ++ show allOverloads
      _ -> pure $ remTys

    -- verify all arguments subsume the expected types,
    -- also reduce polymorphism and verify rigids are the same type
    polySubsumeArgs :: [Type] -> [Type] -> [Type] -> TCEnv [Type]
    polySubsumeArgs consumedTys remTys judgedArgTys = let
      insertLookup kx x t = IM.insertLookupWithKey (\_ a _ -> a) kx x t
      addPossibles i t tys mp = case IM.lookup i mp of
        Nothing  -> IM.insert i tys mp
        Just prevTys  -> -- TODO intersectBy (maybe can cmp TyAliases)
          let unInst = \case { TyInstance t _ -> t ; t -> t}
              possible = intersect (unVar <$> tys) prevTys
          in IM.insert i (filter (`subsume'` t) possible) mp
      doPoly (t@(TyAlias i) , judged) mp = case (unVar judged) of
--      TyRigid r -> if i == r then mp else error "TODO"
        TyPoly (PolyJoin tys) -> addPossibles i t tys mp        
        j -> if subsume' judged t then addPossibles i t [j] mp
             else error $ "cannot unify function args"
                ++ show judged ++ "\n <:?\n" ++ show t
      doPoly _ mp = mp
      expected' = case expected of
        TyUnknown -> case remTys of { [r] -> r ; r -> TyArrow r}
        t         -> t
      polyMap = foldr doPoly IM.empty -- $ traceShowId
        $ zip (consumedTys) (judgedArgTys ++ [expected'])
      oneSolution = \case
        []  -> error $ "No instance: "++show fn++" : "++show expected
        [t] -> t
        tys -> error $"ambiguous instance: "++show fnName++" :? "++show tys
      rigidsMap = oneSolution <$> polyMap

      args'  =  fst . betaReduce rigidsMap unVar <$> consumedTys
      remTys' = fst . betaReduce rigidsMap unVar <$> remTys

      updateTy TyUnknown _ = pure ()
      updateTy ty (Var i) = updateBindTy i ty
      updateTy _ _ = pure ()
      in do
      -- expected ?
      zipWithM_ updateTy args' args
      instantiate fnName args' remTys'

    judgeApp arrowTys isVA =
      let appArity = length args
          splitIndx = if isVA then appArity-1 else appArity
          (consumedTys , remTys) = splitAt splitIndx arrowTys
          checkArity = \case -- (saturated | PAp | VarArgs)
            []  -> last arrowTys -- TODO ensure fn is ExternVA
            [TyInstance (TyArrow ret) inst] ->
              TyInstance (checkArity ret) inst
            [t] -> t
            tys -> TyInstance (TyArrow remTys) $ TyPAp consumedTys remTys
          arrowTys' = if isVA --appArity >= length arrowTys
            then consumedTys ++ repeat TyUnknown
            else arrowTys
      in do
      judgedArgs <- zipWithM judgeExpr' args arrowTys'
      let inst = any (\case {TyInstance{}->True ; _->False}) judgedArgs
          mkInst t = if inst
            then TyInstance t (TyArgInsts judgedArgs) else t
      mkInst . checkArity <$> polySubsumeArgs arrowTys' remTys judgedArgs

    -- use term arg types to gather info on the tyFn's args here
    judgeTyFnApp argNms arrowTys = do
      let (consumedTys , remTys) = splitAt (length args) arrowTys
      judgedArgs <- zipWithM judgeExpr' args arrowTys
      let isRigid = \case {TyRigid{}->True;_->False}
          tyFnArgVals = filter (isRigid . fst)
                        $ zip (unVar <$> arrowTys) judgedArgs
          -- TODO check all vals equal
          prepareIM (TyRigid i, x) = (i , x)
          tyFnArgs = IM.fromList $ prepareIM <$> tyFnArgVals
          -- recursively replace all rigid type variables
      retTy_ <- polySubsumeArgs arrowTys remTys judgedArgs
      let [retTy] = retTy_ -- TODO

      -- generate newtype
      let (retTy' , datas) = betaReduce tyFnArgs unVar retTy
      case datas of
        [newData] -> doDynInstance newData
        _ -> pure retTy'

    doDynInstance (TyPoly (PolyData p@(PolyJoin subs)
                          (DataDef hNm alts))) = do
      let dataINm = parentTy $ (\(TyMono m) -> m) $ head subs
      insts <- gets dataInstances
      let idx = V.length insts
          mkNm hNm = hNm `T.append` T.pack ('@' : show idx)
          newNm = mkNm hNm
          newAlts = (\(nm,t) -> (mkNm nm , t)) <$> alts
          newData = TyPoly $ PolyData p (DataDef newNm newAlts)
          ent = CU.mkNamedEntity newNm newData
      modify (\x->x{ dataInstances=V.snoc (dataInstances x) ent })
      -- TODO !!
      let conIdx = 0
          sub    = head subs
      pure $ TyInstance (TyAlias dataINm) $ TyDynInstance idx conIdx

    judgeFn expFnTy =
      let judgeExtern eTys isVA
            = judgeApp (TyMono . MonoTyPrim <$> eTys) isVA
          notVA = False
          va    = True
      in case expFnTy of
      TyArrow tys -> judgeApp tys notVA
      TyInstance t _ -> judgeFn t
      TyFn argNms (TyArrow tys)->judgeTyFnApp argNms tys
      TyMono (MonoTyPrim (PrimExtern   eTys)) -> judgeExtern eTys notVA
      TyMono (MonoTyPrim (PrimExternVA eTys)) -> judgeExtern eTys va
      TyUnknown -> error ("failed to infer function type: "++show fn)
      t -> error ("not a function: "++show fn++" : "++show t)

    in judgeExpr' (Var fnName) TyUnknown >>= judgeFn . unVar

----------------------
-- Case expressions --
----------------------
-- 1. all patterns must subsume the scrutinee
-- 2. all exprs    must subsume the return type
  Case ofExpr a -> case a of
   Switch alts ->
    let tys = mapM (\(pat, expr) -> judgeExpr' expr expected) alts
    in head <$> tys

-- dataCase: good news is we know the exact type of constructors
   Decon alts -> do
    exprTys <- mapM (\(_,_,expr) -> judgeExpr' expr expected) alts
    patTys  <- mapM (\(con,args,_) -> case args of
        [] -> judgeExpr' (Var con) expected
        _  -> judgeExpr' (App con (Var <$> args)) expected
      ) alts

    let expScrutTy = case mostGeneralType patTys of
            Just t -> t
            Nothing -> error $ "bad case pattern : " ++ show patTys
    scrutTy <- judgeExpr' ofExpr expScrutTy

    let patsOk = all (\got -> subsume' scrutTy got)  patTys
        altsOk = all (\got -> subsume' got expected) exprTys
    pure $ if patsOk && altsOk then expected
           else error (if patsOk then "bad Alts" else "bad pats")
    -- TODO what if we don't know the expected type (in altsOK) ?
    -- use mostGeneralType probably

  TypeExpr (TyAlias l) -> pure expected
  unexpected -> error ("panic: tyJudge: " ++ show unexpected)

-----------------
-- Subsumption --
-----------------
-- t1 <= t2 ? is a vanilla type acceptable as a (boxy) type
-- 'expected' is a vanilla type, 'got' is boxy
-- note. boxy subsumption is not reflexive
-- This requires a lookup function to deref typeAliases
subsume :: Type -> Type -> (Type -> Type) -> Bool
subsume got exp unVar = subsume' got exp
  where
  -- local subsume with freeVar TyVarLookupFn
  subsume' gotV expV =
    let got = unVar gotV
        exp = unVar expV
    in case exp of
    TyRigid exp' -> case got of -- TODO check somehow !
      TyRigid got' -> True -- exp' == got'
      _ -> True -- make sure to check behind !
    TyMono exp' -> case got of
      TyMono got' -> subsumeMM got' exp'
      TyPoly got' -> subsumePM got' exp'
      TyInstance got' _ -> subsume' (unVar got') exp
      TyRigid{} -> True
      a -> error ("subsume: unexpected type: " ++ show a ++ " <:? " ++ show exp)
    TyPoly exp' -> case got of
      TyMono got'  -> subsumeMP got' exp'
      TyPoly got'  -> subsumePP got' exp'
      a -> error ("subsume: unexpected type: " ++ show a)
    TyArrow tysExp -> case got of
      TyArrow tysGot -> subsumeArrow tysGot tysExp
      TyPoly PolyAny -> True
      _ -> False
    TyFn _ _ -> _
    TyUnknown -> True -- 'got' was inferred, so assume it's ok

    TyCon{} -> True -- TODO
    other -> error ("panic: unexpected type: " ++ show other)

  subsumeArrow :: [Type] -> [Type] -> Bool
  subsumeArrow got exp = all id (zipWith subsume' got exp)

  subsumeMM :: MonoType -> MonoType -> Bool
  subsumeMM (MonoTyPrim t) (MonoTyPrim t2) = t == t2
  subsumeMM (MonoSubTy r _ _) (MonoSubTy r2 p _) = r == r2
--  subsumeMM got MonoRigid{} = True -- make sure to check behind
  subsumeMM a b = error $ show a ++ " -- " ++ show b

  subsumeMP :: MonoType -> PolyType -> Bool
   = \got exp            -> case exp of
    PolyAny              -> True
    PolyMeet tys    -> all (`subsume'` (TyMono got)) tys
    PolyJoin  tys       -> any (`subsume'` (TyMono got)) tys
    PolyData p _         -> subsumeMP got p

  subsumePM :: PolyType  -> MonoType -> Bool
--subsumePM (PolyData p _) m@(MonoRigid r) = subsumeMP m p
  subsumePM (PolyJoin [t]) m = subsume' t (TyMono m)
  subsumePM _ _ = False -- Everything else is invalid

  subsumePP :: PolyType  -> PolyType -> Bool
   = \got exp            -> case got of
    PolyAny              -> True
    PolyMeet gTys   -> _ -- all $ f <$> tys
    -- data: use the polytypes for subsumption
    PolyData p1 _        -> case exp of
      PolyData p2 _ -> subsumePP p1 p2
      _             -> False
    PolyJoin  gTys      -> case exp of
      PolyAny            -> False
      PolyMeet eTys -> _
      PolyJoin  eTys    -> hasAnyBy subsume' eTys gTys -- TODO check order
    where
    hasAnyBy :: (a->a->Bool) -> [a] -> [a] -> Bool
    hasAnyBy _ [] _ = False
    hasAnyBy _ _ [] = False
    hasAnyBy f search (x:xs) = any (f x) search || hasAnyBy f search xs

-----------
-- TyCons -
-----------
-- betareduce will inline tyfn argument types.
-- this may create some specialized data that it also needs to return
betaReduce :: (IM.IntMap Type) -> (Type->Type) -> Type
           -> (Type , [Type])
betaReduce mp unVar ty = runState (_betaReduce mp unVar ty) []

_betaReduce :: (IM.IntMap Type)->(Type->Type)->Type -> State [Type] Type
_betaReduce rigidsMap unVar (TyPoly (PolyData polyTy dDef)) =
  let betaReduce' = _betaReduce rigidsMap unVar
      DataDef hNm alts = dDef
      doAlt (hNm, tys) = (hNm ,) <$> mapM betaReduce' tys
      newAlts = mapM doAlt alts
  in do
    newDDef <- DataDef hNm <$> newAlts
    -- leave the polyty
--  newPolyTy <- betaReduce' $ TyPoly polyTy
    let polyData = TyPoly (PolyData polyTy newDDef)
    modify (polyData :)
    pure polyData

_betaReduce rigidsMap unVar ty =
  let betaReduce' = _betaReduce rigidsMap unVar
  in case ty of
  TyRigid i -> pure $ maybe ty id (IM.lookup i rigidsMap)
  TyMono (MonoSubTy sub parent c)-> betaReduce' (unVar (TyAlias parent))
  TyArrow tys -> TyArrow <$> mapM betaReduce' tys
  TyPoly tyPoly -> case tyPoly of
    PolyJoin [t] -> pure t
    PolyJoin tys -> pure $ TyPoly $ PolyJoin tys --mapM betaReduce' tys
  TyFn tyArgs tyVal -> if length tyArgs /= IM.size rigidsMap
      then error $ "tyCon pap: " ++ show ty
      else betaReduce' tyVal
--  TyApp ty argsMap -> betaReduce (IM.union argsMap rigidsMap) ty
  -- aliases are ignored,
  -- we cannot beta reduce anything not directly visibile
  TyAlias i -> {-case unVar (TyAlias i) of
    TyRigid i -> -} pure $ maybe ty id (IM.lookup i rigidsMap)
    --t -> pure t
  ty -> pure ty
