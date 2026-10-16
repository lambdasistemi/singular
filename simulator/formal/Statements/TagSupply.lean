import Singular.Lemmas.FoldFacts

/-! Pending tags in the ruled economic world. No total application-token
supply outside Singular is asserted. -/

namespace Singular.Statements

/-- The actual trie-ready tags in both pending pools equal the number of
pending requests. Application tags held by pending registrations equal their
count, and every such registration holds exactly one. This counts the tags
in the world, not all application tags minted elsewhere; those other tags
cannot replace accepted booking provenance. All world transitions are covered. -/
theorem tag_supplies_equal_pending (world : World) (reachable : WorldReachable world) :
    (world.pending.flatMap (fun b => b.request.contents.trieReadyTags)).length +
      (world.terminations.flatMap (fun b => b.request.contents.trieReadyTags)).length =
      world.pending.length + world.terminations.length ∧
    (world.pending.flatMap (fun b => b.request.contents.applicationTags)).length =
      world.pending.length ∧
    ∀ b ∈ world.pending, b.request.contents.applicationTags.length = 1 := by
  have registrations : ∀ b ∈ world.pending, b.request.contents.trieReadyTags.length = 1 := by
    intro b pending
    have tags := (booked_request_tags_commit_to_own_fields world reachable b pending).1
    simp [tags]
  have terminations : ∀ b ∈ world.terminations, b.request.contents.trieReadyTags.length = 1 := by
    intro b pending
    have tags := (booked_termination_tag_commits_to_own_operation world reachable b pending).1
    simp [tags]
  have applications : ∀ b ∈ world.pending, b.request.contents.applicationTags.length = 1 := by
    intro b pending
    obtain ⟨tag, tags, _⟩ := (booked_request_tags_commit_to_own_fields world reachable b pending).2
    simp [tags]
  exact ⟨by rw [flatMap_length_one _ _ registrations, flatMap_length_one _ _ terminations],
    flatMap_length_one _ _ applications, applications⟩

end Singular.Statements
