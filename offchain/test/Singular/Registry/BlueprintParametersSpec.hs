{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.Registry.BlueprintParametersSpec
Description : a validator's parameter count is read, never assumed
License     : Apache-2.0

A parameterless minting policy's compiled hash IS its policy id: there
is no applied hash to derive, one blueprint entry, one policy. The open
registry's application rests on that, and the packaged command reports
it, so the count has to be READ from the blueprint rather than written
down beside it.

A blueprint omits the @parameters@ array entirely for a parameterless
validator, so the reader has two branches — absent, and present with a
length. Both are exercised here. Without the non-zero case the reader
could be `const 0` and every row asserting "parameterless" would still
pass.
-}
module Singular.Registry.BlueprintParametersSpec (spec) where

import Data.Aeson (eitherDecode)
import Data.ByteString.Lazy qualified as BL
import Data.List (find)
import Test.Hspec

import Singular.Registry.Blueprint (Blueprint (..), Validator (..))

-- | Two entries: one with no `parameters` key, one with two of them.
blueprintJson :: BL.ByteString
blueprintJson =
    "{\"validators\":[\
    \{\"title\":\"open.open.mint\",\
    \\"redeemer\":{\"schema\":{}},\
    \\"hash\":\"aa\"},\
    \{\"title\":\"witness.witness.mint\",\
    \\"redeemer\":{\"schema\":{}},\
    \\"hash\":\"bb\",\
    \\"parameters\":[{\"title\":\"kind\",\"schema\":{}},\
    \{\"title\":\"registry\",\"schema\":{}}]}\
    \],\"definitions\":{}}"

paramsOf :: Blueprint -> String -> Maybe Int
paramsOf bp title =
    vParameters <$> find ((== title) . show . vTitle) (validators bp)

spec :: Spec
spec = describe "Blueprint parameter counts" $ do
    it "reads an absent parameters array as zero and a present one by its length" $
        case eitherDecode blueprintJson of
            Left err -> expectationFailure ("blueprint did not parse: " <> err)
            Right bp -> do
                -- The parameterless case: what makes a compiled hash a
                -- policy id.
                paramsOf bp "\"open.open.mint\"" `shouldBe` Just 0
                -- The non-zero case, which is what stops the reader from
                -- being `const 0`. Without it the row above passes for a
                -- reader that never looks at the blueprint at all.
                paramsOf bp "\"witness.witness.mint\"" `shouldBe` Just 2
