{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Conformance.Cli.ManagedStateSpec
Description : The attach backend resolves the CLI managed layout
License     : Apache-2.0

The attach backend attributes journals to managed identity partitions
('Conformance.Cli.Backend.managedPartition'), bound here to the exact
spelling the production CLI resolves ('Singular.CLI.ManagedState'):
root, network, complete token and wallet payment identity. The token
comes from the production token reader, never retyped; the wallet
identity is fixed bytes, since key loading is the CLI's own unit cover.
-}
module Conformance.Cli.ManagedStateSpec (spec) where

import Data.ByteString qualified as BS
import Data.Either (isRight)
import Data.Text qualified as T
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)

import Conformance.Cli.Backend (managedPartition)
import Singular.Registry.StateToken (parseStateToken)

spec :: Spec
spec = describe "managed partitions" $ do
    it "spells the production managed layout" $ do
        asset <- either (fail . T.unpack) pure (parseStateToken tokenSpelling)
        managedPartition "/root" 42 asset (BS.replicate 28 0x09)
            `shouldBe` "/root/net-42/"
                <> policyHex
                <> "-"
                <> nameHex
                <> "/wallets/"
                <> walletHex
    it "separates wallets, tokens and networks" $ do
        asset <- either (fail . T.unpack) pure (parseStateToken tokenSpelling)
        other <- either (fail . T.unpack) pure (parseStateToken otherSpelling)
        let here = managedPartition "/root" 42 asset (BS.replicate 28 0x09)
        here
            `shouldSatisfy` (/= managedPartition "/root" 42 asset (BS.replicate 28 0x02))
        here
            `shouldSatisfy` (/= managedPartition "/root" 42 other (BS.replicate 28 0x09))
        here
            `shouldSatisfy` (/= managedPartition "/root" 43 asset (BS.replicate 28 0x09))
    it "accepts only well-formed token spellings" $
        parseStateToken "not-a-token" `shouldSatisfy` (not . isRight)
  where
    tokenSpelling = T.replicate 56 "a" <> "." <> T.replicate 64 "b"
    otherSpelling = T.replicate 56 "a" <> "." <> T.replicate 64 "c"
    policyHex = replicate 56 'a'
    nameHex = replicate 64 'b'
    walletHex = concat (replicate 28 "09")
