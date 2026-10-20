{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.Registry.TxBuilder.RetractFundingSpec
Description : #300 — a retraction is funded and collateralised by an output that can carry it
License     : Apache-2.0

The retraction reclaims a refused request's bond, so on a permanent registry
it runs every time a refusal leaves one behind. It is funded and
collateralised by one wallet output, and a wallet that also holds a larger
output carrying a token or a published script must not lose or fail on it:
the funding output holds ada and nothing else and is not a reference
publication. Whatever it funds, the retraction states its total collateral
and returns the rest, pays the ledger's fee and leaves every output its
minimum. Expected values come from the wallet the generator drew and the
ledger's own functions under the public preprod parameters.
-}
module Singular.Registry.TxBuilder.RetractFundingSpec (spec) where

import Control.Exception (SomeException, displayException, try)
import Data.List (isInfixOf, maximumBy)
import Data.Map.Strict qualified as Map
import Data.Ord (comparing)
import Data.Text qualified as T
import Lens.Micro ((&), (.~), (^.))
import PlutusCore.Data qualified as PLC
import Test.Hspec
import Test.QuickCheck
    ( Gen
    , chooseInteger
    , conjoin
    , forAll
    , ioProperty
    , listOf1
    , property
    , (===)
    )

import Cardano.Ledger.Allegra.Scripts (ValidityInterval (..))
import Cardano.Ledger.Api.Tx (bodyTxL)
import Cardano.Ledger.Api.Tx.Body (vldtTxBodyL)
import Cardano.Ledger.Api.Tx.Out
    ( TxOut
    , datumTxOutL
    , mkBasicTxOut
    , referenceScriptTxOutL
    )
import Cardano.Ledger.BaseTypes
    ( Network (Testnet)
    , SlotNo (..)
    , StrictMaybe (..)
    )
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Mary.Value
    ( AssetName (..)
    , MaryValue (..)
    , MultiAsset (..)
    , PolicyID (..)
    )
import Cardano.Ledger.TxIn (TxIn)
import Cardano.Tx.Ledger (ConwayTx)

import Data.ByteString qualified as BS
import Data.ByteString.Short qualified as SBS
import Data.Set qualified as Set
import Singular.Registry.Config (CageConfig (..), bootStateFromCfg)
import Singular.Registry.Deployment (parseOutRef)
import Singular.Registry.Evidence (NoWitness)
import Singular.Registry.Ledger (ConwayEra, Root (..), TokenId (..))
import Singular.Registry.LedgerProvider (Session, TipObservation (..))
import Singular.Registry.NetworkTime (NetworkTimeFailure (..))
import Singular.Registry.SessionIO qualified as SessionIO
import Singular.Registry.StubSession
import Singular.Registry.SyntheticLedger
    ( unitProgram
    , withSyntheticCosts
    )
import Singular.Registry.SyntheticTime
    ( syntheticTime
    , syntheticTimeWith
    )
import Singular.Registry.Trie (Trie (getRoot), TrieManager (..))
import Singular.Registry.Trie.PureManager (mkPureTrieManagerFrom)
import Singular.Registry.TxBuilder.BookingFixture
    ( applicationScript
    , payer
    , preprodParams
    , tokenId
    )
import Singular.Registry.TxBuilder.BookingFixture qualified as Fixture
import Singular.Registry.TxBuilder.CollateralJudgement
    ( Spend (..)
    , judgeCollateral
    )
import Singular.Registry.TxBuilder.ConnectedFold
    ( ConnectedFoldArgs (..)
    , ConnectedMint (..)
    , RawRedeemer (..)
    , connectedFoldTx
    )
import Singular.Registry.TxBuilder.Internal
    ( cageAddrFromCfg
    , cagePolicyIdFromCfg
    , computeScriptHash
    , currentPosixMs
    , emptyRoot
    , mkInlineDatum
    , mkRequestDatumWith
    , onChainTokenId
    , policyIdFromPin
    , requestAddrFromCfg
    , requestPolicyOf
    , toPlcData
    , walkEdge
    )
import Singular.Registry.TxBuilder.Retract
    ( retractRequestAtTipImpl
    , retractRequestImpl
    )
import Singular.Registry.Types
    ( CageDatum (..)
    , OnChainRoot (..)
    , OnChainTerminationRequest (..)
    , edgeInsertActive
    , terminationTrieReadyTagName
    )

-- The state witness consumes one V3 context; the request pin consumes two
-- parameters followed by its context. These are explicit synthetic scripts,
-- evaluated by the local ledger evaluator rather than mocked units.
cfg :: CageConfig
cfg =
    Fixture.cfg
        { cageScriptBytes = unitProgram 1
        , cfgScriptHash = computeScriptHash (unitProgram 1)
        , requestScriptBytes = unitProgram 3
        }

txIn :: Char -> Int -> TxIn
txIn c i =
    either
        (error . ("RetractFundingSpec fixture: " <>))
        id
        (parseOutRef (T.pack (replicate 64 c <> "#" <> show i)))

requestIn, stateIn, tokenHeldIn, publicationIn :: TxIn
requestIn = txIn 'a' 0
stateIn = txIn 'b' 0
tokenHeldIn = txIn 'c' 0
publicationIn = txIn 'd' 0

-- | The bond the request locks: its tip and deposit.
bond :: Integer
bond = 3_000_000

-- | The request script's address and the pending request, submitted at a time.
requestOut :: Integer -> TxOut ConwayEra
requestOut submittedAt =
    mkBasicTxOut
        (requestAddrFromCfg cfg tokenId Testnet)
        (MaryValue (Coin bond) mempty)
        & datumTxOutL
            .~ mkInlineDatum
                ( mkRequestDatumWith
                    tokenId
                    payer
                    "a-key"
                    1
                    2_000_000
                    submittedAt
                    ("", Nothing)
                )

stateOut :: TxOut ConwayEra
stateOut = stateOutWith (OnChainRoot emptyRoot)

-- | The registry's state output carrying a root.
stateOutWith :: OnChainRoot -> TxOut ConwayEra
stateOutWith root =
    let TokenId name = tokenId
    in  mkBasicTxOut
            (cageAddrFromCfg cfg Testnet)
            ( MaryValue
                (Coin 2_000_000)
                ( MultiAsset
                    (Map.singleton (cagePolicyIdFromCfg cfg) (Map.singleton name 1))
                )
            )
            & datumTxOutL
                .~ mkInlineDatum
                    (toPlcData (StateDatum (bootStateFromCfg cfg root)))

-- | A larger output holding a token, and a larger one publishing a script.
tokenHeldOut, publicationOut :: Integer -> TxOut ConwayEra
tokenHeldOut lovelace =
    mkBasicTxOut
        payer
        ( MaryValue
            (Coin lovelace)
            ( MultiAsset
                ( Map.singleton
                    (PolicyID (cfgScriptHash cfg))
                    (Map.singleton (AssetName "approval") 1)
                )
            )
        )
publicationOut lovelace =
    mkBasicTxOut payer (MaryValue (Coin lovelace) mempty)
        & referenceScriptTxOutL
            .~ SJust applicationScript

data Scenario = Scenario
    { scAda :: [Integer]
    -- ^ the ada-only outputs
    , scTrap :: Integer
    -- ^ how much more than the largest ada-only output the traps hold
    }
    deriving stock (Show)

genScenario :: Gen Scenario
genScenario =
    Scenario
        <$> listOf1 (chooseInteger (9_000_000, 12_000_000_000))
        <*> chooseInteger (1_000_000, 5_000_000_000)

wallet :: Scenario -> [(TxIn, TxOut ConwayEra)]
wallet sc =
    [ (txIn 'e' i, mkBasicTxOut payer (MaryValue (Coin l) mempty))
    | (i, l) <- zip [0 ..] (scAda sc)
    ]
        <> [ (tokenHeldIn, tokenHeldOut (largest sc + scTrap sc))
           , (publicationIn, publicationOut (largest sc + scTrap sc + 1))
           ]

largest :: Scenario -> Integer
largest = maximum . scAda

-- | The output the design funds from: the largest that is ada-only and no publication.
fundingOf :: Scenario -> (TxIn, Integer)
fundingOf sc =
    maximumBy
        (comparing snd)
        [(txIn 'e' i, l) | (i, l) <- zip [0 ..] (scAda sc)]

chainView
    :: Scenario -> Integer -> Maybe Integer -> Session NoWitness IO
chainView sc submittedAt =
    chainViewOver
        [(requestIn, requestOut submittedAt)]
        stateOut
        sc
        submittedAt

{- | A view over a registry holding the given pending requests and the given
state output, with the wallet the scenario drew.
-}
chainViewOver
    :: [(TxIn, TxOut ConwayEra)]
    -> TxOut ConwayEra
    -> Scenario
    -> Integer
    -> Maybe Integer
    -> Session NoWitness IO
chainViewOver requests state sc submittedAt horizon =
    withTip
        ( TipObservation
            ( SlotNo
                (fromInteger ((submittedAt + defaultProcessTime cfg + 999) `div` 1000))
            )
            (BS.replicate 32 0)
            1
            0
        )
        $ withAddressOutputs
            ( \addr ->
                pure $
                    if addr == requestAddrFromCfg cfg tokenId Testnet
                        then requests
                        else
                            if addr == cageAddrFromCfg cfg Testnet
                                then [(stateIn, state)]
                                else wallet sc
            )
            ( withParameters (withSyntheticCosts preprodParams)
                $ withTime
                    ( pure $ case horizon of
                        Nothing -> syntheticTime
                        Just limit -> syntheticTimeWith 0 1 (fromIntegral (limit `div` 1000 + 1))
                    )
                $ withResolvedOutputs
                    ( \wanted ->
                        pure
                            [ (reference, output)
                            | (reference, output) <-
                                requests <> ((stateIn, state) : wallet sc)
                            , reference `Set.member` wanted
                            ]
                    )
                    stubSession
            )

spec :: Spec
spec = do
    foldValidity
    retractValidity
    retractFunding

{- | These rows inspect the actual body of the fold of a termination, which
has no window: like the reject that the fold replaced, it is admitted in every
window, so its validity starts at the acquired view's tip and the clock
chooses only the upper bound. Scripts and evaluation are fixtures (the
evaluation is skipped), so this establishes builder bounds rather than node
acceptance.
-}
foldValidity :: Spec
foldValidity = describe
    "a termination fold's validity starts at the acquired view's tip"
    $ do
        it "caps the reached tip-868 build window before the ledger horizon" $ do
            now <- currentPosixMs
            let start = now - 86_800
            (world, base) <- foldWorld (SlotNo 868) Nothing
            let view = withTime (pure (syntheticTimeWith start (1 / 10) 500)) base
            tx <- terminationFold world view
            let ValidityInterval lower upper = tx ^. bodyTxL . vldtTxBodyL
            lower `shouldBe` SJust (SlotNo 868)
            -- k=10, f=1, epoch 500: the first boundary at/after 868+30 is 1000.
            upper `shouldBe` SJust (SlotNo 999)
        it "never starts ahead of a tip lagging the host clock" $
            property $
                forAll (chooseInteger (1, 600)) $ \lag -> ioProperty $ do
                    now <- currentPosixMs
                    (world, view) <- foldWorld (slotOf (now - lag * 1000)) Nothing
                    tip <- observedSlot <$> SessionIO.tip view
                    tx <- terminationFold world view
                    let ValidityInterval lower upper = tx ^. bodyTxL . vldtTxBodyL
                    pure $
                        conjoin
                            [ property (lower <= SJust tip)
                            , lower === SJust tip
                            , property (upper > lower)
                            ]
        it
            "refuses a window with no usable slot after a tip ahead of the host clock"
            $ do
                now <- currentPosixMs
                (world, view) <- foldWorld (slotOf (now + 300_000)) Nothing
                actualTip <- SessionIO.tip view
                terminationFold world view
                    `shouldThrow` ( \case
                                        WindowPastLedgerHorizon tip _ lower upper ->
                                            tip == observedSlot actualTip
                                                && lower == Just tip
                                                && upper == tip + 1
                                        _ -> False
                                  )
        it
            "caps the requested upper-bound window at the ledger horizon from its observed tip"
            $ do
                now <- currentPosixMs
                (world, view) <-
                    foldWorld (slotOf (now - 36_000)) (Just (now + 10_000))
                actualTip <- SessionIO.tip view
                tx <- terminationFold world view
                let ValidityInterval lower upper = tx ^. bodyTxL . vldtTxBodyL
                lower `shouldBe` SJust (observedSlot actualTip)
                upper `shouldSatisfy` (> lower)
                -- Here tip+30s is still in the synthetic epoch ending just
                -- beyond now+10s, so the moving cap is its last slot.
                upper `shouldBe` SJust (slotOf (now + 10_000))
        it
            "builds a nonempty fold interval when the tip is beyond the captured horizon"
            $ do
                now <- currentPosixMs
                let tip = slotOf (now + 11_000)
                (world, view) <- foldWorld tip (Just (now + 10_000))
                tx <- terminationFold world view
                let ValidityInterval lower upper = tx ^. bodyTxL . vldtTxBodyL
                lower `shouldBe` SJust tip
                upper `shouldSatisfy` (> lower)
        it
            "allows an upper bound raised past the captured horizon while preserving a nonempty interval"
            $ do
                now <- currentPosixMs
                let tip = slotOf (now + 10_000)
                (world, view) <- foldWorld tip (Just (now + 10_000))
                tx <- terminationFold world view
                let ValidityInterval lower upper = tx ^. bodyTxL . vldtTxBodyL
                lower `shouldBe` SJust tip
                upper `shouldSatisfy` (> lower)
  where
    slotOf ms = SlotNo (fromInteger (ms `div` 1000))

-- | The key the fold terminates, active in the registry's trie.
foldedKey :: BS.ByteString
foldedKey = "a-key"

-- | The booked termination of that key, holding its singular tag and its trie-ready tag.
terminationRequest :: OnChainTerminationRequest
terminationRequest =
    OnChainTerminationRequest
        { termRegistry = onChainTokenId tokenId
        , termKey = foldedKey
        , termDestination = BS.empty
        , termDeclaredTip = 1_500_000
        , termCarrierAda = 1_500_000
        , termNonce = 1
        }

terminationRequestOut :: TxOut ConwayEra
terminationRequestOut =
    mkBasicTxOut
        (requestAddrFromCfg cfg tokenId Testnet)
        ( MaryValue
            (Coin bond)
            ( MultiAsset
                ( Map.fromList
                    [
                        ( requestPolicyOf cfg tokenId
                        , Map.singleton
                            ( AssetName
                                (SBS.toShort (terminationTrieReadyTagName terminationRequest))
                            )
                            1
                        )
                    ,
                        ( policyIdFromPin (cfgActivePolicy cfg)
                        , Map.singleton (AssetName (SBS.toShort foldedKey)) 1
                        )
                    ]
                )
            )
        )
        & datumTxOutL
            .~ mkInlineDatum (toPlcData (TerminationDatum terminationRequest))

{- | A registry holding the one pending termination, its trie holding the key
active, seen from a tip: the trie manager the fold proves against, and the
view.
-}
foldWorld
    :: SlotNo
    -> Maybe Integer
    -> IO ((TrieManager IO, OnChainRoot), Session NoWitness IO)
foldWorld tip horizon = do
    (manager, _) <- mkPureTrieManagerFrom Map.empty
    createTrie manager tokenId
    root <- withTrie manager tokenId $ \trie -> do
        _ <- walkEdge trie foldedKey edgeInsertActive
        getRoot trie
    let stated = OnChainRoot (unRoot root)
        view =
            chainViewOver
                [(requestIn, terminationRequestOut)]
                (stateOutWith stated)
                (Scenario [100_000_000] 1_000_000)
                1_000
                horizon
    pure
        ( (manager, stated)
        , withTip (TipObservation tip (BS.replicate 32 0) 1 0) view
        )

-- | The fold of the pending termination built over a view, with the singular burn it owes.
terminationFold
    :: (TrieManager IO, OnChainRoot) -> Session NoWitness IO -> IO ConwayTx
terminationFold (manager, root) view =
    fst
        <$> connectedFoldTx
            ConnectedFoldArgs
                { cfaCfg = cfg
                , cfaSession = view
                , cfaTrie = manager
                , cfaToken = tokenId
                , cfaFeeAddr = payer
                , cfaStateUtxo = (stateIn, stateOutWith root)
                , cfaReqUtxos = [(requestIn, terminationRequestOut)]
                , cfaFeeUtxo =
                    ( fst funding
                    , mkBasicTxOut payer (MaryValue (Coin (snd funding)) mempty)
                    )
                , cfaSpends = []
                , cfaMints =
                    [ ConnectedMint
                        { cmPolicy = policyIdFromPin (cfgActivePolicy cfg)
                        , cmAssets = Map.singleton (AssetName (SBS.toShort foldedKey)) (-1)
                        , cmRedeemer = RawRedeemer (PLC.Constr 0 [])
                        , cmScript = applicationScript
                        }
                    ]
                , cfaOutputs = []
                , cfaSigners = []
                , cfaRefUtxos = []
                , cfaAttachScripts = []
                , cfaSkipEval = True
                , cfaAdjustRoot = id
                }
  where
    funding = fundingOf (Scenario [100_000_000] 1_000_000)

{- | Both public entry points must refuse a future lower bound rather
than return a transaction the acquired ledger cannot accept yet.
-}
retractValidity :: Spec
retractValidity = describe "a retraction never starts ahead of its acquired view" $ do
    it
        "refuses when phase two opens after the view tip, through either entry point"
        $ property
        $ forAll (chooseInteger (0, 30))
        $ \tip -> ioProperty $ do
            let view = atTip (SlotNo (fromInteger tip))
            actualTip <- SessionIO.tip view
            mapM_
                refuses
                [ retractRequestImpl cfg view tokenId requestIn payer
                , retractRequestAtTipImpl
                    (observedSlot actualTip)
                    cfg
                    view
                    tokenId
                    requestIn
                    payer
                ]
            pure True
    it "refuses a caller-supplied lower bound ahead of the acquired tip" $ do
        let view = atTip (SlotNo 40)
        refuses
            (retractRequestAtTipImpl (SlotNo 41) cfg view tokenId requestIn payer)
    it "admits phase two's opening slot through either entry point" $ do
        let view = atTip (SlotNo 31)
        actualTip <- SessionIO.tip view
        mapM_
            ( \build -> do
                tx <- build
                let ValidityInterval lower upper = tx ^. bodyTxL . vldtTxBodyL
                lower `shouldBe` SJust (observedSlot actualTip)
                upper `shouldSatisfy` (> lower)
            )
            [ retractRequestImpl cfg view tokenId requestIn payer
            , retractRequestAtTipImpl
                (observedSlot actualTip)
                cfg
                view
                tokenId
                requestIn
                payer
            ]
  where
    atTip tip =
        let view = chainView (Scenario [100_000_000] 1_000_000) 1_000 Nothing
        in  withTip (TipObservation tip (BS.replicate 32 0) 1 0) view
    refuses build = do
        result <- try @SomeException build
        case result of
            Left err ->
                displayException err
                    `shouldSatisfy` isInfixOf "lower-bound-ahead-of-view"
            Right tx -> do
                let interval = tx ^. bodyTxL . vldtTxBodyL
                expectationFailure ("built a future retraction: " <> show interval)

retractFunding :: Spec
retractFunding =
    describe
        "a retraction is funded and collateralised by an output that can carry it (#300)"
        $ do
            it
                "funds from the largest ada-only output, never a larger token or publication, and states its collateral"
                $ property
                $ forAll genScenario
                $ \sc -> ioProperty $ do
                    tx <-
                        retractRequestAtTipImpl
                            (SlotNo 0)
                            cfg
                            (chainView sc 1_000 Nothing)
                            tokenId
                            requestIn
                            payer
                    let (funding, fundingValue) = fundingOf sc
                        spend =
                            Spend
                                { spInputs = [(requestIn, bond), (funding, fundingValue)]
                                , spFunding = funding
                                , spRefBytes = 0
                                }
                    pure (judgeCollateral spend tx === [])
            it
                "is built with a validity bound inside its window when the window's end is past the node's horizon"
                $ property
                $ forAll genScenario
                $ \sc -> ioProperty $ do
                    now <- currentPosixMs
                    let processTime = defaultProcessTime cfg
                        retractTime = defaultRetractTime cfg
                        -- phase 2 opened a second ago; the node translates nothing
                        -- more than ten seconds ahead
                        submittedAt = now - processTime - 1_000
                        windowEnd = submittedAt + processTime + retractTime
                        windowStart = submittedAt + processTime
                    tx <-
                        retractRequestAtTipImpl
                            (SlotNo 0)
                            cfg
                            (chainView sc submittedAt (Just (now + 10_000)))
                            tokenId
                            requestIn
                            payer
                    let ValidityInterval lower upper = tx ^. bodyTxL . vldtTxBodyL
                        secondsOf ms = fromIntegral (ms `div` 1000) :: Integer
                    pure
                        ( conjoin
                            [ property
                                (lower >= SJust (SlotNo (fromIntegral (secondsOf windowStart))))
                            , property (upper > lower)
                            , property
                                ( case upper of
                                    SJust (SlotNo u) -> toInteger u < secondsOf windowEnd
                                    SNothing -> False
                                )
                            ]
                        )
