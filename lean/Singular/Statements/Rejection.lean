import Singular.Statements.Admission
import Singular.Driver
import Singular.Model

/-! Evidence-bound rejection and protection before expiry. -/

namespace Singular.Statements

/-- Rejection is admitted exactly for identity-bound evidence and one of its two positive
conditions. The root check uses the model's logical map. -/
theorem rejection_admitted_iff (s : RegistryState) (r : Request) (w : RejectWitness) :
    rejectAdmission s r (some w) = none ↔
      r.registryId = s.config.registryId ∧
      w.evidence.registry = s.config ∧
      s.config.root = rootOf s.trie ∧
      w.evidence.request = r ∧
      w.validFrom < w.validTo ∧
      (match w.evidence.reason with
       | .mismatch leaf => leaf = trieGet s.trie r.key ∧ transition r.edge leaf = none
       | .expired => r.submittedAt + s.config.processTime + s.config.retractTime ≤ w.validFrom) := by
  unfold rejectAdmission
  cases h : w.evidence.reason <;>
    simp only [h] <;>
    (repeat' split <;> simp_all [bne, Bool.or_eq_true, Nat.not_le, Option.isSome_iff_ne_none])
  all_goals grind

/-- A lifecycle-compatible request cannot be rejected before expiry, regardless of the
evidence the processor chooses to supply. -/
theorem live_compatible_request_protected (s : RegistryState) (r : Request) (w : RejectWitness)
    (compatible : transition r.edge (trieGet s.trie r.key) ≠ none)
    (live : w.validFrom < r.submittedAt + s.config.processTime + s.config.retractTime) :
    rejectAdmission s r (some w) ≠ none := by
  intro admitted
  obtain ⟨_, _, _, _, _, condition⟩ := (rejection_admitted_iff s r w).mp admitted
  cases h : w.evidence.reason with
  | mismatch leaf =>
    simp only [h] at condition
    obtain ⟨same, refused⟩ := condition
    rw [same] at refused
    exact compatible refused
  | expired =>
    simp only [h] at condition
    omega

/-- **#344, a batch of one reject judges as the reject** — for every scenario
taking a request by the reject exit, the driver's judgement of the one-request
batch of rejects over any observed outputs is exactly its judgement of that
scenario's transaction, whatever inputs it spends. -/
theorem reject_batch_of_one_is_reject (r : Request) (sc : Driver.Scenario)
    (inputs : List TxInput) (outputs : List TxOutput)
    (hexit : sc.exit = .reject) (hrequest : sc.request = r) :
    Driver.judgeRejectBatch [r] outputs = Driver.judgeSurface sc inputs outputs := by
  subst hrequest
  simp [Driver.judgeRejectBatch, Driver.rejectBatchPayments, Driver.judgeSurface, hexit,
    spendRefusal]

/-- A rejection uses its own evidence admission, independently of the fold deadline.
Every retraction witness, including its upper bound, gives the same rejection admission. -/
theorem rejection_uses_its_own_admission (s : RegistryState) (r : Request)
    (w : RetractWitness) (rejection : Option RejectWitness) :
    exitAdmission s .reject r w rejection = rejectAdmission s r rejection := by
  rfl

/-- A missing proof never authorizes rejection, even when refunds are paid. -/
theorem rejection_without_evidence (s : RegistryState) (r : Request) (w : RetractWitness)
    (lovelace : Nat) (inputs : List TxInput) (outputs : List TxOutput) :
    admittedExitStep s .reject r w = .error "reject-evidence-missing" ∧
    admittedTxOfExit s .reject r w lovelace = .error "reject-evidence-missing" ∧
    exitRefusal s .reject r w inputs outputs = some "reject-evidence-missing" := by
  simp [admittedExitStep, admittedTxOfExit, exitRefusal, exitAdmission, rejectAdmission]

/-- Every admitted rejection preserves the full intermediate state, mints nothing, and pays
the existing deposit obligation. Admission changes no refund rule. -/
theorem protected_rejection_effects (s : RegistryState) (r : Request) (w : RetractWitness)
    (e : Option RejectWitness) (t : Result)
    (h : admittedExitStep s .reject r w e = .ok t) :
    t.state = s ∧ t.mint = [] ∧ t.paid = [(r.owner, r.deposit)] := by
  unfold admittedExitStep at h
  split at h
  · cases h
  · simp [exitStep, emptyResult, obligations, paymentPaid] at h
    cases h
    exact ⟨rfl, rfl, rfl⟩

/-- An admitted expiry rejection begins after every admitted retraction's excluded upper
bound for the same booked request, regardless of witness time. -/
theorem expiry_after_reclaim (s : RegistryState) (r : Request)
    (rw : RetractWitness) (jw : RejectWitness) (t : Result)
    (retracted : admittedExitStep s .retract r rw = .ok t)
    (rejected : rejectAdmission s r (some jw) = none)
    (expired : jw.evidence.reason = .expired) :
    rw.validTo ≤ jw.validFrom := by
  have reclaim := (retract_admitted_iff s r rw).mp ⟨t, retracted⟩
  have expiry := (rejection_admitted_iff s r jw).mp rejected
  simp only [expired] at expiry
  omega


end Singular.Statements
