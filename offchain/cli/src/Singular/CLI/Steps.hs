{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.CLI.Steps
Description : What the commands of the state line share: the journalled write, one transaction and its readback
License     : Apache-2.0

A command of the state line builds its transactions with the library's
builders, signs and sends them through the journalled submission every write of
the program uses, and reads back what the transaction made. This module is that
common part.

A write first reconciles the journal of its directory with the chain, so that a
transaction an earlier command left unresolved is observed once when the chain
holds it and stops the write when it does not: nothing is built or sent while
an earlier transaction is unresolved, and nothing is ever sent twice.
-}
module Singular.CLI.Steps
    ( -- * A write
      stateWrite
    , creationToken

      -- * A transaction
    , sendStep
    , observeOutput
    , refusing

      -- * Reading what a command is given
    , loadReleaseBlueprint
    , renderRefusal
    , scriptSource
    ) where

import Data.Aeson (Value)
import Data.ByteString (ByteString)
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Char8 qualified as BC
import Data.Text (Text)
import Data.Text qualified as T
import Data.Word (Word16)

import Cardano.Ledger.Api.Tx (txIdTx)
import Cardano.Ledger.BaseTypes (TxIx (..))
import Cardano.Ledger.Core (Script, hashScript)
import Cardano.Ledger.Hashes (ScriptHash)
import Cardano.Ledger.Mary.Value (AssetName (..), PolicyID (..))
import Cardano.Ledger.TxIn (TxIn (..))
import Cardano.Tx.Ledger (ConwayTx)

import Singular.CLI.Command (WriteSettings (..))
import Singular.CLI.ManagedState (resolveSignerDir)
import Singular.CLI.Promise
    ( Promise
    , describePromise
    , promiseKept
    , renderPromise
    )
import Singular.CLI.Receipt (OutcomeClass (..))
import Singular.CLI.Reconcile
    ( reconcileIncomplete
    , reconciledJson
    , refuseUnreconciled
    )
import Singular.CLI.Session
    ( ConfirmedSubmission
    , Env
    , Expectation
    , WriteContext (..)
    , confirmedTx
    , expecting
    , failWith
    , journalObserved
    , readStep
    , submitBuiltIn
    , withWrite
    )
import Singular.Registry.Blueprint (Blueprint, loadBlueprint)
import Singular.Registry.Deployment (renderOutRef)
import Singular.Registry.Evidence (NoWitness)
import Singular.Registry.Ledger (ConwayEra, TxOut)
import Singular.Registry.LedgerProvider
    ( Asset
    , OutputQuery (..)
    , Session
    )
import Singular.Registry.ProviderSettings (ProviderSettings (..))
import Singular.State.Assemble (readOutputs)
import Singular.State.Refusal (Refusal (..))
import Singular.State.Script (ScriptSource (..))

{- | Run the body of a write of the state line. The journal of the registry
named (or of the creations of an application, for a creation) is reconciled
with the chain before anything is built; an earlier transaction that is still
unresolved refuses the write, naming it. The body receives what the
reconciliation did, as the receipt names it.
-}
stateWrite
    :: Env
    -> Maybe FilePath
    -- ^ @--state-dir@
    -> Asset
    -- ^ The token whose directory holds the journal
    -> Text
    -- ^ The command
    -> WriteSettings
    -- ^ Already opened
    -> (WriteContext -> Value -> IO Value)
    -> IO Value
stateWrite env stateDir token command ws body = do
    dir <-
        resolveSignerDir
            stateDir
            (providerMagic (writeProvider ws))
            token
            (writeSigner ws)
    withWrite env dir command ws $ \wc -> do
        reconciled <-
            readStep
                (wcTracer wc)
                (wcSource wc)
                ["journal transactions"]
                (wcCapabilities wc)
                (reconcileIncomplete (wcCommand wc) (wcDir wc))
        refuseUnreconciled reconciled
        body wc (reconciledJson reconciled)

{- | The token the creations of the registries of an application keep their
journal under: the application's state policy and no asset, because the name of
the registry a creation makes is known only once its seed is chosen.
-}
creationToken :: ScriptHash -> Asset
creationToken hash = (PolicyID hash, AssetName mempty)

{- | Build one transaction and send it, journalled: the step names it in the
journal, the promise is what its first output must hold once it is on the
chain, and the builder gives the transaction and whatever else the step wants
to keep.
-}
sendStep
    :: WriteContext
    -> Text
    -> [Text]
    -> (r -> Promise)
    -> (Session NoWitness IO -> IO (ConwayTx, r))
    -> IO (ConfirmedSubmission, r)
sendStep wc step items promised build =
    submitBuiltIn wc step items (expectation . promised) (const build)
  where
    expectation :: Promise -> Expectation
    expectation = expecting . renderPromise

{- | Read back an output the confirmed transaction made and check that it
keeps its promise. It is journalled observed when it does; when it does not
the command stops partial, the transaction kept in the journal and never sent
again.
-}
observeOutput
    :: WriteContext
    -> Text
    -> ConfirmedSubmission
    -> Word16
    -- ^ The index of the output
    -> Promise
    -> IO (TxIn, TxOut ConwayEra)
observeOutput wc step confirmed index promise = do
    let ref = TxIn (txIdTx (confirmedTx confirmed)) (TxIx index)
    found <-
        readStep
            (wcTracer wc)
            (wcSource wc)
            [step <> " output"]
            (wcCapabilities wc)
            (\view -> readOutputs view (AtTxIn ref))
    case found of
        Right [(_, out)] | promiseKept promise out -> do
            journalObserved wc step confirmed (describePromise promise)
            pure (ref, out)
        _ ->
            failWith
                Partial
                ( T.unpack step
                    <> " confirmed but its output "
                    <> show index
                    <> " is not live as built; it is kept in the journal and never sent again"
                )

-- | Stop a command with a builder's refusal as a refusal of the client.
refusing :: Either Refusal a -> IO a
refusing = either (failWith ClientRefusal . renderRefusal) pure

{- | The compiled validators of the release the command was given, or the
refusal that says why they cannot be read.
-}
loadReleaseBlueprint :: FilePath -> IO Blueprint
loadReleaseBlueprint path =
    loadBlueprint path
        >>= either
            ( \why ->
                failWith
                    ClientRefusal
                    ("the blueprint " <> path <> " cannot be loaded: " <> why)
            )
            pure

-- | Where a script is taken from, given the reference outputs found for it.
scriptSource
    :: Script ConwayEra -> [(ScriptHash, TxIn)] -> ScriptSource
scriptSource script references =
    maybe Attached Referenced (lookup (hashScript script) references)

-- | A builder's refusal, in a sentence.
renderRefusal :: Refusal -> String
renderRefusal = \case
    PayerHasNoFunding ->
        "the wallet holds no ada-only output to pay the fee and secure the transaction"
    PayerIsNotAKey ->
        "the wallet's address is not a key's: a script cannot sign"
    SeedNotAtPayer seed ->
        "the seed "
            <> showRef seed
            <> " is not an unspent output of this wallet"
    ReferenceScriptMissing ref ->
        "the reference output " <> showRef ref <> " is not on the chain"
    ReferenceScriptMismatch ref carried expected ->
        "the reference output "
            <> showRef ref
            <> " carries "
            <> maybe "no script" (("the script " <>) . showHash) carried
            <> ", not "
            <> showHash expected
    NoRegistryState _ ->
        "no output holds the state token of this registry"
    AmbiguousRegistryState n ->
        show n <> " outputs hold the state token of this registry"
    NotARegistryState ref ->
        "the output " <> showRef ref <> " is not the state of this registry"
    TrieRefused failure ->
        "the public history of the registry cannot be replayed into its trie: "
            <> show failure
    NothingToFold -> "there is nothing to fold"
    DuplicateRequest ref ->
        "the pending registration " <> showRef ref <> " is named twice"
    DuplicateKey key ->
        "two pending registrations name the key " <> showHex' key
    KeyAlreadyRegistered key ->
        "the key " <> showHex' key <> " is already registered"
    PendingNotFound ref ->
        "the pending registration " <> showRef ref <> " is not on the chain"
    NotAPendingRegistration ref ->
        "the output "
            <> showRef ref
            <> " is not a pending registration of this application with its approval"
    PendingOfAnotherRegistry ref ->
        "the pending registration "
            <> showRef ref
            <> " belongs to another registry"
    DepositBelowHolding ref deposit smallest ->
        "the deposit of "
            <> showRef ref
            <> " ("
            <> show deposit
            <> ") is below the minimum ada of the holding it commits ("
            <> show smallest
            <> "), so no fold could deliver it"
    ProcessingWindowClosed ->
        "no validity interval at the tip ends before every processing deadline: the window to fold has closed"
    BuildFailed message -> T.unpack message
  where
    showRef = T.unpack . renderOutRef
    showHash = show
    showHex' :: ByteString -> String
    showHex' = BC.unpack . B16.encode
