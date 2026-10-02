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
    , planInsert
    , planTerminate

      -- * What an update asks
    , planUpdate
    , buildUpdate

      -- * What it costs
    , refuseOver
    , outlayReport
    ) where

import Control.Monad (unless, when)
import Data.Aeson (Value, object, (.=))
import Data.Aeson qualified as Aeson
import Data.ByteString (ByteString)
import Data.ByteString.Short qualified as SBS
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
import Singular.Application.OpenDatum.Envelope
    ( Control (..)
    , Envelope (..)
    , envelopeVersion
    , registryBytes
    )
import Singular.Application.OpenDatum.Update
    ( UpdateArgs (..)
    , updatePayloadTx
    )
import Singular.CLI.Live
import Singular.CLI.Outlay
    ( Outlay (..)
    , outlayTotal
    , withinAllowance
    )
import Singular.CLI.Receipt (OutcomeClass (..))
import Singular.CLI.Registry (hexT)
import Singular.CLI.Session (failWith, failWithFields)
import Singular.Registry.Config (CageConfig (..))
import Singular.Registry.Ledger
    ( AssetName (..)
    , ConwayEra
    , TokenId (..)
    )
import Singular.Registry.Provider qualified as Cage
import Singular.Registry.TxBuilder.Edges
    ( BookingApproval (..)
    , edgeDeposit
    , selectFunding
    )
import Singular.Registry.TxBuilder.Internal (scriptHashBytes)
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
        (applicationReference live)

-- | One booking through the application: what it books and how it is certified.
data Booked = Booked
    { bookedEdge :: Edge
    , bookedDestination :: (ByteString, ByteString)
    , bookedDeposit :: Integer
    , bookedApproval :: BookingApproval
    }

-- | An insertion of @key@ under @envelope@, by @caller@.
planInsert
    :: Live -> ByteString -> ByteString -> Envelope -> IO Booked
planInsert live caller key envelope = do
    let s = liveSaved live
        cfg = savedCfg s
        c = envControl envelope
        TokenId (AssetName n) = savedToken s
        identity = scriptHashBytes (cfgScriptHash cfg) <> SBS.fromShort n
        refuseIf bad why = when bad (failWith ClientRefusal why)
    refuseIf
        (ctlVersion c /= envelopeVersion)
        "the envelope's version is not 1"
    refuseIf
        (registryBytes (ctlRegistry c) /= identity)
        "the envelope names another registry's state asset"
    refuseIf
        (ctlActivePolicy c /= SBS.fromShort (cfgActivePolicy cfg))
        "the envelope names another active policy"
    refuseIf (ctlKey c /= key) "the envelope names another key than --key"
    refuseIf
        (ctlDeposit c <= 0)
        "the envelope's protected deposit is not positive"
    controllerCheck caller c
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

-- | A termination of @key@ by @caller@: its booking, its holding and envelope.
planTerminate
    :: Live
    -> ByteString
    -> ByteString
    -> [(TxIn, TxOut ConwayEra)]
    -> IO (Booked, (TxIn, TxOut ConwayEra), Envelope)
planTerminate live caller key outs = do
    let s = liveSaved live
    (holding@(liveIn, _), envelope) <-
        either (failWith ClientRefusal) pure (liveOutputFor s key outs)
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
        , envelope
        )

-- | An update of @key@ by @caller@: the holding and the envelope it carries.
planUpdate
    :: Live
    -> ByteString
    -> ByteString
    -> [(TxIn, TxOut ConwayEra)]
    -> IO ((TxIn, TxOut ConwayEra), Envelope)
planUpdate live caller key outs = do
    (holding, envelope) <-
        either
            (failWith ClientRefusal)
            pure
            (liveOutputFor (liveSaved live) key outs)
    controllerCheck caller (envControl envelope)
    pure (holding, envelope)

{- | The unsigned update of a holding to a new payload, funded from the
caller's chosen ada-only output or else the largest.
-}
buildUpdate
    :: Cage.View IO
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
    wallet <- Cage.viewUTxOsAt v addr
    fee <-
        either
            ( \why ->
                failWith ClientRefusal ("the wallet cannot fund the update: " <> why)
            )
            pure
            (selectFunding chosen wallet)
    updatePayloadTx
        UpdateArgs
            { uaView = v
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
