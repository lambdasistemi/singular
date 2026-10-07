{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE TupleSections #-}

{- |
Module      : Singular.CLI.StateTokenSpec
Description : Commands run on the state token, from any directory
License     : Apache-2.0

Every registry command except create names the registry by its state
token, on the command line or in the environment, and may suggest
carriers of its reference scripts. Each command declares the reference
roles its transactions run, and looks up no other. A create checks that
the wallet funds every publication before it submits anything. An actor
whose directory is empty, or holds files from elsewhere, resolves the
same registry from the token alone.
-}
module Singular.CLI.StateTokenSpec (spec) where

import Control.Exception (ErrorCall (..), evaluate, try)
import Control.Monad (forM_)
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Short qualified as SBS
import Data.IORef (newIORef)
import Data.List (isInfixOf)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Lens.Micro ((^.))
import System.Directory (listDirectory)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.Api.Tx (bodyTxL, txIdTx)
import Cardano.Ledger.Api.Tx.Body (inputsTxBodyL, outputsTxBodyL)
import Cardano.Ledger.Api.Tx.Out (TxOut, mkBasicTxOut)
import Cardano.Ledger.BaseTypes (Network (Testnet), TxIx (..))
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Core (Script, hashScript)
import Cardano.Ledger.Mary.Value
    ( AssetName (..)
    , MaryValue (..)
    , PolicyID (..)
    )
import Cardano.Ledger.TxIn (TxIn (..))
import Data.Foldable (toList)

import Singular.CLI.Command
import Singular.CLI.Live (Saved (..), resolveSaved)
import Singular.CLI.Registry
    ( IdentityError (..)
    , checkPendingToken
    , publicationFunding
    , refuseExisting
    )
import Singular.Registry.Config (CageConfig (..))
import Singular.Registry.Ledger (ConwayEra, TokenId (..))
import Singular.Registry.LedgerProvider qualified as LP
import Singular.Registry.StateToken (ReferenceRole (..))
import Singular.Registry.StateTokenFixture
import Singular.Registry.StubSession
    ( stubSession
    , withAddressOutputs
    , withParameters
    , withTime
    )
import Singular.Registry.SyntheticTime (syntheticTime)
import Singular.Registry.TxBuilder.BookingFixture (preprodParams)
import Singular.Registry.TxBuilder.Edges (publishRefScriptTx)
import Singular.Registry.TxBuilder.Internal
    ( addrFromKeyHashBytes
    , scriptHashBytes
    )

spec :: Spec
spec = do
    tokenOnEveryCommand
    rolesPerCommand
    funding
    directories

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
dirAndRelease = ["--registry", "/srv/actor", "--blueprint", "/srv/plutus.json"]

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
        ( "insert"
        , ["registry", "insert", "--key", "k", "--payload", "/p.json"] <> rest
        )
    ,
        ( "update"
        , ["registry", "update", "--key", "k", "--payload", "/p.json"] <> rest
        )
    , ("terminate", ["registry", "terminate", "--key", "k"] <> rest)
    , ("fold", ["registry", "fold"] <> rest)
    , ("reject", ["registry", "reject"] <> rest)
    , ("reclaim", ["registry", "reclaim", "--request", request] <> rest)
    , ("inspect", ["registry", "inspect", "--key", "k"] <> restInspect)
    ]
  where
    rest = dirAndRelease <> provider <> wallet
    restInspect = dirAndRelease <> provider

accessOf :: Command -> Maybe RegistryAccess
accessOf = \case
    Insert a -> Just (entryAccess a)
    Update a -> Just (entryAccess a)
    Terminate a -> Just (entryAccess a)
    Fold a -> Just (foldAccess a)
    Reject a -> Just (rejectAccess a)
    Reclaim a -> Just (reclaimAccess a)
    Inspect a -> Just (inspectAccess a)
    _ -> Nothing

ours :: RegistryAccess
ours = RegistryAccess{accessToken = token, accessHints = []}

tokenOnEveryCommand :: Spec
tokenOnEveryCommand = describe "the state token" $ do
    it "is required by every command but create, before anything is read" $
        forM_ commands $ \(_, line) -> do
            parseCommand line `shouldBe` Left (MissingFlag "--state-token")
            fmap accessOf (parseCommand (line <> tokenFlag))
                `shouldBe` Right (Just ours)
    it "is read from --state-token on each of them" $
        forM_ commands $ \(_, line) ->
            fmap accessOf (parseCommand (line <> tokenFlag))
                `shouldBe` Right (Just ours)
    it "is read from SINGULAR_STATE_TOKEN when the flag is absent" $
        forM_ commands $ \(_, line) ->
            fmap accessOf (parseCommandWithEnvironment [environment token] line)
                `shouldBe` Right (Just ours)
    it "is taken from the flag when both name one" $ do
        let other = tokenOf (refOf (T.replicate 64 "4" <> "#2"))
        forM_ commands $ \(_, line) ->
            fmap
                accessOf
                (parseCommandWithEnvironment [environment other] (line <> tokenFlag))
                `shouldBe` Right (Just ours)
    it
        "is refused by its flag when it is not POLICY.NAME in hex, and read when it is"
        $ forM_ commands
        $ \(_, line) -> do
            fmap accessOf (parseCommand (line <> tokenFlag))
                `shouldBe` Right (Just ours)
            forM_
                ["zz.zz", takeWhile (/= '.') (spelled token), spelled token <> "00"]
                $ \bad ->
                    parseCommand (line <> ["--state-token", bad])
                        `shouldSatisfy` badValueOf "--state-token"
    it "is refused on create, which makes one" $
        parseCommand
            ( ["registry", "create", "--seed", request]
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
    it "carries repeatable reference hints in the order given" $ do
        let hints = [replicate 64 'a' <> "#1", replicate 64 'b' <> "#0"]
        forM_ commands $ \(_, line) ->
            fmap
                (fmap accessHints . accessOf)
                ( parseCommand
                    (line <> tokenFlag <> concatMap (\h -> ["--reference-hint", h]) hints)
                )
                `shouldBe` Right (Just (map (refOf . T.pack) hints))
    it "refuses a reference hint that is not TXID#IX" $
        forM_ commands $ \(_, line) ->
            parseCommand (line <> tokenFlag <> ["--reference-hint", "nothing"])
                `shouldSatisfy` badValueOf "--reference-hint"
  where
    environment t = ("SINGULAR_STATE_TOKEN", spelled t)

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
rolesPerCommand = describe "the reference roles each command's transactions run"
    $ it
        "are the application for a booking, every script for a fold, the state and request for a reject, none for a reclaim or an inspect"
    $ do
        let roles args = fmap neededRoles (parseCommand (args <> tokenFlag))
            everything = Set.fromList [minBound .. maxBound]
            line name = fromMaybe (error name) (lookup name commands)
        roles (line "insert") `shouldBe` Right (Set.singleton RoleApplication)
        roles (line "update") `shouldBe` Right (Set.singleton RoleApplication)
        roles (line "terminate")
            `shouldBe` Right (Set.singleton RoleApplication)
        roles (line "insert" <> ["--fold"]) `shouldBe` Right everything
        roles (line "terminate" <> ["--fold"]) `shouldBe` Right everything
        roles (line "fold") `shouldBe` Right everything
        roles (line "reject")
            `shouldBe` Right (Set.fromList [RoleState, RoleRequest])
        roles (line "reclaim") `shouldBe` Right Set.empty
        roles (line "inspect") `shouldBe` Right Set.empty
        fmap
            neededRoles
            ( parseCommand
                ( ["registry", "create", "--seed", request]
                    <> dirAndRelease
                    <> provider
                    <> wallet
                )
            )
            `shouldBe` Right (Set.singleton RoleState)

-- ---------------------------------------------------------------------------
-- Publication funding before the boot
-- ---------------------------------------------------------------------------

funding :: Spec
funding = describe "a create's publication funding" $ do
    let seed = refOf (T.replicate 64 "6" <> "#0")
        beforeBoot = take 1 bootScripts
        laterScripts = drop 1 bootScripts
        walletOf amounts =
            (seed, adaOnly 10_000_000)
                : [ (refOf (T.pack (replicate 63 'c' <> show i) <> "#0"), adaOnly a)
                  | (i, a) <- zip [0 :: Int ..] amounts
                  ]
    it "is accepted when the publisher can fund every publication" $ do
        let funded = walletOf [400_000_000]
        built <- publishAll seed beforeBoot laterScripts funded
        built `shouldBe` Nothing
        publicationFunding preprodParams seed beforeBoot laterScripts funded
            `shouldBe` Right ()
    it
        "is refused before anything is submitted, naming the first publication the publisher would refuse"
        $ do
            -- Outputs too small for the largest script, the application,
            -- published last: the publisher itself refuses it there.
            let small = walletOf (replicate 8 30_000_000)
            built <- publishAll seed beforeBoot laterScripts small
            built `shouldSatisfy` (== Just "application") . fmap fst
            case publicationFunding preprodParams seed beforeBoot laterScripts small of
                Left (PublicationUnfunded role _ largest) -> do
                    Just role `shouldBe` fmap fst built
                    largest `shouldBe` 30_000_000
                other -> expectationFailure ("not refused: " <> show other)
    it "never counts the seed toward a publication" $ do
        let onlySeedIsLarge = (seed, adaOnly 400_000_000) : drop 1 (walletOf [3_000_000])
        built <- publishAll seed beforeBoot laterScripts onlySeedIsLarge
        built `shouldSatisfy` (== Just "state") . fmap fst
        publicationFunding
            preprodParams
            seed
            beforeBoot
            laterScripts
            onlySeedIsLarge
            `shouldSatisfy` \case
                Left (PublicationUnfunded "state" _ _) -> True
                _ -> False

{- | Build every publication with the publisher create uses, in order,
against the wallet each leaves behind: its fund spent and its change
returned. The seed is reserved before the boot and spent by it. The role
the publisher refuses first, with its reason, or nothing.
-}
publishAll
    :: TxIn
    -> [(Text, Script ConwayEra)]
    -> [(Text, Script ConwayEra)]
    -> [(TxIn, TxOut ConwayEra)]
    -> IO (Maybe (Text, String))
publishAll seed earlier later = go (Set.singleton seed) (map tagged earlier)
  where
    tagged = (,) True
    go _ [] _ = pure Nothing
    go reserved ((isBefore, (role, script)) : rest) held = do
        let session =
                withParameters preprodParams $
                    withTime (pure syntheticTime) $
                        withAddressOutputs (const (pure held)) stubSession
        built <-
            try
                (publishRefScriptTx reserved session publisher script >>= evaluate)
        case built of
            Left (ErrorCall reason) -> pure (Just (role, reason))
            Right (tx, _) -> do
                let spent = tx ^. bodyTxL . inputsTxBodyL
                    produced =
                        [ (TxIn (txIdTx tx) (TxIx ix), o)
                        | (ix, o) <- zip [0 ..] (toList (tx ^. bodyTxL . outputsTxBodyL))
                        , ix == 1
                        ]
                    next = [u | u@(i, _) <- held, Set.notMember i spent] <> produced
                    following = case rest of
                        [] | isBefore -> map (False,) later
                        _ -> rest
                    afterBoot = isBefore && null rest
                go
                    (if afterBoot then Set.empty else reserved)
                    following
                    (if afterBoot then filter ((/= seed) . fst) next else next)

publisher :: Addr
publisher = addrFromKeyHashBytes Testnet (BC.replicate 28 'p')

adaOnly :: Integer -> TxOut ConwayEra
adaOnly n = mkBasicTxOut publisher (MaryValue (Coin n) mempty)

-- ---------------------------------------------------------------------------
-- Directories
-- ---------------------------------------------------------------------------

directories :: Spec
directories = describe "the actor's directory" $ do
    it
        "may be empty: the registry resolves from the token, and nothing is written"
        $ withSystemTempDirectory "actor"
        $ \dir -> do
            saved <- resolveIn dir
            savedToken saved `shouldBe` tokenId
            pinsOf (savedCfg saved) `shouldBe` pinsOf bootCfg
            map fst (savedRefs saved) `shouldBe` [carrierIn RoleApplication]
            listDirectory dir `shouldReturn` []
    it
        "is never an input: a registry.json from another registry changes nothing"
        $ withSystemTempDirectory "actor"
        $ \dir -> do
            writeFile
                (dir </> "registry.json")
                "{\"confDeployment\":{\"depCageToken\":\"00\"}}"
            saved <- resolveIn dir
            savedToken saved `shouldBe` tokenId
            pinsOf (savedCfg saved) `shouldBe` pinsOf bootCfg
            map fst (savedRefs saved) `shouldBe` [carrierIn RoleApplication]
    it
        "may hold a registry.json and still start a create; a journal or a pending identity refuse it"
        $ withSystemTempDirectory "actor"
        $ \dir -> do
            writeFile (dir </> "registry.json") "{}"
            refuseExisting dir `shouldReturn` Right ()
            writeFile (dir </> "journal.jsonl") ""
            refuseExisting dir
                >>= (`shouldSatisfy` either (const True) (const False))
  where
    tokenId = let (_, name) = token in TokenId name
    pinsOf c =
        [ cfgApplicationPolicy c
        , cfgActivePolicy c
        , cfgAbsentPolicy c
        , cfgTerminalPolicy c
        ]
    resolveIn dir = do
        logRef <- newIORef []
        let chain =
                honestChain
                    { chainOutputs =
                        Map.fromList
                            [(carrierIn role, carrierOf script) | (role, script) <- published]
                            <> chainOutputs honestChain
                    , chainCarriers = \h ->
                        [ (carrierIn role, carrierOf script)
                        | (role, script) <- published
                        , hashScript script == h
                        ]
                    }
        resolveSaved
            dir
            release
            ours
            (Set.singleton RoleApplication)
            []
            (chainSession logRef chain)

-- | The six published scripts by role.
published :: [(ReferenceRole, Script ConwayEra)]
published = zip [minBound .. maxBound] (map snd bootScripts)

carrierIn :: ReferenceRole -> TxIn
carrierIn role = refOf (T.pack (replicate 63 'e' <> show (fromEnum role)) <> "#0")
