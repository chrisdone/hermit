{-# LANGUAGE DeriveDataTypeable, FlexibleContexts, MultiParamTypeClasses, ScopedTypeVariables, TypeFamilies #-}

module HERMIT.Shell.ScriptToRewrite
    ( -- * Converting Scripts to Rewrites
      addScriptToDict
--    , evalScript
    , loadAndRun
    , lookupScript
    , parseScriptCLT
    , performScriptEffect
--    , runScript
    , scriptToRewrite
    , setRunningScript
    , ScriptEffect(..)
    ) where

import Control.Arrow
import Control.Monad.Error
import Control.Monad.State
import Control.Exception hiding (catch)

import Data.Dynamic
import Data.Map hiding (lookup)

import HERMIT.Context(LocalPathH)
import HERMIT.Kernel.Scoped
import HERMIT.Kure
import HERMIT.External
import HERMIT.Parser(Script, ExprH, unparseExprH, parseScript, unparseScript)

import HERMIT.Plugin.Types

import HERMIT.PrettyPrinter.Common(TransformCoreTCDocHBox(..))

import HERMIT.Shell.KernelEffect
import HERMIT.Shell.Interpreter
import HERMIT.Shell.ShellEffect
import HERMIT.Shell.Types

------------------------------------

{-
evalScript :: (MonadCatch m, MonadError CLException m, MonadIO m, MonadState CommandLineState m) => String -> m ()
evalScript = parseScriptCLT >=> runScript

runScript :: (MonadCatch m, MonadError CLException m, MonadIO m, MonadState CommandLineState m) => Script -> m ()
runScript = mapM_ undefined

runExprH :: forall m c a r. (ShellCommandSet c a r, MonadCatch m, MonadError CLException m, MonadIO m, MonadState CommandLineState m) => ExprH -> a -> m r
runExprH e arg = do
    cis <- gets cl_interps
    case cis of
        CmdInterps is -> do
            cmd <- interpExprH is e
            performCommand cmd arg
-}

------------------------------------

type RewriteName = String

data ScriptEffect
    = DefineScript ScriptName String
    | LoadFile ScriptName FilePath  -- load a file on top of the current node
    | RunScript ScriptName
    | SaveFile FilePath
    | SaveScript FilePath ScriptName
    | ScriptToRewrite RewriteName ScriptName
    | SeqMeta [ScriptEffect]
    deriving Typeable

instance Extern ScriptEffect where
    type Box ScriptEffect = ScriptEffect
    box i = i
    unbox i = i

{-
instance ShellCommandSet ScriptEffect () () where
    performCommand c () = performScriptEffect c
-}

-- | A composite meta-command for running a loaded script immediately.
--   The script is given the same name as the filepath.
loadAndRun :: FilePath -> ScriptEffect
loadAndRun fp = SeqMeta [LoadFile fp fp, RunScript fp]

performScriptEffect :: (MonadCatch m, MonadError CLException m, MonadIO m, MonadState CommandLineState m) => (Script -> m ()) -> ScriptEffect -> m ()
performScriptEffect runner = go
    where go (SeqMeta ms) = mapM_ go ms
          go (LoadFile scriptName fileName) = do
            putStrToConsole $ "Loading \"" ++ fileName ++ "\"..."
            res <- liftIO $ try (readFile fileName)
            case res of
                Left (err :: IOException) -> fail ("IO error: " ++ show err)
                Right str -> do 
                    script <- parseScriptCLT str
                    modify $ \ st -> st {cl_scripts = (scriptName,script) : cl_scripts st}
                    putStrToConsole ("Script \"" ++ scriptName ++ "\" loaded successfully from \"" ++ fileName ++ "\".")

          go (SaveFile fileName) = do
            version <- gets cl_version
            putStrToConsole $ "[saving " ++ fileName ++ "]"
            -- no checks to see if you are clobering; be careful
            liftIO $ writeFile fileName $ showGraph (vs_graph version) (vs_tags version) (SAST 0)

          go (ScriptToRewrite rewriteName scriptName) = do
            script <- lookupScript scriptName
            addScriptToDict rewriteName script
            putStrToConsole ("Rewrite \"" ++ rewriteName ++ "\" defined successfully.")

          go (DefineScript scriptName str) = do
            script <- parseScriptCLT str
            modify $ \ st -> st {cl_scripts = (scriptName,script) : cl_scripts st}
            putStrToConsole ("Script \"" ++ scriptName ++ "\" defined successfully.")

          go (RunScript scriptName) = do
            script <- lookupScript scriptName
            running_script_st <- gets cl_running_script
            setRunningScript True
            runner script `catchError` (\ err -> setRunningScript running_script_st >> throwError err)
            setRunningScript running_script_st
            putStrToConsole ("Script \"" ++ scriptName ++ "\" ran successfully.")
            showWindow

          go (SaveScript fileName scriptName) = do 
            script <- lookupScript scriptName
            putStrToConsole $ "Saving script \"" ++ scriptName ++ "\" to file \"" ++ fileName ++ "\"."
            liftIO $ writeFile fileName $ unparseScript script
            putStrToConsole $ "Save successful."

lookupScript :: MonadState CommandLineState m => ScriptName -> m Script
lookupScript scriptName = do scripts <- gets cl_scripts
                             case lookup scriptName scripts of
                               Nothing     -> fail $ "No script of name " ++ scriptName ++ " is loaded."
                               Just script -> return script

parseScriptCLT :: Monad m => String -> m Script
parseScriptCLT = either fail return . parseScript

setRunningScript :: MonadState CommandLineState m => Bool -> m ()
setRunningScript b = modify $ \st -> st { cl_pstate = (cl_pstate st) { ps_running_script = b } }

------------------------------------

data UnscopedScriptR
              = ScriptBeginScope
              | ScriptEndScope
              | ScriptPrimUn PrimScriptR
              | ScriptUnsupported String

data ScopedScriptR
              = ScriptScope [ScopedScriptR]
              | ScriptPrimSc ExprH PrimScriptR

data PrimScriptR
       = ScriptRewriteHCore (RewriteH Core)
       | ScriptPath PathH
       | ScriptTransformHCorePath (TransformH Core LocalPathH)


-- TODO: Hacky parsing, needs cleaning up
unscopedToScopedScriptR :: forall m. Monad m => [(ExprH, UnscopedScriptR)] -> m [ScopedScriptR]
unscopedToScopedScriptR = parse
  where
    parse :: [(ExprH, UnscopedScriptR)] -> m [ScopedScriptR]
    parse []     = return []
    parse (y:ys) = case y of
                     (e, ScriptUnsupported msg) -> fail $ mkMsg e msg
                     (e, ScriptPrimUn pr)       -> (ScriptPrimSc e pr :) <$> parse ys
                     (_, ScriptBeginScope)      -> do (rs,zs) <- parseUntilEndScope ys
                                                      (ScriptScope rs :) <$> parse zs
                     (_, ScriptEndScope)        -> fail "unmatched end-of-scope."

    parseUntilEndScope :: Monad m => [(ExprH, UnscopedScriptR)] -> m ([ScopedScriptR], [(ExprH, UnscopedScriptR)])
    parseUntilEndScope []     = fail "missing end-of-scope."
    parseUntilEndScope (y:ys) = case y of
                                  (_, ScriptEndScope)        -> return ([],ys)
                                  (_, ScriptBeginScope)      -> do (rs,zs)  <- parseUntilEndScope ys
                                                                   first (ScriptScope rs :) <$> parseUntilEndScope zs
                                  (e, ScriptPrimUn pr)       -> first (ScriptPrimSc e pr :) <$> parseUntilEndScope ys
                                  (e, ScriptUnsupported msg) -> fail $ mkMsg e msg

    mkMsg :: ExprH -> String -> String
    mkMsg e msg = "script cannot be converted to a rewrite because it contains the following " ++ msg ++ ": " ++ unparseExprH e

-----------------------------------

interpScriptR :: [Interp UnscopedScriptR]
interpScriptR =
  [ interp (\ (RewriteCoreBox r)           -> ScriptPrimUn $ ScriptRewriteHCore r)
  , interp (\ (RewriteCoreTCBox _)         -> ScriptUnsupported "rewrite that traverses types and coercions") -- TODO
  , interp (\ (BiRewriteCoreBox br)        -> ScriptPrimUn $ ScriptRewriteHCore $ whicheverR br)
  , interp (\ (CrumbBox cr)                -> ScriptPrimUn $ ScriptPath [cr])
  , interp (\ (PathBox p)                  -> ScriptPrimUn $ ScriptPath (snocPathToPath p))
  , interp (\ (TransformCorePathBox t)     -> ScriptPrimUn $ ScriptTransformHCorePath t)
  , interp (\ (effect :: KernelEffect)     -> case effect of
                                                BeginScope -> ScriptBeginScope
                                                EndScope   -> ScriptEndScope
                                                _          -> ScriptUnsupported "Kernel effect" )
  , interp (\ (_ :: ShellEffect)           -> ScriptUnsupported "shell effect")
  , interp (\ (_ :: QueryFun)              -> ScriptUnsupported "query")
  , interp (\ (TransformCoreStringBox _)   -> ScriptUnsupported "query")
  , interp (\ (TransformCoreTCStringBox _) -> ScriptUnsupported "query")
  , interp (\ (TransformCoreTCDocHBox _)   -> ScriptUnsupported "query")
  , interp (\ (TransformCoreCheckBox _)    -> ScriptUnsupported "predicate")
  , interp (\ (StringBox _)                -> ScriptUnsupported "message")
  ]

-----------------------------------

scopedScriptsToRewrite :: [ScopedScriptR] -> RewriteH Core
scopedScriptsToRewrite []        = idR
scopedScriptsToRewrite (x : xs)  = let rest = scopedScriptsToRewrite xs
                                       failWith e = prefixFailMsg ("Error in script expression: " ++ unparseExprH e ++ "\n")
                                   in case x of
                                        ScriptScope ys    -> scopedScriptsToRewrite ys >>> rest
                                        ScriptPrimSc e pr -> case pr of
                                                              ScriptRewriteHCore r       -> failWith e r >>> rest
                                                              ScriptPath p               -> failWith e $ pathR p rest
                                                              ScriptTransformHCorePath t -> do p <- failWith e t
                                                                                               localPathR p rest

-----------------------------------

scriptToRewrite :: MonadState CommandLineState m => Script -> m (RewriteH Core)
scriptToRewrite scr = do
    unscoped <- mapM (interpExprH interpScriptR) scr
    scoped   <- unscopedToScopedScriptR $ zip scr unscoped
    return $ scopedScriptsToRewrite scoped

-----------------------------------

-- | Insert a script into the 'Dictionary'.
addScriptToDict :: MonadState CommandLineState m => ScriptName -> Script -> m ()
addScriptToDict nm scr = do
    r <- scriptToRewrite scr

    let dyn = toDyn (box r)

        alteration :: Maybe [Dynamic] -> Maybe [Dynamic]
        alteration Nothing     = Just [dyn]
        alteration (Just dyns) = Just (dyn:dyns)

    modify $ \ st -> st { cl_dict = alter alteration nm (cl_dict st) }

-----------------------------------

-- I find it annoying that Functor is not a superclass of Monad.
(<$>) :: Monad m => (a -> b) -> m a -> m b
(<$>) = liftM
{-# INLINE (<$>) #-}

-----------------------------------
