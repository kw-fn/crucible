-- | Command line interface to crucible-go

{-# Language OverloadedStrings #-}
{-# Language TypeFamilies #-}
{-# Language RankNTypes #-}
{-# Language PatternSynonyms #-}
{-# Language FlexibleContexts #-}
{-# LANGUAGE EmptyCase #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# Language ImplicitParams #-}
{-# Language PartialTypeSignatures #-}

{-# OPTIONS_GHC -fno-warn-missing-signatures #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}
{-# OPTIONS_GHC -fno-warn-unused-local-binds #-}
{-# OPTIONS_GHC -fno-warn-unused-matches #-}
{-# OPTIONS_GHC -fno-warn-unused-imports #-}

module Main where

import qualified Data.ByteString.Lazy as BS
import Data.String (fromString)
import qualified Data.Sequence as Seq
import qualified Data.Map as Map
import Control.Lens ((^.), (&), (%~))
import Control.Monad.ST
import Control.Monad
import Control.Monad.State.Strict

import Control.Exception (SomeException(..), displayException, catch)
import Data.List

import System.Console.GetOpt
import System.IO
import System.Environment (getProgName, getArgs)
import System.Exit (ExitCode(..), exitWith, exitFailure)
-- import System.FilePath(takeExtension,takeBaseName)
-- import System.FilePath(splitSearchPath)

import Data.Parameterized.Nonce (withIONonceGenerator)
import Data.Parameterized.Some (Some(..))
import qualified Data.Parameterized.Context as Ctx
import qualified Data.Parameterized.Map as MapF

-- crucible/crucible
import Lang.Crucible.Backend
import Lang.Crucible.Backend.Online
import Lang.Crucible.Types
import Lang.Crucible.CFG.Core (SomeCFG(..), AnyCFG(..), cfgArgTypes)
import Lang.Crucible.FunctionHandle

import Lang.Crucible.Simulator
import Lang.Crucible.Simulator.GlobalState
import Lang.Crucible.Simulator.PathSplitting
import Lang.Crucible.Simulator.RegValue
import Lang.Crucible.Simulator.RegMap

-- crucible/what4
import What4.ProgramLoc
import qualified What4.Config as W4
import qualified What4.Interface as W4
import qualified What4.Partial as W4

-- crux
import qualified Crux
import qualified Crux.Log     as Crux
import qualified Crux.Model   as Crux
import qualified Crux.Types   as Crux
import qualified Crux.Config.Common as Crux

-- Go
import Language.Go.Parser
import Lang.Crucible.Go.Simulate (setupCrucibleGoCrux)
import Lang.Crucible.Go.Types

-- executable
import System.Console.GetOpt

-- | A simulator context
type SimCtxt sym = SimContext (Crux.Model sym) sym Go

data GoOptions = GoOptions { } -- TODO: include function name to run?

defaultOptions :: GoOptions
defaultOptions = GoOptions { }

cruxGoConfig :: Crux.Config GoOptions
cruxGoConfig = Crux.Config
  { Crux.cfgFile = pure defaultOptions
  , Crux.cfgEnv = []
  }

simulateGo :: Crux.CruxOptions -> GoOptions -> Crux.SimulatorCallback
simulateGo copts opts = Crux.SimulatorCallback $ \sym _maybeOnline -> do
   let files = Crux.inputFiles copts
   let verbosity = Crux.simVerbose copts
   file <- case files of
             [f] -> return f
             _ -> fail "crux-go requires a single file name as an argument"

   -- Load the file
   json <- BS.readFile file
   let fwi = either error id $ parseMain json

   -- Initialize arguments to the function
   let regmap = RegMap Ctx.Empty

   -- Set up initial crucible execution state
   initSt <- let ?machineWordWidth = 32 in
     setupCrucibleGoCrux fwi verbosity sym Crux.emptyModel regmap

   return $ Crux.RunnableState $ initSt


-- | Entry point, parse command line options
main :: IO ()
main =
  Crux.loadOptions Crux.defaultOutputConfig "crux-go" "0.1" cruxGoConfig $
    \(cruxOpts, goOpts) ->
      exitWith =<< Crux.postprocessSimResult cruxOpts =<<
        Crux.runSimulator (cruxOpts { Crux.outDir = "report"
                                    , Crux.skipReport = False })
        (simulateGo cruxOpts goOpts)