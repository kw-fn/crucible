{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE ImplicitParams #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

import           Control.Lens ( (^.), view, to, use )
import           Control.Monad ( when )
import           Control.Monad.IO.Class ( liftIO )
import           Data.IORef
import qualified Data.List as L
import qualified Data.Map as Map
import           Data.Maybe ( isJust )
import qualified Prettyprinter as PP
import           System.Directory ( createDirectoryIfMissing )
import           System.Exit
import           System.FilePath ( (</>) )
import           Test.Tasty
import           Test.Tasty.Hspec

import qualified Text.LLVM as LLVMPr

import           Data.Parameterized.Some
import qualified What4.Expr as W4
import qualified What4.Expr.Builder as WEB

import qualified Lang.Crucible.Analysis.Postdom as CrPostDom
import           Lang.Crucible.Backend
import qualified Lang.Crucible.CFG.Core as CrCFG
import           Lang.Crucible.FunctionHandle
import           Lang.Crucible.Simulator
import           Lang.Crucible.Types

import qualified Lang.Crucible.LLVM as CruLLVM
import qualified Lang.Crucible.LLVM.Globals as CruLLVMGlob
import qualified Lang.Crucible.LLVM.MemModel as CruLLVMMem
import qualified Lang.Crucible.LLVM.Translation as CruLLVMTrans
import qualified Lang.Crucible.LLVM.Errors as CruLLVMErr

import qualified Crux
import qualified Crux.Model as CM
import qualified Crux.Types as CT

import qualified Crux.LLVM.Config as CLCfg
import qualified Crux.LLVM.Compile as CLCmp
import qualified Crux.LLVM.Simulate as CLSim
import qualified Crux.LLVM.Overrides as CLO

import           Lang.Crucible.Combo

----------------------------------------------------------------------

data ComboOptions = ComboOptions

defaultComboOptions :: ComboOptions
defaultComboOptions = ComboOptions

cruxComboConfig :: Crux.Config ComboOptions
cruxComboConfig = Crux.Config
                  {
                    Crux.cfgFile = pure defaultComboOptions
                  , Crux.cfgEnv = []
                  , Crux.cfgCmdLineFlag = []
                  }

----------------------------------------------------------------------

comboIntrinsicTypes :: IsSymInterface sym => IntrinsicTypes sym
comboIntrinsicTypes = undefined

type Inputs = [ (ExtensionType, ExtensionData) ]
type ExtensionType = String
type ExtensionData = String

processComboOpts :: (Crux.CruxOptions, ComboOptions) -> IO (Crux.CruxOptions, ComboOptions)
processComboOpts (cruxOpts, comboOpts) = do
     let cruxOpts2 = if Crux.outDir cruxOpts == ""
                       then cruxOpts { Crux.outDir = "test_results" }
                       else cruxOpts
         odir      = Crux.outDir cruxOpts2
     createDirectoryIfMissing True odir
     return (cruxOpts2, comboOpts)

regFromTrans :: (CLO.ArchOk arch, IsSymInterface sym, CruLLVMMem.HasLLVMAnn sym, Crux.Logs) =>
                CruLLVMTrans.ModuleTranslation arch ->
                (LLVMPr.Module, Some CruLLVMTrans.ModuleTranslation) ->
                CT.OverM CT.Model sym (CruLLVM.LLVM arch) ()
regFromTrans primary_transl (modl, Some transl) =
  let modFile = maybe "??" (show . LLVMPr.umValues) $
                L.find ((1 ==) . LLVMPr.umIndex) (LLVMPr.modUnnamedMd modl)
      regForeignFn (decl, CrCFG.AnyCFG cfg) = do  -- KWQ: AnyCFG parameterized over ext!
        let h = CrCFG.cfgHandle cfg
            s = UseCFG cfg (CrPostDom.postdomInfo cfg)
        binds <- use (stateContext . functionBindings)
        when (isJust $ lookupHandleMap h binds) $
          liftIO $ Crux.sayWarn "CruxCombo" ("Foreign function handle registered twice: " ++ show (handleName h))
        bindFnHandle h s
  in
  case testEquality primary_transl transl of
    Just Refl -> do liftIO $ putStrLn $ "Registering functions in primary module " <> show modFile
                    CLSim.registerFunctions modl transl
                    liftIO $ putStrLn $ "## registered"
                    liftIO $ putStrLn ""
    Nothing ->
      case testEquality
           (primary_transl ^. CruLLVMTrans.transContext . to CruLLVMTrans.llvmArch)
           (transl         ^. CruLLVMTrans.transContext . to CruLLVMTrans.llvmArch) of
        Just Refl -> do liftIO $ putStrLn ""
                        liftIO $ putStrLn $ replicate 40 '='
                        liftIO $ putStrLn $ "Registering 'foreign' functions in " <> show modFile
                        mapM_ regForeignFn$ Map.elems $ CruLLVMTrans.cfgMap transl
                        liftIO $ putStrLn "## Registration completed"
        Nothing -> error "Cannot call between modules with different architectures"

setupComboState :: IsSymInterface sym =>
                   sym ~ WEB.ExprBuilder t st fs =>
                   CLCfg.LLVMOptions ->
                   [FilePath] ->
                   sym ->
                   Maybe (Crux.SomeOnlineSolver sym) ->
                   IO (Crux.RunnableState sym,
                       Maybe (W4.GroundEvalFn t) -> CT.LPred sym SimError -> IO (PP.Doc ann))
setupComboState llvmOpts llvmBCFiles sym mb'Online = do
  -- replication of crux-llvm simulateLLVMFile, enhanced to support multiple modules --v
  let ?outputConfig = Crux.defaultOutputConfig
  let ?laxArith = CLCfg.laxArithmetic llvmOpts
  halloc <- newHandleAllocator
  let prepLLVMFromBC bcFile = do mod <- CLSim.parseLLVM bcFile
                                 trans <- CruLLVMTrans.translateModule halloc mod
                                 return (mod, trans)
  primary <- prepLLVMFromBC $ head llvmBCFiles
  allModsAndSomeTrans <- (primary :) <$> mapM prepLLVMFromBC (tail llvmBCFiles)
  Some trans <- return $ snd $ primary

  -- n.b. This is the LLVMContext, which also contains a memory
  -- declaration and the nonce generator.  It's generally not possible
  -- to combine modules obtained from translateModule.
  let llvmCtxt = trans ^. CruLLVMTrans.transContext

  CruLLVMTrans.llvmPtrWidth llvmCtxt $ \ptrW ->
    CruLLVMMem.withPtrWidth ptrW $
    do liftIO $ Crux.say "CruxCombo" $ unwords ["Using pointer width:", show ptrW]
       bbMapRef <- newIORef (Map.empty :: CruLLVMMem.LLVMAnnMap sym)
       let ?lc = llvmCtxt ^. CruLLVMTrans.llvmTypeCtx
       let ?recordLLVMAnnotation = \an bb -> modifyIORef bbMapRef (Map.insert an bb) in
         do
           let simctx = (CLSim.setupSimCtxt halloc sym (CLCfg.memOpts llvmOpts) llvmCtxt)
                        { printHandle = view Crux.outputHandle ?outputConfig }
           mem <- CruLLVMGlob.populateAllGlobals sym (CruLLVMTrans.globalInitMap trans)
                  =<< CruLLVMGlob.initializeAllMemory sym llvmCtxt (fst $ head allModsAndSomeTrans)
           let globalSt8 = CruLLVM.llvmGlobals llvmCtxt mem
           let initSt8 = InitialState simctx globalSt8 defaultAbortHandler UnitRepr $
                         runOverrideSim UnitRepr $
                         do mapM (regFromTrans trans) allModsAndSomeTrans
                            CLSim.checkFun (CLCfg.entryPoint llvmOpts) (CruLLVMTrans.cfgMap trans)
           let detailLimit = 10
           let explainFailure evalFn gl =
                 do bb <- readIORef bbMapRef
                    ex <- CruLLVMMem.explainCex sym bb evalFn >>= \f -> f (gl ^. labeledPred)
                    let details = case ex of
                                    CruLLVMMem.NoExplanation -> mempty
                                    CruLLVMMem.DisjOfFailures xs ->
                                      case map CruLLVMErr.ppBB xs of
                                        []  -> mempty
                                        [x] -> PP.indent 2 x
                                        xs' | length xs' <= detailLimit
                                              -> "All of the following conditions failed:" <> PP.line <> PP.indent 2 (PP.vcat xs')
                                            | otherwise
                                              -> "All of the following conditions failed (and other conditions have been elided to reduce output): "
                                                 <> PP.line <> PP.indent 2 (PP.vcat (take detailLimit xs'))

                    return $ PP.vcat [ ppSimError (gl^.labeledPredMsg), details ]

           return (Crux.RunnableState initSt8, explainFailure)


simulateCombo :: Crux.CruxOptions -> ComboOptions -> IO Crux.SimulatorCallback
simulateCombo cruxOpts _comboOpts =
  do let ifiles = [ ("main.bc", "test/samples/ex3/main.c") -- first file must have main entrypoint
                  , ("helper.bc", "test/samples/ex3/helper.c")
                  ]
     let llvmOptions = CLCfg.LLVMOptions { CLCfg.clangBin = "/nix/store/b04iyp70fff54fv8s44d0q8r1072qmyj-clang-wrapper-7.1.0/bin/clang"
                                         , CLCfg.linkBin = "/nix/store/yqqyb6mrpm8hbb1dqagl4k4zp5d9nysq-llvm-7.1.0/bin/llvm-link"
                                         , CLCfg.clangOpts = []
                                         , CLCfg.libDir = "/home/kquick/work/Polyglot/crucible/crux-llvm/c-src"
                                         , CLCfg.incDirs = []
                                         , CLCfg.ubSanitizers = []
                                         , CLCfg.memOpts =
                                             CruLLVMMem.MemOptions
                                             {
                                               CruLLVMMem.laxPointerOrdering = False
                                             , CruLLVMMem.laxConstantEquality = False
                                             }
                                         , CLCfg.laxArithmetic = False
                                         , CLCfg.entryPoint = "main"  -- only valid for the first one...
                                         , CLCfg.lazyCompile = False
                                         , CLCfg.optLevel = 1
                                         }

     let llvmPrep :: (FilePath, FilePath) -> IO FilePath
         llvmPrep (o,i) = let ?outputConfig = Crux.defaultOutputConfig in
                            do let ofp = ("testout" </> o)
                               CLCmp.genBitCodeFiles [i] ofp llvmOptions
                               -- CLSim.parseLLVM ofp
                               return ofp
     llvmModules <- mapM llvmPrep ifiles :: IO [FilePath]

     -- return $ CLSim.simulateLLVMFile (head llvmModules) llvmOptions
     return $ Crux.SimulatorCallback $ setupComboState llvmOptions llvmModules

     -- setupComboState
     -- let ?outputconfig = Crux.defaultOutputConfig in
     -- initSt <- setupComboState sym llvmModules
     -- return (Crux.RunnableState initSt, \_ _ -> return mempty)


main :: IO ()
main = do tests <- mkTests
          defaultMain $ testGroup "Combo tests" tests

mkTests :: IO [TestTree]
mkTests =
  sequence [
    testSpec "existence" $ do
        describe "can instantiate" $ do
          it "exists" $ do
            c <- return ComboPointerType
            putStrLn "ok"
            return ()
        describe "can simulate" $ do
          it "simulates main and helper" $ do
            Crux.loadOptions Crux.defaultOutputConfig "crux-combo" "0.1" cruxComboConfig
              \opts ->
                do (cruxOpts, comboOpts) <- processComboOpts opts
                   initCB <- simulateCombo cruxOpts comboOpts
                   res <- Crux.runSimulator cruxOpts initCB
                   rval <- Crux.postprocessSimResult cruxOpts res
                   rval `shouldBe` ExitSuccess
  ]
