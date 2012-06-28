{-# LANGUAGE TypeFamilies, DeriveDataTypeable, FlexibleContexts,
             GADTs, TypeSynonymInstances, FlexibleInstances #-}

module Language.HERMIT.External where

import Data.Map hiding (map)
import Data.Dynamic
import Data.List

import qualified Language.Haskell.TH as TH

import Language.HERMIT.Kure

-----------------------------------------------------------------

type ExternalName = String
type ExternalHelp = [String]

-- Tags --------------------------------------------------------

data CmdTag = CaseCmd       -- works on case statements
            | Context       -- something that uses the context
            | Eval          -- the arrow of evaluation (reduces a term)
            | Experiment    -- things we are trying out
            | GHC           -- a tunnel into GHC
            | KURE          -- a KURE command
            | Lens          -- focuses into a specific node
            | LetCmd        -- works on let statements
            | Local         -- local thing, O(1)
            | Meta          -- combines other commands
            | Restful       -- RESTful API commands
            | Shell         -- Shell commands
            | Slow          -- this command is slow
            | Unimplemented
            -- Other String
            -- etc
    deriving (Eq, Show, Read)

-- Unfortunately, record update syntax seems to associate to the right.
-- This guy saves us some parens.
infixl 3 .+

data TagE :: * where
    Tag    :: (Tag a) => a -> TagE
    NotTag :: TagE -> TagE
    AndTag :: TagE -> TagE -> TagE
    OrTag  :: TagE -> TagE -> TagE

class Tag a where
    toTagE :: a -> TagE
    (.+) :: External -> a -> External
    remTag :: a -> External -> External
    tagMatch :: a -> External -> Bool

instance Tag TagE where
    toTagE = id

    e .+ (Tag t) = e .+ t
    e .+ (NotTag t) = remTag t e
    e .+ (AndTag t1 t2) = e .+ t1 .+ t2
    e .+ (OrTag t1 t2) = e .+ t1 .+ t2 -- not sure what else to do

    remTag (Tag t) e = remTag t e
    remTag (NotTag t) e = e .+ t
    remTag (AndTag t1 t2) e = remTag t1 (remTag t2 e)
    remTag (OrTag t1 t2) e = remTag t1 (remTag t2 e) -- again

    tagMatch (Tag t)        e = tagMatch t e
    tagMatch (NotTag t)     e = not (tagMatch t e)
    tagMatch (AndTag t1 t2) e = tagMatch t1 e && tagMatch t2 e
    tagMatch (OrTag  t1 t2) e = tagMatch t1 e || tagMatch t2 e

instance Tag CmdTag where
    toTagE = Tag
    ex@(External {externTags = ts}) .+ t = ex { externTags = (t:ts) }
    remTag t ex@(External {externTags = ts}) = ex { externTags = [ t' | t' <- ts, t' /= t ] }
    tagMatch t (External {externTags = ts}) = t `elem` ts

infixr 5 .&
(.&) :: (Tag a, Tag b) => a -> b -> TagE
t1 .& t2 = AndTag (toTagE t1) (toTagE t2)

infixr 4 .||
(.||) :: (Tag a, Tag b) => a -> b -> TagE
t1 .|| t2 = OrTag (toTagE t1) (toTagE t2)

-- how to make a unary operator?
notT :: (Tag a) => a -> TagE
notT = NotTag . toTagE

-----------------------------------------------------------------

data External = External
        { externName :: ExternalName
        , externFun  :: Dynamic
        , externHelp :: ExternalHelp
        , externTags :: [CmdTag]
        }

external :: Extern a => ExternalName -> a -> ExternalHelp -> External
external nm fn help = External
        { externName = nm
        , externFun  = toDyn (box fn)
        , externHelp = map ("  " ++) help
        , externTags = []
        }

toDictionary :: [External] -> Map ExternalName [Dynamic]
toDictionary
        -- TODO: check names are uniquely-prefixed
        | otherwise = fromListWith (++) . map toD
  where
         toD :: External -> (ExternalName,[Dynamic])
         toD e = (externName e,[externFun e])

toHelp :: [External] -> Map ExternalName ExternalHelp
toHelp = fromListWith (++) . map toH
  where
         toH :: External -> (ExternalName,ExternalHelp)
         toH e = (externName e, spaceout (externName e ++ " :: " ++ fixup (show (dynTypeRep (externFun e))))
                                         (show (externTags e)) : externHelp e)

         spaceout xs ys = xs ++ take (width - (length xs + length ys)) (repeat ' ') ++ ys

         width = 78

         fixup :: String -> String
         fixup xs | "Box" `isPrefixOf` xs = fixup (drop 3 xs)
         fixup (x:xs)                     = x : fixup xs
         fixup []                         = []


-----------------------------------------------------------------

class Typeable (Box a) => Extern a where
    type Box a
    box :: a -> Box a
    unbox :: Box a -> a

instance (Extern a, Extern b) => Extern (a -> b) where
    type Box (a -> b) = Box a -> Box b
    box f = box . f . unbox
    unbox f = unbox . f . box

data TagBox = TagBox TagE deriving Typeable

instance Extern TagE where
    type Box TagE = TagBox
    box t = TagBox t
    unbox (TagBox t) = t

data IntBox = IntBox Int deriving Typeable

instance Extern Int where
    type Box Int = IntBox
    box i = IntBox i
    unbox (IntBox i) = i

data RewriteCoreBox = RewriteCoreBox (RewriteH Core) deriving Typeable

instance Extern (RewriteH Core) where
    type Box (RewriteH Core) = RewriteCoreBox
    box i = RewriteCoreBox i
    unbox (RewriteCoreBox i) = i

data TranslateCoreStringBox = TranslateCoreStringBox (TranslateH Core String) deriving Typeable

instance Extern (TranslateH Core String) where
    type Box (TranslateH Core String) = TranslateCoreStringBox
    box i = TranslateCoreStringBox i
    unbox (TranslateCoreStringBox i) = i

data NameBox = NameBox (TH.Name) deriving Typeable

instance Extern TH.Name where
    type Box TH.Name = NameBox
    box i = NameBox i
    unbox (NameBox i) = i

data TranslateCorePathBox = TranslateCorePathBox (TranslateH Core Path) deriving Typeable

instance Extern (TranslateH Core Path) where
    type Box (TranslateH Core Path) = TranslateCorePathBox
    box i = TranslateCorePathBox i
    unbox (TranslateCorePathBox i) = i


data StringBox = StringBox String deriving Typeable

instance Extern String where
    type Box String = StringBox
    box i = StringBox i
    unbox (StringBox i) = i

-----------------------------------------------------------------
