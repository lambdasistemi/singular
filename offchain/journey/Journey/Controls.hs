{- |
Module      : Journey.Controls
Description : The registry negative cases the validators must refuse
License     : Apache-2.0

The journey's deliberate refusals (issue #41). With a second insert
request pending, 'stepReject' builds the valid update the oracle would
submit, derives three single-defect transactions from it
("Journey.Malformations"), and requires each to be refused by the named
validator in phase 2 — a phase-1 rejection, or a refusal by any other
script, fails the run naming what came back ('expectRejected'). Its
positive control follows: the authenticated state is re-read and must
be unchanged, and the pending request still unapplied.

These are registry negative cases: they exercise the imported
validators' identity, certified-output and witness guards; no naming
behaviour exists in this runner. It runs no owner-authorization control:
under the ownerless ruling @End@ refuses for every party, and that
evidence belongs to the separate, retained @repair-rows@ runner
(@ownerless-end@), which is currently unverified under #172 — not to this
journey.
-}
module Journey.Controls
    ( stepReject
    , expectRejected
    , expectedRejectionReason
    , negativeKey
    , negativeValue
    ) where

import Control.Monad (unless)
import Data.ByteString (ByteString)
import Data.Foldable (toList)
import Data.List (isInfixOf)
import Data.Maybe (mapMaybe)
import Data.Text qualified as T
import Lens.Micro ((^.))

import Cardano.Ledger.Address (Addr (..))
import Cardano.Ledger.Api.Tx (bodyTxL)
import Cardano.Ledger.Api.Tx.Body (outputsTxBodyL)
import Cardano.Ledger.Api.Tx.Out (TxOut)
import Cardano.Ledger.BaseTypes (Network (..))
import Cardano.Ledger.Credential (Credential (..))
import Cardano.Tx.Ledger (ConwayTx)

import Journey.Chain (readChainState)
import Journey.Malformations
    ( dropModifyProof
    , forgeContributeStateRef
    , tamperRoot
    , tamperStateOutputRoot
    )
import Journey.Narration (emit, failWith, hex, require, textOf)
import Journey.Steps (journeyKey, journeyValue)
import Singular.Registry.Blueprint (NamingCodes)
import Singular.Registry.Capabilities (Capabilities (..))
import Singular.Registry.Config (CageConfig (..))
import Singular.Registry.Evidence (NoWitness)
import Singular.Registry.Ledger
    ( ConwayEra
    , Root (..)
    , TokenId (..)
    , TxIn
    )
import Singular.Registry.LedgerProvider (SubmitResult (..))
import Singular.Registry.LedgerProvider qualified as Provider
import Singular.Registry.SessionIO qualified as Cage
import Singular.Registry.Signing (signTx)
import Singular.Registry.Terminal (submitWithWallet)
import Singular.Registry.Trie (TrieManager (..))
import Singular.Registry.Trie qualified as CageTrie
import Singular.Registry.TxBuilder.Edges qualified as Edges
import Singular.Registry.TxBuilder.Internal
    ( cageAddrFromCfg
    , extractCageDatum
    , leafAbsent
    , requestAddrFromCfg
    , scriptHashBytes
    , txInToRef
    )
import Singular.Registry.TxBuilder.Update (updateTokenWithDuties)
import Singular.Registry.Types
    ( CageDatum (..)
    , OnChainRoot (..)
    , OnChainTokenState (..)
    , edgeInsertAbsent
    )
import Singular.Registry.Wallet (Wallet (..))

{- | The rejection reason each negative case requires: the
node must report a phase-2 Plutus evaluation failure — the
on-chain validator refused to execute the transaction — and
not any phase-1 ledger rule. A malformed CBOR, an unbalanced
fee or a missing input would all "fail" while telling us
nothing about the guards; a phase-1-shaped rejection fails
the run naming what came back instead.

Marker: expected-rejection-reason
-}
expectedRejectionReason :: String
expectedRejectionReason =
    "phase-2 Plutus script evaluation failure \
    \on the submitted transaction"

{- | The node-level marker of that reason: a failed Plutus
evaluation is reported by the ledger as a 'PlutusFailure'.
-}
phase2ScriptFailureMarker :: String -> Bool
phase2ScriptFailureMarker = isInfixOf "PlutusFailure"

{- | The registry negative section. With one unapplied
insert request pending, build the valid update transaction
the oracle would submit, derive three transactions from it
that are each invalid in exactly one intended way, and
require the on-chain validators to refuse all three. Then
prove the authenticated state is unchanged: a rejected
evaluation never applies, so the rejected transactions must
have left no trace.
-}
stepReject
    :: Wallet
    -> CageConfig
    -> NamingCodes
    -> (Provider.Network, Provider.LedgerProvider NoWitness IO)
    -> Capabilities NoWitness IO
    -> TrieManager IO
    -> TokenId
    -> [(TxIn, TxOut ConwayEra)]
    -> OnChainTokenState
    -> IO ()
stepReject wallet cfg codes prov caps tm tid refs stateBeforeRejects = do
    -- A second, unapplied insert request: the payload the
    -- mutated updates below pretend to process. It stays at
    -- the request address throughout.
    let reqAddr = requestAddrFromCfg cfg tid Testnet
    before <- Cage.withLatest prov (`Cage.outputsAt` reqAddr)
    require "reject: request address empty before the second request" $
        null before
    _ <-
        Edges.bookEdge
            cfg
            codes
            prov
            (submitWithWallet wallet caps)
            (walletAddr wallet)
            tid
            negativeKey
            edgeInsertAbsent
    reqUtxos <- Cage.withLatest prov (`Cage.outputsAt` reqAddr)
    require "reject: exactly one request UTxO after the second request" $
        length reqUtxos == 1
    forgedRef <- case reqUtxos of
        ((reqIn, _) : _) -> pure (txInToRef reqIn)
        [] -> failWith "reject: no request UTxO found"
    emit
        "reject-request"
        ( "pending insert request key="
            <> textOf negativeKey
            <> " value="
            <> hex negativeValue
            <> " request_utxos="
            <> show (length reqUtxos)
        )
    -- The apply step ran inside a speculative session, whose
    -- mutations were discarded: the manager's trie still holds
    -- the empty boot state, while the chain holds the applied
    -- hello insert. Replay that insert — committed this time —
    -- so the second update's proofs are computed against the
    -- root the chain actually has, and require the manager to
    -- be in step before building on it.
    _ <- withTrie tm tid $ \trie -> do
        _ <- CageTrie.insert trie journeyKey journeyValue
        managerRoot <- CageTrie.getRoot trie
        require
            "reject: trie manager is in step with the chain"
            (unRoot managerRoot == unOnChainRoot (stateRoot stateBeforeRejects))
        pure ()
    -- The valid oracle update for that request. It is never
    -- submitted unmutated: each case derives one single-defect
    -- transaction from it. Every mutation keeps the tx
    -- well-formed for ledger phase 1 (the case descriptions
    -- say how), so only the on-chain validator stands between
    -- each transaction and the ledger.
    (baseTx, pp) <- Cage.withLatest prov $ \v -> do
        rejectCtx <- Edges.registryContextFor cfg codes v refs
        tx <- updateTokenWithDuties cfg v tm tid (walletAddr wallet) rejectCtx
        pp <- Cage.parameters v
        pure (tx, pp)
    newRoot <- baseTxStateRoot baseTx
    -- The validators the three cases require to refuse, by
    -- their script hashes as the node names them in a phase-2
    -- failure.
    let stateScriptHash =
            scriptHashHexOfAddr (cageAddrFromCfg cfg Testnet)
        requestScriptHash =
            scriptHashHexOfAddr (requestAddrFromCfg cfg tid Testnet)
    -- Case 1: forged state-token identity. The request's
    -- Contribute redeemer names a real input — the request
    -- UTxO itself — as the cage's state UTxO. It carries no
    -- state token, and request.request.spend must refuse it.
    expectRejected
        wallet
        "reject-forged-identity"
        "request.request.spend validateContribute: the claimed state UTxO carries no state token"
        requestScriptHash
        caps
        (forgeContributeStateRef pp forgedRef baseTx)
    -- Case 2: tampered certified output. The new state output
    -- keeps the exact StateDatum shape but its root is the
    -- byte complement of the root the proofs certify.
    let tamperedRoot = tamperRoot newRoot
    expectRejected
        wallet
        "reject-tampered-output"
        "state.state.spend validModify: output datum root must equal the proof-recomputed root"
        stateScriptHash
        caps
        (tamperStateOutputRoot newRoot tamperedRoot baseTx)
    -- Case 3, re-cut under issue #79 (was: missing required
    -- witness). The old case dropped the owner from the required
    -- signers of this Modify and required a refusal. That expectation
    -- encoded the pre-repair defect: Lean `Singular.step`'s `.fold`
    -- case requires only `nativeSpend`, net-mint equality and the
    -- conditional mint witnesses — it states no owner hypothesis — so
    -- the repaired validator rightly accepts an ownerless Modify (the
    -- `epic16-preserved` failure that exposed this row is the evidence).
    -- The owner-signature refusal moved for a time to an `End` case,
    -- since retired (see below). This case instead drops the fold's Merkle proof
    -- witness: Lean's `.fold` refuses a fold whose demanded witnesses
    -- are absent (`representative-witness` / `application-mint-witness`
    -- when the corresponding net is nonzero), and on this registry apply
    -- the carried witness is the Merkle proof certifying the net
    -- effect — `mpf` verification of a witnessless Update must fail.
    expectRejected
        wallet
        "reject-missing-proof"
        "state.state.spend validModify: a Modify with no Merkle proof witness is refused"
        stateScriptHash
        caps
        (dropModifyProof pp baseTx)
    -- No Case 4: the old owner-authorization negative control (`End`
    -- without owner signature) is gone with the owner role itself.
    -- `End` refuses for every party now; that evidence lives in
    -- repair-rows (ownerless-end, receipted) instead of here.
    -- Positive control: the rejected transactions left no
    -- trace. The authenticated state is re-read from the
    -- chain and compared against the post-apply state.
    stateAfter <- readChainState cfg prov tid
    require
        "reject-control: authenticated state datum unchanged"
        (stateAfter == stateBeforeRejects)
    reqAfter <- Cage.withLatest prov (`Cage.outputsAt` reqAddr)
    require
        "reject-control: the pending request is still unapplied"
        (length reqAfter == 1)
    emit
        "reject-control"
        ( "authenticated state unchanged after 3 rejected transactions"
            <> " root=0x"
            <> hex (unOnChainRoot (stateRoot stateAfter))
            <> " request_utxos="
            <> show (length reqAfter)
            <> " — no trace"
        )

{- | Submit a mutated transaction that the on-chain
validators must refuse. Fails the journey if the node
accepts it — naming the guard that did not hold — or if it
rejects it for any reason other than 'expectedRejectionReason'.
-}
expectRejected
    :: Wallet
    -> String
    -> String
    -> String
    -> Capabilities NoWitness IO
    -> ConwayTx
    -> IO ()
expectRejected wallet caseName guard expectedScript caps tx = do
    result <- capSubmit caps (signTx (walletSignKey wallet) tx)
    case result of
        SubmitAccepted _ ->
            failWith $
                caseName
                    <> ": transaction was ACCEPTED — the guard did not hold: "
                    <> guard
        SubmitRefused reason -> do
            let reasonText = T.unpack reason
            unless (phase2ScriptFailureMarker reasonText) $
                failWith $
                    caseName
                        <> ": expected-rejection-reason <"
                        <> expectedRejectionReason
                        <> "> but the node rejected with <"
                        <> reasonText
                        <> ">"
            -- The node names the script that failed: require the
            -- expected validator to be the one that refused.
            unless (expectedScript `isInfixOf` reasonText) $
                failWith $
                    caseName
                        <> ": the node rejected in phase 2 but its failure does not name the expected validator (script hash 0x"
                        <> expectedScript
                        <> "); the node said <"
                        <> reasonText
                        <> ">"
            emit caseName ("node refused it, reason matched: " <> reasonText)
        unavailable ->
            failWith
                (caseName <> ": submission unavailable: " <> show unavailable)

{- | The payload of the request the negative section
pretends to process. It is never applied.
-}
negativeKey :: ByteString
negativeKey = "negative"

negativeValue :: ByteString
negativeValue = leafAbsent

-- | The root the valid update writes into its state output.
baseTxStateRoot :: ConwayTx -> IO OnChainRoot
baseTxStateRoot tx = case mapMaybe stateRootOf outputs of
    [r] -> pure r
    rs ->
        failWith $
            "reject: expected exactly one state output in the base update, found "
                <> show (length rs)
  where
    outputs = toList (tx ^. bodyTxL . outputsTxBodyL)
    stateRootOf out = case extractCageDatum out of
        Just (StateDatum s) -> Just (stateRoot s)
        _ -> Nothing

{- | Lowercase hex of the script hash of a script payment
address, in the form the node names a failing script by.
-}
scriptHashHexOfAddr :: Addr -> String
scriptHashHexOfAddr (Addr _ (ScriptHashObj sh) _) =
    hex (scriptHashBytes sh)
scriptHashHexOfAddr _ = emptyScriptHashHex

{- | The empty fallback for a non-script address, which the
reason check can never match.
-}
emptyScriptHashHex :: String
emptyScriptHashHex = ""
