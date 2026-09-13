# t89 — consumer companion for the ownerless schema (preparation cut)

**Role:** bounded implementation. Parent: epic 18 owner, pane %914. **Seat:** GLM (`glm --approve`).
**Runtime root:** this directory. **context=FRESH** — a new process, new context, nothing inherited.
(An earlier version of this line said `context=REUSED`; that was wrong. `t70b-generic-rows-finish` is
retired and terminal but **NOT accepted**, so no verdict, writable state or context acceptance
transfers from it. You may read its root as history; you write nothing there.)

**Worktree:** `/code/singular-e18-companion` — yours alone.
**Branch:** `feat/ownerless-consumer-companion`, base **`597b010`** (our consumer tip, clean).
**Provisional source identity:** epic 17 antecedent **`f3a68b1bcd63119f8db79548a7d15926bf408856`**,
tree `3cac539b1db35cabfbe176775c8476cd2f753bc7`, already fetched and reachable in your worktree.

## Read first, in full

1. `/tmp/projects/singular/milestone-1/handoffs/ownerless-integration-cut.md`
2. `/tmp/projects/singular/milestone-1/epic-17/handoffs/ownerless-schema-handoff-to-18.md` — the
   complete schema. Read identities **from the committed source and an actual build**, never from
   prose, including this brief's summary of it.

Load `worker-protocol`, `code-the-design` and `worktrees`. (An earlier version of this brief
omitted `worker-protocol` — my omission, and the reason your first journal entry was prose.)

## The schema break

Generic `State` in `onchain/validators/types.ak`, in order: `root: ByteArray`, `tip: Int`,
`process_time: Int`, `retract_time: Int`. **`owner` and `stake_script` are removed from the HEAD of
the record** — so a positional decoder **mis-parses**; it does not merely lose fields. That is the
whole risk in this change. The state validator becomes **parameterless**.

SDK `offchain/lib/Cardano/MPFS/Cage/Types.hs` is already aligned. `RequestDatum` stays Constr 0,
`StateDatum` Constr 1.

**`f3a68b1` is PROVISIONAL, not accepted.** Prepare against it; credit nothing to it.

## Owned scope

Conformance **decoders, builders, parameter application**, and their tests and docs.

Known leads — **derive the complete affected set yourself from the frozen source**, including
imported SDK compatibility:

- `conformance/app/Conformance/CS06.hs` — requires `previousPolicies` and 1 state parameter
- `conformance/app/Conformance/Run.hs` — derives applied state identity with `previousPolicies=[]`
  and still reads/updates `stateOwner`
- `conformance/app/Conformance/Mirror.hs` — decodes `StateDatum`

**Forbidden:** editing `onchain/`, `naming-onchain/` or `offchain/` product sources. Import the
epic-17 commit **mechanically**. Epic 17 is the sole product-validator and SDK writer.

## Rules that decide the work

- **No inherited GREEN.** Nothing from the six-field era carries over — not a passing test, not a
  receipt, not a serialization claim. Old vectors stay as **historical evidence of what the accepted
  model said at their revision**; never rewritten to assert a new meaning.
- **Superseded owner/hook expectations retire to preserved history.** Do not invent new owner roles,
  and do not credit old receipts.
- Distinct **request/refund** and **application/name** authority stays intact. Ownerlessness does not
  touch them, and does not ban a registry creator from funding or signing.
- Full-inventory and held-contract debt **remains**. CG11/CG12/CG19 stay unresolved consumer-contract
  debt.
- Affected CS/CG rows **re-execute against the final artifacts** — not here.

## Terminal conditions

You produce a **clean consumer-only delta**, prepared and locally checked. It **does not merge
alone** and grants **no conformance credit**; epic 17 owns the final serial integration branch that
takes its finalized repair plus your delta, with no parallel writers.

Stop at: a complete prepared delta with local checks; `BLOCKED Q-NNN`; or an **evidenced** capacity
limit with a handoff. Report which. Resolve conflicts against the same approved schema, and report
any behavioral ambiguity as a **concrete Given/When/Then story** rather than choosing.

No push to main, no merge, no release, no deployment. You are not alone in the codebase; do not
revert edits made by others.
