-----------------------------------------------------------------------
-- |
-- Module           : Lang.Crucible.Simulator.EvalStmt
-- Description      : Provides functions for evaluating statements.
-- Copyright        : (c) Galois, Inc 2013-2018
-- License          : BSD3
-- Maintainer       : Joe Hendrix <jhendrix@galois.com>
-- Stability        : provisional
--
-- This module provides functions for evaluating Crucible statements.
------------------------------------------------------------------------
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE EmptyCase #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE PatternGuards #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}
module Lang.Crucible.Simulator.EvalStmt
  ( -- * High-level evaluation
    singleStepCrucible
  , executeCrucible
  , ExecutionFeature(..)
  , GenericExecutionFeature(..)
  , genericToExecutionFeature
  , timeoutFeature

    -- * Lower-level evaluation operations
  , dispatchExecState
  , advanceCrucibleState
  , evalReg
  , evalReg'
  , evalExpr
  , evalArgs
  , evalJumpTarget
  , evalSwitchTarget
  , stepStmt
  , stepTerm
  , stepBasicBlock
  ) where

import qualified Control.Exception as Ex
import           Control.Lens
import           Control.Monad.Reader
import           Data.Maybe (fromMaybe)
import qualified Data.Parameterized.Context as Ctx
import           Data.Parameterized.TraversableFC
import qualified Data.Text as Text
import           Data.Time.Clock
import           System.IO
import           System.IO.Error as Ex
import           Text.PrettyPrint.ANSI.Leijen hiding ((<$>))

import           What4.Config
import           What4.Interface
import           What4.Partial
import           What4.ProgramLoc
import           What4.Symbol (emptySymbol)
import           What4.Utils.MonadST

import           Lang.Crucible.Backend
import           Lang.Crucible.CFG.Core
import           Lang.Crucible.CFG.Extension
import           Lang.Crucible.FunctionHandle
import           Lang.Crucible.Simulator.CallFrame
import           Lang.Crucible.Simulator.Evaluation
import           Lang.Crucible.Simulator.ExecutionTree
import           Lang.Crucible.Simulator.Intrinsics (IntrinsicTypes)
import           Lang.Crucible.Simulator.GlobalState
import           Lang.Crucible.Simulator.Operations
import           Lang.Crucible.Simulator.RegMap
import           Lang.Crucible.Simulator.SimError
import           Lang.Crucible.Utils.MuxTree


-- | Retrieve the value of a register
evalReg ::
  Monad m =>
  Reg ctx tp ->
  ReaderT (CrucibleState p sym ext rtp blocks r ctx) m (RegValue sym tp)
evalReg r = (`regVal` r) <$> view (stateCrucibleFrame.frameRegs)

-- | Retrieve the value of a register, returning a 'RegEntry'
evalReg' ::
  Monad m =>
  Reg ctx tp ->
  ReaderT (CrucibleState p sym ext rtp blocks r ctx) m (RegEntry sym tp)
evalReg' r = (`regVal'` r) <$> view (stateCrucibleFrame.frameRegs)


evalLogFn ::
  Int {- current verbosity -} ->
  CrucibleState p sym ext rtp blocks r ctx ->
  Int {- verbosity level of the message -} ->
  String ->
  IO ()
evalLogFn verb s n msg = do
  let h = s^.stateContext.to printHandle
  if verb >= n then
      do hPutStr h msg
         hFlush h
  else
      return ()

-- | Evaluate an expression.
evalExpr :: forall p sym ext ctx tp rtp blocks r.
  (IsSymInterface sym, IsSyntaxExtension ext) =>
  Int {- ^ current verbosity -} ->
  Expr ext ctx tp ->
  ReaderT (CrucibleState p sym ext rtp blocks r ctx) IO (RegValue sym tp)
evalExpr verb (App a) = ReaderT $ \s ->
  do let iteFns = s^.stateIntrinsicTypes
     let sym = s^.stateSymInterface
     let logFn = evalLogFn verb s
     r <- evalApp sym iteFns logFn
            (extensionEval (extensionImpl (s^.stateContext)) sym iteFns logFn)
            (\r -> runReaderT (evalReg r) s)
            a
     return $! r

evalArgs' :: forall sym ctx args.
  RegMap sym ctx ->
  Ctx.Assignment (Reg ctx) args ->
  RegMap sym args
evalArgs' m0 args = RegMap (fmapFC (getEntry m0) args)
  where getEntry :: RegMap sym ctx -> Reg ctx tp -> RegEntry sym tp
        getEntry (RegMap m) r = m Ctx.! regIndex r
{-# NOINLINE evalArgs' #-}

-- | Evaluate the actual arguments for a function call or block transfer
evalArgs ::
  Monad m =>
  Ctx.Assignment (Reg ctx) args ->
  ReaderT (CrucibleState p sym ext rtp blocks r ctx) m (RegMap sym args)
evalArgs args = ReaderT $ \s -> return $! evalArgs' (s^.stateCrucibleFrame.frameRegs) args
{-# INLINE evalArgs #-}

-- | Resolve the arguments for a jump
evalJumpTarget ::
  (IsSymInterface sym, Monad m) =>
  JumpTarget blocks ctx {- ^  Jump target to evaluate -} ->
  ReaderT (CrucibleState p sym ext rtp blocks r ctx) m (ResolvedJump sym blocks)
evalJumpTarget (JumpTarget tgt _ a) = ResolvedJump tgt <$> evalArgs a

-- | Resolve the arguments for a switch target
evalSwitchTarget ::
  (IsSymInterface sym, Monad m) =>
  SwitchTarget blocks ctx tp {- ^ Switch target to evaluate -} ->
  RegEntry sym tp {- ^ Value inside the variant -}  ->
  ReaderT (CrucibleState p sym ext rtp blocks r ctx) m (ResolvedJump sym blocks)
evalSwitchTarget (SwitchTarget tgt _tp a) x =
  do xs <- evalArgs a
     return (ResolvedJump tgt (assignReg' x xs))

alterRef ::
  IsSymInterface sym =>
  sym ->
  IntrinsicTypes sym ->
  TypeRepr tp ->
  MuxTree sym (RefCell tp) ->
  PartExpr (Pred sym) (RegValue sym tp) ->
  SymGlobalState sym ->
  IO (SymGlobalState sym)
alterRef sym iTypes tpr rs newv globs = foldM upd globs (viewMuxTree rs)
  where
  f p a b = liftIO $ muxRegForType sym iTypes tpr p a b

  upd gs (r,p) =
    do let oldv = lookupRef r globs
       z <- mergePartial sym f p newv oldv
       return (gs & updateRef r z)

readRef ::
  IsSymInterface sym =>
  sym ->
  IntrinsicTypes sym ->
  TypeRepr tp ->
  MuxTree sym (RefCell tp) ->
  SymGlobalState sym ->
  IO (RegValue sym tp)
readRef sym iTypes tpr rs globs =
  do let vs = map (\(r,p) -> (p,lookupRef r globs)) (viewMuxTree rs)
     let f p a b = liftIO $ muxRegForType sym iTypes tpr p a b
     pv <- mergePartials sym f vs
     let msg = ReadBeforeWriteSimError "Attempted to read uninitialized reference cell"
     readPartExpr sym pv msg


-- | Evaluation operation for evaluating a single straight-line
--   statement of the Crucible evaluator.
--
--   This is allowed to throw user execeptions or SimError.
stepStmt :: forall p sym ext rtp blocks r ctx ctx'.
  (IsSymInterface sym, IsSyntaxExtension ext) =>
  Int {- ^ Current verbosity -} ->
  Stmt ext ctx ctx' {- ^ Statement to evaluate -} ->
  StmtSeq ext blocks r ctx' {- ^ Remaning statements in the block -} ->
  ExecCont p sym ext rtp (CrucibleLang blocks r) ('Just ctx)
stepStmt verb stmt rest =
  do ctx <- view stateContext
     let sym = ctx^.ctxSymInterface
     let iTypes = ctxIntrinsicTypes ctx
     globals <- view (stateTree.actFrame.gpGlobals)

     let continueWith :: forall rtp' blocks' r' c f a.
           (SimState p sym ext rtp' f a -> SimState p sym ext rtp' (CrucibleLang blocks' r') ('Just c)) ->
           ExecCont p sym ext rtp' f a
         continueWith f = withReaderT f (checkConsTerm verb)

     case stmt of
       NewRefCell tpr x ->
         do let halloc = simHandleAllocator ctx
            v <- evalReg x
            r <- liftST (freshRefCell halloc tpr)
            continueWith $
               (stateTree . actFrame . gpGlobals %~ insertRef sym r v) .
               (stateCrucibleFrame %~ extendFrame (ReferenceRepr tpr) (toMuxTree sym r) rest)

       NewEmptyRefCell tpr ->
         do let halloc = simHandleAllocator ctx
            r <- liftST (freshRefCell halloc tpr)
            continueWith $
              stateCrucibleFrame %~ extendFrame (ReferenceRepr tpr) (toMuxTree sym r) rest

       ReadRefCell x ->
         do RegEntry (ReferenceRepr tpr) rs <- evalReg' x
            v <- liftIO $ readRef sym iTypes tpr rs globals
            continueWith $
              stateCrucibleFrame %~ extendFrame tpr v rest

       WriteRefCell x y ->
         do RegEntry (ReferenceRepr tpr) rs <- evalReg' x
            newv <- justPartExpr sym <$> evalReg y
            globals' <- liftIO $ alterRef sym iTypes tpr rs newv globals
            continueWith $
              (stateTree . actFrame . gpGlobals .~ globals') .
              (stateCrucibleFrame  . frameStmts .~ rest)

       DropRefCell x ->
         do RegEntry (ReferenceRepr tpr) rs <- evalReg' x
            globals' <- liftIO $ alterRef sym iTypes tpr rs Unassigned globals
            continueWith $
              (stateTree . actFrame . gpGlobals .~ globals') .
              (stateCrucibleFrame  . frameStmts .~ rest)

       ReadGlobal global_var -> do
         case lookupGlobal global_var globals of
           Nothing ->
             do let msg = ReadBeforeWriteSimError $ "Attempt to read undefined global " ++ show global_var
                liftIO $ addFailedAssertion sym msg
           Just v ->
             continueWith $
               (stateCrucibleFrame %~ extendFrame (globalType global_var) v rest)

       WriteGlobal global_var local_reg ->
         do v <- evalReg local_reg
            continueWith $
              (stateTree . actFrame . gpGlobals %~ insertGlobal global_var v) .
              (stateCrucibleFrame . frameStmts .~ rest)

       FreshConstant bt mnm ->
         do let nm = fromMaybe emptySymbol mnm
            v <- liftIO $ freshConstant sym nm bt
            continueWith $ stateCrucibleFrame %~ extendFrame (baseToType bt) v rest

       SetReg tp e ->
         do v <- evalExpr verb e
            continueWith $ stateCrucibleFrame %~ extendFrame tp v rest

       ExtendAssign estmt -> do
         do let tp = appType estmt
            estmt' <- traverseFC evalReg' estmt
            ReaderT $ \s ->
              do (v,s') <- liftIO $ extensionExec (extensionImpl ctx) estmt' s
                 runReaderT
                   (continueWith $ stateCrucibleFrame %~ extendFrame tp v rest)
                   s'

       CallHandle ret_type fnExpr _types arg_exprs ->
         do hndl <- evalReg fnExpr
            args <- evalArgs arg_exprs
            callFunction hndl args (ReturnToCrucible ret_type rest)

       Print e ->
         do msg <- evalReg e
            let msg' = case asString msg of
                         Just txt -> Text.unpack txt
                         _ -> show (printSymExpr msg)
            liftIO $ do
              let h = printHandle ctx
              hPutStr h msg'
              hFlush h
            continueWith (stateCrucibleFrame  . frameStmts .~ rest)

       Assert c_expr msg_expr ->
         do c <- evalReg c_expr
            msg <- evalReg msg_expr
            let msg' = case asString msg of
                         Just txt -> Text.unpack txt
                         _ -> show (printSymExpr msg)
            liftIO $ assert sym c (AssertFailureSimError msg')
            continueWith (stateCrucibleFrame  . frameStmts .~ rest)

       Assume c_expr msg_expr ->
         do c <- evalReg c_expr
            msg <- evalReg msg_expr
            let msg' = case asString msg of
                         Just txt -> Text.unpack txt
                         _ -> show (printSymExpr msg)
            liftIO $
              do loc <- getCurrentProgramLoc sym
                 addAssumption sym (LabeledPred c (AssumptionReason loc msg'))
            continueWith (stateCrucibleFrame  . frameStmts .~ rest)


{-# INLINABLE stepTerm #-}

-- | Evaluation operation for evaluating a single block-terminator
--   statement of the Crucible evaluator.
--
--   This is allowed to throw user execeptions or SimError.
stepTerm :: forall p sym ext rtp blocks r ctx.
  (IsSymInterface sym, IsSyntaxExtension ext) =>
  Int {- ^ Verbosity -} ->
  TermStmt blocks r ctx {- ^ Terminating statement to evaluate -} ->
  ExecCont p sym ext rtp (CrucibleLang blocks r) ('Just ctx)

stepTerm _ (Jump tgt) =
  jumpToBlock =<< evalJumpTarget tgt

stepTerm _ (Return arg) =
  returnValue =<< evalReg' arg

stepTerm _ (Br c x y) =
  do x_jump <- evalJumpTarget x
     y_jump <- evalJumpTarget y
     p <- evalReg c
     conditionalBranch p x_jump y_jump

stepTerm _ (MaybeBranch tp e j n) =
  do evalReg e >>= \case
       Unassigned -> jumpToBlock =<< evalJumpTarget n
       PE p v ->
         do j_jump <- evalSwitchTarget j (RegEntry tp v)
            n_jump <- evalJumpTarget n
            conditionalBranch p j_jump n_jump

stepTerm _ (VariantElim ctx e cases) =
  do vs <- evalReg e
     jmps <- ctx & Ctx.traverseAndCollect (\i tp ->
                case vs Ctx.! i of
                  VB Unassigned ->
                    return []
                  VB (PE p v) ->
                    do jmp <- evalSwitchTarget (cases Ctx.! i) (RegEntry tp v)
                       return [(p,jmp)])

     variantCases jmps

-- When we make a tail call, we first try to unwind our calling context
-- and replace the currently-active frame with the frame of the new called
-- function.  However, this is only successful if there are no pending
-- symbolic merges.
--
-- If there _are_ pending merges we instead treat the tail call as normal
-- call-then-return sequence, pushing a new call frame on the top of our
-- current context (rather than replacing it).  The TailReturnToCrucible
-- return handler tells the simulator to immediately invoke another return
-- in the caller, which is still present on the stack in this scenerio.
stepTerm _ (TailCall fnExpr _types arg_exprs) =
  do cl   <- evalReg fnExpr
     args <- evalArgs arg_exprs
     ctx <- view (stateTree.actContext)
     case unwindContext ctx of
       Just vfv -> tailCallFunction cl args vfv
       Nothing  -> callFunction cl args TailReturnToCrucible

stepTerm _ (ErrorStmt msg) =
  do msg' <- evalReg msg
     sym <- view stateSymInterface
     liftIO $ case asString msg' of
       Just txt -> addFailedAssertion sym
                      $ GenericSimError $ Text.unpack txt
       Nothing  -> addFailedAssertion sym
                      $ GenericSimError $ show (printSymExpr msg')


-- | Checks whether the StmtSeq is a Cons or a Term,
--   to give callers another chance to jump into Crucible's control flow
checkConsTerm ::
  (IsSymInterface sym, IsSyntaxExtension ext) =>
  Int {- ^ Current verbosity -} ->
  ExecCont p sym ext rtp (CrucibleLang blocks r) ('Just ctx)
checkConsTerm verb =
     do cf <- view stateCrucibleFrame

        case cf^.frameStmts of
          ConsStmt _ _ _ -> stepBasicBlock verb
          TermStmt _ _ -> continue (RunBlockEnd (cf^.frameBlockID))

-- | Main evaluation operation for running a single step of
--   basic block evalaution.
--
--   This is allowed to throw user execeptions or SimError.
stepBasicBlock ::
  (IsSymInterface sym, IsSyntaxExtension ext) =>
  Int {- ^ Current verbosity -} ->
  ExecCont p sym ext rtp (CrucibleLang blocks r) ('Just ctx)
stepBasicBlock verb =
  do ctx <- view stateContext
     let sym = ctx^.ctxSymInterface
     let h = printHandle ctx
     cf <- view stateCrucibleFrame

     case cf^.frameStmts of
       ConsStmt pl stmt rest ->
         do liftIO $
              do setCurrentProgramLoc sym pl
                 let sz = regMapSize (cf^.frameRegs)
                 when (verb >= 4) $ ppStmtAndLoc h (frameHandle cf) pl (ppStmt sz stmt)
            stepStmt verb stmt rest

       TermStmt pl termStmt -> do
         do liftIO $
              do setCurrentProgramLoc sym pl
                 when (verb >= 4) $ ppStmtAndLoc h (frameHandle cf) pl (pretty termStmt)
            stepTerm verb termStmt

ppStmtAndLoc :: Handle -> SomeHandle -> ProgramLoc -> Doc -> IO ()
ppStmtAndLoc h sh pl stmt = do
  hPrint h $
    text (show sh) <> char ':' <$$>
    indent 2 (stmt <+> text "%" <+> ppNoFileName (plSourceLoc pl))
  hFlush h



----------------------------------------------------------------------
-- ExecState manipulations


-- | Given an @ExecState@, examine it and either enter the continuation
--   for final results, or construct the appropriate @ExecCont@ for
--   continuing the computation and enter the provided intermediate continuation.
dispatchExecState ::
  (IsSymInterface sym, IsSyntaxExtension ext) =>
  IO Int {- ^ Action to query the current verbosity -} ->
  ExecState p sym ext rtp {- ^ Current execution state of the simulator -} ->
  (ExecResult p sym ext rtp -> IO z) {- ^ Final continuation for results -} ->
  (forall f a. ExecCont p sym ext rtp f a -> SimState p sym ext rtp f a -> IO z)
    {- ^ Intermediate continuation for running states -} ->
  IO z
dispatchExecState getVerb exst kresult k =
  case exst of
    ResultState res ->
      kresult res

    InitialState simctx globals ah cont ->
      let st = initSimState simctx globals ah in
      k cont st

    AbortState rsn st ->
      let (AH handler) = st^.abortHandler in
      k (handler rsn) st

    OverrideState ovr st ->
      k (overrideHandler ovr) st

    SymbolicBranchState p a_frame o_frame tgt st ->
      k (performIntraFrameSplit p a_frame o_frame tgt) st

    ControlTransferState resumption st ->
      k (performControlTransfer resumption) st

    BranchMergeState tgt st ->
      k (performIntraFrameMerge tgt) st

    UnwindCallState vfv ar st ->
      k (resumeValueFromValueAbort vfv ar) st

    CallState retHandler frm st ->
      k (performFunctionCall retHandler frm) st

    TailCallState vfv frm st ->
      k (performTailCall vfv frm) st

    ReturnState fnm vfv ret st ->
      k (performReturn fnm vfv ret) st

    RunningState _runTgt st ->
      do v <- getVerb
         k (stepBasicBlock v) st
{-# INLINE dispatchExecState #-}


-- | Run the given @ExecCont@ on the given @SimState@,
--   being careful to catch any simulator abort exceptions
--   that are thrown and dispatch them to the abort handler.
advanceCrucibleState ::
  (IsSymInterface sym, IsSyntaxExtension ext) =>
  ExecCont p sym ext rtp f a ->
  SimState p sym ext rtp f a ->
  IO (ExecState p sym ext rtp)
advanceCrucibleState m st =
     Ex.catches (runReaderT m st)
                [ Ex.Handler $ \(e::AbortExecReason) ->
                    runAbortHandler e st
                , Ex.Handler $ \(e::Ex.IOException) ->
                    if Ex.isUserError e then
                      runGenericErrorHandler (Ex.ioeGetErrorString e) st
                    else
                      Ex.throwIO e
                ]


-- | Run a single step of the Crucible symbolic simulator.
singleStepCrucible ::
  (IsSymInterface sym, IsSyntaxExtension ext) =>
  Int {- ^ Current verbosity -} ->
  ExecState p sym ext rtp ->
  IO (ExecState p sym ext rtp)
singleStepCrucible verb exst =
  dispatchExecState
    (return verb)
    exst
    (return . ResultState)
    advanceCrucibleState



-- | An execution feature represents a computation that is allowed to intercept
--   the processing of execution states to perform additional processing at
--   each intermediate state.  The next state of processing is provided as
--   a continuation, which allows us to chain execution features together
--   and provides the possibility of short-cutting control flow, etc.
newtype ExecutionFeature p sym ext rtp =
  ExecutionFeature
  { runExecutionFeature :: forall z.
      (ExecResult p sym ext rtp -> IO z, ExecState p sym ext rtp -> IO z) ->
      (ExecResult p sym ext rtp -> IO z, ExecState p sym ext rtp -> IO z)
  }

-- | A generic execution feature is an execution feature that is
--   agnostic to the exeuction environmemnt, and is therefore
--   polymorphic over the @p@, @sym@, @ext@ and @rtp@ variables.
newtype GenericExecutionFeature =
  GenericExecutionFeature
  { runGenericExecutionFeature :: forall p sym ext rtp.
      (IsSymInterface sym, IsSyntaxExtension ext) =>
      forall z.
        (ExecResult p sym ext rtp -> IO z, ExecState p sym ext rtp -> IO z) ->
        (ExecResult p sym ext rtp -> IO z, ExecState p sym ext rtp -> IO z)
  }

genericToExecutionFeature ::
  (IsSymInterface sym, IsSyntaxExtension ext) =>
  GenericExecutionFeature -> ExecutionFeature p sym ext rtp
genericToExecutionFeature (GenericExecutionFeature f) = ExecutionFeature f


-- | Given a 'SimState' and an execution continuation,
--   apply the continuation and execute the resulting
--   computation until completion.
--
--   This function is responsible for catching
--   'AbortExecReason' exceptions and 'UserError'
--   exceptions and invoking the 'errorHandler'
--   contained in the state.
executeCrucible :: forall p sym ext rtp.
  (IsSymInterface sym, IsSyntaxExtension ext) =>
  [ ExecutionFeature p sym ext rtp ] {- ^ Execution features to install -} ->
  ExecState p sym ext rtp   {- ^ Execution state to begin executing -} ->
  IO (ExecResult p sym ext rtp)
executeCrucible execFeatures exst0 =
  do let cfg = getConfiguration . view ctxSymInterface . execStateContext $ exst0
     verbOpt <- getOptionSetting verbosity cfg

     let loop exst =
           dispatchExecState
             (fromInteger <$> getOpt verbOpt)
             exst
             kresult
             (\m st -> knext =<< advanceCrucibleState m st)

         (kresult, knext) = foldr runExecutionFeature (return, loop) execFeatures

     knext exst0


-- | This feature will terminate the execution of a crucible simulator
--   with a @TimeoutResult@ after a given interval of wall-clock time
--   has elapsed.
timeoutFeature ::
  NominalDiffTime ->
  IO GenericExecutionFeature
timeoutFeature timeout =
  do startTime <- getCurrentTime
     let deadline = addUTCTime timeout startTime
     return $ GenericExecutionFeature $ \(kresult, knext) ->
       ( kresult
       , \exst ->
           do now <- getCurrentTime
              if deadline >= now then
                knext exst
              else
                kresult (TimeoutResult exst)
       )
