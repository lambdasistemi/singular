# Corrections to my ruling — supersedes three parts of `A-OPEN-eight-rows-ruling.md`

The seven statement-based dispositions stand, with one addition at the end. Three things I got
wrong.

## 1. `escape_error` needs no user decision and no Lean edit

I framed it as a choice between re-pointing `escape_refused` and dropping the duplicate, and sent it
to the operator. **That was manufacturing a decision that does not exist.**

The declarations have the **same inputs** `(s : State) (id : Nat)` and the **identical conclusion**
`step s (.escape id) = .error "completion-only-custody"`. Both prove it by `rfl`. `Statements`
imports `Singular.Lemmas`. There is **no semantic conflict and no ambiguity** here.

**Keep both accepted declarations and both proof bodies unchanged.** Classify `escape_error` as a
**duplicate statement of the named public obligation**, carrying:

- explicit **exact-clause correspondence** to `Statements.escape_refused`;
- **both stable identities** — neither is absorbed into the other;
- **both source and definition bindings**;
- **honest separate debt.**

Use an existing suitable disposition with rationale, or add an explicit **metadata-only**
`duplicate-statement` category. This is **acceptance metadata, not a design ruling**, and it is
within your mandate.

`code-the-design` already permits grouping or sharing a scenario **when each precise claim is
represented and checked** — grouping never drops identities or clauses. So the eventual property
and production-boundary checks may be indexed by **both** declarations, **but only if they actually
assert their identical full claim.** That grants **no execution credit now**.

**Do not manufacture a user decision, a new Lean dependency, a removal, or a new product requirement
to make classification finish.**

## 2. I mis-described the literal-stripped record

I called `= .error` "strictly weaker" — as if it were a faithfully typed theorem asserting some
unspecified error. It is not. **It is an incomplete and malformed statement representation.**
`.error` without its argument is not a well-formed claim at all. The distinction matters: a weaker
claim can be reasoned about; a malformed one cannot.

## 3. My count of 1 was wrong — it is 2

I scanned a fixed seven-line window from each row's line. `namingStepFoldActionEq`'s missing
`naming-no-delete` literal sits past that window, so my window produced my answer. Re-scanned over
**whole declaration spans**:

```
Singular.escape_error          drops "completion-only-custody"
Singular.namingStepFoldActionEq drops "naming-no-delete"
```

**Inspect whole declaration spans, not a fixed number of lines.** Both must retain their literal
contents after the NOTE-002 repair, and both belong in it as regression fixtures.

## 4. What the seven dispositions do not buy

They may proceed — but **their Lean proofs cannot discharge required implementation-layer debt.**
A pure algebraic claim needs correspondence to the **real API or a composed operation**, not an
invented ledger action to make it look like a transition. Where applicability or refinement evidence
is missing, **leave it explicitly unresolved** rather than closing it with the disposition.

Inventory stays **192 = 109 + 83**; all identities and debt preserved; classification consistency
remains blocked on the NOTE-002 source-binding repair.
