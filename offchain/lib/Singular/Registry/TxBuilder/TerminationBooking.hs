{- |
Module      : Singular.Registry.TxBuilder.TerminationBooking
Description : The termination booking transaction
License     : Apache-2.0

Builds the transaction that books a termination: it spends the key's genuine
custody output, pays the request address the whole custody value plus the
requester's declared ordinary addition with an inline termination datum, and
mints in the same transaction the trie-ready tag under the registry's request
policy. The key's singular tag travels into the request output. The request
policy's mint handler judges the booking; this builder only builds what that
handler accepts, and refuses before building what it would refuse.

There is no booked time and no expiry: a termination has no window. The
custody's own spending condition is the caller's: the builder carries the
spend witness and redeemer it is given and adds nothing of its own, so the
universal layer puts no restriction on the custody address. The held value and
the declared amounts are accounted for exactly: the request holds
@H = custody lovelace + ordinary addition@, and the declared tip @T@ and
carrier @C@ add up to it, @T + C = H@; the fee and the change come from the
payer's ordinary funding output, which is also the collateral, and never from
the custody.
-}
module Singular.Registry.TxBuilder.TerminationBooking
    ( TerminationBooking (..)
    , bookTerminationImpl
    ) where

import Control.Monad (unless)
import Data.ByteString (ByteString)
import Data.ByteString.Short (ShortByteString)
import Data.ByteString.Short qualified as SBS
import Data.Map.Strict qualified as Map
import Data.Sequence.Strict qualified as StrictSeq
import Data.Set qualified as Set
import Lens.Micro ((&), (.~), (^.))
import PlutusCore.Data qualified as PLC

import Cardano.Ledger.Address (Addr (..))
import Cardano.Ledger.Alonzo.Scripts (AsIx (..))
import Cardano.Ledger.Api.Scripts.Data (Data (..))
import Cardano.Ledger.Api.Tx (bodyTxL, mkBasicTx, witsTxL)
import Cardano.Ledger.Api.Tx.Body
    ( collateralInputsTxBodyL
    , collateralReturnTxBodyL
    , inputsTxBodyL
    , mintTxBodyL
    , mkBasicTxBody
    , outputsTxBodyL
    , referenceInputsTxBodyL
    , scriptIntegrityHashTxBodyL
    )
import Cardano.Ledger.Api.Tx.Out
    ( TxOut
    , addrTxOutL
    , coinTxOutL
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
import Cardano.Ledger.BaseTypes (StrictMaybe (SJust, SNothing))
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
import Singular.Registry.Ledger
    ( Coin (..)
    , ConwayEra
    , PParams
    , TokenId (..)
    )
import Singular.Registry.LedgerProvider (Session)
import Singular.Registry.SessionIO (outputsAt, parameters)
import Singular.Registry.TxBuilder.Edges (selectFunding)
import Singular.Registry.TxBuilder.Internal
import Singular.Registry.TxBuilder.RegistrationBooking
    ( holdsStateToken
    )
import Singular.Registry.Types
    ( CageDatum (..)
    , OnChainTerminationRequest (..)
    , OnChainTokenState (..)
    , stateAppPolicyBytes
    , stateRequestPolicyBytes
    , terminationTrieReadyTagName
    )

{- | What a controller chooses for one termination. Everything else comes from
the registry's configuration: the minimum tip and the request policy.
-}
data TerminationBooking = TerminationBooking
    { tbKey :: !ByteString
    -- ^ The registry key being terminated
    , tbDeclaredTip :: !Coin
    -- ^ The declared tip, at least the registry's minimum tip
    , tbCarrier :: !Coin
    {- ^ The declared carrier lovelace: the held value less the tip, so that
    tip and carrier account for the whole of the custody value and the
    ordinary addition
    -}
    , tbNonce :: !Integer
    -- ^ The nonce the trie-ready tag commits to
    , tbCustody :: !(TxIn, TxOut ConwayEra)
    -- ^ The genuine custody output the booking spends, holding the singular tag
    , tbOrdinaryAdded :: !Coin
    -- ^ The ordinary addition the requester pays in beside the custody value
    , tbApplicationScript :: !ShortByteString
    -- ^ The script that guards the custody output, which the spend must satisfy
    , tbRedeemer :: !PLC.Data
    -- ^ The redeemer the custody's script is spent with
    }

refuse :: String -> IO a
refuse = ioError . userError . ("bookTermination: " <>)

{- | Build the unsigned booking of one termination, balanced from the payer's
largest ada-only output, which is also its collateral.

Everything the mint handler would refuse for the booking's own declarations is
refused here first, with the reason: a negative carrier, nonce or ordinary
addition, a tip below the registry's minimum, a tip and carrier that do not
add up to the held lovelace, a custody output that the ledger does not answer
or answers differently from the caller, one that does not hold exactly one of
the key's singular tag or holds anything beside it and lovelace, a custody
script that is not the one the custody address names, a state output that is
missing, does not hold the registry's state token or does not carry the
configuration's booking pins, and a request output below the minimum ada.
After balancing, a funding output that cannot leave its change its minimum
ada, or a collateral return at all, is refused. The payer's outputs that hold
anything beside ada, the key's singular tag included, are never funding.
-}
bookTerminationImpl
    :: CageConfig
    -> Session NoWitness IO
    -> TokenId
    -- ^ The registry token
    -> TxIn
    -- ^ The registry state output, referenced
    -> TerminationBooking
    -> Addr
    -- ^ Fee payer and change address
    -> IO ConwayTx
bookTerminationImpl cfg view tid stateRef b payer = do
    let Coin cost = defaultRegistrationCost cfg
        Coin minimumTip = defaultTip cfg
        Coin tip = tbDeclaredTip b
        Coin carrier = tbCarrier b
        Coin added = tbOrdinaryAdded b
        (custodyRef, statedCustody) = tbCustody b
        Coin custodyLovelace = statedCustody ^. coinTxOutL
        held = custodyLovelace + added
        activePolicy = policyIdFromPin (cfgActivePolicy cfg)
        singularName = AssetName (SBS.toShort (tbKey b))
    unless (carrier >= 0) $ refuse "the carrier is negative"
    unless (tbNonce b >= 0) $ refuse "the nonce is negative"
    unless (added >= 0) $ refuse "the ordinary addition is negative"
    unless (tip >= minimumTip) $
        refuse "the tip is below the registry's minimum tip"
    unless (tip + carrier == held) $
        refuse "the tip and carrier must add up to the held lovelace"
    let requestScript = mkRequestScript cfg tid
        requestPolicy = PolicyID (hashScript requestScript)
    unless (requestPolicy == policyIdFromPin (cfgRequestPolicy cfg)) $
        refuse "the request script is not the registry's request policy"
    -- The custody: the live output the caller names, holding the key's one
    -- singular tag and lovelace and nothing else.
    custodyUtxos <- outputsAt view (statedCustody ^. addrTxOutL)
    custody <- case findUtxoByTxIn custodyRef custodyUtxos of
        Just (_, out) -> pure out
        Nothing -> refuse "the custody output not found at its address"
    unless (custody == statedCustody) $
        refuse "the stated custody differs from the live output"
    let MaryValue _ (MultiAsset assets) = custody ^. valueTxOutL
        heldAssets = Map.filter (not . Map.null) assets
    case Map.lookup activePolicy heldAssets >>= Map.lookup singularName of
        Nothing -> refuse "the custody output does not hold the key's singular tag"
        Just quantity ->
            unless (quantity == 1) $
                refuse
                    "the custody output holds more than one of the key's singular tag"
    unless
        ( Map.keys heldAssets == [activePolicy]
            && fmap Map.size (Map.lookup activePolicy heldAssets) == Just 1
        )
        $ refuse
            "the custody output holds more than the singular tag and lovelace"
    let custodyScript = scriptFromBytes "application" (tbApplicationScript b)
    case custody ^. addrTxOutL of
        Addr _ (ScriptHashObj h) _
            | h == hashScript custodyScript -> pure ()
        _ -> refuse "the application script is not the custody's script"
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
    -- The request: the whole custody value and the ordinary addition, the
    -- key's singular tag and the trie-ready tag the policy mints for it.
    let request =
            OnChainTerminationRequest
                { termRegistry = onChainTokenId tid
                , termKey = tbKey b
                , termDestination = mempty
                , termDeclaredTip = tip
                , termCarrierAda = carrier
                , termNonce = tbNonce b
                }
        trieName = AssetName (SBS.toShort (terminationTrieReadyTagName request))
        minted =
            MultiAsset (Map.singleton requestPolicy (Map.singleton trieName 1))
        singularTag =
            MultiAsset (Map.singleton activePolicy (Map.singleton singularName 1))
        requestOut =
            mkBasicTxOut
                (requestAddrFromCfg cfg tid (network cfg))
                (MaryValue (Coin held) (singularTag <> minted))
                & datumTxOutL .~ mkInlineDatum (toPlcData (TerminationDatum request))
    pp <- parameters view
    let Coin minimumAda = getMinCoinTxOut pp requestOut
    unless (held >= minimumAda) $
        refuse
            "the held value is below the minimum ada its request output needs"
    walletUtxos <- outputsAt view payer
    funding <- case selectFunding Nothing walletUtxos of
        Left why -> refuse why
        Right u -> pure u
    let inputs = Set.fromList [custodyRef, fst funding]
        redeemers =
            Redeemers $
                Map.fromList
                    [
                        ( ConwaySpending (AsIx (spendingIndex custodyRef inputs))
                        , (Data (tbRedeemer b), placeholderExUnits)
                        )
                    ,
                        ( ConwayMinting (AsIx 0)
                        , (Data (PLC.Constr 0 []), placeholderExUnits)
                        )
                    ]
        body =
            mkBasicTxBody
                & inputsTxBodyL .~ inputs
                & outputsTxBodyL .~ StrictSeq.singleton requestOut
                & mintTxBodyL .~ minted
                & referenceInputsTxBodyL .~ Set.singleton stateRef
                & collateralInputsTxBodyL .~ Set.singleton (fst funding)
                & scriptIntegrityHashTxBodyL .~ computeScriptIntegrity pp redeemers
        tx =
            mkBasicTx body
                & witsTxL . scriptTxWitsL
                    .~ Map.fromList
                        [ (hashScript requestScript, requestScript)
                        , (hashScript custodyScript, custodyScript)
                        ]
                & witsTxL . rdmrsTxWitsL .~ redeemers
    -- The state output is a reference input: when it carries a script, the
    -- ledger charges the fee for the script's bytes, so the balancer is
    -- given the resolved output to price them.
    balanced <-
        evaluateAndBalanceReferencing
            view
            pp
            [funding, (custodyRef, custody)]
            [(stateRef, stateOut)]
            payer
            tx
    requireCarriesMinimums pp balanced
    pure balanced

{- | The balancer appends a change output whatever it holds and rejects only a
negative remainder, so a funding output that leaves the change less than its
minimum ada would make a transaction the ledger refuses; the booking refuses
it first. The balancer states a collateral return only when it holds its
minimum; otherwise it states none and the whole funding output would be at
risk, which a booking never accepts.
-}
requireCarriesMinimums :: PParams ConwayEra -> ConwayTx -> IO ()
requireCarriesMinimums pp tx = do
    unless (all carries (body ^. outputsTxBodyL)) $
        refuse
            "the funding output is too small to carry the booking, its fee, its collateral and their change"
    case body ^. collateralReturnTxBodyL of
        SJust _ -> pure ()
        SNothing ->
            refuse
                "the funding output cannot leave a collateral return of its minimum ada, so its whole value would be collateral"
  where
    body = tx ^. bodyTxL
    carries o = o ^. coinTxOutL >= getMinCoinTxOut pp o
