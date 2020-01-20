{- LANGUAGE OverloadedLists -}
import CmdLine
import ParseSyntax
import Parser
import Modules
import CoreSyn
import qualified CoreUtils as CU
import ToCore
import PrettyCore
import TypeJudge
import Core2Stg
--import StgSyn
import StgToLLVM (stgToIRTop)
import qualified LlvmDriver as LD

import Text.Megaparsec
import qualified Data.Text as T
import qualified Data.Text.IO as T.IO
import qualified Data.Text.Lazy.IO as TL.IO

import Control.Monad.Trans (lift)
import Control.Applicative
import System.Console.Haskeline
import System.Exit
import Data.Functor
import Data.Maybe (isJust, fromJust)
import qualified Data.Vector as V
import LLVM.Pretty
import Debug.Trace

preludeFNames = V.empty -- V.fromList ["Library/Prim.arya"]
searchPath    = ["Library/"]

xd = let f = "trivial/sum.arya" in doProgText defaultCmdLine{emitCore=True} f =<< T.IO.readFile f
main = parseCmdLine >>= \cmdLine ->
  case files cmdLine of
    []  -> repl cmdLine
    [f] -> doProgText cmdLine f =<< liftA2 T.append (T.IO.readFile "Library/Prim.arya") (T.IO.readFile f)
--  [f] -> doProgText cmdLine f =<< T.IO.readFile f
    av  -> error "one file pls"
--  av -> mapM_ (doFile cmdLine) av

doImport :: FilePath -> IO CoreModule
doImport fName = (judgeModule . parseTree2Core V.empty) <$> do
  putStrLn ("Compiling " ++ show fName)
  progText <- T.IO.readFile fName
  case parseModule fName progText of
    Left e  -> (putStrLn $ errorBundlePretty e) *> die ""
    Right r -> pure r

doProgText :: CmdLine -> FilePath -> T.Text -> IO ()
doProgText flags fName progText = do
 let preludes = if noPrelude flags then V.empty else preludeFNames
 autoImports <- mapM doImport preludes

 thisMod <- case parseModule fName progText of
    Left e  -> (putStrLn $ errorBundlePretty e) *> die ""
    Right r -> pure r
 let pTree = parseTree thisMod
 inclPaths <- getModulePaths searchPath $ modImports pTree
 customImports <- mapM doImport inclPaths
 let importList = autoImports V.++ customImports
     headers    = CU.mkHeader <$> importList
     llvmObjs   = V.toList $ stgToIRTop . core2stg <$> headers
 let core       = parseTree2Core headers thisMod
     judged     = judgeModule core
     stg        = core2stg judged
     llvmMod    = stgToIRTop stg
 if
  | isJust (outFile flags) -> LD.writeFile (fromJust $ outFile flags)
                                           $ llvmMod
  | emitSourceFile flags -> putStr =<< readFile fName
  | emitParseTree  flags -> print pTree
  | emitParseCore  flags -> putStrLn $ ppCoreModule core
  | emitCore       flags -> putStrLn $ ppCoreModule judged
  | emitStg        flags -> putStrLn $ show stg
  | emitLlvm       flags -> TL.IO.putStrLn $ ppllvm llvmMod
                            -- LD.dumpModule llvmMod
  | jit            flags -> LD.runJIT (optlevel flags) llvmObjs llvmMod
  | otherwise            -> putStrLn $ ppCoreModule judged

repl :: CmdLine -> IO ()
repl cmdLine = let
  doLine l = print =<< doProgText cmdLine "<stdin>" (T.pack l)
  loop     = getInputLine "'''" >>= \case
      Nothing -> pure ()
      Just l  -> lift (doLine l) *> loop
 in runInputT defaultSettings loop
