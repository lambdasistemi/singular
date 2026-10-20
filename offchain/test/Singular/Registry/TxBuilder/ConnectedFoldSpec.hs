{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.Registry.TxBuilder.ConnectedFoldSpec
Description : The fold of genuine tagged registrations and terminations
License     : Apache-2.0

What the permissionless fold builds from pending requests that carry the
request policy's tags: the state spent through @Modify@ with one proof per
member, each request spent through @Contribute@, both tags of every member
burned, a registration's carrier delivered to its booked destination with its
booked datum, the donation of the registration costs and of each termination's
held value less its tip, and the folder's ordinary funding changed only by the
tips and the fee. A registration folds only inside its window; a termination
has none. A legacy untagged request, an untagged output at the request address
and a forged tag are not members, and the state is never spent to reject.

Every expected number comes from the fixture's own values and plain
arithmetic; the expected root is the root of a second trie replayed with the
two edges the model names, in the ledger's input order. The termination's
trie-ready tag is the one a program computed by an independent route.

These rows are the checkpoint's RED: they call the real builder.
-}
module Singular.Registry.TxBuilder.ConnectedFoldSpec (spec) where

import Control.Exception (SomeException, displayException)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Short qualified as SBS
import Data.Foldable (toList)
import Data.List (isInfixOf)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Word (Word32)
import Lens.Micro ((&), (.~), (^.))
import PlutusCore.Data qualified as PLC
import PlutusTx.Builtins.Internal
    ( BuiltinByteString (..)
    , BuiltinData (..)
    )
import PlutusTx.IsData.Class (FromData (..), ToData (..))
import Test.Hspec

import Cardano.Ledger.Address (Addr, serialiseAddr)
import Cardano.Ledger.Allegra.Scripts (ValidityInterval (..))
import Cardano.Ledger.Alonzo.Scripts (AsIx (..))
import Cardano.Ledger.Api.Scripts.Data (Datum (..), binaryDataToData)
import Cardano.Ledger.Api.Tx (bodyTxL, witsTxL)
import Cardano.Ledger.Api.Tx.Body
    ( feeTxBodyL
    , inputsTxBodyL
    , mintTxBodyL
    , outputsTxBodyL
    , treasuryDonationTxBodyL
    , vldtTxBodyL
    )
import Cardano.Ledger.Api.Tx.Out
    ( TxOut
    , addrTxOutL
    , coinTxOutL
    , datumTxOutL
    , mkBasicTxOut
    , valueTxOutL
    )
import Cardano.Ledger.Api.Tx.Wits (Redeemers (..), rdmrsTxWitsL)
import Cardano.Ledger.BaseTypes (Network (Testnet), StrictMaybe (..))
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Conway.Scripts (ConwayPlutusPurpose (..))
import Cardano.Ledger.Core (Script)
import Cardano.Ledger.Mary.Value
    ( AssetName (..)
    , MaryValue (..)
    , MultiAsset (..)
    , PolicyID (..)
    )
import Cardano.Ledger.Plutus.Data (getPlutusData)
import Cardano.Ledger.TxIn (TxIn)
import Cardano.Slotting.Slot (SlotNo (..))
import Cardano.Tx.Ledger (ConwayTx)

import Singular.Registry.Blueprint (NamingCodes (..))
import Singular.Registry.Config
    ( CageConfig (..)
    , bootStateFromCfg
    )
import Singular.Registry.Deployment (parseOutRef)
import Singular.Registry.Evidence (NoWitness)
import Singular.Registry.Ledger (ConwayEra, Root (..), TokenId (..))
import Singular.Registry.LedgerProvider (Session, TipObservation (..))
import Singular.Registry.StubSession
import Singular.Registry.SyntheticLedger
    ( unitProgram
    , withSyntheticCosts
    )
import Singular.Registry.SyntheticTime (syntheticTime)
import Singular.Registry.Trie (Trie (getRoot), TrieManager (..))
import Singular.Registry.Trie.PureManager (mkPureTrieManagerFrom)
import Singular.Registry.TxBuilder.BookingFixture qualified as Fixture
import Singular.Registry.TxBuilder.ConnectedFold
    ( ConnectedFoldArgs (..)
    , ConnectedMint (..)
    , RawRedeemer (..)
    , connectedFoldTx
    )
import Singular.Registry.TxBuilder.Edges
    ( namingPins
    , registryIdOf
    , witnessScriptOf
    )
import Singular.Registry.TxBuilder.Internal
    ( cageAddrFromCfg
    , cagePolicyIdFromCfg
    , computeScriptHash
    , mkInlineDatum
    , onChainTokenId
    , policyIdFromPin
    , requestAddrFromCfg
    , requestPolicyHash
    , scriptFromBytes
    , scriptHashBytes
    , toPlcData
    , txInToRef
    , walkEdge
    )
import Singular.Registry.TxBuilder.Reject (rejectRequestsImpl)
import Singular.Registry.Types
    ( CageDatum (..)
    , OnChainRegistrationRequest (..)
    , OnChainRequest (..)
    , OnChainRoot (..)
    , OnChainTokenId (..)
    , OnChainTokenState (..)
    , RequestAction (..)
    , UpdateRedeemer (..)
    , applicationTagName
    , edgeInsertActive
    , edgeUpdateTerminal
    , trieReadyTagName
    )

-- ---------------------------------------------------------
-- The registry: unit programs wherever a script runs
-- ---------------------------------------------------------

tokenId :: TokenId
tokenId = Fixture.tokenId

payer :: Addr
payer = Fixture.payer

codesU :: NamingCodes
codesU =
    NamingCodes
        { ncApplication = unitProgram 1
        , ncWitness = unitProgram 3
        }

baseCfg :: CageConfig
baseCfg =
    Fixture.cfg
        { cageScriptBytes = unitProgram 1
        , cfgScriptHash = computeScriptHash (unitProgram 1)
        , requestScriptBytes = unitProgram 3
        }

-- | The registry whose four naming pins and request pin are those of its unit programs.
cfg :: CageConfig
cfg =
    baseCfg
        { cfgApplicationPolicy = applicationPin
        , cfgAbsentPolicy = absentPin
        , cfgActivePolicy = activePin
        , cfgTerminalPolicy = terminalPin
        , cfgRequestPolicy =
            SBS.toShort . scriptHashBytes $
                requestPolicyHash
                    (cfgScriptHash baseCfg)
                    (unitProgram 3)
                    (onChainTokenId tokenId)
        }
  where
    (applicationPin, absentPin, activePin, terminalPin) =
        namingPins codesU (registryIdOf baseCfg)

activeId, applicationId, requestId :: PolicyID
activeId = policyIdFromPin (cfgActivePolicy cfg)
applicationId = policyIdFromPin (cfgApplicationPolicy cfg)
requestId = policyIdFromPin (cfgRequestPolicy cfg)

activeScript, applicationScript :: Script ConwayEra
activeScript = witnessScriptOf cfg codesU 1
applicationScript = scriptFromBytes "application" (ncApplication codesU)

unhex :: ByteString -> ByteString
unhex = either (error . ("unhex: " <>)) id . B16.decode

nameOf :: ByteString -> AssetName
nameOf = AssetName . SBS.toShort

registryName :: ByteString
registryName = case unTokenId tokenId of
    AssetName n -> SBS.fromShort n

-- ---------------------------------------------------------
-- Two members: a registration of a new key and a termination of an active one
-- ---------------------------------------------------------

registrationKey, terminationKey :: ByteString
registrationKey = "registered-key"
terminationKey = unhex "6b657942"

{- | Written by @termination_tag_vectors.py@ (evidence/cp3-red-dev/vectors,
output sha256 @9ff8af7c…@) for the key above, the empty destination and nonce
1, not typed.
-}
terminationTag :: ByteString
terminationTag =
    unhex
        "054c1c37bccb9747e1b4e0b76a7ddd96daf15b06d109654eecab7cde86b02e8a"

-- | The registration, booked at slot 5000, the first of the one-second slots.
registration :: OnChainRegistrationRequest
registration =
    OnChainRegistrationRequest
        { regRegistry = OnChainTokenId (BuiltinByteString registryName)
        , regKey = registrationKey
        , regRefundAddress = BuiltinByteString (BS.replicate 28 0xd1)
        , regDestination = BS.cons 0x60 (BS.replicate 28 0x77)
        , regDatum = Just (PLC.I 7)
        , regSubmittedAt = 5_000_000
        , regRegistrationCost = 2_000_000
        , regDeclaredTip = 1_500_000
        , regCarrierAda = 1_500_000
        , regNonce = 5
        }

requestAddr :: Addr
requestAddr = requestAddrFromCfg cfg tokenId Testnet

registrationOut :: OnChainRegistrationRequest -> TxOut ConwayEra
registrationOut r =
    mkBasicTxOut
        requestAddr
        ( MaryValue
            ( Coin
                (regRegistrationCost r + regDeclaredTip r + regCarrierAda r)
            )
            ( MultiAsset
                ( Map.fromList
                    [
                        ( requestId
                        , Map.singleton (nameOf (trieReadyTagName r)) 1
                        )
                    ,
                        ( applicationId
                        , Map.singleton
                            ( nameOf
                                ( applicationTagName
                                    (regKey r)
                                    (regRefundAddress r)
                                    (regDestination r)
                                    (regNonce r)
                                )
                            )
                            1
                        )
                    ]
                )
            )
        )
        & datumTxOutL .~ mkInlineDatum (toPlcData (RegistrationDatum r))

registrationHeld :: Integer
registrationHeld = 5_000_000

terminationTip, terminationHeld :: Integer
terminationTip = 1_500_000
terminationHeld = 4_000_000

{- | The termination: the key's singular tag and the whole custody value in the
request, the datum written field by field without the codec.
-}
terminationOut :: TxOut ConwayEra
terminationOut =
    mkBasicTxOut
        requestAddr
        ( MaryValue
            (Coin terminationHeld)
            ( MultiAsset
                ( Map.fromList
                    [ (requestId, Map.singleton (nameOf terminationTag) 1)
                    , (activeId, Map.singleton (nameOf terminationKey) 1)
                    ]
                )
            )
        )
        & datumTxOutL
            .~ mkInlineDatum
                ( PLC.Constr
                    4
                    [ PLC.Constr
                        0
                        [ PLC.Constr 0 [PLC.B registryName]
                        , PLC.B terminationKey
                        , PLC.B BS.empty
                        , PLC.I terminationTip
                        , PLC.I (terminationHeld - terminationTip)
                        , PLC.I 1
                        ]
                    ]
                )

outRef :: Char -> Int -> TxIn
outRef c i =
    either
        (error . ("ConnectedFoldSpec fixture: " <>))
        id
        (parseOutRef (T.pack (replicate 64 c <> "#" <> show i)))

stateRef, feeRef, registrationRef, terminationRef :: TxIn
stateRef = outRef 'b' 0
feeRef = outRef 'e' 0
registrationRef = outRef 'a' 0
terminationRef = outRef 'a' 1

feeOut :: TxOut ConwayEra
feeOut = mkBasicTxOut payer (MaryValue (Coin 100_000_000) mempty)

-- ---------------------------------------------------------
-- The world: the state, the trie that backs it, the view
-- ---------------------------------------------------------

-- | A trie that already holds the termination's key as active, and its root.
worldTrie :: IO (TrieManager IO, Root)
worldTrie = do
    (manager, _) <- mkPureTrieManagerFrom Map.empty
    createTrie manager tokenId
    root <- withTrie manager tokenId $ \trie -> do
        _ <- walkEdge trie terminationKey edgeInsertActive
        getRoot trie
    pure (manager, root)

stateOutAt :: Root -> TxOut ConwayEra
stateOutAt root =
    mkBasicTxOut
        (cageAddrFromCfg cfg Testnet)
        ( MaryValue
            (Coin 2_000_000)
            ( MultiAsset
                ( Map.singleton
                    (cagePolicyIdFromCfg cfg)
                    (Map.singleton (unTokenId tokenId) 1)
                )
            )
        )
        & datumTxOutL
            .~ mkInlineDatum
                ( toPlcData
                    (StateDatum (bootStateFromCfg cfg (OnChainRoot (unRoot root))))
                )

-- | The view: the tip inside the registration's window, every output resolvable.
viewOver :: Root -> [(TxIn, TxOut ConwayEra)] -> Session NoWitness IO
viewOver root requests =
    withTip (TipObservation (SlotNo 5_005) (BS.replicate 32 0) 1 0) $
        withAddressOutputs
            ( \a ->
                pure $
                    if a == requestAddr
                        then requests
                        else
                            if a == cageAddrFromCfg cfg Testnet
                                then [(stateRef, stateOutAt root)]
                                else [(feeRef, feeOut)]
            )
            ( withParameters (withSyntheticCosts Fixture.preprodParams) $
                withTime (pure syntheticTime) $
                    withResolvedOutputs
                        ( \wanted ->
                            pure
                                [ (r, o)
                                | (r, o) <- (stateRef, stateOutAt root) : (feeRef, feeOut) : requests
                                , r `Set.member` wanted
                                ]
                        )
                        stubSession
            )

-- | The mints the caller attaches: the application tag burn and the singular tags.
attachedMints :: [ConnectedMint]
attachedMints =
    [ ConnectedMint
        { cmPolicy = applicationId
        , cmAssets =
            Map.singleton
                ( nameOf
                    ( applicationTagName
                        (regKey registration)
                        (regRefundAddress registration)
                        (regDestination registration)
                        (regNonce registration)
                    )
                )
                (-1)
        , cmRedeemer = RawRedeemer (PLC.Constr 0 [])
        , cmScript = applicationScript
        }
    , ConnectedMint
        { cmPolicy = activeId
        , cmAssets =
            Map.fromList [(registrationKey, 1), (terminationKey, -1)]
                & Map.mapKeys nameOf
        , cmRedeemer = RawRedeemer (PLC.Constr 0 [])
        , cmScript = activeScript
        }
    ]

folded
    :: [(TxIn, TxOut ConwayEra)]
    -> [ConnectedMint]
    -> IO (ConwayTx, Root)
folded requests mints = do
    (manager, root) <- worldTrie
    connectedFoldTx
        ConnectedFoldArgs
            { cfaCfg = cfg
            , cfaSession = viewOver root requests
            , cfaTrie = manager
            , cfaToken = tokenId
            , cfaFeeAddr = payer
            , cfaStateUtxo = (stateRef, stateOutAt root)
            , cfaReqUtxos = requests
            , cfaFeeUtxo = (feeRef, feeOut)
            , cfaSpends = []
            , cfaMints = mints
            , cfaOutputs = []
            , cfaSigners = []
            , cfaRefUtxos = []
            , cfaAttachScripts = []
            , cfaSkipEval = False
            , cfaAdjustRoot = id
            }

bothMembers :: [(TxIn, TxOut ConwayEra)]
bothMembers =
    [ (registrationRef, registrationOut registration)
    , (terminationRef, terminationOut)
    ]

refusesWith :: String -> IO a -> Expectation
refusesWith what action =
    action `shouldThrow` \e -> what `isInfixOf` displayException (e :: SomeException)

-- ---------------------------------------------------------
-- What the built fold carries, read without the builder
-- ---------------------------------------------------------

outputsOf :: ConwayTx -> [TxOut ConwayEra]
outputsOf tx = toList (tx ^. bodyTxL . outputsTxBodyL)

feeOf :: ConwayTx -> Integer
feeOf tx = let Coin f = tx ^. bodyTxL . feeTxBodyL in f

-- | The spending redeemers of the fold, by the index of the input they are for.
spendRedeemers :: ConwayTx -> [(Word32, PLC.Data)]
spendRedeemers tx =
    let Redeemers rs = tx ^. witsTxL . rdmrsTxWitsL
    in  [ (i, getPlutusData d)
        | (ConwaySpending (AsIx i), (d, _)) <- Map.toList rs
        ]

-- | The index of an input among the fold's inputs, which the ledger orders.
indexOf :: ConwayTx -> TxIn -> Word32
indexOf tx ref =
    fromIntegral
        ( length
            (takeWhile (/= ref) (Set.toAscList (tx ^. bodyTxL . inputsTxBodyL)))
        )

-- | The one-second slots of the synthetic time: a slot starts a thousand milliseconds per number.
slotMs :: SlotNo -> Integer
slotMs (SlotNo s) = 1_000 * fromIntegral s

rawDatum :: TxOut ConwayEra -> Maybe PLC.Data
rawDatum o = case o ^. datumTxOutL of
    Datum bd -> Just (getPlutusData (binaryDataToData bd))
    _ -> Nothing

-- ---------------------------------------------------------
-- The rows
-- ---------------------------------------------------------

spec :: Spec
spec = describe "chunk3 offchain" $ describe "the fold of tagged requests" $ do
    it
        "spends the state through Modify with one update per member, and never a rejection"
        $ do
            (tx, _) <- folded bothMembers attachedMints
            stateActions tx
                `shouldSatisfy` (\as -> length as == 2 && all isUpdate as)
    it "spends each member through Contribute of the state it folds into" $ do
        (tx, _) <- folded bothMembers attachedMints
        case toBuiltinData (Contribute (txInToRef stateRef)) of
            BuiltinData expected ->
                [ lookup (indexOf tx ref) (spendRedeemers tx)
                | ref <- [registrationRef, terminationRef]
                ]
                    `shouldBe` [Just expected, Just expected]
    it
        "continues the state with the root of the two edges the model names, in input order"
        $ do
            (tx, root) <- folded bothMembers attachedMints
            expected <- replayedRoot
            root `shouldBe` expected
            case outputsOf tx of
                continuation : _ -> do
                    continuation ^. addrTxOutL `shouldBe` cageAddrFromCfg cfg Testnet
                    case extractState continuation of
                        Just st -> stateRoot st `shouldBe` OnChainRoot (unRoot expected)
                        Nothing -> expectationFailure "the continuation carries no state datum"
                [] -> expectationFailure "the fold has no outputs"
    it
        "burns both tags of every member and moves exactly one singular tag per member"
        $ do
            (tx, _) <- folded bothMembers attachedMints
            let registrationTags = trieReadyTagName registration
                applicationTag =
                    applicationTagName
                        (regKey registration)
                        (regRefundAddress registration)
                        (regDestination registration)
                        (regNonce registration)
            tx ^. bodyTxL . mintTxBodyL
                `shouldBe` MultiAsset
                    ( Map.fromList
                        [
                            ( requestId
                            , Map.fromList
                                [ (nameOf registrationTags, -1)
                                , (nameOf terminationTag, -1)
                                ]
                            )
                        , (applicationId, Map.singleton (nameOf applicationTag) (-1))
                        ,
                            ( activeId
                            , Map.fromList
                                [ (nameOf registrationKey, 1)
                                , (nameOf terminationKey, -1)
                                ]
                            )
                        ]
                    )
    it
        "delivers a registration's carrier to its booked destination with its booked datum"
        $ do
            (tx, _) <- folded bothMembers attachedMints
            let carriers =
                    [ o
                    | o <- outputsOf tx
                    , MaryValue _ (MultiAsset m) <- [o ^. valueTxOutL]
                    , Just held <- [Map.lookup activeId m]
                    , Map.member (nameOf registrationKey) held
                    ]
            case carriers of
                [o] -> do
                    serialiseAddr (o ^. addrTxOutL) `shouldBe` regDestination registration
                    o ^. valueTxOutL
                        `shouldBe` MaryValue
                            (Coin (regCarrierAda registration))
                            ( MultiAsset
                                (Map.singleton activeId (Map.singleton (nameOf registrationKey) 1))
                            )
                    rawDatum o `shouldBe` Just (PLC.I 7)
                other -> expectationFailure ("carriers: " <> show (length other))
    it "delivers nothing for a termination" $ do
        (tx, _) <- folded bothMembers attachedMints
        [ ()
          | o <- outputsOf tx
          , MaryValue _ (MultiAsset m) <- [o ^. valueTxOutL]
          , Just held <- [Map.lookup activeId m]
          , Map.member (nameOf terminationKey) held
          ]
            `shouldBe` []
    it
        "donates each registration's cost and each termination's held value less its tip"
        $ do
            (tx, _) <- folded bothMembers attachedMints
            tx ^. bodyTxL . treasuryDonationTxBodyL
                `shouldBe` Coin
                    ( regRegistrationCost registration
                        + (terminationHeld - terminationTip)
                    )
    it
        "leaves the folder's ordinary funding changed only by the tips and the fee"
        $ do
            (tx, _) <- folded bothMembers attachedMints
            let tips = regDeclaredTip registration + terminationTip
                change = [o | o <- outputsOf tx, o ^. addrTxOutL == payer]
            map (^. coinTxOutL) change
                `shouldBe` [Coin (100_000_000 + tips - feeOf tx)]
    it "spends the state, the fee input and every member" $ do
        (tx, _) <- folded bothMembers attachedMints
        tx ^. bodyTxL . inputsTxBodyL
            `shouldBe` Set.fromList [stateRef, feeRef, registrationRef, terminationRef]
    it
        "states a finite interval that opens no earlier than the booking and closes inside its window"
        $ do
            (tx, _) <- folded bothMembers attachedMints
            case tx ^. bodyTxL . vldtTxBodyL of
                ValidityInterval (SJust lower) (SJust upper) -> do
                    slotMs lower `shouldSatisfy` (>= regSubmittedAt registration)
                    slotMs upper
                        `shouldSatisfy` (<= regSubmittedAt registration + defaultProcessTimeMs)
                    lower `shouldSatisfy` (< upper)
                other -> expectationFailure ("interval: " <> show other)
    it "builds the same fold whatever order the members are handed in" $ do
        (ascending, _) <- folded bothMembers attachedMints
        (descending, _) <- folded (reverse bothMembers) attachedMints
        descending `shouldBe` ascending
    it "folds a termination of any age, with a finite interval" $ do
        (tx, _) <-
            folded [(terminationRef, terminationOut)] (drop 1 attachedMints)
        case tx ^. bodyTxL . vldtTxBodyL of
            ValidityInterval (SJust lower) (SJust upper) -> lower `shouldSatisfy` (< upper)
            other -> expectationFailure ("interval: " <> show other)
    describe "refuses before building" $ do
        it "a registration whose processing window has closed, by name" $
            refusesWith "not-phase1" $
                folded
                    [
                        ( registrationRef
                        , registrationOut registration{regSubmittedAt = 1_000_000}
                        )
                    ]
                    (take 1 attachedMints)
        it "a legacy untagged request, with no fallback" $
            refusesWith "genuine tagged request" $
                folded [(registrationRef, legacyRequestOut)] []
        it "an untagged output that merely sits at the request address" $
            refusesWith "genuine tagged request" $
                folded
                    [
                        ( registrationRef
                        , mkBasicTxOut requestAddr (MaryValue (Coin 2_000_000) mempty)
                        )
                    ]
                    []
        it "a registration whose tag is not the name its own datum commits to" $
            refusesWith "genuine tagged request" $
                folded [(registrationRef, forgedTagOut)] (take 1 attachedMints)
    describe "never spends the state to reject" $ do
        it "the tagged requests the registry holds" $ do
            (_, root) <- worldTrie
            refusesWith "rejected-retired" $
                rejectRequestsImpl cfg (viewOver root bothMembers) tokenId payer
        it "a legacy untagged request" $ do
            (_, root) <- worldTrie
            refusesWith "rejected-retired" $
                rejectRequestsImpl
                    cfg
                    (viewOver root [(registrationRef, legacyRequestOut)])
                    tokenId
                    payer
  where
    defaultProcessTimeMs = 30_000
    isUpdate = \case Update _ -> True; _ -> False
    stateActions tx =
        case lookup (indexOf tx stateRef) (spendRedeemers tx)
            >>= fromBuiltinData . BuiltinData of
            Just (Modify actions) -> actions
            _ -> []
    extractState o = case rawDatum o of
        Just d -> case fromBuiltinData (BuiltinData d) of
            Just (StateDatum st) -> Just st
            _ -> Nothing
        Nothing -> Nothing
    replayedRoot = do
        (manager, _) <- worldTrie
        withTrie manager tokenId $ \trie -> do
            _ <- walkEdge trie registrationKey edgeInsertActive
            _ <- walkEdge trie terminationKey edgeUpdateTerminal
            getRoot trie
    legacyRequestOut =
        mkBasicTxOut requestAddr (MaryValue (Coin 10_000_000) mempty)
            & datumTxOutL
                .~ mkInlineDatum
                    ( toPlcData
                        ( RequestDatum
                            OnChainRequest
                                { requestToken = onChainTokenId tokenId
                                , requestOwner = BuiltinByteString (BS.replicate 28 0xd1)
                                , requestKey = "legacy-key"
                                , requestEdge = 1
                                , requestDeposit = 2_000_000
                                , requestSubmittedAt = 5_000_000
                                , requestDestination = (regDestination registration, Nothing)
                                }
                        )
                    )
    forgedTagOut =
        registrationOut registration
            & valueTxOutL
                .~ MaryValue
                    (Coin registrationHeld)
                    ( MultiAsset
                        ( Map.singleton
                            requestId
                            (Map.singleton (nameOf "not the committed tag") 1)
                        )
                    )
