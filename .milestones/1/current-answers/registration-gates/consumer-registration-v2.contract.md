# Consumer registration tranche gate v2

This replaces v1 as the prospective mechanical gate. v1 and both root
false-green probes remain immutable evidence. v2 is parent-owned and fail-closed:
the candidate runner prepares raw material but never supplies an expected result,
verdict, compiler identity, artifact digest, or completion boolean that the gate
trusts.

## Current admission state

`BLOCKED-PRE-SEAL`. Epic 17 has not yet supplied the accepted final producer
tuple and integration base. The executable therefore has no positive acceptance
mode today: any otherwise complete candidate stops at `missing parent producer
seal`. This is a named missing input, not a behavioral result. A seal is a new
immutable companion artifact with its own manifest; it is never silently added
to this frozen manifest.

Implementation may proceed against the explicitly labelled provisional snapshot
under NOTE-112. No v2 GREEN, E0/E1/E4 credit, or acceptance is available before
the seal and a real positive execution exist.

## Candidate and source fence

- historical implementation base:
  `0100012b1afa318df3bae6cf40d6d9ee3507110e`;
- the seal supplies the accepted producer integration base, which must descend
  from that historical base;
- candidate HEAD must descend from the sealed integration base and be clean;
- only `conformance/consumer-adapter/**` may differ from the sealed base;
- the sealed final producer sources and the exact consumer source
  `14a64a4681d3e429fab5877062b5c476c2a4bfe2` are read-only build inputs;
- candidate runner interface remains
  `conformance/consumer-adapter/run-registration-gate <prepared-dir>`.

The runner may start an isolated node and prepare sources, CBOR argument vectors,
transaction bodies and keys local to that devnet. It may not decide outcomes.

## Root probes are mandatory controls

Every v2 invocation verifies the two root-owned v1 receipts by exact SHA-256 and
content. The frozen v2 executable is then executed once against each preserved
control commit. Both must be rejected after the fake runner runs, because their
claimed evidence paths do not exist and their reports contain no raw execution.
Those rejection receipts are part of the v2 manifest. Merely changing
`NOT-RUN` to `ESTABLISHED`/`REFUTED` cannot affect the result.

## Parent-owned identity derivation

The sealed manifest fixes:

- accepted integration base and final producer commit;
- exact source repositories/commits and clean-tree requirement;
- Aiken and cardano-cli version strings;
- Plutus V3, live protocol major 10 and
  `defaultFunSemanticsVariantC` (PV11+ requires a new gate/Variant E);
- the exact seven-artifact inventory, blueprint title, source project and
  production parameter CBOR for producer-state, producer-request,
  producer-application, producer-applied-representative, registry-adapter,
  checkpoint-policy and lifecycle-observer;
- expected source-tree digests and compiled/hash identities for all accepted
  dependency artifacts. The adapter identity is measured from candidate HEAD.

The parent verifier copies each sealed project, invokes the pinned production
compiler itself, applies every parameter itself, selects the exact title (never
the first title), writes the measured compiled bytes and derives SHA-256 and V3
script hash. Candidate-supplied identity fields are ignored.

## Prepared evidence and closure

The runner must create only the v2 preparation files and a `raw/` tree:

- `prepared.json`: isolated node socket, network magic, node log and creation
  metadata; no verdict fields;
- `inventory.json`: every regular file below `raw/`, with relative path,
  SHA-256 and byte count;
- `cek-vectors.json`: fixed row ids and, per exact artifact, only UPLC argument
  terms/files;
- `ledger-plan.json`: fixed ledger row ids, signed body paths, watched inputs and
  addresses, and the exact artifact expected to fail;
- raw bodies, signed transactions, datums, redeemers, parameter CBOR, source
  mutation patches and node material needed by the parent.

No symlink, absolute path, `..`, duplicate, missing file, digest mismatch or
unclassified extra file is accepted. Every legacy `evidence` claim is inspected
before schema checking; a nonexistent path rejects both v1 root probes.

## Parent-owned whole-operation rows

The executable, not JSON, fixes these outcomes and exact failure purposes:

| id | parent expectation | exact failing purpose |
|---|---|---|
| `E0-register-valid-cek` | `ESTABLISHED` | none; all seven programs HALT |
| `E0-register-valid-ledger` | `ESTABLISHED` | none; parent submits and queries |
| `E1-missing-inception-cek` | `REFUTED` | lifecycle-observer |
| `E1-missing-inception-ledger` | `REFUTED` | lifecycle-observer |
| `E4-wrong-allocation-cek` | `REFUTED` | registry-adapter |
| `E4-wrong-allocation-ledger` | `REFUTED` | registry-adapter |
| `register-omitted-adapter` | `REFUTED` | producer-state |
| `register-swapped-adapter` | `REFUTED` | producer-state |
| `register-altered-pin` | `REFUTED` | producer-state |
| `register-extra-checkpoint-mint` | `REFUTED` | registry-adapter |
| `register-wrong-aid-name` | `REFUTED` | registry-adapter or lifecycle-observer, sealed exactly |
| `register-delete` | `REFUTED` | registry-adapter |
| `register-end` | `REFUTED` | registry-adapter |
| `register-surplus-action` | `REFUTED` | producer-state |

For CEK rows the parent invokes Aiken UPLC evaluation on the bytes it rebuilt
with the supplied raw arguments. A negative passes only when every prerequisite
program follows the E0 result and the exact named purpose alone fails with an
evaluator-logic error. Decode/setup/unsupported builtin/timeout is
`COULD-NOT-EVALUATE` and RED.

For ledger rows the parent queries live protocol parameters, inspects each body
with `cardano-cli debug transaction view`, computes the txid, submits it itself,
and queries the watched pre/post UTxOs. E0 must be accepted and its unique
checkpoint/state/folder outputs must satisfy the registration formulas. E1/E4
must reach phase-2 submission and fail at the sealed exact script; builder,
balance, TTL, input, fee, decode, unsupported-builtin or opaque failure is RED.
No runner-written `submitted=true` is read.

## Parent-derived mutation controls

The fixed controls remain always-refuse, always-accept,
remove-inception-observer-check, remove-allocation-check,
remove-unaccounted-checkpoint-check, remove-mandatory-adapter-invocation and
inventory-remove-one. The parent applies each sealed patch in a disposable copy,
rebuilds, proves the exact compiled bytes changed, reruns the owned CEK rows,
then restores and proves byte-for-byte clean identity. Inventory removal is
tested by the parent's closure checker. Candidate booleans such as
`source_rebuilt`, `compiled_bytes_changed`, or `clean_restored` are ignored.

The real E0 positive must pass before any refusal/control can certify the slice;
an always-failing implementation cannot pass.

## Registration semantics inspected by the parent

The binding interpretation is unchanged from v1: a processed generic `Insert`
whose authenticated key/value encode the lifecycle-derived AID checkpoint asset;
the final state pin equals the actually executed adapter withdrawal and is
preserved; exact registered lifecycle withdrawal; exact checkpoint mint/output
and datum; request bond to checkpoint, tip to folder, authenticated destinations;
no other checkpoint-policy mint. The parent checker derives these values from
the rebuilt artifacts, transaction body, redeemers/datums and pre/post UTxOs.
Receipt accounting remains a separate missing dependency and is not fabricated.

Revive, goDormant, goConvicted, dormant conviction/duplicity, receipt mint/burn,
the dormant rotation bridge, snapshot burning, or the rest of the board are not
certified by this gate.
