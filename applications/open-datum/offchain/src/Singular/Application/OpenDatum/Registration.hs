{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.Application.OpenDatum.Registration
Description : The commands that book a registration of a key and take it back or clean it up, and the application open datum hands the state commands
License     : Apache-2.0

The five commands of open datum on the proved design are written against the
library's builders and the request builders of this package, not against the
open-datum envelope. @state create@ and @state fold@ are the library's commands
hosted with open datum's request validator; this module hands them that host
('openDatumHost'). @registration book@, @reclaim@ and @cleanup@ are open datum's
own: each builds its transaction, signs and sends it through the journalled
submission every write of the program uses, and reads back the output the
transaction made.
-}
module Singular.Application.OpenDatum.Registration
    ( openDatumHost
    , runBook
    , runReclaim
    , runCleanup
    ) where

import Data.Aeson (Value, object, toJSON, (.=))
import Data.ByteString (ByteString)
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Char8 qualified as BC
import Data.Foldable (toList)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.Encoding.Error (lenientDecode)
import Lens.Micro ((^.))

import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.Api.Tx (bodyTxL)
import Cardano.Ledger.Api.Tx.Body (mintTxBodyL, outputsTxBodyL)
import Cardano.Ledger.Api.Tx.Out (addrTxOutL, coinTxOutL)
import Cardano.Ledger.BaseTypes (Network (Testnet))
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Core (Script, hashScript)
import Cardano.Ledger.Mary.Value
    ( AssetName
    , MultiAsset (..)
    , PolicyID (..)
    )
import Cardano.Ledger.TxIn (TxIn)
import Cardano.Tx.Ledger (ConwayTx)

import Singular.Application.OpenDatum.Command
    ( BookArgs (..)
    , Key (..)
    , PendingArgs (..)
    , RegistryAccess (..)
    , WriteSettings (..)
    )
import Singular.Application.OpenDatum.Requests.Booking
    ( Booking (..)
    , buildBookRegistration
    )
import Singular.Application.OpenDatum.Requests.Configuration
    ( configurationCreate
    )
import Singular.Application.OpenDatum.Requests.Fold
    ( openDatumApplication
    )
import Singular.Application.OpenDatum.Requests.Pending
    ( buildCleanup
    , buildReclaim
    )
import Singular.Application.OpenDatum.Requests.Records
    ( RegistrationData (..)
    , RequestParameters
    , decodeRegistration
    )
import Singular.Application.OpenDatum.Requests.Refusal
    ( Operation (..)
    , Refusal (..)
    )
import Singular.Application.OpenDatum.Requests.Script
    ( RequestScript (..)
    , requestPolicy
    , requestScriptFromBlueprint
    )
import Singular.CLI.FlagGroup (anyAddress)
import Singular.CLI.Live (receipt, txInText)
import Singular.CLI.Payload (readPayloadFile)
import Singular.CLI.Promise (Promise (..), paidTo)
import Singular.CLI.Receipt (OutcomeClass (..))
import Singular.CLI.Registry (registryFields)
import Singular.CLI.Session
    ( Env
    , WriteContext (..)
    , failWith
    )
import Singular.CLI.State (Host (..))
import Singular.CLI.Steps
    ( loadReleaseBlueprint
    , observeOutput
    , refusing
    , scriptSource
    , sendStep
    , stateWrite
    )
import Singular.Registry.Blueprint (Blueprint)
import Singular.Registry.Evidence (NoWitness)
import Singular.Registry.Ledger (ConwayEra, TxOut)
import Singular.Registry.LedgerProvider (OutputQuery (..), Session)
import Singular.Registry.ProviderSettings (ProviderSettings (..))
import Singular.Registry.StateToken (renderStateToken)
import Singular.Registry.TrieState
    ( RegistryIdentity (..)
    , StatePolicyId (..)
    )
import Singular.Registry.TxBuilder.Internal (scriptHashBytes)
import Singular.Registry.Wallet (bech32Address)
import Singular.State.Assemble (inlineDatumOf, readOutputs)
import Singular.State.Publication (References (..), planReferences)
import Singular.State.Script (ScriptSource (..))

-- | The application open datum hands the state commands.
openDatumHost :: RequestParameters -> Host
openDatumHost parameters =
    Host
        { hostScripts = \blueprint _ -> do
            script <- requestScriptFromBlueprint blueprint
            pure (requestPolicy (RequestScript script Attached), [script])
        , hostCreation = \owned seed registry -> case owned of
            [(script, source)] ->
                configurationCreate
                    (RequestScript script source)
                    Testnet
                    registry
                    seed
                    parameters
            _ -> pure ()
        , hostFold = \view network owned -> case owned of
            [(script, source)] ->
                either (Left . renderRefusal) Right
                    <$> openDatumApplication view (RequestScript script source) network
            _ -> pure (Left "open datum owns exactly one validator")
        }

-- ---------------------------------------------------------
-- book
-- ---------------------------------------------------------

-- | Book the registration of a key.
runBook :: Env -> BookArgs -> IO Value
runBook env a = do
    blueprint <- loadReleaseBlueprint (bookArgsBlueprint a)
    script <- requestScriptIn blueprint
    payload <-
        readPayloadFile (bookArgsPayloadSchema a) (bookArgsPayload a)
    let ws = bookArgsWrite a
        magic = providerMagic (writeProvider ws)
        token@(PolicyID statePolicy, name) = accessToken (bookArgsAccess a)
        registry = RegistryIdentity (StatePolicyId (scriptHashBytes statePolicy)) name
        key = unKey (bookArgsKey a)
        policy = PolicyID (hashScript script)
    stateWrite env (bookArgsStateDir a) token "registration book" ws $ \wc reconciled -> do
        let payer = wcCaller wc
        refund <-
            maybe
                (pure payer)
                (either (failWith ClientRefusal) pure . anyAddress . T.pack)
                (bookArgsRefund a)
        (confirmed, approval) <-
            sendStep
                wc
                "book"
                ["wallet outputs", "configuration record", "reference scripts"]
                (HoldsToken policy)
                $ \view -> do
                    source <- sourceOf view payer script
                    tx <-
                        buildBookRegistration
                            view
                            (RequestScript script source)
                            Booking
                                { bookRegistry = registry
                                , bookKey = key
                                , bookPayload = payload
                                , bookDeposit = Coin (bookArgsDeposit a)
                                , bookTip = Coin (bookArgsTip a)
                                , bookRefund = refund
                                }
                            payer
                            >>= requested
                    approval <- mintedUnder policy tx
                    pure (tx, approval)
        (pending, out) <-
            observeOutput wc "book" confirmed 0 (HoldsToken policy approval)
        registration <-
            maybe
                ( failWith
                    Partial
                    "the booking confirmed but its pending registration cannot be read back"
                )
                pure
                (inlineDatumOf out >>= decodeRegistration Testnet)
        pure . receipt "registration book" Success $
            registryFields magic token
                <> [ ("stateToken", toJSON (renderStateToken token))
                   , ("pending", toJSON (txInText pending))
                   , ("approval", toJSON (renderStateToken (policy, approval)))
                   , ("key", toJSON (hexOf key))
                   , ("keyText", toJSON (TE.decodeUtf8With lenientDecode key))
                   , ("deposit", toJSON (rdDeposit registration))
                   , ("tip", toJSON (bookArgsTip a))
                   , ("refundAddress", toJSON (addressText (rdRefundAddress registration)))
                   , ("bookedAt", toJSON (rdBookedAt registration))
                   , ("processDeadline", toJSON (rdProcessDeadline registration))
                   , ("reclaimEnd", toJSON (rdReclaimEnd registration))
                   , ("reconciled", reconciled)
                   ]

-- ---------------------------------------------------------
-- reclaim and cleanup
-- ---------------------------------------------------------

-- | Take a pending registration back inside its reclaim window.
runReclaim :: Env -> PendingArgs -> IO Value
runReclaim = runPending "registration reclaim" "reclaim" buildReclaim

-- | Clean up a pending registration after its reclaim window.
runCleanup :: Env -> PendingArgs -> IO Value
runCleanup = runPending "registration cleanup" "cleanup" buildCleanup

runPending
    :: Text
    -> Text
    -> ( Session NoWitness IO
         -> RequestScript
         -> TxIn
         -> Addr
         -> IO (Either Refusal ConwayTx)
       )
    -> Env
    -> PendingArgs
    -> IO Value
runPending command step build env a = do
    blueprint <- loadReleaseBlueprint (pendingArgsBlueprint a)
    script <- requestScriptIn blueprint
    let ws = pendingArgsWrite a
        magic = providerMagic (writeProvider ws)
        token = accessToken (pendingArgsAccess a)
        pending = pendingArgsPending a
    stateWrite env (pendingArgsStateDir a) token command ws $ \wc reconciled -> do
        let payer = wcCaller wc
        (confirmed, (refund, locked)) <-
            sendStep
                wc
                step
                ["wallet outputs", "pending registration", "reference scripts"]
                (paidTo . fst)
                $ \view -> do
                    source <- sourceOf view payer script
                    held <- readOutputs view (AtTxIn pending)
                    tx <-
                        build view (RequestScript script source) pending payer
                            >>= requested
                    refund <- case toList (tx ^. bodyTxL . outputsTxBodyL) of
                        first : _ -> pure (first ^. addrTxOutL)
                        [] -> failWith ClientRefusal "the transaction pays nobody"
                    pure
                        ( tx
                        ,
                            ( refund
                            , case held of Right [(_, out)] -> Just (coinOf out); _ -> Nothing
                            )
                        )
        (output, out) <- observeOutput wc step confirmed 0 (paidTo refund)
        pure . receipt command Success $
            registryFields magic token
                <> [ ("stateToken", toJSON (renderStateToken token))
                   , ("pending", toJSON (txInText pending))
                   ,
                       ( "returned"
                       , object
                            [ "recipient" .= addressText refund
                            , "output" .= txInText output
                            , "lovelace" .= coinOf out
                            ]
                       )
                   , ("locked", toJSON locked)
                   , ("reconciled", reconciled)
                   ]
  where
    coinOf :: TxOut ConwayEra -> Integer
    coinOf out = let Coin c = out ^. coinTxOutL in c

-- ---------------------------------------------------------
-- shared
-- ---------------------------------------------------------

requestScriptIn :: Blueprint -> IO (Script ConwayEra)
requestScriptIn blueprint =
    either
        (failWith ClientRefusal . ("the request validator: " <>))
        pure
        (requestScriptFromBlueprint blueprint)

{- | Where the request validator is taken from: a live reference copy of it
when the chain holds one, else the transaction carries it.
-}
sourceOf
    :: Session NoWitness IO -> Addr -> Script ConwayEra -> IO ScriptSource
sourceOf view payer script = do
    references <- planReferences view payer [script] >>= refusing
    pure
        ( scriptSource
            script
            [(hash, ref) | (hash, (ref, _)) <- referencesLive references]
        )

requested :: Either Refusal a -> IO a
requested = either (failWith ClientRefusal . renderRefusal) pure

-- | The one token a transaction mints under a policy.
mintedUnder :: PolicyID -> ConwayTx -> IO AssetName
mintedUnder policy tx =
    case Map.lookup
        policy
        (let MultiAsset m = tx ^. bodyTxL . mintTxBodyL in m) of
        Just names | [(name, 1)] <- Map.toList names -> pure name
        _ -> failWith ClientRefusal "the booking mints no single approval"

hexOf :: ByteString -> Text
hexOf = T.pack . BC.unpack . B16.encode

addressText :: Addr -> Text
addressText = T.pack . bech32Address

-- | A request builder's refusal, in a sentence.
renderRefusal :: Refusal -> String
renderRefusal = \case
    NoConfiguration ->
        "the registry has no configuration record at the request address"
    AmbiguousConfiguration n ->
        "the registry has "
            <> show n
            <> " configuration records, so the one a booking reads is not decided"
    PayerHasNoFunding ->
        "the wallet holds no ada-only output to pay the fee and secure the transaction"
    PayerIsNotAKey -> "the wallet's address is not a key's: a script cannot sign"
    BookingWidthTooNarrow width ->
        "the registry's booking width ("
            <> show width
            <> " ms) holds no usable validity interval at the tip"
    DepositBelowHolding deposit smallest ->
        "the deposit ("
            <> show deposit
            <> ") is below the minimum ada of the holding it commits ("
            <> show smallest
            <> "), so no fold could deliver it"
    HoldingNotFound ref ->
        "the holding " <> T.unpack (txInText ref) <> " is not on the chain"
    NotALiveHolding ref ->
        "the output " <> T.unpack (txInText ref) <> " is not a live holding of this application"
    PayerIsNotController ->
        "only the holding's controller can update it or book its termination"
    PendingNotFound ref ->
        "the pending registration "
            <> T.unpack (txInText ref)
            <> " is not on the chain"
    NotAPendingRegistration ref ->
        "the output "
            <> T.unpack (txInText ref)
            <> " is not a pending registration of this request validator"
    RefundAddressIsScript ->
        "the refund address is a script's and cannot sign a reclaim"
    PayerIsNotRefundAddress ->
        "only the refund address reclaims: run the command with the wallet of the refund address"
    WindowNotOpen Reclaim ->
        "the reclaim window has not opened: the chain has not reached the registration's processing deadline"
    WindowNotOpen Cleanup ->
        "the cleanup window has not opened: the chain has not reached the end of the registration's reclaim window"
    WindowClosed Reclaim ->
        "the reclaim window has closed: the registration can be cleaned up instead"
    WindowClosed Cleanup ->
        "the cleanup window is closed"
    ReferenceScriptMissing ref ->
        "the reference output "
            <> T.unpack (txInText ref)
            <> " is not on the chain"
    ReferenceScriptMismatch ref carried expected ->
        "the reference output "
            <> T.unpack (txInText ref)
            <> " carries "
            <> maybe "no script" (("the script " <>) . show) carried
            <> ", not "
            <> show expected
    BuildFailed message -> T.unpack message
