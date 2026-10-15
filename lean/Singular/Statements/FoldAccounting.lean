import Singular.Lemmas.FoldConservation

/-! Economic fold accounting over accepted observed transactions. The carrier
is declared and is not a model calculation of the ledger minimum. -/

namespace Singular.Statements

/-- A fold consuming n booked registrations donates at least n times the
pinned registration cost. Termination donations can increase that amount.
This is the observed transaction donation, not a builder's intended payment. -/
theorem fold_donates_registration_cost (world after : World) (reachable : WorldReachable world)
    (unspent : EconomicUtxo) (transaction : EconomicTransaction)
    (accepted : foldAccepted world unspent transaction = .ok after) :
    ((foldMembers world transaction).filter FoldMember.isRegistration).length *
      world.registry.config.registrationCost ≤ transaction.transaction.donation := by
  obtain ⟨_, result, _, routing, _⟩ := foldAccepted_checks accepted
  rw [(foldRouting_accounting routing).1]
  exact fold_donation_floor reachable _ (fun b member => (foldMembers_registration member).1)

/-- Gross reward is exactly the sum of declared tips: ordinary outputs plus
fee equal actual ordinary inputs plus those tips. State value is preserved,
carriers and donation are exact, and the fee has ordinary funding. Categories
follow holdings, so this is gross allocation, not total wealth at a shared
address. Carrier values are declared; no ledger minimum or fee market is proved. -/
theorem fold_routes_every_amount (world after : World) (reachable : WorldReachable world)
    (unspent : EconomicUtxo) (transaction : EconomicTransaction)
    (accepted : foldAccepted world unspent transaction = .ok after) :
    balanced unspent.ledger transaction.transaction = true ∧
    foldStateLovelace (economicSpent unspent transaction) = foldStateLovelace transaction.outputs ∧
    transaction.transaction.donation = (foldObligations (foldMembers world transaction)).donation ∧
    foldCarrierLovelace transaction.outputs = (foldObligations (foldMembers world transaction)).carriers ∧
    foldOrdinaryLovelace transaction.outputs + transaction.transaction.fee =
      foldOrdinaryLovelace (economicSpent unspent transaction) +
        (foldObligations (foldMembers world transaction)).tips ∧
    transaction.transaction.fee ≤ foldOrdinaryLovelace (economicSpent unspent transaction) ∧
    after.treasury = world.treasury + transaction.transaction.donation ∧
    requestTagsBurned unspent transaction = true := by
  obtain ⟨_, result, _, routing, effect⟩ := foldAccepted_checks accepted
  have accounting := foldRouting_accounting routing
  have partitions := foldRouting_partitions routing
  exact ⟨accounting.2.2.1, partitions.1, accounting.1,
    fold_carrier_observed_sum _ _ _ partitions.2.1 partitions.2.2.1,
    fold_gross_reward reachable accepted, accounting.2.1,
    by rw [effect]; rfl, accounting.2.2.2⟩

/-- Ordinary outputs exceed the actual ordinary funding by at most all
consumed requests' declared tips. The fee only reduces this net gain. This is
a bound on ordinary value, not all wealth delivered at a coincident address;
no input value claim or unaccounted outside funding enters the equation. -/
theorem processors_take_at_most_the_tips (world after : World) (reachable : WorldReachable world)
    (unspent : EconomicUtxo) (transaction : EconomicTransaction)
    (accepted : foldAccepted world unspent transaction = .ok after) :
    foldOrdinaryLovelace transaction.outputs ≤
      foldOrdinaryLovelace (economicSpent unspent transaction) +
        (foldObligations (foldMembers world transaction)).tips := by
  have exact := fold_gross_reward reachable accepted
  omega

end Singular.Statements
