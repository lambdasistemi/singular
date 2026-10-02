{-# LANGUAGE GADTs #-}

{- |
Module      : Conformance.Run.Wire
Description : The wire round-trip vocabulary, executed against the compiled blueprint and the devnet
License     : Apache-2.0

One interpreter for every serialization row: it executes the instructions of
"Conformance.Wire.Programs", one case per instruction. Encoding and parameter
instructions read the compiled blueprint at @REGISTRY_BLUEPRINT@ and need no
node; the others act on the session's devnet through the registry's own
builders and read their results back from the chain. A row's receipt is
written from what its program cites: the transactions it measures, the
constructors it witnessed, the residuals it declares, or the refusal it
attributed.

A control demands the opposite of every instruction it arms, so a run under
it must fail where that instruction runs.
-}
module Conformance.Run.Wire
    ( runWireLocalRow
    , runWireSession
    ) where

import Conformance.Replay (admittedFor)
import Conformance.Run.Cage (ensureStateRefWith)
import Conformance.Run.Control
import Conformance.Run.Environment
import Conformance.Run.Observe
import Conformance.Run.Receipts (debtReport)
import Conformance.Run.Replay
    ( ReplayIndex (..)
    , purposesOf
    , replayEvidenceOf
    , sessionCorrespondence
    )
import Conformance.Run.Submit
import Conformance.Run.Units
import Conformance.Run.Wallet
import Conformance.Story.Live qualified as Live
import Conformance.Wire.Programs
    ( Constructor (..)
    , Encoding (..)
    , Instruction (..)
    , Parameters (..)
    , Program (..)
    , Purpose (..)
    , ReadBackDatum (..)
    , Registry (..)
    , Requirement (..)
    , Residual (..)
    , ResidualKind (..)
    , Sample (..)
    , Standing (..)
    , Transaction (..)
    , Validator (..)
    , Variation (..)
    , armedBy
    , instructionReading
    )

import Control.Concurrent (threadDelay)
import Control.Exception (ErrorCall (..), throwIO)
import Control.Monad (unless, void)
import Data.Aeson qualified as Aeson
import Data.Aeson.Types qualified as AesonTypes
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.ByteString.Lazy qualified as BSL
import Data.ByteString.Short qualified as SBS
import Data.Foldable (toList)
import Data.IORef
    ( IORef
    , modifyIORef'
    , newIORef
    , readIORef
    , writeIORef
    )
import Data.List (intercalate, isInfixOf, nub)
import Data.List.NonEmpty (nonEmpty)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Lens.Micro ((&), (.~), (^.))
import System.Directory (getFileSize)
import System.FilePath ((</>))

import Cardano.Ledger.Api.Scripts.Data (Datum (..))
import Cardano.Ledger.Api.Tx (bodyTxL, mkBasicTx, witsTxL)
import Cardano.Ledger.Api.Tx.Body
    ( outputsTxBodyL
    , scriptIntegrityHashTxBodyL
    )
import Cardano.Ledger.Api.Tx.Out (datumTxOutL)
import Cardano.Ledger.Api.Tx.Wits
    ( Redeemers (..)
    , rdmrsTxWitsL
    , scriptTxWitsL
    )
import Cardano.Ledger.Core (hashScript)
import Cardano.Ledger.Plutus.Data qualified as Ledger
import Cardano.Ledger.TxIn (TxIn (..))
import Cardano.Tx.Ledger (ConwayTx)

import PlutusCore.Data (Data (..))
import PlutusCore.Data qualified as PLC
import PlutusTx.Builtins.Internal
    ( BuiltinByteString (..)
    , BuiltinData (..)
    )
import PlutusTx.IsData.Class (ToData (..))
import Singular.Registry.Blueprint
    ( Blueprint (..)
    , NamingCodes (..)
    , Schema (..)
    , applyPreviousPolicies
    , applyRequestParams
    , extractCompiledCode
    , loadBlueprint
    , validateData
    )
import Singular.Registry.Blueprint qualified as Blueprint
import Singular.Registry.Config (CageConfig (..))
import Singular.Registry.Ledger
    ( ConwayEra
    , ExUnits (..)
    , Root (..)
    , TokenId (..)
    , TxOut
    )
import Singular.Registry.Node
    ( Capabilities (..)
    , checkFunding
    , defaultFundingFloor
    , funderAddr
    , signTx
    , signedTx
    , submitSigned
    )
import Singular.Registry.Node qualified as Node
import Singular.Registry.Provider qualified as Cage
import Singular.Registry.Trie (TrieManager (..))
import Singular.Registry.Trie qualified as CageTrie
import Singular.Registry.Trie.PureManager (mkPureTrieManager)
import Singular.Registry.TxBuilder.Boot (bootTokenImpl)
import Singular.Registry.TxBuilder.Edges qualified as RegistryEdges
import Singular.Registry.TxBuilder.Internal
    ( cageAddrFromCfg
    , cagePolicyIdFromCfg
    , computeScriptHash
    , computeScriptIntegrity
    , extractCageDatum
    , findRequestUtxos
    , findStateUtxo
    , onChainTokenId
    , requestAddrFromCfg
    , scriptHashBytes
    , toPlcData
    , txInToRef
    , walkEdge
    )
import Singular.Registry.TxBuilder.Reject (rejectRequestsImpl)
import Singular.Registry.TxBuilder.Request (requestEdgeImpl)
import Singular.Registry.TxBuilder.Retract (retractRequestImpl)
import Singular.Registry.TxBuilder.Update (updateTokenWithDuties)
import Singular.Registry.Types
    ( CageDatum (..)
    , Migration (..)
    , MintRedeemer (..)
    , Neighbor (..)
    , OnChainRequest (..)
    , OnChainRoot (..)
    , OnChainTokenId (..)
    , OnChainTokenState (..)
    , OnChainTxOutRef (..)
    , ProofStep (..)
    , RequestAction (..)
    , UpdateRedeemer (..)
    , edgeDeleteAbsent
    , edgeDeleteActive
    , edgeInsertAbsent
    , edgeInsertActive
    , edgeUpdateActive
    , edgeUpdateTerminal
    , edgeWitnessTerminal
    )

import Conformance.Mirror
    ( emit
    , failWith
    , hex
    , readChainState
    , require
    , txIdHex
    )
import Conformance.Receipt
    ( ConstructorEvidence (..)
    , ConstructorStanding (..)
    , Outcome (..)
    , PartialInfo (..)
    , Receipt (..)
    , RefusalInfo (..)
    , ReplayCorrespondence
    , Verdict (..)
    , loadReceipts
    , writeReceiptFile
    )
import Conformance.Refusal
    ( matchRefusal
    , refusalScriptHashes
    , trimRefusal
    , wrongReasonMarker
    )

-- ---------------------------------------------------------
-- Rows checked against the compiled blueprint alone
-- ---------------------------------------------------------

-- | Run one serialization row that needs no node, and write its receipt.
runWireLocalRow
    :: FilePath -> FilePath -> String -> Bool -> Control -> Program -> IO ()
runWireLocalRow blueprintPath receiptsDir base dirty control program = do
    blueprint <-
        either (failWith . ("blueprint does not parse: " <>)) pure
            =<< loadBlueprint blueprintPath
    raw <- BS.readFile blueprintPath
    document <-
        either
            (failWith . ("blueprint JSON does not parse: " <>))
            pure
            (Aeson.eitherDecodeStrict' raw)
    fileSize <- fromIntegral <$> getFileSize blueprintPath
    sizes <- newIORef []
    let local =
            Local
                { localBlueprint = blueprint
                , localTitles = extractTitles document
                , localParameters = extractParameters document
                , localFileSize = fileSize
                , localSizes = sizes
                }
    mapM_ (localStep local control row) (programInstructions program)
    measured <- readIORef sizes
    nodeVersion <- readNodeVersion
    blueprintName <- either failWith pure (blueprintIdentity blueprint)
    writeReceiptFile
        receiptsDir
        Receipt
            { receiptRow = T.pack row
            , receiptOutcome = Accepted
            , receiptVerdict = AgreesWithModel
            , receiptTransactions = []
            , receiptRefusal = Nothing
            , receiptRejected = Nothing
            , receiptMem = Just 0
            , receiptCpu = Just 0
            , receiptTxSize = Just (maximum (0 : measured))
            , receiptBase = T.pack base
            , receiptDirty = dirty
            , receiptPartial = Nothing
            , receiptDerivation = Nothing
            , receiptSteps = Nothing
            , receiptReplayCorrespondence = Nothing
            , receiptNode = T.pack nodeVersion
            , receiptBlueprint = T.pack blueprintName
            , receiptVenue = localVenue (programInstructions program)
            }
    emit "row" (row <> ": every instruction held")
  where
    row = programRow program

-- | Where a local row's evidence comes from: parameter checks or schema checks.
localVenue :: [Instruction] -> Text
localVenue instructions
    | any isParameterCheck instructions = "param-check"
    | otherwise = "blueprint-check"
  where
    isParameterCheck i = case i of
        ParametersDeclared{} -> True
        UnappliedHashPinned{} -> True
        ExtraApplicationChangesHash _ -> True
        RequestApplicationDiscriminates -> True
        _ -> False

data Local = Local
    { localBlueprint :: Blueprint
    , localTitles :: TitleMap
    , localParameters :: ParameterMap
    , localFileSize :: Integer
    , localSizes :: IORef [Integer]
    -- ^ the size of every artifact an instruction read
    }

localStep :: Local -> Control -> String -> Instruction -> IO ()
localStep local control row instruction = do
    case instruction of
        EncodingConforms sample definition encoding -> do
            SampleValue value <- pure (sampleValue sample)
            let encoded = dataOf value
            case realFromData encoded of
                Just decoded
                    | decoded == value -> pure ()
                    | otherwise ->
                        failWith (label <> ": " <> reading <> " decodes to another value")
                Nothing -> failWith (label <> ": " <> reading <> " does not decode")
            unless (armed && isConstructorAt encoding) $
                requireSchema definition encoded
            case encoding of
                ConstructorAt index -> case encoded of
                    Constr found _ ->
                        require
                            (label <> ": " <> reading <> " is constructor " <> show found)
                            (if armed then found /= index else found == index)
                    other ->
                        failWith
                            (label <> ": " <> reading <> " is not a constructor: " <> show other)
                PlainBytes -> case encoded of
                    B _ -> pure ()
                    other ->
                        failWith
                            (label <> ": " <> reading <> " is not plain bytes: " <> show other)
                SchemaOnly -> pure ()
            readBlueprint
        RequestFieldAt position name -> do
            wanted <-
                maybe
                    (failWith (label <> ": no request field is named " <> name))
                    pure
                    (lookup name requestFields)
            case dataOf sampleRequest of
                Constr 0 fields
                    | length fields > position
                    , I found <- fields !! position ->
                        require
                            (label <> ": field " <> show position <> " is " <> show found)
                            (found == wanted)
                other ->
                    failWith
                        (label <> ": the request is not shaped as expected: " <> show other)
            readBlueprint
        FieldOrder definition constructor fields -> do
            case Map.lookup (T.pack definition) (localTitles local) of
                Nothing ->
                    failWith (label <> ": the blueprint has no titles for " <> definition)
                Just constructors -> case [fs | (title, _, fs) <- constructors, title == T.pack constructor] of
                    found : _ ->
                        require
                            ( label
                                <> ": the field order is "
                                <> show found
                                <> ", want "
                                <> show fields
                            )
                            (found == map T.pack fields)
                    [] ->
                        failWith
                            (label <> ": no constructor " <> constructor <> " in " <> definition)
            readBlueprint
        UnnamedConstructorRefused definition index -> do
            schema <- definitionOf definition
            require
                ( label
                    <> ": constructor "
                    <> show index
                    <> " validates against "
                    <> definition
                )
                (not (validateData definitions schema (Constr index [])))
            readBlueprint
        FixedTupleArity definition arity -> do
            schema <- definitionOf definition
            let longer = List (replicate (arity + 1) (B "element"))
                validates = validateData definitions schema longer
            require
                ( label
                    <> ": a list of "
                    <> show (arity + 1)
                    <> ( if armed
                            then
                                " elements was demanded to validate and was refused, as the fixed tuple requires"
                            else " elements validates against " <> definition
                       )
                )
                (if armed then validates else not validates)
            readBlueprint
        ParametersDeclared (Validator name) declared -> do
            found <- case lookupParameters (localParameters local) name of
                Nothing -> failWith (label <> ": the blueprint has no validator " <> name)
                Just f -> pure f
            let holds = case (declared, found) of
                    (NoParameterField, Nothing) -> True
                    (NoParameters, Nothing) -> True
                    (NoParameters, Just []) -> True
                    (ExactParameters wanted, Just ps) -> ps == [(T.pack t, T.pack s) | (t, s) <- wanted]
                    _ -> False
            require
                (label <> ": " <> name <> " declares " <> show found)
                (if armed then not holds else holds)
        UnappliedHashPinned (Validator name) requirement ->
            case ( validatorTitled name
                 , extractCompiledCode (T.pack name) (localBlueprint local)
                 ) of
                (Just v, Just code) -> do
                    let computed = hexBytes (scriptHashBytes (computeScriptHash code))
                        pinned = T.unpack (Blueprint.vHash v)
                    require
                        ( label
                            <> ": "
                            <> name
                            <> "'s unapplied hash "
                            <> computed
                            <> " is not the blueprint's "
                            <> pinned
                        )
                        (computed == pinned)
                    modifyIORef' (localSizes local) (fromIntegral (SBS.length code) :)
                _
                    | requirement == IfPresent ->
                        emit "held" (label <> ": " <> name <> " is absent, as it may be")
                    | otherwise ->
                        failWith (label <> ": the blueprint has no " <> name <> " code")
        ExtraApplicationChangesHash (Validator name) -> do
            code <- codeOf name
            require
                ( label
                    <> ": one extra application leaves "
                    <> name
                    <> "'s hash unchanged"
                )
                ( computeScriptHash (applyPreviousPolicies [] code)
                    /= computeScriptHash code
                )
        RequestApplicationDiscriminates -> do
            stateCode <- codeOf "state.state"
            requestCode <- codeOf "request.request"
            let token = OnChainTokenId (BuiltinByteString "cs06-token")
                OnChainTokenId (BuiltinByteString tokenBytes) = token
                statePolicy = scriptHashBytes (computeScriptHash stateCode)
                applied = applyRequestParams statePolicy token requestCode
                swapped =
                    applyRequestParams
                        tokenBytes
                        (OnChainTokenId (BuiltinByteString statePolicy))
                        requestCode
                hashOf = computeScriptHash
            require
                (label <> ": applying the request parameters leaves its hash unchanged")
                (hashOf applied /= hashOf requestCode)
            require
                (label <> ": swapping the request parameters gives the same hash")
                (hashOf swapped /= hashOf applied)
            modifyIORef' (localSizes local) (fromIntegral (SBS.length applied) :)
        other ->
            failWith (label <> ": needs the devnet: " <> instructionReading other)
    emit "held" (row <> ": " <> instructionReading instruction)
  where
    armed = armedBy (controlName control) instruction
    label =
        if armed then row <> " ARMED (" <> controlName control <> ")" else row
    reading = case instruction of
        EncodingConforms sample _ _ -> show sample
        _ -> ""
    definitions = definitionsOf (localBlueprint local)
    definitionOf name =
        maybe
            (failWith (label <> ": the blueprint has no definition " <> name))
            pure
            (Map.lookup (T.pack name) definitions)
    requireSchema definition encoded = do
        schema <- definitionOf definition
        require
            ( label
                <> ": "
                <> reading
                <> " does not validate against "
                <> definition
                <> ": "
                <> show encoded
            )
            (validateData definitions schema encoded)
    readBlueprint = modifyIORef' (localSizes local) (localFileSize local :)
    validatorTitled name =
        case filter
            ((T.pack name `T.isPrefixOf`) . Blueprint.vTitle)
            (validators (localBlueprint local)) of
            v : _ -> Just v
            [] -> Nothing
    codeOf name =
        maybe
            (failWith (label <> ": the blueprint has no " <> name <> " code"))
            pure
            (extractCompiledCode (T.pack name) (localBlueprint local))
    isConstructorAt ConstructorAt{} = True
    isConstructorAt _ = False

definitionsOf :: Blueprint -> Map.Map Text Schema
definitionsOf = Blueprint.definitions

-- ---------------------------------------------------------
-- Samples
-- ---------------------------------------------------------

-- | A sample value with its encoder and the mirrored decoder it must round-trip through.
data SampleValue where
    SampleValue :: (ToData a, RealFromData a, Eq a) => a -> SampleValue

dataOf :: (ToData a) => a -> Data
dataOf x = let BuiltinData d = toBuiltinData x in d

sampleValue :: Sample -> SampleValue
sampleValue sample = case sample of
    TokenIdentifier -> SampleValue sampleToken
    OutputReference -> SampleValue sampleReference
    TrieRoot -> SampleValue (OnChainRoot (BS.replicate 32 0))
    RequestSample -> SampleValue sampleRequest
    RequestOnEdge edge -> SampleValue sampleRequest{requestEdge = edge}
    StateSample -> SampleValue sampleState
    StateWithActivePolicyVaried ->
        SampleValue
            sampleState{stateActivePolicy = BuiltinByteString (BS.replicate 28 7)}
    RequestDatumSample -> SampleValue (RequestDatum sampleRequest)
    StateDatumSample -> SampleValue (StateDatum sampleState)
    AbsentCustodySample -> SampleValue (AbsentCustody "cs01-refund")
    MintingSample -> SampleValue (Minting sampleReference)
    MigratingSample -> SampleValue (Migrating sampleMigration)
    BurningSample -> SampleValue (Burning sampleToken)
    MigrationSample -> SampleValue sampleMigration
    UpdateSample -> SampleValue (Update [sampleBranch, sampleFork, sampleLeaf])
    RejectedSample -> SampleValue Rejected
    EndSample -> SampleValue End
    ContributeSample -> SampleValue (Contribute sampleReference)
    ModifySample -> SampleValue (Modify [Update [sampleLeaf], Rejected])
    RetractSample -> SampleValue (Retract sampleReference)
    SweepSample -> SampleValue (Sweep sampleReference)
    BranchSample -> SampleValue sampleBranch
    ForkSample -> SampleValue sampleFork
    LeafSample -> SampleValue sampleLeaf
    NeighborSample -> SampleValue sampleNeighbor

-- | The request fields a position check can name, read off the sample request.
requestFields :: [(String, Integer)]
requestFields =
    [ ("edge", requestEdge sampleRequest)
    , ("deposit", requestDeposit sampleRequest)
    ]

sampleToken :: OnChainTokenId
sampleToken = OnChainTokenId (BuiltinByteString "test-token-asset")

sampleReference :: OnChainTxOutRef
sampleReference = OnChainTxOutRef (BuiltinByteString (BS.replicate 32 0)) 0

sampleRequest :: OnChainRequest
sampleRequest =
    OnChainRequest
        { requestToken = sampleToken
        , requestOwner = BuiltinByteString (BS.replicate 28 0)
        , requestKey = "cs01-key"
        , requestEdge = edgeInsertActive
        , requestDeposit = 1000000
        , requestSubmittedAt = 1234567890
        , requestDestination = ("cs01-address", "cs01-datum-hash")
        }

sampleState :: OnChainTokenState
sampleState =
    OnChainTokenState
        { stateRoot = OnChainRoot (BS.replicate 32 0)
        , stateMaxFee = 1000000
        , stateProcessTime = 30000
        , stateRetractTime = 30000
        , stateAppPolicy = BuiltinByteString (BS.replicate 28 6)
        , stateActivePolicy = BuiltinByteString (BS.replicate 28 8)
        , stateAbsentPolicy = BuiltinByteString (BS.replicate 28 9)
        , stateTerminalPolicy = BuiltinByteString (BS.replicate 28 10)
        }

sampleMigration :: Migration
sampleMigration = Migration (BuiltinByteString (BS.replicate 28 1)) sampleToken

sampleNeighbor :: Neighbor
sampleNeighbor = Neighbor 5 "ab" (BS.replicate 32 2)

sampleBranch, sampleFork, sampleLeaf :: ProofStep
sampleBranch = Branch 1 (BS.replicate 128 3)
sampleFork = Fork 2 sampleNeighbor
sampleLeaf = Leaf 0 "leaf-key" (BS.replicate 32 4)

{- | A decoder mirrored from the shape of the real 'FromData' instances, so a
sample's round trip does not test a codec against itself alone: the blueprint
schema is the binding verdict, and the round trip shows the Haskell side at
least decodes what it encodes.
-}
class RealFromData a where
    realFromData :: Data -> Maybe a

instance RealFromData OnChainTokenId where
    realFromData (Constr 0 [B bs]) = Just (OnChainTokenId (BuiltinByteString bs))
    realFromData _ = Nothing

instance RealFromData OnChainTxOutRef where
    realFromData (Constr 0 [B tid, I idx]) = Just (OnChainTxOutRef (BuiltinByteString tid) idx)
    realFromData _ = Nothing

instance RealFromData OnChainRoot where
    realFromData (B bs) = Just (OnChainRoot bs)
    realFromData _ = Nothing

instance RealFromData OnChainRequest where
    realFromData
        ( Constr
                0
                [ token
                    , B owner
                    , B key
                    , I edge
                    , I deposit
                    , I submitted
                    , List [B address, B datumHash]
                    ]
            ) = do
            t <- realFromData token
            Just
                OnChainRequest
                    { requestToken = t
                    , requestOwner = BuiltinByteString owner
                    , requestKey = key
                    , requestEdge = edge
                    , requestDeposit = deposit
                    , requestSubmittedAt = submitted
                    , requestDestination = (address, datumHash)
                    }
    realFromData _ = Nothing

instance RealFromData OnChainTokenState where
    realFromData
        ( Constr
                0
                [ root
                    , I maxFee
                    , I process
                    , I retract
                    , B application
                    , B active
                    , B absent
                    , B terminal
                    ]
            ) = do
            r <- realFromData root
            Just
                OnChainTokenState
                    { stateRoot = r
                    , stateMaxFee = maxFee
                    , stateProcessTime = process
                    , stateRetractTime = retract
                    , stateAppPolicy = BuiltinByteString application
                    , stateActivePolicy = BuiltinByteString active
                    , stateAbsentPolicy = BuiltinByteString absent
                    , stateTerminalPolicy = BuiltinByteString terminal
                    }
    realFromData _ = Nothing

instance RealFromData CageDatum where
    realFromData (Constr 0 [d]) = RequestDatum <$> realFromData d
    realFromData (Constr 1 [d]) = StateDatum <$> realFromData d
    realFromData (Constr 2 [B refund]) = Just (AbsentCustody refund)
    realFromData _ = Nothing

instance RealFromData Migration where
    realFromData (Constr 0 [B policy, token]) = Migration (BuiltinByteString policy) <$> realFromData token
    realFromData _ = Nothing

instance RealFromData MintRedeemer where
    realFromData (Constr 0 [d]) = Minting <$> realFromData d
    realFromData (Constr 1 [d]) = Migrating <$> realFromData d
    realFromData (Constr 2 [d]) = Burning <$> realFromData d
    realFromData _ = Nothing

instance RealFromData Neighbor where
    realFromData (Constr 0 [I nibble, B prefix, B root]) = Just (Neighbor nibble prefix root)
    realFromData _ = Nothing

instance RealFromData ProofStep where
    realFromData (Constr 0 [I skip, B neighbors]) = Just (Branch skip neighbors)
    realFromData (Constr 1 [I skip, neighbor]) = Fork skip <$> realFromData neighbor
    realFromData (Constr 2 [I skip, B key, B value]) = Just (Leaf skip key value)
    realFromData _ = Nothing

instance RealFromData RequestAction where
    realFromData (Constr 0 [List steps]) = Update <$> traverse realFromData steps
    realFromData (Constr 1 []) = Just Rejected
    realFromData _ = Nothing

instance RealFromData UpdateRedeemer where
    realFromData (Constr 0 []) = Just End
    realFromData (Constr 1 [d]) = Contribute <$> realFromData d
    realFromData (Constr 2 [List actions]) = Modify <$> traverse realFromData actions
    realFromData (Constr 3 [d]) = Retract <$> realFromData d
    realFromData (Constr 4 [d]) = Sweep <$> realFromData d
    realFromData _ = Nothing

-- ---------------------------------------------------------
-- Blueprint JSON: field titles and parameters
-- ---------------------------------------------------------

type TitleMap = Map.Map Text [(Text, Integer, [Text])]

extractTitles :: Aeson.Value -> TitleMap
extractTitles value = fromMaybe Map.empty (AesonTypes.parseMaybe parseDefinitions value)
  where
    parseDefinitions = AesonTypes.withObject "blueprint" $ \o -> do
        definitions <-
            o AesonTypes..: "definitions"
                :: AesonTypes.Parser (Map.Map Text Aeson.Value)
        pure
            ( Map.map
                (fromMaybe [] . AesonTypes.parseMaybe parseDefinition)
                definitions
            )
    parseDefinition = AesonTypes.withObject "definition" $ \o -> do
        alternatives <-
            o AesonTypes..:? "anyOf" :: AesonTypes.Parser (Maybe [Aeson.Value])
        maybe (pure []) (mapM parseConstructor) alternatives
    parseConstructor = AesonTypes.withObject "constructor" $ \o -> do
        title <- o AesonTypes..:? "title" AesonTypes..!= ""
        index <- o AesonTypes..:? "index" AesonTypes..!= (-1)
        fields <-
            o AesonTypes..:? "fields" AesonTypes..!= ([] :: [Aeson.Value])
        titles <-
            mapM
                ( AesonTypes.withObject
                    "field"
                    (\f -> f AesonTypes..:? "title" AesonTypes..!= "")
                )
                fields
        pure (title, index, titles)

-- | Each validator's declared parameters by title: absent, or a list of title and schema reference.
type ParameterMap = Map.Map Text (Maybe [(Text, Text)])

extractParameters :: Aeson.Value -> ParameterMap
extractParameters value = fromMaybe Map.empty (AesonTypes.parseMaybe parseValidators value)
  where
    parseValidators = AesonTypes.withObject "blueprint" $ \o -> do
        entries <-
            o AesonTypes..: "validators" :: AesonTypes.Parser [Aeson.Value]
        Map.fromList <$> mapM parseValidator entries
    parseValidator = AesonTypes.withObject "validator" $ \o -> do
        title <- o AesonTypes..: "title"
        parameters <-
            o AesonTypes..:? "parameters"
                :: AesonTypes.Parser (Maybe [Aeson.Value])
        (,) title <$> traverse (mapM parseParameter) parameters
    parseParameter = AesonTypes.withObject "parameter" $ \o -> do
        title <- o AesonTypes..: "title"
        schema <- o AesonTypes..: "schema" :: AesonTypes.Parser Aeson.Value
        pure
            ( title
            , fromMaybe
                ""
                ( AesonTypes.parseMaybe
                    (AesonTypes.withObject "schema" (AesonTypes..: "$ref"))
                    schema
                )
            )

lookupParameters
    :: ParameterMap -> String -> Maybe (Maybe [(Text, Text)])
lookupParameters parameters prefix =
    case [ ps
         | (title, ps) <- Map.toList parameters
         , T.pack prefix `T.isPrefixOf` title
         ] of
        found : _ -> Just found
        [] -> Nothing

-- | The compiled state and request scripts' hashes, naming the blueprint in a receipt.
blueprintIdentity :: Blueprint -> Either String String
blueprintIdentity blueprint =
    case ( extractCompiledCode "state.state" blueprint
         , extractCompiledCode "request.request" blueprint
         ) of
        (Just stateCode, Just requestCode) ->
            Right
                ( "state:"
                    <> hexBytes (scriptHashBytes (computeScriptHash stateCode))
                    <> " request:"
                    <> hexBytes (scriptHashBytes (computeScriptHash requestCode))
                )
        _ -> Left "blueprint has no state.state/request.request code"

hexBytes :: ByteString -> String
hexBytes = hex

-- ---------------------------------------------------------
-- Rows on the devnet
-- ---------------------------------------------------------

{- | Run the serialization rows that need a node, in one devnet session. A
partial row ends the session with the partial report, and an unmet row with
the debt report; neither ever reads as a pass.
-}
runWireSession
    :: [Program]
    -> Control
    -> (SBS.ShortByteString, SBS.ShortByteString, NamingCodes)
    -> String
    -> String
    -> Bool
    -> FilePath
    -> Capabilities
    -> ReplayIndex
    -> IO ()
runWireSession rowPrograms control codes@(stateBytes, requestBytes, _) nodeVersion base dirty receiptsDir caps index = do
    let prov = capReads caps
        blueprintName =
            "state:"
                <> hex (scriptHashBytes (computeScriptHash stateBytes))
                <> " request:"
                <> hex (scriptHashBytes (computeScriptHash requestBytes))
    _ <- Cage.withView prov (pure . Cage.viewProtocolParams)
    checkFunding prov funderAddr defaultFundingFloor
    -- Every registry boots by reference: publish the state validator once,
    -- before any row picks its seed.
    ensureStateRefWith prov caps stateBytes
    trie <- mkPureTrieManager
    let session =
            Session
                { sessionProvider = prov
                , sessionCaps = caps
                , sessionCodes = codes
                , sessionTrie = trie
                , sessionControl = control
                , sessionIndex = index
                , sessionReceipts = receiptsDir
                , sessionBase = base
                , sessionDirty = dirty
                , sessionNode = nodeVersion
                , sessionBlueprint = blueprintName
                }
    mapM_
        ( \program -> do
            writeIORef (riRow index) (T.pack (programRow program))
            runDevnetRow session program
        )
        rowPrograms
    emit
        "complete"
        ( show (length rowPrograms)
            <> "/"
            <> show (length rowPrograms)
            <> " rows ok"
        )
    let rows = map programRow rowPrograms
    reportPartials receiptsDir rows
    reportUnmet receiptsDir rows

data Session = Session
    { sessionProvider :: Cage.Provider IO
    , sessionCaps :: Capabilities
    , sessionCodes
        :: (SBS.ShortByteString, SBS.ShortByteString, NamingCodes)
    , sessionTrie :: TrieManager IO
    , sessionControl :: Control
    , sessionIndex :: ReplayIndex
    , sessionReceipts :: FilePath
    , sessionBase :: String
    , sessionDirty :: Bool
    , sessionNode :: String
    , sessionBlueprint :: String
    }

-- | What one row's instructions have made so far.
data Row = Row
    { rowRegistries :: IORef [(String, BootedRegistry)]
    , rowTransactions :: IORef [(Transaction, (ConwayTx, Measure))]
    , rowWitnessed :: IORef [(Constructor, String)]
    , rowRefusal
        :: IORef (Maybe (RefusalInfo, String, Maybe ReplayCorrespondence))
    }

-- | A booted registry: its configuration, token and published references.
data BootedRegistry = BootedRegistry
    { registryConfig :: CageConfig
    , registryToken :: TokenId
    , registryReferences :: IORef (Maybe [(TxIn, TxOut ConwayEra)])
    }

-- | A submitted transaction's memory and CPU units and size.
data Measure = Measure Integer Integer Integer

runDevnetRow :: Session -> Program -> IO ()
runDevnetRow session program = do
    row <-
        Row
            <$> newIORef []
            <*> newIORef []
            <*> newIORef []
            <*> newIORef Nothing
    mapM_ (devnetStep session row name) (programInstructions program)
    transactions <- readIORef (rowTransactions row)
    cited <-
        mapM
            ( \t ->
                maybe
                    ( failWith
                        ( name
                            <> ": the receipt cites "
                            <> show t
                            <> ", which no instruction submitted"
                        )
                    )
                    pure
                    (lookup t transactions)
            )
            (programCites program)
    refusal <- readIORef (rowRefusal row)
    witnessed <- readIORef (rowWitnessed row)
    let txids = [txIdHex tx | (tx, _) <- cited]
        measures = [m | (_, m) <- cited]
        largest f = if null measures then Nothing else Just (maximum (map f measures))
        mem = largest (\(Measure m _ _) -> m)
        cpu = largest (\(Measure _ c _) -> c)
        size = largest (\(Measure _ _ s) -> s)
        receipt outcome verdict refusalInfo rejected correspondence partial =
            writeReceiptFile (sessionReceipts session) $
                Receipt
                    { receiptRow = T.pack name
                    , receiptOutcome = outcome
                    , receiptVerdict = verdict
                    , receiptTransactions = map T.pack txids
                    , receiptRefusal = refusalInfo
                    , receiptRejected = T.pack <$> rejected
                    , receiptMem = mem
                    , receiptCpu = cpu
                    , receiptTxSize = size
                    , receiptBase = T.pack (sessionBase session)
                    , receiptDirty = sessionDirty session
                    , receiptPartial = partial
                    , receiptDerivation = Nothing
                    , receiptSteps = Nothing
                    , receiptReplayCorrespondence = correspondence
                    , receiptNode = T.pack (sessionNode session)
                    , receiptBlueprint = T.pack (sessionBlueprint session)
                    , receiptVenue = "node-submit"
                    }
    case (programStanding program, refusal) of
        (Holds, Nothing) -> do
            receipt Accepted AgreesWithModel Nothing Nothing Nothing Nothing
            emit "row" (name <> ": every instruction held")
        (PartialCoverage residuals, Nothing) -> do
            mapM_
                (writeGap session name)
                [r | r <- residuals, residualKind r == ExplicitGap]
            receipt Accepted Partial Nothing Nothing Nothing $
                Just . PartialInfo $
                    [ ConstructorEvidence
                        (T.pack (constructorName c))
                        (constructorIndex c)
                        StandingAccepted
                        (T.pack txid)
                    | (c, txid) <- witnessed
                    ]
                        <> [ ConstructorEvidence
                                (T.pack (constructorName (residualConstructor r)))
                                (constructorIndex (residualConstructor r))
                                ( if residualKind r == ExplicitGap
                                    then StandingGap
                                    else StandingResidual
                                )
                                (T.pack (residualReason r))
                           | r <- residuals
                           ]
            emit
                "row"
                ( name
                    <> ": PARTIAL — witnessed "
                    <> intercalate ", " [constructorName c | (c, _) <- witnessed]
                    <> "; unexercised "
                    <> intercalate
                        ", "
                        [constructorName (residualConstructor r) | r <- residuals]
                )
        (KeptUnmetByRuling ruling, Just (info, rejected, correspondence)) -> do
            receipt
                Refused
                UnmetByRuling
                (Just info)
                (Just rejected)
                correspondence
                Nothing
            emit "unmet" (name <> " UNMET BY RULING: " <> ruling)
            emit "row" (name <> ": REFUSED by " <> T.unpack (refusalScript info))
        (standing, _) ->
            failWith
                ( name
                    <> ": its standing "
                    <> show standing
                    <> " does not match what its instructions observed"
                )
  where
    name = programRow program

devnetStep :: Session -> Row -> String -> Instruction -> IO ()
devnetStep session row name instruction = do
    case instruction of
        BootRegistry (Registry registry variation) -> do
            (seed, _) <- largestWalletUtxo prov
            let cfg =
                    varied
                        variation
                        (cageCfg stateBytes requestBytes namingCodes (txInToRef seed))
            unsigned <- Cage.withView prov (\v -> bootTokenImpl cfg v genesisAddr)
            measure <- measured unsigned
            signed <- submitWithGenesis caps unsigned
            token <- extractTokenId cfg signed
            createTrie (sessionTrie session) token
            references <- newIORef Nothing
            modifyIORef'
                (rowRegistries row)
                ((registry, BootedRegistry cfg token references) :)
            submitted (BootOf registry) signed measure
        SubmitRequest registry key edge -> do
            booted <- registryOf registry
            let cfg = registryConfig booted
            unsigned <-
                Cage.withView prov $ \v ->
                    requestEdgeImpl
                        cfg
                        v
                        (defaultTip cfg)
                        (registryToken booted)
                        (keyBytes key)
                        (edgeTag edge)
                        genesisAddr
            measure <- measured unsigned
            signed <- submitWithGenesis caps unsigned
            submitted (RequestFor registry key) signed measure
        BookAndFold registry key edge -> do
            booted <- registryOf registry
            unsigned <- bookAndBuildFold booted key edge
            measure <- measured unsigned
            signed <- submitWithGenesis caps unsigned
            withTrie (sessionTrie session) (registryToken booted) $ \t ->
                void (walkEdge t (keyBytes key) (edgeTag edge))
            submitted (FoldOf registry key) signed measure
        BookAndTamperFold registry key edge index -> do
            booted <- registryOf registry
            fold <- bookAndBuildFold booted key edge
            tampered <- retargetModify prov index fold
            let witnessed = signTx genesisSignKey tampered
            result <- submitSigned (capSubmit caps) witnessed
            case result of
                Node.Rejected reason ->
                    attributeRefusal
                        session
                        row
                        booted
                        label
                        (T.unpack (TE.decodeUtf8Lenient reason))
                        (txIdHex (signedTx witnessed))
                        armed
                Node.Submitted txid ->
                    failWith
                        ( label
                            <> " FINDING: the tampered fold was accepted (txid "
                            <> txInHex txid
                            <> ") — reported, not relabelled"
                        )
        RetractRequest registry key -> do
            booted <- registryOf registry
            let cfg = registryConfig booted
            requestIn <-
                findRequestTxIn prov cfg (registryToken booted) (keyBytes key)
            threadDelay 3_000_000
            unsigned <-
                Cage.withView
                    prov
                    ( \v ->
                        retractRequestImpl cfg v (registryToken booted) requestIn genesisAddr
                    )
            measure <- measured unsigned
            signed <- submitWithGenesis caps unsigned
            submitted (RetractionOf registry key) signed measure
        RejectPending registry -> do
            booted <- registryOf registry
            threadDelay 3_000_000
            unsigned <-
                Cage.withView
                    prov
                    ( \v ->
                        rejectRequestsImpl
                            (registryConfig booted)
                            v
                            (registryToken booted)
                            genesisAddr
                    )
            measure <- measured unsigned
            signed <- submitWithGenesis caps unsigned
            submitted (RejectionIn registry) signed measure
        DatumReadBack datum -> do
            (submittedDatum, observed) <- case datum of
                StateDatumOf registry -> do
                    booted <- registryOf registry
                    tx <- transactionOf (BootOf registry)
                    (,) <$> datumIn isStateDatum tx <*> readStateDatum booted
                RequestDatumOf registry key -> do
                    booted <- registryOf registry
                    tx <- transactionOf (RequestFor registry key)
                    (,)
                        <$> datumIn (isRequestDatum (keyBytes key)) tx
                        <*> readRequestDatum booted (keyBytes key)
            require
                ( label
                    <> ": submitted "
                    <> show submittedDatum
                    <> ( if armed
                            then " was demanded to differ from the chain's "
                            else " differs from the chain's "
                       )
                    <> show observed
                )
                ( if armed
                    then submittedDatum /= observed
                    else submittedDatum == observed
                )
        StateFieldsReadBack registry -> do
            booted <- registryOf registry
            tx <- transactionOf (BootOf registry)
            expected <- stateIn tx
            observed <-
                readChainState (registryConfig booted) prov (registryToken booted)
            mapM_
                ( \(field, same) ->
                    require
                        (label <> ": the " <> field <> " read back differs from the boot's")
                        (same expected observed)
                )
                stateFields
            require
                (label <> ": the state read back differs from the boot's")
                (expected == observed)
        StateFieldCount registry count -> do
            booted <- registryOf registry
            observed <-
                readChainState (registryConfig booted) prov (registryToken booted)
            let found = stateDatumArity observed
            require
                ( label
                    <> ": the chain state encodes "
                    <> show found
                    <> " fields"
                    <> ( if armed
                            then ", and the armed control demanded another count"
                            else ", not " <> show count
                       )
                )
                (if armed then found /= count else found == count)
        VariedFieldDiffers a b -> do
            stateA <- chainState a
            stateB <- chainState b
            let differs = stateActivePolicy stateA /= stateActivePolicy stateB
            require
                ( label
                    <> ": the active policy "
                    <> (if armed then "was demanded equal between " else "is equal between ")
                    <> a
                    <> " and "
                    <> b
                )
                (if armed then not differs else differs)
            require
                ( label
                    <> ": the application policy moved between "
                    <> a
                    <> " and "
                    <> b
                )
                (stateAppPolicy stateA == stateAppPolicy stateB)
        PoliciesDerived registry -> do
            state <- chainState registry
            let pins =
                    [ stateAppPolicy state
                    , stateActivePolicy state
                    , stateAbsentPolicy state
                    , stateTerminalPolicy state
                    ]
                tokens =
                    [ stateActivePolicy state
                    , stateAbsentPolicy state
                    , stateTerminalPolicy state
                    ]
            require
                (label <> ": a pinned policy is a placeholder of 28 zero bytes")
                (BuiltinByteString (BS.replicate 28 0) `notElem` pins)
            require
                (label <> ": the three token policies are not distinct")
                (length (nub tokens) == 3)
        ConstructorWitnessed transaction purpose constructor -> do
            tx <- transactionOf transaction
            let found = constructorsOf purpose tx
                present = constructorIndex constructor `elem` found
            require
                ( label
                    <> ": "
                    <> show transaction
                    <> " carries "
                    <> show found
                    <> (if armed then "; the armed control demanded " else "; missing ")
                    <> constructorName constructor
                )
                (if armed then not present else present)
            modifyIORef' (rowWitnessed row) (<> [(constructor, txIdHex tx)])
        ProofShape transaction steps -> do
            tx <- transactionOf transaction
            require
                ( label
                    <> ": "
                    <> show transaction
                    <> " proves with "
                    <> show (proofStepConstrs tx)
                    <> ", want "
                    <> show steps
                )
                (proofStepConstrs tx == steps)
            require
                (label <> ": a fork's neighbour is malformed")
                (forkNeighborsWellFormed tx)
            case transaction of
                FoldOf registry _ -> do
                    booted <- registryOf registry
                    root <-
                        withTrie (sessionTrie session) (registryToken booted) CageTrie.getRoot
                    observed <-
                        readChainState (registryConfig booted) prov (registryToken booted)
                    require
                        (label <> ": the chain's root differs from the committed trie's")
                        (unOnChainRoot (stateRoot observed) == unRoot root)
                _ -> failWith (label <> ": a proof shape is read off a fold")
        ProofStepsWitnessed constructors -> do
            transactions <- readIORef (rowTransactions row)
            let found = concat [proofStepConstrs tx | (FoldOf{}, (tx, _)) <- transactions]
                complete = all ((`elem` found) . constructorIndex) constructors
            require
                ( label
                    <> ": the folds prove with "
                    <> show (nub found)
                    <> ( if armed
                            then "; the armed control demanded a constructor missing"
                            else "; a proof step constructor is missing"
                       )
                )
                (if armed then not complete else complete)
        RefusedByStateScript registry key -> do
            refusal <- readIORef (rowRefusal row)
            case refusal of
                Just _ -> pure ()
                Nothing ->
                    failWith
                        ( label
                            <> ": no refusal of "
                            <> key
                            <> " in "
                            <> registry
                            <> " was attributed"
                        )
        other ->
            failWith
                ( label
                    <> ": is checked against the blueprint alone: "
                    <> instructionReading other
                )
    emit "held" (name <> ": " <> instructionReading instruction)
  where
    prov = sessionProvider session
    caps = sessionCaps session
    (stateBytes, requestBytes, namingCodes) = sessionCodes session
    control = controlName (sessionControl session)
    armed = case instruction of
        -- The refusal's marker is armed where the refusal is attributed.
        BookAndTamperFold{} -> armedBy control (RefusedByStateScript "" "")
        _ -> armedBy control instruction
    label = if armed then name <> " ARMED (" <> control <> ")" else name
    -- Units are evaluated before submission, while the inputs are unspent;
    -- the size is the signed transaction's, witnesses included.
    measured = measureUnitsProv prov
    submitted transaction signed (mem, cpu) =
        modifyIORef'
            (rowTransactions row)
            (<> [(transaction, (signed, Measure mem cpu (txSizeBytes signed)))])
    registryOf registry = do
        known <- readIORef (rowRegistries row)
        maybe
            (failWith (label <> ": " <> registry <> " is not booted"))
            pure
            (lookup registry known)
    transactionOf transaction = do
        known <- readIORef (rowTransactions row)
        maybe
            (failWith (label <> ": " <> show transaction <> " was not submitted"))
            (pure . fst)
            (lookup transaction known)
    chainState registry = do
        booted <- registryOf registry
        readChainState (registryConfig booted) prov (registryToken booted)
    bookAndBuildFold booted key edge = do
        let cfg = registryConfig booted
            token = registryToken booted
        references <- do
            known <- readIORef (registryReferences booted)
            case known of
                Just refs -> pure refs
                Nothing -> do
                    refs <-
                        RegistryEdges.publishCageRefs
                            cfg
                            namingCodes
                            prov
                            (submitWithGenesis caps)
                            genesisAddr
                            token
                    writeIORef (registryReferences booted) (Just refs)
                    pure refs
        _ <-
            RegistryEdges.bookEdge
                cfg
                namingCodes
                prov
                (submitWithGenesis caps)
                genesisAddr
                token
                (keyBytes key)
                (edgeTag edge)
        Cage.withView prov $ \v -> do
            context <-
                RegistryEdges.registryContextFor cfg namingCodes v references
            updateTokenWithDuties
                cfg
                v
                (sessionTrie session)
                token
                genesisAddr
                context
    readStateDatum booted = do
        let cfg = registryConfig booted
        utxos <-
            Cage.withView
                prov
                (`Cage.viewUTxOsAt` cageAddrFromCfg cfg (network cfg))
        case findStateUtxo (cagePolicyIdFromCfg cfg) (registryToken booted) utxos of
            Just (_, out) ->
                maybe
                    (failWith (label <> ": the state output has no inline datum"))
                    pure
                    (inlineDatum out)
            Nothing -> failWith (label <> ": no state output on chain")
    readRequestDatum booted key = do
        let cfg = registryConfig booted
        utxos <-
            Cage.withView
                prov
                ( `Cage.viewUTxOsAt`
                    requestAddrFromCfg cfg (registryToken booted) (network cfg)
                )
        case [ out
             | (_, out) <- findRequestUtxos (registryToken booted) utxos
             , isRequestDatum key out
             ] of
            [out] ->
                maybe
                    (failWith (label <> ": the request output has no inline datum"))
                    pure
                    (inlineDatum out)
            found ->
                failWith
                    ( label
                        <> ": expected one request output for the key, found "
                        <> show (length found)
                    )
    datumIn select tx =
        case [ d
             | out <- toList (tx ^. bodyTxL . outputsTxBodyL)
             , select out
             , Just d <- [inlineDatum out]
             ] of
            [d] -> pure d
            _ ->
                failWith (label <> ": the transaction carries no single such datum")
    stateIn tx =
        case [ s
             | out <- toList (tx ^. bodyTxL . outputsTxBodyL)
             , Just (StateDatum s) <- [extractCageDatum out]
             ] of
            [s] -> pure s
            _ -> failWith (label <> ": the boot carries no single state datum")

-- | A registry configuration with a program's variation applied.
varied :: Variation -> CageConfig -> CageConfig
varied variation cfg = case variation of
    Standard -> cfg
    ActivePolicyVaried -> cfg{cfgActivePolicy = SBS.pack (replicate 28 7)}
    FastRetraction -> cfg{defaultProcessTime = 1_000, defaultRetractTime = 30_000}
    FastRejection -> cfg{defaultProcessTime = 1_000, defaultRetractTime = 1_000}

-- | The wire tag of an edge.
edgeTag :: Live.Edge -> Integer
edgeTag edge = case edge of
    Live.InsertAbsent -> edgeInsertAbsent
    Live.InsertActive -> edgeInsertActive
    Live.UpdateActive -> edgeUpdateActive
    Live.UpdateTerminal -> edgeUpdateTerminal
    Live.DeleteAbsent -> edgeDeleteAbsent
    Live.DeleteActive -> edgeDeleteActive
    Live.WitnessTerminal -> edgeWitnessTerminal

keyBytes :: String -> ByteString
keyBytes = BS8.pack

-- | The constructor indexes a transaction carries for a purpose.
constructorsOf :: Purpose -> ConwayTx -> [Integer]
constructorsOf purpose = case purpose of
    SpentInputs -> spendingConstrs
    MintedPolicies -> mintConstrs
    ModifyActions -> requestActionConstrs

-- | The eight state fields, each compared on its own.
stateFields
    :: [(String, OnChainTokenState -> OnChainTokenState -> Bool)]
stateFields =
    [ ("root", same stateRoot)
    , ("tip", same stateMaxFee)
    , ("processing time", same stateProcessTime)
    , ("retraction time", same stateRetractTime)
    , ("application policy", same stateAppPolicy)
    , ("active policy", same stateActivePolicy)
    , ("absent policy", same stateAbsentPolicy)
    , ("terminal policy", same stateTerminalPolicy)
    ]
  where
    same
        :: (Eq b)
        => (OnChainTokenState -> b)
        -> OnChainTokenState
        -> OnChainTokenState
        -> Bool
    same field a b = field a == field b

-- | How many fields the state datum actually encodes.
stateDatumArity :: OnChainTokenState -> Int
stateDatumArity state = case toPlcData state of
    PLC.Constr _ fields -> length fields
    _ -> -1

inlineDatum :: TxOut ConwayEra -> Maybe (Datum ConwayEra)
inlineDatum out = case out ^. datumTxOutL of
    d@(Datum _) -> Just d
    _ -> Nothing

isStateDatum :: TxOut ConwayEra -> Bool
isStateDatum out = case extractCageDatum out of
    Just (StateDatum _) -> True
    _ -> False

isRequestDatum :: ByteString -> TxOut ConwayEra -> Bool
isRequestDatum key out = case extractCageDatum out of
    Just (RequestDatum request) -> requestKey request == key
    _ -> False

findRequestTxIn
    :: Cage.Provider IO -> CageConfig -> TokenId -> ByteString -> IO TxIn
findRequestTxIn prov cfg token key = do
    utxos <-
        Cage.withView
            prov
            (`Cage.viewUTxOsAt` requestAddrFromCfg cfg token (network cfg))
    case [i | (i, out) <- findRequestUtxos token utxos, isRequestDatum key out] of
        [found] -> pure found
        found ->
            failWith
                ("expected one request for the key, found " <> show (length found))

{- | Retarget a fold's modify redeemer to another constructor, keeping its
fields: the same encoded size, so fee and collateral stay sufficient and a
refusal attributes to the script in phase two, never to phase one.
-}
retargetModify
    :: Cage.Provider IO -> Integer -> ConwayTx -> IO ConwayTx
retargetModify prov index tx = do
    parameters <- Cage.withView prov (pure . Cage.viewProtocolParams)
    let Redeemers redeemers = tx ^. witsTxL . rdmrsTxWitsL
        retarget (Ledger.Data (PLC.Constr 2 fields), units) = (Ledger.Data (PLC.Constr index fields), units)
        retarget other = other
        tampered = Redeemers (Map.map retarget redeemers)
        body =
            tx ^. bodyTxL
                & scriptIntegrityHashTxBodyL
                    .~ computeScriptIntegrity parameters tampered
    pure
        ( mkBasicTx body
            & witsTxL . scriptTxWitsL .~ (tx ^. witsTxL . scriptTxWitsL)
            & witsTxL . rdmrsTxWitsL .~ tampered
        )

measureUnitsProv
    :: Cage.Provider IO -> ConwayTx -> IO (Integer, Integer)
measureUnitsProv prov tx = do
    evaluated <- Cage.withView prov (`Cage.viewEvaluateTx` tx)
    units <- case traverse (either (Left . show) Right) (Map.elems evaluated) of
        Left problem -> failWith ("measure: node evaluation failed: " <> problem)
        Right us -> pure us
    pure
        ( fromIntegral (sum [m | ExUnits m _ <- units])
        , fromIntegral (sum [s | ExUnits _ s <- units])
        )

{- | Attribute a tampered fold's refusal. The tampered fold breaks the fold's
consistency, which the state, request and active-witness scripts share, so
more than one can refuse in one submission and the ledger's order is not
stable. What must hold is that the state script, whose redeemer was tampered,
is among those refusing; the script set is recorded in the ledger's order,
read from the observed hashes. Armed, the matcher looks for a marker no
refusal carries, and the row fails naming what came back.
-}
attributeRefusal
    :: Session
    -> Row
    -> BootedRegistry
    -> String
    -> String
    -> String
    -> Bool
    -> IO ()
attributeRefusal session row booted label text rejected armed = do
    let cfg = registryConfig booted
        (stateBytes, requestBytes, namingCodes) = sessionCodes session
        stateHash = computeScriptHash stateBytes
        stateMarker = hex (scriptHashBytes stateHash)
        requestMarker =
            hex
                ( scriptHashBytes
                    ( computeScriptHash
                        ( applyRequestParams
                            (scriptHashBytes stateHash)
                            (onChainTokenId (registryToken booted))
                            requestBytes
                        )
                    )
                )
        activeWitnessMarker =
            hex
                ( scriptHashBytes
                    (hashScript (RegistryEdges.witnessScriptOf cfg namingCodes 1))
                )
        marker = if armed then wrongReasonMarker else stateMarker
        role h
            | h == stateMarker = pure "state"
            | h == requestMarker = pure "request"
            | h == activeWitnessMarker = pure "witness-active"
            | otherwise =
                failWith (label <> ": the refusal names an unknown script " <> h)
    case matchRefusal marker text of
        Left mismatch ->
            failWith
                ( label
                    <> ": the refusal does not attribute ("
                    <> show mismatch
                    <> "): "
                    <> text
                )
        Right () -> do
            let index = sessionIndex session
            admitted <-
                admittedFor (T.pack marker) <$> purposesOf index (T.pack rejected)
            replay <- replayEvidenceOf index (T.pack rejected)
            correspondence <- sessionCorrespondence index
            let hashes = refusalScriptHashes text
                trimmed = trimRefusal text
            require
                ( label
                    <> ": the state script did not refuse; scripts named: "
                    <> show hashes
                )
                (stateMarker `elem` hashes)
            unless (stateMarker `isInfixOf` trimmed) $
                failWith
                    ( "the trimmed refusal dropped its attribution; full reason: "
                        <> take 20000 text
                    )
            roles <- mapM role hashes
            writeIORef
                (rowRefusal row)
                ( Just
                    ( RefusalInfo
                        { refusalScript = T.intercalate "+" (map T.pack roles)
                        , refusalReason = T.pack trimmed
                        , refusalPhase = "phase-2"
                        , refusalHashes = map T.pack hashes
                        , refusalBranch = admitted
                        , refusalReplay = toList <$> nonEmpty replay
                        , refusalLimit = case admitted of
                            Just _ -> Nothing
                            Nothing ->
                                Just
                                    "no named validator branch in this compiled trace; attribution is script hash plus phase-2 only"
                        }
                    , rejected
                    , correspondence <* nonEmpty replay
                    )
                )

-- | Record an explicit gap beside the receipts, as its own file.
writeGap :: Session -> String -> Residual -> IO ()
writeGap session row residual = do
    let constructor = residualConstructor residual
        text =
            "row: "
                <> row
                <> "\nconstructor: "
                <> constructorName constructor
                <> " (index "
                <> show (constructorIndex constructor)
                <> ")\nstatus: gap\nreason: "
                <> residualReason residual
                <> "\nbase: "
                <> sessionBase session
                <> "\nblueprint: "
                <> sessionBlueprint session
                <> "\n"
    BSL.writeFile
        ( sessionReceipts session
            </> ("gap-" <> row <> "-" <> constructorName constructor <> ".txt")
        )
        (BSL.fromStrict (TE.encodeUtf8 (T.pack text)))
    emit
        "gap"
        ( row
            <> " "
            <> constructorName constructor
            <> ": "
            <> residualReason residual
        )

{- | Partial rows must never read as green: a session with one ends naming
every such row. A loader rejection, including a success verdict carrying
partial constructors, fails the session as invalid evidence.
-}
reportPartials :: FilePath -> [String] -> IO ()
reportPartials receiptsDir rows = do
    receipts <-
        either (failWith . ("partial accounting: " <>)) pure
            =<< loadReceipts receiptsDir
    case [ T.unpack (receiptRow r)
         | r <- receipts
         , receiptVerdict r == Partial
         , T.unpack (receiptRow r) `elem` rows
         ] of
        [] -> pure ()
        partials ->
            throwIO
                ( ErrorCall
                    ( "ROWS PARTIAL: named constructors stay unexercised; "
                        <> "receipts carry the exact residuals"
                        <> "\n- Partial: "
                        <> unwords partials
                    )
                )

-- | An unmet row ends the session with the same debt report a registry session gives.
reportUnmet :: FilePath -> [String] -> IO ()
reportUnmet receiptsDir rows = do
    receipts <-
        either (failWith . ("unmet accounting: " <>)) pure
            =<< loadReceipts receiptsDir
    case [ T.unpack (receiptRow r)
         | r <- receipts
         , receiptVerdict r == UnmetByRuling
         , T.unpack (receiptRow r) `elem` rows
         ] of
        [] -> pure ()
        unmet -> throwIO (ErrorCall (debtReport [] unmet []))
