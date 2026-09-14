{- |
Module      : Naming.CLI.Read
Description : Read a selected deployment without a wallet
License     : Apache-2.0

Connection lifetime is bounded by the requested action. All observations
are bound to a verified deployment; an unverified mirror never proves absence.
-}
module Naming.CLI.Read (runRead, loadParts, validateAttached, lookupName, recordAt, wireOf, hex, unhex, failWith) where

import Control.Concurrent.Async (race)
import Control.Monad (unless)
import Data.Aeson (Value, object, (.=))
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Short qualified as SBS
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Text.Encoding (encodeUtf8)
import Lens.Micro ((^.))
import System.Environment (getEnv)

import Cardano.Crypto.Hash qualified as Crypto
import Cardano.Ledger.Address (Addr (..))
import Cardano.Ledger.Api.Tx.Out (TxOut, datumTxOutL, valueTxOutL)
import Cardano.Ledger.Credential (Credential (..), StakeReference (..))
import Cardano.Ledger.Hashes (ScriptHash (..))
import Cardano.Ledger.Mary.Value (AssetName (..), MaryValue (..), MultiAsset (..), PolicyID (..))
import Cardano.Ledger.Plutus.Data (Data (..), Datum (..), binaryDataToData)
import Cardano.Node.Client.N2C.Connection (newLSQChannel, newLTxSChannel, runNodeClient)
import Cardano.Node.Client.N2C.Provider (mkN2CProvider)
import Cardano.Node.Client.Provider qualified as N2C
import Ouroboros.Network.Magic (NetworkMagic (..))
import PlutusCore.Data qualified as PLC

import Naming.CLI.Options (Command (..), Connection (..), Options (..))
import Naming.Datum (NamingDatum (..), PaymentDestination (..), RetirementQuorum (..), decodeNamingDatum)
import Naming.Wire (Address (..), WireData (..))
import Singular.Registry.Blueprint (applyBytesParam, extractCompiledCode, loadBlueprint)
import Singular.Registry.Config (CageConfig (..))
import Singular.Registry.Deployment (
    Attached (..),
    CageParts (..),
    Deployment (..),
    attach,
    loadMirror,
    readDeployment,
    renderOutRef,
 )
import Singular.Registry.Ledger (ConwayEra, Root (..), TokenId (..), TxIn)
import Singular.Registry.Provider qualified as Cage
import Singular.Registry.Trie qualified as Trie
import Singular.Registry.Trie.PureManager (mkPureTrieManagerFrom)
import Singular.Registry.TxBuilder.Internal (
    ConsumerBinding (..),
    cagePolicyIdFromCfg,
    computeScriptHash,
    deriveConsumerBinding,
    extractCageDatum,
    findRequestUtxos,
    requestAddrFromCfg,
    scriptHashBytes,
 )
import Singular.Registry.Types (CageDatum (..), OnChainRequest (..), OnChainRoot (..), OnChainTokenState (..), stateConsumerPinBytes, stateRepPolicyBytes)

-- | Execute attach or inspect; no signing-key path is read.
runRead :: Options -> IO Value
runRead Options{connection = conn, command = action} = do
    dep <- readDeployment (deploymentFile conn)
    unless (networkMagic conn == depNetworkMagic dep) $
        failWith "network-mismatch: requested magic differs from the deployment"
    parts <- loadParts dep
    withProvider conn $ \provider -> do
        attached <- attach provider dep parts
        validateAttached dep attached
        result <- case action of
            Attach -> pure $ object ["status" .= ("attached" :: String)]
            Inspect name -> inspectName provider dep attached (deploymentFile conn) name
            ChangeRecord{} -> failWith "internal error: write action sent to read dispatcher"
        refreshed <- attach provider dep parts
        unless (fst (attStateUtxo attached) == fst (attStateUtxo refreshed)) $
            failWith "registry-moved: repeat the observation against the current state"
        pure $
            object
                [ "deployment" .= deploymentFile conn
                , "networkMagic" .= networkMagic conn
                , "statePolicy" .= depStatePolicy dep
                , "registryToken" .= depCageToken dep
                , "stateInput" .= renderOutRef (fst (attStateUtxo attached))
                , "observation" .= result
                ]

withProvider :: Connection -> (Cage.Provider IO -> IO a) -> IO a
withProvider conn action = do
    queries <- newLSQChannel 16
    submissions <- newLTxSChannel 16
    let node = mkN2CProvider queries
        provider =
            Cage.Provider
                { Cage.queryUTxOs = N2C.queryUTxOs node
                , Cage.queryProtocolParams = N2C.queryProtocolParams node
                , Cage.evaluateTx = N2C.evaluateTx node
                , Cage.posixMsToSlot = N2C.posixMsToSlot node
                , Cage.posixMsCeilSlot = N2C.posixMsCeilSlot node
                }
    outcome <-
        race
            (runNodeClient (NetworkMagic (networkMagic conn)) (nodeSocket conn) queries submissions)
            (action provider)
    case outcome of
        Left _ -> failWith "node-disconnected: connection ended before the observation"
        Right result -> pure result

loadParts :: Deployment -> IO CageParts
loadParts dep = do
    registryPath <- getEnv "REGISTRY_BLUEPRINT"
    namingPath <- getEnv "NAMING_BLUEPRINT"
    registry <- either failWith pure =<< loadBlueprint registryPath
    naming <- either failWith pure =<< loadBlueprint namingPath
    let need blueprint title =
            maybe
                (failWith ("blueprint missing " <> T.unpack title))
                pure
                (extractCompiledCode title blueprint)
    state <- need registry "state.state"
    request <- need registry "request.request"
    consumer <- need registry "consumer.consumer"
    application <- need naming "application.application"
    representative <- need naming "representative.representative"
    let applied = applyBytesParam (scriptHashBytes (computeScriptHash application)) representative
        ConsumerBinding{cbPin = pin, cbScriptBytes = script} = deriveConsumerBinding consumer
    unless (T.unpack (depApplicationHash dep) == hex (scriptHashBytes (computeScriptHash application))) $
        failWith "application-mismatch: manifest does not name this naming application"
    unless (T.unpack (depRepresentativePolicy dep) == hex (scriptHashBytes (computeScriptHash applied))) $
        failWith "representative-policy-mismatch: manifest does not name this applied policy"
    unless (T.unpack (depConsumerHash dep) == hex (SBS.fromShort pin)) $
        failWith "consumer-mismatch: manifest does not name this registry consumer"
    pure
        CageParts
            { partsStateBytes = state
            , partsRequestBytes = request
            , partsRepPolicy = SBS.toShort (scriptHashBytes (computeScriptHash applied))
            , partsConsumerPin = pin
            , partsConsumerScript = script
            }

validateAttached :: Deployment -> Attached -> IO ()
validateAttached dep Attached{attCfg = cfg, attToken = token, attStateUtxo = (_, out)} = do
    state <- case extractCageDatum out of
        Just (StateDatum value) -> pure value
        _ -> failWith "registry-datum-invalid"
    let MaryValue _ (MultiAsset assets) = out ^. valueTxOutL
        quantity = Map.lookup (cagePolicyIdFromCfg cfg) assets >>= Map.lookup (unTokenId token)
    unless (quantity == Just 1) $ failWith "registry-token-quantity: expected exactly one"
    unless
        ( hex (stateRepPolicyBytes state) == T.unpack (depRepresentativePolicy dep)
            && hex (stateConsumerPinBytes state) == T.unpack (depConsumerHash dep)
        )
        $ failWith "registry-binding-mismatch: state disagrees with manifest policies"
    unless
        ( stateMaxFee state == depTip dep
            && stateProcessTime state == depProcessTime dep
            && stateRetractTime state == depRetractTime dep
        )
        $ failWith "registry-configuration-mismatch: state disagrees with manifest timing or tip"

inspectName :: Cage.Provider IO -> Deployment -> Attached -> FilePath -> String -> IO Value
inspectName provider dep attached@Attached{attCfg = cfg, attToken = token} manifest name = do
    (expectedRoot, value) <- lookupName attached manifest name
    let key = encodeUtf8 (T.pack name)
    requests <- findRequestUtxos token <$> Cage.queryUTxOs provider (requestAddrFromCfg cfg token (network cfg))
    let pending =
            [ renderOutRef ref
            | (ref, out) <- requests
            , Just (RequestDatum request) <- [extractCageDatum out]
            , requestKey request == key
            ]
    status <- case value of
        Nothing -> pure $ object ["status" .= (if null pending then "absent" else "pending" :: String)]
        Just rep
            | BS.length rep == 35 && "over" `BS.isPrefixOf` rep ->
                pure $ object ["status" .= ("retired" :: String)]
            | BS.length rep == 32 -> inspectRecord provider dep cfg rep
            | otherwise -> failWith "naming-entry-invalid: registry value is neither a representative nor Over"
    pure $
        object
            [ "name" .= name
            , "root" .= hex expectedRoot
            , "pendingRequests" .= pending
            , "entry" .= status
            ]

lookupName :: Attached -> FilePath -> String -> IO (BS.ByteString, Maybe BS.ByteString)
lookupName Attached{attToken = token, attStateUtxo = (_, stateOut)} manifest name = do
    expectedRoot <- case extractCageDatum stateOut of
        Just (StateDatum state) -> let OnChainRoot root = stateRoot state in pure root
        _ -> failWith "registry-datum-invalid"
    mirror <- loadMirror manifest
    (manager, _) <- mkPureTrieManagerFrom mirror
    unless (Map.member token mirror) $ Trie.createTrie manager token
    Root actualRoot <- Trie.withTrie manager token Trie.getRoot
    unless (actualRoot == expectedRoot) $
        failWith "mirror-unavailable: no current verified mirror; rebuild it from the node before inspecting"
    let key = encodeUtf8 (T.pack name)
    value <- Trie.withTrie manager token (\trie -> Trie.lookup trie key)
    pure (expectedRoot, value)

inspectRecord :: Cage.Provider IO -> Deployment -> CageConfig -> BS.ByteString -> IO Value
inspectRecord provider dep cfg representative = do
    record <- recordAt provider dep cfg representative
    pure $ case record of
        Nothing -> object ["status" .= ("pending" :: String), "representative" .= hex representative]
        Just ((ref, _), datum) ->
            object
                [ "status" .= ("active" :: String)
                , "representativePolicy" .= depRepresentativePolicy dep
                , "representative" .= hex representative
                , "recordInput" .= renderOutRef ref
                , "datum" .= datumJSON datum
                ]

recordAt :: Cage.Provider IO -> Deployment -> CageConfig -> BS.ByteString -> IO (Maybe ((TxIn, TxOut ConwayEra), NamingDatum))
recordAt provider dep cfg representative = do
    app <- unhex (depApplicationHash dep)
    policy <- unhex (depRepresentativePolicy dep)
    appHash <- hashFromBytes app
    repHash <- hashFromBytes policy
    outputs <- Cage.queryUTxOs provider (Addr (network cfg) (ScriptHashObj appHash) StakeRefNull)
    let matching =
            [ (ref, out)
            | (ref, out) <- outputs
            , let MaryValue _ (MultiAsset assets) = out ^. valueTxOutL
            , Just tokens <- [Map.lookup (PolicyID repHash) assets]
            , Map.lookup (AssetName (SBS.toShort representative)) tokens == Just 1
            ]
    case matching of
        [] -> pure Nothing
        [(ref, out)] -> do
            datum <- case out ^. datumTxOutL of
                Datum binary ->
                    let Data raw = binaryDataToData binary
                     in maybe (failWith "naming-datum-invalid") pure (wireOf raw >>= decodeNamingDatum)
                _ -> failWith "naming-datum-not-inline"
            pure (Just ((ref, out), datum))
        _ -> failWith "representative-ambiguous: more than one live application output"
  where
    hashFromBytes bytes = maybe (failWith "manifest-script-hash-invalid") (pure . ScriptHash) (Crypto.hashFromBytes bytes)

wireOf :: PLC.Data -> Maybe WireData
wireOf (PLC.Constr i fields)
    | i >= 0 && i <= 6 = Constr (fromInteger i) <$> traverse wireOf fields
wireOf (PLC.B bytes) = Just (WBytes bytes)
wireOf (PLC.I n) = Just (WInt n)
wireOf (PLC.List fields) = WList <$> traverse wireOf fields
wireOf _ = Nothing

datumJSON :: NamingDatum -> Value
datumJSON NamingDatum{controlAddress, paymentDestination, nextControlCommitment, retirementQuorum} =
    object
        [ "controlAddressHex" .= hex (addressBytes controlAddress)
        , "paymentDestinationHex" .= case paymentDestination of
            NoDestination -> Nothing
            SomeDestination address -> Just (hex (addressBytes address))
        , "nextControlCommitment" .= hex nextControlCommitment
        , "retirementQuorum"
            .= object
                [ "members" .= map hex (quorumMembers retirementQuorum)
                , "threshold" .= quorumThreshold retirementQuorum
                ]
        ]

hex :: BS.ByteString -> String
hex = BC.unpack . B16.encode

unhex :: T.Text -> IO BS.ByteString
unhex = either failWith pure . B16.decode . encodeUtf8

failWith :: String -> IO a
failWith = ioError . userError
