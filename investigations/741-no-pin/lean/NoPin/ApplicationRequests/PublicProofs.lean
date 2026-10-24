import NoPin.ApplicationRequests.MintedProofs

/-! Hypothetical public construction proof helpers, not accepted law. -/
set_option maxHeartbeats 2000000
set_option maxRecDepth 8192
namespace NoPin.ApplicationRequests.Proofs
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

/-- Hypothesis proof helper: a physical output compares equal to itself. -/
theorem public_output_refl (output : ObservedOutput) : (output == output) = true := by
  cases output with
  | mk reference credential lovelace datum assets =>
    have rr : instBEqOutRef.beq reference reference = true := by
      change (reference == reference) = true
      simp
    have aa : assets.beq assets = true := by
      change (assets == assets) = true
      simp
    cases datum <;> simp [BEq.beq, instBEqObservedOutput.beq, instBEqOutputDatum.beq,
      instBEqApplicationParameters.beq, rr, aa]

local instance : ReflBEq ObservedOutput where
  rfl := public_output_refl _

/-- Hypothesis proof helper: the unmutated application selector preserves its guard. -/
@[simp] theorem appGuard_none (site : AppGuard) (b : Bool) : appGuard .none site b = b := by rfl

/-- Hypothesis proof helper: a request's allocated new holding. -/
def publicHolding (h : Hash) (c : Codec) (d : RegistrationData) : ObservedOutput :=
  ⟨⟨0, 0⟩, d.holdingAddress, d.deposit, .application d.initialDatum,
    [(activeAsset h c d.registry d.key, 1)]⟩

/-- Hypothesis proof helper: the builder's order with an explicit holding offset. -/
def publicPlan (h : Hash) (c : Codec) : Nat → List PendingRequest → List Change × List ObservedOutput
  | _, [] => ([], [])
  | n, .registration o d :: rest =>
      let tail := publicPlan h c (n + 1) rest
      (.register o.reference d.key (n + 1) d.deposit :: tail.1, publicHolding h c d :: tail.2)
  | n, .termination o _ key :: rest =>
      let tail := publicPlan h c n rest
      (.terminate o.reference key :: tail.1, tail.2)

/-- Hypothesis proof helper: append-based allocation equals the recursive plan. -/
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

/-- Hypothesis proof helper: exact correspondence to the frozen allocator. -/
theorem public_prepare (h : Hash) (c : Codec) (requests : List PendingRequest) :
    prepareChanges h c requests = publicPlan h c 0 requests := by
  simpa [prepareChanges, publicHolding] using public_prepare_acc h c requests [] []

/-- Hypothesis proof helper: allocation retains every public request reference. -/
theorem public_plan_refs (h : Hash) (c : Codec) (n : Nat) (requests : List PendingRequest) :
    ((publicPlan h c n requests).1.map Change.reference) = requests.map (·.output.reference) := by
  induction requests generalizing n with
  | nil => rfl
  | cons request rest ih => cases request <;> simp [publicPlan, Change.reference, PendingRequest.output, ih]

/-- Hypothesis proof helper: allocation retains the logical keys. -/
theorem public_plan_keys (h : Hash) (c : Codec) (n : Nat) (requests : List PendingRequest) :
    ((publicPlan h c n requests).1.map Change.key) = requests.map PendingRequest.key := by
  induction requests generalizing n with
  | nil => rfl
  | cons request rest ih => cases request <;> simp [publicPlan, Change.key, PendingRequest.key, ih]

/-- Hypothesis proof helper: holding value is the sum of committed registration deposits. -/
theorem public_plan_value (h : Hash) (c : Codec) (n : Nat) (requests : List PendingRequest) :
    ((publicPlan h c n requests).2.map (·.lovelace)).sum =
      (requests.map fun r => match r with | .registration _ d => d.deposit | .termination .. => 0).sum := by
  induction requests generalizing n with
  | nil => rfl
  | cons request rest ih => cases request <;> simp [publicPlan, publicHolding, ih]

/-- Hypothesis proof helper: renumbering does not change the value of outputs. -/
theorem public_numbered_value (tx : Nat) (outputs : List ObservedOutput) :
    ((numbered tx outputs).map (·.lovelace)).sum = (outputs.map (·.lovelace)).sum := by
  unfold numbered
  simp only [List.map_map, Function.comp_def]
  change (outputs.zipIdx.map ((fun o : ObservedOutput => o.lovelace) ∘ Prod.fst)).sum = _
  rw [← List.map_map, List.zipIdx_map_fst]

/-- Hypothesis proof helper: every public input is spent in the constructed view. -/
theorem public_build_spent (h : Hash) (c : Codec) (t : TrieCommit) (r : PublishedRelease)
    (registry : PublicRegistry) (requests : List PendingRequest) (funding : FoldFunding) :
    (buildFold h c t r registry requests funding).assets.spent =
      (registry.state :: requests.map PendingRequest.output ++ [funding.ordinaryInput]).map (·.reference) := by
  rfl

/-- Hypothesis proof helper: construction keeps the actual inputs. -/
theorem public_build_inputs (h : Hash) (c : Codec) (t : TrieCommit) (r : PublishedRelease)
    (registry : PublicRegistry) (requests : List PendingRequest) (funding : FoldFunding) :
    (buildFold h c t r registry requests funding).spentOutputs =
      registry.state :: requests.map PendingRequest.output ++ [funding.ordinaryInput] := by
  rfl

/-- Hypothesis proof helper: a public fold has no required signer. -/
theorem public_build_signers (h : Hash) (c : Codec) (t : TrieCommit) (r : PublishedRelease)
    (registry : PublicRegistry) (requests : List PendingRequest) (funding : FoldFunding) :
    (buildFold h c t r registry requests funding).signers = [] := by
  rfl

/-- Hypothesis proof helper: construction uses the allocator's exact ordered changes. -/
theorem public_build_changes (h : Hash) (c : Codec) (t : TrieCommit) (r : PublishedRelease)
    (registry : PublicRegistry) (requests : List PendingRequest) (funding : FoldFunding) :
    (buildFold h c t r registry requests funding).changes = (publicPlan h c 0 requests).1 := by
  change (prepareChanges h c requests).1 = _
  rw [public_prepare]

/-- Hypothesis proof helper: projected values commute with arbitrary output numbering. -/
theorem public_numbering_value (tx n : Nat) (outputs : List ObservedOutput) :
    ((outputs.zipIdx n |>.map fun (o, i) => { o with reference := ⟨tx, i⟩ }).map (·.lovelace)).sum =
      (outputs.map (·.lovelace)).sum := by
  simp only [List.map_map, Function.comp_def]
  change ((outputs.zipIdx n).map ((fun o : ObservedOutput => o.lovelace) ∘ Prod.fst)).sum = _
  rw [← List.map_map, List.zipIdx_map_fst]

/-- Hypothesis proof helper: continuing the root changes no output value. -/
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

/-- Hypothesis proof helper: the bid and protected deposit partition each authentic request value. -/
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

/-- Hypothesis proof helper: ordinary fee funding makes public construction balance exactly. -/
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

/-- Hypothesis proof helper: a request contributes exactly one change. -/
theorem public_plan_length (h : Hash) (c : Codec) (n : Nat) (requests : List PendingRequest) :
    (publicPlan h c n requests).1.length = requests.length := by
  induction requests generalizing n with
  | nil => rfl
  | cons request rest ih => cases request <;> simp [publicPlan, ih]

/-- Hypothesis proof helper: all created holdings are the request-derived carriers. -/
theorem public_plan_holdings (h : Hash) (c : Codec) (n : Nat) (requests : List PendingRequest) :
    (publicPlan h c n requests).2 = requests.filterMap (fun request => match request with
      | .registration _ data => some (publicHolding h c data) | .termination .. => none) := by
  induction requests generalizing n with
  | nil => rfl
  | cons request rest ih => cases request <;> simp [publicPlan, ih]

/-- Hypothesis proof helper: every allocated registration index follows the existing prefix. -/
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

/-- Hypothesis proof helper: an allocated registration index identifies its source request and carrier. -/
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

/-- Hypothesis proof helper: an allocated termination identifies its public source request. -/
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

/-- Hypothesis proof helper: no two registration references share an allocated output index. -/
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

/-- Hypothesis proof helper: allocated changes meet the separate-carrier guard. -/
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

/-- Hypothesis proof helper: continuation preserves state address, value and asset contents. -/
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

/-- Hypothesis proof helper: every constructed output belongs to the requested new transaction. -/
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

/-- Hypothesis proof helper: no new output reference is among the construction's spent inputs. -/
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

/-- Hypothesis proof helper: every new holding satisfies the no-new-output-consumed guard. -/
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

/-- Hypothesis proof helper: the genuine before state is spent exactly once. -/
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

/-- Hypothesis proof helper: construction adds only the request approvals to its exact active delta. -/
theorem public_build_mint (h : Hash) (c : Codec) (t : TrieCommit) (r : PublishedRelease)
    (registry : PublicRegistry) (requests : List PendingRequest) (funding : FoldFunding) :
    let o := buildFold h c t r registry requests funding
    o.assets.mint = expectedDelta h c o ++ requests.map (fun request => (
      (match request with
       | .registration _ data => registrationAsset h c r data
       | .termination _ registry key => terminationApproval h c r registry key), (-1 : Int))) := by
  rfl

/-- Hypothesis proof helper: a different policy cannot change any quantity under this policy. -/
theorem public_other_policy_filter (entries : List (TokenId × Int)) (asset : TokenId)
    (policy : Nat) (own : asset.policy = policy)
    (other : ∀ entry ∈ entries, entry.1.policy ≠ policy) :
    entries.filter (fun entry => entry.1 == asset) = [] := by
  apply List.filter_eq_nil_iff.mpr
  intro entry member same
  have equal := token_eq _ _ same
  exact other entry member (by rw [equal, own])

/-- Hypothesis proof helper: the constructed transaction has the exact whole state-policy delta. -/
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
      NoPin.mintQty o.assets asset == ((expectedDelta h c o).filter (fun entry => entry.1 == asset) |>.map (·.2)).sum) = true
    simp only [NoPin.mintQty, mint, List.filter_append, noApprovals, List.append_nil]
    simp
  · change (asset.policy != registry.identity.policy || _) = true
    simp [own]

/-- Hypothesis proof helper: distinct public references stay distinct after allocation. -/
theorem public_build_distinct (h : Hash) (c : Codec) (t : TrieCommit) (r : PublishedRelease)
    (registry : PublicRegistry) (requests : List PendingRequest) (funding : FoldFunding)
    (distinct : (requests.map (·.output.reference)).Nodup) :
    ((buildFold h c t r registry requests funding).changes.map Change.reference).Nodup := by
  simpa only [public_build_changes, public_plan_refs] using distinct

/-- Hypothesis proof helper: construction never loses all changes from a nonempty request set. -/
theorem public_build_nonempty (h : Hash) (c : Codec) (t : TrieCommit) (r : PublishedRelease)
    (registry : PublicRegistry) (requests : List PendingRequest) (funding : FoldFunding)
    (nonempty : requests ≠ []) :
    (buildFold h c t r registry requests funding).changes.isEmpty = false := by
  rw [public_build_changes]
  cases requests with
  | nil => exact (nonempty rfl).elim
  | cons request rest => cases request <;> rfl

/-- Hypothesis proof helper: the remaining obligation for public construction is fold acceptance. -/
theorem public_conclusion_of_fold (h : Hash) (c : Codec) (t : TrieCommit) (q : Query)
    (p : PublicPremises h c t q)
    (accepted : fold .none h c t q.release
      (buildFold h c t q.release q.observation.before q.requests q.funding) = true) :
    PublicConclusion .none h c t q := by
  exact ⟨accepted, public_build_signers .., public_build_spent ..,
    public_build_balance h c t q.release q.observation.before q.requests q.funding p.1⟩

/-- Hypothesis proof helper: constructed acceptance supplies the independent effects and frame. -/
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

/-- Hypothesis proof helper: isolate the three outstanding acceptance obligations.
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

end NoPin.ApplicationRequests.Proofs
