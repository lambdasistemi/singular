{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.Application.OpenDatum.Registration
Description : The commands that book a registration of a key and take it back or clean it up, and the application open datum hands the state commands
License     : Apache-2.0

The five commands of open datum on the proved design are written against the
library's builders and the request builders of this package, not against the
open-datum envelope. @create@ and @fold@ are the library's commands
hosted with open datum's request validator; this module hands them that host
('openDatumHost'). @insert@, @reclaim@ and @cleanup@ are open datum's
own: each builds its transaction, signs and sends it through the journalled
submission every write of the program uses, and reads back the output the
transaction made.
-}
module Singular.Application.OpenDatum.Registration
    ( openDatumHost
    , runBook
    , runReclaim
    , runHoldingUpdate
    , runHoldingTerminate
    , runCleanup
    , ruledOutKey
    ) where

import Control.Exception
    ( SomeAsyncException
    , SomeException
    , fromException
    , throwIO
    , try
    )
import Control.Monad (unless)
import Data.Aeson (Value, object, toJSON, (.=))
import Data.ByteString (ByteString)
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Short qualified as SBS
import Data.Foldable (toList)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.Encoding.Error (lenientDecode)
import Data.Word (Word32)
import Lens.Micro ((^.))
import PlutusCore.Data qualified as PLC

import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.Api.Tx (bodyTxL)
import Cardano.Ledger.Api.Tx.Body (mintTxBodyL, outputsTxBodyL)
import Cardano.Ledger.Api.Tx.Out (addrTxOutL, coinTxOutL)
import Cardano.Ledger.BaseTypes (Network (Testnet))
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Core (Script, hashScript)
import Cardano.Ledger.Mary.Value
    ( AssetName (..)
    , MultiAsset (..)
    , PolicyID (..)
    )
import Cardano.Ledger.TxIn (TxIn)
import Cardano.Tx.Ledger (ConwayTx)

import Cardano.Ledger.Conway.TxBody (treasuryDonationTxBodyL)
import Singular.Application.OpenDatum.Command
    ( BookArgs (..)
    , HoldingArgs (..)
    , Key (..)
    , PendingArgs (..)
    , RegistryAccess (..)
    , WriteSettings (..)
    )
import Singular.Application.OpenDatum.Reader
    ( ReaderAnswer (..)
    , readKey
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
import Singular.Application.OpenDatum.Requests.Holding
    ( buildBookTermination
    , buildUpdate
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
import Singular.CLI.Promise (Promise (..), matchesOutput, paidTo)
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
    , refuseUnserved
    , refusing
    , scriptSource
    , sendStep
    , stateWrite
    )
import Singular.Reader qualified as R
import Singular.Registry.Blueprint (Blueprint)
import Singular.Registry.ContractTable (loadContractTable)
import Singular.Registry.Evidence (NoWitness)
import Singular.Registry.Ledger (ConwayEra, TxOut)
import Singular.Registry.LedgerProvider
    ( Asset
    , OutputQuery (..)
    , ReadFailure (..)
    , Session
    )
import Singular.Registry.LedgerProvider qualified as LP
import Singular.Registry.PlainJson (PayloadSchema)
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
import Singular.State.Script
    ( ScriptSource (..)
    , stateScriptFromBlueprint
    )

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

{- | Stop a registry the installed release does not serve before the provider is
opened: the state validator of this release is the one the blueprint has for
this release's request validator, and the table of releases says which release
serves the registry otherwise.
-}
refuseUnservedRegistry
    :: Blueprint -> Script ConwayEra -> Asset -> IO ()
refuseUnservedRegistry blueprint script token = do
    state <-
        either
            (failWith ClientRefusal . ("the state validator: " <>))
            pure
            (stateScriptFromBlueprint blueprint (PolicyID (hashScript script)))
    refuseUnserved (PolicyID (hashScript state)) token

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
    refuseUnservedRegistry blueprint script token
    stateWrite env (bookArgsStateDir a) token "insert" ws $ \wc reconciled -> do
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
                [ "registry state of the key"
                , "wallet outputs"
                , "configuration record"
                , "reference scripts"
                ]
                (HoldsToken policy)
                $ \view -> do
                    refuseRuledOutKey view magic registry key
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
        pure . receipt "insert" Success $
            registryFields magic token
                <> [ ("stateToken", toJSON (renderStateToken token))
                   , ("pending", toJSON (txInText pending))
                   , ("approval", toJSON (renderStateToken (policy, approval)))
                   , ("key", toJSON (hexOf key))
                   , ("keyText", toJSON (keyText key))
                   , ("deposit", toJSON (rdDeposit registration))
                   , ("tip", toJSON (bookArgsTip a))
                   , ("refundAddress", toJSON (addressText (rdRefundAddress registration)))
                   , ("bookedAt", toJSON (rdBookedAt registration))
                   , ("processDeadline", toJSON (rdProcessDeadline registration))
                   , ("reclaimEnd", toJSON (rdReclaimEnd registration))
                   , ("reconciled", reconciled)
                   ]

-- | A key as the receipt and the refusals name it.
keyText :: ByteString -> Text
keyText = TE.decodeUtf8With lenientDecode

{- | The refusal the registry state calls for when a key is booked, if any. The
state rules out an active key (also one with a termination booked) and a
terminated key; a key never registered, a state the provider could not answer
and a state policy the reader does not recognise leave the booking to the fold.
-}
ruledOutKey :: ByteString -> ReaderAnswer -> Maybe Refusal
ruledOutKey key = \case
    Live{} -> Just (KeyAlreadyRegistered (keyText key))
    PendingTermination{} -> Just (KeyAlreadyRegistered (keyText key))
    Terminal{} -> Just (KeyWasTerminated (keyText key))
    NeverRegistered{} -> Nothing
    Unavailable{} -> Nothing
    Refused{} -> Nothing

{- | Refuse, before the booking is built, a key the registry state already
rules out. The refusal is the client's own policy and a courtesy: the model
admits the insert only from an unknown leaf, but the booking is the
application's to admit and the fold stays the authority. The key is read at the
tip the booking is built at, through the reader that @inspect --key@ uses; a
key the reader cannot place is booked as before.
-}
refuseRuledOutKey
    :: Session NoWitness IO
    -> Word32
    -> RegistryIdentity
    -> ByteString
    -> IO ()
refuseRuledOutKey view magic registry key = do
    answered <-
        try @SomeException $
            loadContractTable >>= \case
                Left _ -> pure Nothing
                Right table ->
                    Just
                        <$> readKey view table (R.ReaderRequest (LP.Network magic) registry key)
    case answered of
        Right (Just answer) ->
            maybe
                (pure ())
                (failWith ClientRefusal . renderRefusal)
                (ruledOutKey key answer)
        Right Nothing -> pure ()
        Left failure
            | Just (_ :: SomeAsyncException) <- fromException failure ->
                throwIO failure
            | otherwise -> pure ()

-- ---------------------------------------------------------
-- reclaim and cleanup
-- ---------------------------------------------------------

-- | Take a pending registration back inside its reclaim window.
runReclaim :: Env -> PendingArgs -> IO Value
runReclaim = runPending "reclaim" "reclaim" buildReclaim

-- | Clean up a pending registration after its reclaim window.
runCleanup :: Env -> PendingArgs -> IO Value
runCleanup = runPending "cleanup" "cleanup" buildCleanup

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
    refuseUnservedRegistry blueprint script token
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

-- | Replace only the payload of the chosen live holding.
runHoldingUpdate
    :: Env -> HoldingArgs -> FilePath -> PayloadSchema -> IO Value
runHoldingUpdate env a path schema = do
    payload <- readPayloadFile schema path
    runHolding
        "update"
        "update"
        "holding"
        (\view script ref payer -> buildUpdate view script ref payload payer)
        env
        a

-- | Book permanent termination and donate the protected deposit.
runHoldingTerminate :: Env -> HoldingArgs -> IO Value
runHoldingTerminate =
    runHolding
        "terminate"
        "terminate"
        "pending"
        buildBookTermination

runHolding
    :: Text
    -> Text
    -> Text
    -> ( Session NoWitness IO
         -> RequestScript
         -> TxIn
         -> Addr
         -> IO (Either Refusal ConwayTx)
       )
    -> Env
    -> HoldingArgs
    -> IO Value
runHolding command step outputField build env a = do
    blueprint <- loadReleaseBlueprint (holdingArgsBlueprint a)
    script <- requestScriptIn blueprint
    let ws = holdingArgsWrite a
        token@(PolicyID policy, AssetName name) = accessToken (holdingArgsAccess a)
        magic = providerMagic (writeProvider ws)
        reference = holdingArgsHolding a
    refuseUnservedRegistry blueprint script token
    stateWrite env (holdingArgsStateDir a) token command ws $ \wc reconciled -> do
        let payer = wcCaller wc
        (confirmed, (expected, donated)) <- sendStep
            wc
            step
            ["wallet outputs", "live holding", "reference scripts"]
            (matchesOutput . fst)
            $ \view -> do
                readOutputs view (AtTxIn reference) >>= \case
                    Right [(_, out)] -> case inlineDatumOf out of
                        Just (PLC.Constr 2 [PLC.Constr 0 (registry : _), _]) ->
                            unless
                                ( registry
                                    == PLC.Constr
                                        0
                                        [PLC.B (scriptHashBytes policy), PLC.B (SBS.fromShort name)]
                                )
                                $ failWith ClientRefusal "the holding belongs to another registry"
                        _ -> pure ()
                    Left (MissingOutput _) -> pure ()
                    Left failure -> throwIO failure
                    Right _ -> pure ()
                source <- sourceOf view payer script
                tx <-
                    build view (RequestScript script source) reference payer >>= requested
                case toList (tx ^. bodyTxL . outputsTxBodyL) of
                    first : _ -> pure (tx, (first, tx ^. bodyTxL . treasuryDonationTxBodyL))
                    [] -> failWith ClientRefusal "the holding transaction creates no output"
        (output, _) <-
            observeOutput wc step confirmed 0 (matchesOutput expected)
        let Coin donation = donated
        pure . receipt command Success $
            registryFields magic token
                <> [ ("stateToken", toJSON (renderStateToken token))
                   , (outputField, toJSON (txInText output))
                   , ("treasuryDonation", toJSON donation)
                   , ("reconciled", reconciled)
                   ]

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
        "the output "
            <> T.unpack (txInText ref)
            <> " is not a live holding of this application"
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
    KeyAlreadyRegistered key ->
        "the key " <> T.unpack key <> " is already registered"
    KeyWasTerminated key ->
        "the key "
            <> T.unpack key
            <> " is already registered and was terminated"
    BuildFailed message -> T.unpack message
