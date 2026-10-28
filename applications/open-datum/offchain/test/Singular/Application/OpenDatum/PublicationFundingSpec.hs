{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- |
Module      : Singular.Application.OpenDatum.PublicationFundingSpec
Description : Publication funding and actor directories through library functions
License     : Apache-2.0
-}
module Singular.Application.OpenDatum.PublicationFundingSpec (spec) where

import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.Api.Tx (bodyTxL, txIdTx)
import Cardano.Ledger.Api.Tx.Body (inputsTxBodyL, outputsTxBodyL)
import Cardano.Ledger.Api.Tx.Out
    ( TxOut
    , addrTxOutL
    , mkBasicTxOut
    )
import Cardano.Ledger.BaseTypes (Network (Testnet), TxIx (..))
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Core (Script, hashScript)
import Cardano.Ledger.Mary.Value (MaryValue (MaryValue))
import Cardano.Ledger.TxIn (TxIn (..))
import Control.Applicative ((<|>))
import Control.Exception
    ( ErrorCall (..)
    , SomeException
    , evaluate
    , try
    )
import Control.Monad (foldM)
import Data.ByteString.Char8 qualified as BC (replicate)
import Data.Foldable (toList)
import Data.IORef (newIORef)
import Data.Map.Strict qualified as Map (fromList)
import Data.Set qualified as Set
    ( empty
    , member
    , notMember
    , singleton
    )
import Data.Text (Text)
import Data.Text qualified as T (pack, replicate)
import Lens.Micro ((^.))
import Singular.Application.OpenDatum.StateTokenFixture
    ( Chain (chainCarriers, chainOutputs)
    , bootCfg
    , bootScripts
    , carrierOf
    , chainSession
    , honestChain
    , refOf
    , release
    , seedIn
    , token
    )
import Singular.Application.OpenDatum.Value
    ( openDatumApplication
    )
import Singular.CLI.Command
    ( RegistryAccess (..)
    )
import Singular.CLI.Live (Saved (..), resolveSaved)
import Singular.CLI.Registry
    ( IdentityError (PublicationUnfunded)
    , publicationFunding
    , refuseExisting
    )
import Singular.Registry.Config (CageConfig (..))
import Singular.Registry.Ledger (ConwayEra, TokenId (..))
import Singular.Registry.StateToken (ReferenceRole (..))
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
import Singular.Registry.TxBuilder.Boot
    ( bootCostBound
    , bootTokenFrom
    )
import Singular.Registry.TxBuilder.Edges (publishRefScriptTx)
import Singular.Registry.TxBuilder.Internal
    ( addrFromKeyHashBytes
    )
import System.Directory (listDirectory)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec
    ( Spec
    , describe
    , expectationFailure
    , it
    , shouldBe
    , shouldReturn
    , shouldSatisfy
    )

spec :: Spec
spec = do
    funding
    directories

ours :: RegistryAccess
ours = RegistryAccess{accessToken = token}

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
            -- Probe a tiny wallet for the first publication's need, then build an
            -- eight-output wallet just short of it in permitted total (amounts
            -- from the producer, never typed; seed withheld for publications).
            -- Several-input funding still cannot cover the first step, so both
            -- sides name it without reaching the boot bound conservatism.
            stateNeed <- case preflight beforeBoot laterScripts (walletOf [1_000_000]) of
                Left (PublicationUnfunded _ need _) -> pure need
                other -> expectationFailure ("probe not refused: " <> show other) >> pure 0
            let shortEach = (stateNeed - 1) `div` 8
                short = walletOf (replicate 8 shortEach)
            failed <- createAll Nothing beforeBoot laterScripts short
            case preflight beforeBoot laterScripts short of
                Left (PublicationUnfunded role _ _) -> Just role `shouldBe` failed
                other -> expectationFailure ("not refused: " <> show other)
    it
        "accepts the eight-output wallet that single-output funding refused"
        $ do
            let accepted = walletOf (replicate 8 30_000_000)
            createAll Nothing beforeBoot laterScripts accepted
                `shouldReturn` Nothing
            preflight beforeBoot laterScripts accepted `shouldBe` Right ()
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
            openDatumApplication
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
