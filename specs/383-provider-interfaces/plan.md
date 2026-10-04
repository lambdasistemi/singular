# Replace the command read path in one runnable slice

As a maintainer, I want a runnable first replacement that exercises the same
registry journey through generic capabilities, so that deleting the node path
does not leave the demonstration dependent on it. Read the [stories](spec.md)
first, then the [decisions awaiting intake acceptance](decisions.md).

## Proposed capability types

As a provider author, I need one effect-polymorphic contract rather than
transport-specific commands. These are proposed public shapes, not compiled
declarations. Ledger types reuse the current Conway representation. All
refusals are named algebraic values; adapter transport failures are handled
inside m. No interface mentions IO, sockets or nodes.

```haskell
data SessionBinding = Bound ChainPoint | Unbound
data ChainPoint = Genesis | At SlotNo BlockHeaderHash
data Acquisition = Latest Network | AtPoint Network ChainPoint
data Evidenced w a = Evidenced { value :: a, witness :: Maybe w }
data NoWitness
data Verdict a endorsement
    = Verified a endorsement
    | Unverified a Reason
newtype Verifier w m = Verifier
    { verifyFact :: forall a. Evidenced w a -> m (Verdict a Endorsement) }
data LedgerProvider w m = LedgerProvider
    { acquire :: forall a. Acquisition -> (Session w m -> m a)
        -> m (Either AcquireFailure a)
    , submitTx :: Network -> SignedTx -> m SubmitResult
    }
data Session w m = Session
    { sessionNetwork :: Network
    , sessionId :: SessionId
    , sessionBinding :: SessionBinding
    , outputs :: OutputQuery -> m (Either ReadFailure (Evidenced w Outputs))
    , protocolParameters :: m (Either ReadFailure (Evidenced w PParams))
    , tipObservation :: m (Either ReadFailure (Evidenced w Tip))
    , scriptRegistered :: ScriptCredential
        -> m (Either ReadFailure (Evidenced w Bool))
    , history :: Asset -> HistoryRange
        -> m (Either HistoryFailure ReconstructionMaterial)
    }
data OutputQuery
    = AtAddress Addr
    | HoldingAsset Asset
    | AtTxIn TxIn
    | AnyOf (NonEmpty OutputQuery)
    | AllOf (NonEmpty OutputQuery)
data HistoricalTransaction = HistoricalTransaction
    { transactionCbor :: TransactionCBOR
    , spentOutputs :: ResolvedOutputs
    , referenceOutputs :: ResolvedOutputs
    }
```

The network is separate from ChainPoint, as Lockness specifies. Bound records
an exact slot and header hash or the named genesis state; an acquisition
request cannot silently switch to another point. Demo 1 supplies only Unbound
sessions and refuses AtPoint requests by name. Session ids identify acquisition
scope, not trust or snapshot atomicity. AtPoint carries the future selection
request; a bound adapter's retention and rollback policies require a later
contract before implementation. This ticket supplies no bound adapter.

AnyOf is union and AllOf is intersection over exact output references, with
full policy-and-name asset identity. Duplicate references with conflicting
bytes refuse; empty NonEmpty compositions cannot be constructed. Resolved
outputs preserve address, value, datum form and bytes, and reference scripts.
Out-of-scope reads, unknown network, malformed bytes, missing input resolution
and incomplete advertised history are named refusals, never successful empty
answers. An honestly empty query result remains distinct from these failures.

Endorsement is abstract terminal-side information, with no witness format or
implementation in Demo 1. The optional witness attaches to facts, not history.
Submission returns the adapter's accepted transaction id or refusal reason;
acceptance for relay is separate from confirmation or settlement.

## Component responsibilities and data flow

As a command maintainer, I obtain ledger facts through one session and give
them to the common evaluator and time conversion. An adapter never evaluates
scripts or interprets registry events. Signing and durable file handling remain
at the executable boundary; confirmation uses injected clock and wait effects
so that its bounded behavior can also run in a pure state fixture.

```mermaid
flowchart TD
  Command[Registry command] -->|Acquires network session| Facts[Fact collection and verdict receipts]
  Facts -->|Resolved inputs and parameters| Evaluate[Local ledger evaluator]
  Pins[Pinned genesis and era history] -->|Supplies network time context| Time[Local time conversion]
  Evaluate -->|Measured units| Build[Existing transaction builders]
  Time -->|Validity slots| Build
  Facts -->|Outputs and parameter values| Build
  Build -->|Prepared body| Send[Signing and submission]
  Send -->|Accepted transaction id| Poll[Bounded output visibility polling]
```

Move shared Provider responsibilities out of the node-internal component.
Use one ledger-provider capability module, one evidence/verdict module, one
generic history representation, common local evaluator and time modules,
the recorded Koios adapter, and a pure State fixture adapter. Replace CLI.Node
composition with terminal composition. Keep generic wallet/signing, transaction
builders, application proofs and receipt durability; move them to their stable
owners rather than retaining a node namespace as a compatibility shim.

Tip is a raw, evidenced provider observation needed by existing expiry and
recovery decisions; it is not a snapshot binding. Script-credential registration
is an additional raw fact used by deployment tools, authorized in answer
A-003. Its Koios endpoint mapping must be demonstrated before acceptance;
unknown registration refuses by name rather than returning False.

## Deletion inventory across the tracked tree

As a reviewer, I want a complete discovery extent, so that an obsolete caller
does not survive outside the obvious adapter files. The committed
[deletion inventory](deletion-inventory.json) scans all 2,452 tracked paths at
the frozen base. It finds 239 paths and 1,284 distinct matching lines:
150 paths name node or indexer wiring, 171 name provider or derived calls, and
24 name the journey or mock; these overlapping categories are not summed.
Each row binds its path, content hash, matching line numbers and proposed
disposition. Lexical discovery establishes scope only, not successful deletion.

| Discovered surface | Replacement or preservation obligation |
| --- | --- |
| Node/View, Node/Indexer, Node/IndexerView, Node/IndexGate | Delete node reads and in-process chain following from the terminal. |
| Node/Memory and Provider's IO-only scopedProvider | Replace with a genuinely pure ledger-provider fixture; retain scope refusal as behavior. |
| Provider's evaluation, registration and two time calls | Move evaluation and time to common local services; supply the generic registration fact. |
| Node Session, Confirmation, Submit, Options, Funding, PhaseLog and Wait | Remove node connections and globals; preserve signed-only submission, bounded wait, loss handling and phase measurements through new capabilities. |
| CLI Node, Command, Session, Attached, Live, Recovery and Reconcile | Replace capability composition and node settings; preserve journalling, identity checks, recovery and input visibility. |
| CLI Create, Preview, Inspect, Entry, Fold and Reject | Move every command and preview path together; keep parser refusal before effects and keys out of read commands. |
| Deployment/Node and retained example executables | Migrate all ledger reads and evaluation; move private devnet orchestration into test-only components. No retained production node adapter. |
| ContractSuite, ProviderSpec, OneViewSpec, IndexerViewSpec, StubView and builder tests | Preserve product obligations over the new pure and recorded adapters; delete indexer coverage mechanics and false snapshot assumptions for Unbound. |
| Cabal, component inventory, Nix, node-confinement checks and CI | Remove obsolete production modules/dependencies and test-only wiring; preserve test coverage and publish newly uncovered limits. |
| Demo journey, attach/recovery/deployment controls, release archive and docs | Replace node/indexer flags and archive instructions in the same replacement; regenerate paired speech and preserve historical decision evidence. |

At implementation, rediscover all callers from the tracked source tree and
compiler dependency graph. Quantify packaged command tests over the parser's
nonempty command extent and public component inventory. Exercise the packaged
binary with removed --backend and --node-socket settings and require a named
parser refusal before acquisition. A renamed import or grep without a real
binary check does not establish that a removed mechanism is unreachable.

## Runnable vertical slices

As a demonstration user, I must retain a working journey after the first
implementation slice, rather than receive an isolated interface library.
The replacement and deletion land together. There is no intermediate pushed
candidate with both provider and node command routes.

| Slice | Runnable outcome | Required observations |
| --- | --- | --- |
| Replace commands and their old reads | Packaged create/preview, insert, inspect, update, terminate, fold, reject and recovery run on the pure and Koios-shaped devnet adapters; common evaluation/time, receipts and bounded confirmation are active; old node/indexer routes are deleted. | Actual ledger journey, no node socket passed to singular, exact output visibility after booking, all facts Unverified, failures and parser removal controls. |
| Demonstrate provider and local-computation preservation | Recorded read-only preprod and devnet responses run through the same adapter; generic history resolves bytes/dependencies; evaluation/time match recorded node results. | Fixture provenance, same-input differential results, pure effect trace, missing/malformed/history-pagination controls. |
| Publish evidence and prepare handoff | Public suite and current docs describe receipt-computed guarantees and missing boundaries; exact-head local gate, CI journey and auditor checkpoint trail are bound to the candidate. | Immutable receipts, controlled-fault red/green, no stale narration, clean committed range and exact-head CI. |

The first slice may be large because runnable replacement is indivisible at
the command boundary. Internal commits may build toward it but are not pushed
as completed slices. Resource limits and immutable per-slice checks are frozen
after intake acceptance, before child launch. No additional seats are inferred.

## Development-network provider and complete call coverage

As a CI reviewer, I need a provider independent of singular's own receipts.
Recommend a CI-only Koios-shaped facade over the generated devnet, replacing
the receipt source in tools/demo1_mock_indexer.py. Its state comes from the
devnet ledger, captured submitted CBOR and an independent history/input store.
The existing readback disagreement modes stay as separate controls. The node
belongs to this test provider; the singular executable never connects to it.
The epic owner accepted loopback-only transport in the CI composition in
answer A-001. Production live Koios HTTP is outside this ticket.

| Koios call | Every journey consumer it must serve | Independent source and present gap |
| --- | --- | --- |
| tip | Acquisition, expiry/recovery and observation receipts | Devnet chain tip; existing mock waits for an inspect receipt and is not sufficient. |
| address_utxos | Funding, reference/state/request lookup, previews and recovery | Full devnet UTxOs including genesis funding; absent from current mock. |
| asset_utxos | Exact state-token and application-token lookup | Full devnet UTxOs filtered by policy and name; current mock serves one synthetic output only. |
| asset_txs | Generic asset history, including consumed and recreated state outputs | Independent transaction index considering both spends and outputs, with pagination and stable ordering; absent. |
| tx_info | Resolve txins, spent/reference inputs and confirmation outputs | Independent transaction/output archive; absent. Must distinguish a spent output from a live one. |
| epoch_params | Fee, collateral, minimum output, cost models and local evaluation | Actual devnet parameters and captured Koios shape; absent. |
| submittx | Every write and preserved refusal control | Raw signed CBOR relayed to the devnet with its actual rejection; absent. Never synthetic acceptance. |
| tx_status | Polling status hint and refusal/timeout controls | Devnet inclusion status; absent. Success still requires exact output visibility. |
| tx_cbor, accepted addition | Full raw transaction bytes in history | Independent CBOR archive; absent and required by the published Koios schema. |
| Registration facts, accepted addition | Deployment verification and reward credential checks | Existing deployment reads this from the node; a demonstrated Koios endpoint mapping is required before acceptance. |

Every call must have a captured request, response, source and hash, linked to
the consumer's effect trace. A required call returning 404, a synthetic empty
answer, or the facade reading terminal receipts fails the CI journey. This
table establishes required coverage; the facade is not implemented and no
runtime endpoint coverage is claimed at intake.

## Invariant-to-test map and controlled faults

As a reviewer, I want each claimed guarantee to name the observation that
would contradict it. These are planned checks. No row below has been executed
on a new implementation. Behavioral red evidence must come from the subject
running with a reachable fault, never a compiler or launcher failure.

| Requirement in the user's words | Executable boundary and positive observation | Controlled fault that must turn it red |
| --- | --- | --- |
| One transaction uses one session | Instrument provider acquisitions and every builder fact; require one session id and matching binding in the prepared receipt. | Reacquire midway or attribute one consumed fact to a second session. |
| Unbound really means no snapshot promise | Pure/recorded adapter permits changing tip between calls while retaining Unbound and honest receipts. | Turn the latest tip into Bound or claim all unbound reads share one ledger state. |
| Every fact is explicitly unverified | Discover every consumed fact from a nonempty journey effect trace and reconcile it with receipt verdicts and inspect output. | Omit one fact, stamp one Verified, erase the extent, or omit inspect's verdict. |
| Confirmation waits for the exact output | Publish status first and exact booking output later; next build starts only after visibility, with bounded clock receipts. | Treat status alone or another transaction's output as confirmed; bypass or remove the wait bound. |
| Provider facts do not override ledger validation | Real devnet rejects a transaction using a spent funding input or a changed application proof with a recorded ledger refusal. | Facade reports synthetic acceptance, ignores ledger rejection, or the test replaces the submitted body. |
| Local evaluation has the same script context | Compare local units and script failures with recorded node answers on identical transaction/input/parameter bytes. | Corrupt a spent/reference output, cost model or transaction redeemer. |
| Pinned time preserves validity bounds | Compare floor, ceiling and slot-start conversion at era/slot boundaries with recorded node answers; require named out-of-range refusal. | Use another network's genesis, shift era start or swap floor and ceiling. |
| History is generic reconstruction material | Pure and recorded adapters return complete CBOR with matching resolved references, covering an asset spend and creation plus multiple pages. | Drop a middle page, spend-only transaction, resolved input or CBOR; invent an evidence verdict for history. |
| Composed queries preserve exact outputs | Pure adapter runs union/intersection over addresses, assets and txins, with exact identity, datum and reference-script bytes. | Drop one constituent, match asset name without policy, or merge conflicting references. |
| Acquisition, registration and released reads refuse by name | Pure fixture exposes wrong-network, unsupported point, unknown registration and released-session paths without silently answering empty. | Convert a refusal into an empty success or allow a released read. |
| Rebuilt root still matches the state output | Existing local replay/root comparison is exercised through provider facts, retaining its unverified verdict. | Change a replay edge or the returned state datum root; require registry-named refusal. Full history-based reconstruction remains outside this ticket. |
| No node instance or in-memory indexer survives | Run packaged commands with provider configuration and no socket; old flags refuse; compiler/package dependency closure contains no production node adapter. | Reintroduce a command socket route or package an obsolete adapter. Source sweep is discovery only. |
| Pure monad can supply every capability | Execute acquisition, all query forms, parameters, tip, history, submit and bounded polling in State with no embedded effects. | Add an observable hidden external-effect requirement; shape compilation controls are reported separately from behavioral red. |
| Only abstract verification ships | Build/API controls establish NoWitness has no constructor and only unverified is configured; runtime receipts cover all facts. | Configure a concrete verifier/decoder or manufacture a successful endorsement. Compilation controls are structural evidence only. |
| Registry model obligations survive | Existing driver-generated scenarios compare observed mint, custody, payments, datums, signers and refusals through conformance. Reject migration preserves current gate/refusal/receipt behavior without claiming Lean correspondence. | Wrong refund, destination datum, signer, token policy or state spent by a retract. Existing uncovered/contradictory rows stay visible, including reject admission. |

The CI carriers are the dev-shell job's `nix develop --quiet -c just ci`,
the packaged `nix run --quiet .#demo1-cli-check` journey, and focused checks
added to that same local/CI surface for the new adapter. Existing
`.github/workflows/registry.yml` also carries attach, readback, contract and
recovery controls that must migrate rather than silently disappear.
The implementation also adds this spec directory to the repository's
presentation-check extent; this intake runs its existing checker explicitly.

## Acceptance boundaries and phase stop

As the epic owner, I receive this draft intake before authorizing execution.
The ticket owner writes planning and PR metadata only. No tests, production
code, dependencies or gate implementations are changed by this intake.
Each Markdown page has speech extracted by mkdocs-speech and stamped against
its current bytes. The proposed per-page ceiling is 24 KiB and 300 lines;
the machine-readable inventory is outside the prose budget.

The next phase begins only after an inbox acceptance naming the intake SHA.
Then the approved commit owner is Codex gpt-6.1-sol with high reasoning, and
the mute auditor is Claude claude-opus-5-5 with high effort in its own detached
audit worktree, both in this ticket's tmux window. No gate-author or draft
seats are authorized. Conflicting generic staffing recipes do not add seats.
The epic owner verifies final readiness and merges; this seat never merges.
