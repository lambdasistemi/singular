{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.Registry.TxBuilder.Internal.Identity
Description : builder script identity and ledger/data conversion
License     : Apache-2.0

One owner for what a builder calls a thing: script construction and
hashing from config bytes, the cage and request identities derived
from a 'CageConfig', request datum encoding, and the conversions
between ledger and on-chain reference types.

This is the identity-and-conversion owner extracted from
@Singular.Registry.TxBuilder.Internal@; the public module re-exports
it and is its only intended consumer surface.
-}
module Singular.Registry.TxBuilder.Internal.Identity (
    -- * Script construction
    mkCageScript,
    mkRequestScript,
    scriptFromBytes,
    scriptHashBytes,
    computeScriptHash,

    -- * Derived identity
    cagePolicyIdFromCfg,
    cageAddrFromCfg,
    requestAddrFromCfg,
    onChainTokenId,

    -- * Datum helpers
    mkRequestDatum,
    mkRequestDatumWith,
    toPlcData,
    toLedgerData,
    mkInlineDatum,
    extractCageDatum,

    -- * Reference conversion
    txInToRef,
    addrKeyHashBytes,
    addrFromKeyHashBytes,
    addrWitnessKeyHash,

    -- * Request helpers
    extractOwnerBytes,

    -- * Constants
    emptyRoot,

    -- * Reference identity from pins
    policyIdFromPin,
    addrFromBytes,
) where

import Cardano.Crypto.Hash (hashFromBytes, hashToBytes)
import Cardano.Ledger.Address (Addr (..), decodeAddrEither)
import Cardano.Ledger.Alonzo.Scripts (
    fromPlutusScript,
    mkPlutusScript,
 )
import Cardano.Ledger.Api.Scripts.Data (
    Data (..),
    Datum (..),
    binaryDataToData,
    dataToBinaryData,
 )
import Cardano.Ledger.Api.Tx.Out (
    TxOut,
    datumTxOutL,
 )
import Cardano.Ledger.BaseTypes (
    Network,
    TxIx (..),
 )
import Cardano.Ledger.Core (
    Script,
    extractHash,
    hashScript,
 )
import Cardano.Ledger.Credential (
    Credential (..),
    StakeReference (..),
 )
import Cardano.Ledger.Hashes (ScriptHash (..))
import Cardano.Ledger.Keys (
    KeyHash (..),
    KeyRole (..),
 )
import Cardano.Ledger.Mary.Value (PolicyID (..))
import Cardano.Ledger.Plutus.Language (
    Language (PlutusV3),
    Plutus (..),
    PlutusBinary (..),
 )
import Cardano.Ledger.TxIn (TxId (..), TxIn (..))
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Short qualified as SBS
import Data.Coerce (coerce)
import Lens.Micro ((^.))
import PlutusCore.Data qualified as PLC
import PlutusTx.Builtins.Internal (
    BuiltinByteString (..),
    BuiltinData (..),
 )
import PlutusTx.IsData.Class (
    FromData (..),
    ToData (..),
 )
import Singular.Registry.Blueprint.Params (applyRequestParams)
import Singular.Registry.Config (CageConfig (..))
import Singular.Registry.Ledger (AssetName (..), ConwayEra, TokenId (..))
import Singular.Registry.Types (
    CageDatum (..),
    Edge,
    OnChainRequest (..),
    OnChainTokenId (..),
    OnChainTxOutRef (..),
 )

-- | Empty MPF root (32 zero bytes).
emptyRoot :: ByteString
emptyRoot = BS.replicate 32 0

-- | Build the cage 'Script' from config bytes.
mkCageScript ::
    CageConfig ->
    Script ConwayEra
mkCageScript cfg =
    scriptFromBytes
        "mkCageScript"
        (cageScriptBytes cfg)

-- | Build the per-cage request 'Script' from config bytes.
mkRequestScript ::
    CageConfig ->
    TokenId ->
    Script ConwayEra
mkRequestScript cfg tid =
    scriptFromBytes
        "mkRequestScript"
        (requestScriptBytesFromCfg cfg tid)

scriptFromBytes ::
    String ->
    SBS.ShortByteString ->
    Script ConwayEra
scriptFromBytes label sbs =
    let plutus =
            Plutus @PlutusV3 $
                PlutusBinary sbs
     in case mkPlutusScript plutus of
            Just ps -> fromPlutusScript ps
            Nothing ->
                error
                    ( label
                        <> ": invalid PlutusV3 \
                           \script"
                    )

-- | Compute the 'ScriptHash' from raw script bytes.
computeScriptHash ::
    SBS.ShortByteString ->
    ScriptHash
computeScriptHash sbs =
    let plutus =
            Plutus @PlutusV3 $
                PlutusBinary sbs
     in case mkPlutusScript @ConwayEra plutus of
            Just ps ->
                hashScript @ConwayEra $
                    fromPlutusScript ps
            Nothing ->
                error
                    "computeScriptHash: invalid \
                    \PlutusV3 script"

-- | Compute the cage minting policy ID from config.
cagePolicyIdFromCfg :: CageConfig -> PolicyID
cagePolicyIdFromCfg =
    PolicyID . cfgScriptHash

-- | Compute the cage script address from config.
cageAddrFromCfg ::
    CageConfig ->
    Network ->
    Addr
cageAddrFromCfg cfg net =
    Addr
        net
        (ScriptHashObj $ cfgScriptHash cfg)
        StakeRefNull

-- | Compute the request script address for a token.
requestAddrFromCfg ::
    CageConfig ->
    TokenId ->
    Network ->
    Addr
requestAddrFromCfg cfg tid net =
    Addr
        net
        ( ScriptHashObj $
            computeScriptHash
                (requestScriptBytesFromCfg cfg tid)
        )
        StakeRefNull

-- | Convert a ledger token id to its on-chain token id.
onChainTokenId :: TokenId -> OnChainTokenId
onChainTokenId tid =
    OnChainTokenId $
        BuiltinByteString $
            SBS.fromShort $
                let AssetName sbs = unTokenId tid
                 in sbs

requestScriptBytesFromCfg ::
    CageConfig ->
    TokenId ->
    SBS.ShortByteString
requestScriptBytesFromCfg cfg tid =
    applyRequestParams
        (scriptHashBytes $ cfgScriptHash cfg)
        (onChainTokenId tid)
        (requestScriptBytes cfg)

scriptHashBytes :: ScriptHash -> ByteString
scriptHashBytes (ScriptHash h) =
    hashToBytes h

-- | Build a 'CageDatum' for a request at one C2 edge (#183).
mkRequestDatum ::
    TokenId ->
    Addr ->
    ByteString ->
    -- | The C2 row index the request names
    Edge ->
    -- | The deposit the request rides with, over and above the tip
    Integer ->
    Integer ->
    PLC.Data
mkRequestDatum tid addr key edge deposit submittedAt =
    mkRequestDatumWith
        tid
        addr
        key
        edge
        deposit
        submittedAt
        (BS.empty, BS.empty)

{- | A request datum naming where the edge it books delivers (#157
D-DEST). The cage reads the destination for every edge that mints an
active or terminal token, and the approval that certifies the edge binds
these same bytes, so the booking and the fold cannot disagree about where
the token goes.
-}
mkRequestDatumWith ::
    TokenId ->
    Addr ->
    ByteString ->
    -- | The C2 row index the request names
    Edge ->
    -- | The deposit the request rides with, over and above the tip
    Integer ->
    Integer ->
    (ByteString, ByteString) ->
    PLC.Data
mkRequestDatumWith tid addr key edge deposit submittedAt destination =
    let datum =
            OnChainRequest
                { requestToken = onChainTokenId tid
                , requestOwner =
                    BuiltinByteString
                        (addrKeyHashBytes addr)
                , requestKey = key
                , requestEdge = edge
                , requestDeposit = deposit
                , requestSubmittedAt = submittedAt
                , requestDestination = destination
                }
     in toPlcData (RequestDatum datum)

{- | Convert a 'ToData' value to
'PlutusCore.Data.Data'.
-}
toPlcData :: (ToData a) => a -> PLC.Data
toPlcData x =
    let BuiltinData d = toBuiltinData x in d

-- | Convert a 'ToData' value to a ledger 'Data'.
toLedgerData ::
    (ToData a) => a -> Data ConwayEra
toLedgerData = Data . toPlcData

{- | Wrap 'PlutusCore.Data.Data' as an inline
'Datum'.
-}
mkInlineDatum :: PLC.Data -> Datum ConwayEra
mkInlineDatum d =
    Datum $
        dataToBinaryData
            (Data d :: Data ConwayEra)

{- | Convert a ledger 'TxIn' to an on-chain
'OnChainTxOutRef'.
-}
txInToRef :: TxIn -> OnChainTxOutRef
txInToRef (TxIn (TxId h) (TxIx ix)) =
    OnChainTxOutRef
        { txOutRefId =
            BuiltinByteString
                (hashToBytes (extractHash h))
        , txOutRefIdx = fromIntegral ix
        }

{- | Extract the payment key hash raw bytes from
an 'Addr'.
-}
addrKeyHashBytes :: Addr -> ByteString
addrKeyHashBytes
    (Addr _ (KeyHashObj (KeyHash h)) _) =
        hashToBytes h
addrKeyHashBytes _ = BS.empty

{- | Reconstruct an 'Addr' from raw payment key
hash bytes.
-}
addrFromKeyHashBytes ::
    Network ->
    ByteString ->
    Addr
addrFromKeyHashBytes net bs =
    case hashFromBytes bs of
        Just h ->
            Addr
                net
                (KeyHashObj (KeyHash h))
                StakeRefNull
        Nothing ->
            error
                "addrFromKeyHashBytes: \
                \invalid hash"

{- | Extract a 'KeyHash' ''Witness' from raw
payment key hash bytes.
-}
addrWitnessKeyHash ::
    ByteString -> KeyHash Guard
addrWitnessKeyHash bs =
    case hashFromBytes bs of
        Just h ->
            coerce
                (KeyHash h :: KeyHash Payment)
        Nothing ->
            error
                "addrWitnessKeyHash: \
                \invalid hash"

{- | Extract a 'CageDatum' from an inline datum
in a 'TxOut'.
-}
extractCageDatum ::
    TxOut ConwayEra -> Maybe CageDatum
extractCageDatum txOut =
    case txOut ^. datumTxOutL of
        Datum bd ->
            let Data plcData =
                    binaryDataToData bd
             in fromBuiltinData (BuiltinData plcData)
        _ -> Nothing

{- | Extract the owner key hash bytes from a
request 'TxOut'.
-}
extractOwnerBytes ::
    TxOut ConwayEra -> ByteString
extractOwnerBytes out =
    case extractCageDatum out of
        Just (RequestDatum req) ->
            let OnChainRequest
                    { requestOwner =
                        BuiltinByteString bs
                    } = req
             in bs
        _ ->
            error
                "extractOwnerBytes: \
                \not a request"

{- | The policy id a 28-byte pin names. The four pins the state datum
carries are raw script hashes; this is the one place that turns one back
into the ledger's own type.
-}
policyIdFromPin :: SBS.ShortByteString -> PolicyID
policyIdFromPin pin = case hashFromBytes (SBS.fromShort pin) of
    Just h -> PolicyID (ScriptHash h)
    Nothing ->
        error
            ( "policyIdFromPin: a pin is not a 28-byte script hash: "
                <> show pin
            )

{- | The address a request's binary destination names (#157 D-DEST). The
bytes are a full Cardano address, network byte and all, so nothing here
supplies a network of its own.
-}
addrFromBytes :: ByteString -> Maybe Addr
addrFromBytes bs = case decodeAddrEither bs of
    Right a -> Just a
    Left _ -> Nothing
