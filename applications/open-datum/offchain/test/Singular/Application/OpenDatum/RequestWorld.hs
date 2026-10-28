{-# LANGUAGE DataKinds #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NumericUnderscores #-}

{- |
Module      : Singular.Application.OpenDatum.RequestWorld
Description : The compiled request validator, a chain to build against and a ledger to judge with
License     : Apache-2.0

What the request-builder rows share. The validator is the compiled script of
the application blueprint, read from the file the test runner names and checked
against the hash the pinned identity manifest records. The chain is an
in-memory set of outputs behind a real session, so a builder reads it the way
it reads a node. A built transaction is judged by the ledger's own script
evaluator on exactly the outputs the transaction names.

The encodings of the records are written here a second time, by hand, from the
validator's type definitions, so a row compares a builder's bytes with bytes it
did not produce.
-}
module Singular.Application.OpenDatum.RequestWorld
    ( -- * The compiled validator
      compiledScript
    , pinnedScriptHash
    , attachedScript
    , scriptHashOf

      -- * The scenario
    , configuredParameters
    , registryUnderTest
    , Scenario (..)
    , newScenario
    , newScenarioWith
    , adjustRegistrationField
    , registrationFields
    , handBooking
    , Return (..)
    , handReturn
    , bookingOf
    , firstBooking
    , bookWithScript
    , expectBuilt

      -- * Time
    , slotMs

      -- * The parties
    , network
    , keyAddress
    , baseAddress
    , scriptAddress
    , keyHashOf
    , seedIn
    , fundingIn
    , txInOf
    , ada

      -- * The chain
    , Chain
    , newChain
    , chainSession
    , setTip
    , addOutputs
    , removeOutputs
    , applyTransaction
    , lookupOutput

      -- * Judging a transaction
    , Purpose (..)
    , Judgement
    , judge
    , everyScriptAccepts
    , refusedBy

      -- * Reading a built transaction
    , outputsOf
    , inlineDatum
    , withDatum
    , valueAda
    , tokenQuantity
    , assetsOf
    , mintedOf
    , validityOf
    , signersOf
    , referencesOf
    , inputsOf
    , feeOf
    , outputRef
    , paidTo
    , outputsAt
    , soundnessProblems
    , validatorAddress
    , paymentKeyOf

      -- * Changing a built transaction
    , mapOutput
    , withMint
    , withSigners
    , withReferences
    , withoutInput
    , redeemersOf
    , withValidity

      -- * Hand-written encodings
    , oracleAddress
    , oracleConfiguration
    , oracleRegistry
    , oracleRegistration
    , oracleLive
    , oracleDatumHash

      -- * Outputs built without the builders
    , configurationOutput
    , Pending (..)
    , defaultPending
    , pendingOutput
    , pendingFixture
    , registrationOf
    , holdingOf
    , initialOf
    , approvalOf
    , approvalNameFor
    ) where

import Codec.Serialise (serialise)
import Crypto.Hash (Blake2b_256 (..), hashWith)
import Data.Aeson (Value (..), eitherDecodeFileStrict')
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteArray qualified as BA
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Lazy qualified as BL
import Data.ByteString.Short qualified as SBS
import Data.Foldable (toList)
import Data.IORef
    ( IORef
    , modifyIORef'
    , newIORef
    , readIORef
    , writeIORef
    )
import Data.List (sortOn)
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Sequence.Strict qualified as StrictSeq
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Word (Word8)
import Lens.Micro ((%~), (&), (.~), (^.))
import PlutusCore.Data qualified as PLC
import System.Environment (lookupEnv)
import Test.Hspec (expectationFailure)

import Cardano.Crypto.Hash
    ( Hash
    , HashAlgorithm
    , hashFromBytes
    , hashToBytes
    )
import Cardano.Ledger.Address (Addr (..))
import Cardano.Ledger.Allegra.Scripts (ValidityInterval (..))
import Cardano.Ledger.Alonzo.Scripts (AsIx (..))
import Cardano.Ledger.Alonzo.TxBody (reqSignerHashesTxBodyL)
import Cardano.Ledger.Api.Scripts.Data
    ( Data (..)
    , Datum (..)
    , binaryDataToData
    )
import Cardano.Ledger.Api.Tx
    ( bodyTxL
    , estimateMinFeeTx
    , mkBasicTx
    , txIdTx
    , witsTxL
    )
import Cardano.Ledger.Api.Tx.Body
    ( collateralInputsTxBodyL
    , feeTxBodyL
    , inputsTxBodyL
    , mintTxBodyL
    , mkBasicTxBody
    , outputsTxBodyL
    , referenceInputsTxBodyL
    , vldtTxBodyL
    )
import Cardano.Ledger.Api.Tx.Out
    ( addrTxOutL
    , coinTxOutL
    , datumTxOutL
    , getMinCoinTxOut
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
    ( Inject (..)
    , Network (..)
    , SlotNo
    , StrictMaybe (..)
    , TxIx (..)
    )
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Conway.Scripts (ConwayPlutusPurpose (..))
import Cardano.Ledger.Core (Script, hashScript)
import Cardano.Ledger.Credential
    ( Credential (..)
    , StakeReference (..)
    )
import Cardano.Ledger.Hashes (ScriptHash (..))
import Cardano.Ledger.Keys (KeyHash (..), KeyRole (..))
import Cardano.Ledger.Mary.Value
    ( AssetName (..)
    , MaryValue (..)
    , MultiAsset (..)
    , PolicyID (..)
    )
import Cardano.Ledger.Plutus.ExUnits (ExUnits (..))
import Cardano.Ledger.Plutus.TxInfo (transAddr)
import Cardano.Ledger.TxIn (TxIn (..))
import Cardano.Slotting.Slot (SlotNo (..))
import Cardano.Tx.Ledger (ConwayTx)
import PlutusLedgerApi.V3 qualified as PV3
import PlutusTx.Builtins.Internal (BuiltinByteString (..))

import Singular.Application.OpenDatum.Requests.Booking
    ( Booking (..)
    , buildBookRegistration
    )
import Singular.Application.OpenDatum.Requests.Refusal (Refusal)
import Singular.Application.OpenDatum.Requests.Script
    ( RequestScript (..)
    , ScriptSource (..)
    , requestScriptTitle
    )
import Singular.Registry.Blueprint
    ( extractCompiledCode
    , loadBlueprint
    )
import Singular.Registry.Deployment (parseOutRef)
import Singular.Registry.Evidence (Evidenced (..), NoWitness)
import Singular.Registry.Ledger (ConwayEra, TxOut)
import Singular.Registry.LedgerProvider
    ( OutputQuery (..)
    , Outputs
    , ReadFailure (..)
    , Session (..)
    , TipObservation (..)
    )
import Singular.Registry.SessionIO qualified as Services
import Singular.Registry.StubSession
    ( stubSession
    , withParameters
    , withTime
    )
import Singular.Registry.SyntheticLedger (withSyntheticCosts)
import Singular.Registry.SyntheticTime (syntheticTime)
import Singular.Registry.TrieState
    ( RegistryIdentity (..)
    , StatePolicyId (..)
    )
import Singular.Registry.TxBuilder.BookingFixture (preprodParams)
import Singular.Registry.TxBuilder.Internal
    ( mkInlineDatum
    , scriptFromBytes
    )
import Singular.State.Preimage
    ( activeTokenName
    , approvalName
    , configurationTokenName
    , registrationPreimage
    , stateTokenName
    )

-- ---------------------------------------------------------
-- The compiled validator
-- ---------------------------------------------------------

{- | The request validator, read from the blueprint the test runner names in
@OPEN_DATUM_BLUEPRINT@. A missing variable fails the row: a run that cannot
reach the compiled validator proves nothing.
-}
compiledScript :: IO (Script ConwayEra)
compiledScript = do
    path <- required "OPEN_DATUM_BLUEPRINT"
    blueprint <-
        loadBlueprint path >>= either (fail . ("blueprint: " <>)) pure
    code <-
        maybe
            (fail ("the blueprint carries no " <> T.unpack requestScriptTitle))
            pure
            (extractCompiledCode requestScriptTitle blueprint)
    pure (scriptFromBytes "open-datum-requests" code)

{- | The hash the pinned identity manifest (@OPEN_DATUM_SCRIPT_IDENTITY@)
records for the request validator.
-}
pinnedScriptHash :: IO ScriptHash
pinnedScriptHash = do
    path <- required "OPEN_DATUM_SCRIPT_IDENTITY"
    manifest <- eitherDecodeFileStrict' path >>= either fail pure
    entries <- case manifest of
        Object o
            | Just (Array vs) <- KeyMap.lookup (Key.fromText "validators") o ->
                pure (toList vs)
        _ -> fail "the identity manifest has no validators"
    case [ h
         | Object o <- entries
         , Just (String t) <- [KeyMap.lookup (Key.fromText "title") o]
         , t == requestScriptTitle
         , Just (String h) <- [KeyMap.lookup (Key.fromText "hash") o]
         ] of
        [hex] -> case B16.decode (encodeAscii hex) of
            Right bytes
                | Just h <- hashFromBytes bytes -> pure (ScriptHash h)
            _ -> fail "the pinned hash is not 28 bytes of hex"
        found ->
            fail
                ( "the manifest pins "
                    <> show (length found)
                    <> " hashes for the request validator"
                )
  where
    encodeAscii = BS.pack . map (fromIntegral . fromEnum) . T.unpack

required :: String -> IO FilePath
required name =
    lookupEnv name >>= \case
        Just value | not (null value) -> pure value
        _ -> fail (name <> " is not set: the rows need the compiled validator")

-- | The compiled validator, carried in the witness set.
attachedScript :: IO RequestScript
attachedScript = (`RequestScript` Attached) <$> compiledScript

-- ---------------------------------------------------------
-- Time
-- ---------------------------------------------------------

-- | POSIX milliseconds at the start of a slot of the synthetic network.
slotMs :: SlotNo -> Integer
slotMs (SlotNo s) = 1_000 * toInteger s

-- ---------------------------------------------------------
-- The parties
-- ---------------------------------------------------------

network :: Network
network = Testnet

hashBytes :: Word8 -> ByteString
hashBytes = BS.replicate 28

keyHashOf :: Word8 -> ByteString
keyHashOf = hashBytes

keyCredential :: Word8 -> Credential kr
keyCredential b = KeyHashObj (KeyHash (hashOf b))

scriptCredential :: Word8 -> Credential kr
scriptCredential b = ScriptHashObj (ScriptHash (hashOf b))

hashOf :: (HashAlgorithm h) => Word8 -> Hash h a
hashOf b = case hashFromBytes (hashBytes b) of
    Just h -> h
    Nothing -> error "a 28-byte hash"

-- | An enterprise address of a key.
keyAddress :: Word8 -> Addr
keyAddress b = Addr network (keyCredential b) StakeRefNull

-- | A base address of a key with a key stake credential.
baseAddress :: Word8 -> Word8 -> Addr
baseAddress b s = Addr network (keyCredential b) (StakeRefBase (keyCredential s))

{- | A base address of a script payment credential with a script stake
credential.
-}
scriptAddress :: Word8 -> Word8 -> Addr
scriptAddress b s =
    Addr network (scriptCredential b) (StakeRefBase (scriptCredential s))

txInOf :: Char -> Word -> TxIn
txInOf c ix =
    either
        (error . ("RequestWorld: " <>))
        id
        (parseOutRef (T.pack (replicate 64 c <> "#" <> show ix)))

-- | The output a registry's genesis spends.
seedIn :: TxIn
seedIn = txInOf '7' 0

-- | The payer's funding output.
fundingIn :: Char -> TxIn
fundingIn c = txInOf c 0

ada :: Integer -> Coin
ada n = Coin (n * 1_000_000)

-- ---------------------------------------------------------
-- The chain
-- ---------------------------------------------------------

-- | An in-memory set of outputs and the slot of the tip.
data Chain = Chain
    { chainOutputs :: IORef (Map.Map TxIn (TxOut ConwayEra))
    , chainTip :: IORef SlotNo
    }

newChain :: SlotNo -> [(TxIn, TxOut ConwayEra)] -> IO Chain
newChain tip outs = Chain <$> newIORef (Map.fromList outs) <*> newIORef tip

setTip :: Chain -> SlotNo -> IO ()
setTip chain = writeIORef (chainTip chain)

addOutputs :: Chain -> [(TxIn, TxOut ConwayEra)] -> IO ()
addOutputs chain outs =
    modifyIORef' (chainOutputs chain) (Map.union (Map.fromList outs))

removeOutputs :: Chain -> [TxIn] -> IO ()
removeOutputs chain refs =
    modifyIORef'
        (chainOutputs chain)
        (\known -> foldr Map.delete known refs)

lookupOutput :: Chain -> TxIn -> IO (Maybe (TxOut ConwayEra))
lookupOutput chain ref = Map.lookup ref <$> readIORef (chainOutputs chain)

{- | Apply a transaction as a block would: its inputs leave the set, its
outputs join it.
-}
applyTransaction :: Chain -> ConwayTx -> IO ()
applyTransaction chain tx = do
    let body = tx ^. bodyTxL
        created =
            [ (TxIn (txIdTx tx) (TxIx ix), out)
            | (ix, out) <- zip [0 ..] (toList (body ^. outputsTxBodyL))
            ]
    modifyIORef' (chainOutputs chain) $ \known ->
        Map.union
            (Map.fromList created)
            (foldr Map.delete known (Set.toList (body ^. inputsTxBodyL)))

-- | A session over the chain: raw reads, synthetic time and parameters.
chainSession :: Chain -> Session NoWitness IO
chainSession chain =
    ( withParameters
        (withSyntheticCosts preprodParams)
        (withTime (pure syntheticTime) stubSession)
    )
        { outputs = query
        , tipObservation = do
            SlotNo slot <- readIORef (chainTip chain)
            pure
                ( Right
                    ( Evidenced
                        (TipObservation (SlotNo slot) (BS.replicate 32 0) (fromIntegral slot) 0)
                        Nothing
                    )
                )
        }
  where
    query requested = do
        known <- readIORef (chainOutputs chain)
        pure (fmap (`Evidenced` Nothing) (run known requested))
    run
        :: Map.Map TxIn (TxOut ConwayEra)
        -> OutputQuery
        -> Either ReadFailure Outputs
    run known = \case
        AtAddress address ->
            Right
                [(i, o) | (i, o) <- Map.toAscList known, o ^. addrTxOutL == address]
        HoldingAsset (policy, name) ->
            Right
                [ (i, o)
                | (i, o) <- Map.toAscList known
                , tokenQuantity policy name o > 0
                ]
        AtTxIn ref -> case Map.lookup ref known of
            Just o -> Right [(ref, o)]
            Nothing -> Left (MissingOutput ref)
        CarryingReferenceScript wanted ->
            Right
                [ (i, o)
                | (i, o) <- Map.toAscList known
                , SJust s <- [o ^. referenceScriptTxOutL]
                , hashScript s == wanted
                ]
        AnyOf queries -> do
            found <- traverse (run known) (NE.toList queries)
            Right (union' (concat found))
        AllOf queries -> do
            found <- traverse (run known) (NE.toList queries)
            Right
                ( sortOn
                    fst
                    [x | x@(i, _) <- union' (concat found), all (elem i . map fst) found]
                )
    union' = Map.toAscList . Map.fromList

-- ---------------------------------------------------------
-- Judging a transaction
-- ---------------------------------------------------------

-- | The script purposes a request transaction can carry.
data Purpose = Mint | Spend | Other
    deriving stock (Eq, Ord, Show)

-- | The ledger's answer for each script purpose.
type Judgement = [(Purpose, Either String ExUnits)]

{- | The ledger's script evaluator on the transaction, with every spent,
collateral and reference input read from the chain.
-}
judge :: Chain -> ConwayTx -> IO Judgement
judge chain tx = do
    result <- Services.evaluateTx (chainSession chain) tx
    pure $
        sortOn
            fst
            [ (purposeOf p, either (Left . show) Right r)
            | (p, r) <- Map.toList result
            ]
  where
    purposeOf :: ConwayPlutusPurpose AsIx ConwayEra -> Purpose
    purposeOf = \case
        ConwayMinting _ -> Mint
        ConwaySpending _ -> Spend
        _ -> Other

{- | Every purpose ran and was accepted, using memory and steps: an empty
answer or a free run is not an acceptance.
-}
everyScriptAccepts :: Judgement -> Bool
everyScriptAccepts verdicts = not (null verdicts) && all ok verdicts
  where
    ok (_, Right (ExUnits memory steps)) = memory > 0 && steps > 0
    ok _ = False

-- | Some purpose was refused by its script.
refusedBy :: Judgement -> Bool
refusedBy = any (either (const True) (const False) . snd)

-- ---------------------------------------------------------
-- Reading a built transaction
-- ---------------------------------------------------------

outputsOf :: ConwayTx -> [TxOut ConwayEra]
outputsOf tx = toList (tx ^. bodyTxL . outputsTxBodyL)

inputsOf :: ConwayTx -> [TxIn]
inputsOf tx = Set.toAscList (tx ^. bodyTxL . inputsTxBodyL)

referencesOf :: ConwayTx -> [TxIn]
referencesOf tx = Set.toAscList (tx ^. bodyTxL . referenceInputsTxBodyL)

signersOf :: ConwayTx -> [ByteString]
signersOf tx =
    [ hashToBytes h
    | KeyHash h <- Set.toList (tx ^. bodyTxL . reqSignerHashesTxBodyL)
    ]

-- | The inline datum of an output.
inlineDatum :: TxOut ConwayEra -> Maybe PLC.Data
inlineDatum out = case out ^. datumTxOutL of
    Datum bd -> let Data d = binaryDataToData bd in Just d
    _ -> Nothing

withDatum :: PLC.Data -> TxOut ConwayEra -> TxOut ConwayEra
withDatum d out = out & datumTxOutL .~ mkInlineDatum d

valueAda :: TxOut ConwayEra -> Integer
valueAda out = let Coin c = out ^. coinTxOutL in c

tokenQuantity :: PolicyID -> AssetName -> TxOut ConwayEra -> Integer
tokenQuantity policy name out =
    let MaryValue _ (MultiAsset assets) = out ^. valueTxOutL
    in  fromMaybe 0 (Map.lookup policy assets >>= Map.lookup name)

-- | The assets an output holds besides ADA.
assetsOf :: TxOut ConwayEra -> [(PolicyID, AssetName, Integer)]
assetsOf out =
    let MaryValue _ (MultiAsset assets) = out ^. valueTxOutL
    in  [ (p, n, q)
        | (p, names) <- Map.toList assets
        , (n, q) <- Map.toList names
        ]

-- | What the transaction mints (positive) and burns (negative).
mintedOf :: ConwayTx -> [(PolicyID, AssetName, Integer)]
mintedOf tx =
    let MultiAsset assets = tx ^. bodyTxL . mintTxBodyL
    in  [ (p, n, q)
        | (p, names) <- Map.toList assets
        , (n, q) <- Map.toList names
        ]

-- | The validity interval as slots.
validityOf :: ConwayTx -> (Maybe SlotNo, Maybe SlotNo)
validityOf tx =
    let ValidityInterval lower upper = tx ^. bodyTxL . vldtTxBodyL
    in  (strict lower, strict upper)
  where
    strict (SJust s) = Just s
    strict SNothing = Nothing

-- ---------------------------------------------------------
-- Changing a built transaction
-- ---------------------------------------------------------

mapOutput
    :: Int -> (TxOut ConwayEra -> TxOut ConwayEra) -> ConwayTx -> ConwayTx
mapOutput index change tx =
    tx
        & bodyTxL . outputsTxBodyL
            .~ StrictSeq.fromList
                [ if i == index then change o else o
                | (i, o) <- zip [0 ..] (outputsOf tx)
                ]

withMint :: MultiAsset -> ConwayTx -> ConwayTx
withMint m tx = tx & bodyTxL . mintTxBodyL .~ m

withSigners :: [KeyHash Guard] -> ConwayTx -> ConwayTx
withSigners hs tx = tx & bodyTxL . reqSignerHashesTxBodyL .~ Set.fromList hs

withReferences :: [TxIn] -> ConwayTx -> ConwayTx
withReferences refs tx = tx & bodyTxL . referenceInputsTxBodyL .~ Set.fromList refs

withValidity :: Maybe SlotNo -> Maybe SlotNo -> ConwayTx -> ConwayTx
withValidity lower upper tx =
    tx & bodyTxL . vldtTxBodyL .~ ValidityInterval (lax lower) (lax upper)
  where
    lax = maybe SNothing SJust

-- ---------------------------------------------------------
-- Hand-written encodings
-- ---------------------------------------------------------

{- | A ledger address as the validator reads it, written from the definition
of the Plutus address: a credential (key 0, script 1), then an optional
staking credential (some 0, none 1) that is itself a credential inside the
staking-hash constructor 0.
-}
oracleAddress :: Addr -> PLC.Data
oracleAddress = \case
    Addr _ payment stake ->
        PLC.Constr 0 [credential payment, staking stake]
    _ -> error "oracleAddress: a Byron address has no Plutus form"
  where
    credential = \case
        KeyHashObj (KeyHash h) -> PLC.Constr 0 [PLC.B (hashBytesOf h)]
        ScriptHashObj (ScriptHash h) -> PLC.Constr 1 [PLC.B (hashBytesOf h)]
    staking = \case
        StakeRefNull -> PLC.Constr 1 []
        StakeRefBase c -> PLC.Constr 0 [PLC.Constr 0 [credential c]]
        StakeRefPtr _ -> error "oracleAddress: pointer addresses are not used"
    hashBytesOf = hashToBytes

-- | A configuration datum: constructor 0 holding the five parameters.
oracleConfiguration :: [Integer] -> PLC.Data
oracleConfiguration ps = PLC.Constr 0 [PLC.Constr 0 (map PLC.I ps)]

-- | A registry identity: the state policy and the state token name.
oracleRegistry :: RegistryIdentity -> PLC.Data
oracleRegistry (RegistryIdentity (StatePolicyId policy) (AssetName name)) =
    PLC.Constr 0 [PLC.B policy, PLC.B (SBS.fromShort name)]

-- | A pending registration datum: constructor 1 holding the ten fields.
oracleRegistration
    :: RegistryIdentity
    -> ByteString
    -> ByteString
    -> Addr
    -> Addr
    -> PLC.Data
    -> Integer
    -> (Integer, Integer, Integer)
    -> PLC.Data
oracleRegistration registry key controller refund holding initial deposit (booked, process, reclaim) =
    PLC.Constr
        1
        [ PLC.Constr
            0
            [ oracleRegistry registry
            , PLC.B key
            , PLC.B controller
            , oracleAddress refund
            , oracleAddress holding
            , initial
            , PLC.I deposit
            , PLC.I booked
            , PLC.I process
            , PLC.I reclaim
            ]
        ]

-- | A live holding datum: constructor 2 holding the control and the payload.
oracleLive
    :: RegistryIdentity
    -> ByteString
    -> ByteString
    -> Integer
    -> PLC.Data
    -> PLC.Data
oracleLive registry@(RegistryIdentity (StatePolicyId policy) _) key controller deposit payload =
    PLC.Constr
        2
        [ PLC.Constr
            0
            [ oracleRegistry registry
            , PLC.Constr
                0
                [PLC.B policy, PLC.B (assetBytes (activeTokenName registry key))]
            , PLC.B key
            , PLC.B controller
            , PLC.I deposit
            ]
        , payload
        ]

assetBytes :: AssetName -> ByteString
assetBytes (AssetName n) = SBS.fromShort n

-- | The hash a registration approval commits for an initial datum.
oracleDatumHash :: PLC.Data -> ByteString
oracleDatumHash d = BA.convert (hashWith Blake2b_256 (BL.toStrict (serialise d)))

-- ---------------------------------------------------------
-- Outputs built without the builders
-- ---------------------------------------------------------

{- | The configuration record of a registry as its creation leaves it: at the
address of the script, holding its one token, with the parameters inline.
-}
configurationOutput
    :: ScriptHash -> RegistryIdentity -> [Integer] -> TxOut ConwayEra
configurationOutput script registry parameters =
    mkBasicTxOut
        (Addr network (ScriptHashObj script) StakeRefNull)
        ( MaryValue
            (ada 3)
            ( MultiAsset
                ( Map.singleton
                    (PolicyID script)
                    (Map.singleton (configurationTokenName registry) 1)
                )
            )
        )
        & datumTxOutL .~ mkInlineDatum (oracleConfiguration parameters)

{- | A pending registration as booking leaves it, described without the
builders: whose it is, what it commits and what it holds.
-}
data Pending = Pending
    { pendingRegistry :: RegistryIdentity
    , pendingKey :: ByteString
    , pendingController :: ByteString
    , pendingRefund :: Addr
    , pendingPayload :: PLC.Data
    , pendingDeposit :: Integer
    , pendingValue :: Integer
    -- ^ The lovelace the request holds
    , pendingTimes :: (Integer, Integer, Integer)
    -- ^ Booked at, processing deadline, reclaim end (milliseconds)
    }

{- | A pending registration booked at slot 10060, with the deadlines of the
configuration the rows use: 600 seconds to process, 600 to reclaim.
-}
defaultPending :: RegistryIdentity -> Pending
defaultPending registry =
    Pending
        { pendingRegistry = registry
        , pendingKey = "a key"
        , pendingController = keyHashOf 0x11
        , pendingRefund = keyAddress 0x22
        , pendingPayload = PLC.I 42
        , pendingDeposit = 5_000_000
        , pendingValue = 6_000_000
        , pendingTimes = (10_060_000, 10_660_000, 11_260_000)
        }

{- | The output of a pending registration, made by hand from the preimage
codec and the hand-written encodings: at the address of the script, holding
the approval it commits and its value, with the registration inline.
-}
pendingOutput :: ScriptHash -> Pending -> TxOut ConwayEra
pendingOutput script pending =
    mkBasicTxOut
        (Addr network (ScriptHashObj script) StakeRefNull)
        ( MaryValue
            (Coin (pendingValue pending))
            ( MultiAsset
                ( Map.singleton
                    (PolicyID script)
                    (Map.singleton (approvalOf script pending) 1)
                )
            )
        )
        & datumTxOutL .~ mkInlineDatum (registrationOf script pending)

-- | The pending registration's datum.
registrationOf :: ScriptHash -> Pending -> PLC.Data
registrationOf script pending =
    oracleRegistration
        (pendingRegistry pending)
        (pendingKey pending)
        (pendingController pending)
        (pendingRefund pending)
        (holdingOf script)
        (initialOf pending)
        (pendingDeposit pending)
        (pendingTimes pending)

-- | The holding address a registration commits: the script's own.
holdingOf :: ScriptHash -> Addr
holdingOf script = Addr network (ScriptHashObj script) StakeRefNull

-- | The datum the holding starts with.
initialOf :: Pending -> PLC.Data
initialOf pending =
    oracleLive
        (pendingRegistry pending)
        (pendingKey pending)
        (pendingController pending)
        (pendingDeposit pending)
        (pendingPayload pending)

-- | The approval token of a pending registration, named by the codec.
approvalOf :: ScriptHash -> Pending -> AssetName
approvalOf script pending =
    approvalNameFor
        (pendingRegistry pending)
        (pendingKey pending)
        (holdingOf script)
        (initialOf pending)
        (pendingDeposit pending)

{- | The name of the approval of a registration: the preimage codec on the
key, the registry, the holding address, the hash of the initial datum and the
deposit.
-}
approvalNameFor
    :: RegistryIdentity
    -> ByteString
    -> Addr
    -> PLC.Data
    -> Integer
    -> AssetName
approvalNameFor registry key holding initial deposit =
    approvalName $
        registrationPreimage
            key
            registry
            (fromMaybe (error "no Plutus form") (transAddr holding))
            (PV3.DatumHash (BuiltinByteString (oracleDatumHash initial)))
            (PV3.Lovelace deposit)

{- | The pending registration as an output of the chain: where it sits and
what it is.
-}
pendingFixture :: ScriptHash -> Pending -> (TxIn, TxOut ConwayEra)
pendingFixture script pending =
    (txInOf '9' 0, pendingOutput script pending)

-- ---------------------------------------------------------
-- The scenario the builder rows share
-- ---------------------------------------------------------

{- | The parameters of the registry's configuration record: registration cost,
minimum tip, seconds to process and to reclaim (in milliseconds), and the
widest booking interval, all as the record carries them.
-}
configuredParameters :: [Integer]
configuredParameters = [2_000_000, 1_000_000, 600_000, 600_000, 60_000]

-- | The registry the rows work in: the state policy and the name its seed gives.
registryUnderTest :: RegistryIdentity
registryUnderTest =
    RegistryIdentity
        (StatePolicyId (BS.replicate 28 0xaa))
        (stateTokenName seedIn)

-- | A chain with a payer who has funds, and a registry with its record.
data Scenario = Scenario
    { scChain :: Chain
    , scScript :: RequestScript
    , scHash :: ScriptHash
    , scRegistry :: RegistryIdentity
    , scPayer :: Addr
    , scFunding :: TxIn
    , scRecord :: TxIn
    }

{- | A scenario at a tip slot: the payer's two ADA-only outputs, the
configuration record of the registry, and the compiled validator.
-}
newScenario :: SlotNo -> IO Scenario
newScenario = newScenarioWith configuredParameters

-- | A scenario whose registry is configured with these parameters.
newScenarioWith :: [Integer] -> SlotNo -> IO Scenario
newScenarioWith parameters tip = do
    script <- attachedScript
    let hash = hashScript (rsScript script)
        payer = keyAddress 0x41
        funding = fundingIn '3'
        record = txInOf '8' 0
    chain <-
        newChain
            tip
            [ (funding, mkBasicTxOut payer (inject (ada 100)))
            , (fundingIn '4', mkBasicTxOut payer (inject (ada 10)))
            , (record, configurationOutput hash registryUnderTest parameters)
            ]
    pure
        (Scenario chain script hash registryUnderTest payer funding record)

-- | The script's hash as the ledger computes it from the compiled code.
scriptHashOf :: RequestScript -> ScriptHash
scriptHashOf = hashScript . rsScript

-- | Change field @n@ of the registration inside a pending registration datum.
adjustRegistrationField
    :: Int -> (PLC.Data -> PLC.Data) -> PLC.Data -> PLC.Data
adjustRegistrationField n change = \case
    PLC.Constr 1 [PLC.Constr 0 fields] ->
        PLC.Constr
            1
            [ PLC.Constr
                0
                [if i == n then change f else f | (i, f) <- zip [0 ..] fields]
            ]
    other -> other

-- | The fields of the registration inside a pending registration datum.
registrationFields :: PLC.Data -> Maybe [PLC.Data]
registrationFields = \case
    PLC.Constr 1 [PLC.Constr 0 fields] -> Just fields
    _ -> Nothing

-- ---------------------------------------------------------
-- A transaction assembled by hand
-- ---------------------------------------------------------

{- | A booking assembled by hand from the hand-written encodings, with none of
the builders in it: the funding output is spent and collateral, the
configuration record is read, one request is paid to the validator's address
under the approval it commits, the approval is minted, the payer signs and the
interval is the one the configuration allows at the tip of the scenario.
It is the known-good transaction the judging is proven against.
-}
handBooking :: Scenario -> ConwayTx
handBooking sc =
    mkBasicTx body
        & witsTxL . scriptTxWitsL
            .~ Map.singleton (scHash sc) (rsScript (scScript sc))
        & witsTxL . rdmrsTxWitsL
            .~ Redeemers
                ( Map.singleton
                    (ConwayMinting (AsIx 0))
                    ( Data (PLC.List [PLC.Constr 1 [PLC.I 0]])
                    , ExUnits 1_000_000 1_000_000_000
                    )
                )
  where
    registry = scRegistry sc
    key = "hand key"
    controller = keyHashOf 0x41
    holding = Addr network (ScriptHashObj (scHash sc)) StakeRefNull
    deposit = 5_000_000
    initial = oracleLive registry key controller deposit (PLC.I 7)
    name = approvalNameFor registry key holding initial deposit
    booked = slotMs (SlotNo 10_060)
    datum =
        oracleRegistration
            registry
            key
            controller
            (keyAddress 0x22)
            holding
            initial
            deposit
            (booked, booked + 600_000, booked + 1_200_000)
    tokens =
        MultiAsset
            (Map.singleton (PolicyID (scHash sc)) (Map.singleton name 1))
    request =
        mkBasicTxOut holding (MaryValue (Coin 6_000_000) tokens)
            & datumTxOutL .~ mkInlineDatum datum
    body =
        mkBasicTxBody
            & inputsTxBodyL .~ Set.singleton (scFunding sc)
            & referenceInputsTxBodyL .~ Set.singleton (scRecord sc)
            & outputsTxBodyL .~ StrictSeq.singleton request
            & mintTxBodyL .~ tokens
            & collateralInputsTxBodyL .~ Set.singleton (scFunding sc)
            & reqSignerHashesTxBodyL .~ Set.singleton (KeyHash (hashOf 0x41))
            & vldtTxBodyL
                .~ ValidityInterval (SJust (SlotNo 10_000)) (SJust (SlotNo 10_060))

-- ---------------------------------------------------------
-- Booking in a scenario
-- ---------------------------------------------------------

-- | What a booker asks for: a key, its payload, the deposit, the tip and the refund address.
bookingOf
    :: ByteString -> PLC.Data -> Integer -> Integer -> Addr -> Booking
bookingOf key payload kept tipped refund =
    Booking
        { bookRegistry = registryUnderTest
        , bookKey = key
        , bookPayload = payload
        , bookDeposit = Coin kept
        , bookTip = Coin tipped
        , bookRefund = refund
        }

-- | A booking of a short key with a tip.
firstBooking :: Booking
firstBooking =
    bookingOf "first key" (PLC.I 42) 5_000_000 1_000_000 (keyAddress 0x22)

-- | Ask the builder for a booking, paid by the scenario's payer.
bookWithScript
    :: Scenario -> RequestScript -> Booking -> IO (Either Refusal ConwayTx)
bookWithScript sc script b =
    buildBookRegistration
        (chainSession (scChain sc))
        script
        b
        (scPayer sc)

-- | The transaction a builder returned; a refusal fails the row.
expectBuilt :: (Show r) => Either r a -> IO a
expectBuilt = \case
    Right built -> pure built
    Left refusal -> do
        expectationFailure ("the builder refused: " <> show refusal)
        fail "no transaction"

-- ---------------------------------------------------------
-- Reading what a built transaction pays
-- ---------------------------------------------------------

-- | The fee a transaction declares.
feeOf :: ConwayTx -> Integer
feeOf tx = let Coin f = tx ^. bodyTxL . feeTxBodyL in f

-- | The reference of the output at an index of a transaction.
outputRef :: ConwayTx -> Int -> TxIn
outputRef tx ix = TxIn (txIdTx tx) (TxIx (fromIntegral ix))

-- | The lovelace the outputs of a transaction pay to an address.
paidTo :: Addr -> ConwayTx -> Integer
paidTo address tx = sum [valueAda o | o <- outputsOf tx, o ^. addrTxOutL == address]

-- | The indices of the outputs of a transaction at an address.
outputsAt :: Addr -> ConwayTx -> [Int]
outputsAt address tx =
    [i | (i, o) <- zip [0 ..] (outputsOf tx), o ^. addrTxOutL == address]

-- | The address of the validator: its hash as payment credential, no stake part.
validatorAddress :: Scenario -> Addr
validatorAddress sc = Addr network (ScriptHashObj (scHash sc)) StakeRefNull

-- | The payment key hash of an address, when its payment credential is a key.
paymentKeyOf :: Addr -> Maybe ByteString
paymentKeyOf = \case
    Addr _ (KeyHashObj (KeyHash h)) _ -> Just (hashToBytes h)
    _ -> Nothing

-- | Which way a hand-assembled return goes.
data Return = ByReclaim | ByCleanup
    deriving stock (Eq, Show)

{- | A reclaim or a cleanup of a pending registration assembled by hand: the
registration and the funding output are spent, the approval is burned, the
refund address is paid, and the interval lies in the window of the return.
The reclaim names the refund address as signer and pays the whole request;
the cleanup names nobody and pays the deposit.
-}
handReturn :: Scenario -> Pending -> TxIn -> Return -> ConwayTx
handReturn sc held ref way =
    mkBasicTx body
        & witsTxL . scriptTxWitsL
            .~ Map.singleton (scHash sc) (rsScript (scScript sc))
        & witsTxL . rdmrsTxWitsL
            .~ Redeemers
                ( Map.fromList
                    [
                        ( ConwayMinting (AsIx 0)
                        , (Data (PLC.List [PLC.Constr 2 []]), ExUnits 1_000_000 1_000_000_000)
                        )
                    ,
                        ( ConwaySpending (AsIx (fromIntegral spendingIndex))
                        , (Data action, ExUnits 1_000_000 1_000_000_000)
                        )
                    ]
                )
  where
    inputs = Set.fromList [ref, scFunding sc]
    spendingIndex = Set.findIndex ref inputs
    burned =
        MultiAsset
            ( Map.singleton
                (PolicyID (scHash sc))
                (Map.singleton (approvalOf (scHash sc) held) (-1))
            )
    (action, paid, window, signers) = case way of
        ByReclaim ->
            ( PLC.Constr 1 []
            , pendingValue held
            , (SlotNo 10_700, SlotNo 11_200)
            , Set.fromList [KeyHash (hashOfRefund (pendingRefund held))]
            )
        ByCleanup ->
            ( PLC.Constr 2 []
            , pendingDeposit held
            , (SlotNo 11_300, SlotNo 11_400)
            , Set.empty
            )
    hashOfRefund = \case
        Addr _ (KeyHashObj (KeyHash h)) _ -> coerceHash h
        _ -> error "the refund address is not a key"
    coerceHash = id
    body =
        mkBasicTxBody
            & inputsTxBodyL .~ inputs
            & outputsTxBodyL
                .~ StrictSeq.singleton
                    (mkBasicTxOut (pendingRefund held) (inject (Coin paid)))
            & mintTxBodyL .~ burned
            & collateralInputsTxBodyL .~ Set.singleton (scFunding sc)
            & reqSignerHashesTxBodyL .~ signers
            & vldtTxBodyL
                .~ ValidityInterval (SJust (fst window)) (SJust (snd window))

-- | A transaction without one of its inputs.
withoutInput :: TxIn -> ConwayTx -> ConwayTx
withoutInput ref tx = tx & bodyTxL . inputsTxBodyL %~ Set.delete ref

-- | The redeemers a transaction declares, as the data of each.
redeemersOf :: ConwayTx -> [PLC.Data]
redeemersOf tx =
    let Redeemers declared = tx ^. witsTxL . rdmrsTxWitsL
    in  [d | (Data d, _) <- Map.elems declared]

-- ---------------------------------------------------------
-- What the ledger requires beside the validator
-- ---------------------------------------------------------

{- | The ledger rules a builder can break without the validator noticing, as
the problems found: the value the transaction spends and mints is not the value
it pays and burns as fee; the fee is below the minimum for one signature; an
output holds less than its minimum ADA; no collateral is declared. The fee rule
is checked only for a script the transaction attaches, because the minimum
for a reference script is charged per byte of the script it references.
-}
soundnessProblems :: Chain -> ConwayTx -> IO [String]
soundnessProblems chain tx = do
    spent <-
        mapM
            ( \ref ->
                lookupOutput chain ref
                    >>= maybe (fail ("no output " <> show ref)) pure
            )
            (inputsOf tx)
    let pp = withSyntheticCosts preprodParams
        body = tx ^. bodyTxL
        Coin fee = body ^. feeTxBodyL
        valueIn =
            mconcat (map (^. valueTxOutL) spent)
                <> MaryValue (Coin 0) (body ^. mintTxBodyL)
        valueOut =
            mconcat (map (^. valueTxOutL) (outputsOf tx))
                <> MaryValue (Coin fee) mempty
        attached = not (Map.null (tx ^. witsTxL . scriptTxWitsL))
        minimumFee = estimateMinFeeTx pp tx 1 0 0
        thin =
            [ i
            | (i, o) <- zip [0 :: Int ..] (outputsOf tx)
            , o ^. coinTxOutL < getMinCoinTxOut pp o
            ]
    pure $
        [ "value is not conserved: "
            <> show valueIn
            <> " in, "
            <> show valueOut
            <> " out"
        | valueIn /= valueOut
        ]
            <> [ "the fee " <> show fee <> " is below the minimum " <> show minimumFee
               | attached && Coin fee < minimumFee
               ]
            <> [ "outputs " <> show thin <> " hold less than their minimum ADA"
               | not (null thin)
               ]
            <> [ "no collateral is declared"
               | Set.null (body ^. collateralInputsTxBodyL)
               ]
