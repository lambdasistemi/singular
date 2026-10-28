{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- |
Module      : Singular.Application.OpenDatum.StateTokenSpec
Description : State-token parsing and reference-role declarations
License     : Apache-2.0

These rows check state-token arguments and the reference roles requested
by command values. Publication funding and directory resolution are checked
in "Singular.Application.OpenDatum.PublicationFundingSpec".
-}
module Singular.Application.OpenDatum.StateTokenSpec (spec) where

import Cardano.Ledger.Mary.Value
    ( AssetName (AssetName)
    , PolicyID (PolicyID)
    )
import Control.Monad (forM_)
import Data.ByteString.Base16 qualified as B16 (encode)
import Data.ByteString.Char8 qualified as BC (unpack)
import Data.ByteString.Short qualified as SBS (fromShort)
import Data.List (isInfixOf)
import Data.Set qualified as Set (empty, fromList, singleton)
import Data.Text qualified as T (isInfixOf, replicate)
import Singular.Application.OpenDatum.Command
    ( BookArgs (..)
    , CLIError (BadValue, MissingFlag)
    , EntryArgs (..)
    , EntryMode (..)
    , HoldingArgs (..)
    , Key (..)
    , OpenDatumCommand (..)
    , PendingArgs (..)
    , ProviderSettings (..)
    , RegistryAccess (..)
    , Signer (..)
    , StateFoldArgs (..)
    , WriteSettings (..)
    , neededRoles
    , parseOpenDatumCommand
    , parseOpenDatumCommandWithEnvironment
    )
import Singular.Application.OpenDatum.StateTokenFixture
    ( refOf
    , token
    , tokenOf
    )
import Singular.CLI.Registry (checkPendingToken)
import Singular.Registry.LedgerProvider qualified as LP (Asset)
import Singular.Registry.PlainJson (PayloadSchema (PlainSchema))
import Singular.Registry.StateToken (ReferenceRole (..))
import Singular.Registry.TxBuilder.Internal (scriptHashBytes)
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)

spec :: Spec
spec = do
    tokenOnEveryCommand
    rolesPerCommand

-- ---------------------------------------------------------------------------
-- The token on the command line
-- ---------------------------------------------------------------------------

provider :: [String]
provider =
    [ "--koios-url"
    , "http://127.0.0.1:8080/api/v1"
    , "--network-magic"
    , "42"
    ]

wallet :: [String]
wallet = ["--wallet-skey", "/keys/payment.skey"]

dirAndRelease :: [String]
dirAndRelease = ["--state-dir", "/srv/actor", "--blueprint", "/srv/plutus.json"]

-- | The token as a person copies it from the registry's page.
spelled :: LP.Asset -> String
spelled (PolicyID policy, AssetName name) =
    BC.unpack (B16.encode (scriptHashBytes policy))
        <> "."
        <> BC.unpack (B16.encode (SBS.fromShort name))

tokenFlag :: [String]
tokenFlag = ["--state-token", spelled token]

request :: String
request = replicate 64 '7' <> "#0"

-- | Each command but create, without its token.
commands :: [(String, [String])]
commands =
    [
        ( "registration book"
        , ["registration", "book", "--key", "k", "--payload", "/p.json"] <> rest
        )
    , ("state fold", ["state", "fold", "--pending", request] <> rest)
    ,
        ( "registration reclaim"
        , ["registration", "reclaim", "--pending", request] <> rest
        )
    ,
        ( "registration cleanup"
        , ["registration", "cleanup", "--pending", request] <> rest
        )
    ,
        ( "holding update"
        , ["holding", "update", "--holding", request, "--payload", "/p.json"]
            <> rest
        )
    ,
        ( "holding terminate"
        , ["holding", "terminate", "--holding", request] <> rest
        )
    ]
  where
    rest = dirAndRelease <> provider <> wallet

accessOf :: OpenDatumCommand -> Maybe RegistryAccess
accessOf = \case
    OpenRegistrationBook a -> Just (bookArgsAccess a)
    OpenStateFold a -> Just (stateFoldAccess a)
    OpenRegistrationReclaim a -> Just (pendingArgsAccess a)
    OpenRegistrationCleanup a -> Just (pendingArgsAccess a)
    OpenHoldingUpdate a _ _ -> Just (holdingArgsAccess a)
    OpenHoldingTerminate a -> Just (holdingArgsAccess a)
    _ -> Nothing

ours :: RegistryAccess
ours = RegistryAccess{accessToken = token}

tokenOnEveryCommand :: Spec
tokenOnEveryCommand = describe "the state token" $ do
    it "is required by every command but create, before anything is read" $
        forM_ commands $ \(_, line) -> do
            parseOpenDatumCommand line
                `shouldBe` Left (MissingFlag "--state-token")
            fmap accessOf (parseOpenDatumCommand (line <> tokenFlag))
                `shouldBe` Right (Just ours)
    it "is read from --state-token on each of them" $
        forM_ commands $ \(_, line) ->
            fmap accessOf (parseOpenDatumCommand (line <> tokenFlag))
                `shouldBe` Right (Just ours)
    it "is read from SINGULAR_STATE_TOKEN when the flag is absent" $
        forM_ commands $ \(_, line) ->
            fmap
                accessOf
                (parseOpenDatumCommandWithEnvironment [environment token] line)
                `shouldBe` Right (Just ours)
    it "is taken from the flag when both name one" $ do
        let other = tokenOf (refOf (T.replicate 64 "4" <> "#2"))
        forM_ commands $ \(_, line) ->
            fmap
                accessOf
                ( parseOpenDatumCommandWithEnvironment
                    [environment other]
                    (line <> tokenFlag)
                )
                `shouldBe` Right (Just ours)
    it
        "is refused by its flag when it is not POLICY.NAME in hex, and read when it is"
        $ forM_ commands
        $ \(_, line) -> do
            fmap accessOf (parseOpenDatumCommand (line <> tokenFlag))
                `shouldBe` Right (Just ours)
            forM_
                ["zz.zz", takeWhile (/= '.') (spelled token), spelled token <> "00"]
                $ \bad ->
                    parseOpenDatumCommand (line <> ["--state-token", bad])
                        `shouldSatisfy` badValueOf "--state-token"
    it "is refused on create, which makes one" $
        parseOpenDatumCommand
            ( ["state", "create", "--seed", request]
                <> dirAndRelease
                <> provider
                <> wallet
                <> tokenFlag
            )
            `shouldSatisfy` refusedNaming "--state-token" "create"
    it "reads an interrupted create only with its own state token" $ do
        let mismatched = \case
                Left reason ->
                    T.isInfixOf "pending" reason
                        || T.isInfixOf "mismatch" reason
                        || T.isInfixOf "state-token" reason
                Right () -> False
            other = tokenOf (refOf (T.replicate 64 "4" <> "#2"))
        checkPendingToken token token `shouldBe` Right ()
        checkPendingToken other token `shouldSatisfy` mismatched
        checkPendingToken token other `shouldSatisfy` mismatched
    it
        "is the only name of the registry: no command reads a reference hint"
        $ do
            let every = ("create", createLine) : commands
                hinted line =
                    parseOpenDatumCommand
                        ( line
                            <> tokenFlagFor line
                            <> ["--reference-hint", replicate 64 'a' <> "#1"]
                        )
            [(name, hinted line) | (name, line) <- every]
                `shouldBe` [ ( name
                             , Left (BadValue "--reference-hint" "is not a flag singular reads")
                             )
                           | (name, _) <- every
                           ]
  where
    environment t = ("SINGULAR_STATE_TOKEN", spelled t)
    createLine =
        ["state", "create", "--seed", request]
            <> dirAndRelease
            <> provider
            <> wallet
    tokenFlagFor line
        | "create" `elem` take 2 line = []
        | otherwise = tokenFlag

-- | A refusal of the flag whose reason names the word.
refusedNaming :: String -> String -> Either CLIError a -> Bool
refusedNaming flag word = \case
    Left (BadValue named reason) -> named == flag && word `isInfixOf` reason
    _ -> False

badValueOf :: String -> Either CLIError a -> Bool
badValueOf flag = \case
    Left (BadValue named _) -> named == flag
    _ -> False

-- ---------------------------------------------------------------------------
-- Roles per command
-- ---------------------------------------------------------------------------

rolesPerCommand :: Spec
rolesPerCommand = describe "the reference roles each internal preparation value needs" $ do
    let args =
            EntryArgs
                { entryStateDir = Nothing
                , entryAccess = ours
                , entryBlueprint = "/srv/plutus.json"
                , entryMode =
                    Submit
                        ( WriteSettings
                            (ProviderSettings "http://127.0.0.1:8080/api/v1" 42 Nothing Nothing)
                            (SignerKeyFile "/keys/payment.skey")
                            Nothing
                        )
                , entryKey = Key "k"
                , entryDocument = Just "/p.json"
                , entryPayloadSchema = PlainSchema
                , entryDeposit = Nothing
                , entryFund = Nothing
                , entryMaxOutlay = Nothing
                , entryReceipt = Nothing
                , entryFold = False
                }
        everything = Set.fromList [minBound .. maxBound]
    it
        "uses the application for each entry and all roles for a combined booking and fold"
        $ do
            neededRoles (OpenInsert args) `shouldBe` Set.singleton RoleApplication
            neededRoles (OpenUpdate args) `shouldBe` Set.singleton RoleApplication
            neededRoles (OpenTerminate args)
                `shouldBe` Set.singleton RoleApplication
            neededRoles (OpenInsert args{entryFold = True}) `shouldBe` everything
            neededRoles (OpenTerminate args{entryFold = True})
                `shouldBe` everything
    it
        "keeps the request-contract commands independent of the old reference roles"
        $ forM_ commands
        $ \(_, line) ->
            fmap neededRoles (parseOpenDatumCommand (line <> tokenFlag))
                `shouldBe` Right Set.empty
