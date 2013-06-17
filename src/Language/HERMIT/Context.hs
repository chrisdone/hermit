{-# LANGUAGE InstanceSigs, ConstraintKinds, MultiParamTypeClasses #-}

module Language.HERMIT.Context
       ( -- * HERMIT Contexts
         -- ** The Standard Context
         HermitC
       , AbsolutePathH
       , initHermitC
         -- ** Bindings
       , HermitBindingSite(..)
       , BindingDepth
       , HermitBinding
       , hermitBindingSiteExpr
       , hermitBindingExpr
         -- ** Adding bindings to contexts
       , AddBindings(..)
       , addBindingGroup
       , addLambdaBinding
       , addAltBindings
       , addCaseWildBinding
       , addForallBinding
         -- ** Reading bindings from the context
       , BoundVars(..)
       , boundIn
       , findBoundVars
       , ReadBindings(..)
       , lookupHermitBinding
         -- ** Accessing the Global Reader Environment from the context
       , HasGlobalRdrEnv(..)
         -- ** Accessing GHC rewrite rules from the context
       , HasCoreRules(..)
) where

import Prelude hiding (lookup)
import GhcPlugins hiding (empty)
import Data.Monoid (mempty)
import Data.Map hiding (map, foldr, filter)
import qualified Data.Set as S
import qualified Language.Haskell.TH as TH

import Language.KURE

import Language.HERMIT.Core
import Language.HERMIT.GHC

------------------------------------------------------------------------

-- | The depth of a binding.  Used, for example, to detect shadowing when inlining.
type BindingDepth = Int


-- | HERMIT\'s representation of variable bindings.
--   Bound expressions cannot be inlined without checking for shadowing issues (using the depth information).
data HermitBindingSite
        = REC CoreExpr
        | NONREC CoreExpr
        | LAM
        | CASEALT
        | FORALL
        | CASEWILD CoreExpr (AltCon,[Var])  -- ^ We store both the scrutinised expression, and the case alternative 'AltCon' (which can be converted to Constructor or Literal) and variables.

type HermitBinding = (BindingDepth, HermitBindingSite)

-- | Retrieve the expression in a 'HermitBindingSite', if there is one.
hermitBindingSiteExpr :: HermitBindingSite -> Maybe CoreExpr
hermitBindingSiteExpr b = case b of
                            REC e        -> Just e
                            NONREC e     -> Just e
                            CASEWILD e _ -> Just e
                            _            -> Nothing

-- | Retrieve the expression in a 'HermitBinding', if there is one.
hermitBindingExpr :: HermitBinding -> Maybe CoreExpr
hermitBindingExpr = hermitBindingSiteExpr . snd

------------------------------------------------------------------------

-- | A class of contexts that can have HERMIT bindings added to them.
class AddBindings c where
  -- | Add a complete set of parrallel bindings to the context.
  --   (Parallel bindings occur in recursive let bindings and case alternatives.)
  --   This can also be used for solitary bindings (e.g. lambdas).
  --   Bindings are added in parallel sets to help with shadowing issues.
  addHermitBindings :: [(Var,HermitBindingSite)] -> c -> c

-- | Here the bindings are just discarded.
instance AddBindings (SnocPath crumb) where
  addHermitBindings :: [(Var,HermitBindingSite)] -> SnocPath crumb -> SnocPath crumb
  addHermitBindings _ = id

-------------------------------------------

-- | Add a single binding to the context.
addHermitBinding  :: AddBindings c => Var -> HermitBindingSite -> c -> c
addHermitBinding v bd = addHermitBindings [(v,bd)]

-- | Add all bindings in a binding group to a context.
addBindingGroup :: AddBindings c => CoreBind -> c -> c
addBindingGroup (NonRec v e) = addHermitBinding  v (NONREC e)
addBindingGroup (Rec ies)    = addHermitBindings [ (i, REC e) | (i,e) <- ies ]

-- | Add a wildcard binding for a specific case alternative.
addCaseWildBinding :: AddBindings c => (Id,CoreExpr,CoreAlt) -> c -> c
addCaseWildBinding (i,e,(con,vs,_)) = addHermitBinding i (CASEWILD e (con,vs))

-- | Add a lambda bound variable to a context.
--   All that is known is the variable, which may shadow something.
--   If so, we don't worry about that here, it is instead checked during inlining.
addLambdaBinding :: AddBindings c => Var -> c -> c
addLambdaBinding v = addHermitBinding v LAM

-- | Add the variables bound by a 'DataCon' in a case.
--   They are all bound at the same depth.
addAltBindings :: AddBindings c => [Var] -> c -> c
addAltBindings vs = addHermitBindings [ (v, CASEALT) | v <- vs ]

-- | Add a universally quantified type variable to a context.
addForallBinding :: AddBindings c => TyVar -> c -> c
addForallBinding v = addHermitBinding v FORALL

------------------------------------------------------------------------

-- | A class of contexts that stores the set of variables in scope that have been bound during the traversal.
class BoundVars c where
  boundVars :: c -> S.Set Var

-- | List all variables bound in the context that match the given name.
findBoundVars :: BoundVars c => TH.Name -> c -> [Var]
findBoundVars nm = filter (cmpTHName2Var nm) . S.toList . boundVars


-- | A class of contexts from which HERMIT bindings can be retrieved.
class BoundVars c => ReadBindings c where
  hermitDepth    :: c -> BindingDepth
  hermitBindings :: c -> Map Var HermitBinding

-- | Determine if a variable is bound in a context.
boundIn :: ReadBindings c => Var -> c -> Bool
boundIn i c = i `member` hermitBindings c

-- | Lookup the binding for a variable in a context.
lookupHermitBinding :: ReadBindings c => Var -> c -> Maybe HermitBinding
lookupHermitBinding v = lookup v . hermitBindings

------------------------------------------------------------------------

-- | A class of contexts that store GHC rewrite rules.
class HasCoreRules c where
  hermitCoreRules :: c -> [CoreRule]

------------------------------------------------------------------------

-- | A class of contexts that store the Global Reader Environment.
class HasGlobalRdrEnv c where
  hermitGlobalRdrEnv :: c -> GlobalRdrEnv

------------------------------------------------------------------------

type AbsolutePathH = AbsolutePath Crumb

-- | The HERMIT context, containing all bindings in scope and the current location in the AST.
--   The bindings here are lazy by choice, so that we can avoid the cost
--   of building the context if we never use it.
data HermitC = HermitC
        { hermitC_bindings       :: Map Var HermitBinding   -- ^ All (important) bindings in scope.
        , hermitC_depth          :: BindingDepth            -- ^ The depth of the bindings.
        , hermitC_path           :: AbsolutePathH           -- ^ The 'AbsolutePath' to the current node from the root.
        , hermitC_globalRdrEnv   :: GlobalRdrEnv            -- ^ The top-level lexical environment.
        , hermitC_coreRules      :: [CoreRule]              -- ^ GHC rewrite RULES.
        }

------------------------------------------------------------------------

-- | Create the initial HERMIT 'HermitC' by providing a 'ModGuts'.
initHermitC :: ModGuts -> HermitC
initHermitC modGuts = HermitC
                        { hermitC_bindings      = empty
                        , hermitC_depth         = 0
                        , hermitC_path          = mempty
                        , hermitC_globalRdrEnv  = mg_rdr_env modGuts
                        , hermitC_coreRules     = mg_rules modGuts ++ other_rules
                        }

    where other_rules :: [CoreRule]
          other_rules = mg_binds modGuts >>= bindToIdExprs >>= (idCoreRules . fst)

------------------------------------------------------------------------

-- | Retrieve the 'AbsolutePath' to the current node, from the HERMIT context.
instance ReadPath HermitC Crumb where
  absPath :: HermitC -> AbsolutePath Crumb
  absPath = hermitC_path

-- | Extend the 'AbsolutePath' stored in the HERMIT context.
instance ExtendPath HermitC Crumb where
  (@@) :: HermitC -> Crumb -> HermitC
  c @@ n = c { hermitC_path = hermitC_path c @@ n }

------------------------------------------------------------------------

instance AddBindings HermitC where
  addHermitBindings :: [(Var,HermitBindingSite)] -> HermitC -> HermitC
  addHermitBindings vbs c = let nextDepth = succ (hermitC_depth c)
                                vhbs      = [ (v, (nextDepth,b)) | (v,b) <- vbs ]
                             in c { hermitC_bindings = fromList vhbs `union` hermitC_bindings c
                                  , hermitC_depth    = nextDepth
                                  }

------------------------------------------------------------------------

instance BoundVars HermitC where
  boundVars :: HermitC -> S.Set Var
  boundVars =  keysSet . hermitC_bindings

instance ReadBindings HermitC where
  hermitDepth :: HermitC -> BindingDepth
  hermitDepth = hermitC_depth

  hermitBindings :: HermitC -> Map Var HermitBinding
  hermitBindings = hermitC_bindings

------------------------------------------------------------------------

instance HasCoreRules HermitC where
  hermitCoreRules :: HermitC -> [CoreRule]
  hermitCoreRules = hermitC_coreRules

------------------------------------------------------------------------

instance HasGlobalRdrEnv HermitC where
  hermitGlobalRdrEnv :: HermitC -> GlobalRdrEnv
  hermitGlobalRdrEnv = hermitC_globalRdrEnv

------------------------------------------------------------------------
