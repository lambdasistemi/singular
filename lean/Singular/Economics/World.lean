import Singular.Economics.Retraction

namespace Singular

/-- Start with an actually reachable registry and no pending requests. The
existing registry reachability is a premise, not extended or restated here.
Every subsequent world results from an admitted booking, rejection or retraction. -/
inductive WorldReachable : World → Prop where
  | initial (registry : RegistryState) (reachable : Reachable registry) :
      WorldReachable ⟨registry, [], []⟩
  | booking {before after : World} (reachable : WorldReachable before)
      (transaction : RegistrationBooking) (accepted : book before transaction = .ok after) :
      WorldReachable after
  | termination {before after : World} (reachable : WorldReachable before)
      (transaction : TerminationBooking) (accepted : bookTermination before transaction = .ok after) :
      WorldReachable after
  | rejection {before after : World} (reachable : WorldReachable before)
      (unspent : EconomicUtxo) (transaction : Rejection)
      (accepted : rejectionAccepted before unspent transaction = .ok after) :
      WorldReachable after
  | retraction {before after : World} (reachable : WorldReachable before)
      (unspent : EconomicUtxo) (transaction : EconomicTransaction)
      (accepted : retractionAccepted before unspent transaction = .ok after) :
      WorldReachable after

/-- Count actual singular tags in pending outputs, by their full identity.
This reads the contents rather than assuming that every request carries one. -/
def carriedSingularCount (world : World) (key : Key) : Nat :=
  (world.terminations.flatMap (fun b => b.request.singularTags)).countP
    (fun tag => decide (tag = world.registry.config.singularTag key))

def pendingTerminationCount (world : World) (key : Key) : Nat :=
  (world.terminations.filter (fun b => b.request.key == key)).length

/-- Supply spans application custody and pending termination outputs. -/
def worldSingularSupply (world : World) (key : Key) : Nat :=
  kindCount world.registry .active key + carriedSingularCount world key

/-- The world-level law counts the singular tags outside the registry
component as well as its holdings. It does not assert registry consistency
of that component after a holding has moved into a pending termination. -/
def WorldSupplyConsistent (world : World) : Prop :=
  ∀ key, worldSingularSupply world key =
    (if trieGet world.registry.trie key = .known .active then 1 else 0)


end Singular
