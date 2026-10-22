{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.Application.OpenDatum.TxBuilder.BurnSourceSpec
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
named.

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
module Singular.Application.OpenDatum.BurnSourceSpec (spec, builtFoldUnder) where

import Control.Exception
    ( ErrorCall
    , SomeException
    , displayException
    , try
    )
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Short qualified as SBS
import Data.Either (isLeft, isRight)
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import Data.List (isPrefixOf)
import Data.Set qualified as Set
import Data.Word (Word8)
import GHC.Clock (getMonotonicTimeNSec)
import MPF.Backend.Pure (emptyMPFInMemoryDB)
import Test.Hspec

import Cardano.Ledger.Address (Addr (..), serialiseAddr)
import Cardano.Ledger.Alonzo.TxBody (reqSignerHashesTxBodyL)
import Cardano.Ledger.Api.PParams
    ( PParams
    , emptyPParams
    , ppMaxValSizeL
    )
import Cardano.Ledger.Api.Tx (bodyTxL, witsTxL)
import Cardano.Ledger.Api.Tx.Body
    ( ValidityInterval (..)
    , inputsTxBodyL
    , mintTxBodyL
    , outputsTxBodyL
    , referenceInputsTxBodyL
    , treasuryDonationTxBodyL
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
import Cardano.Ledger.Plutus.Data (Datum (..), getPlutusData)
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
import Singular.Application.OpenDatum.Value (openDatumApplication)
import Singular.Registry.Application
    ( Application (..)
    , DecodedHolding (..)
    , HoldingRules (..)
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
    , onChainTokenId
    , policyIdFromPin
    , requestAddrFromCfg
    , requestPolicyOf
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
    , updateTokenWithDuties
    , updateTokenWithTrieState
    )
import Singular.Registry.Types
    ( CageDatum (..)
    , Edge
    , OnChainRegistrationRequest (..)
    , OnChainRequest (..)
    , OnChainRoot (..)
    , OnChainTerminationRequest (..)
    , OnChainTokenId (..)
    , OnChainTokenState (..)
    , OnChainTxOutRef
    , applicationTagName
    , edgeInsertActive
    , edgeUpdateTerminal
    , terminationTrieReadyTagName
    , trieReadyTagName
    )

import Control.Monad (forM_, void)
import Data.Map.Strict qualified as Map
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
        , defaultRegistrationCost = Coin 2000000
        , defaultBookingWidth = 10000
        , cfgApplicationPolicy = pin 0xa1
        , cfgActivePolicy = witnessPin 1
        , cfgAbsentPolicy = witnessPin 0
        , cfgTerminalPolicy = witnessPin 2
        , cfgRequestPolicy = pin 0xe1
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
        , stateRegistrationCost = 2000000
        , stateBookingWidth = 10000
        , stateRequestPolicy =
            toBuiltin (SBS.fromShort (cfgRequestPolicy cfg))
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
            , requestDestination = (refund, Nothing)
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
    holderSelection
    burnSourceRequired
    retirementBurnSource
    depositReturn
    requestOrder
    noFoldSigner
    builtFoldBody
    upperOnlyWindow
    builderRefusals
    applicationRelease
    openDatumFold
    custodyHolding
    releaseResolution

-- | A token-bearing holder value for application release controls.
witnessValue
    :: SBS.ShortByteString -> ByteString -> Integer -> MaryValue
witnessValue policy key quantity =
    MaryValue
        (Coin 10000000)
        ( MultiAsset
            ( Map.singleton
                (policyIdFromPin policy)
                (Map.singleton (AssetName (SBS.toShort key)) quantity)
            )
        )

-- | A decodable destination for registration.
refund :: ByteString
refund = serialiseAddr (cageAddrFromCfg cfg Testnet)

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

        it "refuses each excluded historical edge" $
            forM_ [0, 2, 4, 5, 6] $
                \edge -> decide edge `shouldSatisfy` isLeft

        -- The other direction: an edge that owes nothing beyond its mint
        -- must still build from the same empty context, so `Left` above is
        -- attributable to the missing witness rather than to the fixture.
        it "still builds an edge that owes no external input (insertActive)" $
            decide edgeInsertActive `shouldSatisfy` isRight

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
-- #236: updateTerminal burns the witness it holds
-- ---------------------------------------------------------

{- | Retirement destroys the active witness. These controls bind the
holder, mint and selection to one script-derived active policy.
-}
boundRetirement :: Edge
boundRetirement = edgeUpdateTerminal

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

decideRetirement
    :: [(TxIn, TxOut ConwayEra)] -> Either String RegistryDuties
decideRetirement utxos =
    registryDuties
        boundCfg
        emptyPParams
        tokenState
        (holding utxos)
        [requestFor boundRetirement]
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

{- | The witness shape of one retirement: mint @-1@, exactly one input
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

retirementBurnSource :: Spec
retirementBurnSource =
    describe "#236: updateTerminal sources its burn from a holder" $ do
        -- The fixture binds one asset: a holder built from the pin
        -- carries what the builder's mint policy names. Without this
        -- every `carried` below could read 0 and prove nothing.
        it "binds the holder's asset to the builder's active mint policy" $
            carried keyA (snd (boundHolder 1 keyA 1)) `shouldBe` 1

        -- Two keys held, so a builder that swept the inventory, or took
        -- its head, cannot pass.
        it
            "burns -1 from the one input holding the key's witness, outputs none"
            $ case decideRetirement [boundHolder 1 keyB 1, boundHolder 2 keyA 1] of
                Left err -> expectationFailure err
                Right d -> do
                    witnessShape keyA d
                    map fst (rdInputs d) `shouldBe` [holderIn 2]

        it "refuses the retirement when nothing holds the key's witness" $
            void (decideRetirement []) `shouldSatisfy` isLeft

        it "does not sweep another key's holder into the retirement" $
            void (decideRetirement [boundHolder 1 keyB 1])
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
            it "pays a retirement's deposit to its owner's key" $
                case depositsOf [ownedRequest 1 ownerKey edgeUpdateTerminal] of
                    Left err -> expectationFailure err
                    Right d -> rdOutputs d `shouldBe` [ownerPaid ownerKey 2000000]

            -- Summed per owner: two deposits of one owner are one output, and
            -- another owner's deposit is an output of its own.
            it "pays one output per owner, summing that owner's deposits" $
                case depositsOf
                    [ ownedRequest 1 ownerKey edgeUpdateTerminal
                    , ownedRequest 2 otherKey edgeUpdateTerminal
                    , ownedRequest 3 ownerKey edgeUpdateTerminal
                    ] of
                    Left err -> expectationFailure err
                    Right d ->
                        rdOutputs d
                            `shouldMatchList` [ownerPaid ownerKey 4000000, ownerPaid otherKey 2000000]

            -- The approval a retirement carried is not burned: it goes back to
            -- the owner in the deposit's own output, never beside it.
            it "returns a retirement's approval inside its deposit output" $
                case depositsOf [approved (ownedRequest 1 ownerKey edgeUpdateTerminal)] of
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
                    [ownedRequest 1 ownerKey edgeUpdateTerminal]
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
        it "delivers active tokens in request order" $
            case orderOf
                [ keyedRequest 1 keyB edgeInsertActive
                , keyedRequest 2 keyA edgeInsertActive
                ] of
                Left err -> expectationFailure err
                Right d -> map soleAssetKey (rdOutputs d) `shouldBe` [keyB, keyA]

        it "mints in request order" $
            case orderOf
                [ keyedRequest 1 keyB edgeInsertActive
                , keyedRequest 2 keyA edgeInsertActive
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
                [ keyedRequest 3 keyB edgeUpdateTerminal
                , keyedRequest 4 keyA edgeUpdateTerminal
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

{- | Both supported transitions require no signer from the public folder.
This is builder-body evidence; application approval is checked separately.
-}
noFoldSigner :: Spec
noFoldSigner =
    describe "#267: no edge of a fold requires a signature" $
        it "accumulates no required signer across both supported edges" $
            case registryDuties
                boundCfg
                emptyPParams
                tokenState
                fullFoldContext
                supportedEdges
                (map (const True) supportedEdges) of
                Left err -> expectationFailure err
                Right d -> do
                    rdSigners d `shouldSatisfy` null
                    -- Both transitions mint, and retirement consumes its holder.
                    length (rdMints d) `shouldBe` 2
                    length (rdSpends d) `shouldBe` 0
                    length (rdInputs d) `shouldBe` 1
                    rdOutputs d `shouldSatisfy` (not . null)

-- | The key a request on `edge` is booked at, one byte of edge in it.
edgeKey :: Edge -> ByteString
edgeKey e = "t267-key-" <> BS.pack [fromIntegral (e + 48)]

-- | Both admissible edges, in ordinal order.
allEdges :: [Edge]
allEdges = [edgeInsertActive, edgeUpdateTerminal]

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
supportedEdges :: [(TxIn, TxOut ConwayEra)]
supportedEdges = [destinedRequest i e | (i, e) <- zip [20 ..] allEdges]

-- | The supported fold needs one active burn source.
fullFoldContext :: RegistryContext
fullFoldContext = holding [boundHolder 11 (edgeKey edgeUpdateTerminal) 1]

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

{- | The application's own program and script, and the registry the whole-path
rows fold: `builtCfg` with the application policy pinned to that script, so the
application tag a booked registration holds is burned under a policy the
context can answer for.
-}
appProgram :: SBS.ShortByteString
appProgram = applyDataParam (PLC.I 7) (unitProgram 2)

appScript :: Script ConwayEra
appScript = scriptFromBytes "open-datum" appProgram

foldCfg :: CageConfig
foldCfg =
    builtCfg
        { cfgApplicationPolicy =
            SBS.toShort (scriptHashBytes (computeScriptHash appProgram))
        }

{- | The scripts the library finds by the registry's pins: the three witness
policies (the active one mints and burns the singular tag) and the
application's (it burns the application tag a registration holds).
-}
foldContext :: RegistryContext
foldContext =
    witnessScripts
        { rcWitnessScripts =
            Map.insert 3 appScript (rcWitnessScripts witnessScripts)
        }

{- | A booked registration of `key` at the fold's registry, as its booking
leaves it: the datum a registry commits to under the trie-ready tag.
-}
bookedRegistrationOf
    :: ByteString
    -> Integer
    -> ByteString
    -> Maybe PLC.Data
    -> OnChainRegistrationRequest
bookedRegistrationOf key submittedAt destination datum =
    OnChainRegistrationRequest
        { regRegistry = onChainTokenId foldTokenId
        , regKey = key
        , regRefundAddress = toBuiltin ownerKey
        , regDestination = destination
        , regDatum = datum
        , regSubmittedAt = submittedAt
        , regRegistrationCost = 2000000
        , regDeclaredTip = bookedTip
        , regCarrierAda = 2000000
        , regNonce = 1
        }

-- | The output that holds a booked registration, with both tags its booking issued.
bookedRegistration
    :: TxIn -> OnChainRegistrationRequest -> (TxIn, TxOut ConwayEra)
bookedRegistration reference r =
    ( reference
    , mkBasicTxOut
        (requestAddrFromCfg foldCfg foldTokenId Testnet)
        ( MaryValue
            (Coin 5000000)
            ( MultiAsset
                ( Map.fromList
                    [
                        ( requestPolicyOf foldCfg foldTokenId
                        , Map.singleton
                            (AssetName (SBS.toShort (trieReadyTagName r)))
                            1
                        )
                    ,
                        ( policyIdFromPin (cfgApplicationPolicy foldCfg)
                        , Map.singleton
                            ( AssetName
                                ( SBS.toShort
                                    ( applicationTagName
                                        (regKey r)
                                        (regRefundAddress r)
                                        (regDestination r)
                                        (regNonce r)
                                    )
                                )
                            )
                            1
                        )
                    ]
                )
            )
        )
        & datumTxOutL .~ mkInlineDatum (toPlcData (RegistrationDatum r))
    )

{- | A booked termination of `key`: the request holds the key's singular tag
and the whole value of its booking, under the trie-ready tag its datum commits to.
-}
bookedTermination :: TxIn -> ByteString -> (TxIn, TxOut ConwayEra)
bookedTermination reference key =
    ( reference
    , mkBasicTxOut
        (requestAddrFromCfg foldCfg foldTokenId Testnet)
        ( MaryValue
            (Coin 4000000)
            ( MultiAsset
                ( Map.fromList
                    [
                        ( requestPolicyOf foldCfg foldTokenId
                        , Map.singleton
                            (AssetName (SBS.toShort (terminationTrieReadyTagName t)))
                            1
                        )
                    ,
                        ( policyIdFromPin (cfgActivePolicy foldCfg)
                        , Map.singleton (AssetName (SBS.toShort key)) 1
                        )
                    ]
                )
            )
        )
        & datumTxOutL .~ mkInlineDatum (toPlcData (TerminationDatum t))
    )
  where
    t =
        OnChainTerminationRequest
            { termRegistry = onChainTokenId foldTokenId
            , termKey = key
            , termDestination = BS.empty
            , termDeclaredTip = bookedTip
            , termCarrierAda = 2000000
            , termNonce = 1
            }

-- | The tip every booked request declares.
bookedTip :: Integer
bookedTip = 1000000

{- | A legacy request, even one that holds a tag under the request policy, is
no booked request: its datum is the legacy edge-only one. This one names an
edge no booked request can name.
-}
legacyTagged :: (TxIn, TxOut ConwayEra)
legacyTagged =
    let (_, out) = requestFor 99
    in  ( requestIn
        , out
            & addrTxOutL .~ requestAddrFromCfg foldCfg foldTokenId Testnet
            & valueTxOutL
                .~ MaryValue
                    (out ^. coinTxOutL)
                    ( MultiAsset
                        ( Map.singleton
                            (requestPolicyOf foldCfg foldTokenId)
                            (Map.singleton (AssetName "legacy-tag") 1)
                        )
                    )
        )

-- | The registration the whole-path rows fold unless they name another.
defaultRegistration :: (TxIn, TxOut ConwayEra)
defaultRegistration =
    bookedRegistration
        requestIn
        (bookedRegistrationOf keyA 0 refund Nothing)

-- | An untagged output at the request address: pollution no discovery sees.
pollutionOut :: (TxIn, TxOut ConwayEra)
pollutionOut =
    ( case parseOutRef (T.pack (replicate 64 'c' <> "#0")) of
        Right r -> r
        Left e -> error ("BurnSourceSpec fixture: " <> e)
    , mkBasicTxOut
        (requestAddrFromCfg foldCfg foldTokenId Testnet)
        (MaryValue (Coin 3000000) mempty)
    )

{- | A stub provider serving one registry: the state at the cage, the booked
requests under the request policy, an untagged output at the request address
that discovery must never read, an ada-only wallet output anywhere else.
Explicit finite synthetic time, exact resolved outputs and unit-returning
synthetic witnesses let the real local evaluator run. These rows inspect
assembled bodies and do not establish registry script admission.
-}
foldProviderOver :: [(TxIn, TxOut ConwayEra)] -> Session NoWitness IO
foldProviderOver requests =
    withPolicyOutputs (\_ -> pure requests) $
        withAddressOutputs (pure . utxosAt) $
            withParameters (withSyntheticCosts (withRecordedLimits preprodParams)) $
                withTime (pure syntheticTime) $
                    withResolvedOutputs
                        (resolveBuilt requests [])
                        stubSession

foldProvider :: Session NoWitness IO
foldProvider = foldProviderOver [defaultRegistration]

{- | The limit the public preprod parameters report besides the fee ones, which
the fold's final body is judged against: the largest value an output may hold,
5000 bytes (the recorded protocol parameters file, sha256 @66eb0791…@). Parameters
without it forbid every output.
-}
withRecordedLimits :: PParams ConwayEra -> PParams ConwayEra
withRecordedLimits = ppMaxValSizeL .~ 5_000

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
        [pollutionOut]
    | otherwise =
        [(feeIn, mkBasicTxOut a (MaryValue (Coin 100000000) mempty))]

{- | The fold this stub registry builds through the public
`updateTokenWithDuties` when its view holds these protocol parameters: the
fold a command builds under its own view, after its booking confirmed (#300's
outlay across the booking and the fold).
-}
builtFoldUnder :: PParams ConwayEra -> IO ConwayTx
builtFoldUnder pp = do
    tm <- trieWith Nothing
    updateTokenWithDuties
        foldCfg
        ( withParameters
            (withSyntheticCosts (withRecordedLimits pp))
            foldProvider
        )
        tm
        foldTokenId
        payer
        foldContext

{- | The fold's promise that no signer is required is a promise about
the transaction a caller SUBMITS, so the row drives the public
`updateTokenWithDuties` — discovery by the request policy, selection, proofs,
duties and assembly, the whole path a caller runs — and reads the
required-signer field of the body it builds. Non-vacuity rides the same body:
the fold really spent the state and the booked request and really minted, so
an empty signer field is a built fold's decision, not an empty answer.
-}
builtFoldBody :: Spec
builtFoldBody =
    describe "#267: the built fold requires no signature" $
        it "builds the fold with no required signers in its body" $ do
            tm <- trieWith Nothing
            tx <-
                updateTokenWithDuties
                    foldCfg
                    foldProvider
                    tm
                    foldTokenId
                    payer
                    foldContext
            let body = tx ^. bodyTxL
            body ^. reqSignerHashesTxBodyL `shouldSatisfy` Set.null
            body
                ^. inputsTxBodyL
                `shouldSatisfy` (\ins -> Set.member stateIn ins && Set.member requestIn ins)
            case body ^. mintTxBodyL of
                MultiAsset m -> m `shouldSatisfy` (not . Map.null)

{- | The public fold builder supplies an unsigned body only when a future
slot remains. A registration folds only from the slot its booking was made, so
the interval the ruled fold states has both bounds: it opens at the booking
and closes at the registration's deadline, held inside the ledger's horizon
(`lean/Singular/Economics/Fold.lean`, `foldPrerequisite`; the Aiken
`modify.ak` requires `lower >= submitted_at` and two finite bounds). The
numerical boundaries are the legacy rows' own: the legacy rows omitted the
lower bound, which the ruled fold cannot. Synthetic scripts establish
construction/refusal here, not actual registry admission.
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
            lower `shouldBe` SJust (bookedAt 1250)
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
                `shouldThrow` ( ==
                                    WindowTooShort
                                        (SlotNo 971)
                                        (SlotNo 1500)
                                        (Just (bookedAt 1016))
                                        (SlotNo 1016)
                                        100
                              )
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
    it "builds the accepting upper-999 twin from the booking's slot" $ do
        tx <- build 999
        let body = tx ^. bodyTxL
            ValidityInterval lower upper = body ^. vldtTxBodyL
        lower `shouldBe` SJust (bookedAt 999)
        upper `shouldBe` SJust (SlotNo 999)
        body ^. inputsTxBodyL
            `shouldSatisfy` (\inputs -> Set.member stateIn inputs && Set.member requestIn inputs)
        body ^. mintTxBodyL `shouldSatisfy` (/= mempty)
  where
    build = buildAt 868
    buildAt observed = buildWith (pure observed)
    -- one slot lasts a tenth of a second, and a registration is booked a
    -- processing time before its deadline: the slot it opens its window at
    bookedAt upper =
        SlotNo
            ( fromInteger upper
                - fromInteger (stateProcessTime tokenState `div` 100)
            )
    buildWith nextTip upper = do
        let requested =
                bookedRegistration
                    requestIn
                    ( bookedRegistrationOf
                        keyA
                        (upper * 100 - stateProcessTime tokenState)
                        refund
                        Nothing
                    )
            raw =
                withTime
                    (pure (syntheticTimeWith 0 (1 / 10) 500))
                    (foldProviderOver [requested])
            view =
                raw
                    { tipObservation = do
                        observed <- nextTip
                        tipObservation
                            (withTip (TipObservation (SlotNo observed) (BS.replicate 32 0) 1 0) raw)
                    }
        tm <- trieWith Nothing
        updateTokenWithDuties
            foldCfg
            view
            tm
            foldTokenId
            payer
            foldContext
    refused upper failure = case failure of
        WindowPastLedgerHorizon tip horizon lower windowUpper ->
            tip == SlotNo 868
                && horizon == SlotNo 1000
                && lower == Just (bookedAt upper)
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
            [defaultRegistration]
    it "names another selected output StaleState" $
        check
            "TrieState StaleState"
            who
            requestIn
            validState
            [defaultRegistration]
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
            [defaultRegistration]
    it "names an undecodable state datum StaleState" $
        check
            "TrieState StaleState"
            who
            stateIn
            (const (snd stateUtxoFor & datumTxOutL .~ mkInlineDatum (PLC.I 42)))
            [defaultRegistration]
    it "names a request datum in the state output StaleState" $
        check
            "TrieState StaleState"
            who
            stateIn
            ( const $
                snd stateUtxoFor
                    & datumTxOutL .~ (snd defaultRegistration ^. datumTxOutL)
            )
            [defaultRegistration]
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
            [defaultRegistration]
    -- A request datum carries no edge: a booked request is a registration or
    -- a termination, so an edge outside the two, which the legacy row printed
    -- as the speculative walk's `EdgeOutOfRange 99`, has no booked form. The
    -- legacy request that names it, even rightly tagged, is no pending request.
    it
        "refuses a legacy request naming an edge no booked request can, as no pending request"
        $ check
            "updateToken: no pending requests"
            who
            stateIn
            validState
            [legacyTagged]
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
            (foldProviderOver [])
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
                            else utxosAt a
                )
                (foldProviderOver requests)
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
                    foldCfg
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
body it assembles: which inputs it spends, which tags it mints and burns,
paying which outputs. The scripts are the synthetic 'program', the pins are the
synthetic 'cfg' ones, and the envelope names a synthetic registry, so
nothing here evaluates the applied open_datum script or shows a ledger
would accept the transaction. That acceptance is the devnet journey's
evidence, not these rows'.

A termination is booked with the key's singular tag and the whole value of its
booking inside the request itself, so the fold consumes that request and burns
the tag: there is no separate holder to spend and no holder release to pay.
The retired holder-release row is replaced by the booked termination below.
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
        (witnessValue (cfgActivePolicy cfg) keyA 1)
        & datumTxOutL .~ mkInlineDatum (envelopeToData openEnvelope)
    )

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

-- | What the body mints of one asset, zero when it mints none.
mintedBy :: ConwayTx -> PolicyID -> ByteString -> Integer
mintedBy tx policy key = case tx ^. bodyTxL . mintTxBodyL of
    MultiAsset m ->
        maybe
            0
            (Map.findWithDefault 0 (AssetName (SBS.toShort key)))
            (Map.lookup policy m)

-- | The booked termination of `keyA` the retirement rows fold.
terminationIn :: TxIn
terminationIn = case parseOutRef (T.pack (replicate 64 'd' <> "#0")) of
    Right r -> r
    Left e -> error ("BurnSourceSpec fixture: " <> e)

-- ---------------------------------------------------------
-- The custody a termination books against: which live output is a holding
-- ---------------------------------------------------------

{- | The envelope of a live holding of this registry: the registry's full
state asset (the state script's hash and the registry token's name), its
active policy, the key `keyA` and its controller.
-}
registryEnvelope :: Envelope
registryEnvelope =
    openEnvelope
        { envControl =
            (envControl openEnvelope)
                { ctlRegistry =
                    StateAsset
                        (scriptHashBytes (cfgScriptHash cfg))
                        "t177-registry"
                }
        }

-- | A live output at the application holding `quantity` of `key`'s token under `datum`.
holdingWith
    :: Int
    -> ByteString
    -> Integer
    -> Maybe Envelope
    -> (TxIn, TxOut ConwayEra)
holdingWith i key quantity datum =
    ( holderIn i
    , mkBasicTxOut
        applicationAddr
        (witnessValue (cfgActivePolicy cfg) key quantity)
        & datumTxOutL
            .~ maybe NoDatum (mkInlineDatum . envelopeToData) datum
    )

{- | The key's custody as the producers find it: the one live output the
application recognizes as this registry's holding of `keyA`.
-}
custodyOf
    :: [(TxIn, TxOut ConwayEra)]
    -> Either T.Text ((TxIn, TxOut ConwayEra), DecodedHolding)
custodyOf outs = case appHolding openDatumApplication of
    Just rules -> hrLiveOutputFor rules cfg foldTokenId keyA outs
    Nothing -> Left "the open-datum application carries no holding rules"

{- | Which live output a termination books against. The retired release read
each live output's envelope and token count and refused a malformed one,
naming it; the termination spends exactly the output the producers find as
the key's holding, and an output that is not a holding of this registry for
this key is never taken as one. These rows carry that custody property
directly: the on-chain side of it is the application's termination spend
(its envelope binding and its one-token custody) and the request policy's
universal layer, established over the compiled validators in Aiken.
-}
custodyHolding :: Spec
custodyHolding = describe "the custody a termination books against" $ do
    let good = holdingWith 2 keyA 1 (Just registryEnvelope)
        refusedAs why outs =
            either (\e -> why `T.isInfixOf` e) (const False) (custodyOf outs)
                `shouldBe` True
    it
        "is the one live output holding the key's single token under an envelope of this registry"
        $ fmap (fst . fst) (custodyOf [good]) `shouldBe` Right (holderIn 2)
    it "reads the controller and the key from that envelope" $
        fmap (\(_, h) -> (dhKey h, dhController h)) (custodyOf [good])
            `shouldBe` Right (keyA, ownerKey)
    it "is no live output that carries no datum" $
        refusedAs "no live output holds key" [holdingWith 2 keyA 1 Nothing]
    it "is no live output whose datum is not an envelope" $
        refusedAs
            "no live output holds key"
            [
                ( holderIn 2
                , snd good & datumTxOutL .~ mkInlineDatum (PLC.I 5)
                )
            ]
    it "is no live output holding two of the key's token" $
        refusedAs
            "no live output holds key"
            [holdingWith 2 keyA 2 (Just registryEnvelope)]
    it "is no live output holding none of the key's token" $
        refusedAs
            "no live output holds key"
            [
                ( holderIn 2
                , snd good & valueTxOutL .~ MaryValue (Coin 10000000) mempty
                )
            ]
    it "is no live output whose envelope names another registry" $
        refusedAs
            "no live output holds key"
            [ holdingWith
                2
                keyA
                1
                ( Just
                    registryEnvelope
                        { envControl =
                            (envControl registryEnvelope)
                                { ctlRegistry =
                                    StateAsset (BS.replicate 28 0x09) "t177-registry"
                                }
                        }
                )
            ]
    it "is no live output whose envelope names another active policy" $
        refusedAs
            "no live output holds key"
            [ holdingWith
                2
                keyA
                1
                ( Just
                    registryEnvelope
                        { envControl =
                            (envControl registryEnvelope)
                                { ctlActivePolicy = BS.replicate 28 0x08
                                }
                        }
                )
            ]
    it "is no live output whose envelope names another key" $
        refusedAs
            "no live output holds key"
            [ holdingWith
                2
                keyA
                1
                ( Just
                    registryEnvelope
                        { envControl =
                            (envControl registryEnvelope){ctlKey = keyB}
                        }
                )
            ]
    it "is refused when two live outputs claim the key" $
        refusedAs
            "more than one live output claims key"
            [good, holdingWith 3 keyA 1 (Just registryEnvelope)]
    it "ignores another key's holding beside it" $
        fmap
            (fst . fst)
            ( custodyOf
                [ good
                , holdingWith
                    3
                    keyB
                    1
                    ( Just
                        registryEnvelope
                            { envControl = (envControl registryEnvelope){ctlKey = keyB}
                            }
                    )
                ]
            )
            `shouldBe` Right (holderIn 2)

openDatumFold :: Spec
openDatumFold =
    describe
        "#299 (build only): the open-datum application's part of a fold"
        $ do
            it
                "retires the key by consuming a booked termination that holds its singular tag and whole value"
                $ do
                    tm <- trieWith (Just leafActive)
                    let termination = bookedTermination terminationIn keyA
                        Coin held = snd termination ^. coinTxOutL
                        active = policyIdFromPin (cfgActivePolicy foldCfg)
                    tx <-
                        updateTokenWithDuties
                            foldCfg
                            (foldProviderOver [termination])
                            tm
                            foldTokenId
                            payer
                            foldContext
                    -- the request is consumed, and no holder rides in beside it
                    tx ^. bodyTxL . inputsTxBodyL `shouldSatisfy` Set.member terminationIn
                    tx ^. bodyTxL . inputsTxBodyL
                        `shouldSatisfy` (not . Set.member (fst liveOutput))
                    -- its singular tag burns, and the request's own tag with it
                    mintedBy tx active keyA `shouldBe` (-1)
                    -- the whole value less the declared tip goes to the treasury
                    tx ^. bodyTxL . treasuryDonationTxBodyL
                        `shouldBe` Coin (held - bookedTip)
                    -- no old holder release is invoked, and no output carries the tag
                    spendRedeemers tx `shouldSatisfy` notElem (PLC.Constr 1 [])
                    [ ()
                      | out <- bodyOutputs tx
                      , carried keyA out /= 0
                      ]
                        `shouldBe` []
            it
                "delivers an insertion's token to an output carrying its envelope inline"
                $ do
                    tm <- trieWith Nothing
                    let registration =
                            bookedRegistration
                                requestIn
                                ( bookedRegistrationOf
                                    keyA
                                    0
                                    (serialiseAddr applicationAddr)
                                    (Just (envelopeToData openEnvelope))
                                )
                    tx <-
                        updateTokenWithDuties
                            foldCfg
                            (foldProviderOver [registration])
                            tm
                            foldTokenId
                            payer
                            foldContext
                    [ ()
                      | out <- bodyOutputs tx
                      , out ^. addrTxOutL == applicationAddr
                      , out ^. datumTxOutL == mkInlineDatum (envelopeToData openEnvelope)
                      ]
                        `shouldBe` [()]

-- ---------------------------------------------------------
-- #299 F299-T6-001: the application's script beside the registry's references
-- ---------------------------------------------------------

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
them: the state and its token-specific applied request validator. Each is an
output of its own: the wallet's funding output is another, and a transaction
may not both spend an output and reference it.
-}
requestReference :: (TxIn, TxOut ConwayEra)
requestReference = referenceOf 'e' (mkRequestScript builtCfg foldTokenId)

appReference :: (TxIn, TxOut ConwayEra)
appReference = referenceOf '9' appScript

-- | Register keyA with the registry's references in hand, and the application's if given.
registerWithReferences :: Maybe (TxIn, TxOut ConwayEra) -> IO ConwayTx
registerWithReferences app = do
    tm <- trieWith Nothing
    updateTokenWithDuties
        foldCfg
        (foldProviderOver [defaultRegistration])
        tm
        foldTokenId
        payer
        foldContext
            { rcRefUtxos =
                [registryReference, requestReference] <> maybe [] pure app
            }

witnessedScripts :: ConwayTx -> [ScriptHash]
witnessedScripts tx = Map.keys (tx ^. witsTxL . scriptTxWitsL)

releaseResolution :: Spec
releaseResolution =
    describe
        "#299 (build only): the application's script resolves beside the registry's references"
        $ do
            let registration = bookedRegistrationOf keyA 0 refund Nothing
                applicationTag =
                    applicationTagName
                        (regKey registration)
                        (regRefundAddress registration)
                        (regDestination registration)
                        (regNonce registration)
                appPolicy = policyIdFromPin (cfgApplicationPolicy foldCfg)
            it "attaches the application's script when no reference carries it" $ do
                tx <- registerWithReferences Nothing
                tx ^. bodyTxL . referenceInputsTxBodyL
                    `shouldSatisfy` Set.member (fst registryReference)
                witnessedScripts tx `shouldSatisfy` elem (hashScript appScript)
                witnessedScripts tx
                    `shouldSatisfy` notElem (hashScript (scriptFromBytes "state" program))
                -- the script is run: it is the policy that burns the registration's application tag
                mintedBy tx appPolicy applicationTag `shouldBe` (-1)
            it
                "references the application's script, attaching nothing, when its output is given"
                $ do
                    tx <- registerWithReferences (Just appReference)
                    tx ^. bodyTxL . referenceInputsTxBodyL
                        `shouldSatisfy` ( \refs ->
                                            Set.member (fst appReference) refs
                                                && Set.member (fst registryReference) refs
                                        )
                    witnessedScripts tx `shouldSatisfy` notElem (hashScript appScript)
                    mintedBy tx appPolicy applicationTag `shouldBe` (-1)
