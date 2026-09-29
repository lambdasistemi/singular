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

Each case holds one role to its own spent output, because an expectation
stops at its first failure: a fixture reporting three wrong forms at once
cannot say which of them the observer got right. The state leg reads the
state input the step retained, which a fold always has and a retraction
never does.
-}
module Conformance.Support.ObservedTx (spec) where

import Conformance.Compare.Perturbation
    ( Step (..)
    , reportedDifferences
    )
import Conformance.Compare.Registration
    ( Declared (..)
    , compareRegistration
    , declaredSurface
    )
import Conformance.Observe.Payments
    ( Payee (..)
    , Payment (..)
    )
import Conformance.Run.Environment (RowCage (..))
import Conformance.Run.Live
    ( LiveStep (..)
    , StepOutcome (..)
    , newLiveIdentities
    , observedStepTx
    , prepareRegistrationIdentities
    , walletHoldingsOf
    )
import Conformance.Story.Live qualified as Live
import Control.Exception (ErrorCall, displayException)
import Data.Aeson
    ( Value (..)
    , eitherDecodeFileStrict
    , object
    , (.=)
    )
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BSC
import Data.ByteString.Short qualified as SBS
import Data.Foldable (forM_)
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
import Test.Hspec
    ( Expectation
    , Spec
    , describe
    , expectationFailure
    , it
    , shouldBe
    , shouldSatisfy
    , shouldThrow
    )

import Cardano.Crypto.Hash.Class (hashFromBytes)
import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.Api.Scripts.Data (Datum (..))
import Cardano.Ledger.Api.Tx (mkBasicTx, txIdTx)
import Cardano.Ledger.Api.Tx.Body
    ( feeTxBodyL
    , inputsTxBodyL
    , mintTxBodyL
    , mkBasicTxBody
    , outputsTxBodyL
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
import Singular.Registry.Ledger
    ( AssetName (..)
    , PolicyID (..)
    , TokenId (..)
    )
import Singular.Registry.TxBuilder.Internal
    ( addrFromKeyHashBytes
    , mkInlineDatum
    , toPlcData
    )
import Singular.Registry.Types
    ( CageDatum (..)
    , OnChainRoot (..)
    , OnChainTokenState (..)
    , OnChainTxOutRef (..)
    )

-- | The committed corpus, wired in by the package rather than copied here.
declaredSurfaceOf :: IO Declared
declaredSurfaceOf = do
    wired <- lookupEnv "CONFORMANCE_DRIVER_CORPUS"
    path <- case wired of
        Just p -> pure p
        Nothing ->
            error
                "CONFORMANCE_DRIVER_CORPUS is not wired; the comparison has no declared surface"
    decoded <- eitherDecodeFileStrict path >>= either error pure
    either error pure (declaredSurface decoded)

-- | A pin-sized byte string, distinct per byte value.
pin :: Word8 -> SBS.ShortByteString
pin b = SBS.toShort (BS.replicate 28 b)

-- | A script hash sized like the pins this fixture distinguishes.
scriptHashOf :: Word8 -> ScriptHash
scriptHashOf b =
    ScriptHash (fromJust (hashFromBytes (BS.replicate 28 b)))

-- | The cage's seed reference; no live run consumed it.
fixtureSeed :: OnChainTxOutRef
fixtureSeed =
    OnChainTxOutRef (BuiltinByteString (BS.replicate 32 0x13)) 0

{- | The fixture's registry: a config whose pins and script hash are distinct
byte strings, in a cage no live run booted.
-}
fixtureCfg :: CageConfig
fixtureCfg =
    CageConfig
        { cageScriptBytes = pin 0x10
        , requestScriptBytes = pin 0x11
        , cfgScriptHash = scriptHashOf 0x12
        , cageSeed = fixtureSeed
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

-- | A distinct output reference, named by the ledger's own transaction id.
named :: Integer -> TxIn
named n =
    TxIn
        (txIdTx (mkBasicTx (mkBasicTxBody & feeTxBodyL .~ Coin n) :: ConwayTx))
        (TxIx 0)

stateIn, requestIn, witnessIn, custodyIn, elsewhere :: TxIn
stateIn = named 1
requestIn = named 2
witnessIn = named 3
custodyIn = named 4
elsewhere = named 5

-- | A state policy pin, in the builtin spelling a state datum carries.
statePolicy :: Word8 -> BuiltinByteString
statePolicy b = BuiltinByteString (SBS.fromShort (pin b))

-- | The state datum a continued state output carries; opaque to observation.
tokenState :: OnChainTokenState
tokenState =
    OnChainTokenState
        { stateRoot = OnChainRoot (BS.replicate 32 0x30)
        , stateMaxFee = 1_000_000
        , stateProcessTime = 30_000
        , stateRetractTime = 30_000
        , stateAppPolicy = statePolicy 0x14
        , stateActivePolicy = statePolicy 0x15
        , stateAbsentPolicy = statePolicy 0x16
        , stateTerminalPolicy = statePolicy 0x17
        }

keyBytes :: ByteString
keyBytes = BSC.pack "fixture-key"

-- | The one active token this fixture's delivering folds mint and carry.
activeAsset :: MultiAsset
activeAsset =
    MultiAsset
        ( Map.singleton
            (PolicyID (scriptHashOf 0x15))
            (Map.singleton (AssetName (SBS.toShort keyBytes)) 1)
        )

-- | An output carrying an ada value, presenting its datum as told.
outAt
    :: Addr
    -> Integer
    -> MultiAsset
    -> Datum ConwayEra
    -> TxOut ConwayEra
outAt address lovelace assets form =
    mkBasicTxOut address (MaryValue (Coin lovelace) assets)
        & datumTxOutL .~ form

inlineDatum :: Datum ConwayEra
inlineDatum = mkInlineDatum (toPlcData (StateDatum tokenState))

hashedDatum :: Datum ConwayEra
hashedDatum =
    DatumHash (hashData (Data (PLC.Constr 0 []) :: Data ConwayEra))

{- | The inline datum a non-state output carries: one it really holds, and no
registry datum, so a fold's continued state output stays its only state output.
-}
plainDatum :: Datum ConwayEra
plainDatum = mkInlineDatum (PLC.I 0)

-- | A form told to a non-state output: told inline, it carries 'plainDatum'.
nonState :: Datum ConwayEra -> Datum ConwayEra
nonState form = case form of
    Datum _ -> plainDatum
    _ -> form

-- | The transaction's continued state output, as the ledger writes it.
stateOutput :: TxOut ConwayEra
stateOutput = outAt (walletAt 0x23) 2_000_000 mempty inlineDatum

-- | The spent state input of a fixture step, presenting the form it is told to.
spentState :: Datum ConwayEra -> TxOut ConwayEra
spentState = outAt (walletAt 0x24) 2_000_000 mempty

-- | The spent active witness of a retirement, presenting the form it is told to.
spentWitness :: Datum ConwayEra -> TxOut ConwayEra
spentWitness form = outAt holderWallet 1_000_000 activeAsset (nonState form)

-- | The spent absent custody of a fold, presenting the form it is told to.
spentCustody :: Datum ConwayEra -> TxOut ConwayEra
spentCustody form = outAt (walletAt 0x26) 3_000_000 mempty (nonState form)

-- | The spent request output of a fixture step, presenting the form it is told to.
spentRequest :: Datum ConwayEra -> TxOut ConwayEra
spentRequest form = outAt (walletAt 0x25) 4_000_000 mempty (nonState form)

-- | The destination output of a delivering fold, presenting the form it is told to.
carrier :: Datum ConwayEra -> TxOut ConwayEra
carrier form = outAt holderWallet 3_000_000 activeAsset (nonState form)

-- | An owner output paying a fold's owner, as the ledger writes it.
ownerOutput :: Integer -> TxOut ConwayEra
ownerOutput lovelace = outAt ownerWallet lovelace mempty NoDatum

{- | The submitted transaction of a fixture step: the inputs it spent, the
outputs it produced and the token it minted.
-}
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

{- | One live step of the fixture, in the observation's own vocabulary: the
cage, the edge it books, then the outputs the ledger physically held for the
state, the witness and the custody, the request output, and the transaction
the step submitted.
-}
fixtureStep
    :: RowCage
    -> Live.Edge
    -> Maybe (TxIn, TxOut ConwayEra)
    -> Maybe (TxIn, TxOut ConwayEra)
    -> Maybe (TxIn, TxOut ConwayEra)
    -> TxOut ConwayEra
    -> ConwayTx
    -> LiveStep
fixtureStep cage edge state witness custody requestOut transaction =
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
        , lsStateUtxo = state
        , lsSpent = []
        , lsOutcome = StepAccepted transaction (0, 0, 0)
        }

{- | The observed transaction of one fixture fold, through the live chapters'
own observation entry point.
-}
observedTx
    :: LiveStep
    -> ConwayTx
    -> [Value]
    -> [Payment]
    -> Integer
    -> IO Value
observedTx step transaction mint payments destination = do
    ids <- newLiveIdentities
    -- The bindings the live run makes before a step: the request's key and
    -- wallet and the registry's policies, so observation only looks them up.
    prepareRegistrationIdentities
        ids
        (lsCage step)
        (BSC.pack (Live.requestKey (lsRequest step)))
        (Live.requestWallet (lsRequest step))
    observedStepTx
        undefined
        ids
        [ownerWallet, holderWallet]
        step
        transaction
        Null
        mint
        destination
        7
        []
        []
        (fromJust (lsRequestOut step))
        (TokenId (AssetName (SBS.toShort (BSC.pack "fixture-token"))))
        payments

-- | One entry of an observed array, by its role.
entry :: Text -> Text -> Value -> Value
entry array role observation = case found of
    [one] -> one
    _ -> error (wrongCount array role (length found))
  where
    found =
        [ v
        | v <- entriesOf array observation
        , roleOf v == String role
        ]

{- | The position the role's own entry holds in the observed array, so a
reported difference can be bound to that entry and not merely to its array.
-}
entryIndex :: Text -> Text -> Value -> Int
entryIndex array role observation = case found of
    [one] -> one
    _ -> error (wrongCount array role (length found))
  where
    found =
        [ i
        | (i, v) <- indexed (entriesOf array observation)
        , roleOf v == String role
        ]

indexed :: [a] -> [(Int, a)]
indexed = zip [0 ..]

wrongCount :: Text -> Text -> Int -> String
wrongCount array role count =
    "expected exactly one "
        <> T.unpack role
        <> " in "
        <> T.unpack array
        <> ", found "
        <> show count

entriesOf :: Text -> Value -> [Value]
entriesOf name value = case value of
    Object fields -> case KM.lookup (Key.fromText name) fields of
        Just (Array found) -> V.toList found
        _ -> error ("no such array: " <> T.unpack name)
    _ -> error "observation is not an object"

roleOf :: Value -> Value
roleOf value = case value of
    Object fields ->
        fromMaybe Null (KM.lookup (Key.fromText "role") fields)
    _ -> Null

-- | The form an observed input or output reports for its datum.
datumFormOf :: Value -> Value
datumFormOf value = case value of
    Object fields ->
        fromMaybe Null (KM.lookup (Key.fromText "datum") fields)
    _ -> Null

{- | The model's side of the same transaction: every spent input and the
destination output present their datum inline, as @registryDatumForm@ says.
-}
modelInlineForms :: Value -> Value
modelInlineForms observation = case observation of
    Object fields ->
        Object
            ( adjustEntries
                "inputs"
                inlineForm
                (adjustEntries "outputs" inlineDestination fields)
            )
    _ -> observation
  where
    -- The model spells every datum form; an entry the transaction does not
    -- carry is left as it is, never invented.
    datumKey = Key.fromText "datum"
    inline = String "inline"
    inlineForm value = case value of
        Object fields' -> Object (KM.insert datumKey inline fields')
        _ -> value
    inlineDestination value = case value of
        Object fields'
            | roleOf value == String "destination" ->
                Object (KM.insert datumKey inline fields')
        _ -> value
    adjustEntries name f entries =
        case KM.lookup (Key.fromText name) entries of
            Just found -> KM.insert key (mapArray f found) entries
            Nothing -> entries
      where
        key = Key.fromText name
    mapArray f value = case value of
        Array found' -> Array (fmap f found')
        _ -> value

{- | One role of an accepted fold, and the step that hands the ledger a given
form for it: what a case calls the role, the array the observation reports it
in, the fold that spends it, and what that fold mints, pays and delivers.

Every role's fold carries every other role inline, so a case that varies one
role's form can say which role the observation read wrong.
-}
data Role = Role
    { roleName :: String
    , roleKey :: Text
    , roleArray :: Text
    , roleStep :: Datum ConwayEra -> RowCage -> LiveStep
    , roleMint :: [Value]
    , rolePayments :: [Payment]
    , roleDestination :: Integer
    }

{- | The three forms the ledger can carry, and what reading each honestly must
report: a carried datum is inline, one presented by hash is hashed, and one
presenting nothing is none.
-}
carriedForms :: [(String, Datum ConwayEra, String)]
carriedForms =
    [ ("carrying its datum inline", inlineDatum, "inline")
    , ("presenting its datum by hash", hashedDatum, "hashed")
    , ("presenting no datum", NoDatum, "none")
    ]

-- | The forms a ledger output that is not inline can present.
nonInlineForms :: [(String, Datum ConwayEra, String)]
nonInlineForms = drop 1 carriedForms

{- | One role's reported datum form, read off the observation of a fold the
ledger answered exactly as the case told it to.
-}
reports
    :: Text
    -> Text
    -> String
    -> LiveStep
    -> [Value]
    -> [Payment]
    -> Integer
    -> Expectation
reports array role reported step mint payments destination = do
    let transaction = lsTransactionOf step
    observation <-
        observedTx step transaction mint payments destination
    datumFormOf (entry array role observation)
        `shouldBe` String (T.pack reported)

{- | One role's reported datum field, reached by the same comparison the
chapters run. A ledger form the model does not expect must reach it as a
difference at that role's own datum field, and a fold where only that role
differs must produce exactly one difference.
-}
differsAt
    :: Text
    -> Text
    -> LiveStep
    -> [Value]
    -> [Payment]
    -> Integer
    -> Expectation
differsAt array role step mint payments destination = do
    surface <- declaredSurfaceOf
    let transaction = lsTransactionOf step
    observation <-
        observedTx step transaction mint payments destination
    let model = modelInlineForms observation
    case compareRegistration
        surface
        (asObservations model)
        (asObservations observation) of
        Right _ ->
            expectationFailure
                "a ledger datum form the model does not expect \
                \passed the comparison"
        Left differences -> do
            let paths = map snd (reportedDifferences differences)
                ownDatum =
                    [ Field array
                    , Index (entryIndex array role observation)
                    , Field "datum"
                    ]
            length paths `shouldBe` 1
            -- The one difference must be the named role's own entry: a form
            -- read off another role's output lands on another path and fails.
            paths `shouldSatisfy` elem ownDatum

-- The folds these cases book. Each takes the cage to run in and the forms
-- its own spent outputs present; a per-role fold below pins every other role
-- it touches to inline, so a case varying one role can say which role was
-- misread.

{- | A retirement spends a state, a request and an active witness, and
delivers no token: the witness is the only witness it can spend.
-}
retirement
    :: RowCage
    -> Datum ConwayEra
    -> Datum ConwayEra
    -> LiveStep
retirement cage stateForm witnessForm =
    fixtureStep
        cage
        Live.UpdateTerminal
        (Just (stateIn, spentState stateForm))
        (Just (witnessIn, spentWitness witnessForm))
        Nothing
        (spentRequest inlineDatum)
        ( submitted
            [stateIn, requestIn, witnessIn]
            [stateOutput, ownerOutput 4_000_000]
            mempty
        )

{- | An update spends a state, a request and an absent custody, and delivers a
token, so its destination is a physical carrier.
-}
update :: RowCage -> Datum ConwayEra -> Datum ConwayEra -> LiveStep
update cage stateForm custodyForm =
    fixtureStep
        cage
        Live.UpdateActive
        (Just (stateIn, spentState stateForm))
        Nothing
        (Just (custodyIn, spentCustody custodyForm))
        (spentRequest inlineDatum)
        ( submitted
            [stateIn, requestIn, custodyIn]
            [stateOutput, carrier inlineDatum]
            activeAsset
        )

{- | An insertion spends a state and a request, and delivers the active token
in the one output that carries it.
-}
delivery
    :: RowCage
    -> Datum ConwayEra
    -> Datum ConwayEra
    -> Datum ConwayEra
    -> LiveStep
delivery cage stateForm carrierForm requestForm =
    fixtureStep
        cage
        Live.InsertActive
        (Just (stateIn, spentState stateForm))
        Nothing
        Nothing
        (spentRequest requestForm)
        ( submitted
            [stateIn, requestIn]
            [stateOutput, carrier carrierForm]
            activeAsset
        )

-- | A fold whose only non-inline role is the state input it spends.
stateFold :: Datum ConwayEra -> RowCage -> LiveStep
stateFold form cage = delivery cage form inlineDatum inlineDatum

-- | A fold whose only non-inline role is the request input it spends.
requestFold :: Datum ConwayEra -> RowCage -> LiveStep
requestFold form cage = delivery cage inlineDatum inlineDatum form

-- | A fold whose only non-inline role is the absent custody it spends.
custodyFold :: Datum ConwayEra -> RowCage -> LiveStep
custodyFold form cage = update cage inlineDatum form

-- | A fold whose only non-inline role is the active witness it spends.
witnessFold :: Datum ConwayEra -> RowCage -> LiveStep
witnessFold form cage = retirement cage inlineDatum form

-- | A fold whose only non-inline role is the output it delivers.
destinationFold :: Datum ConwayEra -> RowCage -> LiveStep
destinationFold form cage = delivery cage inlineDatum form inlineDatum

spec :: Spec
spec =
    describe "Reading an observed exit's datum forms off the ledger" $ do
        let delivering =
                [Payment (Destination "holder") 3_000_000]
            activeMint = [mintedAsset "active" 1]
            roles =
                [ Role
                    { roleName = "the spent state input"
                    , roleKey = "state"
                    , roleArray = "inputs"
                    , roleStep = stateFold
                    , roleMint = activeMint
                    , rolePayments = delivering
                    , roleDestination = 1
                    }
                , Role
                    { roleName = "the spent request input"
                    , roleKey = "request"
                    , roleArray = "inputs"
                    , roleStep = requestFold
                    , roleMint = activeMint
                    , rolePayments = delivering
                    , roleDestination = 1
                    }
                , Role
                    { roleName = "the spent custody input"
                    , roleKey = "cage"
                    , roleArray = "inputs"
                    , roleStep = custodyFold
                    , roleMint = activeMint
                    , rolePayments = delivering
                    , roleDestination = 1
                    }
                , Role
                    { roleName = "the spent witness input"
                    , roleKey = "witness"
                    , roleArray = "inputs"
                    , roleStep = witnessFold
                    , roleMint = []
                    , rolePayments = []
                    , roleDestination = 0
                    }
                , Role
                    { roleName = "the delivered output"
                    , roleKey = "destination"
                    , roleArray = "outputs"
                    , roleStep = destinationFold
                    , roleMint = activeMint
                    , rolePayments = delivering
                    , roleDestination = 1
                    }
                ]

        -- Every role, in all three forms: the inline leg of each role is its
        -- control, and the two others are what the ledger can really carry.
        forM_ roles $ \role ->
            forM_ carriedForms $ \(told, form, reported) ->
                it
                    ( roleName role
                        <> ", "
                        <> told
                        <> ", is reported as "
                        <> reported
                    )
                    ( do
                        cage <- fixtureCage
                        reports
                            (roleArray role)
                            (roleKey role)
                            reported
                            (roleStep role form cage)
                            (roleMint role)
                            (rolePayments role)
                            (roleDestination role)
                    )

        -- The same comparison the chapters run, one role at a time: a ledger
        -- form the model does not expect must reach it at that role's field.
        forM_ roles $ \role ->
            forM_ nonInlineForms $ \(_, form, reported) ->
                it
                    ( "the ledger's "
                        <> reported
                        <> " "
                        <> roleName role
                        <> " reaches the comparison at its own datum field"
                    )
                    ( do
                        cage <- fixtureCage
                        differsAt
                            (roleArray role)
                            (roleKey role)
                            (roleStep role form cage)
                            (roleMint role)
                            (rolePayments role)
                            (roleDestination role)
                    )

        -- Each fold, with a distinct form per role, so reading any one role's
        -- form off another role's output fails the case.
        it "keeps each role's form bound to its own output on a delivery" $ do
            cage <- fixtureCage
            let step = delivery cage NoDatum inlineDatum hashedDatum
            observation <-
                observedTx step (lsTransactionOf step) activeMint delivering 1
            datumFormOf (entry "inputs" "state" observation)
                `shouldBe` String "none"
            datumFormOf (entry "inputs" "request" observation)
                `shouldBe` String "hashed"
            datumFormOf (entry "outputs" "destination" observation)
                `shouldBe` String "inline"

        it "keeps each role's form bound to its own output on an update" $ do
            cage <- fixtureCage
            let step = update cage NoDatum hashedDatum
            observation <-
                observedTx step (lsTransactionOf step) activeMint delivering 1
            datumFormOf (entry "inputs" "state" observation)
                `shouldBe` String "none"
            datumFormOf (entry "inputs" "cage" observation)
                `shouldBe` String "hashed"
            datumFormOf (entry "inputs" "request" observation)
                `shouldBe` String "inline"

        it "keeps each role's form bound to its own output on a retirement" $ do
            cage <- fixtureCage
            let step = retirement cage hashedDatum NoDatum
            observation <-
                observedTx step (lsTransactionOf step) [] [] 0
            datumFormOf (entry "inputs" "state" observation)
                `shouldBe` String "hashed"
            datumFormOf (entry "inputs" "witness" observation)
                `shouldBe` String "none"
            datumFormOf (entry "inputs" "request" observation)
                `shouldBe` String "inline"

        it "an all-inline observation keeps the comparison green" $ do
            surface <- declaredSurfaceOf
            cage <- fixtureCage
            let step =
                    delivery cage inlineDatum inlineDatum inlineDatum
            observation <-
                observedTx step (lsTransactionOf step) activeMint delivering 1
            let model = modelInlineForms observation
            case compareRegistration
                surface
                (asObservations model)
                (asObservations observation) of
                Left differences ->
                    expectationFailure
                        ( "an all-inline observation disagreed: "
                            <> show differences
                        )
                Right _ -> pure ()

        it "a spent input the transaction did not spend" $ do
            cage <- fixtureCage
            let state = Just (stateIn, spentState inlineDatum)
                request = spentRequest inlineDatum
                tx = submitted [stateIn] [stateOutput] mempty
                step =
                    ( fixtureStep
                        cage
                        Live.InsertActive
                        state
                        Nothing
                        Nothing
                        request
                        tx
                    )
                        { lsRequestIn = Just elsewhere
                        }
            observedTx step tx [] [] 0
                `shouldThrow` errorMentioning "request"

        it "a delivery more than one output carries is an error" $ do
            cage <- fixtureCage
            let state = Just (stateIn, spentState inlineDatum)
                request = spentRequest inlineDatum
                tx =
                    submitted
                        [stateIn, requestIn]
                        [ stateOutput
                        , carrier NoDatum
                        , carrier NoDatum
                        ]
                        activeAsset
                step =
                    fixtureStep
                        cage
                        Live.InsertActive
                        state
                        Nothing
                        Nothing
                        request
                        tx
            observedTx step tx activeMint delivering 1
                `shouldThrow` errorMentioning "destination"

        it "an accepted fold retaining no state input" $ do
            cage <- fixtureCage
            let request = spentRequest inlineDatum
                tx =
                    submitted
                        [stateIn, requestIn]
                        [stateOutput, carrier NoDatum]
                        activeAsset
                step =
                    fixtureStep
                        cage
                        Live.InsertActive
                        Nothing
                        Nothing
                        Nothing
                        request
                        tx
            observedTx step tx activeMint delivering 1
                `shouldThrow` errorMentioning "state"

        it "a witness the transaction did not spend" $ do
            cage <- fixtureCage
            let state = Just (stateIn, spentState inlineDatum)
                request = spentRequest inlineDatum
                tx =
                    submitted
                        [stateIn, requestIn]
                        [stateOutput, ownerOutput 4_000_000]
                        mempty
                step =
                    fixtureStep
                        cage
                        Live.UpdateTerminal
                        state
                        (Just (witnessIn, spentWitness inlineDatum))
                        Nothing
                        request
                        tx
            observedTx step tx [] [] 0
                `shouldThrow` errorMentioning "witness"

        it "a custody the transaction did not spend" $ do
            cage <- fixtureCage
            let state = Just (stateIn, spentState inlineDatum)
                request = spentRequest inlineDatum
                tx =
                    submitted
                        [stateIn, requestIn]
                        [stateOutput, carrier inlineDatum]
                        activeAsset
                step =
                    fixtureStep
                        cage
                        Live.UpdateActive
                        state
                        Nothing
                        (Just (custodyIn, spentCustody inlineDatum))
                        request
                        tx
            observedTx step tx activeMint delivering 1
                `shouldThrow` errorMentioning "custody"

        -- A held token sits on the output its delivery wrote: the census
        -- reads that output's own datum form for each token it carries.
        forM_ carriedForms $ \(told, form, reported) ->
            it
                ( "a held token on an output "
                    <> told
                    <> " is held as "
                    <> reported
                )
                ( do
                    forms <- heldForms [(custodyIn, carrier form)]
                    forms `shouldBe` [String (T.pack reported)]
                )

        it "keeps each held token's form bound to its own output" $ do
            forms <-
                heldForms
                    [ (custodyIn, carrier hashedDatum)
                    , (elsewhere, carrier NoDatum)
                    ]
            forms `shouldBe` [String "hashed", String "none"]

{- | The datum form of every holding the census reads off a holder's outputs,
in the order it reads them.
-}
heldForms :: [(TxIn, TxOut ConwayEra)] -> IO [Value]
heldForms outputs = do
    ids <- newLiveIdentities
    cage <- fixtureCage
    prepareRegistrationIdentities ids cage keyBytes holderWallet
    holdings <-
        walletHoldingsOf
            ids
            [keyBytes]
            [("active", SBS.fromShort (cfgActivePolicy fixtureCfg))]
            holderWallet
            outputs
    pure (map datumFormOf holdings)

-- | The transaction a fixture step submitted, as its outcome carries it.
lsTransactionOf :: LiveStep -> ConwayTx
lsTransactionOf step = case lsOutcome step of
    StepAccepted transaction _ -> transaction
    _ -> error "a fixture step is always accepted"

{- | One transaction observation inside the full observations object the
registration comparison compares: every declared name present, every other
observation empty and equal on both sides, so only the transaction's own
fields can differ.
-}
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

{- | Every refusal this observer raises on missing or ambiguous evidence
names the role whose evidence it could not read, as its witness and custody
refusals already do, so each case can hold it to one obligation. The state,
request and destination refusals are the repair's to write on those terms.
-}
errorMentioning :: Text -> ErrorCall -> Bool
errorMentioning role = T.isInfixOf role . T.pack . displayException
