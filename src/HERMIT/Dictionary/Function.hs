{-# LANGUAGE FlexibleContexts, RankNTypes #-}
module HERMIT.Dictionary.Function
    ( externals
    , appArgM
    , buildApplicationM
    , buildCompositionT
    , buildFixT
    , buildIdT
    , staticArgR
    , staticArgPosR
    , staticArgPredR
    , staticArgTypesR
    ) where

import Control.Arrow
import Control.Monad.IO.Class

import Data.List (nub, intercalate, intersect, partition, transpose)
import Data.Maybe (isNothing)

import HERMIT.Context
import HERMIT.Core
import HERMIT.External
import HERMIT.GHC
import HERMIT.Kure
import HERMIT.Monad

import HERMIT.Dictionary.Common
import HERMIT.Dictionary.GHC hiding (externals)

externals ::  [External]
externals =
    [ external "static-arg" (promoteDefR staticArgR :: RewriteH Core)
        [ "perform the static argument transformation on a recursive function." ]
    , external "static-arg-types" (promoteDefR staticArgTypesR :: RewriteH Core)
        [ "perform the static argument transformation on a recursive function, only transforming type arguments." ]
    , external "static-arg-pos" (promoteDefR . staticArgPosR :: [Int] -> RewriteH Core)
        [ "perform the static argument transformation on a recursive function, only transforming the arguments specified (by index)." ]
    ]

------------------------------------------------------------------------------------------------------

-- | Traditional Static Argument Transformation
staticArgR :: (ExtendPath c Crumb, ReadPath c Crumb, AddBindings c, HasEmptyContext c) => Rewrite c HermitM CoreDef
staticArgR = staticArgPredR (return . map fst)

-- | Static Argument Transformation that only considers type arguments to be static.
staticArgTypesR :: (ExtendPath c Crumb, ReadPath c Crumb, AddBindings c, HasEmptyContext c) => Rewrite c HermitM CoreDef
staticArgTypesR = staticArgPredR (return . map fst . filter (isTyVar . snd))

-- | Static Argument Transformations which requires that arguments in the given position are static.
staticArgPosR :: (ExtendPath c Crumb, ReadPath c Crumb, AddBindings c, HasEmptyContext c) => [Int] -> Rewrite c HermitM CoreDef
staticArgPosR is' = staticArgPredR $ \ss' -> let is = nub is'
                                                 ss = map fst ss'
                                            in if is == (is `intersect` ss)
                                               then return is
                                               else fail $ "args " ++ commas (filter (`notElem` ss) is) ++ " are not static."

-- | Generalized Static Argument Transformation, which allows static arguments to be filtered.
staticArgPredR :: (ExtendPath c Crumb, ReadPath c Crumb, AddBindings c, HasEmptyContext c)
               => ([(Int, Var)] -> HermitM [Int]) -- ^ given list of static args and positions, decided which to transform
               -> Rewrite c HermitM CoreDef
staticArgPredR decide = prefixFailMsg "static-arg failed: " $ do
    Def f rhs <- idR
    let (bnds, body) = collectBinders rhs
    guardMsg (notNull bnds) "rhs is not a function"
    contextonlyT $ \ c -> do
        let bodyContext = foldl (flip addLambdaBinding) c bnds

        -- TODO: we convert an Id to string here, and callsT then uses cmpString2Var
        --       refactor to avoid intermediate string!
        callPats <- apply (callsT (var2String f) (callT >>> arr snd)) bodyContext (ExprCore body)
        let argExprs = transpose callPats
            numCalls = length callPats
            allBinds = zip [0..] bnds

            staticBinds = [ (i,b) | ((i,b),exprs) <- zip allBinds $ argExprs ++ repeat []
                                  , length exprs == numCalls && isStatic b exprs ]
                                    -- ensure argument is present in every call (partial applications boo)

            isStatic _ []                          = True  -- all were static
            isStatic b ((Var b'):es)               | b == b' = isStatic b es
            isStatic b ((Type (TyVarTy v)):es)     | b == v  = isStatic b es
            isStatic b ((Coercion (CoVarCo v)):es) | b == v  = isStatic b es
            isStatic _ _                           = False -- not a simple repass, so dynamic

        chosen <- decide staticBinds
        let choices = map fst staticBinds
        guardMsg (notNull chosen) "no arguments selected for transformation."
        guardMsg (all (`elem` choices) chosen)
            $ "args " ++ commas choices ++ " are static, but " ++ commas chosen ++ " were selected."

        let (chosenBinds, dynBinds) = partition ((`elem` chosen) . fst) allBinds
            (ps, dbnds) = unzip dynBinds
            unboundTys = concat [ [ (i,i') | (i',b') <- dynBinds, i' < i , b' `elem` fvs ]
                                | (i,b) <- chosenBinds, let fvs = varSetElems (varTypeTyVars b) ]

        guardMsg (null unboundTys)
            $ "type variables in args " ++ commas (nub $ map fst unboundTys) ++ " would become unbound unless args "
              ++ commas (nub $ map snd unboundTys) ++ " are included in the transformation."

        wkr <- newIdH (var2String f ++ "'") (exprType (mkCoreLams dbnds body))

        let replaceCall :: Monad m => Rewrite c m CoreExpr
            replaceCall = do
                (_,exprs) <- callT
                return $ mkApps (Var wkr) [ e | (p,e) <- zip [0..] exprs, (p::Int) `elem` ps ]

        ExprCore body' <- apply (callsR (var2String f) replaceCall) bodyContext (ExprCore body)

        return $ Def f $ mkCoreLams bnds $ Let (Rec [(wkr, mkCoreLams dbnds body')])
                                             $ mkApps (Var wkr) (varsToCoreExprs dbnds)

------------------------------------------------------------------------------

-- | Get the nth argument of an application. Arg 0 is the function being applied.
appArgM :: Monad m => Int -> CoreExpr -> m CoreExpr
appArgM n e | n < 0     = fail "appArgM: arg must be non-negative"
            | otherwise = let (fn,args) = collectArgs e
                              l = fn : args
                          in if n > length args
                             then fail "appArgM: not enough arguments"
                             else return $ l !! n

-- | Build composition of two functions.
buildCompositionT :: (BoundVars c, HasDynFlags m, HasHscEnv m, HasModGuts m, MonadCatch m, MonadIO m, MonadThings m)
                  => CoreExpr -> CoreExpr -> Transform c m x CoreExpr
buildCompositionT f g = do
    composeId <- findIdT "Data.Function.."
    fDot <- buildApplicationM (varToCoreExpr composeId) f
    buildApplicationM fDot g

-- | Given expression for f and for x, build f x, figuring out the type arguments.
buildApplicationM :: (HasDynFlags m, MonadCatch m, MonadIO m) => CoreExpr -> CoreExpr -> m CoreExpr
buildApplicationM f x = do
    (vsF, domF, _) <- funTyComponentsM (exprType f)
    let (vsX, xTy) = splitForAllTys (exprType x)

    sub <- maybe (do d <- getDynFlags
                     liftIO $ putStrLn $ "f: " ++ showPpr d f
                     liftIO $ putStrLn $ "x: " ++ showPpr d x
                     liftIO $ putStrLn $ "vsF: " ++ showPpr d vsF
                     liftIO $ putStrLn $ "domF: " ++ showPpr d domF
                     liftIO $ putStrLn $ "vsX: " ++ showPpr d vsX
                     liftIO $ putStrLn $ "xTy: " ++ showPpr d xTy
                     fail "buildApplicationM - domain of f and type of x do not unify")
                 return
                 (tcUnifyTy domF xTy)

    f' <- substOrApply f [ (v, Type $ substTyVar sub v) | v <- vsF ]
    x' <- substOrApply x [ (v, Type $ substTyVar sub v) | v <- vsX ]
    let vs = [ v | v <- vsF ++ vsX, isNothing $ lookupTyVar sub v ]  -- things we should stick back on as foralls
    -- TODO: make sure vsX don't capture anything in f'
    --       and vsF' doesn't capture anything in x'
    return $ mkCoreLams vs $ mkCoreApp f' x'

-- | Given expression for f, build fix f.
buildFixT :: (BoundVars c, HasHscEnv m, HasModGuts m, MonadCatch m, MonadIO m, MonadThings m)
          => CoreExpr -> Transform c m x CoreExpr
buildFixT f = do
    ty <- endoFunExprType f
    fixId <- findIdT "Data.Function.fix"
    return $ mkCoreApps (varToCoreExpr fixId) [Type ty, f]

-- | Build an expression that is the monomorphic id function for given type.
buildIdT :: (BoundVars c, HasHscEnv m, HasModGuts m, MonadCatch m, MonadIO m, MonadThings m)
         => Type -> Transform c m x CoreExpr
buildIdT ty = do
    idId <- findIdT "Data.Function.id"
    return $ mkCoreApp (varToCoreExpr idId) (Type ty)

------------------------------------------------------------------------------

commas :: Show a => [a] -> String
commas = intercalate "," . map show

-- | Like mkCoreApps, but automatically beta-reduces when possible.
substOrApply :: Monad m => CoreExpr -> [(Var,CoreExpr)] -> m CoreExpr
substOrApply e         []         = return e
substOrApply (Lam b e) ((v,ty):r) = if b == v
                                    then substOrApply e r >>= return . substCoreExpr b ty
                                    else fail $ "substOrApply: unexpected binder - "
                                                ++ getOccString b ++ " - " ++ getOccString v
substOrApply e         rest       = return $ mkCoreApps e (map snd rest)

------------------------------------------------------------------------------
