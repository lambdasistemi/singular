{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.CLI.ManagedStateSpec
Description : #485 managed state: commands run without a directory argument
License     : Apache-2.0

Bob receives Carl's public state token and runs inspect, booking, fold and
readback with no directory argument and no pre-created per-registry state:
every existing-registry command works without @--state-dir@, which remains
only as an optional state-root override with the same identity partitioning.
A new participant's lack of files is never a refusal.

These rows run the effect-free parser over the real module. Each identity is
spelled inline; the token is a well-formed POLICY.NAME the real token reader
accepts. Resolver identity partitioning (network, complete token, stable
wallet identity) and the connected fresh-Bob proof are the track's next rows,
not these.
-}
module Singular.CLI.ManagedStateSpec (spec) where

import Data.Either (isLeft, isRight)
import Data.List (isInfixOf)
import Test.Hspec

import Singular.CLI.Command
    ( CLIError (..)
    , parseCommand
    , usage
    )

spec :: Spec
spec = describe "managed state command line (#485)" $ do
    directoryOptional
    rootOverride
    noWeakening

provider :: [String]
provider =
    [ "--koios-url"
    , "http://127.0.0.1:8080/api/v1"
    , "--network-magic"
    , "42"
    ]

wallet :: [String]
wallet = ["--wallet-skey", "/keys/payment.skey"]

-- | A well-formed state token POLICY.NAME: 28 policy bytes, 32 name bytes.
tokenSpelling :: String
tokenSpelling = replicate 56 'a' <> "." <> replicate 64 'b'

tokenArgs :: [String]
tokenArgs = ["--state-token", tokenSpelling]

seedText :: String
seedText = replicate 64 'b' <> "#1"

directoryOptional :: Spec
directoryOptional = describe "every command works without --state-dir" $ do
    it "create books from seed, blueprint, provider and wallet alone" $
        parseCommand
            ( ["registry", "create", "--seed", seedText, "--blueprint", "/srv/plutus.json"]
                <> provider
                <> wallet
            )
            `shouldSatisfy` isRight
    it "insert books from token, key, payload, provider and wallet alone" $
        parseCommand
            ( ["registry", "insert", "--key", "bob", "--payload", "/srv/doc.json", "--blueprint", "/srv/plutus.json"]
                <> tokenArgs
                <> provider
                <> wallet
            )
            `shouldSatisfy` isRight
    it "fold runs from token, provider and wallet alone" $
        parseCommand
            ( ["registry", "fold", "--blueprint", "/srv/plutus.json"]
                <> tokenArgs
                <> provider
                <> wallet
            )
            `shouldSatisfy` isRight
    it "inspect reads from token, key, blueprint and provider alone, key-free" $
        parseCommand
            ( ["registry", "inspect", "--key", "bob", "--blueprint", "/srv/plutus.json"]
                <> tokenArgs
                <> provider
            )
            `shouldSatisfy` isRight
    it "terminate books from token, key, provider and wallet alone" $
        parseCommand
            ( ["registry", "terminate", "--key", "bob", "--blueprint", "/srv/plutus.json"]
                <> tokenArgs
                <> provider
                <> wallet
            )
            `shouldSatisfy` isRight
    it "usage documents the managed default state location" $
        usage `shouldSatisfy` isInfixOf "XDG_STATE_HOME"

rootOverride :: Spec
rootOverride = describe "an explicit --state-dir stays a root override" $ do
    it "insert still accepts --state-dir" $
        parseCommand
            ( ["registry", "insert", "--key", "bob", "--payload", "/srv/doc.json", "--blueprint", "/srv/plutus.json", "--state-dir", "/srv/root"]
                <> tokenArgs
                <> provider
                <> wallet
            )
            `shouldSatisfy` isRight
    it "inspect still accepts --state-dir" $
        parseCommand
            ( ["registry", "inspect", "--key", "bob", "--blueprint", "/srv/plutus.json", "--state-dir", "/srv/root"]
                <> tokenArgs
                <> provider
            )
            `shouldSatisfy` isRight

noWeakening :: Spec
noWeakening = describe "no refusal is weakened" $ do
    it "still refuses --registry with its rename" $
        parseCommand
            ( ["registry", "inspect", "--key", "bob", "--blueprint", "b", "--registry", "/srv/reg"]
                <> provider
                <> tokenArgs
            )
            `shouldSatisfy` isLeftWithRename
    it "insert without a key is still refused" $
        parseCommand
            ( ["registry", "insert", "--payload", "/srv/doc.json", "--blueprint", "/srv/plutus.json"]
                <> tokenArgs
                <> provider
                <> wallet
            )
            `shouldSatisfy` isLeft
    it "insert without a state token is still refused" $
        parseCommand
            ( ["registry", "insert", "--key", "bob", "--payload", "/srv/doc.json", "--blueprint", "/srv/plutus.json"]
                <> provider
                <> wallet
            )
            `shouldSatisfy` isLeft
  where
    isLeftWithRename = \case
        Left (BadValue "--registry" _) -> True
        _ -> False
