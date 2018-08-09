{-# Language OverloadedStrings #-}
module Report where

import System.FilePath
import System.Directory(copyFile)
import Data.List(intercalate,partition)
import Data.Maybe(fromMaybe)
import Control.Exception(catch,SomeException(..))
import Control.Monad(when)

import Lang.Crucible.Simulator.SimError
import Lang.Crucible.Backend
import What4.ProgramLoc


import Options
import Model
import Goal
import Loops

generateReport :: Options -> Maybe ProvedGoals -> IO ()
generateReport opts xs =
  do when (takeExtension (inputFile opts) == ".c") (generateSource opts)
     writeFile (outDir opts </> "report.js")
        $ "var goals = " ++ renderJS (jsList (renderSideConds xs))
     let copy a = copyFile ("ui" </> a) (outDir opts </> a)
     copy "index.html"
     copy "jquery.min.js"



generateSource :: Options -> IO ()
generateSource opts =
  do src <- readFile (inputFile opts)
     writeFile (outDir opts </> "source.js")
        $ "var lines = " ++ show (lines src)
  `catch` \(SomeException {}) -> return ()


renderSideConds :: Maybe ProvedGoals -> [ JS ]
renderSideConds = maybe [] (go [])
  where
  flatBranch (Branch x y : more) = flatBranch (x : y : more)
  flatBranch (x : more)          = x : flatBranch more
  flatBranch []                  = []

  isGoal x = case x of
               Goal {} -> True
               _       -> False

  go path gs =
    case gs of
      AtLoc pl _ gs1  -> go ((jsLoc pl, pl) : path) gs1
      Branch g1 g2 ->
        let (now,rest) = partition isGoal (flatBranch [g1,g2])
        in concatMap (go path) now ++ concatMap (go path) rest

      Goal asmps conc triv proved ->
        let (ls,ps) = unzip (reverse path)
            ap      = map fst (annotateLoops ps)
            mkStep a l = jsObj [ "loop" ~> jsList (map jsNum a)
                               , "loc"  ~> l ]
            apath   = zipWith mkStep ap ls
        in [ jsSideCond apath asmps conc triv proved ]

jsLoc :: ProgramLoc -> JS
jsLoc x = case plSourceLoc x of
            SourcePos _ l _ -> jsStr (show l)
            _               -> jsNull



jsSideCond ::
  [ JS ] ->
  [(Maybe Int,AssumptionReason,String)] ->
  (SimError,String) ->
  Bool ->
  ProofResult ->
  JS
jsSideCond path asmps (conc,_) triv status =
  jsObj
  [ "proved"          ~> proved
  , "counter-example" ~> example
  , "goal"            ~> jsStr (simErrorReasonMsg (simErrorReason conc))
  , "location"        ~> jsLoc (simErrorLoc conc)
  , "assumptions"     ~> jsList (map mkAsmp asmps)
  , "trivial"         ~> jsBool triv
  , "path"            ~> jsList path
  ]
  where
  proved = case status of
             Proved -> jsBool True
             _      -> jsBool False

  example = case status of
             NotProved (Just m) -> JS (modelInJS m)
             _                  -> jsNull

  mkAsmp (lab,asmp,_) =
    jsObj [ "line" ~> jsLoc (assumptionLoc asmp)
          , "step" ~> jsMaybe ((path !!) <$> lab)
          ]

--------------------------------------------------------------------------------
newtype JS = JS { renderJS :: String }

jsList :: [JS] -> JS
jsList xs = JS $ "[" ++ intercalate "," [ x | JS x <- xs ] ++ "]"

infix 1 ~>

(~>) :: a -> b -> (a,b)
(~>) = (,)

jsObj :: [(String,JS)] -> JS
jsObj xs =
  JS $ "{" ++ intercalate "," [ show x ++ ": " ++ v | (x,JS v) <- xs ] ++ "}"

jsBool :: Bool -> JS
jsBool b = JS (if b then "true" else "false")

jsStr :: String -> JS
jsStr = JS . show

jsNull :: JS
jsNull = JS "null"

jsMaybe :: Maybe JS -> JS
jsMaybe = fromMaybe jsNull

jsNum :: Show a => a -> JS
jsNum = JS . show


