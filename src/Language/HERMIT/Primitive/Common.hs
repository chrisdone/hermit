-- | Note: this module should NOT export externals. It is for common
--   transformations needed by the other primitive modules.
module Language.HERMIT.Primitive.Common where

import GhcPlugins

import Control.Arrow

import Data.List
import Data.Monoid

import Language.HERMIT.Kure

import Language.HERMIT.Primitive.GHC

-- | All the identifiers bound in this binding group.
bindings :: CoreBind -> [Id]
bindings (NonRec b _) = [b]
bindings (Rec bs)     = map fst bs

-- | Lifted version of 'bindings'.
bindingsT :: TranslateH CoreBind [Var]
bindingsT = arr bindings

-- | List of variables bound by Let (including type variables)
letVarsT :: TranslateH CoreExpr [Var]
letVarsT = do Let bs _ <- idR
              return (bindings bs)

-- | List of Ids bound by the case alternative
altVarsT :: TranslateH CoreAlt [Id]
altVarsT = do (_,vs,_) <- idR
              return vs

-- | List of the list of Ids bound by each case alternative
caseAltVarsT :: TranslateH CoreExpr [[Id]]
caseAltVarsT = caseT mempty (const altVarsT) $ \ () _ _ vs -> vs

-- | List of the list of Ids bound by each case alternative, including the Case binder in each list
caseAltVarsWithBinderT :: TranslateH CoreExpr [[Id]]
caseAltVarsWithBinderT = caseT mempty (const altVarsT) $ \ () v _ vs -> map (v:) vs

-- | list containing the single Id of the case binder
caseBinderVarT :: TranslateH CoreExpr [Id]
caseBinderVarT = setFailMsg "Not a Case expression." $
                 do Case _ b _ _ <- idR
                    return [b]

-- | Free variables for a CoreAlt, returns a function, which accepts
--   the coreBndr name, before giving a result.
--   This is so we can use this with congruence combinators:
--
--   caseT id (const altFreeVarsT) $ \ _ bndr _ fs -> [ f bndr | f <- fs ]
altFreeVarsT :: TranslateH CoreAlt (Id -> [Var])
altFreeVarsT = altT freeVarsT $ \ _con ids frees coreBndr -> nub frees \\ nub (coreBndr : ids)

------------------------------------------------------------------------------

wrongExprForm :: String -> String
wrongExprForm form = "Expression does not have the form: " ++ form

------------------------------------------------------------------------------
