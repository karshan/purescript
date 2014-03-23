-----------------------------------------------------------------------------
--
-- Module      :  Language.PureScript.CaseDeclarations
-- Copyright   :  (c) Phil Freeman 2013
-- License     :  MIT
--
-- Maintainer  :  Phil Freeman <paf31@cantab.net>
-- Stability   :  experimental
-- Portability :
--
-- |
-- This module implements the desugaring pass which replaces top-level binders with
-- case expressions.
--
-----------------------------------------------------------------------------

module Language.PureScript.Sugar.CaseDeclarations (
    desugarCases,
    desugarCasesModule
) where

import Data.List (groupBy)
import Data.Generics (mkM, mkT, everywhere)
import Data.Generics.Extras

import Control.Applicative
import Control.Monad ((<=<), forM, join, unless)
import Control.Monad.Error.Class

import Language.PureScript.Names
import Language.PureScript.Declarations
import Language.PureScript.Scope
import Language.PureScript.Environment

-- |
-- Replace all top-level binders in a module with case expressions.
--
desugarCasesModule :: [Module] -> Either String [Module]
desugarCasesModule ms = forM ms $ \(Module name ds exps) -> Module name <$> (desugarCases . desugarAbs $ ds) <*> pure exps

desugarAbs :: [Declaration] -> [Declaration]
desugarAbs = everywhere (mkT replace)
  where
  replace (Abs (Right binder) val) =
    let
      ident = head $ unusedNames (binder, val)
    in
      Abs (Left ident) $ Case [Var (Qualified Nothing ident)] [CaseAlternative [binder] Nothing val]
  replace other = other

-- |
-- Replace all top-level binders with case expressions.
--
desugarCases :: [Declaration] -> Either String [Declaration]
desugarCases = desugarRest <=< fmap join . mapM toDecls . groupBy inSameGroup
  where
    desugarRest :: [Declaration] -> Either String [Declaration]
    desugarRest (TypeInstanceDeclaration name constraints className tys ds : rest) =
      (:) <$> (TypeInstanceDeclaration name constraints className tys <$> desugarCases ds) <*> desugarRest rest
    desugarRest (ValueDeclaration name nameKind bs g val : rest) = do
      (:) <$> (ValueDeclaration name nameKind bs g <$> everywhereM' (mkM go) val) <*> desugarRest rest
      where
      go (Let ds val') = Let <$> desugarCases ds <*> pure val'
      go other = return other
    desugarRest (d : ds) = (:) d <$> desugarRest ds
    desugarRest [] = pure []

inSameGroup :: Declaration -> Declaration -> Bool
inSameGroup (ValueDeclaration ident1 _ _ _ _) (ValueDeclaration ident2 _ _ _ _) = ident1 == ident2
inSameGroup _ _ = False

toDecls :: [Declaration] -> Either String [Declaration]
toDecls [ValueDeclaration ident nameKind bs Nothing val] | all isVarBinder bs = do
  let args = map (\(VarBinder arg) -> arg) bs
      body = foldr (Abs . Left) val args
  return [ValueDeclaration ident nameKind [] Nothing body]
toDecls ds@(ValueDeclaration ident _ bs _ _ : _) = do
  let tuples = map toTuple ds
  unless (all ((== length bs) . length . fst) tuples) $
      throwError $ "Argument list lengths differ in declaration " ++ show ident
  return [makeCaseDeclaration ident tuples]
toDecls ds = return ds

isVarBinder :: Binder -> Bool
isVarBinder (VarBinder _) = True
isVarBinder _ = False

toTuple :: Declaration -> ([Binder], (Maybe Guard, Value))
toTuple (ValueDeclaration _ _ bs g val) = (bs, (g, val))
toTuple _ = error "Not a value declaration"

makeCaseDeclaration :: Ident -> [([Binder], (Maybe Guard, Value))] -> Declaration
makeCaseDeclaration ident alternatives =
  let
    argPattern = length . fst . head $ alternatives
    args = take argPattern $ unusedNames (ident, alternatives)
    vars = map (Var . Qualified Nothing) args
    binders = [ CaseAlternative bs g val | (bs, (g, val)) <- alternatives ]
    value = foldr (Abs . Left) (Case vars binders) args
  in
    ValueDeclaration ident Value [] Nothing value

