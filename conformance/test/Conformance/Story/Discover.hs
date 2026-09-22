{-# LANGUAGE TemplateHaskell #-}

-- | Discover every constructor and argument recursively; unsupported shapes
-- fail compilation instead of silently shrinking the control's denominator.
module Conformance.Story.Discover (discoverPrograms) where

import Control.Monad (forM)
import Control.Monad.Operational (singleton)
import Data.Aeson (Value (String))
import Data.Text (Text, pack)
import Language.Haskell.TH

-- | Compile a finite exhaustive constructor census, varying every argument.
-- This is constructor coverage, not exhaustive coverage of scalar values.
discoverPrograms :: Name -> Q Exp
discoverPrograms name = do
    samples <- constructors name
    if null samples then fail "empty instruction census" else
        listE [ [| (label, singleton $(pure sample)) |] | (label, sample) <- samples ]

constructors :: Name -> Q [(String, Exp)]
constructors name = do
    info <- reify name
    cs <- case info of
        TyConI (DataD _ _ _ _ cons _) -> pure cons
        _ -> fail ("unsupported instruction type: " <> show name)
    fmap concat $ forM cs $ \con -> do
        (cn, fields) <- case con of
            GadtC [n] fs _ -> pure (n, map snd fs)
            NormalC n fs -> pure (n, map snd fs)
            _ -> fail ("unsupported constructor: " <> pprint con)
        args <- traverse values fields
        pure [(nameBase cn, foldl AppE (ConE cn) xs) | xs <- sequence args]

values :: Type -> Q [Exp]
values ty = case ty of
    ConT n | n == ''Value -> sequence
        [ [| String (pack "same-prefix-first") |]
        , [| String (pack "same-prefix-second") |]
        ]
    ConT n | n == ''Text -> sequence [[| pack "first" |], [| pack "second" |]]
    ConT n | n == ''Integer -> pure [LitE (IntegerL 1), LitE (IntegerL 2)]
    ConT n -> map snd <$> constructors n
    AppT ListT t -> do
        xs <- values t
        pure (ListE [] : map (ListE . (: [])) xs)
    AppT (AppT (ConT p) (ConT n)) (TupleT 0) | nameBase p == "Program" -> do
        xs <- constructors n
        -- Empty, each instruction, and ordered pairs expose dropped tails.
        let singles = [AppE (VarE 'singleton) x | (_, x) <- xs]
        empty <- [| pure () |]
        pure (empty : singles <> [InfixE (Just x) (VarE '(>>)) (Just y) | x <- singles, y <- take 2 singles])
    _ -> fail ("unsupported instruction argument: " <> pprint ty)
