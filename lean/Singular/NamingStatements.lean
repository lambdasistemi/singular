import Singular.NamingLemmas

/-! The naming statement surface over the registry-mode model. Every
declaration re-states a first-release obligation with its meaning preserved:
naming defines no delete; the record UTxO holds the active token; retirement
completes as `updateTerminal` certified by the committed recovery key or a
distinct-member quorum, never the current control key alone; the recovery rows
keep their meaning. -/

namespace Singular
namespace NamingStatements

/-- **NM4 / R-NM4** — naming's certification of `deleteActive` is never true:
the profile defines no delete. -/
theorem naming_certifies_no_delete (hasher : RecoveryHasher) (signatures : List (List Nat))
    (revealed : Option NamingAddress) (context : NamingCtx) :
    namingCertifies hasher .deleteActive signatures revealed context = false := by rfl

/-- **naming_delete_refused** — a `deleteActive` request never folds through
the naming transition, whatever the state. -/
theorem naming_delete_refused (hasher : RecoveryHasher) (state : NamingState) (key : Key) :
    ∃ why, namingStep hasher state (Request.mk .deleteActive key 0 0 0 0 none []) none =
      .error why := by
  unfold namingStep
  cases hc : namingContext state key (toBytes28 0) with
  | none =>
    refine ⟨"naming-context", ?_⟩
    simp only [Option.toExcept, hc]
    rfl
  | some ctx =>
    refine ⟨"naming-no-delete", ?_⟩
    simp only [Option.toExcept, hc]
    simp only [bind, Except.bind]
    rfl

/-- **NM4** — the six admission rows. -/
theorem naming_nm4_admissions (hasher : RecoveryHasher) (context : NamingCtx)
    (signatures : List (List Nat)) (revealed : Option NamingAddress) :
    namingCertifies hasher .insertAbsent signatures revealed context = true ∧
    (namingCertifies hasher .insertActive signatures revealed context = true ↔
      signatures.contains context.controllerBytes = true) ∧
    (namingCertifies hasher .updateActive signatures revealed context = true ↔
      signatures.contains context.controllerBytes = true) ∧
    (namingCertifies hasher .deleteAbsent signatures revealed context = true ↔
      signatures = [context.refundBytes]) ∧
    (namingCertifies hasher .updateTerminal signatures revealed context = true ↔
      (revealsCommittedRecoveryKey hasher context.fixture revealed = true ∨
        quorumMet context.fixture.retirementQuorum signatures = true)) ∧
    namingCertifies hasher .deleteActive signatures revealed context = false := by
  refine ⟨rfl, Iff.rfl, Iff.rfl, ?_, ?_, rfl⟩
  · simp [namingCertifies]
  · simp [namingCertifies]

/-- **NM4** — an `updateTerminal` approval signed by the current control key
alone is refused (operator ruling): with nothing revealed there is no committed
recovery key, and one signature that is not a quorum member's meets no quorum.

The two hypotheses are what make the ruling precise rather than merely true of
one fixture. A control key that is *itself* a quorum member and a threshold of
one would be certified — but then it is certifying as a member of the quorum,
which is the other half of R-NM4, not as the current control key. -/
theorem naming_control_key_alone_never_retires (hasher : RecoveryHasher)
    (fixture : NamingFixture)
    (hthreshold : 1 ≤ fixture.retirementQuorum.threshold)
    (hnotmember : fixture.controlAddress.bytes ∉ fixture.retirementQuorum.members) :
    namingCertifies hasher .updateTerminal [fixture.controlAddress.bytes] none
      (NamingCtx.mk fixture.controlAddress.bytes fixture.controlAddress.bytes fixture) = false := by
  simp only [namingCertifies, revealsCommittedRecoveryKey, Bool.or_eq_false_iff]
  refine ⟨trivial, ?_⟩
  simp only [quorumMet, decide_eq_false_iff_not, Nat.not_le]
  have hempty : fixture.retirementQuorum.members.filter
      [fixture.controlAddress.bytes].contains = [] := by
    apply List.filter_eq_nil_iff.mpr
    intro x hx
    simp only [List.contains_cons, List.contains_nil, Bool.or_false, beq_iff_eq]
    intro hEq
    exact hnotmember (by rw [← hEq]; exact hx)
  rw [hempty]
  simpa using hthreshold

/-- **NM4** — a `deleteAbsent` approval under any signature but the refund
address's, and one under no signature, are refused. -/
theorem naming_retract_only_inserter (context : NamingCtx) (other : List Nat)
    (hdiff : other ≠ context.refundBytes) :
    namingCertifies fixtureHasher .deleteAbsent [other] none context = false ∧
    namingCertifies fixtureHasher .deleteAbsent [] none context = false := by
  refine ⟨?_, by simp [namingCertifies]⟩
  simp only [namingCertifies, decide_eq_false_iff_not]
  intro hEq
  exact hdiff (by simpa using congrArg List.head? hEq)

/-- **NM5** — the recovery commitment check binds the revealed key to the
record's committed digest. -/
theorem naming_recovery_commitment_binding (hasher : RecoveryHasher)
    (fixture : NamingFixture) (revealed : NamingAddress)
    (hok : (hasher revealed).digest = fixture.nextControlCommitment.digest) :
    revealsCommittedRecoveryKey hasher fixture revealed = true := by
  simp [revealsCommittedRecoveryKey, hok]

/-- **WellFormed** over the naming state, preserved meaning: ledgers agree
with the trie and every record holds its active token. -/
theorem naming_wellformed_initial :
    Naming.WellFormed namingInitial := by
  refine ⟨⟨rfl, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩, ?_, ?_⟩
  · intro key; simp [kindCount, trieGet, namingInitial]
  · intro key; simp [kindCount, namingInitial]
  · intro key; simp [custodyCount, trieGet, namingInitial]
  · intro key; simp [custodyCount, namingInitial]
  · intro hh hmem _; simp [namingInitial] at hmem
  · intro c hmem; simp [namingInitial] at hmem
  · intro c₁ h1 _ _ _; simp [namingInitial] at h1
  · intro record hmem; simp [namingInitial] at hmem
  · intro pending hmem; simp [namingInitial] at hmem

end NamingStatements
end Singular
