# Approved story: reject empty processing attempts

Recorded 2026-09-12T18:12:51.141Z.

## Stakeholder words

The desk proposed: **As an application user, I want empty processing attempts rejected, so a successful operation means real work was done.** Its concrete example was a registry update with no requests and no tokens to mint: reject it and leave the registry unchanged. The stakeholder answered **"yes"**, then immediately challenged the purpose: **"it's trickable, if the SPO is a bad actor it will feed and starve anyway"**.

## Exact ruling and its limit

The explicit yes approves refusal of an empty processing batch. It authorizes the corresponding Lean-first design revision and dependent implementation/acceptance changes. It does not require a nonzero token net: a legitimate nonempty sequence with zero net remains governed by its existing clauses. Preserve all other fold conditions, permissionless submission, witness implications, and legitimate request outcomes. Revise the top-level fold acceptance, not the recursive empty-list base case needed to terminate a nonempty fold, unless the owner proves a faithful alternative.

The immediate follow-up rejects the claim that nonemptiness prevents starvation. A hostile producer can choose a nonempty batch of its own requests while omitting a victim. Do not count the empty-batch repair as queue fairness, censorship resistance, guaranteed inclusion, or useful progress for every user. The concern is not a cancellation of the narrow yes and does not approve FIFO, mandatory whole-queue processing, a deadline, privileged processors, new fees, or a consensus change.

## User outcome to assess

**As a requester, I want another willing processor to complete my request even when one SPO keeps skipping it.**

Assess against a trace with a victim request, repeated nonempty adversary batches, and then a willing processor using the latest registry state while the victim remains processable. Establish whether the request remains available, its timing remains its own, proof reconstruction is possible, and its processing/refund/tip behavior follows the contract. Separate validator admission when included from actual block inclusion: a finite successful takeover does not prove eventual inclusion. If it expires, establish the specified recovery/refund path rather than promising eventual processing. Derive every expected outcome and timing assumption from the accepted model. Escalate only a demonstrated missing product guarantee as a concrete story; do not invent its semantics.

## Primary sources and ownership

Accepted Singular Lean: 13231f58833b8feb57f4b0f9b1117bfcfba0c07d, tree dd9e508bb11108c5c459fcf8e59e3dd1930eead6; Model.step fold and Statements.fold_iff currently allow empty items under the other guards. Bound consumer 14a64a4681d3e429fab5877062b5c476c2a4bfe2: Registry.stepFn fold requires batch != []; R8_empty_fold_refused. The full read-only primary packet is handoffs/consumer-value-primary-20260912; registry-as-mpfs.md:295-322 discusses producer choice and a censoring leader but is not a liveness proof.

Epic17 owns the Lean-first/product repair plan and serial integration; epic18 owns consumer correspondence and the bounded starvation/takeover evidence assessment. Root routes dependencies. Keep current four-worker ceiling and pending accepted producer identity; no fresh worker, dependency update, or unrelated semantic edits follow from this ruling. Revise affected statement/digest/story/proof/coverage records honestly; no debt reduction from approval alone.

## Communication

The stakeholder explicitly said: "stop treating me as your co-worker I am the stake holder you talk to me in user stories". Product-facing debriefs and necessary decisions must state actor, observable outcome, evidence, and remaining limitation. Engineering coordination belongs to the owners.
