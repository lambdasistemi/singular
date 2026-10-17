{- |
Module      : Singular.Registry.TxBuilder.RegistrationBooking
Description : The registration booking transaction
License     : Apache-2.0

Builds the transaction that books a registration: it pays the request
address the declared cost, tip and carrier with an inline registration
datum, and mints in the same transaction the registry's application tag
under its application policy and the trie-ready tag under its request
policy, both held by the request output. The request policy's mint handler
judges the booking; this builder only builds what that handler accepts, and
refuses before building what it would refuse.

The booked time is the start of the explicit upper validity slot, never a
wall-clock sample, and the nonce is the caller's.

The application witness is supplied by the caller. Its convention here is
the open policy's registration arm only: the builder is not an interface for
other application policies or redeemers.
-}
module Singular.Registry.TxBuilder.RegistrationBooking
    ( RegistrationBooking (..)
    , bookRegistrationImpl
    ) where

import Control.Monad (unless)
import Data.ByteString (ByteString)
import Data.ByteString.Short (ShortByteString)
import Data.ByteString.Short qualified as SBS
import Data.List (sort)
import Data.Map.Strict qualified as Map
import Data.Sequence.Strict qualified as StrictSeq
import Data.Set qualified as Set
import Lens.Micro ((&), (.~), (^.))
import PlutusCore.Data qualified as PLC
import PlutusTx.Builtins.Internal (BuiltinByteString (..))

import Cardano.Ledger.Address (Addr (..))
import Cardano.Ledger.Allegra.Scripts (ValidityInterval (..))
import Cardano.Ledger.Alonzo.Scripts (AsIx (..))
import Cardano.Ledger.Api.Scripts.Data (Data (..))
import Cardano.Ledger.Api.Tx (mkBasicTx, witsTxL)
import Cardano.Ledger.Api.Tx.Body
    ( collateralInputsTxBodyL
    , inputsTxBodyL
    , mintTxBodyL
    , mkBasicTxBody
    , outputsTxBodyL
    , referenceInputsTxBodyL
    , scriptIntegrityHashTxBodyL
    , vldtTxBodyL
    )
import Cardano.Ledger.Api.Tx.Out
    ( TxOut
    , datumTxOutL
    , getMinCoinTxOut
    , mkBasicTxOut
    , valueTxOutL
    )
import Cardano.Ledger.Api.Tx.Wits
    ( Redeemers (..)
    , rdmrsTxWitsL
    , scriptTxWitsL
    )
import Cardano.Ledger.BaseTypes (SlotNo, StrictMaybe (SJust))
import Cardano.Ledger.Conway.Scripts (ConwayPlutusPurpose (..))
import Cardano.Ledger.Core (hashScript)
import Cardano.Ledger.Credential (Credential (..))
import Cardano.Ledger.Mary.Value
    ( AssetName (..)
    , MaryValue (..)
    , MultiAsset (..)
    , PolicyID (..)
    )
import Cardano.Ledger.TxIn (TxIn)
import Cardano.Tx.Ledger (ConwayTx)

import Singular.Registry.Config (CageConfig (..))
import Singular.Registry.Evidence (NoWitness)
import Singular.Registry.Ledger (Coin (..), ConwayEra, TokenId (..))
import Singular.Registry.LedgerProvider (Session)
import Singular.Registry.SessionIO (outputsAt, parameters)
import Singular.Registry.SessionIO qualified as Services
import Singular.Registry.TxBuilder.Edges (selectFunding)
import Singular.Registry.TxBuilder.Internal
import Singular.Registry.Types
    ( CageDatum (..)
    , OnChainRegistrationRequest (..)
    , OnChainTokenState (..)
    , applicationTagName
    , stateAppPolicyBytes
    , stateRequestPolicyBytes
    , trieReadyTagName
    )

{- | What a requester chooses for one registration. Everything else comes
from the registry's configuration: the cost, the minimum tip, the widest
interval and the request policy.
-}
data RegistrationBooking = RegistrationBooking
    { rbKey :: !ByteString
    -- ^ The registry key being registered
    , rbRefundAddress :: !Addr
    -- ^ The key address that may retract and is refunded
    , rbDestination :: !ByteString
    -- ^ Binary address bytes of the output that will receive the token
    , rbDatum :: !(Maybe PLC.Data)
    -- ^ The datum the delivered output must carry, or none
    , rbDeclaredTip :: !Coin
    -- ^ The declared tip, at least the registry's minimum tip
    , rbCarrier :: !Coin
    -- ^ The declared carrier lovelace
    , rbNonce :: !Integer
    -- ^ The one nonce both tags commit to
    , rbLower :: !SlotNo
    -- ^ The first slot of the validity interval
    , rbUpper :: !SlotNo
    -- ^ The slot whose start is the booked time: the interval's upper end
    , rbApplicationScript :: !ShortByteString
    {- ^ The application policy's script, whose hash must be the registry's
    pinned application policy
    -}
    }

refuse :: String -> IO a
refuse = ioError . userError . ("bookRegistration: " <>)

{- | Build the unsigned booking of one registration, balanced from the
payer's largest ada-only output, which is also its collateral.

Everything the mint handler would refuse for the booking's own declarations
is refused here first, with the reason: a lower slot not before the upper
one, an interval wider than the registry's widest, a tip below its minimum,
a negative carrier or nonce, a refund address that is not a key address, an
application script that is not the pinned application policy, a state output
that is missing or does not carry the configuration's pins, and a request
output below the minimum ada.
-}
bookRegistrationImpl
    :: CageConfig
    -> Session NoWitness IO
    -> TokenId
    -- ^ The registry token
    -> TxIn
    -- ^ The registry state output, referenced
    -> RegistrationBooking
    -> Addr
    -- ^ Fee payer and change address
    -> IO ConwayTx
bookRegistrationImpl cfg view tid stateRef b payer = do
    let Coin cost = defaultRegistrationCost cfg
        Coin minimumTip = defaultTip cfg
        Coin tip = rbDeclaredTip b
        Coin carrier = rbCarrier b
    unless (rbLower b < rbUpper b) $
        refuse "the lower slot is not before the upper slot"
    unless (carrier >= 0) $ refuse "the carrier is negative"
    unless (rbNonce b >= 0) $ refuse "the nonce is negative"
    unless (tip >= minimumTip) $
        refuse "the tip is below the registry's minimum tip"
    refund <- case rbRefundAddress b of
        Addr _ (KeyHashObj _) _ -> pure (addrKeyHashBytes (rbRefundAddress b))
        _ -> refuse "the refund address is not a key address"
    let applicationScript = scriptFromBytes "application" (rbApplicationScript b)
        applicationPolicy = policyIdFromPin (cfgApplicationPolicy cfg)
    unless (PolicyID (hashScript applicationScript) == applicationPolicy) $
        refuse
            "the application script is not the registry's application policy"
    lowerMs <- Services.slotStart view (rbLower b)
    upperMs <- Services.slotStart view (rbUpper b)
    unless (upperMs - lowerMs <= defaultBookingWidth cfg) $
        refuse "the interval is wider than the registry's booking width"
    let requestScript = mkRequestScript cfg tid
        requestScriptAgrees =
            PolicyID (hashScript requestScript)
                == policyIdFromPin (cfgRequestPolicy cfg)
    unless requestScriptAgrees $
        refuse "the request script is not the registry's request policy"
    -- The state output the booking reads: it must be the registry's, with
    -- the pins this configuration derived.
    stateUtxos <- outputsAt view (cageAddrFromCfg cfg (network cfg))
    stateOut <- case findUtxoByTxIn stateRef stateUtxos of
        Just (_, out) -> pure out
        Nothing ->
            refuse "the state output not found at the registry's state address"
    unless (holdsStateToken cfg tid stateOut) $
        refuse "the state output does not hold the registry's state token"
    case extractCageDatum stateOut of
        Just (StateDatum st)
            | stateRegistrationCost st == cost
                && stateBookingWidth st == defaultBookingWidth cfg
                && stateMaxFee st == minimumTip
                && stateRequestPolicyBytes st == SBS.fromShort (cfgRequestPolicy cfg)
                && stateAppPolicyBytes st == SBS.fromShort (cfgApplicationPolicy cfg) ->
                pure ()
        _ ->
            refuse
                "the state output does not carry this configuration's booking pins"
    let request =
            OnChainRegistrationRequest
                { regRegistry = onChainTokenId tid
                , regKey = rbKey b
                , regRefundAddress = BuiltinByteString refund
                , regDestination = rbDestination b
                , regDatum = rbDatum b
                , regSubmittedAt = upperMs
                , regRegistrationCost = cost
                , regDeclaredTip = tip
                , regCarrierAda = carrier
                , regNonce = rbNonce b
                }
        requestPolicy = PolicyID (hashScript requestScript)
        applicationName =
            applicationTagName
                (rbKey b)
                (BuiltinByteString refund)
                (rbDestination b)
                (rbNonce b)
        trieName = trieReadyTagName request
        tags =
            MultiAsset
                ( Map.fromList
                    [ (requestPolicy, Map.singleton (AssetName (SBS.toShort trieName)) 1)
                    ,
                        ( applicationPolicy
                        , Map.singleton (AssetName (SBS.toShort applicationName)) 1
                        )
                    ]
                )
        requestOut =
            mkBasicTxOut
                (requestAddrFromCfg cfg tid (network cfg))
                (MaryValue (Coin (cost + tip + carrier)) tags)
                & datumTxOutL .~ mkInlineDatum (toPlcData (RegistrationDatum request))
    pp <- parameters view
    let Coin minimumAda = getMinCoinTxOut pp requestOut
    unless (cost + tip + carrier >= minimumAda) $
        refuse "the booking is below the minimum ada its request output needs"
    walletUtxos <- outputsAt view payer
    funding <- case selectFunding Nothing walletUtxos of
        Left why -> refuse why
        Right u -> pure u
    let sortedPolicies = sort [requestPolicy, applicationPolicy]
        indexOf p = fromIntegral (length (takeWhile (/= p) sortedPolicies))
        redeemers =
            Redeemers $
                Map.fromList
                    [
                        ( ConwayMinting (AsIx (indexOf requestPolicy))
                        , (Data (PLC.Constr 0 []), placeholderExUnits)
                        )
                    ,
                        ( ConwayMinting (AsIx (indexOf applicationPolicy))
                        , (Data (applicationRedeemer b refund), placeholderExUnits)
                        )
                    ]
        body =
            mkBasicTxBody
                & inputsTxBodyL .~ Set.singleton (fst funding)
                & outputsTxBodyL .~ StrictSeq.singleton requestOut
                & mintTxBodyL .~ tags
                & referenceInputsTxBodyL .~ Set.singleton stateRef
                & collateralInputsTxBodyL .~ Set.singleton (fst funding)
                & vldtTxBodyL
                    .~ ValidityInterval (SJust (rbLower b)) (SJust (rbUpper b))
                & scriptIntegrityHashTxBodyL .~ computeScriptIntegrity pp redeemers
        tx =
            mkBasicTx body
                & witsTxL . scriptTxWitsL
                    .~ Map.fromList
                        [ (hashScript requestScript, requestScript)
                        , (hashScript applicationScript, applicationScript)
                        ]
                & witsTxL . rdmrsTxWitsL .~ redeemers
    evaluateAndBalance view pp [funding] payer tx

{- | The open policy's registration arm: constructor 1 over the booking's key,
refund hash, destination and nonce.
-}
applicationRedeemer :: RegistrationBooking -> ByteString -> PLC.Data
applicationRedeemer b refund =
    PLC.Constr
        1
        [ PLC.B (rbKey b)
        , PLC.B refund
        , PLC.B (rbDestination b)
        , PLC.I (rbNonce b)
        ]

{- | Whether the output holds exactly one of the registry's state token: the
state policy's asset named by the registry token. Anyone may pay an output
with any datum to the state address, so the address and the datum alone do
not make an output the registry's state.
-}
holdsStateToken :: CageConfig -> TokenId -> TxOut ConwayEra -> Bool
holdsStateToken cfg tid out =
    case out ^. valueTxOutL of
        MaryValue _ (MultiAsset assets) ->
            ( Map.lookup (PolicyID (cfgScriptHash cfg)) assets
                >>= Map.lookup (unTokenId tid)
            )
                == Just 1
