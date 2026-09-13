# Singular M1 cross-boundary contract registry

Current 2026-09-13T05:35:00Z. Every entry is either enforced by named evidence
or remains an explicit completion debt.

## E17 producer to E18 consumer tuple

Parties: E17 naming/registry producer and E18 cardano-keri consumer.

Invariant: NamingDatum is four-field/double-wrapped; Retire is constructor 3;
representative name is Rep plus blake2b_224 of state-policy, cage-token-name
and original creation payment-key hash plus incarnation; the state datum's
representative policy owns that name. State carries the exact consumer pin.
E17 supplies one coherent applied/unapplied script tuple and vectors before
E18 migrates.

Enforced: PARTIAL. Wire identities and existing consumer-pin checks have
focused controls. Final tuple is unavailable. E18 migration is closed until
root accepts E17's final candidate.

## Authentic retirement completion

Parties: E17 application, registry state, request, consumer, representative
policy and custody.

Invariant: the exact representative asset under the spent state's configured
representative policy moves into custody, its own pending Update is processed
to Over, and that exact policy/name/quantity-one asset is burned minus one.
Rejected, unrelated-root and foreign-policy paths cannot complete retirement.

Enforced: NONE on current candidate 27e5f9a. Root control
handoffs/e17-root-foreign-policy-control.json proves the four actual executing
handlers accept a foreign-policy lookalike with the authentic name. NOTE-095
commissions complete policy/name/quantity binding plus positive, negative and
guard-erasure controls. This is the current highest-priority contract defect.

## Nonempty processing and rejected requests

Parties: generic registry, consumer implementation and Lean correspondence.

Invariant: empty and surplus processing refuse. Legitimate nonempty
all-rejected, mixed and zero-net batches succeed with exact timing, funding,
refund, custody retention and full post-state behavior.

Enforced: PARTIAL. Producer checks exist. Candidate general FullCorr and
reachable histories exist with an orphan-custody discriminator. Both actual
implementation layers and production-built compiled correspondence remain
open; no accepted-model adoption.

## Authentic registry association

Parties: Singular registry producer and cardano-keri registration.

Invariant: the consumer targets its configured authentic registry and rejects
own-policy, copied-policy and forged-anchor substitutions with attributable
semantic failures and preserved attempted inputs.

Enforced: NONE. The sole three-variant ledger run stopped during setup with
zero target transactions. Offline seed, mintless, full signed transaction and
UTxO evidence repair is incomplete. No second ledger authority exists.

## Production-built invariant validation

Parties: accepted Lean model, exact final Aiken source/compiler/parameters and
Blaster.

Invariant: all 192 source-derived obligations retain their clauses,
hypotheses, domains, quantifiers, both directions and full result/post-state
meaning against production-built final UPLC. Unsupported or unevaluated rows
remain debt.

Enforced: NONE at milestone scope. The 192-row source/clause checker is
accepted only as a checker; candidate formal relations and four shared
endpoints are partial evidence. Final source tuple, actual two-layer
correspondence and production-built Blaster execution remain open.

## Obtainable release and onboarding

Parties: Singular release, cardano-keri maintainer and new operator.

Invariant: versioned exact artifacts can be obtained and replayed through the
full required journey by a new operator.

Enforced: NONE. E17/E18 acceptance, final artifact publication and onboarding
remain unfinished. Release PR 67 is held.
