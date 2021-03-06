{-# LANGUAGE TemplateHaskell , DeriveGeneric #-}
{-# OPTIONS  -funbox-strict-fields #-}

module ParseSyntax where -- import qualified as PSyn

import Prim
import qualified Data.Map as M
--import qualified Data.HashMap.Strict as HM
--import qualified Data.Vector as V
import Control.Lens

type IName = Int
type HName = Text
type FName = IName -- record  fields
type LName = IName -- sumtype labels
type FreeVar = IName -- let or non-local argument needed deeper in a function nest
type ImplicitArg = (IName , Maybe TT) -- implicit arg with optional type annotation
type FreeVars = IntSet
type NameMap = M.Map HName IName

data MixFixName = MFHole | MFName HName deriving (Show , Eq)
type MixFixDef = [MixFixName]

data Fixity = Fixity Assoc (Maybe Int) [IName]
data Assoc = AssocNone | AssocLeft | AssocRight

data ImportDecl -- extern types can't be checked (eg. syscalls / C apis etc..)
 = Extern   { externName :: HName , externType :: TT }
 | ExternVA { externName :: HName , externType :: TT }

data Module = Module {
   _moduleName :: HName

 , _imports    :: [HName]
 , _externFns  :: [ImportDecl]
 , _bindings   :: [TopBind] -- top binds

 , _parseDetails :: ParseDetails
}

data ParseDetails = ParseDetails {
 -- Note. mixFixDefs stored in these maps are partial:
 -- for mf, the first, and for postfixes the first 2 elems of the mixfixdef list are implicit
   _mixFixDefs    :: M.Map HName [(MixFixDef , TTName)] -- all mixfixDefs starting with a name
 , _postFixDefs   :: M.Map HName [(MixFixDef , TTName)] -- mixfixes starting with _
 , _hNameBinds    :: (Int , NameMap) -- count anonymous args (>= nameMap size)
 , _hNameLocals   :: [NameMap] -- let-bound
 , _hNameArgs     :: [NameMap]
 , _freeVars      :: FreeVars
 , _nArgs         :: Int
 , _hNamesNoScope :: NameMap
 , _fields        :: NameMap
 , _labels        :: NameMap
-- , fixities     :: V.Vector Fixity
}

data TopBind = FunBind {
   fnNm         :: HName
 , implicitArgs :: [ImplicitArg]
 , fnFreeVars   :: FreeVars
 , fnMatches    :: [FnMatch]
 , fnSig        :: (Maybe TT)
-- , fnIsRec      :: Bool
}
data FnMatch = FnMatch [ImplicitArg] [Pattern] TT

data TTName
 = VBind   IName
 | VLocal  IName
 | VExtern IName

-- info on record fields
data FieldInfo = FieldInfo {
   mixfix     :: Int
 , dependents :: FName
}

data LensOp a = LensGet | LensSet a | LensOver a deriving Show

-- Parser Expressions (types and terms are syntactically equivalent)
data TT
 = Var !TTName
 | WildCard -- "_"

 -- lambda-calculus
 | Abs TopBind
 | App TT [TT]
 | InfixTrain TT [(TT, TT)] -- precedence unknown

 -- tt primitives (sum , product , list)
 | Cons   [(FName , TT)] -- can be used to type itself
 | Proj   TT FName
 | TTLens TT [FName] (LensOp TT)
 | Label  LName [TT]
 | Match  [(LName , FreeVars , [Pattern] , TT)]
 | List   [TT]
-- | TySum  [(LName , [TT])]
 | TySum [(LName , [ImplicitArg] , TT)] -- function signature
 | TyListOf TT

 -- term primitives
 | Lit     Literal
 | LitArray [Literal]

-- patterns represent arguments of abstractions
data Pattern
 = PArg  IName -- introduce VLocal arguments
 | PTT   TT
 | PApp  Pattern [Pattern]
-- | PLit  Literal
-- | PWildCard
-- | PTyped Pattern TT
-- | PAs   IName Pattern
-- | match sum-of-product ?

makeLenses ''Module
makeLenses ''ParseDetails

showL ind = Prelude.concatMap $ (('\n' : ind) ++) . show
prettyModule m = show (m^.moduleName) ++ " {\n"
    ++ "imports: " ++ showL "  " (m^.imports)  ++ "\n"
    ++ "binds:   " ++ showL "  " (m^.bindings) ++ "\n"
--  ++ "locals:  " ++ showL "  " (m^.locals)   ++ "\n"
    ++ show (m^.parseDetails) ++ "\n}"
prettyParseDetails p = Prelude.concatMap ("\n  " ++) 
    [ "binds:  " ++ show (p^.hNameBinds)
    , "args:   " ++ show (p^.hNameArgs)
    , "extern: " ++ show (p^.hNamesNoScope)
    , "fields: " ++ show (p^.fields)
    , "labels: " ++ show (p^.labels)
    ]
prettyTTName = \case
    VBind x   -> "π" ++ show x 
    VLocal  x -> "λ" ++ show x
    VExtern x -> "?" ++ show x

--deriving instance Show Module
deriving instance Show ParseDetails
deriving instance Show TopBind
deriving instance Show ImportDecl
deriving instance Show TTName
deriving instance Show Fixity
deriving instance Show Assoc
deriving instance Show FnMatch 
deriving instance Show TT
deriving instance Show Pattern
