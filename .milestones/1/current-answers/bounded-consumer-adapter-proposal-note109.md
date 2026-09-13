# NOTE-109 bounded consumer-adapter proposal

Owner proposal, 2026-09-12. This refines
`handoffs/consumer-adapter-binding.md` against NOTE-109. It does not commission a
new worker, edit an upstream product, or claim acceptance. NOTE-110 subsequently
assigned the compiled compositor to epic 18 and separated its executable
registration tranche from the missing go/revive/convict dependencies; the
correction is incorporated below.

## Outcome

The epic-18 adapter should be a specific compiled Plutus V3 withdrawal validator
whose identity is pinned by the sixth generic `State` field delivered by epic 17.
It realizes the model value
`Plugin.registry = { body := processBody, allowReject := Op.userPostable }`; it is
not an arbitrary selected plugin, a caller-supplied `Bool`, or an unchecked
operation label.

The adapter is a bounded conformance artifact. It authenticates the actual
transaction effects required by the validated registry transition. It does not
put KERI economics into naming and does not replace the checkpoint machine.

## Fixed identities and inputs

Before an executable result can be accepted, the artifact and every test context
must bind all of the following, as native ledger identities rather than labels:

1. epic 17's accepted six-field `State` bytes, constructor/field order, width
   checks, state/request/application/applied-representative hashes, and exact
   compiler plus semantics variant;
2. the compiled adapter source, parameters, unapplied/applied bytes and hashes;
3. checkpoint policy identity and bonded checkpoint datum/address/value shape;
4. lifecycle, advance and dormant-conviction observer credentials and their
   registration/withdrawal route;
5. checkpoint-reap receipt policy identity, asset-name derivation and authentic
   minting contract.

The request supplies correlation data such as `aid` and recorded `k`, but it is
not its own authorization. The adapter derives the expected operation and effects
from the consumed Singular request/state plus transaction evidence and reconciles
those effects with the complete mint map, withdrawals and outputs.

## Operation contract

All accepted nonempty `Modify` transactions include the exact zero withdrawal
which executes the pinned adapter. The ledger executes every withdrawal, so the
adapter additionally requires the exact observer withdrawals below; mere
presence of a credential in request data is not evidence.

| operation | authenticated evidence and effects |
|---|---|
| `register aid` | actual lifecycle-observer withdrawal for that inception; exactly one accounted checkpoint-policy mint for `aid`; exactly one correctly bonded checkpoint output with the derived initial checkpoint; no pre-existing registry leaf for `aid` |
| `revive aid k` | actual rotation/advance authorization bound to recorded `k`; exactly one accounted checkpoint-policy mint for `aid`; exactly one correctly bonded checkpoint output at the derived successor state |
| `goDormant aid k` / `goConvicted aid` | the consumed request carries the authentic receipt emitted by checkpoint reap under the fixed receipt policy; the same transaction burns exactly that receipt while applying the corresponding registry fold transition |
| `convict aid k` from dormant | actual dormant-conviction observer withdrawal bound to the same `aid` and recorded `k`, plus its authenticated duplicity evidence |

The adapter refuses `Delete`, `End`, a rejected receipt-carrying go request, an
unsupported transition, mismatched `aid`/`k`, omitted or substituted observers,
wrong destinations with otherwise correct totals, and every unaccounted
checkpoint/receipt mint or burn. Accounting is by exact policy, asset name,
quantity and destination; foreign-policy substitution and extra `+1`/`-1`
entries refuse.

## Required controls

- a valid bootstrap and legitimate operation through the correctly pinned
  adapter (positive control);
- coherently posted but consumer-invalid operation through the correct adapter;
- omitted adapter withdrawal and substituted adapter withdrawal;
- wrong allocation with otherwise correct totals;
- omitted and substituted lifecycle/advance/enforcement observer;
- fabricated, wrong-policy, wrong-name, wrong-quantity and missing receipt;
- receipt present but not burned, extra receipt mint/burn, and extra checkpoint
  mint/burn;
- mismatched `aid` or `k`, plus `Delete`, `End`, and rejected go request;
- mandatory-hook-predicate removal, showing the omitted-hook case becomes
  accepted;
- unaccounted-asset-check removal, showing an extra checkpoint or receipt asset
  becomes accepted.

Each negative must retain a nearby positive with the same setup so a setup failure
cannot masquerade as discrimination.

## Exact unresolved compiled boundary at the pinned consumer revision

Pinned source examined:
`lambdasistemi/cardano-keri@14a64a4681d3e429fab5877062b5c476c2a4bfe2`.

What exists:

- `onchain/validators/checkpoint_observer.ak` supplies registrable lifecycle,
  advance and enforcement withdrawal validators;
- `checkpoint.ak` implements registration and live-checkpoint spend branches.

What does not exist in the pinned `onchain/` tree:

1. a compiled withdrawal validator composing `Registry.processBody`'s registry
   transition, checkpoint effect, allocation and rejection veto; **this is an
   epic-18 conformance deliverable under NOTE-110**, not an external dependency;
2. a checkpoint-reap branch and receipt-token policy whose authentic output can
   be consumed and burned by the fold transaction;
3. a compiled dormant-registry duplicity observer binding the dormant leaf's
   `aid` and recorded `k`.

The existing `observer_enforcement` authenticates conviction against a live
checkpoint input. That is not the model's dormant-leaf `env.duplicity aid k`.
Likewise `advance` consumes and advances a live checkpoint; using it for revival
from a dormant registry leaf with no live checkpoint needs an explicit bridge and
cannot be inferred. `wit_receipts` in checkpoint advance code are KERI signature
witnesses, not reap receipt assets.

This absence was checked with a negative search for `processBody`, receipt-policy
and reap/dormant symbols over the pinned `onchain/` tree (zero matches), with a
positive-control search finding the observer entry points and 130
observer/`wit_receipts` matches. The explicit `Close` path in `checkpoint.ak`
remains fail-closed.

## Executable acceptance boundary

The work is split into two prerequisite sets rather than one all-or-nothing
block:

1. **Registration tranche (E0/E1/E4): epic-18 owned and executable.** Compile the
   bounded compositor and the existing lifecycle/registration/checkpoint sources
   from the pinned consumer revision; reproduce and bind exact compiler,
   dependency, parameter, unapplied/applied-byte and hash identities; establish
   the real credential registration and withdrawal route. These rows do not need
   a reap receipt, dormant rotation bridge or dormant duplicity observer. Their
   final composed producer executions wait only for epic 17's accepted six-field
   tuple, not for unrelated operations.
2. **Go/revive/convict tranche: named incomplete inputs.** Authentic go requires
   the missing reap branch and receipt policy; dormant revival requires an
   explicit bridge from dormant state to the live-checkpoint advance domain;
   dormant conviction requires the missing `aid,k` duplicity authenticator. These
   rows remain `COULD-NOT-EVALUATE` until those exact artifacts have accepted
   source, bytes, policy derivations and toolchain provenance. A locally
   fabricated receipt or renamed KERI witness receipt cannot cross that boundary.

Once those inputs exist, acceptance requires two distinct implementation layers:

1. compiled CEK execution of the final epic-17 producer and exact applied adapter
   over retained transaction contexts, including all controls above;
2. an isolated real-ledger journey that registers the credentials, creates the
   authentic observer/reap evidence, executes the pinned withdrawal and retains
   transaction bodies, txids, script identities and queried outputs.

Mutation discrimination supports those layers but is not a substitute for the
second layer.

## Ownership and minimum external route

Epic 18 implements and verifies the composed registry adapter in
conformance-owned paths. It is not waiting for root to supply that deliverable.
The minimum external consumer-side work is only: (a) checkpoint reap plus receipt
policy, (b) a dormant rotation bridge compatible with revival, and (c)
dormant-registry duplicity authentication. Return their precise source-derived
interfaces and scopes to root if no bounded compatible artifacts can be produced
without upstream product edits. The affected operations then stay explicitly
open; epic 18 must not fill them with a mock issuer or widen itself into an
upstream checkpoint rewrite. This is a technical dependency route, not a
stakeholder semantics question.
