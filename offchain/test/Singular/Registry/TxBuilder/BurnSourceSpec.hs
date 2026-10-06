{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.Registry.TxBuilder.BurnSourceSpec
Description : #177 I177-BUILDER — the retirement burns a token it holds
License     : Apache-2.0

`updateTerminal` (edge ordinal 3) is the only registry edge whose token
column is a burn with no carrier output: @deltaOf 3 = [(active, -1)]@,
and the Lean transaction row
`Singular.Statements.update_terminal_transaction_row` puts the asset it
destroys on a WITNESS INPUT —
@{ role := .witness, assets := [((.active, r.key), 1)] }@ — and on no
output at all.

A mint of @-1@ with no such input is not a retirement. It is a claim the
ledger cannot settle and the cage refuses (`token-missing`), so a builder
that emits it has produced a transaction whose only possible outcome is a
refusal. The failure belongs HERE, in the builder, where it is cheap and
named — the same rule `registryDuties` already applies to the custody an
`updateActive` spends.

These rows are pure. `registryDuties` is the ONE place the off-chain side
decides what an edge owes; it is the decision site this ticket changes,
and these rows assert what it decides, not what a node later does with it.

One row is not pure: the last describe drives the public
`updateTokenWithDuties` itself, against a stub provider and an in-memory
trie, and reads the body of the transaction it builds. The model proves
no fold requires a signer, and that promise is about the SUBMITTED
transaction's required-signer field — so the row reads that field of the
built body, not only the duties the fold accumulated.
-}
module Singular.Registry.TxBuilder.BurnSourceSpec (spec, builtFoldUnder) where

import Control.Exception
    ( ErrorCall
    , SomeException
    , displayException
    , try
    )
import Data.Bifunctor (second)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Short qualified as SBS
import Data.Either (isLeft, isRight)
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import Data.List (isPrefixOf)
import Data.List.NonEmpty qualified as NE
import Data.Set qualified as Set
import Data.Word (Word8)
import GHC.Clock (getMonotonicTimeNSec)
import MPF.Backend.Pure (emptyMPFInMemoryDB)
import Test.Hspec

import Cardano.Ledger.Address (Addr (..), serialiseAddr)
import Cardano.Ledger.Alonzo.TxBody (reqSignerHashesTxBodyL)
import Cardano.Ledger.Api.PParams (PParams, emptyPParams)
import Cardano.Ledger.Api.Tx (bodyTxL, witsTxL)
import Cardano.Ledger.Api.Tx.Body
    ( ValidityInterval (..)
    , inputsTxBodyL
    , mintTxBodyL
    , outputsTxBodyL
    , referenceInputsTxBodyL
    , vldtTxBodyL
    )
import Cardano.Ledger.Api.Tx.Out
    ( TxOut
    , addrTxOutL
    , coinTxOutL
    , datumTxOutL
    , mkBasicTxOut
    , referenceScriptTxOutL
    , valueTxOutL
    )
import Cardano.Ledger.Api.Tx.Wits
    ( Redeemers (..)
    , rdmrsTxWitsL
    , scriptTxWitsL
    )
import Cardano.Ledger.BaseTypes
    ( Network (Testnet)
    , StrictMaybe (..)
    )
import Cardano.Ledger.Core (Script, hashScript)
import Cardano.Ledger.Credential
    ( Credential (..)
    , StakeReference (..)
    )
import Cardano.Ledger.Hashes (ScriptHash)
import Cardano.Ledger.Mary.Value
    ( AssetName (..)
    , MaryValue (..)
    , MultiAsset (..)
    , PolicyID (..)
    )
import Cardano.Ledger.Plutus.Data (getPlutusData)
import Cardano.Ledger.TxIn (TxIn)
import Cardano.Tx.Ledger (ConwayTx)
import Data.Foldable (toList)
import Lens.Micro ((&), (.~), (^.))
import PlutusCore.Data qualified as PLC
import PlutusTx.Builtins (toBuiltin)
import Singular.Application.OpenDatum.Envelope
    ( Control (..)
    , Envelope (..)
    , StateAsset (..)
    , envelopeToData
    , envelopeVersion
    )
import Singular.Application.OpenDatum.Release
    ( releaseOf
    , withApplication
    )
import UntypedPlutusCore.DeBruijn ()

import Cardano.Slotting.Slot (SlotNo (..))
import Singular.Registry.Blueprint (applyDataParam)
import Singular.Registry.Config (CageConfig (..))
import Singular.Registry.Deployment (parseOutRef)
import Singular.Registry.Evidence (NoWitness)
import Singular.Registry.Ledger
    ( Coin (..)
    , ConwayEra
    , Root (..)
    , TokenId (..)
    )
import Singular.Registry.LedgerProvider
    ( Session (..)
    , TipObservation (..)
    )
import Singular.Registry.NetworkTime (NetworkTimeFailure (..))
import Singular.Registry.StubSession
import Singular.Registry.SyntheticLedger
    ( unitProgram
    , withSyntheticCosts
    )
import Singular.Registry.SyntheticTime
    ( syntheticTime
    , syntheticTimeWith
    )
import Singular.Registry.Trie (Trie (..), TrieManager (..))
import Singular.Registry.Trie.PureManager (mkPureTrieManager)
import Singular.Registry.TrieState qualified as TS
import Singular.Registry.TrieState.Fixture qualified as Fixture
import Singular.Registry.TxBuilder.BookingFixture (preprodParams)
import Singular.Registry.TxBuilder.ConnectedFold
    ( ConnectedMint (..)
    , ConnectedSpend (..)
    )
import Singular.Registry.TxBuilder.Internal
    ( addrFromKeyHashBytes
    , cageAddrFromCfg
    , cagePolicyIdFromCfg
    , computeScriptHash
    , extractCageDatum
    , leafActive
    , mkInlineDatum
    , mkRequestScript
    , policyIdFromPin
    , requestAddrFromCfg
    , scriptFromBytes
    , scriptHashBytes
    , toPlcData
    , txInToRef
    )
import Singular.Registry.TxBuilder.Update
    ( HolderRelease (..)
    , RegistryContext (..)
    , RegistryDuties (..)
    , emptyRegistryContext
    , registryDuties
    , updateTokenSelected
    , updateTokenWithDuties
    , updateTokenWithTrieState
    )
import Singular.Registry.Types
    ( CageDatum (..)
    , Edge
    , OnChainRequest (..)
    , OnChainRoot (..)
    , OnChainTokenId (..)
    , OnChainTokenState (..)
    , OnChainTxOutRef
    , edgeDeleteAbsent
    , edgeDeleteActive
    , edgeInsertAbsent
    , edgeInsertActive
    , edgeUpdateActive
    , edgeUpdateTerminal
    , edgeWitnessTerminal
    )

import Control.Monad (forM_, void)
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust, isNothing)
import Data.Text qualified as T

-- ---------------------------------------------------------
-- Fixtures: one registry, two keys
-- ---------------------------------------------------------

keyA, keyB :: ByteString
keyA = "t177-key-a"
keyB = "t177-key-b"

-- | The edge under test, spelled once.
retirement :: Edge
retirement = edgeUpdateTerminal

{- | A 28-byte policy pin, one distinct byte per kind, so a row that
swept the wrong policy could not accidentally agree with the right one.
-}
pin :: Word8 -> SBS.ShortByteString
pin b = SBS.toShort (BS.replicate 28 b)

cfg :: CageConfig
cfg =
    CageConfig
        { cageScriptBytes = SBS.toShort (BS.pack [0x01])
        , requestScriptBytes = SBS.toShort (BS.pack [0x02])
        , cfgScriptHash = computeScriptHash (SBS.toShort (BS.pack [0x01]))
        , cageSeed = seedRef
        , defaultProcessTime = 30000
        , defaultRetractTime = 30000
        , defaultTip = Coin 1000000
        , cfgApplicationPolicy = pin 0xa1
        , cfgActivePolicy = witnessPin 1
        , cfgAbsentPolicy = witnessPin 0
        , cfgTerminalPolicy = witnessPin 2
        , cfgConsumerScript = SBS.empty
        , network = Testnet
        }

seedRef :: OnChainTxOutRef
seedRef = case parseOutRef (T.pack (replicate 64 '1' <> "#0")) of
    Right r -> txInToRef r
    Left e -> error ("BurnSourceSpec fixture: " <> e)

tokenState :: OnChainTokenState
tokenState =
    OnChainTokenState
        { stateRoot = OnChainRoot BS.empty
        , stateMaxFee = 1000000
        , stateProcessTime = 30000
        , stateRetractTime = 30000
        , stateAppPolicy = toBuiltin (SBS.fromShort (cfgApplicationPolicy cfg))
        , stateActivePolicy = toBuiltin (SBS.fromShort (cfgActivePolicy cfg))
        , stateAbsentPolicy = toBuiltin (SBS.fromShort (cfgAbsentPolicy cfg))
        , stateTerminalPolicy =
            toBuiltin (SBS.fromShort (cfgTerminalPolicy cfg))
        }

requestIn :: TxIn
requestIn = case parseOutRef (T.pack (replicate 64 '2' <> "#0")) of
    Right r -> r
    Left e -> error ("BurnSourceSpec fixture: " <> e)

{- | A request UTxO carrying `op` at `keyA`, and NO approval asset: the
approval-return leg is not what these rows are about, and a request
carrying none leaves it untouched.
-}
requestFor :: Edge -> (TxIn, TxOut ConwayEra)
requestFor edge =
    ( requestIn
    , mkBasicTxOut
        (cageAddrFromCfg cfg Testnet)
        (MaryValue (Coin 3000000) mempty)
        & datumTxOutL .~ mkInlineDatum (toPlcData (RequestDatum req))
    )
  where
    req =
        OnChainRequest
            { requestToken =
                OnChainTokenId (toBuiltin ("t177-registry" :: ByteString))
            , requestOwner = toBuiltin (BS.replicate 28 0x5a)
            , requestKey = keyA
            , requestEdge = edge
            , requestDeposit = 2000000
            , requestSubmittedAt = 0
            , requestDestination = ("", Nothing)
            }

{- | The three witness policies the fold mints under. Their BYTES do
return unit under actual evaluation; the builder has one per kind, so a
`Left` below is about the burn source and never about a missing script.
-}
witnessPin :: Int -> SBS.ShortByteString
witnessPin kind =
    SBS.toShort
        ( scriptHashBytes
            ( computeScriptHash
                (applyDataParam (PLC.I (fromIntegral kind)) (unitProgram 2))
            )
        )

witnessScripts :: RegistryContext
witnessScripts =
    emptyRegistryContext
        { rcWitnessScripts =
            Map.fromList
                [ ( k
                  , scriptFromBytes
                        "t177 witness"
                        (applyDataParam (PLC.I (fromIntegral k)) (unitProgram 2))
                  )
                | k <- [0, 1, 2]
                ]
        }

-- | What the builder decides this single request owes.
decide :: Edge -> Either String ()
decide edge =
    void
        ( registryDuties
            cfg
            emptyPParams
            tokenState
            witnessScripts
            [requestFor edge]
            [True]
        )

-- ---------------------------------------------------------
-- The rows
-- ---------------------------------------------------------

spec :: Spec
spec = do
    custodyIdentity
    holderSelection
    burnSourceRequired
    deletionBurnSource
    depositReturn
    requestOrder
    noFoldSigner
    builtFoldBody
    upperOnlyWindow
    builderRefusals
    applicationRelease
    openDatumFold
    releaseResolution
    selectedFold

-- ---------------------------------------------------------
-- #178: absent custody identity comes from its sole asset
-- ---------------------------------------------------------

custodyRef :: TxIn
custodyRef = holderIn 8

refund :: ByteString
refund = serialiseAddr (cageAddrFromCfg cfg Testnet)

refundOnly, retiredTwoField :: PLC.Data
refundOnly = PLC.Constr 2 [PLC.B refund]
retiredTwoField = PLC.Constr 2 [PLC.B keyA, PLC.B refund]

custodyValue
    :: SBS.ShortByteString -> ByteString -> Integer -> MaryValue
custodyValue policy key quantity =
    MaryValue
        (Coin 10000000)
        ( MultiAsset
            ( Map.singleton
                (policyIdFromPin policy)
                (Map.singleton (AssetName (SBS.toShort key)) quantity)
            )
        )

twoAssetCustodyValue :: MaryValue
twoAssetCustodyValue =
    MaryValue
        (Coin 10000000)
        ( MultiAsset
            ( Map.fromList
                [
                    ( policyIdFromPin (cfgAbsentPolicy cfg)
                    , Map.singleton (AssetName (SBS.toShort keyA)) 1
                    )
                ,
                    ( policyIdFromPin (cfgActivePolicy cfg)
                    , Map.singleton (AssetName (SBS.toShort keyB)) 1
                    )
                ]
            )
        )

custodyWith :: PLC.Data -> MaryValue -> (TxIn, TxOut ConwayEra)
custodyWith datum value =
    ( custodyRef
    , mkBasicTxOut (cageAddrFromCfg cfg Testnet) value
        & datumTxOutL .~ mkInlineDatum datum
    )

decideCustody
    :: (TxIn, TxOut ConwayEra) -> Either String RegistryDuties
decideCustody held =
    registryDuties
        cfg
        emptyPParams
        tokenState
        custodyContext
        [requestFor edgeDeleteAbsent]
        [True]
  where
    cageScript = scriptFromBytes "t178 cage" (SBS.toShort (BS.pack [0x58]))
    custodyContext =
        witnessScripts
            { rcCageScript = Just cageScript
            , rcCageUtxos = [held]
            }

expectAssetRefusal :: (TxIn, TxOut ConwayEra) -> Expectation
expectAssetRefusal held@(_, out) = do
    extractCageDatum out `shouldSatisfy` isJust
    void (decideCustody held) `shouldSatisfy` isLeft

custodyIdentity :: Spec
custodyIdentity = describe "#178: absent custody derives identity from its sole asset" $ do
    it "selects a refund-only custody carrying one absent asset" $ do
        let held = custodyWith refundOnly (custodyValue (cfgAbsentPolicy cfg) keyA 1)
        extractCageDatum (snd held) `shouldSatisfy` isJust
        case decideCustody held of
            Left err -> expectationFailure err
            Right duties -> map (fst . csUtxo) (rdSpends duties) `shouldBe` [custodyRef]

    it "does not use the retired datum key as an identity fallback" $
        void
            ( decideCustody
                ( custodyWith
                    retiredTwoField
                    (custodyValue (cfgAbsentPolicy cfg) keyA 1)
                )
            )
            `shouldSatisfy` isLeft

    it "refuses refund-only custody with no non-ADA asset" $
        expectAssetRefusal
            (custodyWith refundOnly (MaryValue (Coin 10000000) mempty))

    it "refuses refund-only custody with two non-ADA assets" $
        expectAssetRefusal (custodyWith refundOnly twoAssetCustodyValue)

    it "refuses refund-only custody under the wrong policy" $
        expectAssetRefusal
            (custodyWith refundOnly (custodyValue (cfgActivePolicy cfg) keyA 1))

    it "refuses refund-only custody with a quantity other than one" $
        expectAssetRefusal
            (custodyWith refundOnly (custodyValue (cfgAbsentPolicy cfg) keyA 2))

burnSourceRequired :: Spec
burnSourceRequired = describe
    "#177 I177-BUILDER: updateTerminal sources its burn from a holder"
    $ do
        -- The row under test. With nothing in hand that carries the key's
        -- active witness, the only transaction this edge could produce mints
        -- `-1` against no input — the shape the cage refuses `token-missing`.
        -- The builder must say so instead of handing back a fold.
        it
            "refuses to build the retirement when nothing holds the key's active witness"
            $ decide retirement `shouldSatisfy` isLeft

        -- The control for the row above, and the reason it is not vacuous:
        -- `updateActive` at the same key, through the same call, with the
        -- same empty context, ALREADY fails — for its own missing custody.
        -- So `registryDuties` is demonstrably able to return `Left` here,
        -- and a green row above is about the retirement, not about the
        -- harness.
        it
            "already refuses updateActive with no custody in hand (the harness can fail)"
            $ decide edgeUpdateActive `shouldSatisfy` isLeft

        -- The other direction: an edge that owes nothing beyond its mint
        -- must still build from the same empty context, so `Left` above is
        -- attributable to the missing witness rather than to the fixture.
        it "still builds an edge that owes no external input (insertAbsent)" $
            decide edgeInsertAbsent `shouldSatisfy` isRight

{- | The candidate burn-source inventory the builder selects from: wallet
outputs that actually hold registry witnesses.
-}
holding :: [(TxIn, TxOut ConwayEra)] -> RegistryContext
holding utxos = witnessScripts{rcHolderUtxos = utxos}

-- | One wallet UTxO holding `quantity` of the active witness for `key`.
holderOf :: Int -> ByteString -> Integer -> (TxIn, TxOut ConwayEra)
holderOf i key quantity =
    ( holderIn i
    , mkBasicTxOut
        (cageAddrFromCfg cfg Testnet)
        ( MaryValue
            (Coin 2000000)
            ( MultiAsset
                ( Map.singleton
                    (policyIdFromPin (cfgActivePolicy cfg))
                    (Map.singleton (AssetName (SBS.toShort key)) quantity)
                )
            )
        )
    )

holderIn :: Int -> TxIn
holderIn i = case parseOutRef (T.pack (replicate 63 '3' <> show i <> "#0")) of
    Right r -> r
    Left e -> error ("BurnSourceSpec fixture: " <> e)

-- | What the builder decides, with a candidate inventory in hand.
decideWith :: RegistryContext -> Edge -> Either String RegistryDuties
decideWith ctx edge =
    registryDuties
        cfg
        emptyPParams
        tokenState
        ctx
        [requestFor edge]
        [True]

{- | The same decision with the duties discarded. `RegistryDuties` holds
ledger values that have no `Show`, and a row that only asks WHETHER the
builder refused does not need them.
-}
refusedWith :: RegistryContext -> Edge -> Either String ()
refusedWith ctx edge = void (decideWith ctx edge)

{- | The rows that need the candidate inventory: selection is exact in
both directions, and the selected UTxO is the one the fold consumes.
-}
holderSelection :: Spec
holderSelection = describe "#177 I177-BUILDER: the burn source is selected exactly" $ do
    it "takes the key's own holder as an input of the fold" $
        case decideWith (holding [holderOf 1 keyA 1]) retirement of
            Left err -> expectationFailure err
            Right d -> map fst (rdInputs d) `shouldBe` [holderIn 1]

    -- Non-vacuity, the direction that matters most here: a builder that
    -- swept whatever it found would pass the row above and this one
    -- too, so the wrong key is offered ALONE. Nothing else in the
    -- inventory can rescue it.
    it "does not sweep another key's holder" $
        refusedWith (holding [holderOf 1 keyB 1]) retirement
            `shouldSatisfy` isLeft

    -- And with both in hand it must still take exactly the right one,
    -- which an inventory-order accident would not survive.
    it "picks this key's holder out of an inventory that holds both" $
        case decideWith (holding [holderOf 1 keyB 1, holderOf 2 keyA 1]) retirement of
            Left err -> expectationFailure err
            Right d -> map fst (rdInputs d) `shouldBe` [holderIn 2]

    it "refuses an inventory carrying the witness twice over" $
        refusedWith
            (holding [holderOf 1 keyA 1, holderOf 2 keyA 1])
            retirement
            `shouldSatisfy` isLeft

    it "refuses a holder carrying more than one of the witness" $
        refusedWith (holding [holderOf 1 keyA 2]) retirement
            `shouldSatisfy` isLeft

    -- The retirement creates no carrier: the Lean row has the active
    -- asset on an input and on no output at all. Its one output is the
    -- deposit going back to the owner (#253), carrying no asset.
    it "creates no output carrying the asset it burns" $
        case decideWith (holding [holderOf 1 keyA 1]) retirement of
            Left err -> expectationFailure err
            Right d -> rdOutputs d `shouldBe` [ownerPaid ownerKey 2000000]

-- ---------------------------------------------------------
-- #236: deleteActive burns the witness it holds
-- ---------------------------------------------------------

{- | `deleteActive` (edge 5) destroys the key's active witness as
`updateTerminal` does: @deltaOf 5 = [(active, -1)]@, and Lean's
`applyEdge` for `.deleteActive` drops the key's active holding. The
ledger balances a burn only against an input carrying the burned asset,
so the fold has to consume the holder's own UTxO and create no carrier.

The asset under test is not typed into the fixture. Its policy is the
hash of the witness script the builder mints under for the active kind,
read from the context, and the registry's active pin is set to that
hash, so the holder, the mint and the selection name one asset.
-}
deletion :: Edge
deletion = edgeDeleteActive

activeWitness :: Script ConwayEra
activeWitness = case Map.lookup 1 (rcWitnessScripts witnessScripts) of
    Just s -> s
    Nothing -> error "BurnSourceSpec fixture: no active witness script"

activeId :: PolicyID
activeId = PolicyID (hashScript activeWitness)

-- | The registry whose active pin is the policy the builder mints under.
boundCfg :: CageConfig
boundCfg =
    cfg
        { cfgActivePolicy =
            SBS.toShort (scriptHashBytes (hashScript activeWitness))
        }

-- | One wallet UTxO holding `quantity` of `boundCfg`'s active witness.
boundHolder :: Int -> ByteString -> Integer -> (TxIn, TxOut ConwayEra)
boundHolder i key quantity =
    ( holderIn i
    , mkBasicTxOut
        (cageAddrFromCfg cfg Testnet)
        ( MaryValue
            (Coin 2000000)
            ( MultiAsset
                ( Map.singleton
                    (policyIdFromPin (cfgActivePolicy boundCfg))
                    (Map.singleton (AssetName (SBS.toShort key)) quantity)
                )
            )
        )
    )

decideDeletion
    :: [(TxIn, TxOut ConwayEra)] -> Either String RegistryDuties
decideDeletion utxos =
    registryDuties
        boundCfg
        emptyPParams
        tokenState
        (holding utxos)
        [requestFor deletion]
        [True]

-- | Quantity of the active witness for `key` an output carries.
carried :: ByteString -> TxOut ConwayEra -> Integer
carried key out = case out ^. valueTxOutL of
    MaryValue _ (MultiAsset m) ->
        maybe
            0
            (Map.findWithDefault 0 (AssetName (SBS.toShort key)))
            (Map.lookup activeId m)

-- | Net quantity of the active witness for `key` the duties mint.
minted :: ByteString -> RegistryDuties -> Integer
minted key d =
    sum
        [ q
        | m <- rdMints d
        , cmPolicy m == activeId
        , Just q <- [Map.lookup (AssetName (SBS.toShort key)) (cmAssets m)]
        ]

{- | The witness shape of one deletion: mint @-1@, exactly one input
carrying quantity 1 of the asset, and no output carrying any of it.
Plain inputs and script-spent inputs are counted together, so a witness
that rode in by either route counts once.
-}
witnessShape :: ByteString -> RegistryDuties -> Expectation
witnessShape key d = do
    minted key d `shouldBe` (-1)
    let ins = map snd (rdInputs d) <> map (snd . csUtxo) (rdSpends d)
    filter (/= 0) (map (carried key) ins) `shouldBe` [1]
    filter (/= 0) (map (carried key) (rdOutputs d)) `shouldBe` []

deletionBurnSource :: Spec
deletionBurnSource =
    describe "#236: deleteActive sources its burn from a holder" $ do
        -- The fixture binds one asset: a holder built from the pin
        -- carries what the builder's mint policy names. Without this
        -- every `carried` below could read 0 and prove nothing.
        it "binds the holder's asset to the builder's active mint policy" $
            carried keyA (snd (boundHolder 1 keyA 1)) `shouldBe` 1

        -- Two keys held, so a builder that swept the inventory, or took
        -- its head, cannot pass.
        it
            "burns -1 from the one input holding the key's witness, outputs none"
            $ case decideDeletion [boundHolder 1 keyB 1, boundHolder 2 keyA 1] of
                Left err -> expectationFailure err
                Right d -> do
                    witnessShape keyA d
                    map fst (rdInputs d) `shouldBe` [holderIn 2]

        it "refuses the deletion when nothing holds the key's witness" $
            void (decideDeletion []) `shouldSatisfy` isLeft

        it "does not sweep another key's holder into the deletion" $
            void (decideDeletion [boundHolder 1 keyB 1])
                `shouldSatisfy` isLeft

-- ---------------------------------------------------------
-- #253: a fold that delivers nothing returns the deposit to its owner
-- ---------------------------------------------------------

-- | The owner `requestFor` names.
ownerKey :: ByteString
ownerKey = BS.replicate 28 0x5a

-- | A plain payment of `lovelace` to `owner`'s key: what the cage counts.
ownerPaid :: ByteString -> Integer -> TxOut ConwayEra
ownerPaid owner lovelace =
    mkBasicTxOut
        (addrFromKeyHashBytes Testnet owner)
        (MaryValue (Coin lovelace) mempty)

{- | A request of `owner` at `keyA` on `edge`, holding tip plus a deposit
of 2 ada, at its own input `i`.
-}
ownedRequest :: Int -> ByteString -> Edge -> (TxIn, TxOut ConwayEra)
ownedRequest i owner edge =
    let (_, out) = requestFor edge
        req = case extractCageDatum out of
            Just (RequestDatum r) -> r{requestOwner = toBuiltin owner}
            _ -> error "BurnSourceSpec fixture: requestFor carries no request"
    in  ( case parseOutRef (T.pack (replicate 64 '4' <> "#" <> show i)) of
            Right r -> r
            Left e -> error ("BurnSourceSpec fixture: " <> e)
        , out & datumTxOutL .~ mkInlineDatum (toPlcData (RequestDatum req))
        )

{- | The burn sources are not what these rows are about: with
`rcAllowInadmissible` the builder emits the burn without a source, so the
deposit leg is the only output an edge 3 or 5 request creates here.
-}
depositsOf
    :: [(TxIn, TxOut ConwayEra)] -> Either String RegistryDuties
depositsOf reqs =
    registryDuties
        cfg
        emptyPParams
        tokenState
        witnessScripts{rcAllowInadmissible = True}
        reqs
        (map (const True) reqs)

depositReturn :: Spec
depositReturn =
    describe
        "#253: the deposit of a fold that delivers nothing goes to its owner"
        $ do
            it "pays a deletion's deposit to its owner's key" $
                case depositsOf [ownedRequest 1 ownerKey edgeDeleteActive] of
                    Left err -> expectationFailure err
                    Right d -> rdOutputs d `shouldBe` [ownerPaid ownerKey 2000000]

            -- Summed per owner: two deposits of one owner are one output, and
            -- another owner's deposit is an output of its own.
            it "pays one output per owner, summing that owner's deposits" $
                case depositsOf
                    [ ownedRequest 1 ownerKey edgeUpdateTerminal
                    , ownedRequest 2 otherKey edgeDeleteActive
                    , ownedRequest 3 ownerKey edgeDeleteActive
                    ] of
                    Left err -> expectationFailure err
                    Right d ->
                        rdOutputs d
                            `shouldMatchList` [ownerPaid ownerKey 4000000, ownerPaid otherKey 2000000]

            -- The approval a deletion carried is not burned: it goes back to
            -- the owner in the deposit's own output, never beside it.
            it "returns a deletion's approval inside its deposit output" $
                case depositsOf [approved (ownedRequest 1 ownerKey edgeDeleteActive)] of
                    Left err -> expectationFailure err
                    Right d ->
                        rdOutputs d
                            `shouldBe` [ mkBasicTxOut
                                            (addrFromKeyHashBytes Testnet ownerKey)
                                            (MaryValue (Coin 2000000) approvalAsset)
                                       ]

            -- A request the fold does not process (a rejected row) owes no
            -- deposit output here; its refund is the reject builder's.
            it "owes nothing for a request the fold does not process" $
                case registryDuties
                    cfg
                    emptyPParams
                    tokenState
                    witnessScripts{rcAllowInadmissible = True}
                    [ownedRequest 1 ownerKey edgeDeleteActive]
                    [False] of
                    Left err -> expectationFailure err
                    Right d -> rdOutputs d `shouldBe` []
  where
    otherKey = BS.replicate 28 0x6b

-- | One approval under the registry's application pin.
approvalAsset :: MultiAsset
approvalAsset =
    MultiAsset
        ( Map.singleton
            (policyIdFromPin (cfgApplicationPolicy cfg))
            (Map.singleton (AssetName "t253-approval") 1)
        )

-- | The request carrying `approvalAsset` beside its lovelace.
approved :: (TxIn, TxOut ConwayEra) -> (TxIn, TxOut ConwayEra)
approved (i, out) =
    ( i
    , out
        & valueTxOutL
            .~ MaryValue (out ^. coinTxOutL) approvalAsset
    )

-- ---------------------------------------------------------
-- #267: accumulated duties preserve request order
-- ---------------------------------------------------------

{- | A request at `key` on `edge`, at its own input `i`. The fold runs
its requests in the order the caller hands them (the facade sorts by
input), and these rows pin what that order means for the duties the
fold accumulates.
-}
keyedRequest :: Int -> ByteString -> Edge -> (TxIn, TxOut ConwayEra)
keyedRequest i key edge =
    let (_, out) = requestFor edge
        req = case extractCageDatum out of
            Just (RequestDatum r) -> r{requestKey = key}
            _ -> error "BurnSourceSpec fixture: requestFor carries no request"
    in  ( case parseOutRef (T.pack (replicate 64 '5' <> "#" <> show i)) of
            Right r -> r
            Left e -> error ("BurnSourceSpec fixture: " <> e)
        , out & datumTxOutL .~ mkInlineDatum (toPlcData (RequestDatum req))
        )

{- | The key one custody output locks: read from the output the builder
produced, never typed into the row.
-}
soleAssetKey :: TxOut ConwayEra -> ByteString
soleAssetKey out = case out ^. valueTxOutL of
    MaryValue _ (MultiAsset m) -> case Map.toList m of
        [(_, names)] -> case Map.toList names of
            [(AssetName n, _)] -> SBS.fromShort n
            _ -> error "order fixture: a custody output names one key"
        _ -> error "order fixture: a custody output holds one policy"

-- | The key one mint names, read the same way.
mintAssetKey :: ConnectedMint -> ByteString
mintAssetKey m = case Map.toList (cmAssets m) of
    [(AssetName n, _)] -> SBS.fromShort n
    _ -> error "order fixture: a mint names one key"

{- | The rows use two requests whose keys sort the OPPOSITE way to the
requests, so a builder that sorted its outputs, folded the requests
backwards, or swept the context's inventory in its own order each fails
differently. Deposit returns are owed per OWNER and deliberately group
by key, so no row here orders them.
-}
requestOrder :: Spec
requestOrder =
    describe "#267: accumulated duties preserve request order" $ do
        it "locks custody in request order" $
            case orderOf
                [ keyedRequest 1 keyB edgeInsertAbsent
                , keyedRequest 2 keyA edgeInsertAbsent
                ] of
                Left err -> expectationFailure err
                Right d -> map soleAssetKey (rdOutputs d) `shouldBe` [keyB, keyA]

        it "mints in request order" $
            case orderOf
                [ keyedRequest 1 keyB edgeInsertAbsent
                , keyedRequest 2 keyA edgeInsertAbsent
                ] of
                Left err -> expectationFailure err
                Right d -> map mintAssetKey (rdMints d) `shouldBe` [keyB, keyA]

        -- The holder inventory deliberately lists the keys in the
        -- opposite order to the requests, so the fold consumes the
        -- sources its requests name, in request order — not the
        -- inventory's.
        it "consumes burn sources in request order" $
            case registryDuties
                boundCfg
                emptyPParams
                tokenState
                (holding [boundHolder 1 keyA 1, boundHolder 2 keyB 1])
                [ keyedRequest 3 keyB edgeDeleteActive
                , keyedRequest 4 keyA edgeDeleteActive
                ]
                [True, True] of
                Left err -> expectationFailure err
                Right d -> map fst (rdInputs d) `shouldBe` [holderIn 2, holderIn 1]
  where
    orderOf reqs =
        registryDuties
            cfg
            emptyPParams
            tokenState
            witnessScripts
            reqs
            (map (const True) reqs)

-- ---------------------------------------------------------
-- #267: no edge of a fold requires a signature
-- ---------------------------------------------------------

{- | The model proves every fold requires no signer
(`Singular.Statements.fold_requires_no_signer`), so the duties a fold
accumulates must carry no signature requirement however many edges it
discharges. One request on each of the seven admissible edges, all
processed, each with what that edge needs in hand — custody for the two
that spend it, holders for the two that burn — read through the public
`Update` import, exactly as a caller reads it.
-}
noFoldSigner :: Spec
noFoldSigner =
    describe "#267: no edge of a fold requires a signature" $
        it "accumulates no required signer across all seven edges" $
            case registryDuties
                boundCfg
                emptyPParams
                tokenState
                fullFoldContext
                sevenEdges
                (map (const True) sevenEdges) of
                Left err -> expectationFailure err
                Right d -> do
                    rdSigners d `shouldSatisfy` null
                    -- Non-vacuity: this fold did real work on every edge,
                    -- so an empty signer list is a decision and not an
                    -- empty answer. Seven edges mint eight entries
                    -- (updateActive mints two), and the two custody
                    -- spends and two burn sources are all consumed.
                    length (rdMints d) `shouldBe` 8
                    length (rdSpends d) `shouldBe` 2
                    length (rdInputs d) `shouldBe` 2
                    rdOutputs d `shouldSatisfy` (not . null)

-- | The key a request on `edge` is booked at, one byte of edge in it.
edgeKey :: Edge -> ByteString
edgeKey e = "t267-key-" <> BS.pack [fromIntegral (e + 48)]

-- | All seven admissible edges, in ordinal order.
allEdges :: [Edge]
allEdges =
    [ edgeInsertAbsent
    , edgeInsertActive
    , edgeUpdateActive
    , edgeUpdateTerminal
    , edgeDeleteAbsent
    , edgeDeleteActive
    , edgeWitnessTerminal
    ]

{- | A request on `edge` at its own key, with a destination this builder
can decode (the cage's own address, as the #178 refund fixture uses).
-}
destinedRequest :: Int -> Edge -> (TxIn, TxOut ConwayEra)
destinedRequest i edge =
    let (_, out) = requestFor edge
        req = case extractCageDatum out of
            Just (RequestDatum r) ->
                r{requestKey = edgeKey edge, requestDestination = (refund, Nothing)}
            _ -> error "BurnSourceSpec fixture: requestFor carries no request"
    in  ( case parseOutRef (T.pack (replicate 64 '5' <> "#" <> show i)) of
            Right r -> r
            Left e -> error ("BurnSourceSpec fixture: " <> e)
        , out & datumTxOutL .~ mkInlineDatum (toPlcData (RequestDatum req))
        )

-- | One request per admissible edge, at distinct inputs.
sevenEdges :: [(TxIn, TxOut ConwayEra)]
sevenEdges = [destinedRequest i e | (i, e) <- zip [20 ..] allEdges]

{- | A custody UTxO at its own input, holding one absent token for `key`
and naming a decodable refund address.
-}
keyedCustody :: Int -> ByteString -> (TxIn, TxOut ConwayEra)
keyedCustody i key =
    ( holderIn i
    , mkBasicTxOut
        (cageAddrFromCfg cfg Testnet)
        (custodyValue (cfgAbsentPolicy cfg) key 1)
        & datumTxOutL .~ mkInlineDatum refundOnly
    )

{- | Everything the seven-edge fold needs in hand: the witness scripts,
the cage script, custody for the two edges that spend it, and holders
for the two edges that burn.
-}
fullFoldContext :: RegistryContext
fullFoldContext =
    ( holding
        [ boundHolder 11 (edgeKey edgeUpdateTerminal) 1
        , boundHolder 12 (edgeKey edgeDeleteActive) 1
        ]
    )
        { rcCageScript =
            Just (scriptFromBytes "t267 cage" (SBS.toShort (BS.pack [0x57])))
        , rcCageUtxos =
            [ keyedCustody 13 (edgeKey edgeUpdateActive)
            , keyedCustody 14 (edgeKey edgeDeleteAbsent)
            ]
        }

-- ---------------------------------------------------------
-- #267: the BUILT fold requires no signature
-- ---------------------------------------------------------

{- | A well-formed PlutusV3 program returning unit from its context. The
request script's parameters are applied to ACTUAL UPLC
(`applyDataParam` deserialises the configured bytes), so a config whose
script fields carry arbitrary bytes cannot reach the fold's assertions:
it fails inside the build with a deserialisation error. The built-body
row folds under `builtCfg`; every pure row keeps the shared `cfg`.
-}
program :: SBS.ShortByteString
program = unitProgram 1

{- | The registry the built-body row folds under: the same census, with
both script fields carrying the well-formed program and the script
hash following it.
-}
builtCfg :: CageConfig
builtCfg =
    cfg
        { cageScriptBytes = program
        , requestScriptBytes = unitProgram 3
        , cfgScriptHash = computeScriptHash program
        }

-- | The token this registry folds: the one `requestFor` already names.
foldTokenId :: TokenId
foldTokenId = TokenId (AssetName "t177-registry")

stateIn :: TxIn
stateIn = case parseOutRef (T.pack (replicate 64 '6' <> "#0")) of
    Right r -> r
    Left e -> error ("BurnSourceSpec fixture: " <> e)

feeIn :: TxIn
feeIn = case parseOutRef (T.pack (replicate 64 '7' <> "#0")) of
    Right r -> r
    Left e -> error ("BurnSourceSpec fixture: " <> e)

-- | The wallet the fold funds and collaterals with.
payer :: Addr
payer = addrFromKeyHashBytes Testnet ownerKey

{- | The registry state UTxO: one state token under the cage policy, the
census datum at the cage address. Everything the fold's own queries ask
for is served from this fixture — the stub provider never reaches a
node, and the values it returns are read back from the built body, never
compared to themselves.
-}
stateUtxoFor :: (TxIn, TxOut ConwayEra)
stateUtxoFor =
    ( stateIn
    , mkBasicTxOut
        (cageAddrFromCfg builtCfg Testnet)
        (MaryValue (Coin 5000000) stateToken)
        & datumTxOutL .~ mkInlineDatum (toPlcData (StateDatum tokenState))
    )
  where
    stateToken =
        MultiAsset
            ( Map.singleton
                (cagePolicyIdFromCfg builtCfg)
                (Map.singleton (AssetName "t177-registry") 1)
            )

{- | A stub provider serving one registry: the state at the cage, the one
pending request at the request address, an ada-only wallet output
anywhere else. Explicit finite synthetic time, exact resolved outputs and
unit-returning synthetic witnesses let the real local evaluator run. These
rows inspect assembled bodies and do not establish registry script admission.
-}
foldProvider :: Session NoWitness IO
foldProvider =
    withAddressOutputs (pure . utxosAt) $
        withParameters (withSyntheticCosts preprodParams) $
            withTime (pure syntheticTime) $
                withResolvedOutputs
                    (resolveBuilt [builtRequest (requestFor edgeInsertAbsent)] [])
                    stubSession

-- | Actual script address for the request the built fixture owns.
builtRequest :: (TxIn, TxOut ConwayEra) -> (TxIn, TxOut ConwayEra)
builtRequest (reference, output) =
    ( reference
    , output & addrTxOutL .~ requestAddrFromCfg builtCfg foldTokenId Testnet
    )

{- | Resolve the full raw extent, including application inputs and publications.
Explicit extra facts replace the default application output by reference.
-}
resolveBuilt
    :: [(TxIn, TxOut ConwayEra)]
    -> [(TxIn, TxOut ConwayEra)]
    -> Set.Set TxIn
    -> IO [(TxIn, TxOut ConwayEra)]
resolveBuilt requests extra wanted =
    let facts =
            Map.fromList
                ( stateUtxoFor
                    : utxosAt payer
                        <> [liveOutput, registryReference, requestReference, appReference]
                        <> requests
                        <> extra
                )
    in  pure (Map.toAscList (Map.restrictKeys facts wanted))

-- | What the fold's own queries see at each address.
utxosAt :: Addr -> [(TxIn, TxOut ConwayEra)]
utxosAt a
    | a == cageAddrFromCfg builtCfg Testnet = [stateUtxoFor]
    | a == requestAddrFromCfg builtCfg foldTokenId Testnet =
        [builtRequest (requestFor edgeInsertAbsent)]
    | otherwise =
        [(feeIn, mkBasicTxOut a (MaryValue (Coin 100000000) mempty))]

{- | The fold this stub registry builds through the public
`updateTokenWithDuties` when its view holds these protocol parameters: the
fold a command builds under its own view, after its booking confirmed (#300's
outlay across the booking and the fold).
-}
builtFoldUnder :: PParams ConwayEra -> IO ConwayTx
builtFoldUnder pp = do
    tm <- mkPureTrieManager
    createTrie tm foldTokenId
    updateTokenWithDuties
        builtCfg
        (withParameters (withSyntheticCosts pp) foldProvider)
        tm
        foldTokenId
        payer
        witnessScripts

{- | The fold's promise that no signer is required is a promise about
the transaction a caller SUBMITS, so the row drives the public
`updateTokenWithDuties` — query, proofs, duties and assembly, the whole
path a caller runs — and reads the required-signer field of the body it
builds. Non-vacuity rides the same body: the fold really spent the
state and the request and really minted, so an empty signer field is a
built fold's decision, not an empty answer.
-}
builtFoldBody :: Spec
builtFoldBody =
    describe "#267: the built fold requires no signature" $
        it "builds the fold with no required signers in its body" $ do
            tm <- mkPureTrieManager
            createTrie tm foldTokenId
            tx <-
                updateTokenWithDuties
                    builtCfg
                    foldProvider
                    tm
                    foldTokenId
                    payer
                    witnessScripts
            let body = tx ^. bodyTxL
            body ^. reqSignerHashesTxBodyL `shouldSatisfy` Set.null
            body
                ^. inputsTxBodyL
                `shouldSatisfy` (\ins -> Set.member stateIn ins && Set.member requestIn ins)
            case body ^. mintTxBodyL of
                MultiAsset m -> m `shouldSatisfy` (not . Map.null)

{- | The public fold builder supplies an unsigned body only when a future
slot remains. Its original omitted lower bound must stay omitted. Synthetic
scripts establish construction/refusal here, not actual registry admission.
-}
upperOnlyWindow :: Spec
upperOnlyWindow = describe "upper-only folds remain usable after their observed tip" $ do
    forM_ [868, 869] $ \upper ->
        it
            ( "refuses upper "
                <> show upper
                <> " before returning a body for signing"
            )
            $ build upper `shouldThrow` refused upper
    it "refuses the registry-limited upper999 at tip917 before signing" $
        buildAt 917 999
            `shouldThrow` ( (isPrefixOf "WindowTooShort" . displayException)
                                :: SomeException -> Bool
                          )
    it
        "waits through970 and rebuilds the upper-only body at971 before signing"
        $ do
            observations <- newIORef ([915, 970, 971], [])
            let next = atomicModifyIORef' observations $ \(remainingTips, seen) -> case remainingTips of
                    current : rest -> ((rest, seen <> [current]), current)
                    [] -> (([], seen <> [971]), 971)
            tx <- buildWith next 1250
            let ValidityInterval lower upper = tx ^. bodyTxL . vldtTxBodyL
            lower `shouldBe` SNothing
            upper `shouldBe` SJust (SlotNo 1250)
            (_, observed) <- readIORef observations
            observed `shouldBe` [915, 970, 971]
    it
        "waits for the later horizon before reselecting a registry window that becomes short"
        $ do
            observations <- newIORef ([915, 916, 970, 971], [])
            let next = atomicModifyIORef' observations $ \(remainingTips, seen) -> case remainingTips of
                    current : rest -> ((rest, seen <> [current]), current)
                    [] -> (([], seen <> [971]), 971)
            buildWith next 1016
                `shouldThrow` (== WindowTooShort (SlotNo 971) (SlotNo 1500) Nothing (SlotNo 1016) 100)
            (_, observed) <- readIORef observations
            observed `shouldBe` [915, 916, 970, 971]
    it
        "checks the Mslot wait bound before reselecting an expired registry window"
        $ do
            observations <- newIORef [915, 1016]
            let next = atomicModifyIORef' observations $ \case
                    current : rest -> (rest, current)
                    [] -> ([], 1016)
            buildWith next 1016
                `shouldThrow` (== HorizonWaitTimedOut (SlotNo 1016) (SlotNo 1500))
    it
        "refuses stalled horizon after the actual20second bound before returning a body"
        $ do
            begin <- getMonotonicTimeNSec
            buildAt 970 1250
                `shouldThrow` (== HorizonWaitTimedOut (SlotNo 970) (SlotNo 1000))
            end <- getMonotonicTimeNSec
            let elapsed = fromIntegral (end - begin) / 1_000_000_000 :: Double
            elapsed `shouldSatisfy` (>= 19.9)
            elapsed `shouldSatisfy` (< 25)
    it
        "enforces the Mslot wait bound even when a later observation jumps past it"
        $ do
            observations <- newIORef [915, 1016]
            let next = atomicModifyIORef' observations $ \case
                    current : rest -> (rest, current)
                    [] -> ([], 1016)
            buildWith next 1250
                `shouldThrow` (== HorizonWaitTimedOut (SlotNo 1016) (SlotNo 1500))
    it "builds the accepting upper-999 twin with no lower bound" $ do
        tx <- build 999
        let body = tx ^. bodyTxL
            ValidityInterval lower upper = body ^. vldtTxBodyL
        lower `shouldBe` SNothing
        upper `shouldBe` SJust (SlotNo 999)
        body ^. inputsTxBodyL
            `shouldSatisfy` (\inputs -> Set.member stateIn inputs && Set.member requestIn inputs)
        body ^. mintTxBodyL `shouldSatisfy` (/= mempty)
  where
    build = buildAt 868
    buildAt observed = buildWith (pure observed)
    buildWith nextTip upper = do
        let (reference, output) = requestFor edgeInsertAbsent
            requested = case extractCageDatum output of
                Just (RequestDatum request) ->
                    ( reference
                    , output
                        & datumTxOutL
                            .~ mkInlineDatum
                                ( toPlcData
                                    ( RequestDatum
                                        request
                                            { requestSubmittedAt = upper * 100 - stateProcessTime tokenState
                                            }
                                    )
                                )
                    )
                _ -> error "upper-only fixture: request datum absent"
            raw =
                withTime
                    (pure (syntheticTimeWith 0 (1 / 10) 500))
                    (providerWith requested)
            view =
                raw
                    { tipObservation = do
                        observed <- nextTip
                        tipObservation
                            (withTip (TipObservation (SlotNo observed) (BS.replicate 32 0) 1 0) raw)
                    }
        tm <- trieWith Nothing
        updateTokenWithDuties
            builtCfg
            view
            tm
            foldTokenId
            payer
            witnessScripts
    refused upper failure = case failure of
        WindowPastLedgerHorizon tip horizon lower windowUpper ->
            tip == SlotNo 868
                && horizon == SlotNo 1000
                && isNothing lower
                && windowUpper == SlotNo (fromInteger upper)
        _ -> False

-- The fold command includes the builder exception in its printed refusal.
-- Drive the public builder, then read that exception's first line: no name
-- is obtained from a refusal renderer or from the implementation under test.
builderRefusals :: Spec
builderRefusals = describe "the fold builder preserves its printed refusal names" $ do
    it "names another registry WrongRegistry" $
        check
            "TrieState WrongRegistry"
            otherWho
            stateIn
            validState
            [requestFor edgeInsertAbsent]
    it "names another selected output StaleState" $
        check
            "TrieState StaleState"
            who
            requestIn
            validState
            [requestFor edgeInsertAbsent]
    it "names a different recorded root StaleState" $
        check
            "TrieState StaleState"
            who
            stateIn
            ( const $
                snd stateUtxoFor
                    & datumTxOutL
                        .~ mkInlineDatum
                            ( toPlcData
                                (StateDatum tokenState{stateRoot = OnChainRoot "different-root"})
                            )
            )
            [requestFor edgeInsertAbsent]
    it "names an undecodable state datum StaleState" $
        check
            "TrieState StaleState"
            who
            stateIn
            (const (snd stateUtxoFor & datumTxOutL .~ mkInlineDatum (PLC.I 42)))
            [requestFor edgeInsertAbsent]
    it "names a request datum in the state output StaleState" $
        check
            "TrieState StaleState"
            who
            stateIn
            ( const $
                snd stateUtxoFor
                    & datumTxOutL .~ (snd (requestFor edgeInsertAbsent) ^. datumTxOutL)
            )
            [requestFor edgeInsertAbsent]
    it "names a missing state datum StaleState" $
        check
            "TrieState StaleState"
            who
            stateIn
            ( const $
                mkBasicTxOut
                    (snd stateUtxoFor ^. addrTxOutL)
                    (snd stateUtxoFor ^. valueTxOutL)
            )
            [requestFor edgeInsertAbsent]
    it "prints the speculative refusal with its subject and cause" $
        check
            ( "TrieState "
                <> show (TS.UndecodableRequest who Nothing (TS.EdgeOutOfRange 99))
            )
            who
            stateIn
            validState
            [requestFor 99]
    it "still refuses a view without the state output" $
        checkView
            "updateToken: state UTxO not found"
            ( withAddressOutputs
                ( \a ->
                    pure (if a == cageAddrFromCfg builtCfg Testnet then [] else utxosAt a)
                )
                foldProvider
            )
    it "still refuses a view without pending requests" $
        checkView
            "updateToken: no pending requests"
            ( withAddressOutputs
                ( \a ->
                    pure
                        ( if a == requestAddrFromCfg builtCfg foldTokenId Testnet
                            then []
                            else utxosAt a
                        )
                )
                foldProvider
            )
    it "still refuses a view without an ada-only funding output" $
        checkView
            "updateToken: no ada-only UTxO to fund the fold"
            ( withAddressOutputs
                (\a -> pure (if a == payer then [] else utxosAt a))
                foldProvider
            )
  where
    who =
        TS.RegistryIdentity
            (TS.StatePolicyId (scriptHashBytes (cfgScriptHash builtCfg)))
            (AssetName "t177-registry")
    otherWho =
        TS.RegistryIdentity
            (TS.StatePolicyId (scriptHashBytes (cfgScriptHash cfg)))
            (AssetName "t177-registry")
    validState root =
        snd stateUtxoFor
            & datumTxOutL
                .~ mkInlineDatum
                    ( toPlcData
                        (StateDatum tokenState{stateRoot = OnChainRoot (unRoot root)})
                    )
    check name identity output state requests =
        checkWith name identity output $ \root ->
            withAddressOutputs
                ( \a ->
                    pure $
                        if a == cageAddrFromCfg builtCfg Testnet
                            then [(stateIn, state root)]
                            else
                                if a == requestAddrFromCfg builtCfg foldTokenId Testnet
                                    then requests
                                    else utxosAt a
                )
                foldProvider
    checkView name view = checkWith name who stateIn (const view)
    checkWith name identity output viewAt = do
        let root = Root (BS.replicate 32 0)
            point = TS.StatePoint (TS.SessionId "builder-fixture") TS.Unbound output
            chosen = TS.TrieSelection identity point root
            fixture =
                Fixture.fixtureStore
                    [
                        ( chosen
                        , Just (TS.CreateRecord identity output)
                        , []
                        , emptyMPFInMemoryDB
                        )
                    ]
        checkedSnapshot <-
            either
                (\why -> expectationFailure (show why) >> fail "fixture setup")
                pure
                (Fixture.fixtureSnapshot fixture chosen)
        let capability =
                TS.TrieState
                    (\_ use -> Right <$> use checkedSnapshot)
                    (const (pure (Right ())))
        result <- TS.withTrieState capability chosen $ \snap ->
            try @ErrorCall
                ( updateTokenWithTrieState
                    builtCfg
                    (viewAt root)
                    snap
                    foldTokenId
                    payer
                    emptyRegistryContext
                )
        case result of
            Right (Left err) -> takeWhile (/= '\n') (displayException err) `shouldBe` name
            Right (Right _) -> expectationFailure "the builder accepted the invalid input"
            Left why -> expectationFailure ("the snapshot was not reached: " <> show why)

-- ---------------------------------------------------------
-- #299: a burn sourced from an application's holding
-- ---------------------------------------------------------

-- | A retirement of `owner` at `key`, at its own input `i`.
retirementAt
    :: Int -> ByteString -> ByteString -> (TxIn, TxOut ConwayEra)
retirementAt i owner key =
    let (_, out) = requestFor retirement
        req = case extractCageDatum out of
            Just (RequestDatum r) -> r{requestOwner = toBuiltin owner, requestKey = key}
            _ -> error "BurnSourceSpec fixture: requestFor carries no request"
    in  ( case parseOutRef (T.pack (replicate 64 '4' <> "#" <> show i)) of
            Right r -> r
            Left e -> error ("BurnSourceSpec fixture: " <> e)
        , out & datumTxOutL .~ mkInlineDatum (toPlcData (RequestDatum req))
        )

-- | The application's own script, the release spend's witness.
applicationScript :: Script ConwayEra
applicationScript = scriptFromBytes "t299 application" (SBS.toShort (BS.pack [0x61]))

releaseRedeemerData :: PLC.Data
releaseRedeemerData = PLC.Constr 1 []

-- | Releasing `lovelace` to `ownerKey` when the holder at `i` is spent.
releasing :: Int -> Integer -> (TxIn, HolderRelease)
releasing i lovelace =
    ( holderIn i
    , HolderRelease
        { hrRedeemer = releaseRedeemerData
        , hrScript = applicationScript
        , hrRecipient = ownerKey
        , hrReleased = lovelace
        }
    )

releaseDuties
    :: [(TxIn, TxOut ConwayEra)]
    -> [(TxIn, TxOut ConwayEra)]
    -> [(TxIn, HolderRelease)]
    -> Either String RegistryDuties
releaseDuties reqs holders releases =
    registryDuties
        cfg
        emptyPParams
        tokenState
        witnessScripts
            { rcHolderUtxos = holders
            , rcHolderReleases = Map.fromList releases
            }
        reqs
        (map (const True) reqs)

applicationRelease :: Spec
applicationRelease =
    describe "#299: a burn sourced from an application's holding" $ do
        it
            "spends the holding with the application's witness, not as a plain input"
            $ case releaseDuties
                [retirementAt 1 ownerKey keyA]
                [holderOf 1 keyA 1]
                [releasing 1 2000000] of
                Left err -> expectationFailure err
                Right d -> do
                    map (fst . csUtxo) (rdSpends d) `shouldBe` [holderIn 1]
                    map csScript (rdSpends d) `shouldBe` [applicationScript]
                    map fst (rdInputs d) `shouldBe` []
        it "leaves a key-held witness a plain input (the control)" $
            case releaseDuties [retirementAt 1 ownerKey keyA] [holderOf 1 keyA 1] [] of
                Left err -> expectationFailure err
                Right d -> do
                    map fst (rdInputs d) `shouldBe` [holderIn 1]
                    map (fst . csUtxo) (rdSpends d) `shouldBe` []
        it
            "pays the release with the returned deposit, in one output to the key"
            $ case releaseDuties
                [retirementAt 1 ownerKey keyA]
                [holderOf 1 keyA 1]
                [releasing 1 2000000] of
                Left err -> expectationFailure err
                Right d -> rdOutputs d `shouldBe` [ownerPaid ownerKey (2000000 + 2000000)]
        it
            "sums two releases and two deposits to one controller in one output"
            $ case releaseDuties
                [retirementAt 1 ownerKey keyA, retirementAt 2 ownerKey keyB]
                [holderOf 1 keyA 1, holderOf 2 keyB 1]
                [releasing 1 2000000, releasing 2 2000000] of
                Left err -> expectationFailure err
                Right d -> rdOutputs d `shouldBe` [ownerPaid ownerKey (4 * 2000000)]
        it "owes no release for a holding the fold does not spend" $
            case releaseDuties
                [retirementAt 1 ownerKey keyA]
                [holderOf 1 keyA 1]
                [releasing 1 2000000, releasing 2 5000000] of
                Left err -> expectationFailure err
                Right d -> rdOutputs d `shouldBe` [ownerPaid ownerKey (2000000 + 2000000)]

-- ---------------------------------------------------------
-- #299: the open-datum application's part of a fold, as BUILT
-- ---------------------------------------------------------

{- $buildOnly
Transaction-build evidence only. These rows drive the real
'updateTokenWithDuties' with the application's context and read the
body it assembles: which inputs it spends, with which redeemers, paying
which outputs. The scripts are the synthetic 'program', the pins are the
synthetic 'cfg' ones, and the envelope names a synthetic registry, so
nothing here evaluates the applied open_datum script or shows a ledger
would accept the transaction. That acceptance is the devnet journey's
evidence, not these rows'.
-}

-- | The application's live-output address: the applied script's own hash.
applicationAddr :: Addr
applicationAddr =
    Addr Testnet (ScriptHashObj (computeScriptHash program)) StakeRefNull

-- | An envelope for `keyA`, controlled by `ownerKey`.
openEnvelope :: Envelope
openEnvelope =
    Envelope
        { envControl =
            Control
                { ctlVersion = envelopeVersion
                , ctlRegistry = StateAsset (BS.replicate 28 0x01) "t177-registry"
                , ctlActivePolicy = SBS.fromShort (cfgActivePolicy cfg)
                , ctlKey = keyA
                , ctlController = ownerKey
                , ctlDeposit = 2000000
                }
        , envPayload = PLC.List [PLC.I 1, PLC.B "payload"]
        }

-- | The key's live output at the application, holding its one token.
liveOutput :: (TxIn, TxOut ConwayEra)
liveOutput =
    ( holderIn 1
    , mkBasicTxOut
        applicationAddr
        (custodyValue (cfgActivePolicy cfg) keyA 1)
        & datumTxOutL .~ mkInlineDatum (envelopeToData openEnvelope)
    )

-- | A stub view whose one pending request is `request`.
providerWith :: (TxIn, TxOut ConwayEra) -> Session NoWitness IO
providerWith request =
    withAddressOutputs
        ( \a ->
            pure $
                if a == requestAddrFromCfg builtCfg foldTokenId Testnet
                    then [builtRequest request]
                    else utxosAt a
        )
        $ withResolvedOutputs
            (resolveBuilt [builtRequest request] [])
            foldProvider

-- | An in-memory trie whose `keyA` leaf is `leaf`, or empty.
trieWith :: Maybe ByteString -> IO (TrieManager IO)
trieWith leaf = do
    tm <- mkPureTrieManager
    createTrie tm foldTokenId
    case leaf of
        Nothing -> pure ()
        Just l -> withTrie tm foldTokenId $ \t -> void (insert t keyA l)
    pure tm

spendRedeemers :: ConwayTx -> [PLC.Data]
spendRedeemers tx =
    let Redeemers m = tx ^. witsTxL . rdmrsTxWitsL
    in  [getPlutusData d | (_, (d, _)) <- Map.toList m]

bodyOutputs :: ConwayTx -> [TxOut ConwayEra]
bodyOutputs tx = toList (tx ^. bodyTxL . outputsTxBodyL)

openDatumFold :: Spec
openDatumFold =
    describe
        "#299 (build only): the open-datum application's part of a fold"
        $ do
            it
                "reads the live envelope and releases its deposit to the controller"
                $ releaseOf program liveOutput
                    `shouldBe` Right
                        ( holderIn 1
                        , HolderRelease
                            { hrRedeemer = PLC.Constr 1 []
                            , hrScript = scriptFromBytes "open-datum" program
                            , hrRecipient = ownerKey
                            , hrReleased = 2000000
                            }
                        )
            it "refuses a live output without an envelope, naming it" $
                releaseOf program (holderOf 1 keyA 1) `shouldSatisfy` isLeft
            it "refuses a live output holding two of its key's token" $
                releaseOf
                    program
                    ( second
                        (valueTxOutL .~ custodyValue (cfgActivePolicy cfg) keyA 2)
                        liveOutput
                    )
                    `shouldSatisfy` isLeft
            it
                "retires the key by spending its live output with Release, paying deposit and release together"
                $ do
                    tm <- trieWith (Just leafActive)
                    ctx <-
                        either
                            fail
                            pure
                            (withApplication program Nothing [liveOutput] witnessScripts)
                    tx <-
                        updateTokenWithDuties
                            builtCfg
                            (providerWith (retirementAt 1 ownerKey keyA))
                            tm
                            foldTokenId
                            payer
                            ctx
                    tx ^. bodyTxL . inputsTxBodyL `shouldSatisfy` Set.member (holderIn 1)
                    spendRedeemers tx `shouldSatisfy` elem (PLC.Constr 1 [])
                    bodyOutputs tx
                        `shouldSatisfy` elem (ownerPaid ownerKey (2000000 + 2000000))
            it
                "delivers an insertion's token to an output carrying its envelope inline"
                $ do
                    tm <- trieWith Nothing
                    let destination =
                            (serialiseAddr applicationAddr, Just (envelopeToData openEnvelope))
                        request =
                            let (i, out) = requestFor edgeInsertActive
                                req = case extractCageDatum out of
                                    Just (RequestDatum r) ->
                                        r
                                            { requestOwner = toBuiltin ownerKey
                                            , requestDestination = destination
                                            }
                                    _ -> error "BurnSourceSpec fixture: no request"
                            in  (i, out & datumTxOutL .~ mkInlineDatum (toPlcData (RequestDatum req)))
                    ctx <-
                        either
                            fail
                            pure
                            (withApplication program Nothing [] witnessScripts)
                    tx <-
                        updateTokenWithDuties
                            builtCfg
                            (providerWith request)
                            tm
                            foldTokenId
                            payer
                            ctx
                    [ ()
                      | out <- bodyOutputs tx
                      , out ^. addrTxOutL == applicationAddr
                      , out ^. datumTxOutL == mkInlineDatum (envelopeToData openEnvelope)
                      ]
                        `shouldBe` [()]

-- ---------------------------------------------------------
-- #299 F299-T6-001: the release script beside the registry's references
-- ---------------------------------------------------------

-- | An application program distinct from the registry's own `program`.
appProgram :: SBS.ShortByteString
appProgram = applyDataParam (PLC.I 7) (unitProgram 2)

appScript :: Script ConwayEra
appScript = scriptFromBytes "open-datum" appProgram

-- | A published reference output carrying `script`, at input `c`.
referenceOf :: Char -> Script ConwayEra -> (TxIn, TxOut ConwayEra)
referenceOf c script =
    ( case parseOutRef (T.pack (replicate 64 c <> "#0")) of
        Right r -> r
        Left e -> error ("BurnSourceSpec fixture: " <> e)
    , mkBasicTxOut payer (MaryValue (Coin 20000000) mempty)
        & referenceScriptTxOutL .~ SJust script
    )

-- | The registry's own published reference: its state script.
registryReference :: (TxIn, TxOut ConwayEra)
registryReference = referenceOf '8' (scriptFromBytes "state" program)

{- | Both registry scripts must actually resolve when the fixture references
them: the state and its token-specific applied request validator.
-}
requestReference :: (TxIn, TxOut ConwayEra)
requestReference = referenceOf '7' (mkRequestScript builtCfg foldTokenId)

appReference :: (TxIn, TxOut ConwayEra)
appReference = referenceOf '9' appScript

-- | Retire keyA with the registry's references in hand, and the app's if given.
retireWithReferences :: Maybe (TxIn, TxOut ConwayEra) -> IO ConwayTx
retireWithReferences app = do
    let appLive =
            second
                ( addrTxOutL
                    .~ Addr
                        Testnet
                        (ScriptHashObj (computeScriptHash appProgram))
                        StakeRefNull
                )
                liveOutput
    tm <- trieWith (Just leafActive)
    ctx <-
        either
            fail
            pure
            ( withApplication
                appProgram
                app
                [appLive]
                witnessScripts{rcRefUtxos = [registryReference, requestReference]}
            )
    updateTokenWithDuties
        builtCfg
        ( withResolvedOutputs
            (resolveBuilt [builtRequest (retirementAt 1 ownerKey keyA)] [appLive])
            $ providerWith (retirementAt 1 ownerKey keyA)
        )
        tm
        foldTokenId
        payer
        ctx

witnessedScripts :: ConwayTx -> [ScriptHash]
witnessedScripts tx = Map.keys (tx ^. witsTxL . scriptTxWitsL)

releaseResolution :: Spec
releaseResolution =
    describe
        "#299 (build only): the release script resolves beside the registry's references"
        $ do
            it "attaches the release script when no reference carries it" $ do
                tx <- retireWithReferences Nothing
                tx ^. bodyTxL . referenceInputsTxBodyL
                    `shouldSatisfy` Set.member (fst registryReference)
                witnessedScripts tx `shouldSatisfy` elem (hashScript appScript)
                witnessedScripts tx
                    `shouldSatisfy` notElem (hashScript (scriptFromBytes "state" program))
                spendRedeemers tx `shouldSatisfy` elem (PLC.Constr 1 [])
            it
                "references the release script, attaching nothing, when its output is given"
                $ do
                    tx <- retireWithReferences (Just appReference)
                    tx ^. bodyTxL . referenceInputsTxBodyL
                        `shouldSatisfy` ( \refs ->
                                            Set.member (fst appReference) refs
                                                && Set.member (fst registryReference) refs
                                        )
                    witnessedScripts tx `shouldSatisfy` notElem (hashScript appScript)
                    spendRedeemers tx `shouldSatisfy` elem (PLC.Constr 1 [])

-- ---------------------------------------------------------
-- A fold over chosen pending requests
-- ---------------------------------------------------------

{- | Three insertions are pending, at three keys; a fold over two of them
spends the state and exactly those two, and its validity upper bound is the
earliest deadline of the two — never the third's, which is earlier still.
Under the synthetic tenth-of-a-second slot each request is submitted so its
deadline falls at a chosen slot: 975 for the request left out, 995 and 985
for the two chosen. Folding all three is the control: the bound moves to 975.
-}
selectedFold :: Spec
selectedFold = describe "a fold over chosen pending requests" $ do
    it
        "spends the state and exactly the chosen requests, bounded by their earliest deadline" $ do
        tx <- buildSelected (fst first NE.:| [fst third])
        let body = tx ^. bodyTxL
            ValidityInterval _ upper = body ^. vldtTxBodyL
            spent = body ^. inputsTxBodyL
        Set.member stateIn spent `shouldBe` True
        filter (`elem` map fst waiting) (Set.toList spent)
            `shouldBe` [fst first, fst third]
        upper `shouldBe` SJust (SlotNo 985)
    it "bounds a fold over every pending request by the earliest of all" $ do
        tx <- buildSelected (NE.fromList (map fst waiting))
        let body = tx ^. bodyTxL
            ValidityInterval _ upper = body ^. vldtTxBodyL
        filter (`elem` map fst waiting) (Set.toList (body ^. inputsTxBodyL))
            `shouldBe` map fst waiting
        upper `shouldBe` SJust (SlotNo 975)
  where
    first = pendingAt 0 "t396-key-a" 995
    left = pendingAt 1 "t396-key-b" 975
    third = pendingAt 2 "t396-key-c" 985
    waiting = [first, left, third]
    pendingAt :: Int -> ByteString -> Integer -> (TxIn, TxOut ConwayEra)
    pendingAt i key slot =
        let (_, output) = requestFor edgeInsertAbsent
            reference = case parseOutRef (T.pack (replicate 64 '2' <> "#" <> show i)) of
                Right r -> r
                Left e -> error ("selected fold fixture: " <> e)
        in  case extractCageDatum output of
                Just (RequestDatum request) ->
                    builtRequest
                        ( reference
                        , output
                            & datumTxOutL
                                .~ mkInlineDatum
                                    ( toPlcData
                                        ( RequestDatum
                                            request
                                                { requestKey = key
                                                , requestSubmittedAt =
                                                    slot * 100 - stateProcessTime tokenState
                                                }
                                        )
                                    )
                        )
                _ -> error "selected fold fixture: request datum absent"
    who =
        TS.RegistryIdentity
            (TS.StatePolicyId (scriptHashBytes (cfgScriptHash builtCfg)))
            (AssetName "t177-registry")
    buildSelected chosen = do
        let root = Root (BS.replicate 32 0)
            point = TS.StatePoint (TS.SessionId "builder-fixture") TS.Unbound stateIn
            selection = TS.TrieSelection who point root
            fixture =
                Fixture.fixtureStore
                    [
                        ( selection
                        , Just (TS.CreateRecord who stateIn)
                        , []
                        , emptyMPFInMemoryDB
                        )
                    ]
            state =
                snd stateUtxoFor
                    & datumTxOutL
                        .~ mkInlineDatum
                            ( toPlcData
                                (StateDatum tokenState{stateRoot = OnChainRoot (unRoot root)})
                            )
            raw =
                withAddressOutputs
                    ( \a ->
                        pure $
                            if a == cageAddrFromCfg builtCfg Testnet
                                then [(stateIn, state)]
                                else
                                    if a == requestAddrFromCfg builtCfg foldTokenId Testnet
                                        then waiting
                                        else utxosAt a
                    )
                    $ withResolvedOutputs (resolveBuilt waiting [])
                    $ withTime (pure (syntheticTimeWith 0 (1 / 10) 500)) foldProvider
            view =
                withTip (TipObservation (SlotNo 868) (BS.replicate 32 0) 1 0) raw
        snapshot <-
            either
                (\why -> expectationFailure (show why) >> fail "fixture setup")
                pure
                (Fixture.fixtureSnapshot fixture selection)
        let capability =
                TS.TrieState
                    (\_ use -> Right <$> use snapshot)
                    (const (pure (Right ())))
        result <- TS.withTrieState capability selection $ \snap ->
            updateTokenSelected
                builtCfg
                view
                snap
                foldTokenId
                payer
                witnessScripts
                chosen
        either
            (\why -> expectationFailure (show why) >> fail "no snapshot")
            pure
            result
