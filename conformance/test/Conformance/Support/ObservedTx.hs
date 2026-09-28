{- | What reading an observed exit's datum forms off the ledger must establish.

Appendix material: evidence about how the live runner reads the chain, not
about the registry. Each case runs the transaction observation the live
chapters run — @Conformance.Run.Live.observedStepTx@ — over one submitted
transaction with the outputs it spent, exactly as an accepted live step hands
them over, and reads the forms it reports for the spent state, request,
custody and witness inputs and the destination output. A form comes from the
ledger's own datum constructors: an output presenting its datum by hash
reports hashed, one presenting nothing reports none, and only a datum the
output actually carries reports inline. The comparison legs run the same
registration comparison the chapters run, so a ledger form the model does not
expect reaches it as a difference at that field, never a quiet agreement.
-}
module Conformance.Support.ObservedTx (spec) where

import Conformance.Compare.Perturbation (Step (..), reportedDifferences)
import Conformance.Compare.Registration (
    Declared (..),
    compareRegistration,
    declaredSurface,
 )
import Conformance.Observe.Payments (
    Payee (..),
    Payment (..),
 )
import Conformance.Run.Environment (RowCage (..))
import Conformance.Run.Live (
    LiveStep (..),
    StepOutcome (..),
    newLiveIdentities,
    observedStepTx,
 )
import Conformance.Story.Live qualified as Live
import Control.Exception (ErrorCall)
import Data.Aeson (
    Value (..),
    eitherDecodeFileStrict,
    object,
    (.=),
 )
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BSC
import Data.ByteString.Short qualified as SBS
import Data.IORef (newIORef)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromJust, fromMaybe)
import Data.Sequence.Strict qualified as StrictSeq
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Vector qualified as V
import Data.Word (Word8)
import Lens.Micro ((&), (.~))
import System.Environment (lookupEnv)
import Test.Hspec (
    Spec,
    describe,
    expectationFailure,
    it,
    runIO,
    shouldBe,
    shouldSatisfy,
    shouldThrow,
 )

import Cardano.Crypto.Hash.Class (hashFromBytes)
import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.Api.Scripts.Data (Datum (..))
import Cardano.Ledger.Api.Tx (mkBasicTx, txIdTx)
import Cardano.Ledger.Api.Tx.Body (
    feeTxBodyL,
    inputsTxBodyL,
    mintTxBodyL,
    mkBasicTxBody,
    outputsTxBodyL,
 )
import Cardano.Ledger.Api.Tx.Out (TxOut, datumTxOutL, mkBasicTxOut)
import Cardano.Ledger.BaseTypes (Network (..), TxIx (..))
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Hashes (ScriptHash (..))
import Cardano.Ledger.Mary.Value (MaryValue (..), MultiAsset (..))
import Cardano.Ledger.Plutus.Data (Data (..), hashData)
import Cardano.Ledger.TxIn (TxIn (..))
import Cardano.Tx.Ledger (ConwayTx)
import PlutusCore.Data qualified as PLC
import PlutusTx.Builtins.Internal (BuiltinByteString (..))

import Singular.Registry.Config (CageConfig (..))
import Singular.Registry.Ledger (AssetName (..), PolicyID (..), TokenId (..))
import Singular.Registry.TxBuilder.Internal (
    addrFromKeyHashBytes,
    addrKeyHashBytes,
    mkInlineDatum,
    toPlcData,
 )
import Singular.Registry.Types (
    CageDatum (..),
    OnChainRoot (..),
    OnChainTokenState (..),
    OnChainTxOutRef (..),
 )

-- | The committed corpus, wired in by the package rather than copied here.
declaredSurfaceOf :: IO Declared
declaredSurfaceOf = do
    wired <- lookupEnv "CONFORMANCE_DRIVER_CORPUS"
    path <- case wired of
        Just p -> pure p
        Nothing -> error "CONFORMANCE_DRIVER_CORPUS is not wired; the comparison has no declared surface"
    decoded <- eitherDecodeFileStrict path >>= either error pure
    either error pure (declaredSurface decoded)

-- | A pin-sized byte string, distinct per byte value.
pin :: Word8 -> SBS.ShortByteString
pin b = SBS.toShort (BS.replicate 28 b)

-- | A script hash sized like the pins this fixture distinguishes.
scriptHashOf :: Word8 -> ScriptHash
scriptHashOf b = ScriptHash (fromJust (hashFromBytes (BS.replicate 28 b)))

-- | The fixture's registry: a config whose pins and script hash are distinct
-- byte strings, in a cage no live run booted.
fixtureCfg :: CageConfig
fixtureCfg =
    CageConfig
        { cageScriptBytes = pin 0x10
        , requestScriptBytes = pin 0x11
        , cfgScriptHash = scriptHashOf 0x12
        , cageSeed = OnChainTxOutRef (BuiltinByteString (BS.replicate 32 0x13)) 0
        , defaultProcessTime = 30_000
        , defaultRetractTime = 30_000
        , defaultTip = Coin 1_000_000
        , cfgApplicationPolicy = pin 0x14
        , cfgActivePolicy = pin 0x15
        , cfgAbsentPolicy = pin 0x16
        , cfgTerminalPolicy = pin 0x17
        , cfgConsumerScript = pin 0x18
        , network = Testnet
        }

-- | The fixture's cage, carrying only what observation reads.
fixtureCage :: IO RowCage
fixtureCage =
    RowCage fixtureCfg
        <$> newIORef Nothing
        <*> newIORef (0, 0)
        <*> pure []

-- | One wallet per role, named by its payment key's repeated byte.
walletAt :: Word8 -> Addr
walletAt b = addrFromKeyHashBytes Testnet (BS.replicate 28 b)

ownerWallet, holderWallet :: Addr
ownerWallet = walletAt 0x21
holderWallet = walletAt 0x22

-- | The owner's payment key, as a fold's owner payments name it.
ownerKey :: ByteString
ownerKey = addrKeyHashBytes ownerWallet

-- | A distinct output reference, named by the ledger's own transaction id.
named :: Integer -> TxIn
named n = TxIn (txIdTx (mkBasicTx (mkBasicTxBody & feeTxBodyL .~ Coin n) :: ConwayTx)) (TxIx 0)

stateIn, requestIn, witnessIn, custodyIn, elsewhere :: TxIn
stateIn = named 1
requestIn = named 2
witnessIn = named 3
custodyIn = named 4
elsewhere = named 5

-- | The state datum a continued state output carries; opaque to observation.
tokenState :: OnChainTokenState
tokenState =
    OnChainTokenState
        { stateRoot = OnChainRoot (BS.replicate 32 0x30)
        , stateMaxFee = 1_000_000
        , stateProcessTime = 30_000
        , stateRetractTime = 30_000
        , stateAppPolicy = BuiltinByteString (SBS.fromShort (pin 0x14))
        , stateActivePolicy = BuiltinByteString (SBS.fromShort (pin 0x15))
        , stateAbsentPolicy = BuiltinByteString (SBS.fromShort (pin 0x16))
        , stateTerminalPolicy = BuiltinByteString (SBS.fromShort (pin 0x17))
        }

keyBytes :: ByteString
keyBytes = BSC.pack "fixture-key"

-- | The one active token this fixture's delivering folds mint and carry.
activeAsset :: MultiAsset
activeAsset =
    MultiAsset
        (Map.singleton
            (PolicyID (scriptHashOf 0x15))
            (Map.singleton (AssetName (SBS.toShort keyBytes)) 1))

-- | An output carrying an ada value, presenting its datum as told.
outAt :: Addr -> Integer -> MultiAsset -> Datum ConwayEra -> TxOut ConwayEra
outAt address lovelace assets form =
    mkBasicTxOut address (MaryValue (Coin lovelace) assets)
        & datumTxOutL .~ form

inlineDatum :: Datum ConwayEra
inlineDatum = mkInlineDatum (toPlcData (StateDatum tokenState))

hashedDatum :: Datum ConwayEra
hashedDatum = DatumHash (hashData (Data (PLC.Constr 0 []) :: Data ConwayEra))

-- | The transaction's continued state output, as the ledger writes it.
stateOutput :: TxOut ConwayEra
stateOutput = outAt (walletAt 0x23) 2_000_000 mempty inlineDatum

-- | The spent active witness of a retirement, presenting the form it is told to.
spentWitness :: Datum ConwayEra -> TxOut ConwayEra
spentWitness form = outAt holderWallet 1_000_000 activeAsset form

-- | The spent absent custody of a deletion, presenting the form it is told to.
spentCustody :: Datum ConwayEra -> TxOut ConwayEra
spentCustody form = outAt (walletAt 0x26) 3_000_000 mempty form

-- | The spent request output of a fixture step, presenting the form it is told to.
spentRequest :: Datum ConwayEra -> TxOut ConwayEra
spentRequest form = outAt (walletAt 0x25) 4_000_000 mempty form

-- | The destination output of a delivering fold, presenting the form it is told to.
carrier :: Datum ConwayEra -> TxOut ConwayEra
carrier form = outAt holderWallet 3_000_000 activeAsset form

-- | An owner output paying a fold's owner, as the ledger writes it.
ownerOutput :: Integer -> TxOut ConwayEra
ownerOutput lovelace = outAt ownerWallet lovelace mempty NoDatum

-- | The submitted transaction of a fixture step: the inputs it spent, the
-- outputs it produced and the token it minted.
submitted :: [TxIn] -> [TxOut ConwayEra] -> MultiAsset -> ConwayTx
submitted ins outs minted =
    mkBasicTx
        ( mkBasicTxBody
            & inputsTxBodyL .~ Set.fromList ins
            & outputsTxBodyL .~ StrictSeq.fromList outs
            & mintTxBodyL .~ minted
        )

-- | One minted asset, in the observation's own vocabulary.
mintedAsset :: Text -> Integer -> Value
mintedAsset kind quantity =
    object
        [ "kind" .= kind
        , "key" .= (1 :: Integer)
        , "policy" .= (1 :: Integer)
        , "assetName" .= (1 :: Integer)
        , "quantity" .= quantity
        ]

-- | One live step of the fixture, in the observation's own vocabulary.
fixtureStep :: RowCage -> Live.Edge -> Maybe (TxIn, TxOut ConwayEra)
    -> Maybe (TxIn, TxOut ConwayEra) -> TxOut ConwayEra -> ConwayTx -> LiveStep
fixtureStep cage edge witness custody requestOut transaction =
    LiveStep
        { lsCage = cage
        , lsRequest = Live.EdgeRequest edge "fixture-key" ownerWallet
        , lsExit = Live.Fold
        , lsTamper = Nothing
        , lsRequestIn = Just requestIn
        , lsRequestOut = Just requestOut
        , lsModelRequest = Null
        , lsRetraction = Nothing
        , lsRequestLovelace = 4_000_000
        , lsAfter = Nothing
        , lsWitness = witness
        , lsCustody = custody
        , lsSpent = []
        , lsOutcome = StepAccepted transaction (0, 0, 0)
        }

-- | The observed transaction of one fixture fold, through the live chapters'
-- own observation entry point.
observedTx :: LiveStep -> ConwayTx -> [Value] -> [Payment] -> Integer -> IO Value
observedTx step transaction mint payments destination = do
    ids <- newLiveIdentities
    observedStepTx undefined ids [ownerWallet, holderWallet] step transaction
        Null mint destination 7 [] []
        (fromJust (lsRequestOut step))
        (TokenId (AssetName (SBS.toShort (BSC.pack "fixture-token"))))
        payments

-- | One entry of an observed array, by its role.
entry :: Text -> Text -> Value -> Value
entry array role observation = case found of
    [one] -> one
    _ -> error ("expected exactly one " <> T.unpack role <> " in " <> T.unpack array
        <> ", found " <> show (length found))
  where
    found =
        [ v
        | v <- entriesOf array observation
        , roleOf v == String role
        ]
    entriesOf name value = case value of
        Object fields -> case KM.lookup (Key.fromText name) fields of
            Just (Array found') -> V.toList found'
            _ -> error ("observation has no " <> T.unpack name <> " array")
        _ -> error "observation is not an object"
    roleOf value = case value of
        Object fields -> fromMaybe Null (KM.lookup (Key.fromText "role") fields)
        _ -> Null

-- | The form an observed input or output reports for its datum.
datumFormOf :: Value -> Value
datumFormOf value = case value of
    Object fields -> fromMaybe Null (KM.lookup (Key.fromText "datum") fields)
    _ -> Null

-- | The model's side of the same transaction: every spent input and the
-- destination output present their datum inline, as @registryDatumForm@ says.
modelInlineForms :: Value -> Value
modelInlineForms observation = case observation of
    Object fields ->
        Object
            ( adjustEntries "inputs" inlineForm
                (adjustEntries "outputs" inlineDestination fields)
            )
    _ -> observation
  where
    adjustEntries name f fields = KM.alter (fmap (mapArray f)) (Key.fromText name) fields
    mapArray f value = case value of
        Array found -> Array (fmap f found)
        _ -> value
    inlineForm value = case value of
        Object fields -> Object (KM.insert (Key.fromText "datum") (String "inline") fields)
        _ -> value
    inlineDestination value = case value of
        Object fields
            | fromMaybe Null (KM.lookup (Key.fromText "role") fields) == String "destination" ->
                Object (KM.insert (Key.fromText "datum") (String "inline") fields)
        _ -> value

spec :: Spec
spec = do
    surface <- runIO declaredSurfaceOf
    cage <- runIO fixtureCage
    describe "Reading an observed exit's datum forms off the ledger" $ do
        let retirement =
                fixtureStep cage Live.UpdateTerminal
                    (Just (witnessIn, spentWitness NoDatum)) Nothing
                    (spentRequest inlineDatum)
                    (submitted [stateIn, requestIn, witnessIn]
                        [stateOutput, ownerOutput 4_000_000] mempty)
            registration carrierForm requestForm =
                ( fixtureStep cage Live.InsertActive Nothing Nothing
                    (spentRequest requestForm)
                    (submitted [stateIn, requestIn]
                        [stateOutput, carrier carrierForm] activeAsset)
                , [mintedAsset "active" 1]
                , [Payment (Destination "holder") 3_000_000]
                )
            deletion =
                fixtureStep cage Live.DeleteAbsent Nothing
                    (Just (custodyIn, spentCustody hashedDatum))
                    (spentRequest inlineDatum)
                    (submitted [stateIn, requestIn, custodyIn]
                        [stateOutput, ownerOutput 8_000_000] mempty)

        it "reports each spent input's actual datum form, distinct per role" $ do
            -- The state was spent presenting its datum by hash, the active
            -- witness presenting none, and the request carrying its datum.
            observation <- observedTx retirement (lsTransactionOf retirement) [] [Payment (Owner ownerKey) 4_000_000] 0
            datumFormOf (entry "inputs" "state" observation) `shouldBe` String "hashed"
            datumFormOf (entry "inputs" "witness" observation) `shouldBe` String "none"
            datumFormOf (entry "inputs" "request" observation) `shouldBe` String "inline"

        it "reports the spent custody input's actual datum form" $ do
            observation <- observedTx deletion (lsTransactionOf deletion) [] [Payment (Owner ownerKey) 8_000_000] 0
            datumFormOf (entry "inputs" "cage" observation) `shouldBe` String "hashed"

        it "reports the destination output's actual datum form" $ do
            let (step, mint, payments) = registration NoDatum inlineDatum
            observation <- observedTx step (lsTransactionOf step) mint payments 1
            datumFormOf (entry "outputs" "destination" observation) `shouldBe` String "none"

        it "keeps each role's form bound to its own output" $ do
            let (step, mint, payments) = registration hashedDatum hashedDatum
            observation <- observedTx step (lsTransactionOf step) mint payments 1
            datumFormOf (entry "outputs" "destination" observation) `shouldBe` String "hashed"
            datumFormOf (entry "inputs" "state" observation) `shouldBe` String "none"
            datumFormOf (entry "inputs" "request" observation) `shouldBe` String "hashed"

        it "reports inline where the ledger holds inline" $ do
            let (step, mint, payments) = registration inlineDatum inlineDatum
            observation <- observedTx step (lsTransactionOf step) mint payments 1
            datumFormOf (entry "outputs" "destination" observation) `shouldBe` String "inline"
            datumFormOf (entry "inputs" "state" observation) `shouldBe` String "inline"
            datumFormOf (entry "inputs" "request" observation) `shouldBe` String "inline"

        it "a hashed or absent observed datum fails the registration comparison at its field" $ do
            let (step, mint, payments) = registration NoDatum inlineDatum
            observation <- observedTx step (lsTransactionOf step) mint payments 1
            let observed = asObservations observation
            case compareRegistration surface (asObservations (modelInlineForms observation)) observed of
                Left differences ->
                    reportedDifferences differences
                        `shouldSatisfy` any (\(_, path) -> Field "datum" `elem` path)
                Right _ ->
                    expectationFailure "a ledger datum form the model does not expect passed the comparison"

        it "an all-inline observation keeps the comparison green" $ do
            let (step, mint, payments) = registration inlineDatum inlineDatum
            observation <- observedTx step (lsTransactionOf step) mint payments 1
            let observed = asObservations observation
            case compareRegistration surface (asObservations (modelInlineForms observation)) observed of
                Left differences ->
                    expectationFailure ("an all-inline observation disagreed: " <> show differences)
                Right _ -> pure ()

        it "a spent input the transaction did not spend is an error" $ do
            let transaction = submitted [stateIn] [stateOutput] mempty
                step =
                    (fixtureStep cage Live.InsertActive Nothing Nothing
                        (spentRequest inlineDatum) transaction)
                        { lsRequestIn = Just elsewhere }
            observedTx step transaction [] [] 0 `shouldThrow` anyError

        it "a destination delivered by more than one output is an error" $ do
            let transaction =
                    submitted [stateIn, requestIn]
                        [stateOutput, carrier NoDatum, carrier NoDatum] activeAsset
                step =
                    fixtureStep cage Live.InsertActive Nothing Nothing
                        (spentRequest inlineDatum) transaction
            observedTx step transaction [mintedAsset "active" 1]
                [Payment (Destination "holder") 3_000_000] 1
                `shouldThrow` anyError

-- | The transaction a fixture step submitted, as its outcome carries it.
lsTransactionOf :: LiveStep -> ConwayTx
lsTransactionOf step = case lsOutcome step of
    StepAccepted transaction _ -> transaction
    _ -> error "a fixture step is always accepted"

-- | One transaction observation inside the full observations object the
-- registration comparison compares: every declared name present, every other
-- observation empty and equal on both sides, so only the transaction's own
-- fields can differ.
asObservations :: Value -> Value
asObservations transaction =
    object
        [ "config" .= Null
        , "custody" .= Null
        , "held" .= Null
        , "leaf" .= Null
        , "mint" .= Null
        , "paid" .= ([] :: [Value])
        , "root" .= Null
        , "state" .= Null
        , "tx" .= transaction
        ]

-- | Every error this observer raises on missing or ambiguous evidence.
anyError :: ErrorCall -> Bool
anyError _ = True
