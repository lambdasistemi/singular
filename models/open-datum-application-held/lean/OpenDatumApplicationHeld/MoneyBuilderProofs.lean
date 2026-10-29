import OpenDatumApplicationHeld.MoneyJourneyProofs

namespace OpenDatumApplicationHeld.Money.Proofs
open Singular Lean SingularApplicationHeld

theorem public_build_outputs (h : Hash) (c : Codec) (t : TrieCommit) (r : PublishedRelease)
    (registry : PublicRegistry) (requests : List PendingRequest) (funding : FoldFunding) :
    let o := SingularApplicationHeld.buildFold h c t r registry requests funding
    o.outputs = o.after.state ::
      ((((SingularApplicationHeld.Proofs.publicPlan h c 0 requests).2 ++
        [ObservedOutput.mk ⟨0, 0⟩ funding.processorAddress
          ((requests.map PendingRequest.bid).sum + funding.ordinaryInput.lovelace - funding.fee) .empty [] none]).zipIdx 1).map
        fun (output, index) => { output with reference := ⟨funding.transactionId, index⟩ }) := by
  simp [SingularApplicationHeld.buildFold, numbered, List.zipIdx_cons, SingularApplicationHeld.Proofs.public_prepare]

end OpenDatumApplicationHeld.Money.Proofs
