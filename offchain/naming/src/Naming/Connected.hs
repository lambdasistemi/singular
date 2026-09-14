{-# LANGUAGE LambdaCase #-}

{- |
Module      : Naming.Connected
Description : Atomic naming registration and certified cancellation
License     : Apache-2.0

The registration receipt is the public commitment witness for both pending
outputs. Cancellation issues a distinct request-bound withdrawal certificate,
burns the Insert approval and consumes the native request in its retract window.
Old application scripts and old approvals do not support this interface.
-}
module Naming.Connected
    ( Registration (..)
    , registrationData
    , serialiseRegistration
    , deserialiseRegistration
    , insertName
    , withdrawalName
    , registerRedeemer
    , foldApprovalRedeemer
    , cancelApprovalRedeemer
    , connectedApplication
    , registerConnected
    , cancelConnected
    ) where

import Control.Monad (guard, unless)
import Codec.CBOR.Read (deserialiseFromBytes)
import Codec.Serialise (decode)
import Crypto.Hash (Blake2b_256, Digest, hash)
import Data.ByteArray (convert)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BL
import Data.ByteString.Short qualified as SBS
import Data.List (sortOn)
import Data.Map.Strict qualified as Map
import Data.Ord (Down (..))
import Data.Sequence.Strict qualified as StrictSeq
import Data.Set qualified as Set
import Lens.Micro ((&), (.~), (^.))
import PlutusCore.Data qualified as PLC
import PlutusTx.Builtins.Internal (BuiltinByteString (..), BuiltinData (..), serialiseData)
import PlutusTx.IsData.Class (fromBuiltinData)

import Cardano.Ledger.Address (Addr (..), decodeAddr, serialiseAddr)
import Cardano.Ledger.Alonzo.Scripts (AsIx (..))
import Cardano.Ledger.Api.Scripts.Data (Data (..), Datum (..), binaryDataToData)
import Cardano.Ledger.Api.Tx (bodyTxL, mkBasicTx, witsTxL)
import Cardano.Ledger.Api.Tx.Body
    ( collateralInputsTxBodyL, feeTxBodyL, inputsTxBodyL, mintTxBodyL
    , mkBasicTxBody, outputsTxBodyL, referenceInputsTxBodyL
    , reqSignerHashesTxBodyL, scriptIntegrityHashTxBodyL, vldtTxBodyL
    )
import Cardano.Ledger.Api.Tx.Out
    ( TxOut, coinTxOutL, datumTxOutL, getMinCoinTxOut, mkBasicTxOut )
import Cardano.Ledger.Api.Tx.Wits (Redeemers (..), rdmrsTxWitsL, scriptTxWitsL)
import Cardano.Ledger.BaseTypes (TxIx (..))
import Cardano.Ledger.Conway.Scripts (ConwayPlutusPurpose (..))
import Cardano.Ledger.Core (Script, hashScript)
import Cardano.Ledger.Credential (Credential (..), StakeReference (..))
import Cardano.Ledger.Mary.Value (AssetName (..), MaryValue (..), MultiAsset (..), PolicyID (..))
import Cardano.Ledger.TxIn (TxIn (..))
import Cardano.Node.Client.Ledger (ConwayTx)
import Naming.Datum (NamingDatum (..), decodeNamingDatum, encodeNamingDatum)
import Naming.Register qualified as Register
import Naming.Wire (WireData (..))
import Singular.Registry.Config (CageConfig (..))
import Singular.Registry.Blueprint (applyBytesParam)
import Singular.Registry.Ledger (Coin (..), ConwayEra, TokenId (..))
import Singular.Registry.Node (currentTipSlot)
import Singular.Registry.Provider (Provider (..))
import Singular.Registry.TxBuilder.Internal
    ( addrWitnessKeyHash, cageAddrFromCfg, cagePolicyIdFromCfg, computeScriptIntegrity
    , currentPosixMs, extractCageDatum, findStateUtxo, mkInlineDatum, mkRequestDatum
    , mkRequestScript, placeholderExUnits, requestAddrFromCfg, scriptHashBytes
    , spendingIndex, toPlcData, txInToRef, evaluateAndBalance, scriptFromBytes
    )
import Singular.Registry.TxBuilder.Request (requestLockedAda)
import Singular.Registry.TxBuilder.Retract (retractRequestAtTipImpl)
import Singular.Registry.Types (CageDatum (..), OnChainOperation (..), OnChainRequest (..), OnChainTxOutRef)

-- | Immutable public witness, preserved with the submitted registration ID.
data Registration = Registration
    { registrationSeed :: OnChainTxOutRef
    , registrationPolicy :: ByteString
    , registrationToken :: ByteString
    , registrationRequestIndex :: Integer
    , registrationRequestAddress :: Addr
    , registrationRequestDatum :: OnChainRequest
    , registrationRefund :: Addr
    , registrationNamingDatum :: NamingDatum
    }

-- | Instantiate against the actual native request script for this cage.
connectedApplication :: CageConfig -> TokenId -> SBS.ShortByteString -> Script ConwayEra
connectedApplication cfg token blueprint = scriptFromBytes "connected naming" $
    applyBytesParam (scriptHashBytes (hashScript (mkRequestScript cfg token))) blueprint

-- | Exact canonical Plutus Data encoding shared with connected.Registration.
registrationData :: Registration -> PLC.Data
registrationData Registration{..} = PLC.Constr 0
    [ toPlcData registrationSeed, PLC.B registrationPolicy, PLC.B registrationToken
    , PLC.I registrationRequestIndex, PLC.B (serialiseAddr registrationRequestAddress)
    , toPlcData (RequestDatum registrationRequestDatum), PLC.B (serialiseAddr registrationRefund)
    , namingData registrationNamingDatum
    ]

-- | Versioned canonical CBOR, exactly the public Insert commitment preimage.
serialiseRegistration :: Registration -> ByteString
serialiseRegistration registration = dataBytes (PLC.Constr 0
    [PLC.B "singular/naming/connected-insert/v1", registrationData registration])

-- | Decode a portable receipt, refusing trailing bytes, unsupported versions,
-- malformed fields and noncanonical encodings. Its hash is checked again by
-- the validator against the token in the live claim.
deserialiseRegistration :: ByteString -> Maybe Registration
deserialiseRegistration bytes = do
    (rest, datum) <- either (const Nothing) Just (deserialiseFromBytes decode (BL.fromStrict bytes))
    guard (BL.null rest)
    PLC.Constr 0 [PLC.B "singular/naming/connected-insert/v1", PLC.Constr 0
        [seedData, PLC.B policy, PLC.B token, PLC.I index, PLC.B requestAddress,
         requestData, PLC.B refundAddress, namingDatum]] <- pure datum
    seed <- fromBuiltinData (BuiltinData seedData)
    RequestDatum request <- fromBuiltinData (BuiltinData requestData)
    reqAddress <- decodeAddr requestAddress
    refund <- decodeAddr refundAddress
    naming <- fromData namingDatum >>= decodeNamingDatum
    guard (index >= 0 && index <= 65535 && BS.length policy == 28 && BS.length token <= 32)
    let receipt = Registration seed policy token index reqAddress request refund naming
    guard (serialiseRegistration receipt == bytes)
    pure receipt
  where
    fromData (PLC.Constr i fields) | i >= 0 && i < 7 = Constr (fromInteger i) <$> traverse fromData fields
    fromData (PLC.B value) = Just (WBytes value)
    fromData (PLC.I value) = Just (WInt value)
    fromData (PLC.List values) = WList <$> traverse fromData values
    fromData _ = Nothing

-- | Unique Insert approval for this seed, registry and pair of outputs.
insertName :: Registration -> ByteString
insertName registration = hashData (PLC.Constr 0
    [PLC.B "singular/naming/connected-insert/v1", registrationData registration])

-- | Distinct withdrawal certificate binding the exact consumed request.
withdrawalName :: Registration -> TxIn -> ByteString
withdrawalName Registration{..} request = hashData (PLC.Constr 0
    [ PLC.B "singular/naming/connected-withdraw/v1", PLC.B registrationPolicy
    , PLC.B registrationToken, toPlcData (txInToRef request), PLC.B (serialiseAddr registrationRefund)
    ])

-- | Registration mint witness, using the existing controller authorization.
registerRedeemer :: Registration -> ByteString -> PLC.Data
registerRedeemer registration controller = PLC.Constr 0 [registrationData registration, PLC.B controller]

-- | Permissionless fold burns the registration approval.
foldApprovalRedeemer :: Registration -> PLC.Data
foldApprovalRedeemer registration = PLC.Constr 1 [registrationData registration]

-- | Distinct withdrawal issuance, requiring the explicitly named issuer signer.
cancelApprovalRedeemer :: Registration -> ByteString -> PLC.Data
cancelApprovalRedeemer registration issuer = PLC.Constr 2 [registrationData registration, PLC.B issuer]

hashData :: PLC.Data -> ByteString
hashData datum = convert (hash (dataBytes datum) :: Digest Blake2b_256)

dataBytes :: PLC.Data -> ByteString
dataBytes datum = let BuiltinByteString bytes = serialiseData (BuiltinData datum) in bytes

namingData :: NamingDatum -> PLC.Data
namingData = wireData . encodeNamingDatum
  where
    wireData (Constr index fields) = PLC.Constr (toInteger index) (map wireData fields)
    wireData (WBytes bytes) = PLC.B bytes
    wireData (WInt number) = PLC.I number
    wireData (WList fields) = PLC.List (map wireData fields)

-- | Build one transaction creating the native request (output 0) and claim.
-- The caller signs the controller requirement and its selected funding input.
registerConnected :: CageConfig -> Script ConwayEra -> Provider IO -> TokenId
    -> Addr -> ByteString -> NamingDatum -> ByteString -> Addr -> IO (ConwayTx, Registration)
registerConnected cfg app prov token owner controller datum spelling refund = do
    pp <- queryProtocolParams prov
    funds <- queryUTxOs prov owner
    fund <- funding funds
    state <- registryState cfg prov token
    now <- currentPosixMs
    let TokenId (AssetName tokenBytes) = token
        registryToken = SBS.fromShort tokenBytes
        policyBytes = scriptHashBytes (cfgScriptHash cfg)
        representative = Register.representativeName spelling
        reqAddr = requestAddrFromCfg cfg token (network cfg)
        request = case fromBuiltinData (BuiltinData (mkRequestDatum token owner spelling (OpInsert representative) 1000000 now)) of
            Just (RequestDatum value) -> value
            _ -> error "registerConnected: request constructor invariant"
        receipt = Registration (txInToRef (fst fund)) policyBytes registryToken 0 reqAddr request refund datum
        policy = PolicyID (hashScript app)
        mint = asset policy (insertName receipt) 1
        claimAddr = Addr (network cfg) (ScriptHashObj (hashScript app)) StakeRefNull
        -- Size the actual coin encoding (a zero-valued draft underestimates
        -- the final output's minUTxO, as the node regression demonstrates).
        claimDraft = mkBasicTxOut claimAddr (MaryValue (Coin 2000000) mint)
            & datumTxOutL .~ mkInlineDatum (namingData datum)
        claim = claimDraft & coinTxOutL .~ getMinCoinTxOut pp claimDraft
        requestDraft = mkBasicTxOut reqAddr (MaryValue (Coin 0) mempty)
            & datumTxOutL .~ mkInlineDatum (toPlcData (RequestDatum request))
        refundDraft = mkBasicTxOut refund (MaryValue (Coin 0) mempty)
        requestOut = requestDraft & coinTxOutL .~ requestLockedAda pp requestDraft refundDraft 1000000
        redeemers = Redeemers (Map.singleton (ConwayMinting (AsIx 0))
            (Data (registerRedeemer receipt controller), placeholderExUnits))
        body = mkBasicTxBody
            & inputsTxBodyL .~ Set.singleton (fst fund)
            & referenceInputsTxBodyL .~ Set.singleton (fst state)
            & collateralInputsTxBodyL .~ Set.singleton (fst fund)
            & outputsTxBodyL .~ StrictSeq.fromList [requestOut, claim]
            & mintTxBodyL .~ mint
            & reqSignerHashesTxBodyL .~ Set.singleton (addrWitnessKeyHash controller)
            & scriptIntegrityHashTxBodyL .~ computeScriptIntegrity pp redeemers
        tx = mkBasicTx body
            & witsTxL . scriptTxWitsL .~ Map.singleton (hashScript app) app
            & witsTxL . rdmrsTxWitsL .~ redeemers
    built <- evaluateAndBalance prov pp [fund] owner tx
    pure (built, receipt)

-- | Cancel the live pair during the native request's existing retract window.
-- The refund output retains one request-specific withdrawal certificate. It is
-- not a representative and cannot replay consumption of the now-spent request.
-- Request-owner and certificate-issuer signing requirements remain distinct.
cancelConnected :: CageConfig -> Script ConwayEra -> Provider IO -> TokenId
    -> Registration -> TxIn -> ByteString -> Addr -> IO ConwayTx
cancelConnected cfg app prov token receipt claimIn issuer feeAddress = do
    let appAddress = Addr (network cfg) (ScriptHashObj (hashScript app)) StakeRefNull
        TxIn creation _ = claimIn
        requestIn = TxIn creation (TxIx (fromInteger (registrationRequestIndex receipt)))
        requestAddress = requestAddrFromCfg cfg token (network cfg)
    request <- liveInput prov requestAddress requestIn
    unless (extractCageDatum (snd request) == Just (RequestDatum (registrationRequestDatum receipt))) $
        fail "cancelConnected: request datum differs from registration"
    case requestValue (registrationRequestDatum receipt) of
        OpInsert _ -> pure ()
        _ -> fail "cancelConnected: cancellation-insert-only"
    claim <- liveInput prov appAddress claimIn
    unless (datumOf (snd claim) == Just (namingData (registrationNamingDatum receipt))) $
        fail "cancelConnected: claim datum differs from registration"
    state <- registryState cfg prov token
    pp <- queryProtocolParams prov
    tip <- currentTipSlot
    native <- retractRequestAtTipImpl tip cfg prov token requestIn feeAddress
    funds <- queryUTxOs prov feeAddress
    fund <- funding funds
    let policy = PolicyID (hashScript app)
        minted = asset policy (insertName receipt) (-1) <> asset policy (withdrawalName receipt requestIn) 1
        certificateValue = asset policy (withdrawalName receipt requestIn) 1
        Coin claimCoin = snd claim ^. coinTxOutL
        Coin requestCoin = snd request ^. coinTxOutL
        refund = mkBasicTxOut (registrationRefund receipt)
            (MaryValue (Coin (claimCoin + requestCoin)) certificateValue)
        allInputs = Set.fromList [claimIn, requestIn, fst fund]
        requestScript = mkRequestScript cfg token
        requestRedeemer = PLC.Constr 3 [toPlcData (txInToRef (fst state))]
        cancelRedeemer = PLC.Constr 1 [PLC.B (serialiseAddr (registrationRefund receipt))]
        redeemers = Redeemers (Map.fromList
            [ (ConwaySpending (AsIx (spendingIndex claimIn allInputs)), (Data cancelRedeemer, placeholderExUnits))
            , (ConwaySpending (AsIx (spendingIndex requestIn allInputs)), (Data requestRedeemer, placeholderExUnits))
            , (ConwayMinting (AsIx 0), (Data (cancelApprovalRedeemer receipt issuer), placeholderExUnits))
            ])
        body = mkBasicTxBody
            & inputsTxBodyL .~ allInputs
            & referenceInputsTxBodyL .~ Set.singleton (fst state)
            & collateralInputsTxBodyL .~ Set.singleton (fst fund)
            & outputsTxBodyL .~ StrictSeq.singleton refund
            & feeTxBodyL .~ (native ^. bodyTxL . feeTxBodyL)
            & mintTxBodyL .~ minted
            & vldtTxBodyL .~ (native ^. bodyTxL . vldtTxBodyL)
            & reqSignerHashesTxBodyL .~ Set.insert (addrWitnessKeyHash issuer) (native ^. bodyTxL . reqSignerHashesTxBodyL)
            & scriptIntegrityHashTxBodyL .~ computeScriptIntegrity pp redeemers
        tx = mkBasicTx body
            & witsTxL . scriptTxWitsL .~ Map.fromList [(hashScript app, app), (hashScript requestScript, requestScript)]
            & witsTxL . rdmrsTxWitsL .~ redeemers
    evaluateAndBalance prov pp [fund, claim, request] feeAddress tx

asset :: PolicyID -> ByteString -> Integer -> MultiAsset
asset policy name amount = MultiAsset (Map.singleton policy (Map.singleton (AssetName (SBS.toShort name)) amount))

funding :: [(TxIn, TxOut ConwayEra)] -> IO (TxIn, TxOut ConwayEra)
funding funds = case sortOn (Down . (^. coinTxOutL) . snd) funds of
    fund : _ -> pure fund
    _ -> fail "connected naming: funding UTxO required"

registryState :: CageConfig -> Provider IO -> TokenId -> IO (TxIn, TxOut ConwayEra)
registryState cfg prov token = do
    utxos <- queryUTxOs prov (cageAddrFromCfg cfg (network cfg))
    maybe (fail "connected naming: registry state unavailable") pure
        (findStateUtxo (cagePolicyIdFromCfg cfg) token utxos)

liveInput :: Provider IO -> Addr -> TxIn -> IO (TxIn, TxOut ConwayEra)
liveInput prov address input = do
    utxos <- queryUTxOs prov address
    case filter ((== input) . fst) utxos of
        [found] -> pure found
        _ -> fail "connected naming: request or claim unavailable"

datumOf :: TxOut ConwayEra -> Maybe PLC.Data
datumOf out = case out ^. datumTxOutL of
    Datum bytes -> let Data datum = binaryDataToData bytes in Just datum
    _ -> Nothing
