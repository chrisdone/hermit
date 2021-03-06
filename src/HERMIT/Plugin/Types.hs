{-# LANGUAGE TypeFamilies, DeriveDataTypeable, FlexibleContexts,
             LambdaCase, GADTs, GeneralizedNewtypeDeriving,
             ScopedTypeVariables, FlexibleInstances #-}
module HERMIT.Plugin.Types where

import Control.Applicative
import Control.Concurrent.STM
import Control.Monad.Error.Class (MonadError(..))
import Control.Monad.IO.Class (MonadIO(..))
import Control.Monad.State (MonadState(..), StateT(..))
import Control.Monad.Trans.Class (MonadTrans(..))
import Control.Monad.Trans.Except (ExceptT, runExceptT)

import Data.Dynamic
import qualified Data.Map as M

import HERMIT.Kure
import HERMIT.External
import HERMIT.Kernel (KernelEnv(..))
import HERMIT.Kernel.Scoped
import HERMIT.Monad
import HERMIT.Plugin.Builder
import HERMIT.PrettyPrinter.Common

import System.IO

type PluginM = PluginT IO
newtype PluginT m a = PluginT { unPluginT :: ExceptT PException (StateT PluginState m) a }
    deriving (Functor, Applicative, MonadIO, MonadError PException, MonadState PluginState)

runPluginT :: PluginState -> PluginT m a -> m (Either PException a, PluginState)
runPluginT ps = flip runStateT ps . runExceptT . unPluginT

instance Monad m => Monad (PluginT m) where
    return = PluginT . return
    PluginT m >>= k = PluginT (m >>= unPluginT . k)
    fail = PluginT . throwError . PError

instance MonadTrans PluginT where
    lift = PluginT . lift . lift

instance Monad m => MonadCatch (PluginT m) where
    -- law: fail msg `catchM` f == f msg
    -- catchM :: m a -> (String -> m a) -> m a
    catchM m f = do
        st <- get
        (r,st') <- lift $ runPluginT st m
        case r of
            Left err -> case err of
                            PError msg -> f msg
                            other -> throwError other -- rethrow abort/resume
            Right v  -> put st' >> return v

-- Session-local issues; things that are never saved.
data PluginState = PluginState
    { ps_cursor         :: SAST                                     -- ^ the current AST
    , ps_pretty         :: PrettyPrinter                            -- ^ which pretty printer to use
    , ps_render         :: Handle -> PrettyOptions -> Either String DocH -> IO () -- ^ the way of outputing to the screen
    , ps_tick           :: TVar (M.Map String Int)                  -- ^ the list of ticked messages
    , ps_corelint       :: Bool                                     -- ^ if true, run Core Lint on module after each rewrite
    , ps_diffonly       :: Bool                                     -- ^ if true, show diffs rather than pp full code (TODO: move into pretty opts)
    , ps_failhard       :: Bool                                     -- ^ if true, abort on *any* failure
    -- this should be in a reader
    , ps_kernel         :: ScopedKernel
    , ps_pass           :: PassInfo
    } deriving (Typeable)

data PException = PAbort | PResume SAST | PError String

newtype PSBox = PSBox PluginState deriving Typeable
instance Extern PluginState where
    type Box PluginState = PSBox
    unbox (PSBox st) = st
    box = PSBox

-- tick counter
tick :: TVar (M.Map String Int) -> String -> IO Int
tick var msg = atomically $ do
        m <- readTVar var
        let c = case M.lookup msg m of
                Nothing -> 1
                Just x  -> x + 1
        writeTVar var (M.insert msg c m)
        return c

mkKernelEnv :: PluginState -> KernelEnv
mkKernelEnv st =
    let pp = ps_pretty st
        out str = liftIO $ ps_render st stdout (pOptions pp) (Left $ str ++ "\n")

    in  KernelEnv $ \ msg -> case msg of
                DebugTick    msg'      -> do
                        c <- liftIO $ tick (ps_tick st) msg'
                        out $ "<" ++ show c ++ "> " ++ msg'
                DebugCore  msg' cxt core -> do
                        out $ "[" ++ msg' ++ "]"
                        doc :: DocH <- applyT (pCoreTC pp) (liftPrettyC (pOptions pp) cxt) (inject core)
                        liftIO $ ps_render st stdout (pOptions pp) (Right doc)

iokm' :: (MonadIO m, MonadCatch m) => String -> (a -> m b) -> IO (KureM a) -> m b
iokm' msg ret m = liftIO m >>= runKureM ret (fail . (msg ++))

iokm :: (MonadIO m, MonadCatch m) => String -> IO (KureM a) -> m a
iokm msg = iokm' msg return

iokm'' :: (MonadIO m, MonadCatch m) => IO (KureM a) -> m a
iokm'' = iokm ""