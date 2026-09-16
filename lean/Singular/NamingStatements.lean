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
    namingCertifies hasher .deleteActive signatures revealed context = false := by
  sorry

/-- **naming_delete_refused** — a `deleteActive` request never folds through
the naming transition, whatever the state. -/
theorem naming_delete_refused (hasher : RecoveryHasher) (state : NamingState) (key : Key) :
    ∃ why, namingStep hasher state (Request.mk .deleteActive key 0 0 0 0 none []) none =
      .error why := by
  sorry

/-- **NM4** — the six admission rows. -/
theorem naming_nm4_admissions (hasher : RecoveryHasher) (context : NamingCtx)
    (controllerSig : List (List Nat)) (refundSig : List (List Nat))
    (quorumSig : List (List Nat)) (revealed : Option NamingAddress)
    (hcontext : context.controllerBytes = controllerAddress.bytes) :
    namingCertifies hasher .insertAbsent [] none context = true ∧
    namingCertifies hasher .insertActive controllerSig none context = true ∧
    namingCertifies hasher .updateActive controllerSig none context = true ∧
    namingCertifies hasher .deleteAbsent refundSig none context = true ∧
    (namingCertifies hasher .updateTerminal quorumSig none context = true ∨
      namingCertifies hasher .updateTerminal [] revealed context = true) ∧
    namingCertifies hasher .deleteActive controllerSig none context = false := by
  sorry

/-- **NM4** — an `updateTerminal` approval signed by the current control key
alone is refused (operator ruling). -/
theorem naming_control_key_alone_never_retires (hasher : RecoveryHasher)
    (fixture : NamingFixture) (hfix : fixture.nextControlCommitment = nextControllerCommitment) :
    namingCertifies hasher .updateTerminal [fixture.controlAddress.bytes] none
      (NamingCtx.mk fixture.controlAddress.bytes fixture.controlAddress.bytes fixture) = false := by
  sorry

/-- **NM4** — a `deleteAbsent` approval under any signature but the refund
address's, and one under no signature, are refused. -/
theorem naming_retract_only_inserter (context : NamingCtx) (other : List Nat)
    (hdiff : other ≠ context.refundBytes) :
    namingCertifies fixtureHasher .deleteAbsent [other] none context = false ∧
    namingCertifies fixtureHasher .deleteAbsent [] none context = false := by
  sorry

/-- **NM5** — the recovery commitment check binds the revealed key to the
record's committed digest. -/
theorem naming_recovery_commitment_binding (hasher : RecoveryHasher)
    (fixture : NamingFixture) (revealed : NamingAddress)
    (hok : (hasher revealed).digest = fixture.nextControlCommitment.digest) :
    revealsCommittedRecoveryKey hasher fixture revealed = true := by
  sorry

/-- **WellFormed** over the naming state, preserved meaning: ledgers agree
with the trie and every record holds its active token. -/
theorem naming_wellformed_initial :
    Naming.WellFormed namingInitial := by
  sorry

end NamingStatements
end Singular
