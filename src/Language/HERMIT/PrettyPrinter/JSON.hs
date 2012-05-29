{-# LANGUAGE OverloadedStrings #-}
-- | JSON pretty printer
module Language.HERMIT.PrettyPrinter.JSON where

import Control.Arrow

import Data.Aeson
import Data.Aeson.Types
import qualified Data.Text as T

import qualified GhcPlugins as GHC
import Language.HERMIT.HermitKure
import Language.HERMIT.PrettyPrinter
import Language.KURE
import Language.KURE.Injection

corePrettyH :: PrettyOptions -> TranslateH Core Value
corePrettyH _opts =
       promoteT ppCoreExpr
    <+ promoteT ppProgram
    <+ promoteT ppCoreBind
    <+ promoteT ppCoreDef
    <+ promoteT ppModGuts
    <+ promoteT ppCoreAlt
  where
    mkCon :: String -> Pair
    mkCon con = "con" .= con

    -- Use for any GHC structure, the 'showSDoc' prefix is to remind us
    -- that we are eliding infomation here.
    ppSDoc :: (GHC.Outputable a) => a -> Value
    ppSDoc = String . T.pack . GHC.showSDoc . GHC.ppr

    ppModGuts :: TranslateH GHC.ModGuts Value
    ppModGuts = arr (ppSDoc . GHC.mg_module)

    -- DocH is not a monoid, so we can't use listT here
    ppProgram :: TranslateH GHC.CoreProgram Value -- CoreProgram = [CoreBind]
    ppProgram = translate $ \ c -> fmap toJSON . mapM (apply ppCoreBind c)

    ppCoreExpr :: TranslateH GHC.CoreExpr Value
    ppCoreExpr = varT (\i -> object [mkCon "Var", "value" .= ppSDoc i])
              <+ litT (\i -> object [mkCon "Lit", "value" .= ppSDoc i])
              <+ appT ppCoreExpr ppCoreExpr (\ a b -> object [mkCon "App", "lhs" .= a, "rhs" .= b])
              <+ lamT ppCoreExpr (\ v e -> object [mkCon "Lam", "var" .= ppSDoc v, "body" .= e])
              <+ letT ppCoreBind ppCoreExpr (\ b e -> object [mkCon "Let", "binds" .= b, "exp" .= e])
              <+ caseT ppCoreExpr (const ppCoreAlt) (\s b ty alts ->
                        object [ mkCon "Case"
                               , "s" .= s
                               , "caseBndr" .= ppSDoc b
                               , "type" .= ppSDoc ty
                               , "alts" .= alts ])
              <+ castT ppCoreExpr (\e co -> object [mkCon "Cast", "exp" .= e, "cast" .= ppSDoc co])
              <+ tickT ppCoreExpr (\i e  -> object [mkCon "Tick", "tick" .= ppSDoc i, "exp" .= e])
              <+ typeT (\ty -> object [mkCon "Type", "type" .= ppSDoc ty])
              <+ coercionT (\co -> object [mkCon "Coercion", "coercion" .= ppSDoc co])

    ppCoreBind :: TranslateH GHC.CoreBind Value
    ppCoreBind = nonRecT ppCoreExpr (\i e -> object [mkCon "NonRec", "var" .= ppSDoc i, "exp" .= e])
              <+ recT (const ppCoreDef) (\bnds -> object [mkCon "Rec", "binds" .= bnds])

    ppCoreAlt :: TranslateH GHC.CoreAlt Value
    ppCoreAlt = altT ppCoreExpr $ \ con ids e -> object [ mkCon "Alt"
                                                        , "altcon" .= ppSDoc con
                                                        , "ids" .= map ppSDoc ids
                                                        , "exp" .= e ]

    ppCoreDef :: TranslateH CoreDef Value
    ppCoreDef = defT ppCoreExpr $ \ i e -> object [mkCon "CoreDef", "var" .= ppSDoc i, "exp" .= e]