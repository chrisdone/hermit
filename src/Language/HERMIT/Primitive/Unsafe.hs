module Language.HERMIT.Primitive.Unsafe
    ( externals
    , unsafeReplaceR
    , unsafeReplaceStashR
    ) where

import GhcPlugins hiding (empty)
import Control.Monad

import Language.HERMIT.Core
import Language.HERMIT.Kure
import Language.HERMIT.Monad
import Language.HERMIT.External
import Language.HERMIT.ParserCore

import Prelude hiding (exp)

------------------------------------------------------------------------

externals :: [External]
externals = map (.+ Unsafe)
    [ external "unsafe-replace" (promoteExprR . unsafeReplaceR :: CoreString -> RewriteH Core)
        [ "replace the currently focused expression with a new expression" ]
    , external "unsafe-replace" (promoteExprR . unsafeReplaceStashR :: String -> RewriteH Core)
        [ "replace the currently focused expression with an expression from the stash"
        , "DOES NOT ensure expressions have the same type, or that free variables in the replacement expression are in scope" ]
    ]

------------------------------------------------------------------------

unsafeReplaceR :: CoreString -> RewriteH CoreExpr
unsafeReplaceR core =
    translate $ \ c e -> do
        e' <- parseCore core c
        guardMsg (eqType (exprType e) (exprType e')) "expression types differ."
        return e'

unsafeReplaceStashR :: String -> RewriteH CoreExpr
unsafeReplaceStashR label = prefixFailMsg "unsafe-replace failed: " $
    contextfreeT $ \ e -> do
        Def _ rhs <- lookupDef label
        guardMsg (eqType (exprType e) (exprType rhs)) "expression types differ."
        return rhs