import SingularApplicationHeld.Core

/-! A holder approves the exact holding address, including staking. The
26 October 2026 ruling on issue 743 keeps a folder from redirecting staking.
These fixtures exercise the model's change predicate, not a ledger history. -/

namespace SingularApplicationHeld.AddressStatements
open Singular

/-- Equal approvals bind the whole address under the explicit finite premises. -/
theorem approval_binds_address (h : Hash) (c : Codec) (r : PublishedRelease)
    (registry : TokenId) (key datum deposit : Nat) (approved proposed : Address)
    (encoding : FiniteEncoding c
      [.registrationApproval registry key approved datum deposit,
       .registrationApproval registry key proposed datum deposit])
    (collision : FiniteCollisionFree h c
      [.registrationApproval registry key approved datum deposit,
       .registrationApproval registry key proposed datum deposit])
    (same : registrationApproval h c r registry key approved datum deposit =
      registrationApproval h c r registry key proposed datum deposit) : approved = proposed := by
  have names := congrArg TokenId.name same
  have codes := collision _ (by simp) _ (by simp) names
  have preimages := encoding _ (by simp) _ (by simp) codes
  simpa using preimages

namespace Fixtures

def code : Codec
  | .state seed => [0, seed.tx, seed.index]
  | .active registry key => [1, registry.policy, registry.name, key]
  | .applicationConfiguration registry => [2, registry.policy, registry.name]
  | .registrationApproval registry key address datum deposit =>
      [3, registry.policy, registry.name, key, address.paymentCredential] ++
        (match address.stakingCredential with | none => [0] | some stake => [1, stake]) ++
        [datum, deposit]
  | .terminationApproval registry key => [4, registry.policy, registry.name, key]

def hash : Hash := fun xs => xs.foldl (fun acc n => acc * 4099 + n + 1) 1

def release : PublishedRelease := ⟨5, 99, 70, 10⟩
def registry : TokenId := ⟨10, 1⟩
def action : Change := .register ⟨2, 0⟩ 7 0 7

def holding (stake : Option Nat) : ObservedOutput :=
  ⟨⟨3, 0⟩, 99, 7, .application 11, [(activeAsset hash code registry 7, 1)], stake⟩

def booked (stake : Option Nat) : FoldObservation :=
  let output := holding stake
  let approval := registrationApproval hash code release registry 7 output.address 11 7
  let input : ObservedOutput := ⟨action.reference, 99, 9, .empty, [(approval, 1)]⟩
  let before : PublicRegistry := ⟨registry, ⟨1, 0⟩, input, []⟩
  { before, after := before,
    assets := ⟨[action.reference], [⟨output.assets⟩],
      [(approval, -1), (activeAsset hash code registry 7, 1)], []⟩,
    spentOutputs := [input], outputs := [output], changes := [action],
    signers := [], interval := ⟨0, 1⟩, fee := 0, donation := 0 }

def redirected (approved proposed : Option Nat) : FoldObservation :=
  { booked approved with outputs := [{ holding approved with stakingCredential := proposed }] }

end Fixtures
open Fixtures

/-- Both unstaked and staked approved holdings pass the actual change predicate. -/
theorem approved_addresses_accepted :
    change .none hash code release [] action (booked none) =
      .ok (trieSet [] 7 (.known .active)) ∧
    change .none hash code release [] action (booked (some 20)) =
      .ok (trieSet [] 7 (.known .active)) := by decide

/-- Keeping payment fixed cannot redirect either an unstaked or a staked holding. -/
theorem staking_redirection_refused :
    (holding none).credential = (holding (some 20)).credential ∧
    (holding (some 20)).credential = (holding (some 21)).credential ∧
    change .none hash code release [] action (redirected none (some 20)) =
      .error "operation-approval" ∧
    change .none hash code release [] action (redirected (some 20) (some 21)) =
      .error "operation-approval" := by decide

end SingularApplicationHeld.AddressStatements
