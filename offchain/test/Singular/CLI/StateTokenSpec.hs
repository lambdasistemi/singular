{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE ScopedTypeVariables #-}

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

import Control.Applicative ((<|>))
import Control.Exception
    ( ErrorCall (..)
    , SomeException
    , evaluate
    , try
    )
import Control.Monad (foldM, forM_)
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
import Cardano.Ledger.Api.Tx.Out (TxOut, addrTxOutL, mkBasicTxOut)
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
    , withResolvedOutputs
    , withTime
    )
import Singular.Registry.SyntheticLedger (withSyntheticCosts)
import Singular.Registry.SyntheticTime (syntheticTime)
import Singular.Registry.TxBuilder.BookingFixture (preprodParams)
import Singular.Registry.TxBuilder.Boot (bootCostBound, bootTokenFrom)
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
ours = RegistryAccess{accessToken = token}

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
    it
        "is the only name of the registry: no command reads a reference hint"
        $ do
            let every = ("create", createLine) : commands
                hinted line =
                    parseCommand
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
        ["registry", "create", "--seed", request]
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
    let beforeBoot = take 1 bootScripts
        laterScripts = drop 1 bootScripts
        walletOf amounts =
            (seedIn, adaOnly 10_000_000)
                : [ (refOf (T.pack (replicate 63 'c' <> show i) <> "#0"), adaOnly a)
                  | (i, a) <- zip [0 :: Int ..] amounts
                  ]
        preflight =
            publicationFunding
                preprodParams
                seedIn
                (bootCostBound preprodParams reusedCarrier)
    it "is accepted when the real create can fund every publication" $ do
        let funded = walletOf [400_000_000]
        createAll Nothing beforeBoot laterScripts funded
            `shouldReturn` Nothing
        preflight beforeBoot laterScripts funded `shouldBe` Right ()
    it
        "is refused before anything is submitted, naming the first publication the real create would fail"
        $ do
            let small = walletOf (replicate 8 30_000_000)
            failed <- createAll Nothing beforeBoot laterScripts small
            case preflight beforeBoot laterScripts small of
                Left (PublicationUnfunded role _ _) -> Just role `shouldBe` failed
                other -> expectationFailure ("not refused: " <> show other)
    it "never counts the seed toward a publication" $ do
        let onlySeedIsLarge = (seedIn, adaOnly 400_000_000) : drop 1 (walletOf [3_000_000])
        createAll Nothing beforeBoot laterScripts onlySeedIsLarge
            `shouldReturn` Just "state"
        preflight beforeBoot laterScripts onlySeedIsLarge
            `shouldSatisfy` \case
                Left (PublicationUnfunded "state" _ _) -> True
                _ -> False
    it
        "never accepts a wallet the real create cannot fund, when the state script is published first"
        $ do
            let walletWith x = [(seedIn, adaOnly 2_000_000), (fundIn, adaOnly x)]
                accepted x = preflight beforeBoot laterScripts (walletWith x) == Right ()
                lowest = smallest accepted 1_000_000 1_000_000_000
            createAll Nothing beforeBoot laterScripts (walletWith lowest)
                `shouldReturn` Nothing
    it
        "never accepts a wallet the real create cannot fund, when a live state carrier is reused"
        $ do
            let walletWith x = [(seedIn, adaOnly 2_000_000), (fundIn, adaOnly x)]
                accepted x = preflight [] laterScripts (walletWith x) == Right ()
                lowest = smallest accepted 1_000_000 1_000_000_000
            createAll (Just reusedCarrier) [] laterScripts (walletWith lowest)
                `shouldReturn` Nothing
    it
        "counts what the boot returns of the seed toward the publications after it"
        $ do
            let seedRich = [(seedIn, adaOnly 400_000_000), (fundIn, adaOnly 3_000_000)]
            createAll (Just reusedCarrier) [] laterScripts seedRich
                `shouldReturn` Nothing
            preflight [] laterScripts seedRich `shouldBe` Right ()
  where
    fundIn = refOf (T.replicate 64 "c" <> "#9")
    -- A live carrier of the state script, published by someone else.
    reusedCarrier = case bootScripts of
        (_, stateScript) : _ ->
            (refOf (T.replicate 64 "e" <> "#7"), carrierOf stateScript)
        [] -> error "the fixture publishes no state script"

-- | The smallest value in the range satisfying a monotone predicate.
smallest :: (Integer -> Bool) -> Integer -> Integer -> Integer
smallest holds low high
    | low >= high = high
    | holds middle = smallest holds low middle
    | otherwise = smallest holds (middle + 1) high
  where
    middle = (low + high) `div` 2

{- | Run a create's transactions with the real builders, in order: the
publications before the boot, the seed reserved; the boot, from the state
carrier; the publications after it. Each runs against the wallet the ones
before it left: the inputs it spent removed and its outputs to the
publisher added, so a boot's own spending reaches the publications after
it. The role whose transaction a builder refuses first, @boot@ for the
boot, or nothing.
-}
createAll
    :: Maybe (TxIn, TxOut ConwayEra)
    -- ^ A live state carrier the create reuses, or none
    -> [(Text, Script ConwayEra)]
    -> [(Text, Script ConwayEra)]
    -> [(TxIn, TxOut ConwayEra)]
    -> IO (Maybe Text)
createAll reused earlier later wallet0 = do
    first <- publishing (Set.singleton seedIn) earlier wallet0
    case first of
        Left role -> pure (Just role)
        Right (wallet1, carriers) -> case reused <|> lookup "state" carriers of
            Nothing -> pure (Just "state")
            Just stateRef -> do
                booted <-
                    try
                        ( bootTokenFrom
                            bootCfg
                            stateRef
                            (sessionOver (stateRef : wallet1) wallet1)
                            publisher
                            >>= evaluate
                        )
                case booted of
                    Left (_ :: SomeException) -> pure (Just "boot")
                    Right tx -> do
                        rest <- publishing Set.empty later (applied tx wallet1)
                        pure (either Just (const Nothing) rest)
  where
    publishing reserved scripts held = foldM step (Right (held, [])) scripts
      where
        step (Left role) _ = pure (Left role)
        step (Right (w, made)) (role, script) = do
            built <-
                try
                    ( publishRefScriptTx reserved (sessionOver w w) publisher script
                        >>= evaluate
                    )
            pure $ case built of
                Left (ErrorCall _) -> Left role
                Right (tx, refOut) ->
                    Right
                        (applied tx w, (role, (TxIn (txIdTx tx) (TxIx 0), refOut)) : made)
    sessionOver known held =
        withParameters (withSyntheticCosts preprodParams) $
            withTime (pure syntheticTime) $
                withAddressOutputs (const (pure held)) $
                    withResolvedOutputs
                        (\wanted -> pure [u | u@(i, _) <- known, i `Set.member` wanted])
                        stubSession
    applied tx held =
        [ u | u@(i, _) <- held, Set.notMember i (tx ^. bodyTxL . inputsTxBodyL)
        ]
            <> [ (TxIn (txIdTx tx) (TxIx ix), o)
               | (ix, o) <- zip [0 ..] (toList (tx ^. bodyTxL . outputsTxBodyL))
               , o ^. addrTxOutL == publisher
               ]

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
            Nothing
            (chainSession logRef chain)

-- | The six published scripts by role.
published :: [(ReferenceRole, Script ConwayEra)]
published = zip [minBound .. maxBound] (map snd bootScripts)

carrierIn :: ReferenceRole -> TxIn
carrierIn role = refOf (T.pack (replicate 63 'e' <> show (fromEnum role)) <> "#0")
