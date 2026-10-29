import SingularApplicationHeld.MintedProofs

/-! The application-held Singular model beside the current one, to be removed
with it in #743. -/
set_option maxHeartbeats 2000000
set_option maxRecDepth 8192
namespace SingularApplicationHeld.Proofs
open Singular Lean

local instance : LawfulBEq OutRef where
  eq_of_beq := by
    intro a b same
    cases a
    cases b
    simp_all [BEq.beq, instBEqOutRef.beq]
  rfl := by
    intro a
    cases a
    simp [BEq.beq, instBEqOutRef.beq]

local instance : LawfulBEq TokenId where
  eq_of_beq := token_eq _ _
  rfl := by
    intro a
    cases a
    simp [BEq.beq, instBEqTokenId.beq]

local instance : ReflBEq Leaf where
  rfl := by
    intro leaf
    cases leaf with
    | unknown => rfl
    | known state => cases state <;> rfl

/-- Proof helper: a physical output compares equal to itself. -/
theorem public_output_refl (output : ObservedOutput) : (output == output) = true := by
  cases output with
  | mk reference credential lovelace datum assets stakingCredential =>
    have rr : instBEqOutRef.beq reference reference = true := by
      change (reference == reference) = true
      simp
    have aa : assets.beq assets = true := by
      change (assets == assets) = true
      simp
    cases stakingCredential <;> cases datum <;> simp [BEq.beq, Option.instBEq.beq, instBEqObservedOutput.beq, instBEqOutputDatum.beq,
      instBEqApplicationParameters.beq, rr, aa]

local instance : ReflBEq ObservedOutput where
  rfl := public_output_refl _

/-- Proof helper: the unmutated application selector preserves its guard. -/
@[simp] theorem appGuard_none (site : AppGuard) (b : Bool) : appGuard .none site b = b := by rfl

/-- Proof helper: a request's allocated new holding. -/
def publicHolding (h : Hash) (c : Codec) (d : RegistrationData) : ObservedOutput :=
  ⟨⟨0, 0⟩, d.holdingAddress.paymentCredential, d.deposit, .application d.initialDatum,
    [(activeAsset h c d.registry d.key, 1)], d.holdingAddress.stakingCredential⟩

/-- Proof helper: the builder's order with an explicit holding offset. -/
def publicPlan (h : Hash) (c : Codec) : Nat → List PendingRequest → List Change × List ObservedOutput
  | _, [] => ([], [])
  | n, .registration o d :: rest =>
      let tail := publicPlan h c (n + 1) rest
      (.register o.reference d.key (n + 1) d.deposit :: tail.1, publicHolding h c d :: tail.2)
  | n, .termination o _ key :: rest =>
      let tail := publicPlan h c n rest
      (.terminate o.reference key :: tail.1, tail.2)

/-- Proof helper: append-based allocation equals the recursive plan. -/
theorem public_prepare_acc (h : Hash) (c : Codec) (requests : List PendingRequest)
    (changes : List Change) (holdings : List ObservedOutput) :
    requests.foldl (fun (cs, hs) request => match request with
      | .registration o d =>
        (cs ++ [.register o.reference d.key (hs.length + 1) d.deposit],
         hs ++ [publicHolding h c d])
      | .termination o _ key => (cs ++ [.terminate o.reference key], hs)) (changes, holdings) =
      (changes ++ (publicPlan h c holdings.length requests).1,
       holdings ++ (publicPlan h c holdings.length requests).2) := by
  induction requests generalizing changes holdings with
  | nil => simp [publicPlan]
  | cons request rest ih =>
    cases request <;> simp [List.foldl_cons, publicPlan, ih, List.append_assoc]

/-- Proof helper: exact correspondence to the frozen allocator. -/
theorem public_prepare (h : Hash) (c : Codec) (requests : List PendingRequest) :
    prepareChanges h c requests = publicPlan h c 0 requests := by
  simpa [prepareChanges, publicHolding] using public_prepare_acc h c requests [] []

/-- Proof helper: allocation retains every public request reference. -/
theorem public_plan_refs (h : Hash) (c : Codec) (n : Nat) (requests : List PendingRequest) :
    ((publicPlan h c n requests).1.map Change.reference) = requests.map (·.output.reference) := by
  induction requests generalizing n with
  | nil => rfl
  | cons request rest ih => cases request <;> simp [publicPlan, Change.reference, PendingRequest.output, ih]

/-- Proof helper: allocation retains the logical keys. -/
theorem public_plan_keys (h : Hash) (c : Codec) (n : Nat) (requests : List PendingRequest) :
    ((publicPlan h c n requests).1.map Change.key) = requests.map PendingRequest.key := by
  induction requests generalizing n with
  | nil => rfl
  | cons request rest ih => cases request <;> simp [publicPlan, Change.key, PendingRequest.key, ih]

/-- Proof helper: holding value is the sum of committed registration deposits. -/
theorem public_plan_value (h : Hash) (c : Codec) (n : Nat) (requests : List PendingRequest) :
    ((publicPlan h c n requests).2.map (·.lovelace)).sum =
      (requests.map fun r => match r with | .registration _ d => d.deposit | .termination .. => 0).sum := by
  induction requests generalizing n with
  | nil => rfl
  | cons request rest ih => cases request <;> simp [publicPlan, publicHolding, ih]

/-- Proof helper: renumbering does not change the value of outputs. -/
theorem public_numbered_value (tx : Nat) (outputs : List ObservedOutput) :
    ((numbered tx outputs).map (·.lovelace)).sum = (outputs.map (·.lovelace)).sum := by
  unfold numbered
  simp only [List.map_map, Function.comp_def]
  change (outputs.zipIdx.map ((fun o : ObservedOutput => o.lovelace) ∘ Prod.fst)).sum = _
  rw [← List.map_map, List.zipIdx_map_fst]

/-- Proof helper: every public input is spent in the constructed view. -/
theorem public_build_spent (h : Hash) (c : Codec) (t : TrieCommit) (r : PublishedRelease)
    (registry : PublicRegistry) (requests : List PendingRequest) (funding : FoldFunding) :
    (buildFold h c t r registry requests funding).assets.spent =
      (registry.state :: requests.map PendingRequest.output ++ [funding.ordinaryInput]).map (·.reference) := by
  rfl

/-- Proof helper: construction keeps the actual inputs. -/
theorem public_build_inputs (h : Hash) (c : Codec) (t : TrieCommit) (r : PublishedRelease)
    (registry : PublicRegistry) (requests : List PendingRequest) (funding : FoldFunding) :
    (buildFold h c t r registry requests funding).spentOutputs =
      registry.state :: requests.map PendingRequest.output ++ [funding.ordinaryInput] := by
  rfl

/-- Proof helper: a public fold has no required signer. -/
theorem public_build_signers (h : Hash) (c : Codec) (t : TrieCommit) (r : PublishedRelease)
    (registry : PublicRegistry) (requests : List PendingRequest) (funding : FoldFunding) :
    (buildFold h c t r registry requests funding).signers = [] := by
  rfl

/-- Proof helper: construction uses the allocator's exact ordered changes. -/
theorem public_build_changes (h : Hash) (c : Codec) (t : TrieCommit) (r : PublishedRelease)
    (registry : PublicRegistry) (requests : List PendingRequest) (funding : FoldFunding) :
    (buildFold h c t r registry requests funding).changes = (publicPlan h c 0 requests).1 := by
  change (prepareChanges h c requests).1 = _
  rw [public_prepare]

/-- Proof helper: projected values commute with arbitrary output numbering. -/
theorem public_numbering_value (tx n : Nat) (outputs : List ObservedOutput) :
    ((outputs.zipIdx n |>.map fun (o, i) => { o with reference := ⟨tx, i⟩ }).map (·.lovelace)).sum =
      (outputs.map (·.lovelace)).sum := by
  simp only [List.map_map, Function.comp_def]
  change ((outputs.zipIdx n).map ((fun o : ObservedOutput => o.lovelace) ∘ Prod.fst)).sum = _
  rw [← List.map_map, List.zipIdx_map_fst]

/-- Proof helper: continuing the root changes no output value. -/
theorem public_build_value (h : Hash) (c : Codec) (t : TrieCommit) (r : PublishedRelease)
    (registry : PublicRegistry) (requests : List PendingRequest) (funding : FoldFunding) :
    ((buildFold h c t r registry requests funding).outputs.map (·.lovelace)).sum =
      registry.state.lovelace + ((publicPlan h c 0 requests).2.map (·.lovelace)).sum +
      ((requests.map PendingRequest.bid).sum + funding.ordinaryInput.lovelace - funding.fee) := by
  simp only [buildFold, Id.run, pure, numbered, List.cons_append, List.zipIdx_cons,
    List.map_cons, List.drop_succ_cons, List.drop_zero, List.head?_cons, Option.getD_some,
    List.sum_cons]
  rw [public_numbering_value]
  simp [public_prepare, List.map_append, List.sum_append_nat, Nat.add_assoc]

/-- Proof helper: the bid and protected deposit partition each authentic request value. -/
theorem public_request_value (h : Hash) (c : Codec) (decode : DecodeApplication)
    (r : PublishedRelease) (requests : List PendingRequest)
    (authentic : ∀ request ∈ requests, pendingAuthentic h c decode r request = true) :
    ((requests.map PendingRequest.output).map (·.lovelace)).sum =
      (requests.map PendingRequest.bid).sum +
      (requests.map fun request => match request with
        | .registration _ data => data.deposit | .termination .. => 0).sum := by
  induction requests with
  | nil => rfl
  | cons request rest ih =>
    have tail := ih (fun request member => authentic request (List.mem_cons_of_mem _ member))
    have here := authentic request (by simp)
    cases request with
    | registration output data =>
      have funded : data.deposit ≤ output.lovelace := by
        simp only [pendingAuthentic, registrationShape, appGuard_none, Bool.and_eq_true,
          decide_eq_true_eq] at here
        exact here.2.2
      simp only [List.map_cons, List.sum_cons, PendingRequest.output, PendingRequest.bid]
      omega
    | termination output registry key =>
      simp only [List.map_cons, List.sum_cons, PendingRequest.output, PendingRequest.bid]
      omega

/-- Proof helper: ordinary fee funding makes public construction balance exactly. -/
theorem public_build_balance (h : Hash) (c : Codec) (t : TrieCommit) (r : PublishedRelease)
    (registry : PublicRegistry) (requests : List PendingRequest) (funding : FoldFunding)
    (p : PublicFoldPremises h c t decode r registry requests funding) :
    let o := buildFold h c t r registry requests funding
    observedBalance o.spentOutputs o.outputs o.fee o.donation = true := by
  have fee := p.2.2.2.2.2.2.1
  have authentic : ∀ request ∈ requests, pendingAuthentic h c decode r request = true := by
    intro request member
    exact (p.2.2.2.2.2.2.2.2.2.2.2.2 request member).2.1
  have split := public_request_value h c decode r requests authentic
  change observedBalance (registry.state :: requests.map PendingRequest.output ++ [funding.ordinaryInput])
    (buildFold h c t r registry requests funding).outputs funding.fee 0 = true
  simp only [observedBalance, beq_iff_eq, public_build_value,
    List.map_cons, List.map_append, List.map_nil, List.sum_cons, List.sum_append_nat, List.sum_nil,
    public_plan_value]
  omega

/-- Proof helper: a request contributes exactly one change. -/
theorem public_plan_length (h : Hash) (c : Codec) (n : Nat) (requests : List PendingRequest) :
    (publicPlan h c n requests).1.length = requests.length := by
  induction requests generalizing n with
  | nil => rfl
  | cons request rest ih => cases request <;> simp [publicPlan, ih]

/-- Proof helper: all created holdings are the request-derived carriers. -/
theorem public_plan_holdings (h : Hash) (c : Codec) (n : Nat) (requests : List PendingRequest) :
    (publicPlan h c n requests).2 = requests.filterMap (fun request => match request with
      | .registration _ data => some (publicHolding h c data) | .termination .. => none) := by
  induction requests generalizing n with
  | nil => rfl
  | cons request rest ih => cases request <;> simp [publicPlan, ih]

/-- Proof helper: every allocated registration index follows the existing prefix. -/
theorem public_plan_index_bounds (h : Hash) (c : Codec) (n : Nat) (requests : List PendingRequest)
    (reference : OutRef) (key : Key) (index deposit : Nat)
    (member : Change.register reference key index deposit ∈ (publicPlan h c n requests).1) :
    n < index ∧ index ≤ n + (publicPlan h c n requests).2.length := by
  induction requests generalizing n with
  | nil => simp [publicPlan] at member
  | cons request rest ih =>
    cases request with
    | registration output data =>
      simp only [publicPlan, List.mem_cons] at member
      rcases member with same | member
      · cases same
        simp [publicPlan]
      · have bounds := ih (n + 1) member
        simp only [publicPlan, List.length_cons]
        omega
    | termination output registry k =>
      simp only [publicPlan, List.mem_cons,  reduceCtorEq, false_or] at member
      exact ih n member

/-- Proof helper: an allocated registration index identifies its source request and carrier. -/
theorem public_plan_registration (h : Hash) (c : Codec) (n : Nat) (requests : List PendingRequest)
    (reference : OutRef) (key : Key) (index deposit : Nat)
    (member : Change.register reference key index deposit ∈ (publicPlan h c n requests).1) :
    ∃ output data, PendingRequest.registration output data ∈ requests ∧
      reference = output.reference ∧ key = data.key ∧ deposit = data.deposit ∧
      (publicPlan h c n requests).2[index - (n + 1)]? = some (publicHolding h c data) := by
  induction requests generalizing n with
  | nil => simp [publicPlan] at member
  | cons request rest ih =>
    cases request with
    | registration output data =>
      simp only [publicPlan, List.mem_cons] at member
      rcases member with same | member
      · cases same
        exact ⟨output, data, by simp, rfl, rfl, rfl, by simp [publicPlan]⟩
      · obtain ⟨o, d, present, referenceEq, keyEq, depositEq, carrier⟩ := ih (n + 1) member
        have bounds := public_plan_index_bounds h c (n + 1) rest reference key index deposit member
        refine ⟨o, d, List.mem_cons_of_mem _ present, referenceEq, keyEq, depositEq, ?_⟩
        have offset : index - (n + 1) = (index - (n + 1 + 1)) + 1 := by omega
        simp only [publicPlan, offset, List.getElem?_cons_succ]
        exact carrier
    | termination output registry k =>
      simp only [publicPlan, List.mem_cons,  reduceCtorEq, false_or] at member
      obtain ⟨o, d, present, referenceEq, keyEq, depositEq, carrier⟩ := ih n member
      exact ⟨o, d, List.mem_cons_of_mem _ present, referenceEq, keyEq, depositEq, carrier⟩

/-- Proof helper: an allocated termination identifies its public source request. -/
theorem public_plan_termination (h : Hash) (c : Codec) (n : Nat) (requests : List PendingRequest)
    (reference : OutRef) (key : Key)
    (member : Change.terminate reference key ∈ (publicPlan h c n requests).1) :
    ∃ output registry, PendingRequest.termination output registry key ∈ requests ∧ reference = output.reference := by
  induction requests generalizing n with
  | nil => simp [publicPlan] at member
  | cons request rest ih =>
    cases request with
    | registration output data =>
      simp only [publicPlan, List.mem_cons,  reduceCtorEq, false_or] at member
      obtain ⟨o, registry, present, same⟩ := ih (n + 1) member
      exact ⟨o, registry, List.mem_cons_of_mem _ present, same⟩
    | termination output registry k =>
      simp only [publicPlan, List.mem_cons] at member
      rcases member with same | member
      · cases same
        exact ⟨output, registry, by simp, rfl⟩
      · obtain ⟨o, registry, present, same⟩ := ih n member
        exact ⟨o, registry, List.mem_cons_of_mem _ present, same⟩

/-- Proof helper: no two registration references share an allocated output index. -/
theorem public_plan_separate (h : Hash) (c : Codec) (n : Nat) (requests : List PendingRequest)
    (first second : OutRef) (firstKey secondKey : Key) (index firstDeposit secondDeposit : Nat)
    (one : Change.register first firstKey index firstDeposit ∈ (publicPlan h c n requests).1)
    (two : Change.register second secondKey index secondDeposit ∈ (publicPlan h c n requests).1) :
    first = second := by
  induction requests generalizing n with
  | nil => simp [publicPlan] at one
  | cons request rest ih =>
    cases request with
    | registration output data =>
      simp only [publicPlan, List.mem_cons] at one two
      rcases one with firstSame | firstMember <;> rcases two with secondSame | secondMember
      · cases firstSame
        cases secondSame
        rfl
      · cases firstSame
        have bounds := public_plan_index_bounds h c (n + 1) rest second secondKey (n + 1) secondDeposit secondMember
        omega
      · cases secondSame
        have bounds := public_plan_index_bounds h c (n + 1) rest first firstKey (n + 1) firstDeposit firstMember
        omega
      · exact ih (n + 1) firstMember secondMember
    | termination output registry key =>
      simp only [publicPlan, List.mem_cons,  reduceCtorEq, false_or] at one two
      exact ih n one two

/-- Proof helper: allocated changes meet the separate-carrier guard. -/
theorem public_build_separate (h : Hash) (c : Codec) (t : TrieCommit) (r : PublishedRelease)
    (registry : PublicRegistry) (requests : List PendingRequest) (funding : FoldFunding)
    (reference : OutRef) (key : Key) (index deposit : Nat)
    (member : Change.register reference key index deposit ∈
      (buildFold h c t r registry requests funding).changes) :
    separateHolding (buildFold h c t r registry requests funding) reference index = true := by
  rw [public_build_changes] at member
  apply List.all_eq_true.mpr
  intro action present
  rw [public_build_changes] at present
  cases action with
  | terminate => rfl
  | register other otherKey otherIndex otherDeposit =>
    simp only [Bool.or_eq_true]
    by_cases same : otherIndex = index
    · subst otherIndex
      have refs := public_plan_separate h c 0 requests other reference otherKey key index otherDeposit deposit present member
      exact Or.inl (by simpa using refs)
    · exact Or.inr (by simp [same])

/-- Proof helper: continuation preserves state address, value and asset contents. -/
theorem public_build_state (h : Hash) (c : Codec) (t : TrieCommit) (r : PublishedRelease)
    (registry : PublicRegistry) (requests : List PendingRequest) (funding : FoldFunding) :
    let o := buildFold h c t r registry requests funding
    o.before = registry ∧ o.after.identity = registry.identity ∧ o.after.seed = registry.seed ∧
    o.after.state.credential = registry.state.credential ∧
    o.after.state.lovelace = registry.state.lovelace ∧
    o.after.state.assets = registry.state.assets ∧
    o.after.state.reference = ⟨funding.transactionId, 0⟩ ∧
    o.after.state.datum = .root (t o.after.trie) := by
  simp [buildFold, numbered, List.zipIdx_cons]

/-- Proof helper: every constructed output belongs to the requested new transaction. -/
theorem public_build_output_reference (h : Hash) (c : Codec) (t : TrieCommit) (r : PublishedRelease)
    (registry : PublicRegistry) (requests : List PendingRequest) (funding : FoldFunding)
    (output : ObservedOutput)
    (member : output ∈ (buildFold h c t r registry requests funding).outputs) :
    output.reference.tx = funding.transactionId := by
  simp only [buildFold, Id.run, pure, numbered, List.cons_append, List.zipIdx_cons,
    List.map_cons, List.drop_succ_cons, List.drop_zero, List.head?_cons, Option.getD_some,
    List.mem_cons] at member
  rcases member with same | member
  · subst output
    rfl
  · obtain ⟨entry, _, same⟩ := List.mem_map.mp member
    subst output
    rfl

/-- Proof helper: no new output reference is among the construction's spent inputs. -/
theorem public_build_output_not_spent (h : Hash) (c : Codec) (t : TrieCommit) (r : PublishedRelease)
    (registry : PublicRegistry) (requests : List PendingRequest) (funding : FoldFunding)
    (fresh : ∀ input ∈ registry.state :: requests.map PendingRequest.output ++ [funding.ordinaryInput],
      input.reference.tx ≠ funding.transactionId)
    (output : ObservedOutput)
    (member : output ∈ (buildFold h c t r registry requests funding).outputs) :
    output.reference ∉ (buildFold h c t r registry requests funding).assets.spent := by
  intro spent
  rw [public_build_spent] at spent
  obtain ⟨input, inputMember, referenceEq⟩ := List.mem_map.mp spent
  apply fresh input inputMember
  rw [referenceEq]
  exact public_build_output_reference h c t r registry requests funding output member

/-- Proof helper: every new holding satisfies the no-new-output-consumed guard. -/
theorem public_build_no_new_consumed (h : Hash) (c : Codec) (t : TrieCommit) (r : PublishedRelease)
    (registry : PublicRegistry) (requests : List PendingRequest) (funding : FoldFunding)
    (p : PublicFoldPremises h c t decode r registry requests funding) :
    let o := buildFold h c t r registry requests funding
    (o.changes.filterMap (fun action => match action with
      | .register _ _ index _ => holdingAt o index | .terminate .. => none)).all
      (fun output => !o.assets.spent.contains output.reference) = true := by
  let o := buildFold h c t r registry requests funding
  apply List.all_eq_true.mpr
  intro output member
  obtain ⟨action, _, holding⟩ := List.mem_filterMap.mp member
  have inOutputs : output ∈ o.outputs := by
    cases action with
    | terminate => simp at holding
    | register reference key index deposit =>
      exact List.mem_of_getElem? holding
  have absent := public_build_output_not_spent h c t r registry requests funding
    p.2.2.2.2.2.2.2.2.2.2.2.1 output inOutputs
  simpa using absent

/-- Proof helper: the genuine before state is spent exactly once. -/
theorem public_build_before_guard (h : Hash) (c : Codec) (t : TrieCommit) (r : PublishedRelease)
    (registry : PublicRegistry) (requests : List PendingRequest) (funding : FoldFunding)
    (p : PublicFoldPremises h c t decode r registry requests funding) :
    let o := buildFold h c t r registry requests funding
    (recognizeState .none h c r registry.seed registry.state &&
      registry.state.datum == .root (t registry.trie) &&
      o.assets.spent.count registry.state.reference == 1 && o.spentOutputs.contains registry.state) = true := by
  rcases p with ⟨_, _, _, recognized, _, root, _, _, _, _, distinct, _, _⟩
  dsimp only
  rw [public_build_spent, public_build_inputs]
  have count : (registry.state.reference :: requests.map (·.output.reference) ++
      [funding.ordinaryInput.reference]).count registry.state.reference = 1 := by
    rw [distinct.count]
    simp
  have actualCount : ((registry.state :: requests.map PendingRequest.output ++ [funding.ordinaryInput]).map
      (·.reference)).count registry.state.reference = 1 := by
    simpa only [List.map_cons, List.map_append, List.map_map, Function.comp_def,
      List.map_nil] using count
  rw [actualCount]
  simp only [recognized, root, List.cons_append, List.contains_cons, public_output_refl]
  simp [BEq.beq, instBEqOutputDatum.beq]

/-- Proof helper: construction adds only the request approvals to its exact active delta. -/
theorem public_build_mint (h : Hash) (c : Codec) (t : TrieCommit) (r : PublishedRelease)
    (registry : PublicRegistry) (requests : List PendingRequest) (funding : FoldFunding) :
    let o := buildFold h c t r registry requests funding
    o.assets.mint = expectedDelta h c o ++ requests.map (fun request => (
      (match request with
       | .registration _ data => registrationAsset h c r data
       | .termination _ registry key => terminationApproval h c r registry key), (-1 : Int))) := by
  rfl

/-- Proof helper: a different policy cannot change any quantity under this policy. -/
theorem public_other_policy_filter (entries : List (TokenId × Int)) (asset : TokenId)
    (policy : Nat) (own : asset.policy = policy)
    (other : ∀ entry ∈ entries, entry.1.policy ≠ policy) :
    entries.filter (fun entry => entry.1 == asset) = [] := by
  apply List.filter_eq_nil_iff.mpr
  intro entry member same
  have equal := token_eq _ _ same
  exact other entry member (by rw [equal, own])

/-- Proof helper: the constructed transaction has the exact whole state-policy delta. -/
theorem public_build_whole_policy (h : Hash) (c : Codec) (t : TrieCommit) (r : PublishedRelease)
    (registry : PublicRegistry) (requests : List PendingRequest) (funding : FoldFunding)
    (identity : registry.identity = stateAsset h c r registry.seed)
    (policies : r.applicationPolicy ≠ r.statePolicy) :
    wholePolicyDelta h c (buildFold h c t r registry requests funding) = true := by
  let o := buildFold h c t r registry requests funding
  let approvals := requests.map (fun request => (
    (match request with
     | .registration _ data => registrationAsset h c r data
     | .termination _ registry key => terminationApproval h c r registry key), (-1 : Int)))
  have mint : o.assets.mint = expectedDelta h c o ++ approvals := public_build_mint ..
  have other : ∀ entry ∈ approvals, entry.1.policy ≠ registry.identity.policy := by
    intro entry member
    obtain ⟨request, _, same⟩ := List.mem_map.mp member
    subst entry
    cases request <;> simpa [registrationAsset, registrationApproval, terminationApproval, identity, stateAsset] using policies
  apply List.all_eq_true.mpr
  intro asset _
  by_cases own : asset.policy = registry.identity.policy
  · have noApprovals := public_other_policy_filter approvals asset registry.identity.policy own other
    change (asset.policy != registry.identity.policy ||
      SingularApplicationHeld.Assets.mintQty o.assets asset == ((expectedDelta h c o).filter (fun entry => entry.1 == asset) |>.map (·.2)).sum) = true
    simp only [SingularApplicationHeld.Assets.mintQty, mint, List.filter_append, noApprovals, List.append_nil]
    simp
  · change (asset.policy != registry.identity.policy || _) = true
    simp [own]

/-- Proof helper: distinct public references stay distinct after allocation. -/
theorem public_build_distinct (h : Hash) (c : Codec) (t : TrieCommit) (r : PublishedRelease)
    (registry : PublicRegistry) (requests : List PendingRequest) (funding : FoldFunding)
    (distinct : (requests.map (·.output.reference)).Nodup) :
    ((buildFold h c t r registry requests funding).changes.map Change.reference).Nodup := by
  simpa only [public_build_changes, public_plan_refs] using distinct

/-- Proof helper: construction never loses all changes from a nonempty request set. -/
theorem public_build_nonempty (h : Hash) (c : Codec) (t : TrieCommit) (r : PublishedRelease)
    (registry : PublicRegistry) (requests : List PendingRequest) (funding : FoldFunding)
    (nonempty : requests ≠ []) :
    (buildFold h c t r registry requests funding).changes.isEmpty = false := by
  rw [public_build_changes]
  cases requests with
  | nil => exact (nonempty rfl).elim
  | cons request rest => cases request <;> rfl

/-- Proof helper: the remaining obligation for public construction is fold acceptance. -/
theorem public_conclusion_of_fold (h : Hash) (c : Codec) (t : TrieCommit) (q : Query)
    (p : PublicPremises h c t q)
    (accepted : fold .none h c t q.release
      (buildFold h c t q.release q.observation.before q.requests q.funding) = true) :
    PublicConclusion .none h c t q := by
  exact ⟨accepted, public_build_signers .., public_build_spent ..,
    public_build_balance h c t q.release q.observation.before q.requests q.funding p.1⟩

/-- Proof helper: constructed acceptance supplies the independent effects and frame. -/
theorem public_effects_of_conclusion (h : Hash) (c : Codec) (t : TrieCommit) (q : Query)
    (conclusion : PublicConclusion .none h c t q) :
    PublicConclusion .none h c t q ∧
      batchEffects t (buildFold h c t q.release q.observation.before q.requests q.funding) ∧
      FoldFrame (buildFold h c t q.release q.observation.before q.requests q.funding) := by
  let o := buildFold h c t q.release q.observation.before q.requests q.funding
  have effects := fold_effect h c t q.release o conclusion.1
  refine ⟨conclusion, effects, ?_⟩
  intro key outside
  rw [effects.1]
  exact target_frame o.changes o.before.trie key outside

/-- Proof helper: isolate the three outstanding acceptance obligations.
All other fold guards and the balance/no-signature/input/effect/frame conclusions
follow from the frozen public premises and the construction. -/
theorem public_conclusion_of_remaining (h : Hash) (c : Codec) (t : TrieCommit) (q : Query)
    (p : PublicPremises h c t q)
    (pairing : exactPairing q.release
      (buildFold h c t q.release q.observation.before q.requests q.funding) = true)
    (changes : let o := buildFold h c t q.release q.observation.before q.requests q.funding
      changeBatch .none h c q.release o = .ok o.after.trie)
    (continuation : let o := buildFold h c t q.release q.observation.before q.requests q.funding
      (o.outputs.filter fun output => quantity output o.before.identity > 0) = [o.after.state]) :
    PublicConclusion .none h c t q := by
  let registry := q.observation.before
  let o := buildFold h c t q.release registry q.requests q.funding
  obtain ⟨_, afterIdentity, afterSeed, afterAddress, afterValue, afterAssets, _, afterDatum⟩ :=
    public_build_state h c t q.release registry q.requests q.funding
  have regId : registry.identity = stateAsset h c q.release registry.seed := p.1.2.2.2.2.1
  have beforeGuard : (recognizeState .none h c q.release o.before.seed o.before.state &&
      o.before.state.datum == .root (t o.before.trie) &&
      o.assets.spent.count o.before.state.reference == 1 && o.spentOutputs.contains o.before.state) = true :=
    public_build_before_guard h c t q.release registry q.requests q.funding p.1
  have nonempty : o.changes.isEmpty = false := public_build_nonempty h c t q.release registry q.requests q.funding p.1.1
  have distinct : (o.changes.map Change.reference).Nodup :=
    public_build_distinct h c t q.release registry q.requests q.funding p.1.2.1
  have whole : wholePolicyDelta h c o = true :=
    public_build_whole_policy h c t q.release registry q.requests q.funding regId p.2.1
  have newOutputs : (o.changes.filterMap (fun action => match action with
      | .register _ _ index _ => holdingAt o index | .terminate .. => none)).all
      (fun output => !o.assets.spent.contains output.reference) = true :=
    public_build_no_new_consumed h c t q.release registry q.requests q.funding p.1
  have paired : exactPairing q.release o = true := pairing
  have batched : changeBatch .none h c q.release o = .ok o.after.trie := changes
  have continued : (o.outputs.filter fun output => quantity output o.before.identity > 0) = [o.after.state] := continuation
  have recognized := recognized_assets h c q.release registry.seed registry.state p.1.2.2.2.1
  have bare : bareState o.after.state registry.identity = true := by
    rw [bareState, quantity, afterAssets, recognized, regId]
    dsimp only [registry]
    simp
  have identity : (o.before.identity == stateAsset h c q.release o.before.seed &&
      o.after.identity == o.before.identity && o.after.seed == o.before.seed) = true := by
    change (registry.identity == stateAsset h c q.release registry.seed &&
      o.after.identity == registry.identity && o.after.seed == registry.seed) = true
    rw [afterIdentity, afterSeed, regId]
    simp
  have root : (o.after.state.datum == .root (t o.after.trie)) = true := by
    rw [afterDatum]
    dsimp only [o, registry]
    simp [BEq.beq, instBEqOutputDatum.beq]
  apply public_conclusion_of_fold h c t q p
  change fold .none h c t q.release o = true
  simp only [fold, applyGuard_none]
  repeat' first
    | exact identity
    | exact beforeGuard
    | exact paired
    | exact whole
    | exact newOutputs
    | exact bare
    | (apply Bool.and_eq_true_iff.mpr; constructor)
  all_goals first
    | (simpa only [nonempty] using (show (!false) = true from rfl))
    | (simpa only [decide_eq_true_eq] using distinct)
    | (simpa only [batched] using (show (o.after.trie == o.after.trie) = true from by simp))
    | exact root
    | (simpa only [continued] using (show ([o.after.state] == [o.after.state]) = true from by simp))
    | exact bare
    | (change (o.after.state.credential == registry.state.credential) = true; rw [afterAddress]; simp)
    | (change decide (registry.state.lovelace ≤ o.after.state.lovelace) = true; rw [afterValue]; simp)

/-- Proof helper: quantity agrees at each expected or observed asset. -/
theorem public_exact_at (output : ObservedOutput) (expected : List (TokenId × Nat))
    (exact : exactAssets output expected = true) (asset : TokenId) :
    quantity output asset = ((expected.filter fun entry => entry.1 == asset).map (·.2)).sum := by
  by_cases present : asset ∈ (output.assets ++ expected).map (·.1)
  · exact beq_iff_eq.mp (List.all_eq_true.mp exact asset present)
  · have actual : output.assets.filter (fun entry => entry.1 == asset) = [] := by
      apply List.filter_eq_nil_iff.mpr
      intro entry member same
      exact present (List.mem_map.mpr ⟨entry, List.mem_append_left _ member, token_eq _ _ same⟩)
    have wanted : expected.filter (fun entry => entry.1 == asset) = [] := by
      apply List.filter_eq_nil_iff.mpr
      intro entry member same
      exact present (List.mem_map.mpr ⟨entry, List.mem_append_right _ member, token_eq _ _ same⟩)
    simp [quantity, actual, wanted]

/-- Proof helper: an actual entry cannot exceed its asset quantity. -/
theorem public_entry_bound (entries : List (TokenId × Nat)) (entry : TokenId × Nat)
    (member : entry ∈ entries) :
    entry.2 ≤ ((entries.filter fun e => e.1 == entry.1).map (·.2)).sum := by
  induction entries with
  | nil => simp at member
  | cons first rest ih =>
    rcases List.mem_cons.mp member with same | inside
    · subst first
      simp
    · have bound := ih inside
      by_cases same : first.1 = entry.1 <;> simp [same] <;> omega

/-- Proof helper: the public finite domain separates state and every active role. -/
theorem public_active_state_ne (h : Hash) (c : Codec) (t : TrieCommit) (q : Query)
    (p : PublicPremises h c t q) (request : PendingRequest) (member : request ∈ q.requests) :
    activeAsset h c request.registry request.key ≠ stateAsset h c q.release q.observation.before.seed := by
  intro same
  have am : Preimage.active request.registry request.key ∈ publicDomain q := by
    simp only [publicDomain, List.mem_append, List.mem_cons, List.not_mem_nil, or_false]
    right
    exact List.mem_flatMap.mpr ⟨request, member, by simp⟩
  have sm : Preimage.state q.observation.before.seed ∈ publicDomain q := by simp [publicDomain]
  have impossible := p.2.2.1 _ am _ sm (p.2.2.2 _ am _ sm (congrArg TokenId.name same))
  cases impossible

/-- Proof helper: numbering preserves asset observations. -/
theorem public_numbering_assets (tx n : Nat) (outputs : List ObservedOutput) :
    ((outputs.zipIdx n |>.map fun (o, i) => { o with reference := ⟨tx, i⟩ }).map (·.assets)) =
      outputs.map (·.assets) := by
  simp only [List.map_map, Function.comp_def]
  change ((outputs.zipIdx n).map ((fun o : ObservedOutput => o.assets) ∘ Prod.fst)) = _
  rw [← List.map_map, List.zipIdx_map_fst]

/-- Proof helper: public construction's tail carries only new active assets. -/
theorem public_build_tail_assets (h : Hash) (c : Codec) (t : TrieCommit) (r : PublishedRelease)
    (registry : PublicRegistry) (requests : List PendingRequest) (funding : FoldFunding) :
    let o := buildFold h c t r registry requests funding
    o.outputs.head? = some o.after.state ∧
    (o.outputs.drop 1).map (·.assets) = ((publicPlan h c 0 requests).2.map (·.assets)) ++ [[]] := by
  simp only [buildFold, Id.run, pure, numbered, List.cons_append, List.zipIdx_cons,
    List.map_cons, List.drop_succ_cons, List.drop_zero, List.head?_cons, Option.getD_some]
  constructor
  · trivial
  · rw [public_numbering_assets]
    simp [public_prepare]

/-- Proof helper: a public fold has exactly its continuing state-token output. -/
theorem public_build_continuation (h : Hash) (c : Codec) (t : TrieCommit) (q : Query)
    (p : PublicPremises h c t q) :
    let o := buildFold h c t q.release q.observation.before q.requests q.funding
    (o.outputs.filter fun output => quantity output o.before.identity > 0) = [o.after.state] := by
  let o := buildFold h c t q.release q.observation.before q.requests q.funding
  have regId := p.1.2.2.2.2.1
  have stateAssets := recognized_assets h c q.release q.observation.before.seed
    q.observation.before.state p.1.2.2.2.1
  have fields := public_build_state h c t q.release q.observation.before q.requests q.funding
  have tail := public_build_tail_assets h c t q.release q.observation.before q.requests q.funding
  have noTail : ∀ output ∈ o.outputs.drop 1, quantity output o.before.identity = 0 := by
    intro output member
    have assetMember : output.assets ∈ (o.outputs.drop 1).map (·.assets) := List.mem_map.mpr ⟨output, member, rfl⟩
    rw [tail.2] at assetMember
    rcases List.mem_append.mp assetMember with carrier | empty
    · obtain ⟨holding, hm, assets⟩ := List.mem_map.mp carrier
      rw [public_plan_holdings] at hm
      obtain ⟨request, rm, shape⟩ := List.mem_filterMap.mp hm
      cases request with
      | termination => simp at shape
      | registration input data =>
        simp only [Option.some.injEq] at shape
        subst holding
        have different := public_active_state_ne h c t q p (.registration input data) rm
        change activeAsset h c data.registry data.key ≠ stateAsset h c q.release q.observation.before.seed at different
        change quantity output q.observation.before.identity = 0
        simp [quantity, ← assets, publicHolding, regId, different]
    · have emptyAssets : output.assets = [] := by simpa using empty
      simp [quantity, emptyAssets]
  have noTailFilter : (o.outputs.drop 1).filter (fun output => quantity output o.before.identity > 0) = [] := by
    apply List.filter_eq_nil_iff.mpr
    intro output member
    simp [noTail output member]
  have positive : (decide (quantity o.after.state o.before.identity > 0)) = true := by
    change decide (quantity o.after.state q.observation.before.identity > 0) = true
    have afterAssets : o.after.state.assets = q.observation.before.state.assets := fields.2.2.2.2.2.1
    rw [quantity, afterAssets, stateAssets, regId]
    simp
  have shape : o.outputs = o.after.state :: o.outputs.drop 1 := by
    cases xs : o.outputs with
    | nil => simp [o, xs] at tail
    | cons first rest =>
      have same : first = o.after.state := by simpa [o, xs] using tail.1
      simp [same]
  change (o.outputs.filter fun output => quantity output o.before.identity > 0) = [o.after.state]
  rw [shape, List.filter_cons, positive, noTailFilter]
  rfl

/-- Proof helper: a positive quantity yields an actual positive policy entry. -/
theorem public_positive_detect (entries : List (TokenId × Nat)) (asset : TokenId)
    (policy : Nat) (own : asset.policy = policy)
    (positive : 0 < ((entries.filter fun entry => entry.1 == asset).map (·.2)).sum) :
    entries.any (fun entry => entry.1.policy == policy && entry.2 > 0) = true := by
  induction entries with
  | nil => simp at positive
  | cons entry rest ih =>
    by_cases same : entry.1 = asset
    · by_cases amount : 0 < entry.2
      · simp [List.any_cons, same, own, amount]
      · have zero : entry.2 = 0 := by omega
        simp only [List.filter_cons, beq_iff_eq.mpr same, ↓reduceIte, List.map_cons,
          List.sum_cons, zero, Nat.zero_add] at positive
        simp [List.any_cons, ih positive]
    · simp only [List.filter_cons, beq_eq_false_iff_ne.mpr same, Bool.false_eq_true,
        ↓reduceIte] at positive
      simp [List.any_cons, ih positive]

/-- Proof helper: every authentic public request carries a positive application asset. -/
theorem public_request_approval (h : Hash) (c : Codec) (t : TrieCommit) (q : Query)
    (p : PublicPremises h c t q) (request : PendingRequest) (member : request ∈ q.requests) :
    request.output.assets.any (fun entry => entry.1.policy == q.release.applicationPolicy && entry.2 > 0) = true := by
  have source := p.1.2.2.2.2.2.2.2.2.2.2.2.2 request member
  have regId := p.1.2.2.2.2.1
  have policies := p.2.1
  cases request with
  | registration output data =>
    have shape : exactAssets output [(registrationAsset h c q.release data, 1)] = true := by
      have auth := source.2.1
      simp only [pendingAuthentic, registrationShape, appGuard_none, Bool.and_eq_true] at auth
      exact auth.2.1.2
    have qt := public_exact_at output _ shape (registrationAsset h c q.release data)
    have positive : 0 < quantity output (registrationAsset h c q.release data) := by
      rw [qt]
      simp
    exact public_positive_detect output.assets _ q.release.applicationPolicy rfl positive
  | termination output registry key =>
    have shape : exactAssets output [(activeAsset h c registry key, 1), (terminationApproval h c q.release registry key, 1)] = true := by
      have auth := source.2.1
      simp only [pendingAuthentic, terminationShape, appGuard_none, Bool.and_eq_true] at auth
      exact auth.2
    have registryEq : registry = q.observation.before.identity := source.1
    have different : activeAsset h c registry key ≠ terminationApproval h c q.release registry key := by
      intro same
      have policiesEqual := congrArg TokenId.policy same
      simp only [activeAsset, terminationApproval, registryEq, regId, stateAsset] at policiesEqual
      exact policies policiesEqual.symm
    have qt := public_exact_at output _ shape (terminationApproval h c q.release registry key)
    have positive : 0 < quantity output (terminationApproval h c q.release registry key) := by
      rw [qt]
      simp [different]
    exact public_positive_detect output.assets _ q.release.applicationPolicy rfl positive

/-- Proof helper: construction pairs precisely the actual request inputs. -/
theorem public_build_pairing (h : Hash) (c : Codec) (t : TrieCommit) (q : Query)
    (p : PublicPremises h c t q) :
    exactPairing q.release (buildFold h c t q.release q.observation.before q.requests q.funding) = true := by
  let registry := q.observation.before
  let o := buildFold h c t q.release registry q.requests q.funding
  let predicate := fun output : ObservedOutput =>
    output.assets.any (fun entry => entry.1.policy == q.release.applicationPolicy && entry.2 > 0)
  have recognized := recognized_assets h c q.release registry.seed registry.state p.1.2.2.2.1
  have notState : predicate registry.state = false := by
    simp [predicate, recognized, stateAsset, Ne.symm p.2.1]
  have notFunding : predicate q.funding.ordinaryInput = false := by
    have empty : q.funding.ordinaryInput.assets = [] := p.1.2.2.2.2.2.2.2.1
    simp [predicate, empty]
  have allRequests : (q.requests.map PendingRequest.output).filter predicate = q.requests.map PendingRequest.output := by
    apply List.filter_eq_self.mpr
    intro output member
    obtain ⟨request, rm, rfl⟩ := List.mem_map.mp member
    exact public_request_approval h c t q p request rm
  have filtered : o.spentOutputs.filter predicate = q.requests.map PendingRequest.output := by
    rw [public_build_inputs]
    simp only [List.filter_cons, notState, Bool.false_eq_true, ↓reduceIte, List.filter_append,
      allRequests, notFunding, List.filter_nil, List.append_nil]
  change (((o.changes.map Change.reference).length == (o.spentOutputs.filter predicate).length) &&
    (o.spentOutputs.filter predicate).all (fun output => (o.changes.map Change.reference).contains output.reference)) = true
  rw [filtered, public_build_changes, public_plan_refs]
  simp only [List.length_map, beq_self_eq_true, Bool.true_and, List.all_eq_true]
  intro output member
  obtain ⟨request, rm, rfl⟩ := List.mem_map.mp member
  simpa using (show request.output.reference ∈ q.requests.map (·.output.reference) from List.mem_map.mpr ⟨request, rm, rfl⟩)

/-- Proof helper: distinct input references identify one exact physical input. -/
theorem public_input_unique (inputs : List ObservedOutput) (distinct : (inputs.map (·.reference)).Nodup)
    (input : ObservedOutput) (member : input ∈ inputs) :
    inputs.find? (fun output => output.reference == input.reference) = some input ∧
    inputs.filter (fun output => output.reference == input.reference) = [input] ∧
    (inputs.map (·.reference)).count input.reference = 1 := by
  induction inputs with
  | nil => simp at member
  | cons first rest ih =>
    have nd := List.nodup_cons.mp distinct
    rcases List.mem_cons.mp member with same | inside
    · subst first
      have noTail : rest.filter (fun output => output.reference == input.reference) = [] := by
        apply List.filter_eq_nil_iff.mpr
        intro output om equal
        exact nd.1 (List.mem_map.mpr ⟨output, om, by simpa using equal⟩)
      have count : (rest.map (·.reference)).count input.reference = 0 := by
        rw [nd.2.count]
        simp [nd.1]
      simp [noTail, count]
    · have notSame : first.reference ≠ input.reference := by
        intro same
        exact nd.1 (List.mem_map.mpr ⟨input, inside, same.symm⟩)
      have tail := ih nd.2 inside
      simp [notSame, tail.1, tail.2.1, tail.2.2]

/-- Proof helper: positive policy entries exhaust a singleton quantity. -/
theorem public_single_positive (entries : List (TokenId × Nat)) (asset : TokenId) (policy : Nat)
    (own : asset.policy = policy)
    (total : ((entries.filter fun entry => entry.1 == asset).map (·.2)).sum = 1)
    (only : ∀ entry ∈ entries, (entry.1.policy == policy && entry.2 > 0) = true → entry.1 = asset) :
    entries.filter (fun entry => entry.1.policy == policy && entry.2 > 0) = [(asset, 1)] := by
  induction entries with
  | nil => simp at total
  | cons first rest ih =>
    by_cases picked : (first.1.policy == policy && first.2 > 0) = true
    · have same := only first (by simp) picked
      have positive : 0 < first.2 := by simpa only [Bool.and_eq_true, decide_eq_true_eq] using (Bool.and_eq_true_iff.mp picked).2
      have sumEq : first.2 + ((rest.filter fun entry => entry.1 == asset).map (·.2)).sum = 1 := by
        simpa [same] using total
      have amount : first.2 = 1 := by omega
      have zero : ((rest.filter fun entry => entry.1 == asset).map (·.2)).sum = 0 := by omega
      have empty : rest.filter (fun entry => entry.1.policy == policy && entry.2 > 0) = [] := by
        apply List.filter_eq_nil_iff.mpr
        intro entry member chosen
        have equal := only entry (List.mem_cons_of_mem _ member) chosen
        have bound := public_entry_bound rest entry member
        have pos : 0 < entry.2 := of_decide_eq_true (Bool.and_eq_true_iff.mp chosen).2
        rw [equal, zero] at bound
        omega
      simp only [List.filter_cons, picked, ↓reduceIte, empty]
      exact congrArg (fun e => [e]) (Prod.ext same amount)
    · have restTotal : ((rest.filter fun entry => entry.1 == asset).map (·.2)).sum = 1 := by
        by_cases same : first.1 = asset
        · have zero : first.2 = 0 := by
            have noPositive : ¬ 0 < first.2 := by
              intro positive
              exact picked (by simp [same, own, positive])
            omega
          simpa [same, zero] using total
        · simpa [same] using total
      simpa only [List.filter_cons, picked, ↓reduceIte] using
        ih restTotal (fun entry member => only entry (List.mem_cons_of_mem _ member))

/-- Proof helper: exact assets expose the singleton positive approval under a distinct policy. -/
theorem public_exact_policy (output : ObservedOutput) (expected : List (TokenId × Nat))
    (exact : exactAssets output expected = true) (asset : TokenId) (policy : Nat)
    (own : asset.policy = policy)
    (wanted : expected.filter (fun entry => entry.1.policy == policy) = [(asset, 1)]) :
    output.assets.filter (fun entry => entry.1.policy == policy && entry.2 > 0) = [(asset, 1)] := by
  have atAsset := public_exact_at output expected exact asset
  have filtered : expected.filter (fun entry => entry.1 == asset) = [(asset, 1)] := by
    calc
      _ = (expected.filter (fun entry => entry.1.policy == policy)).filter (fun entry => entry.1 == asset) := by
        rw [List.filter_filter]
        apply List.filter_congr
        intro entry member
        by_cases same : entry.1 = asset <;> simp [same, own]
      _ = _ := by rw [wanted]; simp
  apply public_single_positive output.assets asset policy own (by simpa [filtered] using atAsset)
  intro entry member positive
  have policyEq : entry.1.policy = policy := by simpa using (Bool.and_eq_true_iff.mp positive).1
  have pos : 0 < entry.2 := of_decide_eq_true (Bool.and_eq_true_iff.mp positive).2
  apply Classical.byContradiction
  intro different
  have noExpected : expected.filter (fun other => other.1 == entry.1) = [] := by
    calc
      _ = (expected.filter (fun other => other.1.policy == policy)).filter (fun other => other.1 == entry.1) := by
        rw [List.filter_filter]
        apply List.filter_congr
        intro other om
        by_cases same : other.1 = entry.1 <;> simp [same, policyEq]
      _ = _ := by rw [wanted]; simp [Ne.symm different]
  have zero := public_exact_at output expected exact entry.1
  have bound := public_entry_bound output.assets entry member
  change entry.2 ≤ quantity output entry.1 at bound
  rw [zero, noExpected] at bound
  simp only [List.map_nil, List.sum_nil] at bound
  omega

/-- Proof helper: the public request's exact approval preimage. -/
def publicApprovalPreimage : PendingRequest → Preimage
  | .registration _ d => .registrationApproval d.registry d.key d.holdingAddress d.initialDatum d.deposit
  | .termination _ registry key => .terminationApproval registry key

/-- Proof helper: the public request's exact approval asset. -/
def publicApproval (h : Hash) (c : Codec) (r : PublishedRelease) (request : PendingRequest) : TokenId :=
  ⟨r.applicationPolicy, h (c (publicApprovalPreimage request))⟩

/-- Proof helper: each operation's signed active delta. -/
def publicSign : PendingRequest → Int
  | .registration .. => 1 | .termination .. => -1

/-- Proof helper: the approval preimage occurs in the frozen public domain. -/
theorem public_approval_domain (q : Query) (request : PendingRequest) (member : request ∈ q.requests) :
    publicApprovalPreimage request ∈ publicDomain q := by
  apply List.mem_append_right
  apply List.mem_flatMap.mpr
  refine ⟨request, member, ?_⟩
  cases request <;> simp [publicApprovalPreimage]

/-- Proof helper: active-asset equality implies key equality in the public domain. -/
theorem public_active_key (h : Hash) (c : Codec) (t : TrieCommit) (q : Query)
    (p : PublicPremises h c t q) (first second : PendingRequest)
    (fm : first ∈ q.requests) (sm : second ∈ q.requests)
    (same : activeAsset h c first.registry first.key = activeAsset h c second.registry second.key) :
    first.key = second.key := by
  have domain : ∀ request ∈ q.requests, Preimage.active request.registry request.key ∈ publicDomain q := by
    intro request member
    apply List.mem_append_right
    exact List.mem_flatMap.mpr ⟨request, member, by simp⟩
  have eq := p.2.2.1 _ (domain first fm) _ (domain second sm)
    (p.2.2.2 _ (domain first fm) _ (domain second sm) (congrArg TokenId.name same))
  exact (Preimage.active.inj eq).2

/-- Proof helper: approval-asset equality implies key equality in the public domain. -/
theorem public_approval_key (h : Hash) (c : Codec) (t : TrieCommit) (q : Query)
    (p : PublicPremises h c t q) (first second : PendingRequest)
    (fm : first ∈ q.requests) (sm : second ∈ q.requests)
    (same : publicApproval h c q.release first = publicApproval h c q.release second) :
    first.key = second.key := by
  have eq := p.2.2.1 _ (public_approval_domain q first fm) _ (public_approval_domain q second sm)
    (p.2.2.2 _ (public_approval_domain q first fm) _ (public_approval_domain q second sm) (congrArg TokenId.name same))
  have keyEq := congrArg (fun preimage => match preimage with
    | .registrationApproval _ key .. | .terminationApproval _ key | .active _ key => key
    | _ => 0) eq
  cases first <;> cases second <;> exact keyEq

/-- Proof helper: distinct logical keys isolate exactly one public record. -/
theorem public_unique_key {α : Type} (records : List α) (key : α → Nat)
    (distinct : (records.map key).Nodup) (record : α) (member : record ∈ records) :
    records.filter (fun other => key other == key record) = [record] := by
  induction records with
  | nil => simp at member
  | cons first rest ih =>
    have nd := List.nodup_cons.mp distinct
    rcases List.mem_cons.mp member with same | inside
    · subst first
      have empty : rest.filter (fun other => key other == key record) = [] := by
        apply List.filter_eq_nil_iff.mpr
        intro other om eq
        exact nd.1 (List.mem_map.mpr ⟨other, om, by simpa using eq⟩)
      simp [empty]
    · have different : key first ≠ key record := by
        intro equal
        exact nd.1 (List.mem_map.mpr ⟨record, inside, equal.symm⟩)
      simp [different, ih nd.2 inside]

/-- Proof helper: finite asset separation and distinct keys isolate one public record. -/
theorem public_unique_asset (q : Query) (asset : PendingRequest → TokenId)
    (distinct : (q.requests.map PendingRequest.key).Nodup)
    (separates : ∀ a ∈ q.requests, ∀ b ∈ q.requests, asset a = asset b → a.key = b.key)
    (request : PendingRequest) (member : request ∈ q.requests) :
    q.requests.filter (fun other => asset other == asset request) = [request] := by
  have byKey := public_unique_key q.requests PendingRequest.key distinct request member
  calc
    _ = q.requests.filter (fun other => other.key == request.key) := by
      apply List.filter_congr
      intro other om
      by_cases equal : asset other = asset request
      · simp [equal, separates other om request member equal]
      · have keys : other.key ≠ request.key := by
          intro same
          have present : other ∈ q.requests.filter (fun r => r.key == request.key) :=
            List.mem_filter.mpr ⟨om, by simp [same]⟩
          rw [byKey] at present
          have otherEq : other = request := by simpa using present
          exact equal (congrArg asset otherEq)
        exact (beq_eq_false_iff_ne.mpr equal).trans (beq_eq_false_iff_ne.mpr keys).symm
    _ = _ := byKey

/-- Proof helper: ordered allocation preserves the exact signed active entries. -/
theorem public_plan_delta (h : Hash) (c : Codec) (registry : TokenId) (n : Nat) (requests : List PendingRequest) :
    (publicPlan h c n requests).1.map (fun action =>
      (activeAsset h c registry action.key, match action with | .register .. => (1 : Int) | .terminate .. => -1)) =
    requests.map (fun request => (activeAsset h c registry request.key, publicSign request)) := by
  induction requests generalizing n with
  | nil => rfl
  | cons request rest ih =>
    cases request with
    | registration output data =>
      simp only [publicPlan, List.map_cons]
      exact congrArg (fun xs => (activeAsset h c registry data.key, (1 : Int)) :: xs) (ih (n + 1))
    | termination output r key =>
      simp only [publicPlan, List.map_cons]
      exact congrArg (fun xs => (activeAsset h c registry key, (-1 : Int)) :: xs) (ih n)

/-- Proof helper: construction's complete mint is exactly the two public request maps. -/
theorem public_build_mint_maps (h : Hash) (c : Codec) (t : TrieCommit) (q : Query)
    (p : PublicPremises h c t q) :
    (buildFold h c t q.release q.observation.before q.requests q.funding).assets.mint =
      q.requests.map (fun request => (activeAsset h c request.registry request.key, publicSign request)) ++
      q.requests.map (fun request => (publicApproval h c q.release request, (-1 : Int))) := by
  rw [public_build_mint]
  congr 1
  · unfold expectedDelta
    rw [public_build_changes]
    change (publicPlan h c 0 q.requests).1.map (fun action =>
      (activeAsset h c q.observation.before.identity action.key, match action with | .register .. => (1 : Int) | .terminate .. => -1)) = _
    rw [public_plan_delta]
    apply List.map_congr_left
    intro request member
    have same := (p.1.2.2.2.2.2.2.2.2.2.2.2.2 request member).1
    rw [same]
  · apply List.map_congr_left
    intro request _
    cases request <;> rfl

/-- Proof helper: one isolated signed asset contributes exactly its own delta. -/
theorem public_signed_at (q : Query) (asset : PendingRequest → TokenId) (amount : PendingRequest → Int)
    (request : PendingRequest) (_member : request ∈ q.requests)
    (isolated : q.requests.filter (fun other => asset other == asset request) = [request]) :
    (((q.requests.map fun other => (asset other, amount other)).filter
      (fun entry => entry.1 == asset request)).map (·.2)).sum = amount request := by
  rw [List.filter_map]
  change ((q.requests.filter (fun other => asset other == asset request)).map
    (fun other => (asset other, amount other)) |>.map (·.2)).sum = _
  rw [isolated]
  simp

/-- Proof helper: every constructed request approval burns once and active asset has its signed delta. -/
theorem public_build_mint_at (h : Hash) (c : Codec) (t : TrieCommit) (q : Query)
    (p : PublicPremises h c t q) (request : PendingRequest) (member : request ∈ q.requests) :
    let o := buildFold h c t q.release q.observation.before q.requests q.funding
    SingularApplicationHeld.Assets.mintQty o.assets (publicApproval h c q.release request) = -1 ∧
    SingularApplicationHeld.Assets.mintQty o.assets (activeAsset h c request.registry request.key) = publicSign request := by
  have approvalOnly := public_unique_asset q (publicApproval h c q.release) p.1.2.2.1
    (fun a am b bm => public_approval_key h c t q p a b am bm) request member
  have activeOnly := public_unique_asset q (fun r => activeAsset h c r.registry r.key) p.1.2.2.1
    (fun a am b bm => public_active_key h c t q p a b am bm) request member
  have ap := public_signed_at q (publicApproval h c q.release) (fun _ => (-1 : Int)) request member approvalOnly
  have ac := public_signed_at q (fun r => activeAsset h c r.registry r.key) publicSign request member activeOnly
  have policies := p.2.1
  have activePolicy : ∀ request ∈ q.requests, (activeAsset h c request.registry request.key).policy = q.release.statePolicy := by
    intro request member
    have same := (p.1.2.2.2.2.2.2.2.2.2.2.2.2 request member).1
    rw [activeAsset, same, p.1.2.2.2.2.1]
    rfl
  have noActive : (q.requests.map (fun other => (activeAsset h c other.registry other.key, publicSign other))).filter
      (fun entry => entry.1 == publicApproval h c q.release request) = [] := by
    apply public_other_policy_filter _ _ q.release.applicationPolicy rfl
    intro entry member
    obtain ⟨other, om, rfl⟩ := List.mem_map.mp member
    rw [activePolicy other om]
    exact Ne.symm policies
  have noApproval : (q.requests.map (fun other => (publicApproval h c q.release other, (-1 : Int)))).filter
      (fun entry => entry.1 == activeAsset h c request.registry request.key) = [] := by
    apply public_other_policy_filter _ _ q.release.statePolicy (activePolicy request member)
    intro entry _
    obtain ⟨other, _, rfl⟩ := List.mem_map.mp ‹entry ∈ _›
    exact policies
  dsimp only
  simp only [SingularApplicationHeld.Assets.mintQty, public_build_mint_maps h c t q p, List.filter_append, noActive, noApproval,
    List.nil_append, List.append_nil]
  exact ⟨ap, ac⟩

/-- Proof helper: every constructed output after the state is a numbered carrier or processor output. -/
theorem public_build_outputs (h : Hash) (c : Codec) (t : TrieCommit) (r : PublishedRelease)
    (registry : PublicRegistry) (requests : List PendingRequest) (funding : FoldFunding) :
    let o := buildFold h c t r registry requests funding
    o.outputs = o.after.state ::
      ((((publicPlan h c 0 requests).2 ++
        [ObservedOutput.mk ⟨0, 0⟩ funding.processorAddress
          ((requests.map PendingRequest.bid).sum + funding.ordinaryInput.lovelace - funding.fee) .empty [] none]).zipIdx 1).map
        fun (output, index) => { output with reference := ⟨funding.transactionId, index⟩ }) := by
  simp [buildFold, numbered, List.zipIdx_cons, public_prepare]

/-- Proof helper: the actual numbered carrier is found at its allocated index. -/
theorem public_build_holding (h : Hash) (c : Codec) (t : TrieCommit) (r : PublishedRelease)
    (registry : PublicRegistry) (requests : List PendingRequest) (funding : FoldFunding)
    (index : Nat) (holding : ObservedOutput) (positive : 0 < index)
    (carrier : (publicPlan h c 0 requests).2[index - 1]? = some holding) :
    holdingAt (buildFold h c t r registry requests funding) index =
      some { holding with reference := ⟨funding.transactionId, index⟩ } := by
  have bounds : index - 1 < (publicPlan h c 0 requests).2.length := (List.getElem?_eq_some_iff.mp carrier).choose
  have offset : index = (index - 1) + 1 := by omega
  unfold holdingAt
  rw [public_build_outputs]
  rw [offset, List.getElem?_cons_succ, List.getElem?_map, List.getElem?_zipIdx,
    List.getElem?_append_left bounds, carrier]
  have addition : 1 + (index - 1) = index := by omega
  simp only [Option.map_some, addition, ← offset]

/-- Proof helper: numbered output quantities have the same sum. -/
theorem public_numbering_quantity (tx n : Nat) (outputs : List ObservedOutput) (asset : TokenId) :
    ((outputs.zipIdx n |>.map fun (o, i) => { o with reference := ⟨tx, i⟩ }).map (fun output => quantity output asset)).sum =
      (outputs.map (fun output => quantity output asset)).sum := by
  simp only [List.map_map, Function.comp_def]
  change ((outputs.zipIdx n).map ((fun o : ObservedOutput => quantity o asset) ∘ Prod.fst)).sum = _
  rw [← List.map_map, List.zipIdx_map_fst]

/-- Proof helper: carriers for different active names contribute zero. -/
theorem public_holdings_filter (h : Hash) (c : Codec) (requests : List PendingRequest) (asset : TokenId) :
    ((publicPlan h c 0 requests).2.map (fun output => quantity output asset)).sum =
      ((publicPlan h c 0 (requests.filter (fun request => activeAsset h c request.registry request.key == asset))).2.map
        (fun output => quantity output asset)).sum := by
  simp only [public_plan_holdings]
  induction requests with
  | nil => rfl
  | cons request rest ih =>
    cases request with
    | registration output data =>
      by_cases same : activeAsset h c data.registry data.key = asset
      · simpa [same, publicHolding, quantity, PendingRequest.registry, PendingRequest.key] using congrArg (fun n : Nat => 1 + n) ih
      · simpa [same, publicHolding, quantity, PendingRequest.registry, PendingRequest.key] using ih
    | termination output registry key =>
      by_cases same : activeAsset h c registry key = asset <;>
        simpa [same, PendingRequest.registry, PendingRequest.key] using ih

/-- Proof helper: each registered active asset is present exactly once in all constructed outputs. -/
theorem public_build_placement (h : Hash) (c : Codec) (t : TrieCommit) (q : Query)
    (p : PublicPremises h c t q) (input : ObservedOutput) (data : RegistrationData)
    (member : PendingRequest.registration input data ∈ q.requests) :
    let o := buildFold h c t q.release q.observation.before q.requests q.funding
    (o.outputs.map fun output => quantity output (activeAsset h c data.registry data.key)).sum = 1 := by
  let asset := activeAsset h c data.registry data.key
  have isolated := public_unique_asset q (fun r => activeAsset h c r.registry r.key) p.1.2.2.1
    (fun a am b bm => public_active_key h c t q p a b am bm) (.registration input data) member
  change q.requests.filter (fun request => activeAsset h c request.registry request.key == asset) = [.registration input data] at isolated
  have sum := public_holdings_filter h c q.requests asset
  have one : ((publicPlan h c 0 q.requests).2.map (fun output => quantity output asset)).sum = 1 := by
    rw [isolated] at sum
    simpa [publicPlan, publicHolding, quantity, asset] using sum
  have diff := public_active_state_ne h c t q p (.registration input data) member
  change asset ≠ stateAsset h c q.release q.observation.before.seed at diff
  have stateAssets := recognized_assets h c q.release q.observation.before.seed q.observation.before.state p.1.2.2.2.1
  have fields := public_build_state h c t q.release q.observation.before q.requests q.funding
  let o := buildFold h c t q.release q.observation.before q.requests q.funding
  have afterAssets : o.after.state.assets = q.observation.before.state.assets := fields.2.2.2.2.2.1
  change (o.outputs.map fun output => quantity output asset).sum = 1
  rw [public_build_outputs, List.map_cons, List.sum_cons, public_numbering_quantity]
  have stateZero : quantity (buildFold h c t q.release q.observation.before q.requests q.funding).after.state asset = 0 := by
    rw [quantity, fields.2.2.2.2.2.1, stateAssets]
    simp [Ne.symm diff]
  simp only [List.map_append, List.sum_append_nat, List.map_cons, List.map_nil, List.sum_cons, List.sum_nil]
  rw [stateZero, one]
  simp [quantity]

/-- Proof helper: registration assets are exactly the request-derived carrier assets. -/
theorem public_plan_new_assets (h : Hash) (c : Codec) (registry : TokenId) (n : Nat) (requests : List PendingRequest) :
    ((publicPlan h c n requests).1.filterMap fun action => match action with
      | .register _ key _ _ => some (activeAsset h c registry key) | .terminate .. => none) =
    requests.filterMap (fun request => match request with
      | .registration _ data => some (activeAsset h c registry data.key) | .termination .. => none) := by
  induction requests generalizing n with
  | nil => rfl
  | cons request rest ih => cases request <;> simp only [publicPlan, List.filterMap_cons, ih]

/-- Proof helper: new-asset counting can discard every different active name. -/
theorem public_new_asset_filter (h : Hash) (c : Codec) (requests : List PendingRequest) (asset : TokenId) :
    ((requests.filterMap fun request => match request with
      | .registration _ data => some (activeAsset h c data.registry data.key) | .termination .. => none).map
        (fun other => if asset == other then (1 : Nat) else 0)).sum =
    (((requests.filter (fun request => activeAsset h c request.registry request.key == asset)).filterMap fun request => match request with
      | .registration _ data => some (activeAsset h c data.registry data.key) | .termination .. => none).map
        (fun other => if asset == other then (1 : Nat) else 0)).sum := by
  induction requests with
  | nil => rfl
  | cons request rest ih =>
    cases request with
    | registration output data =>
      by_cases same : activeAsset h c data.registry data.key = asset
      · simpa [same, PendingRequest.registry, PendingRequest.key] using congrArg (fun n : Nat => 1 + n) ih
      · simpa [same, Ne.symm same, PendingRequest.registry, PendingRequest.key] using ih
    | termination output registry key =>
      by_cases same : activeAsset h c registry key = asset <;>
        simpa [same, PendingRequest.registry, PendingRequest.key] using ih

/-- Proof helper: optional list projections respect equality on the observed extent. -/
theorem public_filterMap_congr {α β : Type} (records : List α) (f g : α → Option β)
    (same : ∀ record ∈ records, f record = g record) : records.filterMap f = records.filterMap g := by
  induction records with
  | nil => rfl
  | cons first rest ih =>
    simp only [List.filterMap_cons, same first (by simp)]
    rw [ih (fun record member => same record (List.mem_cons_of_mem _ member))]

/-- Proof helper: a registration's carrier contains exactly one of all newly minted tokens. -/
theorem public_build_one_new (h : Hash) (c : Codec) (t : TrieCommit) (q : Query)
    (p : PublicPremises h c t q) (input : ObservedOutput) (data : RegistrationData)
    (member : PendingRequest.registration input data ∈ q.requests) (output : ObservedOutput)
    (assets : output.assets = [(activeAsset h c data.registry data.key, 1)]) :
    oneNewToken h c (buildFold h c t q.release q.observation.before q.requests q.funding) output = true := by
  let asset := activeAsset h c data.registry data.key
  have isolated := public_unique_asset q (fun r => activeAsset h c r.registry r.key) p.1.2.2.1
    (fun a am b bm => public_active_key h c t q p a b am bm) (.registration input data) member
  change q.requests.filter (fun request => activeAsset h c request.registry request.key == asset) = [.registration input data] at isolated
  have filtered := public_new_asset_filter h c q.requests asset
  rw [isolated] at filtered
  simp only [oneNewToken, public_build_changes]
  change ((((publicPlan h c 0 q.requests).1.filterMap fun action => match action with
    | .register _ key _ _ => some (activeAsset h c q.observation.before.identity key) | .terminate .. => none).map (quantity output) |>.sum) == 1) = true
  rw [public_plan_new_assets]
  have actual : (q.requests.filterMap fun request => match request with
      | .registration _ data => some (activeAsset h c q.observation.before.identity data.key) | .termination .. => none) =
      q.requests.filterMap (fun request => match request with
      | .registration _ data => some (activeAsset h c data.registry data.key) | .termination .. => none) := by
    apply public_filterMap_congr
    intro request rm
    have same := (p.1.2.2.2.2.2.2.2.2.2.2.2.2 request rm).1
    cases request with
    | termination => rfl
    | registration output data =>
      change some (activeAsset h c q.observation.before.identity data.key) = some (activeAsset h c data.registry data.key)
      rw [show data.registry = q.observation.before.identity from same]
  change (((q.requests.filterMap fun request => match request with
      | .registration _ data => some (activeAsset h c q.observation.before.identity data.key) | .termination .. => none).map
      (quantity output)).sum == 1) = true
  rw [actual]
  have quantityEq : quantity output = (fun other => if asset == other then (1 : Nat) else 0) := by
    funext other
    by_cases same : activeAsset h c data.registry data.key = other <;> simp [quantity, assets, asset, same]
  rw [quantityEq]
  simpa [asset] using filtered

/-- Proof helper: the authentic request's positive application census is exactly its approval. -/
theorem public_request_approval_shape (h : Hash) (c : Codec) (t : TrieCommit) (q : Query)
    (p : PublicPremises h c t q) (request : PendingRequest) (member : request ∈ q.requests) :
    request.output.assets.filter (fun entry => entry.1.policy == q.release.applicationPolicy && entry.2 > 0) =
      [(publicApproval h c q.release request, 1)] := by
  have source := p.1.2.2.2.2.2.2.2.2.2.2.2.2 request member
  cases request with
  | registration output data =>
    have auth := source.2.1
    simp only [pendingAuthentic, registrationShape, appGuard_none, Bool.and_eq_true] at auth
    apply public_exact_policy output [(registrationAsset h c q.release data, 1)] auth.2.1.2
      (publicApproval h c q.release (.registration output data)) q.release.applicationPolicy rfl
    simp [publicApproval, publicApprovalPreimage, registrationAsset, registrationApproval]
  | termination output registry key =>
    have auth := source.2.1
    simp only [pendingAuthentic, terminationShape, appGuard_none, Bool.and_eq_true] at auth
    apply public_exact_policy output [(activeAsset h c registry key, 1), (terminationApproval h c q.release registry key, 1)]
      auth.2 (publicApproval h c q.release (.termination output registry key)) q.release.applicationPolicy rfl
    have regEq : registry = q.observation.before.identity := source.1
    simp [activeAsset, terminationApproval, publicApproval, publicApprovalPreimage, regEq,
      p.1.2.2.2.2.1, stateAsset, Ne.symm p.2.1]

/-- Proof helper: a constructed transaction observes each public request once. -/
theorem public_build_request_input (h : Hash) (c : Codec) (t : TrieCommit) (q : Query)
    (p : PublicPremises h c t q) (request : PendingRequest) (member : request ∈ q.requests) :
    let o := buildFold h c t q.release q.observation.before q.requests q.funding
    o.spentOutputs.find? (fun output => output.reference == request.output.reference) = some request.output ∧
    o.spentOutputs.filter (fun output => output.reference == request.output.reference) = [request.output] ∧
    o.assets.spent.count request.output.reference = 1 := by
  dsimp only
  rw [public_build_inputs, public_build_spent]
  have distinct : ((q.observation.before.state :: q.requests.map PendingRequest.output ++ [q.funding.ordinaryInput]).map
      (·.reference)).Nodup := by
    simpa only [List.map_cons, List.map_append, List.map_map, Function.comp_def, List.map_nil] using p.1.2.2.2.2.2.2.2.2.2.2.1
  apply public_input_unique _ distinct
  exact List.mem_cons_of_mem _ (List.mem_append_left _ (List.mem_map.mpr ⟨request, member, rfl⟩))

/-- Proof helper: each constructed operation succeeds whenever its own original leaf is retained. -/
theorem public_build_change (h : Hash) (c : Codec) (t : TrieCommit) (q : Query)
    (p : PublicPremises h c t q) (action : Change)
    (member : action ∈ (buildFold h c t q.release q.observation.before q.requests q.funding).changes)
    (trie : Trie) (retained : trieGet trie action.key = trieGet q.observation.before.trie action.key) :
    change .none h c q.release trie action (buildFold h c t q.release q.observation.before q.requests q.funding) =
      .ok (targetTrie trie action) := by
  let o := buildFold h c t q.release q.observation.before q.requests q.funding
  have beforeId : o.before.identity = q.observation.before.identity := rfl
  have allocated := member
  rw [public_build_changes] at allocated
  cases action with
  | register reference key index deposit =>
    obtain ⟨input, data, rm, rfl, rfl, rfl, carrier⟩ := public_plan_registration h c 0 q.requests reference key index deposit allocated
    have bounds := public_plan_index_bounds h c 0 q.requests input.reference data.key index data.deposit allocated
    have source := p.1.2.2.2.2.2.2.2.2.2.2.2.2 (.registration input data) rm
    have regEq : data.registry = q.observation.before.identity := source.1
    have leaf : trieGet trie data.key = .unknown := retained.trans source.2.2.1
    let holding := { publicHolding h c data with reference := OutRef.mk q.funding.transactionId index }
    have lookup : holdingAt o index = some holding := public_build_holding h c t q.release q.observation.before q.requests q.funding
      index (publicHolding h c data) (by omega) (by simpa using carrier)
    have observed := public_build_request_input h c t q p (.registration input data) rm
    have approvalShape := public_request_approval_shape h c t q p (.registration input data) rm
    have found : o.spentOutputs.find? (fun output => output.reference == input.reference) = some input := observed.1
    have filteredInput : o.spentOutputs.filter (fun output => output.reference == input.reference) = [input] := observed.2.1
    have count : o.assets.spent.count input.reference = 1 := observed.2.2
    have mint := public_build_mint_at h c t q p (.registration input data) rm
    have separate : separateHolding o input.reference index = true := public_build_separate h c t q.release q.observation.before q.requests q.funding
      input.reference data.key index data.deposit member
    have one : oneNewToken h c o holding = true := public_build_one_new h c t q p input data rm holding rfl
    have placement := public_build_placement h c t q p input data rm
    let approval := publicApproval h c q.release (.registration input data)
    let active := activeAsset h c q.observation.before.identity data.key
    have expected : approvalFor h c q.release o (.register input.reference data.key index data.deposit) = some approval := by
      simp [approvalFor, lookup, holding, publicHolding, approval, publicApproval, publicApprovalPreimage, registrationApproval, beforeId, regEq]
    have supplied : input.assets.filter (fun entry => entry.1.policy == q.release.applicationPolicy && entry.2 > 0) = [(approval, 1)] := approvalShape
    have activeMint : SingularApplicationHeld.Assets.mintQty o.assets active = 1 := by
      simpa only [PendingRequest.registry, PendingRequest.key, publicSign, regEq] using mint.2
    have activeQuantity : quantity holding active = 1 := by simp [holding, publicHolding, quantity, active, regEq]
    have allQuantity : (o.outputs.map fun output => quantity output active).sum = 1 := by
      simpa only [regEq] using placement
    have approvalBurn : SingularApplicationHeld.Assets.mintQty o.assets approval = -1 := mint.1
    dsimp only [active] at activeQuantity allQuantity activeMint
    change change .none h c q.release trie (.register input.reference data.key index data.deposit) o = _
    rw [change_eq]
    simp only [changeConditions, Change.reference, Change.key, found, expected, filteredInput, count, supplied,
      beforeId,
      leaf, lookup, activeQuantity, allQuantity, separate, one, activeMint, targetTrie,
      bind, Except.bind, pure, Except.pure]
    simp [approvalBurn, holding, publicHolding]
  | terminate reference key =>
    obtain ⟨input, registry, rm, rfl⟩ := public_plan_termination h c 0 q.requests reference key allocated
    have source := p.1.2.2.2.2.2.2.2.2.2.2.2.2 (.termination input registry key) rm
    have regEq : registry = q.observation.before.identity := source.1
    have leaf : trieGet trie key = .known .active := retained.trans source.2.2
    have observed := public_build_request_input h c t q p (.termination input registry key) rm
    have approvalShape := public_request_approval_shape h c t q p (.termination input registry key) rm
    have found : o.spentOutputs.find? (fun output => output.reference == input.reference) = some input := observed.1
    have filteredInput : o.spentOutputs.filter (fun output => output.reference == input.reference) = [input] := observed.2.1
    have count : o.assets.spent.count input.reference = 1 := observed.2.2
    have mint := public_build_mint_at h c t q p (.termination input registry key) rm
    have auth := source.2.1
    simp only [pendingAuthentic, terminationShape, appGuard_none, Bool.and_eq_true] at auth
    have qt := public_exact_at input _ auth.2 (activeAsset h c registry key)
    have different : terminationApproval h c q.release registry key ≠ activeAsset h c registry key := by
      intro same
      have policiesEqual := congrArg TokenId.policy same
      simp only [terminationApproval, activeAsset, regEq, p.1.2.2.2.2.1, stateAsset] at policiesEqual
      exact p.2.1 policiesEqual
    have held : quantity input (activeAsset h c q.observation.before.identity key) = 1 := by
      rw [← regEq, qt]
      simp [different]
    let approval := publicApproval h c q.release (.termination input registry key)
    let active := activeAsset h c q.observation.before.identity key
    have expected : approvalFor h c q.release o (.terminate input.reference key) = some approval := by
      simp [approvalFor, approval, publicApproval, publicApprovalPreimage, terminationApproval, beforeId, regEq]
    have supplied : input.assets.filter (fun entry => entry.1.policy == q.release.applicationPolicy && entry.2 > 0) = [(approval, 1)] := approvalShape
    have activeMint : SingularApplicationHeld.Assets.mintQty o.assets active = -1 := by
      simpa only [PendingRequest.registry, PendingRequest.key, publicSign, regEq] using mint.2
    have approvalBurn : SingularApplicationHeld.Assets.mintQty o.assets approval = -1 := mint.1
    dsimp only [active] at activeMint
    change change .none h c q.release trie (.terminate input.reference key) o = _
    rw [change_eq]
    simp only [changeConditions, Change.reference, Change.key, found, expected, filteredInput, count, supplied, beforeId,
      leaf, held, activeMint, targetTrie, bind, Except.bind, pure, Except.pure]
    simp [approvalBurn]

/-- Proof helper: the frozen builder prefix before its root-only continuation update. -/
def publicRaw (hash : Hash) (code : Codec) (_commit : TrieCommit) (release : PublishedRelease)
    (registry : PublicRegistry) (requests : List PendingRequest) (funding : FoldFunding) : FoldObservation := Id.run do
  let (changes, holdings) := prepareChanges hash code requests
  let processorValue := (requests.map PendingRequest.bid).sum + funding.ordinaryInput.lovelace - funding.fee
  let processor : ObservedOutput := ⟨⟨0, 0⟩, funding.processorAddress, processorValue, .empty, [], none⟩
  let outputs := numbered funding.transactionId ([registry.state] ++ holdings ++ [processor])
  let state := outputs.head?.getD registry.state
  let inputs := [registry.state] ++ requests.map PendingRequest.output ++ [funding.ordinaryInput]
  let approvals := requests.map fun request =>
    let asset := match request with
      | .registration _ data => registrationAsset hash code release data
      | .termination _ registry key => terminationApproval hash code release registry key
    (asset, (-1 : Int))
  let view : SingularApplicationHeld.Assets.TxView := ⟨inputs.map (·.reference), outputs.map (fun output => ⟨output.assets⟩),
    [], [release.statePolicy, release.applicationPolicy]⟩
  let provisional : FoldObservation := ⟨registry, { registry with state }, view, inputs, outputs,
    changes, [], funding.interval, funding.fee, 0⟩
  let observation := { provisional with assets := { view with mint := expectedDelta hash code provisional ++ approvals } }
  return observation

/-- Proof helper: root continuation changes no field used by positive-index operations. -/
theorem public_raw_fields (h : Hash) (c : Codec) (t : TrieCommit) (r : PublishedRelease)
    (registry : PublicRegistry) (requests : List PendingRequest) (funding : FoldFunding) :
    let o := buildFold h c t r registry requests funding
    let raw := publicRaw h c t r registry requests funding
    o.before.identity = raw.before.identity ∧ o.spentOutputs = raw.spentOutputs ∧
    o.assets.spent = raw.assets.spent ∧ o.assets.mint = raw.assets.mint ∧ o.changes = raw.changes ∧
    o.outputs.map (·.assets) = raw.outputs.map (·.assets) ∧
    (∀ index, 0 < index → holdingAt o index = holdingAt raw index) ∧
    o.after.trie = (match changeBatch .none h c r raw with | .ok trie => trie | .error _ => registry.trie) := by
  refine ⟨rfl, rfl, rfl, rfl, rfl, ?_, ?_, rfl⟩
  · rfl
  · intro index positive
    obtain ⟨n, rfl⟩ := Nat.exists_eq_succ_of_ne_zero (by omega : index ≠ 0)
    simp only [holdingAt, buildFold, publicRaw, Id.run, pure, numbered, List.cons_append,
      List.zipIdx_cons, List.map_cons, List.drop_succ_cons, List.drop_zero, List.head?_cons,
      Option.getD_some, List.getElem?_cons_succ]

/-- Proof helper: operations depend on physical fields, never the continued root datum. -/
theorem public_change_congr (h : Hash) (c : Codec) (r : PublishedRelease)
    (first second : FoldObservation) (action : Change) (trie : Trie)
    (before : first.before.identity = second.before.identity)
    (inputs : first.spentOutputs = second.spentOutputs)
    (spent : first.assets.spent = second.assets.spent) (mint : first.assets.mint = second.assets.mint)
    (changes : first.changes = second.changes)
    (assets : first.outputs.map (·.assets) = second.outputs.map (·.assets))
    (holding : match action with | .register _ _ index _ => holdingAt first index = holdingAt second index | .terminate .. => True) :
    change .none h c r trie action first = change .none h c r trie action second := by
  have quantities (asset : TokenId) : first.outputs.map (fun output => quantity output asset) =
      second.outputs.map (fun output => quantity output asset) := by
    calc
      _ = (first.outputs.map (·.assets)).map (fun entries => ((entries.filter fun entry => entry.1 == asset).map (·.2)).sum) := by simp only [List.map_map]; rfl
      _ = _ := by rw [assets]
      _ = _ := by simp only [List.map_map]; rfl
  rw [change_eq, change_eq]
  cases action <;>
    simp only [changeConditions, approvalFor, inputs, spent, before, SingularApplicationHeld.Assets.mintQty, mint,
      holding, oneNewToken, separateHolding, changes, quantities]

/-- Proof helper: pointwise operation equality preserves the ordered monadic fold. -/
theorem public_batch_congr (h : Hash) (c : Codec) (r : PublishedRelease)
    (first second : FoldObservation) (actions : List Change)
    (same : ∀ action ∈ actions, ∀ trie, change .none h c r trie action first = change .none h c r trie action second)
    (trie : Trie) :
    actions.foldlM (fun trie action => change .none h c r trie action first) trie =
    actions.foldlM (fun trie action => change .none h c r trie action second) trie := by
  induction actions generalizing trie with
  | nil => rfl
  | cons action rest ih =>
    simp only [List.foldlM_cons]
    rw [same action (by simp) trie]
    congr 1
    funext middle
    exact ih (fun action member => same action (List.mem_cons_of_mem _ member)) middle

/-- Proof helper: the final root datum has no effect on the ordered changes. -/
theorem public_build_batch_raw (h : Hash) (c : Codec) (t : TrieCommit) (r : PublishedRelease)
    (registry : PublicRegistry) (requests : List PendingRequest) (funding : FoldFunding) :
    changeBatch .none h c r (buildFold h c t r registry requests funding) =
      changeBatch .none h c r (publicRaw h c t r registry requests funding) := by
  let o := buildFold h c t r registry requests funding
  let raw := publicRaw h c t r registry requests funding
  have fields := public_raw_fields h c t r registry requests funding
  change o.changes.foldlM (fun trie action => change .none h c r trie action o) registry.trie =
    raw.changes.foldlM (fun trie action => change .none h c r trie action raw) registry.trie
  rw [← fields.2.2.2.2.1]
  apply public_batch_congr
  intro action member trie
  apply public_change_congr h c r o raw action trie fields.1 fields.2.1 fields.2.2.1 fields.2.2.2.1
    fields.2.2.2.2.1 fields.2.2.2.2.2.1
  cases action with
  | terminate => trivial
  | register reference key index deposit =>
    have allocated : Change.register reference key index deposit ∈ (publicPlan h c 0 requests).1 := by
      simpa only [o, public_build_changes] using member
    have bounds := public_plan_index_bounds h c 0 requests reference key index deposit allocated
    exact fields.2.2.2.2.2.2.1 index (by omega)

/-- Proof helper: distinct keys preserve every later operation's original leaf. -/
theorem public_ordered_success (h : Hash) (c : Codec) (r : PublishedRelease) (o : FoldObservation)
    (initial : Trie) (actions : List Change) (distinct : (actions.map Change.key).Nodup)
    (ready : ∀ action ∈ actions, ∀ trie, trieGet trie action.key = trieGet initial action.key →
      change .none h c r trie action o = .ok (targetTrie trie action))
    (trie : Trie) (retained : ∀ action ∈ actions, trieGet trie action.key = trieGet initial action.key) :
    actions.foldlM (fun trie action => change .none h c r trie action o) trie = .ok (actions.foldl targetTrie trie) := by
  induction actions generalizing trie with
  | nil => rfl
  | cons action rest ih =>
    have nd := List.nodup_cons.mp distinct
    simp only [List.foldlM_cons, List.foldl_cons]
    rw [ready action (by simp) trie (retained action (by simp))]
    simp only [bind, Except.bind]
    apply ih nd.2 (fun action member => ready action (List.mem_cons_of_mem _ member))
    intro later member
    have different : later.key ≠ action.key := by
      intro same
      exact nd.1 (List.mem_map.mpr ⟨later, member, same⟩)
    have unchanged : trieGet (targetTrie trie action) later.key = trieGet trie later.key := by
      cases action <;> apply Singular.trieGet_set_of_ne <;> exact different
    rw [unchanged]
    exact retained later (List.mem_cons_of_mem _ member)

/-- Proof helper: the constructed ordered changes return exactly the constructed trie. -/
theorem public_build_batch (h : Hash) (c : Codec) (t : TrieCommit) (q : Query)
    (p : PublicPremises h c t q) :
    let o := buildFold h c t q.release q.observation.before q.requests q.funding
    changeBatch .none h c q.release o = .ok o.after.trie := by
  let o := buildFold h c t q.release q.observation.before q.requests q.funding
  have distinct : (o.changes.map Change.key).Nodup := by
    rw [public_build_changes, public_plan_keys]
    exact p.1.2.2.1
  have success := public_ordered_success h c q.release o q.observation.before.trie o.changes distinct
    (public_build_change h c t q p) q.observation.before.trie (fun _ _ => rfl)
  have actual : changeBatch .none h c q.release o = .ok (o.changes.foldl targetTrie q.observation.before.trie) := success
  have raw := public_build_batch_raw h c t q.release q.observation.before q.requests q.funding
  have fields := public_raw_fields h c t q.release q.observation.before q.requests q.funding
  have result : o.after.trie = o.changes.foldl targetTrie q.observation.before.trie := by
    rw [fields.2.2.2.2.2.2.2, ← raw, actual]
  dsimp only
  rw [actual, result]

end SingularApplicationHeld.Proofs
