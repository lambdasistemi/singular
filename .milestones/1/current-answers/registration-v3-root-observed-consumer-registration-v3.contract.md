# Consumer registration tranche gate v3

v3 is the owned executable registration verifier required by NOTE-114/116. It
supersedes v2's pre-gate design while retaining v1, v2 and every falsification
receipt as historical evidence. It is currently `BLOCKED-PRE-SEAL`: the final
accepted producer tuple and integration base do not exist here, so the checked-in
gate intentionally has no positive mode and executes no candidate program.

## Admission and authority order

The shell gate first verifies the two root-owned v1 false-green receipts, then
requires a parent producer seal and its digest. Missing or malformed seal
authority stops before the candidate repository or runner is inspected. A
complete seal binds candidate, historical and integration commits; consumer
source `14a64a4681d3e429fab5877062b5c476c2a4bfe2`; exact parent-verifier bytes;
pinned tool paths and version strings; all source trees, artifact parameters,
compiled byte digests and V3 hashes; raw-vector bindings; ledger semantic
assertions; and the mutation inventory.

Only after a parent-only sealed preflight succeeds may
`conformance/consumer-adapter/run-registration-gate <prepared-dir>` execute.
The candidate may write raw inputs, argument terms, signed transactions and
node material, but no candidate verdict is consumed. The parent then rebuilds,
executes, submits, queries and decides every result. Candidate HEAD must be a
clean descendant of the sealed integration base, and the diff fence is exactly
`conformance/consumer-adapter/**`.

## Closed identities and retained execution

The seven fixed artifacts are producer state, request, application and applied
representative; registry adapter; checkpoint policy; and lifecycle observer.
For each, the parent verifies a clean exact source commit and digest, copies the
tracked tree, runs the pinned production Aiken build, applies production CBOR
parameters, selects the exact blueprint title, measures compiled bytes, derives
the V3 hash and compares it with an independent `cardano-cli policyid` result.

Every external command retains argv, cwd, timeout, relevant node socket, numeric
exit, stdout and stderr below an initially empty parent evidence root. Build
trees, rebuilt programs, mutant trees, failures and the complete retained-file
inventory survive both RED and GREEN outcomes.

Candidate `raw/` input is a closed nonsymlink inventory: every file has a safe
relative path, SHA-256 and byte count, and no undeclared file is permitted. CEK
argument counts are fixed per artifact. Four ledger rows use mutually disjoint,
nonempty watched inputs and nonempty watched-address sets.

## Executed semantics binding

Seal metadata alone does not establish CEK semantics. Before any candidate row
is credited, the exact Aiken evaluator executes two parent-generated UPLC
canaries. `consByteString 255 #` must return `#ff`; `consByteString 256 #` must
fail with the precise range error. Earlier semantics reduce 256 modulo 256 and
return `#00`, so that behavior is an executed RED. Live ledger execution also
requires Plutus V3 at protocol major 10. PV11+ requires a new Variant-E gate.

## Parent-fixed CEK matrix

“Invoked” and “must refuse” are separate sets. A program omitted by an operation
is not credited as a refusal.

| row | invoked | must refuse |
|---|---|---|
| `E0-register-valid-cek` | all seven | none |
| `E1-omitted-inception-withdrawal-cek` | all except lifecycle observer | checkpoint policy |
| `E1-invalid-inception-evidence-cek` | all seven | lifecycle observer |
| `E4-wrong-allocation-cek` | all seven | registry adapter and checkpoint policy |
| `register-omitted-adapter` | all except registry adapter | producer state |
| `register-swapped-adapter` | all except registry adapter | producer state |
| `register-altered-pin` | all seven | producer state |
| `register-extra-checkpoint-mint` | all seven | registry adapter and checkpoint policy |
| `register-wrong-aid-name` | all seven | registry adapter, checkpoint policy and lifecycle observer |
| `register-delete` | producer state, producer request, registry adapter | registry adapter |
| `register-end` | producer state, producer request, registry adapter | registry adapter |
| `register-surplus-action` | producer state, request, application, applied representative and registry adapter | producer state and registry adapter |

Every invoked program is evaluated from parent-rebuilt bytes with the exact
sealed raw arguments. Success must be a fully applied result. Decode, parse,
free-variable, unsupported-builtin, budget and timeout failures are
`COULD-NOT-EVALUATE`, never semantic refusals. A legitimate refusal must contain
the exact parent-sealed logic marker for each exact enforcing artifact.

## Parent-fixed live-ledger matrix

The four submitted rows are E0 valid, E1 omitted lifecycle withdrawal, E1
invoked with invalid inception evidence, and E4 correct total but wrong bond
allocation. Their exact expected failures are respectively none; checkpoint
policy; lifecycle observer; and registry adapter plus checkpoint policy.

Before submission, the parent parses every transaction view and verifies all
registration roles: operation, authenticated request key/value, state and
request inputs, pin before/after, adapter and lifecycle withdrawals/redeemers,
inception evidence, hash-proof input/burn, checkpoint policy/name/mint/output
address/datum/value, bond, tip and complete inputs/outputs/mint/withdrawals/
redeemers. Witness hash pointers must resolve to the corresponding rebuilt
program.

The omitted and invalid-evidence E1 rows are distinct relations to E0. The
omission row is otherwise equal and contains no lifecycle withdrawal; the
invalid row invokes lifecycle and changes only inception evidence. E4 preserves
the full configured relation and moves exactly the positive bond from the
checkpoint allocation to the refund allocation without changing the total.

Negatives are submitted first. They pass only on a real phase-2
`ValidationTagMismatch Phase2Valid`/`CekError` whose complete parsed
script-hash/purpose set equals the parent-fixed enforcing set; pre-submit or
unrelated failures are RED. Their watched state must remain byte-identical. E0
runs last, must submit successfully, consume every watched input, and produce
the txid-indexed outputs whose live queried fields equal the sealed assertions.

## Mutation controls

The parent first re-executes the unmodified target and requires the fixed
baseline observation. It then applies the exact sealed source patch to the
fixed enforcing artifact, rebuilds, requires changed compiled bytes and the
opposite result, restores and re-executes the original bytes. Fixed controls
are always-refuse, always-accept, remove inception-observer check, remove
allocation check, remove unaccounted-checkpoint check, remove mandatory adapter
invocation, plus a parent-generated inventory-remove-one control. No mutation
may be redirected to a different artifact or row.

## Current controls and limits

The validly shaped fabricated candidate passes sealed preflight and executes its
runner, then is rejected by the parent rebuild because its declared compiled
digest is fabricated, before CEK or ledger credit. A separate false evaluator
which returns `#00` for byte 256 is rejected by the executed Variant-C canary.

No current control is an E0 result. No v3 acceptance exists until the final
parent seal is installed and a fresh full run rebuilds all seven artifacts,
passes every CEK row, executes all four isolated ledger submissions, fires every
mutation control and writes the parent receipt. This gate does not certify reap
receipts, dormant/convicted/duplicity behavior, rotation bridging, snapshot
burning, or the rest of the full compiled-invariant denominator.
