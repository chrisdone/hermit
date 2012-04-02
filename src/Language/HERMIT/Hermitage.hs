{-# LANGUAGE RankNTypes, ScopedTypeVariables, FlexibleInstances, KindSignatures, GADTs, DataKinds, TypeOperators #-}

-- A Hermitage is a place of quiet reflection.

module Language.HERMIT.Hermitage where

import GhcPlugins

import Control.Monad

import Language.HERMIT.HermitEnv
import Language.HERMIT.HermitMonad
import Language.HERMIT.Types
import Language.HERMIT.KURE



-- CXT is *Kind*.
data CXT where
        Everything :: CXT
        (:<) :: a -> CXT -> CXT


-- abstact outside this module
data Hermitage :: CXT -> * -> * where
    HermitageRoot   :: Context ModGuts          -> Hermitage Everything ModGuts
    Hermitage       :: Context a
                    -> (Rewrite a -> Rewrite b)
                    -> Hermitage cxt b          -> Hermitage (b :< cxt) a

{-
        = Hermitage
        { ageModGuts :: ModGuts
        , ageFocus   :: Focus c a
        , ageEnv     :: HermitEnv
        }
-}
-- Create a new Hermitage, does not return until the interaction
-- is completed.
new :: (Hermitage Everything ModGuts -> CoreM (Hermitage Everything ModGuts)) -> ModGuts -> CoreM ModGuts
new k modGuts = do
        HermitageRoot (Context _ modGuts') <- k (HermitageRoot (Context initHermitEnv modGuts))
        return modGuts'
{-

-- | What are the *current* module guts?
getModGuts :: Hermitage cxt a -> ModGuts
getModGuts age = ageModGuts age

-}
-- | 'getForeground' gets the current 'blob' under consideraton.
getForeground :: Hermitage cxt a -> Context a
getForeground (HermitageRoot a) = a
getForeground (Hermitage a _ _) = a

-- | 'getBackground' gets the current context of the blob under consideraton.
getBackground :: Hermitage cxt a -> (a -> Hermitage cxt a)
getBackground (HermitageRoot (Context c _))      a = HermitageRoot (Context c a)
getBackground (Hermitage (Context c _) hrr rest) a = Hermitage (Context c a) hrr rest


-- this focuses in to a sub-expresssion. It will do error checking, hence the
-- need for the the CoreM.

focusHermitage :: forall x a cxt
                . (Term x, Generic x ~ Blob)
               => (Rewrite x -> Rewrite a)
               -> Hermitage cxt a
               -> CoreM (Either HermitMessage (Hermitage (a :< cxt) x))
focusHermitage zoom h = focus (apply zoomT $ getForeground h)

    where
        zoomT :: Translate a [Context (Generic x)]
        zoomT = rewriteTransformerToTranslate zoom

        focus :: HermitM [Context Blob] -> CoreM (Either HermitMessage (Hermitage (a :< cxt) x))
        focus m = do
                res <- runHermitM m
                case res of
                  -- TODO: complete
                  SuccessR [Context c e] -> case select e of
                                     Nothing -> error "JDGjksdfgh"
                                     Just x  -> return $ Right $ Hermitage (Context c x) zoom h
                  SuccessR [] -> return $ Left $ HermitMessage "no down expressions found"
                  SuccessR xs -> return $ Left $ HermitMessage $ "to many down expressions found: " ++ show (length xs)
                  FailR msg -> return $ Left $ HermitMessage msg
                  YieldR {} -> return $ Left $ TransformationContainedIllegalYield

unfocusHermitage :: Hermitage (a :< cxt) x -> CoreM (Either HermitMessage (Hermitage cxt a))
unfocusHermitage (Hermitage (Context _ a) rrT rest) = applyRewrite (rrT $ constT a) rest

applyRewrite :: forall a cxt
              . Rewrite a
             -> Hermitage cxt a
             -> CoreM (Either HermitMessage (Hermitage cxt a))
applyRewrite rr h = applyRewrite2 (apply rr (getForeground h))
  where
      applyRewrite2 :: HermitM a -> CoreM (Either HermitMessage (Hermitage cxt a))
      applyRewrite2 m  = do
              r <- runHermitM m
              case r of
                SuccessR a -> return $ Right (getBackground h a)
                FailR msg  -> return $ Left $ HermitMessage msg
                YieldR {}  -> return $ Left $ TransformationContainedIllegalYield

------------------------------------------------------------------


data HermitMessage
        = UnableToFocusMessage
        | TransformationContainedIllegalYield
        | HermitMessage String
        deriving (Show)

------------------------------------------------------------------


handle :: (Monad m) => Either a b -> (b -> m (Either a c)) -> m (Either a c)
handle (Left msg) _ = return $ Left $ msg
handle (Right a)  m = m a

data Hermit :: * -> * where
   Focus :: (Term a, Term x) => (Rewrite x -> Rewrite a) -> [ Hermit x ] -> Hermit a
   Apply :: Rewrite a                                                    -> Hermit a

runHermits :: [Hermit a] -> Hermitage cxt a -> CoreM (Either HermitMessage (Hermitage cxt a))
runHermits []         h = return $ Right $ h
runHermits (cmd:cmds) h = do
        ret <- runHermit cmd h
        handle ret $ \ h1 -> runHermits cmds h1

runHermit :: Hermit a -> Hermitage cxt a -> CoreM (Either HermitMessage (Hermitage cxt a))
runHermit (Focus kick inners) h = do
        ret <- focusHermitage kick h
        handle ret $ \ h1 -> do
                ret <- runHermits inners h1
                handle ret $ \ h2 ->
                        unfocusHermitage h2
runHermit (Apply rr) h = applyRewrite rr h