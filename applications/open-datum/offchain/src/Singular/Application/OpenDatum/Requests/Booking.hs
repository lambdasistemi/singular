{-# LANGUAGE LambdaCase #-}

{- |
Module      : Singular.Application.OpenDatum.Requests.Booking
Description : Book the registration of a key
License     : Apache-2.0

Booking a registration puts its request at the address of the request
validator, holding an approval token that commits the change, and the
request value. The validator accepts the mint when the output carries the ten
fields of the registration, the controller signs, the clock fixes the
deadlines from the registry's configuration record read by reference, and the
output holds at least the deposit.
-}
module Singular.Application.OpenDatum.Requests.Booking
    ( Booking (..)
    , buildBookRegistration
    ) where

import Control.Exception (throwIO)
import Control.Monad (when)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Except (ExceptT (..), runExceptT, throwE)
import Data.ByteString (ByteString)
import Data.Map.Strict qualified as Map
import Lens.Micro ((&), (.~), (^.))
import PlutusCore.Data qualified as PLC

import Cardano.Crypto.Hash (hashFromBytes, hashToBytes)
import Cardano.Ledger.Address (Addr (..))
import Cardano.Ledger.Api.Tx.Out
    ( addrTxOutL
    , datumTxOutL
    , getMinCoinTxOut
    , mkBasicTxOut
    , valueTxOutL
    )
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Credential (Credential (..))
import Cardano.Ledger.Hashes (ScriptHash (..))
import Cardano.Ledger.Keys (KeyHash (..))
import Cardano.Ledger.Mary.Value
    ( AssetName
    , MaryValue (..)
    , MultiAsset (..)
    , PolicyID (..)
    )
import Cardano.Ledger.TxIn (TxIn)
import Cardano.Slotting.Slot (SlotNo (..))
import Cardano.Tx.Build qualified as Tx
import Cardano.Tx.Ledger (ConwayTx)

import Singular.Application.OpenDatum.Requests.Assemble
    ( Payer (..)
    , assembleTransaction
    , inlineDatumOf
    , readOutputs
    , resolvePayer
    , tipSlot
    , validityFromTip
    )
import Singular.Application.OpenDatum.Requests.Records
    ( AsData (..)
    , MintAction (..)
    , RegistrationData (..)
    , RequestParameters (..)
    , approvalNameOf
    , decodeConfiguration
    , liveDatum
    , mintRedeemer
    , registrationDatum
    )
import Singular.Application.OpenDatum.Requests.Refusal (Refusal (..))
import Singular.Application.OpenDatum.Requests.Script
    ( RequestScript
    , referenceOutputs
    , requestAddress
    , requestPolicy
    , requestScriptHash
    , useScript
    )
import Singular.Registry.Evidence (NoWitness)
import Singular.Registry.Ledger (ConwayEra, TxOut)
import Singular.Registry.LedgerProvider
    ( OutputQuery (..)
    , Session
    )
import Singular.Registry.SessionIO (floorSlot, parameters, slotStart)
import Singular.Registry.TrieState
    ( RegistryIdentity (..)
    , StatePolicyId (..)
    )
import Singular.Registry.TxBuilder.Internal (mkInlineDatum)
import Singular.State.Preimage
    ( activeTokenName
    , configurationTokenName
    )

-- | What a booking asks for.
data Booking = Booking
    { bookRegistry :: RegistryIdentity
    , bookKey :: ByteString
    , bookPayload :: PLC.Data
    -- ^ The payload the key's holding starts with
    , bookDeposit :: Coin
    -- ^ What the holding keeps; committed in the approval
    , bookTip :: Coin
    {- ^ The request value above the deposit: what the folder takes. The
    request holds the deposit and the tip, raised to the ledger's minimum
    ADA of the request output when that is more.
    -}
    , bookRefund :: Addr
    -- ^ Where a reclaim or a cleanup returns the value
    }
    deriving stock (Eq, Show)

{- | Build the booking transaction. The payer funds it and signs it; its
payment key is the controller of the registration.
-}
buildBookRegistration
    :: Session NoWitness IO
    -> RequestScript
    -> Booking
    -> Addr
    -- ^ The payer: fee, collateral and change, and the controller's key
    -> IO (Either Refusal ConwayTx)
buildBookRegistration session script booking payerAddress = runExceptT $ do
    payer <- ExceptT (resolvePayer session payerAddress)
    (recordRef, record, configured) <-
        ExceptT (configurationRecord session script (bookRegistry booking))
    (lower, upper, bookedAt) <-
        ExceptT (bookingWindow session (rpBookingWidth configured))
    protocol <- lift (parameters session)
    let KeyHash controllerHash = payerKey payer
        controller = hashToBytes controllerHash
        application = requestAddress (payerNetwork payer) script
        Coin kept = bookDeposit booking
        Coin tipped = bookTip booking
        initial =
            liveDatum
                (bookRegistry booking)
                (bookKey booking)
                controller
                kept
                (bookPayload booking)
        processed = bookedAt + rpProcessTime configured
        registration =
            RegistrationData
                { rdRegistry = bookRegistry booking
                , rdKey = bookKey booking
                , rdController = controller
                , rdRefundAddress = bookRefund booking
                , rdHoldingAddress = application
                , rdInitialDatum = initial
                , rdDeposit = kept
                , rdBookedAt = bookedAt
                , rdProcessDeadline = processed
                , rdReclaimEnd = processed + rpRetractTime configured
                }
    datum <-
        maybe
            (throwE (BuildFailed "an address of the booking has no Plutus form"))
            pure
            $ registrationDatum registration
    approval <-
        maybe
            (throwE (BuildFailed "the approval of the booking has no name"))
            pure
            $ approvalNameOf registration
    activePolicy <- activePolicyOf (bookRegistry booking)
    let holding =
            mkBasicTxOut
                application
                ( MaryValue
                    (Coin kept)
                    ( MultiAsset
                        ( Map.singleton
                            activePolicy
                            ( Map.singleton
                                (activeTokenName (bookRegistry booking) (bookKey booking))
                                1
                            )
                        )
                    )
                )
                & datumTxOutL .~ mkInlineDatum initial
        smallest = getMinCoinTxOut protocol holding
    when (Coin kept < smallest) $
        throwE (DepositBelowHolding (Coin kept) smallest)
    scriptOutputs <- ExceptT (referenceOutputs session script)
    let tokens =
            MultiAsset
                (Map.singleton (requestPolicy script) (Map.singleton approval 1))
        funding = payerFunding payer
    ExceptT $
        assembleTransaction
            session
            [funding]
            ((recordRef, record) : scriptOutputs)
            payerAddress
            ( do
                output <-
                    Tx.payTo'
                        application
                        (MaryValue (Coin (kept + tipped)) tokens)
                        (AsData datum)
                Tx.mint
                    (requestPolicy script)
                    (Map.singleton approval 1)
                    (AsData (mintRedeemer [BookRegistration (toInteger output)]))
                useScript script
                Tx.reference recordRef
                Tx.requireSignature (payerKey payer)
                Tx.validFrom lower
                Tx.validTo upper
                Tx.collateral (fst funding)
            )

{- | The one configuration record of a registry, read from the chain: an
output at the address of the script, holding exactly the record's token, with
the parameters inline. No record, or several, is refused.
-}
configurationRecord
    :: Session NoWitness IO
    -> RequestScript
    -> RegistryIdentity
    -> IO (Either Refusal (TxIn, TxOut ConwayEra, RequestParameters))
configurationRecord session script registry = do
    let policy = requestPolicy script
        name = configurationTokenName registry
    found <-
        readOutputs session (HoldingAsset (policy, name))
            >>= either throwIO pure
    let records =
            [ (ref, output, parameters')
            | (ref, output) <- found
            , atScript output
            , holdsOnly policy name output
            , Just parameters' <- [inlineDatumOf output >>= decodeConfiguration]
            ]
    pure $ case records of
        [] -> Left NoConfiguration
        [record] -> Right record
        several -> Left (AmbiguousConfiguration (length several))
  where
    atScript output = case output ^. addrTxOutL of
        Addr _ (ScriptHashObj h) _ -> h == requestScriptHash script
        _ -> False

-- | The output holds this token once and nothing but ADA besides.
holdsOnly :: PolicyID -> AssetName -> TxOut ConwayEra -> Bool
holdsOnly policy name output =
    let MaryValue _ (MultiAsset assets) = output ^. valueTxOutL
    in  assets == Map.singleton policy (Map.singleton name 1)

{- | The interval a booking declares: from the tip, as long as the booking
width and the ledger's horizon allow, and the time its upper bound stands at,
which the booking commits as its time.
-}
bookingWindow
    :: Session NoWitness IO
    -> Integer
    -> IO (Either Refusal (SlotNo, SlotNo, Integer))
bookingWindow session width = do
    now <- tipSlot session
    nowMs <- slotStart session now
    wanted <- floorSlot session (nowMs + width)
    validityFromTip session now wanted >>= \case
        Nothing -> pure (Left (BookingWidthTooNarrow width))
        Just upper -> do
            upperMs <- slotStart session upper
            pure (Right (now, upper, upperMs))

{- | The policy of the active token of a registry: its state policy, which
must be a script hash.
-}
activePolicyOf
    :: (Monad m) => RegistryIdentity -> ExceptT Refusal m PolicyID
activePolicyOf (RegistryIdentity (StatePolicyId bytes) _) =
    maybe
        ( throwE
            (BuildFailed "the state policy of the registry is not a script hash")
        )
        (pure . PolicyID . ScriptHash)
        (hashFromBytes bytes)
