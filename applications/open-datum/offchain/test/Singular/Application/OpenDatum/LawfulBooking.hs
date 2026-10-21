{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.Application.OpenDatum.LawfulBooking
Description : The bookings the accepted open-datum programs accept, built apart from any producer
License     : Apache-2.0

The registration and the termination of a key as the frozen law books them,
built here from the programs' own conditions and nothing else: the setup a
control needs when it must start from a registry that already holds a key, and
the reference a producer's booking is compared with. These functions are test
instruments. No producer calls them, none of them decides what a producer
does, and what they build is built under the retained compiled programs, so
a booking that comes out of them is a booking those programs accepted (the
builder evaluates every script it carries before it balances).

A registration is booked by one transaction that mints the application tag
under the application policy and the trie-ready tag under the request policy.
Its request output holds both tags, the declared cost, tip and carrier and the
registration datum that carries the complete envelope; the controller signs.
A termination is booked by spending the key's custody output through the
application's @BookTermination@ and minting the trie-ready tag under the
request policy; its request output takes the whole custody value and the
requester's declared addition.
-}
module Singular.Application.OpenDatum.LawfulBooking
    ( lawfulInsertBooking
    , lawfulInsertBookingAs
    , TerminationFault (..)
    , lawfulTerminationBooking
    , lawfulTerminationBookingWith
    , lawfulApplicationBurn
    , applicationAddressBytes
    , bookInsertRedeemerOf
    ) where

import Control.Monad (unless)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Short qualified as SBS
import Data.List (sort)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Sequence.Strict qualified as StrictSeq
import Data.Set qualified as Set
import Lens.Micro ((&), (.~), (^.))
import PlutusCore.Data qualified as PLC
import PlutusTx.Builtins.Internal (BuiltinByteString (..))

import Cardano.Crypto.Hash.Class (hashFromBytes)
import Cardano.Ledger.Address (Addr (..))
import Cardano.Ledger.Allegra.Scripts (ValidityInterval (..))
import Cardano.Ledger.Alonzo.Scripts (AsIx (..))
import Cardano.Ledger.Alonzo.TxBody (reqSignerHashesTxBodyL)
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
    , coinTxOutL
    , datumTxOutL
    , mkBasicTxOut
    )
import Cardano.Ledger.Api.Tx.Wits
    ( Redeemers (..)
    , rdmrsTxWitsL
    , scriptTxWitsL
    )
import Cardano.Ledger.BaseTypes
    ( Network (..)
    , SlotNo
    , StrictMaybe (SJust)
    )
import Cardano.Ledger.Conway.Scripts (ConwayPlutusPurpose (..))
import Cardano.Ledger.Core (hashScript)
import Cardano.Ledger.Keys (KeyHash (..), KeyRole (..))
import Cardano.Ledger.Mary.Value
    ( AssetName (..)
    , MaryValue (..)
    , MultiAsset (..)
    , PolicyID (..)
    )
import Cardano.Ledger.TxIn (TxIn)
import Cardano.Tx.Ledger (ConwayTx)

import Singular.Application.OpenDatum.Envelope
    ( Control (..)
    , Envelope (..)
    , envelopeToData
    )
import Singular.Registry.Config (CageConfig (..))
import Singular.Registry.Evidence (NoWitness)
import Singular.Registry.Ledger
    ( Coin (..)
    , ConwayEra
    , TokenId (..)
    )
import Singular.Registry.LedgerProvider (Session)
import Singular.Registry.SessionIO (outputsAt, parameters)
import Singular.Registry.SessionIO qualified as Services
import Singular.Registry.TxBuilder.Edges (selectFunding)
import Singular.Registry.TxBuilder.Internal
import Singular.Registry.Types
    ( CageDatum (..)
    , OnChainRegistrationRequest (..)
    , OnChainTerminationRequest (..)
    , applicationTagName
    , terminationTrieReadyTagName
    , trieReadyTagName
    )

refuse :: String -> IO a
refuse = ioError . userError . ("lawful booking: " <>)

keyHashOf :: ByteString -> IO (KeyHash Guard)
keyHashOf bytes =
    maybe
        (refuse "the controller is not a 28-byte key hash")
        (pure . KeyHash)
        (hashFromBytes bytes)

{- | The enterprise script address of the applied open-datum script, as the
application's own destination bytes: the header of the network, then the
script hash.
-}
applicationAddressBytes
    :: Network -> SBS.ShortByteString -> ByteString
applicationAddressBytes net applied =
    BS.cons header (scriptHashBytes (computeScriptHash applied))
  where
    header = case net of
        Mainnet -> 0x71
        Testnet -> 0x70

{- | The application's registration redeemer, constructor 0 of the mint
redeemer type: the key, the owner, the destination address and the complete
envelope.
-}
bookInsertRedeemerOf
    :: ByteString -> ByteString -> ByteString -> Envelope -> PLC.Data
bookInsertRedeemerOf key owner address envelope =
    PLC.Constr
        0
        [PLC.B key, PLC.B owner, PLC.B address, envelopeToData envelope]

{- | The registration of the envelope's key by its controller: the request the
law asks for, the two tags, the controller as a required signer, balanced from
the payer's largest ada-only output.
-}
lawfulInsertBooking
    :: CageConfig
    -> Session NoWitness IO
    -> TokenId
    -> TxIn
    -- ^ The registry state output, referenced
    -> SBS.ShortByteString
    -- ^ The applied open-datum script, which is the application policy
    -> Envelope
    -> Coin
    -- ^ The declared tip
    -> Integer
    -- ^ The nonce both tags commit to
    -> (SlotNo, SlotNo)
    -- ^ The validity interval; the start of its upper slot is the booked time
    -> Addr
    -- ^ The payer, whose key hash is the controller
    -> IO ConwayTx
lawfulInsertBooking = lawfulInsertBookingAs Nothing

{- | 'lawfulInsertBooking' with the application mint redeemer replaced when one
is named: the single fact a refusal control moves.
-}
lawfulInsertBookingAs
    :: Maybe PLC.Data
    -> CageConfig
    -> Session NoWitness IO
    -> TokenId
    -> TxIn
    -- ^ The registry state output, referenced
    -> SBS.ShortByteString
    -- ^ The applied open-datum script, which is the application policy
    -> Envelope
    -> Coin
    -- ^ The declared tip
    -> Integer
    -- ^ The nonce both tags commit to
    -> (SlotNo, SlotNo)
    -- ^ The validity interval; the start of its upper slot is the booked time
    -> Addr
    -- ^ The payer, whose key hash is the controller
    -> IO ConwayTx
lawfulInsertBookingAs override cfg view tid stateRef applied envelope (Coin tip) nonce (lower, upper) payer = do
    let control = envControl envelope
        key = ctlKey control
        owner = ctlController control
        address = applicationAddressBytes (network cfg) applied
        Coin cost = defaultRegistrationCost cfg
        carrier = ctlDeposit control
        applicationScript = scriptFromBytes "application" applied
        applicationPolicy = PolicyID (hashScript applicationScript)
        requestScript = mkRequestScript cfg tid
        requestPolicy = PolicyID (hashScript requestScript)
    unless
        (applicationPolicy == policyIdFromPin (cfgApplicationPolicy cfg))
        $ refuse "the applied script is not the registry's application policy"
    signer <- keyHashOf owner
    upperMs <- Services.slotStart view upper
    stateUtxos <- outputsAt view (cageAddrFromCfg cfg (network cfg))
    stateOut <- case findUtxoByTxIn stateRef stateUtxos of
        Just (_, out) -> pure out
        Nothing -> refuse "the state output is not at the registry's state address"
    let request =
            OnChainRegistrationRequest
                { regRegistry = onChainTokenId tid
                , regKey = key
                , regRefundAddress = BuiltinByteString owner
                , regDestination = address
                , regDatum = Just (envelopeToData envelope)
                , regSubmittedAt = upperMs
                , regRegistrationCost = cost
                , regDeclaredTip = tip
                , regCarrierAda = carrier
                , regNonce = nonce
                }
        tags =
            MultiAsset
                ( Map.fromList
                    [
                        ( requestPolicy
                        , Map.singleton (AssetName (SBS.toShort (trieReadyTagName request))) 1
                        )
                    ,
                        ( applicationPolicy
                        , Map.singleton
                            ( AssetName
                                ( SBS.toShort
                                    (applicationTagName key (BuiltinByteString owner) address nonce)
                                )
                            )
                            1
                        )
                    ]
                )
        requestOut =
            mkBasicTxOut
                (requestAddrFromCfg cfg tid (network cfg))
                (MaryValue (Coin (cost + tip + carrier)) tags)
                & datumTxOutL .~ mkInlineDatum (toPlcData (RegistrationDatum request))
    pp <- parameters view
    walletUtxos <- outputsAt view payer
    funding <- either refuse pure (selectFunding Nothing walletUtxos)
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
                        ,
                            ( Data
                                (fromMaybe (bookInsertRedeemerOf key owner address envelope) override)
                            , placeholderExUnits
                            )
                        )
                    ]
        body =
            mkBasicTxBody
                & inputsTxBodyL .~ Set.singleton (fst funding)
                & outputsTxBodyL .~ StrictSeq.singleton requestOut
                & mintTxBodyL .~ tags
                & referenceInputsTxBodyL .~ Set.singleton stateRef
                & collateralInputsTxBodyL .~ Set.singleton (fst funding)
                & reqSignerHashesTxBodyL .~ Set.singleton signer
                & vldtTxBodyL .~ ValidityInterval (SJust lower) (SJust upper)
                & scriptIntegrityHashTxBodyL .~ computeScriptIntegrity pp redeemers
        tx =
            mkBasicTx body
                & witsTxL . scriptTxWitsL
                    .~ Map.fromList
                        [ (hashScript requestScript, requestScript)
                        , (hashScript applicationScript, applicationScript)
                        ]
                & witsTxL . rdmrsTxWitsL .~ redeemers
    evaluateAndBalanceReferencing
        view
        pp
        [funding]
        [(stateRef, stateOut)]
        payer
        tx

-- | What a termination booking is made to get wrong, for a refusal control.
data TerminationFault
    = -- | Nothing: the booking the law asks for
      Intact
    | -- | The controller does not sign
      WithoutSigner
    | -- | The request holds one lovelace less than the custody and the addition
      ShortRequest
    deriving stock (Eq, Show)

{- | The termination of a key: the custody output spent through
@BookTermination { ordinary_added }@, the trie-ready tag minted under the
request policy, the controller as a required signer, a request output holding
the whole custody value with the key's singular tag.
-}
lawfulTerminationBooking
    :: CageConfig
    -> Session NoWitness IO
    -> TokenId
    -> TxIn
    -> SBS.ShortByteString
    -> (TxIn, TxOut ConwayEra)
    -> ByteString
    -> ByteString
    -> Coin
    -> Integer
    -> Addr
    -> IO ConwayTx
lawfulTerminationBooking = lawfulTerminationBookingWith Intact

-- | 'lawfulTerminationBooking' made to get one thing wrong, or nothing.
lawfulTerminationBookingWith
    :: TerminationFault
    -> CageConfig
    -> Session NoWitness IO
    -> TokenId
    -> TxIn
    -- ^ The registry state output, referenced
    -> SBS.ShortByteString
    -- ^ The applied open-datum script, which guards the custody
    -> (TxIn, TxOut ConwayEra)
    -- ^ The key's custody output
    -> ByteString
    -- ^ The key
    -> ByteString
    -- ^ The controller
    -> Coin
    -- ^ The declared tip
    -> Integer
    -- ^ The nonce the trie-ready tag commits to
    -> Addr
    -- ^ The payer
    -> IO ConwayTx
lawfulTerminationBookingWith fault cfg view tid stateRef applied (custodyRef, custody) key owner (Coin tip) nonce payer = do
    let Coin held = custody ^. coinTxOutL
        carrier = held - tip
        applicationScript = scriptFromBytes "application" applied
        requestScript = mkRequestScript cfg tid
        requestPolicy = PolicyID (hashScript requestScript)
        activePolicy = policyIdFromPin (cfgActivePolicy cfg)
        singularName = AssetName (SBS.toShort key)
    unless (carrier >= 0) $ refuse "the tip exceeds the held value"
    signer <- keyHashOf owner
    stateUtxos <- outputsAt view (cageAddrFromCfg cfg (network cfg))
    stateOut <- case findUtxoByTxIn stateRef stateUtxos of
        Just (_, out) -> pure out
        Nothing -> refuse "the state output is not at the registry's state address"
    let request =
            OnChainTerminationRequest
                { termRegistry = onChainTokenId tid
                , termKey = key
                , termDestination = mempty
                , termDeclaredTip = tip
                , termCarrierAda = carrier
                , termNonce = nonce
                }
        minted =
            MultiAsset
                ( Map.singleton
                    requestPolicy
                    ( Map.singleton
                        (AssetName (SBS.toShort (terminationTrieReadyTagName request)))
                        1
                    )
                )
        singularTag =
            MultiAsset (Map.singleton activePolicy (Map.singleton singularName 1))
        requestOut =
            mkBasicTxOut
                (requestAddrFromCfg cfg tid (network cfg))
                ( MaryValue
                    (Coin (if fault == ShortRequest then held - 1 else held))
                    (singularTag <> minted)
                )
                & datumTxOutL .~ mkInlineDatum (toPlcData (TerminationDatum request))
    pp <- parameters view
    walletUtxos <- outputsAt view payer
    funding <- either refuse pure (selectFunding Nothing walletUtxos)
    let inputs = Set.fromList [custodyRef, fst funding]
        redeemers =
            Redeemers $
                Map.fromList
                    [
                        ( ConwaySpending (AsIx (spendingIndex custodyRef inputs))
                        , (Data (PLC.Constr 2 [PLC.I 0]), placeholderExUnits)
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
                & reqSignerHashesTxBodyL
                    .~ (if fault == WithoutSigner then Set.empty else Set.singleton signer)
                & scriptIntegrityHashTxBodyL .~ computeScriptIntegrity pp redeemers
        tx =
            mkBasicTx body
                & witsTxL . scriptTxWitsL
                    .~ Map.fromList
                        [ (hashScript requestScript, requestScript)
                        , (hashScript applicationScript, applicationScript)
                        ]
                & witsTxL . rdmrsTxWitsL .~ redeemers
    evaluateAndBalanceReferencing
        view
        pp
        [funding, (custodyRef, custody)]
        [(stateRef, stateOut)]
        payer
        tx

{- | A transaction that only burns one application tag, as the permissionless
fold does: the output holding the tag is spent, one tag is burned under the
application policy with this redeemer, and nothing else is minted. The builder
evaluates the application's mint before it balances, so a refusal of the
redeemer is an exception here.
-}
lawfulApplicationBurn
    :: CageConfig
    -> Session NoWitness IO
    -> SBS.ShortByteString
    -- ^ The applied open-datum script, which is the application policy
    -> PLC.Data
    -- ^ The burn redeemer
    -> (TxIn, TxOut ConwayEra)
    -- ^ The output holding the tag
    -> ByteString
    -- ^ The tag name
    -> Addr
    -- ^ The payer
    -> IO ConwayTx
lawfulApplicationBurn cfg view applied redeemer (tagRef, tagOut) tagName payer = do
    let applicationScript = scriptFromBytes "application" applied
        applicationPolicy = PolicyID (hashScript applicationScript)
        burned =
            MultiAsset
                ( Map.singleton
                    applicationPolicy
                    (Map.singleton (AssetName (SBS.toShort tagName)) (-1))
                )
    unless
        (applicationPolicy == policyIdFromPin (cfgApplicationPolicy cfg))
        $ refuse "the applied script is not the registry's application policy"
    pp <- parameters view
    walletUtxos <- outputsAt view payer
    funding <- either refuse pure (selectFunding Nothing walletUtxos)
    let redeemers =
            Redeemers $
                Map.singleton
                    (ConwayMinting (AsIx 0))
                    (Data redeemer, placeholderExUnits)
        body =
            mkBasicTxBody
                & inputsTxBodyL .~ Set.fromList [tagRef, fst funding]
                & mintTxBodyL .~ burned
                & collateralInputsTxBodyL .~ Set.singleton (fst funding)
                & scriptIntegrityHashTxBodyL .~ computeScriptIntegrity pp redeemers
        tx =
            mkBasicTx body
                & witsTxL . scriptTxWitsL
                    .~ Map.singleton (hashScript applicationScript) applicationScript
                & witsTxL . rdmrsTxWitsL .~ redeemers
    evaluateAndBalanceReferencing
        view
        pp
        [funding, (tagRef, tagOut)]
        []
        payer
        tx
