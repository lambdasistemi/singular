# Permanent registration and termination

As a registry participant, I register a key and terminate it permanently, while
every caller is unable to use the other five registry transitions on this
instance. I can still update an application's payload without moving the
  registry, fold permissionlessly, reject a pending request and retract an
eligible request with the original timing and refund obligations.

Authority: the operator's 8 October 2026 bounded permanent contract ruling,
issues #505/#506, and the carve-505 brief. Base model and implementation:
`464ed8674de626470396cc871f3af85a1d489477`. Protected rejection #495 is deferred.
Preservation is recorded in `specs/504-m2-preservation`; its refs stay untouched.

1. Define `Singular.M1` as a fixed restriction of the existing model, with
   allowed outcomes delegated unchanged, excluded folds refused, atomic batches,
   original request exits, executable driver cases and proofs.
2. Give the bounded state validator a distinct compiled identity. Its fold
   checks every updating request before approval or trie execution. Keep the
   broader state validator and its evidence separate. Bind bounded witnesses
   to the bounded state hash, and select both explicitly in ordinary CLI creation
  and recognition. Do not introduce mutable admission configuration.
3. Exercise allowed lifecycle controls and independently constructed excluded,
   unknown and mixed requests at the validator boundary. Check a deliberately
   broader contract against the boundary checker to demonstrate detection.
4. Reuse the packaged Demo1 journey and existing conformance description
   language; retain broader evidence and uncovered rows. Run targeted checks,
   then one bounded full repository gate and exact-head hosted CI. Submit one
   draft PR and the precise receipt/limit manifest to the parent for acceptance.

Evidence is reported separately for Lean execution/proofs, Aiken evaluation,
compiled scripts, connected local ledger journey, extracted artifact and hosted
CI. Unreachable absent starting states are explicit fixture limits. KERI model
conformance and demonstrated integration remain distinct unmet outcomes. This
worker has no merge, release, deployment or public-network transaction authority.

Superseding scope: [the later operator ruling](ruling.md) abandons registries
from earlier releases and withdraws old-deployment compatibility. New M1
identities must still be checked and wrong/unknown identities refused. Protected
rejection (#498/#495) follows this carve with its own identity change and remains
an M1 closing condition. This candidate does not close M1. Protected deposit
is outside this carve's closing conditions.
