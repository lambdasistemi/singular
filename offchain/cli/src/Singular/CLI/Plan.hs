{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.CLI.Plan
Description : What an insert, update or terminate asks of the registry, decided without a wallet key
License     : Apache-2.0

The checks and the choices that turn an attached registry and a caller's
public identity into the transactions a write command builds: the
envelope's identity and deposit, who may act on a key, the application's
published reference, the booking's approval and destination, and the
update's builder arguments. Nothing here signs, submits or journals, so the
submitting commands ("Singular.CLI.Entry") and the read-only preparation
route ("Singular.CLI.Preview") decide from the same code and cannot drift.
-}
module Singular.CLI.Plan
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

      -- * What an update asks
    , planUpdate
    , buildUpdate
    , previewInsert

      -- * What it costs
    , refuseOver
    , outlayReport
    ) where

import Control.Monad (unless)
import Data.Aeson (Value, object, (.=))
import Data.Aeson qualified as Aeson
import Data.ByteString (ByteString)
import Data.Maybe (fromMaybe)
import Data.Text qualified as T
import PlutusCore.Data qualified as PLC

import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.Api.Tx.Out (TxOut)
import Cardano.Ledger.BaseTypes (Network (Testnet))
import Cardano.Ledger.TxIn (TxIn)
import Cardano.Tx.Ledger (ConwayTx)

import Singular.Application.OpenDatum.Book
    ( insertApproval
    , insertDestination
    , terminateApproval
    , terminateDestination
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
    , envelopeToJson
    )
import Singular.Application.OpenDatum.Update
    ( UpdateArgs (..)
    , updatePayloadTx
    )
import Singular.Application.OpenDatum.Value (openDatumApplication)
import Singular.CLI.Command (EntryArgs (..), Key (..))
import Singular.CLI.InsertEnvelope (insertEnvelope)
import Singular.CLI.Live
import Singular.CLI.Outlay
    ( Outlay (..)
    , outlayTotal
    , withinAllowance
    )
import Singular.CLI.Receipt (OutcomeClass (..))
import Singular.CLI.Registry (hexT)
import Singular.CLI.Session (failWith, failWithFields)
import Singular.Registry.Application (DecodedHolding (..))
import Singular.Registry.Evidence qualified as Cage
import Singular.Registry.Ledger (ConwayEra)
import Singular.Registry.LedgerProvider qualified as Cage
import Singular.Registry.SessionIO qualified as Cage
import Singular.Registry.TxBuilder.Edges
    ( BookingApproval (..)
    , edgeDeposit
    , selectFunding
    )
import Singular.Registry.Types
    ( Edge
    , edgeInsertActive
    , edgeUpdateTerminal
    )

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

-- | One booking through the application: what it books and how it is certified.
data Booked = Booked
    { bookedEdge :: Edge
    , bookedDestination :: (ByteString, Maybe PLC.Data)
    -- ^ Where the fold delivers, and the datum the request carries for it
    , bookedDeposit :: Integer
    , bookedApproval :: BookingApproval
    }

-- | An insertion under @envelope@, built by the command from its own sources.
planInsert :: Live -> Envelope -> IO Booked
planInsert live envelope = do
    let s = liveSaved live
        c = envControl envelope
    appRef <- appReferenceOf live
    let stateIn = fst (liveState live)
    pure
        Booked
            { bookedEdge = edgeInsertActive
            , bookedDestination = insertDestination Testnet (applied s) envelope
            , bookedDeposit = ctlDeposit c
            , bookedApproval =
                (insertApproval Testnet (applied s) stateIn envelope)
                    { baScriptReference = Just appRef
                    }
            }

{- | An insertion preview without naming the envelope outside this module
(slice 2 C: `Preview` stays clean; slice 4 moves the entry commands).
-}
previewInsert
    :: Live
    -> Saved
    -> EntryArgs
    -> ByteString
    -> PLC.Data
    -> IO (Booked, Value)
previewInsert live s a caller payload = do
    let envelope = insertionOf s a caller payload
    booked <- planInsert live envelope
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
        (liveIn, _) = holding
    (_, envelope) <-
        either (failWith ClientRefusal) pure (toEnvelopeHolding decoded)
    let c = envControl envelope
    controllerCheck caller c
    appRef <- appReferenceOf live
    let stateIn = fst (liveState live)
    pure
        ( Booked
            { bookedEdge = edgeUpdateTerminal
            , bookedDestination = terminateDestination
            , bookedDeposit = edgeDeposit
            , bookedApproval =
                (terminateApproval (applied s) stateIn liveIn key (ctlController c))
                    { baScriptReference = Just appRef
                    }
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

-- | A JSON document the caller named, or a client refusal saying why not.
readJson :: FilePath -> IO Aeson.Value
readJson path =
    Aeson.eitherDecodeFileStrict' path
        >>= either (failWith ClientRefusal . ((path <> ": ") <>)) pure

{- | Stop before anything is signed, sent or journalled when the measured
outlay passes the approved allowance.
-}
refuseOver :: Maybe Integer -> Outlay -> IO ()
refuseOver allowance outlay =
    unless (withinAllowance allowance outlay) $
        failWithFields
            ClientRefusal
            ( "the measured outlay of "
                <> show (outlayTotal outlay)
                <> " lovelace passes the approved allowance of "
                <> maybe "none" show allowance
            )
            [("outlay", outlayReport allowance outlay)]

-- | The outlay and the allowance it is judged against.
outlayReport :: Maybe Integer -> Outlay -> Value
outlayReport allowance o =
    object
        [ "fee" .= outlayFee o
        , "lockedBond" .= outlayBond o
        , "foldFeeBound" .= outlayFoldBound o
        , "total" .= outlayTotal o
        , "allowance" .= allowance
        , "withinAllowance" .= withinAllowance allowance o
        ]
