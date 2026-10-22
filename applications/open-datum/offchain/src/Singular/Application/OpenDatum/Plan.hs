{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.Application.OpenDatum.Plan
Description : What an insert, update or terminate asks of the registry, decided without a wallet key
License     : Apache-2.0

The checks and the choices that turn an attached registry and a caller's
public identity into the transactions a write command builds: the
envelope's identity and deposit, who may act on a key, the application's
published reference, the booking's approval and destination, and the
update's builder arguments. Nothing here signs, submits or journals, so the
submitting commands ("Singular.Application.OpenDatum.Entry") and the read-only preparation
route ("Singular.Application.OpenDatum.Preview") decide from the same code and cannot drift.
-}
module Singular.Application.OpenDatum.Plan
    ( -- * Reading what the caller names
      readJson

      -- * Who acts
    , controllerCheck

      -- * What a booking asks
    , Booked (..)
    , readInsertPayload
    , insertionOf
    , planInsert
    , planTerminate
    , transferOf

      -- * What an update asks
    , planUpdate
    , buildUpdate
    , previewInsert

      -- * What it costs
    , refuseOver
    , refuseUnderfunded
    , emptyFields
    , retainedFaucetStep
    , resolveFunding
    , outlayReport
    ) where

import Control.Monad (unless, when)
import Data.Aeson (Value)
import Data.ByteString (ByteString)
import Data.ByteString.Short qualified as SBS
import Data.Foldable (toList)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text qualified as T
import Lens.Micro ((&), (.~), (^.))
import PlutusCore.Data qualified as PLC

import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.Api.Tx (bodyTxL)
import Cardano.Ledger.Api.Tx.Body (outputsTxBodyL)
import Cardano.Ledger.Api.Tx.Out
    ( TxOut
    , coinTxOutL
    , datumTxOutL
    , getMinCoinTxOut
    , mkBasicTxOut
    )
import Cardano.Ledger.Mary.Value
    ( AssetName (..)
    , MaryValue (..)
    , MultiAsset (..)
    )
import Cardano.Ledger.TxIn (TxIn)
import Cardano.Slotting.Slot (SlotNo (..))
import Cardano.Tx.Ledger (ConwayTx)

import Singular.Application.OpenDatum.Book
    ( bookInsertRedeemer
    , bookTerminationRedeemer
    )
import Singular.Application.OpenDatum.Build
    ( PayloadRefusal (..)
    , minimumDeposit
    , readPayload
    )
import Singular.Application.OpenDatum.Envelope
    ( Control (..)
    , Envelope (..)
    , envelopeFromData
    , envelopeToData
    , envelopeToJson
    )
import Singular.Application.OpenDatum.InsertEnvelope (insertEnvelope)
import Singular.Application.OpenDatum.Script (openDatumAddressBytes)
import Singular.Application.OpenDatum.Update
    ( UpdateArgs (..)
    , updatePayloadTx
    )
import Singular.Application.OpenDatum.Value (openDatumApplication)
import Singular.CLI.Command (EntryArgs (..), Key (..))
import Singular.CLI.Live
import Singular.CLI.Outlay (Outlay, bookingOutlay, terminationOutlay)
import Singular.CLI.Plan
    ( emptyFields
    , outlayReport
    , readJson
    , refuseOver
    , refuseUnderfunded
    , resolveFunding
    , retainedFaucetStep
    )
import Singular.CLI.Receipt (OutcomeClass (..))
import Singular.CLI.Registry (hexT)
import Singular.CLI.Session (failWith)
import Singular.Registry.Application (DecodedHolding (..))
import Singular.Registry.Config (CageConfig (..))
import Singular.Registry.Evidence qualified as Cage
import Singular.Registry.Ledger (Coin (..), ConwayEra, PParams)
import Singular.Registry.LedgerProvider qualified as Cage
import Singular.Registry.SessionIO qualified as Cage
import Singular.Registry.TxBuilder.Edges (selectFunding)
import Singular.Registry.TxBuilder.Internal
    ( addrFromBytes
    , mkInlineDatum
    , policyIdFromPin
    )
import Singular.Registry.TxBuilder.RegistrationBooking
    ( RegistrationBooking (..)
    , bookRegistrationImpl
    , registrationWindow
    )
import Singular.Registry.TxBuilder.TerminationBooking
    ( CustodyAuthority (..)
    , TerminationBooking (..)
    , bookTerminationImpl
    )
import Singular.Registry.Types
    ( Edge
    , edgeInsertActive
    , edgeUpdateTerminal
    )

{- | The lovelace a booking transfers into its request: what the request output
holds, the first output of the booking.
-}
transferOf :: ConwayTx -> Integer
transferOf booking = case toList (booking ^. bodyTxL . outputsTxBodyL) of
    request : _ -> let Coin c = request ^. coinTxOutL in c
    [] -> 0

-- | The caller must be the envelope's controller.
controllerCheck :: ByteString -> Control -> IO ()
controllerCheck caller c =
    unless (ctlController c == caller) $
        failWith
            ClientRefusal
            ( "the envelope's controller is 0x"
                <> T.unpack (hexT (ctlController c))
                <> " but this command signs as 0x"
                <> T.unpack (hexT caller)
            )

-- | The application's published reference output, required by every write.
appReferenceOf :: Live -> IO TxIn
appReferenceOf live =
    maybe
        ( failWith
            Partial
            "the deployment records no published application reference"
        )
        (pure . fst)
        (applicationReference openDatumApplication live)

{- | A holding view as the envelope the entry commands still book with
(slice 2 B shim; slice 4 moves these commands).
-}
toEnvelopeHolding
    :: ((TxIn, TxOut ConwayEra), DecodedHolding)
    -> Either String ((TxIn, TxOut ConwayEra), Envelope)
toEnvelopeHolding (u, dh) = case envelopeFromData (dhDatumData dh) of
    Left why -> Left why
    Right e -> Right (u, e)

{- | One booking through the application: the edge it books and how it is
built. The builder is the registry's shared registration or termination
booking, given what the application owns (the mint redeemer or the custody
spend, the controller as the required signer), so the producers, the preview
and the combined commands all build the same booking.
-}
data Booked = Booked
    { bookedEdge :: Edge
    , bookedBuild :: Cage.Session Cage.NoWitness IO -> Addr -> IO ConwayTx
    -- ^ The unsigned booking from one view, paid and refunded by this address
    , bookedOutlay
        :: PParams ConwayEra -> [(TxIn, TxOut ConwayEra)] -> ConwayTx -> Outlay
    -- ^ What the booking puts out of the wallet, measured from its body
    }

{- | An insertion under @envelope@, built by the command from its own sources.
The custody output the fold will make must be able to carry the deposit the
envelope names: the ledger's minimum for that output is asked of the
parameters of the booking's own view and a deposit below it is refused, naming
the amount, before anything is built. The deposit is never topped up.
-}
planInsert
    :: Cage.Session Cage.NoWitness IO -> Live -> Envelope -> IO Booked
planInsert v live envelope = do
    let s = liveSaved live
        cfg = savedCfg s
        c = envControl envelope
        address = openDatumAddressBytes (network cfg) (applied s)
        deposit = ctlDeposit c
    pp <- Cage.parameters v
    custodyAddress <-
        maybe
            (failWith Partial "the application's address does not decode")
            pure
            (addrFromBytes address)
    let custody =
            mkBasicTxOut
                custodyAddress
                ( MaryValue
                    (Coin deposit)
                    ( MultiAsset
                        ( Map.singleton
                            (policyIdFromPin (cfgActivePolicy cfg))
                            (Map.singleton (AssetName (SBS.toShort (ctlKey c))) 1)
                        )
                    )
                )
                & datumTxOutL .~ mkInlineDatum (envelopeToData envelope)
        Coin least = getMinCoinTxOut pp custody
    when (deposit < least) $
        failWith
            ClientRefusal
            ( "the output that will hold key 0x"
                <> T.unpack (hexT (ctlKey c))
                <> " needs at least "
                <> show least
                <> " lovelace to carry its envelope under the ledger's minimum, and the deposit is "
                <> show deposit
                <> "; name a deposit of at least "
                <> show least
                <> " lovelace (client policy)"
            )
    pure
        Booked
            { bookedEdge = edgeInsertActive
            , bookedBuild = \view payer -> do
                (lower, upper) <- registrationWindow cfg view
                bookRegistrationImpl
                    cfg
                    view
                    (savedToken s)
                    (fst (liveState live))
                    RegistrationBooking
                        { rbKey = ctlKey c
                        , rbRefundAddress = payer
                        , rbDestination = address
                        , rbDatum = Just (envelopeToData envelope)
                        , rbDeclaredTip = defaultTip cfg
                        , rbCarrier = Coin deposit
                        , rbNonce = toInteger (unSlotNo upper)
                        , rbLower = lower
                        , rbUpper = upper
                        , rbApplicationScript = applied s
                        , rbApplicationRedeemer =
                            Just
                                ( bookInsertRedeemer
                                    (ctlKey c)
                                    (ctlController c)
                                    address
                                    envelope
                                )
                        , rbRequiredSigners = [ctlController c]
                        }
                    payer
            , bookedOutlay = bookingOutlay
            }

{- | An insertion preview without naming the envelope outside this module
(slice 2 C: `Preview` stays clean; slice 4 moves the entry commands).
-}
previewInsert
    :: Cage.Session Cage.NoWitness IO
    -> Live
    -> Saved
    -> EntryArgs
    -> ByteString
    -> PLC.Data
    -> IO (Booked, Value)
previewInsert v live s a caller payload = do
    let envelope = insertionOf s a caller payload
    booked <- planInsert v live envelope
    pure (booked, envelopeToJson envelope)

-- | The payload an insert carries, from the file its @--payload@ names.
readInsertPayload :: EntryArgs -> IO PLC.Data
readInsertPayload a = do
    path <-
        maybe
            (failWith ClientRefusal "insert needs --payload")
            pure
            (entryDocument a)
    readJson path
        >>= either (failWith ClientRefusal . refused path) pure . readPayload
  where
    refused path (PayloadNotPlutusData why) =
        path <> ": --payload is not Plutus data: " <> why

{- | The envelope an insert books: the saved registry, the insert's key and
deposit, the controller (the payment key hash of whoever signs, or of the
address a preview names) and the payload.
-}
insertionOf
    :: Saved -> EntryArgs -> ByteString -> PLC.Data -> Envelope
insertionOf s a controller =
    insertEnvelope
        (savedCfg s)
        (savedToken s)
        key
        controller
        (fromMaybe minimumDeposit (entryDeposit a))
  where
    Key key = entryKey a

-- | A termination of @key@ by @caller@: its booking, its holding and decoded view.
planTerminate
    :: Live
    -> ByteString
    -> ByteString
    -> [(TxIn, TxOut ConwayEra)]
    -> IO (Booked, (TxIn, TxOut ConwayEra), DecodedHolding)
planTerminate live caller key outs = do
    let s = liveSaved live
    decoded <-
        either
            (failWith ClientRefusal)
            pure
            (liveOutputFor openDatumApplication s key outs)
    let holding = fst decoded
        dh = snd decoded
    (_, envelope) <-
        either (failWith ClientRefusal) pure (toEnvelopeHolding decoded)
    let c = envControl envelope
    controllerCheck caller c
    let cfg = savedCfg s
        Coin held = snd holding ^. coinTxOutL
        Coin tip = defaultTip cfg
    pure
        ( Booked
            { bookedEdge = edgeUpdateTerminal
            , bookedBuild = \view payer -> do
                observed <- Cage.tip view
                bookTerminationImpl
                    cfg
                    view
                    (savedToken s)
                    (fst (liveState live))
                    TerminationBooking
                        { tbKey = key
                        , tbDeclaredTip = Coin tip
                        , tbCarrier = Coin (held - tip)
                        , tbNonce = toInteger (unSlotNo (Cage.observedSlot observed))
                        , tbCustody = holding
                        , tbOrdinaryAdded = Coin 0
                        , tbCustodyAuthority =
                            ScriptGuarded (applied s) (bookTerminationRedeemer 0)
                        , tbRequiredSigners = [ctlController c]
                        }
                    payer
            , bookedOutlay = \pp refs -> terminationOutlay pp refs held
            }
        , holding
        , dh
        )

-- | An update of @key@ by @caller@: the holding and the decoded view it carries.
planUpdate
    :: Live
    -> ByteString
    -> ByteString
    -> [(TxIn, TxOut ConwayEra)]
    -> IO ((TxIn, TxOut ConwayEra), DecodedHolding)
planUpdate live caller key outs = do
    decoded <-
        either
            (failWith ClientRefusal)
            pure
            (liveOutputFor openDatumApplication (liveSaved live) key outs)
    (_, envelope) <-
        either (failWith ClientRefusal) pure (toEnvelopeHolding decoded)
    controllerCheck caller (envControl envelope)
    pure decoded

{- | The unsigned update of a holding to a new payload, funded from the
caller's chosen ada-only output or else the largest.
-}
buildUpdate
    :: Cage.Session Cage.NoWitness IO
    -- ^ The one view the update is built from: its wallet, parameters and evaluation
    -> Live
    -> Addr
    -> Maybe TxIn
    -> (TxIn, TxOut ConwayEra)
    -> PLC.Data
    -> IO ConwayTx
buildUpdate v live addr chosen holding payload = do
    appRef <- appReferenceOf live
    let refOut = [u | u@(i, _) <- liveRefs live, i == appRef]
    wallet <- Cage.outputsAt v addr
    fee <-
        either
            ( \why ->
                failWith ClientRefusal ("the wallet cannot fund the update: " <> why)
            )
            pure
            (selectFunding chosen wallet)
    updatePayloadTx
        UpdateArgs
            { uaSession = v
            , uaApplied = applied (liveSaved live)
            , uaHolding = holding
            , uaPayload = payload
            , uaFee = fee
            , uaChange = addr
            , uaReference = case refOut of
                (u : _) -> Just u
                [] -> Nothing
            }
        >>= either (failWith ClientRefusal) pure

-- Generic planning (readJson, refuseOver, refuseUnderfunded,
-- retainedFaucetStep, resolveFunding, outlayReport) comes from
-- Singular.CLI.Plan, the one module both binaries plan through, and is
-- re-exported here so existing callers keep importing this module.
