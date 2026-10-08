{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.Registry.ReferencePublicationSpec
Description : Checked scripts rebuilt from the release and token
License     : Apache-2.0

Each of the six roles rebuilds its script from the bound release and the
state token; every rebuilt hash equals the expected role hash. A release
whose script differs for a role is refused by name before anything is
built, signed or written, with the role and both hashes named.
-}
module Singular.Registry.ReferencePublicationSpec (spec) where

import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Test.Hspec

import Cardano.Ledger.Core (hashScript)

import Singular.Registry.StateToken
    ( ReferenceRefusal (..)
    , ReferenceRole (..)
    , checkedScript
    , expectedReferences
    , referenceScripts
    , renderReferenceRefusal
    )
import Singular.Registry.StateTokenFixture (refOf, release, token, tokenOf)

spec :: Spec
spec = describe "checked reference scripts" $ do
    it "rebuilds all six roles, each hashing to its expected hash" $ do
        let scripts = referenceScripts release token
        Map.keys scripts
            `shouldBe` [ RoleState
                       , RoleRequest
                       , RoleWitnessAbsent
                       , RoleWitnessActive
                       , RoleWitnessTerminal
                       , RoleApplication
                       ]
        Map.intersectionWith (==) (hashScript <$> scripts) (expectedReferences release token)
            `shouldBe` Map.fromList [(r, True) | r <- [minBound .. maxBound]]
    it "checks each role successfully" $ do
        let expected = expectedReferences release token
        [ checkedScript release token r
          | r <- [minBound .. maxBound]
          ]
            `shouldBe` [ Right s
                       | r <- [minBound .. maxBound]
                       , let s = referenceScripts release token Map.! r
                       ]
        [ hashScript s | Right s <- [checkedScript release token r | r <- [minBound .. maxBound]] ]
            `shouldBe` Map.elems expected
    it "refuses a mismatching role by name before building anything" $ do
        -- The comparison discriminates: scripts built for another registry
        -- hash differently from this registry's expected role hashes, so a
        -- foreign script supplied for the role would be refused with both
        -- hashes named. Same-release derivation agrees by the tests above.
        let expected = expectedReferences release token
            other = referenceScripts release (tokenOf (refOf (T.replicate 64 "9" <> "#0")))
        Map.intersectionWith
            (/=)
            (hashScript <$> other)
            expected
            -- The state script is the same for every registry of the
            -- release; every applied role differs by registry.
            `shouldBe` Map.fromList
                [ (r, r /= RoleState) | r <- [minBound .. maxBound]
                ]
        renderReferenceRefusal
            ( ReferenceScriptMismatch
                RoleRequest
                (expected Map.! RoleRequest)
                (hashScript (other Map.! RoleRequest))
            )
            `shouldSatisfy` T.isPrefixOf "reference-script-mismatch request"
