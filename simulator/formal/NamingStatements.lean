import Singular.Naming
namespace Singular
namespace NamingStatements
/-! The first-release naming statement surface. Every declaration here names one
observable property of the naming profile; the frozen demo journey constants in
`Singular.Naming` make each concrete statement a nonvacuous execution of the
real transition functions. -/

/-- The naming profile defines no delete: a crafted generic release carrying a
Delete request straight into the naming transition is refused with
`naming-no-delete`, never accepted and never a generic exception. -/
theorem naming_delete_refused (state : NamingState) (source : Nat) (request : Request)
    (evidence : ReleaseEvidence) (witness : Witnesses) :
    namingStep state (Action.release source request evidence witness) = .error "naming-no-delete" := by
  rfl

/-- Approval reserves nothing: two competing `alice` claims both queue, and
after both approvals the spelling's key is still absent, with no active record
and exactly the two pending claims. -/
theorem naming_approval_reserves_nothing :
    claimedTwice.registry.entries = [] ∧ claimedTwice.records = [] ∧
    claimedTwice.claims.length = 2 ∧ (entry claimedTwice.registry aliceKey).value = none := by
  decide

/-- The first valid fold of a certified absent-key Insert activates the key and
mints exactly one application output. -/
theorem naming_absent_certified_insert_activates :
    (entry activeOnce.registry aliceKey).value = some Value.active ∧
    activeOnce.registry.applications.length = 1 := by
  decide

/-- Uniqueness is decided only at fold: a competing certified Insert for the
now-occupied key is refused with the named registry reason. -/
theorem naming_occupied_key_refuses_duplicate :
    namingFoldRequest activeOnce 2 = .error "occupied-key" := by
  rfl

/-- The successful Insert carries the four certified fixture fields unchanged
into the active naming record. -/
theorem naming_fixture_fields_preserved_on_insert :
    activeOnce.records = [{ key := aliceKey, representative := representative activeOnce.registry aliceKey, fixture := aliceFixture }] := by
  decide

/-- An unauthenticated view observes nothing about the naming state. -/
theorem naming_unauthenticated_resolve (state : NamingState) (key : Nat) :
    namingResolve state key false = .ok NamingObservation.unauthenticated := by
  rfl

/-- The demo fixture's payment destination is present and distinct from the
control address; the competing fixture's is absent. Both are well formed. -/
theorem naming_payment_destination_distinct_from_control :
    aliceFixture.paymentDestination = some 70 ∧ aliceFixture.controlAddress = 50 ∧
    aliceFixture.paymentDestination != some aliceFixture.controlAddress ∧
    wellFormedFixture aliceFixture = true ∧ wellFormedFixture otherFixture = true := by
  decide

end NamingStatements
end Singular
