data Foo = Bar Int Float | Baz String

main = print foo

{-# NOINLINE bar #-}
bar = Bar 5 2.1
foo = case bar of
        Bar x f -> show x
        Baz s -> s
