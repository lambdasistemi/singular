{-# LANGUAGE TemplateHaskellQuotes #-}

module Singular.Registry.E2E.Constructors (constructorSet, constructorTag) where

import Language.Haskell.TH

-- Reify the declarations, never the replay implementation or fixture list.
constructors :: Name -> Q [(Name, Int)]
constructors name = do
    TyConI (DataD _ _ _ _ cs _) <- reify name
    mapM one cs
  where
    one (NormalC n fields) = pure (n, length fields)
    one (RecC n fields) = pure (n, length fields)
    one _ = fail "unsupported constructor form: extend the inventory extractor"

constructorSet :: Name -> Q Exp
constructorSet name = constructors name >>= listE . map (\(n, _) -> sigE (litE (stringL (nameBase n))) [t|String|])

constructorTag :: Name -> Q Exp
constructorTag name = do
    cs <- constructors name
    x <- newName "value"
    lamE
        [varP x]
        ( caseE
            (varE x)
            [match (conP n (replicate arity wildP)) (normalB (sigE (litE (stringL (nameBase n))) [t|String|])) [] | (n, arity) <- cs]
        )
