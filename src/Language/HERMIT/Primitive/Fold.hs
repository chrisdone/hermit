{-# LANGUAGE ScopedTypeVariables, TypeFamilies, FlexibleContexts, TupleSections #-}
module Language.HERMIT.Primitive.Fold where

import GhcPlugins hiding (empty)
import Control.Monad
import qualified Data.Map as Map

import Language.HERMIT.Primitive.Navigation
import Language.HERMIT.Primitive.Unfold

import Language.HERMIT.Kure
import Language.HERMIT.External
import Language.HERMIT.Context

import qualified Language.Haskell.TH as TH

import Prelude hiding (exp)

------------------------------------------------------------------------

externals :: [External]
externals =
         [ external "fold" (promoteExprR . foldR)
                ["fold"]
         ]

------------------------------------------------------------------------

foldR :: TH.Name -> RewriteH CoreExpr
foldR nm =
    translate $ \ c e -> do
        i <- case filter (\i -> nm `cmpName` (idName i)) $ Map.keys (hermitBindings c) of
                [i] -> return i
                _ -> fail "fold: cannot find name"
        either fail
               (\(rhs,_d) -> maybe (fail "fold: no match")
                                   (\exp -> return exp)
                                   (fold i rhs e))
               (getUnfolding False i c)

fold :: Id -> CoreExpr -> CoreExpr -> Maybe CoreExpr
fold i lam exp = do
    let (vs,body) = foldArgs lam
    m <- foldMatch vs body exp
    -- TODO: make sure duplicate keys have same exp!
    es <- sequence [ lookup v m | v <- vs ]
    return (foldl App (Var i) es)

-- | Collect arguments to function we are folding, so we can unify with them.
foldArgs :: CoreExpr -> ([Var], CoreExpr)
foldArgs = go []
    where go vs (Lam v e) = go (v:vs) e
          go vs e         = (vs, e)

-- Note: return list can have duplicate keys, caller is responsible
-- for checking that dupes refer to same expression
foldMatch :: [Var]          -- ^ vars that can unify with anything
          -> CoreExpr       -- ^ pattern we are matching on
          -> CoreExpr       -- ^ expression we are checking
          -> Maybe [(Var,CoreExpr)] -- ^ mapping of vars to expressions, or failure
foldMatch vs (Var i) e | i `elem` vs = return [(i,e)]
                       | otherwise   = case e of
                                        Var i' | i == i' -> return []
                                        _                -> Nothing
foldMatch _  (Lit l) (Lit l') | l == l' = return []
foldMatch vs (App e a) (App e' a') = do
    x <- foldMatch vs e e'
    y <- foldMatch vs a a'
    return (x ++ y)
foldMatch vs (Lam v e) (Lam v' e') | v == v' = foldMatch (filter (==v) vs) e e'
foldMatch vs (Let (NonRec v rhs) e) (Let (NonRec v' rhs') e') | v == v' = do
    x <- foldMatch vs rhs rhs'
    y <- foldMatch (filter (==v) vs) e e'
    return (x ++ y)
foldMatch vs (Let (Rec bnds) e) (Let (Rec bnds') e') | length bnds == length bnds' = do
    let vs' = filter (`elem` map fst bnds) vs
        bmatch (v,rhs) (v',rhs') | v == v' = foldMatch vs' rhs rhs'
        bmatch _ _ = Nothing
    x <- zipWithM bmatch bnds bnds'
    y <- foldMatch vs' e e'
    return (concat x ++ y)
foldMatch vs (Tick t e) (Tick t' e') | t == t' = foldMatch vs e e'
-- TODO: showPpr hack in the rest of these!
-- TODO: we don't care if b == b' if they are not used anywhere
foldMatch vs (Case s b ty alts) (Case s' b' ty' alts')
  | (b == b') && (showPpr ty == showPpr ty') && (length alts == length alts') = do
    x <- foldMatch vs s s'
    let vs' = filter (==b) vs
        altMatch (ac, is, e) (ac', is', e') | (ac == ac') && (is == is') =
            foldMatch (filter (`elem` is) vs') e e'
        altMatch _ _ = Nothing
    y <- zipWithM altMatch alts alts'
    return (x ++ concat y)
foldMatch vs (Cast e c) (Cast e' c') | showPpr c == showPpr c' = foldMatch vs e e'
foldMatch _ (Type t) (Type t') | showPpr t == showPpr t' = return []
foldMatch _ (Coercion c) (Coercion c') | showPpr c == showPpr c' = return []
foldMatch _ _ _ = Nothing
