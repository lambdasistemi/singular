# Empty-batch refusal — Lean-first repair plan, for the desk to route

Owner: epic 17 (Lean-first/product repair plan and serial integration). Epic 18
owns consumer correspondence and the bounded starvation/takeover assessment.
Authority: `answers/A-001-empty-batch-refusal-and-starvation-limit.md` (stakeholder
"yes", 2026-09-12T18:12:51Z). **Nothing here is scheduled into the #77 candidate
under acceptance**, and nothing here jumps the queued value-routing work.

## The story, and the limit stated in the same breath

**As an application user, I want empty processing attempts rejected, so a
successful operation means real work was done.** A registry update with no
requests and no tokens to mint is refused and the registry is left unchanged.

**This is not protection against starvation, and will never be reported as
such.** A hostile producer can submit a nonempty batch of its own requests while
omitting a victim's. Nonemptiness buys "a success means something happened"; it
buys no queue fairness, no censorship resistance, no guaranteed inclusion, and no
useful progress for any particular user. The separate outcome — *as a requester,
I want another willing processor to complete my request even when one SPO keeps
skipping it* — is unassessed, and belongs to epic 18's takeover evidence.

## Affected Lean definitions (accepted tree `dd9e508b`, commit `13231f58`)

| site | today | change |
|---|---|---|
| `Model.lean:250-256` — `step … \| .fold items mint actionNet w` | accepts any `items`, including `[]`, under the other guards | **the whole change**: refuse when `items = []` |
| `Model.lean:188-193` — `foldItems` | `\| s, [] => .ok { state := s }` | **UNCHANGED.** This base case is what terminates a *nonempty* fold; A-001 forbids touching it, and I have no faithful alternative to propose |
| `Model.lean:168-186` — `foldOne` | per-item guards | unchanged |

One decision the desk must rule on, because it is observable: **where in
`step`'s fold arm the new check sits.** Today the first guard is
`if !w.nativeSpend then throw "native-witness"`. An empty batch submitted without
a native witness is refused today as `native-witness`; if the empty check goes
first it becomes the new refusal instead. Both refuse. My recommendation is
**first**, because the most specific true statement about the transaction is that
it processes nothing, and an empty batch should refuse regardless of witnesses —
but it changes an existing observable refusal string, so it is the desk's call,
not mine to take silently.

Proposed refusal name: **`empty-fold`**, matching the existing kebab vocabulary
(`native-witness`, `net-mint-mismatch`, `representative-witness`,
`application-mint-witness`). Lean owns the word; the implementation and the
stories inherit it.

## Theorem obligations

| theorem | effect |
|---|---|
| `Statements.lean:66-72` `fold_iff` | **changes**: the RHS gains `items ≠ []`. Its proof delegates to `fold_ok` in `Lemmas.lean`, which changes with it |
| new, mirroring the consumer's `R8_empty_fold_refused` | **`empty_fold_refused`**: `step s (.fold [] mint net w) = .error "empty-fold"`. The consumer already has exactly this at `Registry.stepFn` (`batch ≠ []`), so this closes a real asymmetry rather than inventing one |
| `Statements.lean:242` `native_witness_even_zero_net` | **must be re-checked**: a legitimate *nonempty* zero-net fold is explicitly preserved by A-001, so if this theorem quantifies over `items` including `[]` its statement narrows; if it is already about a nonempty sequence it is untouched. Verify, do not assume |
| `Statements.lean:101` `sequential_fold_cons`, `:248` `nonzero_action_invokes_policy`, `:83` `foldOne_insert_iff`, `:93` `foldOne_terminal_iff` | expected unaffected (cons-shaped or nonzero-implies-nonempty), to be confirmed by elaboration rather than by reading |

Statement digests, story records and coverage rows move with these. **Approval
alone reduces no debt**: every affected row is revised honestly, and the new
obligation enters the denominator with its own required layers.

## Downstream identity effects — the expensive part, named up front

The refusal has to exist **on chain**, not only in the model. `validModify` in
`onchain/validators/state.ak` currently has no emptiness guard, so:

- `state.ak` changes → **the state script hash moves again** (it is `2bf61b13…`
  as of the current candidate, already moved once this epic for E-001);
- every naming identity that reads the state hash moves with it;
- the SDK codec is unaffected (no `State` field change), but the **final identity
  handoff to epic 18 moves again**, and companion `7816305` would need a third
  reconciliation;
- gates, the verifier's obligation set and the conformance rows that pin those
  identities all rebind.

That cost is the reason this is scheduled at a boundary, not folded into a live
candidate.

## Proposed slice placement

1. **Not now.** The #77 candidate at `fe89e68` is in fresh full acceptance; no
   edit enters it.
2. **Not ahead of value routing.** The operation-specific value-routing slice is
   already queued and touches the same `validModify`.
3. **Then one bounded slice**, Lean first: the `step` guard and `fold_iff`, the
   new `empty_fold_refused`, the re-check of `native_witness_even_zero_net`, then
   the `state.ak` guard, then the two executable layers (a property/state-machine
   check that an empty batch is refused and a nonempty zero-net fold still
   succeeds, plus a ledger row), then the identity rebind and one handoff to epic
   18.
4. **Merging it with the value-routing slice is worth considering** — both edit
   `validModify` and both move the state hash, so doing them together costs one
   identity rebind and one epic-18 reconciliation instead of two. That is a
   sequencing question for the desk; I am not taking it unilaterally.

## What is NOT approved by this ruling, restated so no one reads it wide

No FIFO, no mandatory whole-queue processing, no deadline, no privileged
processor, no new fee, no consensus change. No nonzero-net requirement.
Permissionless submission, ownerlessness, all other fold conditions, witness
implications and legitimate request outcomes are preserved. No new worker, no
dependency update, no unrelated semantic edit.

## Related, and distinct

`CG11` was carried as the unresolved empty-fold conflict. This ruling settles its
**product** question — the consumer's `batch ≠ []` is the correct behaviour and
Singular should match it. The conformance disposition of that row remains epic
18's.

---

# Revision 2 — desk rulings applied (NOTE-054, 2026-09-12T18:19Z)

No new stakeholder decision was needed; these are sequencing answers to the plan
above and they supersede it where they differ.

## 1. Guard placement and precedence — ruled, and narrower than I proposed

The guard goes **after** the native-spend guard and **before** `foldItems`.
Existing `native-witness` precedence is preserved: the user approved refusing
empty processing, not changing an already-refused command's error. So:

| case | refusal today | refusal after |
|---|---|---|
| empty items, no native witness | `native-witness` | `native-witness` — **unchanged** |
| empty items, native witness present | accepted | `empty-fold` |

My recommendation of "first" is withdrawn. It would have changed an existing
refusal string for a command that is already refused, which is outside the yes.

**And the theorem shape is ruled with it**, which is the part I had wrong: do not
state an unconditional equality to `empty-fold` across all `w`. Two statements,
both bound exactly:

- a **general** empty-refused theorem: no successful result for an empty batch,
  for any witnesses;
- an **exact-error** theorem: the error is `empty-fold` **when
  `nativeSpend = true`**, with the missing-native case preserving
  `native-witness`.

## 2. The two theorems are not narrowed

- `Statements.lean:242` `native_witness_even_zero_net` already carries
  `h : step s (.fold items [] n w) = .ok t` as its **premise** and concludes
  `nativeSpend = true` and `sameNet = true`. A premise of success excludes the
  empty case automatically once the guard exists. Its statement stands; update
  the proof projections if elaboration demands it, and **elaborate rather than
  reason about it**.
- `nonzero_action_invokes_policy` does not establish that a nonzero action net
  implies nonempty items, and must not be restated as if it did. Preserve its
  actual success premise and witness implication.

## 3. One combined consumer-repair candidate

Approved: **operation-specific value routing AND the narrow empty-batch refusal
in one coherent subsequent candidate**, so the shared `validModify` changes take
**one** downstream identity reconciliation instead of two. This was the
sequencing question I raised, and the answer is the merge.

Bounds that come with it: separately discriminating controls and separate
acceptance records per outcome — the two stories never share a control; Lean
first, before dependent implementation; `fe89e68` is not touched during its
current acceptance; the combined placement neither delays nor displaces the
queued value work, does not authorize checkpoint-machine implementation, and
waives neither story. Existing seats only.

## 4. The script dependency graph, computed — my earlier claim was too wide

I wrote that "every naming identity that reads the state hash moves". That was
asserted, not computed. Measured against the candidate's own sources and built
blueprints:

| script | params | depends on the state hash how | moves when `state.ak` changes? |
|---|---|---|---|
| `state.state.*` | 0 | it **is** the state | **yes** — the root of the change |
| `request.request.*` | 2 (`statePolicyId`, `cageTokenName`) | **applied** parameter | **applied identity yes**, unapplied only if `request.ak` changes |
| `application.application.*` | 0 | `naming.ak:202-203` holds `pub const mpfs_state_hash = #"2bf61b13…"`, consumed at `application.ak:22-23` to authenticate the state input — a **compiled-in constant** | **yes, unapplied hash** — the constant must be re-pinned |
| `representative.representative.*` | 1 (`application_policy`) | through the application policy | **applied identity yes**; unapplied `6f14bdea…` unchanged |
| `retirement_custody.*` | 0 | imports only stdlib; no state reference | **no** |
| `staking.staking.*` | 0 | none | **no** |

So the chain is **state → (constant) → application → (parameter) → applied
representative**, plus request's applied identity. Two scripts are untouched.
Rebind only what is affected, retain each script's actual hash and application
inputs, and keep the final consumer candidate tuple coherent.
