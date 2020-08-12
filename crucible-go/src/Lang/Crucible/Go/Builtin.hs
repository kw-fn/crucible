{-|
Module      : Lang.Crucible.Go.Builtin
Description : Translation of Go built-in functions.
Maintainer  : abagnall@galois.com
Stability   : experimental

Builtins in Go are similar to lisp special forms. They can only appear
in call expressions, can't be reified into first-class function
values, and may (in the case of 'new' and 'make') take types as
arguments.
-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
module Lang.Crucible.Go.Builtin (translateBuiltin) where

import           Control.Monad.State

import           Data.Functor.Product
import           Data.Text as T hiding (foldl, length, zip)

import           Data.Parameterized.Context as Ctx
import           Data.Parameterized.NatRepr
import           Data.Parameterized.Some (Some(..))

import qualified Lang.Crucible.CFG.Expr as C
import qualified Lang.Crucible.CFG.Generator as Gen
import           Lang.Crucible.Types

import           What4.Utils.StringLiteral

import           Language.Go.AST
import           Language.Go.Rec
import           Language.Go.Types
import           Lang.Crucible.Go.Encodings
import           Lang.Crucible.Go.TransUtil
import           Lang.Crucible.Go.Types

translateBuiltin :: Show a
                 => Ident
                 -> Ident
                 -> [Product (Node a) TranslateM Expr]
                 -> TranslateM' (Translated Expr)
translateBuiltin _qual ident@(Ident _k name) args = do
  Some retRepr <- gets retRepr
  translated_args <- mapM runTranslated args
  PosNat w LeqProof <- gets machineWordWidth
  return $ mkTranslatedExpr retRepr $ do
    case name of

      -- Compute the length of a value of appropriate type. The length
      -- of a nil pointer to an array or a nil slice is zero.
      "len" -> do
        args' <- forM translated_args $ runTranslatedExpr retRepr
        case args' of
          [Some (GoExpr _loc arg)] ->
            tryAsArray arg
            (\arrRepr arr -> do
                vec <- Gen.readRef arr
                return $ mkSomeGoExpr $ natToBV w $ Gen.App $ C.VectorSize vec
            ) $
            -- TODO: must be a pointer to an array, in which case the
            -- length is equal to the length of the array (nil pointer
            -- has length zero).
            tryAsPointer arg
            (\ptrRepr ptr -> case ptr of
                _ -> undefined
            ) $
            tryAsSlice arg
            (\sliceRepr slice -> do
                -- The length of a nil slice is zero.
                len <- maybeElim (BVRepr w) (return $ zeroBV w)
                  (\slice' -> do
                      end <- sliceEnd slice
                      begin <- sliceBegin slice
                      return $ natToBV w $ Gen.App $ C.NatSub end begin
                  ) slice
                return $ mkSomeGoExpr len
            ) $
            tryAsString arg
            (\si str ->
               return $ mkSomeGoExpr $ natToBV w $ Gen.App $ C.StringLength str
            ) $
            fail $ "translateBuiltin: invalid argument for 'len': " ++ show arg
          _args ->
            fail $ "translateBuiltin: expected exactly one argument to\
                   \ 'len', got " ++ show args'

      -- Create a new slice or map value.
      "make" -> case zip args translated_args of
        (Pair arg_node _argM, TranslatedType (Some repr)) : translated_args' ->
          tryAsSliceRepr repr
          (\sliceRepr ->
             undefined
          ) $
          fail $ "translateBuiltin: unsupported argument type for 'make':"
                ++ show arg_node
        _args ->
          fail $ "translateBuiltin: expected type argument to 'make', got "
                ++ show (proj1 <$> args)

      -- Allocate a new value and return a pointer to it.
      "new" -> case zip args translated_args of
        [(Pair arg_node _argM, TranslatedType (Some repr))] -> do
          zero <- zeroValue' (typeOf' arg_node) repr
          ptr <- newRefPointer zero
          return $ mkSomeGoExpr ptr
        _args ->
          fail $ "translateBuiltin: expected exactly one type argument to\
                 \ 'new', got " ++ show (proj1 <$> args)

      -- Exit the program with an error message. Technically panics
      -- can be recovered from in Go, similar to catching an
      -- exception, but we don't support such control flow for now.
      "panic" -> do
        args' <- forM translated_args $ runTranslatedExpr retRepr
        Gen.reportError $ Gen.App $ C.StringLit $
          UnicodeLiteral $ T.pack $ "panic: " ++ show args'

      -- Print the arguments.
      "print" -> do
        args' <- forM translated_args $ runTranslatedExpr retRepr
        Gen.addPrintStmt $ Gen.App $ C.StringLit $
          UnicodeLiteral $ T.pack $ show args'
        return $ mkSomeGoExpr' $ C.MkStruct Ctx.empty Ctx.empty

      -- TODO: more
      _nm ->
        fail $ "translateBuiltin: unknown identifier: " ++ show ident
