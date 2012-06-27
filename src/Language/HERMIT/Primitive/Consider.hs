module Language.HERMIT.Primitive.Consider where

import GhcPlugins as GHC

import Language.HERMIT.HermitKure
import Language.HERMIT.External
import Language.HERMIT.GHC

import Control.Arrow

import qualified Language.Haskell.TH as TH

externals :: [External]
externals = map (.+ Lens)
            [
              external "consider" considerName
                [ "'consider <v>' focuses on a named binding <v>" ]
            , external "consider" considerConstruct
                [ "'consider <c>' focuses on the first construct <c>.",
                  recognizedConsiderables]
            , external "rhs-of" rhsOf
                [ "rhs-of 'name focuses into the right-hand-side of binding <v>" ]
        -- This is in the wrong place
            , external "var" (promoteR . var :: TH.Name -> RewriteH Core)
                [ "var <v> succeeded for variable v, and fails otherwise"]
            ]

-- Focus on a bindings
considerName :: TH.Name -> TranslateH Core Path
considerName = uniquePrunePathToT . bindGroup

-- find a bind group that defineds a given name

bindGroup :: TH.Name -> Core -> Bool
bindGroup nm (BindCore (NonRec v _))  =  nm `cmpName` idName v
bindGroup nm (BindCore (Rec bds))     =  any (cmpName nm . idName) $ map fst bds
bindGroup _  _                        =  False

-- find a specific binding's rhs.
rhsOf :: TH.Name -> TranslateH Core Path
rhsOf nm = uniquePrunePathToT (namedBinding nm) >>> arr (++ [0])

namedBinding :: TH.Name -> Core -> Bool
namedBinding nm (BindCore (NonRec v _))  =  nm `cmpName` idName v
namedBinding nm (DefCore (Def v _))      =  nm `cmpName` idName v
namedBinding _  _                        =  False

-- Hacks till we can find the correct way of doing these.
cmpName :: TH.Name -> Name -> Bool
cmpName = cmpTHName2Name

data Considerable = Binding | Definition | CaseAlt | Variable | Literal | Application | Lambda | LetIn | CaseOf | Casty | Ticky | TypeVar | Coerce

recognizedConsiderables :: String
recognizedConsiderables = "Recognized constructs are: " ++ show (map fst considerables)

considerables ::  [(String,Considerable)]
considerables =   [ ("bind",Binding)
                  , ("def",Definition)
                  , ("alt",CaseAlt)
                  , ("var",Variable)
                  , ("lit",Literal)
                  , ("app",Application)
                  , ("lam",Lambda)
                  , ("let",LetIn)
                  , ("case",CaseOf)
                  , ("cast",Casty)
                  , ("tick",Ticky)
                  , ("type",TypeVar)
                  , ("coerce",Coerce)
                  ]

considerConstruct :: String -> TranslateH Core Path
considerConstruct str = case string2considerable str of
                          Nothing -> fail $ "Unrecognized construct \"" ++ str ++ "\". " ++ recognizedConsiderables ++ ".  Or did you mean \"consider '" ++ str ++ "\"?"
                          Just c  -> firstPathToT (underConsideration c)

string2considerable :: String -> Maybe Considerable
string2considerable = flip lookup considerables

underConsideration :: Considerable -> Core -> Bool
underConsideration Binding     (BindCore _)               = True
underConsideration Definition  (BindCore (NonRec _ _))    = True
underConsideration Definition  (DefCore _)                = True
underConsideration CaseAlt     (AltCore _)                = True
underConsideration Variable    (ExprCore (Var _))         = True
underConsideration Literal     (ExprCore (Lit _))         = True
underConsideration Application (ExprCore (App _ _))       = True
underConsideration Lambda      (ExprCore (Lam _ _))       = True
underConsideration LetIn       (ExprCore (Let _ _))       = True
underConsideration CaseOf      (ExprCore (Case _ _ _ _))  = True
underConsideration Casty       (ExprCore (Cast _ _))      = True
underConsideration Ticky       (ExprCore (Tick _ _))      = True
underConsideration TypeVar     (ExprCore (Type _))        = True
underConsideration Coerce      (ExprCore (Coercion _))    = True
underConsideration _           _                          = False


var :: TH.Name -> RewriteH CoreExpr
var nm = whenM (varT $ \ v -> nm `cmpName` idName v) idR

-- var nm = contextfreeT $ \ e -> do
--   liftIO $ print ("VAR",GHC.showSDoc . GHC.ppr $ thRdrNameGuesses $ nm)
--   case e of
--     Var n0 | nm `cmpName` idName n0 -> return e
--     _                               -> fail $ "Name \"" ++ show nm ++ "\" not found."
