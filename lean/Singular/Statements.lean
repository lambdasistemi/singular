import Singular.Lemmas

/-! The public statement surface of the registry-mode model. The eleven
promises of the interface — P1, L1, S1, S2, S3, O1, T1, W1–W4 — and the seven
edge inversions, the fold inversions and the read facts. Every declaration
quantifies over states reachable from genesis by folds; over arbitrary `State`
values the supply laws are simply false. -/

namespace Singular
namespace Statements

/-- **P1** — no tree change without approval, and the pins never move. -/
theorem no_tree_change_without_approval (s : RegistryState) (r : Request) (t : Result)
    (h : Reachable s) (hok : step s r = .ok t) (htree : r.edge ≠ .witnessTerminal) :
    (∃ ap, r.approval = some ap ∧ ap.policy = s.config.applicationPolicy ∧
      ap.edge = r.edge ∧ ap.key = r.key ∧ ap.owner = r.owner ∧
      ap.destination = requestDestination r ∧
      ap.assetName = approvalAssetName ap.edge ap.key ap.owner ap.destination) ∧
    t.state.config.applicationPolicy = s.config.applicationPolicy ∧
    t.state.config.activePolicy = s.config.activePolicy ∧
    t.state.config.absentPolicy = s.config.absentPolicy ∧
    t.state.config.terminalPolicy = s.config.terminalPolicy := by
  sorry

/-- **L1** — each request is spent once and in order (the fold is a step
chain), a refusal anywhere refuses the whole batch, and no key ends the batch
booked twice. -/
theorem booked_at_most_once (s : RegistryState) (batch : List Request) (t : Result)
    (h : Reachable s) (hok : foldBatch s batch = .ok t) :
    Folds s batch t ∧
    (∀ b bs, batch = b :: bs → ∀ why, step s b = .error why → foldBatch s batch = .error why) ∧
    (∀ key, kindCount t.state .active key ≤ 1 ∧ custodyCount t.state key ≤ 1) := by
  sorry

/-- **S1** — every terminal attestation in a reachable state is about a leaf
that is terminal: no attestation of an Active, Absent or Unknown key exists. -/
theorem terminal_attestation_sound (s : RegistryState) (key : Key) (out : Nat)
    (h : Reachable s) (hmem : { key := key, kind := .terminal, output := out } ∈ s.held) :
    trieGet s.trie key = .known .terminal := by
  sorry

/-- The provenance half of S1: a terminal token enters the ledger only through
an admitted `witnessTerminal` step whose read was verified. -/
theorem terminal_mint_only_by_read (s : RegistryState) (r : Request) (t : Result)
    (hok : step s r = .ok t) (key : Key)
    (hnew : kindCount t.state .terminal key = kindCount s .terminal key + 1) :
    r.edge = .witnessTerminal ∧ trieGet s.trie key = .known .terminal ∧
      s.config.root = rootOf s.trie := by
  sorry

/-- **S2** — a terminal attestation is valid in every later state: a terminal
leaf admits no edge that moves it, and no edge burns an attestation. -/
theorem terminal_attestation_permanent (s : RegistryState) (acts : List Request) (t : Result)
    (h : Reachable s) (hok : foldBatch s acts = .ok t) (key : Key) (out : Nat)
    (hmem : { key := key, kind := .terminal, output := out } ∈ s.held) :
    { key := key, kind := .terminal, output := out } ∈ t.state.held ∧
      trieGet t.state.trie key = .known .terminal := by
  sorry

/-- **S3** — the biconditional supply law, unconditionally over reachable
states: supply is 1 iff the key is in that token's state, 0 otherwise. -/
theorem biconditional_supply_sync (s : RegistryState) (h : Reachable s) (key : Key) :
    (kindCount s .active key = 1 ↔ trieGet s.trie key = .known .active) ∧
    (kindCount s .active key = 0 ↔ trieGet s.trie key ≠ .known .active) ∧
    (custodyCount s key = 1 ↔ trieGet s.trie key = .known .absent) ∧
    (custodyCount s key = 0 ↔ trieGet s.trie key ≠ .known .absent) := by
  sorry

/-- **O1** — occupancy: a booking edge succeeds only on a key that is not
taken, and books it. -/
theorem occupancy (s : RegistryState) (r : Request) (t : Result) (h : Reachable s)
    (hok : step s r = .ok t)
    (hedge : r.edge = .insertActive ∨ r.edge = .updateActive) :
    ¬ (trieGet s.trie r.key = .known .active ∨ trieGet s.trie r.key = .known .terminal) ∧
    trieGet t.state.trie r.key = .known .active := by
  sorry

/-- **O1**, converse: a booking edge on an untaken key, with a matching
approval, succeeds. -/
theorem occupancy_free_key_succeeds (s : RegistryState) (h : Reachable s) (key : Key)
    (owner out : Nat) (hfree : trieGet s.trie key = .unknown)
    (ap : Approval) (hmatch : admitsFor s.config
      { edge := .insertActive, key := key, owner := owner, output := out } (some ap)) :
    ∃ t, step s { edge := .insertActive, key := key, owner := owner, output := out, approval := ap } = .ok t := by
  sorry

/-- **T1** — termination: on a terminal key every leaf-moving edge is refused,
forever, so the key stays terminated and is never re-booked. Supersedes the
base `over_terminal`. -/
theorem termination (s : RegistryState) (key : Key) (h : Reachable s)
    (hterm : trieGet s.trie key = .known .terminal) :
    (∀ (r : Request), r.edge ≠ .witnessTerminal → r.key = key →
        ∃ why, step s r = .error why) ∧
    (∀ (acts : List Request) (t : Result), foldBatch s acts = .ok t →
        trieGet t.state.trie key = .known .terminal) := by
  sorry

/-- **W1** — at most one active token, exactly one iff the leaf is Active. -/
theorem active_witness_unique (s : RegistryState) (h : Reachable s) (key : Key) :
    kindCount s .active key ≤ 1 ∧
    (kindCount s .active key = 1 ↔ trieGet s.trie key = .known .active) := by
  sorry

/-- **W2** — at most one absent witness, exactly one iff the leaf is Absent. -/
theorem absent_witness_unique (s : RegistryState) (h : Reachable s) (key : Key) :
    custodyCount s key ≤ 1 ∧
    (custodyCount s key = 1 ↔ trieGet s.trie key = .known .absent) := by
  sorry

/-- **W3** — terminal attestations are plural, all true, and freely mintable
while the leaf is terminal; none exists otherwise. -/
theorem terminal_witness_plural (s : RegistryState) (key : Key) (h : Reachable s)
    (hterm : trieGet s.trie key = .known .terminal) (out : Nat) :
    (∃ t, step s (Request.mk .witnessTerminal key 0 0 0 out none
        [(.terminal, 1)]) = .ok t ∧
      kindCount t.state .terminal key = kindCount s .terminal key + 1) ∧
    (∀ h ∈ s.held, h.kind = .terminal → h.key = key) ∧
    (∀ n : Nat, ∃ (u : RegistryState), Reachable u ∧
      kindCount u .terminal key = n ∧ trieGet u.trie key = .known .terminal) := by
  sorry

/-- **W4** — kind exclusion: at most one kind of witness is outstanding for a
key, so a consumer that finds one kind knows the other two do not exist. -/
theorem witness_kinds_exclude (s : RegistryState) (h : Reachable s) (key : Key) :
    (kindCount s .active key > 0 → custodyCount s key = 0 ∧ kindCount s .terminal key = 0) ∧
    (custodyCount s key > 0 → kindCount s .active key = 0 ∧ kindCount s .terminal key = 0) ∧
    (kindCount s .terminal key > 0 → kindCount s .active key = 0 ∧ custodyCount s key = 0) := by
  sorry

/-! ### Edge inversions — one per edge, exact guards and effects -/

/-- Inversion of an admitted `insertAbsent`. -/
theorem insert_absent_inversion (s : RegistryState) (r : Request) (t : Result)
    (he : r.edge = .insertAbsent) :
    step s r = .ok t ↔
    trieGet s.trie r.key = .unknown ∧
    (∃ ap, r.approval = some ap ∧ ap.policy = s.config.applicationPolicy ∧
      ap.key = r.key ∧ ap.owner = r.owner ∧
      ap.destination = requestDestination r ∧
      ap.assetName = approvalAssetName ap.edge ap.key ap.owner ap.destination) ∧
    t.state.trie = trieSet s.trie r.key (.known .absent) ∧
    t.state.config.root = rootOf (trieSet s.trie r.key (.known .absent)) ∧
    t.state.custody =
      { key := r.key, refundAddress := r.refundAddress, value := r.deposit } :: s.custody ∧
    t.state.held = s.held ∧ t.mint = [(.absent, 1)] ∧ t.paid = [] := by
  sorry

/-- Inversion of an admitted `insertActive`. -/
theorem insert_active_inversion (s : RegistryState) (r : Request) (t : Result)
    (he : r.edge = .insertActive) :
    step s r = .ok t ↔
    trieGet s.trie r.key = .unknown ∧
    (∃ ap, r.approval = some ap ∧ ap.policy = s.config.applicationPolicy ∧
      ap.key = r.key ∧ ap.owner = r.owner ∧
      ap.destination = requestDestination r ∧
      ap.assetName = approvalAssetName ap.edge ap.key ap.owner ap.destination) ∧
    t.state.trie = trieSet s.trie r.key (.known .active) ∧
    t.state.config.root = rootOf (trieSet s.trie r.key (.known .active)) ∧
    t.state.custody = s.custody ∧
    t.state.held = { key := r.key, kind := .active, output := r.output } :: s.held ∧
    t.mint = [(.active, 1)] ∧ t.paid = [] := by
  sorry

/-- Inversion of an admitted `updateActive` — booking a witnessed name; the
consumed absent token's value is paid to the refund address its custody datum
records (R-ADA). -/
theorem update_active_inversion (s : RegistryState) (r : Request) (t : Result)
    (he : r.edge = .updateActive) (c : Custody)
    (hc : s.custody.find? (·.key == r.key) = some c) :
    step s r = .ok t ↔
    trieGet s.trie r.key = .known .absent ∧ c.key = r.key ∧
    (∃ ap, r.approval = some ap ∧ ap.policy = s.config.applicationPolicy ∧
      ap.key = r.key ∧ ap.owner = r.owner ∧
      ap.destination = requestDestination r ∧
      ap.assetName = approvalAssetName ap.edge ap.key ap.owner ap.destination) ∧
    t.state.trie = trieSet s.trie r.key (.known .active) ∧
    t.state.config.root = rootOf (trieSet s.trie r.key (.known .active)) ∧
    t.state.custody = s.custody.filter (·.key != r.key) ∧
    t.state.held = { key := r.key, kind := .active, output := r.output } :: s.held ∧
    t.mint = [(.absent, -1), (.active, 1)] ∧
    t.paid = [(c.refundAddress, c.value)] := by
  sorry

/-- Inversion of an admitted `updateTerminal` — retirement completes here. -/
theorem update_terminal_inversion (s : RegistryState) (r : Request) (t : Result)
    (he : r.edge = .updateTerminal) :
    step s r = .ok t ↔
    trieGet s.trie r.key = .known .active ∧
    (∃ ap, r.approval = some ap ∧ ap.policy = s.config.applicationPolicy ∧
      ap.key = r.key ∧ ap.owner = r.owner ∧
      ap.destination = requestDestination r ∧
      ap.assetName = approvalAssetName ap.edge ap.key ap.owner ap.destination) ∧
    t.state.trie = trieSet s.trie r.key (.known .terminal) ∧
    t.state.config.root = rootOf (trieSet s.trie r.key (.known .terminal)) ∧
    t.state.custody = s.custody ∧
    t.state.held = s.held.filter fun h => !(h.key == r.key && h.kind == .active) ∧
    t.mint = [(.active, -1)] ∧ t.paid = [] := by
  sorry

/-- Inversion of an admitted `deleteAbsent` — the witness retracts, the deposit
returns to the inserter (R-ADA), and the key reads `Unknown` again. -/
theorem delete_absent_inversion (s : RegistryState) (r : Request) (t : Result)
    (he : r.edge = .deleteAbsent) (c : Custody)
    (hc : s.custody.find? (·.key == r.key) = some c) :
    step s r = .ok t ↔
    trieGet s.trie r.key = .known .absent ∧ c.key = r.key ∧
    (∃ ap, r.approval = some ap ∧ ap.policy = s.config.applicationPolicy ∧
      ap.key = r.key ∧ ap.owner = r.owner ∧
      ap.destination = requestDestination r ∧
      ap.assetName = approvalAssetName ap.edge ap.key ap.owner ap.destination) ∧
    t.state.trie = trieSet s.trie r.key .unknown ∧
    t.state.config.root = rootOf (trieSet s.trie r.key .unknown) ∧
    t.state.custody = s.custody.filter (·.key != r.key) ∧
    t.state.held = s.held ∧
    t.mint = [(.absent, -1)] ∧ t.paid = [(c.refundAddress, c.value)] := by
  sorry

/-- Inversion of an admitted `deleteActive` — the key reads `Unknown` again and
may be inserted again as the same key. -/
theorem delete_active_inversion (s : RegistryState) (r : Request) (t : Result)
    (he : r.edge = .deleteActive) :
    step s r = .ok t ↔
    trieGet s.trie r.key = .known .active ∧
    (∃ ap, r.approval = some ap ∧ ap.policy = s.config.applicationPolicy ∧
      ap.key = r.key ∧ ap.owner = r.owner ∧
      ap.destination = requestDestination r ∧
      ap.assetName = approvalAssetName ap.edge ap.key ap.owner ap.destination) ∧
    t.state.trie = trieSet s.trie r.key .unknown ∧
    t.state.config.root = rootOf (trieSet s.trie r.key .unknown) ∧
    t.state.custody = s.custody ∧
    t.state.held = s.held.filter fun h => !(h.key == r.key && h.kind == .active) ∧
    t.mint = [(.active, -1)] ∧ t.paid = [] := by
  sorry

/-- Inversion of an admitted `witnessTerminal` — the read: the leaf, the root
and custody are unchanged, one attestation is minted to the named output. -/
theorem witness_terminal_inversion (s : RegistryState) (r : Request) (t : Result)
    (he : r.edge = .witnessTerminal) :
    step s r = .ok t ↔
    trieGet s.trie r.key = .known .terminal ∧ s.config.root = rootOf s.trie ∧
    t.state.trie = s.trie ∧ t.state.config = s.config ∧ t.state.custody = s.custody ∧
    t.state.held = { key := r.key, kind := .terminal, output := r.output } :: s.held ∧
    t.mint = [(.terminal, 1)] ∧ t.paid = [] := by
  sorry

/-! ### Fold and read facts -/

/-- A zero-request batch is always refused. -/
theorem empty_fold_error (s : RegistryState) (batch : List Request)
    (h : batch = []) : foldBatch s batch = .error "empty-fold" := by
  sorry

/-- A fold succeeds iff every request applies in order and the claimed mint
matches the summed delta of the folded edges. -/
theorem fold_batch_cons (s : RegistryState) (b : Request) (bs : List Request) (t : Result) :
    foldBatch s (b :: bs) = .ok t ↔
    ∃ m r, step s b = .ok m ∧ foldBatch m.state bs = .ok r ∧
      t = { state := r.state, mint := deltaPlus m.mint r.mint, paid := m.paid ++ r.paid } ∧
      deltaSame (deltaPlus b.claimed (bs.foldl (fun acc b => deltaPlus acc b.claimed) []))
        (deltaPlus (delta b.edge) (bs.foldl (fun acc b => deltaPlus acc (delta b.edge)) [])) := by
  sorry

/-- A read changes nothing: the leaf, the root and custody survive an admitted
`witnessTerminal` step unchanged. -/
theorem read_changes_nothing (s : RegistryState) (r : Request) (t : Result)
    (he : r.edge = .witnessTerminal) (hok : step s r = .ok t) :
    t.state.trie = s.trie ∧ t.state.config = s.config ∧ t.state.custody = s.custody := by
  sorry

/-- A read's verification is exactly the intermediate leaf being the claimed
terminal state, against a committed root. -/
theorem readAt_true_iff (s : RegistryState) (key : Key) :
    readAt s 0 key .terminal = true ↔
      s.config.root = rootOf s.trie ∧ trieGet s.trie key = .known .terminal := by
  sorry

end Statements
end Singular
