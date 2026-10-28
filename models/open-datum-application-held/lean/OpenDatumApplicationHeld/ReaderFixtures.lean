import OpenDatumApplicationHeld.MoneyBaseFixtures
import OpenDatumApplicationHeld.ReaderStatements
import SingularApplicationHeld.ReaderQuery

/-! Concrete reachable reader stories and their executable observations. -/
namespace OpenDatumApplicationHeld.ReaderFixtures
open Singular SingularApplicationHeld
open OpenDatumApplicationHeld.Fixtures (hash code commit release seed registryId decode registration)

def ordinary (reference : OutRef) (value : Nat) : ObservedOutput :=
  ⟨reference, 60, value, .empty, []⟩

def seedInput := ordinary seed 100
def registrationFunding := ordinary ⟨14, 0⟩ 1
def bookingFunding := ordinary ⟨15, 0⟩ 1
def terminationFunding := ordinary ⟨16, 0⟩ 1
def genesisState : ObservedOutput :=
  ⟨⟨21, 0⟩, release.statePolicy, 2, .root (commit []), [(registryId, 1)]⟩
def genesisChange := ordinary ⟨21, 1⟩ 98
def genesisRegistry : PublicRegistry := ⟨registryId, seed, genesisState, []⟩
def initialWorld : CandidateWorld :=
  ⟨[], [seedInput, registration.output, registrationFunding, bookingFunding, terminationFunding], [], []⟩
def genesisAssets : SingularApplicationHeld.Assets.TxView :=
  ⟨[seed], [⟨genesisState.assets⟩, ⟨genesisChange.assets⟩], [(registryId, 1)], [release.statePolicy]⟩

def nextWorld (before : CandidateWorld) (view : SingularApplicationHeld.Assets.TxView)
    (outputs : List ObservedOutput) (registries : List PublicRegistry) (domain : List Preimage) : CandidateWorld :=
  ⟨registries, before.unspent.filter (fun output => !view.spent.contains output.reference) ++ outputs,
    before.spentReferences ++ view.spent, domain⟩

def genesisWorld := nextWorld initialWorld genesisAssets [genesisState, genesisChange]
  [genesisRegistry] [.state seed]
def liveFold := buildFold hash code commit release genesisRegistry [registration]
  ⟨registrationFunding, 77, 30, ⟨5, 6⟩, 1⟩
def liveOutput : ObservedOutput := liveFold.outputs[1]?.getD registration.output
def liveWorld := nextWorld genesisWorld liveFold.assets liveFold.outputs [liveFold.after]
  (genesisWorld.domain ++ liveFold.changes.flatMap (SingularApplicationHeld.changePreimages liveFold))

def pendingOutput : ObservedOutput :=
  ⟨⟨31, 0⟩, release.applicationCredential, 1, .empty,
    [(activeAsset hash code registryId 7, 1), (terminationApproval hash code release registryId 7, 1)]⟩
def bookingAssets : SingularApplicationHeld.Assets.TxView :=
  ⟨[liveOutput.reference, bookingFunding.reference], [⟨pendingOutput.assets⟩],
    [(terminationApproval hash code release registryId 7, 1)], [release.applicationPolicy]⟩
def booking : ApplicationObservation :=
  ⟨bookingAssets, [liveOutput, bookingFunding], [pendingOutput], [], [], [42], ⟨5, 6⟩,
    0, 7, [.bookTermination liveOutput.reference 0]⟩
def pendingWorld := nextWorld liveWorld bookingAssets [pendingOutput] [liveFold.after] liveWorld.domain
def terminalFold := buildFold hash code commit release liveFold.after [.termination pendingOutput registryId 7]
  ⟨terminationFunding, 77, 32, ⟨5, 6⟩, 1⟩
def terminalWorld := nextWorld pendingWorld terminalFold.assets terminalFold.outputs [terminalFold.after]
  (pendingWorld.domain ++ terminalFold.changes.flatMap (SingularApplicationHeld.changePreimages terminalFold))

def request : ReaderRequest := ⟨42, registryId, 7⟩
def observedAt (world : CandidateWorld) (registry : PublicRegistry) (key : Key) : ReaderObservation :=
  ⟨.complete 42, some release,
    .complete (world.unspent.filter fun output => quantity output (activeAsset hash code registryId key) > 0),
    .complete (some registry.state), .complete registry.trie⟩
def live := observedAt liveWorld liveFold.after 7
def pending := observedAt pendingWorld liveFold.after 7
def terminal := observedAt terminalWorld terminalFold.after 7
def neverRegistered := observedAt terminalWorld terminalFold.after 9

set_option maxRecDepth 8192
set_option maxHeartbeats 4000000

local instance : LawfulBEq OutRef where
  eq_of_beq := by intro a b same; cases a; cases b; simp_all [reduceBEq]
  rfl := by intro a; cases a; simp [reduceBEq]
local instance : LawfulBEq TokenId where
  eq_of_beq := SingularApplicationHeld.Proofs.token_eq _ _
  rfl := by intro a; cases a; simp
local instance : LawfulBEq State where
  eq_of_beq := by intro a b same; cases a <;> cases b <;> simp_all [reduceBEq, State.ctorIdx]
  rfl := by intro a; cases a <;> rfl
local instance : LawfulBEq Leaf where
  eq_of_beq := by intro a b same; cases a <;> cases b <;> simp_all [reduceBEq]
  rfl := by intro a; cases a <;> simp
local instance : LawfulBEq ApplicationParameters where
  eq_of_beq := by intro a b same; cases a; cases b; simp_all [reduceBEq]
  rfl := by intro a; cases a; simp [reduceBEq]
local instance : LawfulBEq OutputDatum where
  eq_of_beq := by intro a b same; cases a <;> cases b <;> simp_all [reduceBEq]
  rfl := by intro a; cases a <;> simp [reduceBEq]
local instance : LawfulBEq ObservedOutput where
  eq_of_beq := by intro a b same; cases a; cases b; simp_all [reduceBEq]
  rfl := by intro a; cases a; simp [reduceBEq]
local instance : LawfulBEq PublicRegistry where
  eq_of_beq := by intro a b same; cases a; cases b; simp_all [reduceBEq]
  rfl := by intro a; cases a; simp [reduceBEq]

private theorem initial_reachable : CandidateReachable hash code commit release initialWorld := by
  apply CandidateReachable.initial
  · decide
  · decide

private theorem genesis_reachable : CandidateReachable hash code commit release genesisWorld := by
  refine CandidateReachable.genesis initial_reachable seed genesisAssets [seedInput]
    [genesisState, genesisChange] genesisRegistry 0 0 ?_ ?_ ?_ ?_ ?_ ?_ ?_ ?_ ?_ ?_
  · constructor <;> decide
  all_goals decide

private theorem live_reachable : CandidateReachable hash code commit release liveWorld := by
  refine CandidateReachable.fold genesis_reachable liveFold ?_ ?_ ?_ ?_ ?_
  · constructor <;> decide
  all_goals decide

private theorem pending_reachable : CandidateReachable hash code commit release pendingWorld := by
  refine CandidateReachable.neutral live_reachable bookingAssets [liveOutput, bookingFunding]
    [pendingOutput] 0 7 ?_ ?_ ?_ ?_ ?_
  · constructor <;> decide
  all_goals decide

private theorem terminal_reachable : CandidateReachable hash code commit release terminalWorld := by
  refine CandidateReachable.fold pending_reachable terminalFold ?_ ?_ ?_ ?_ ?_
  · constructor <;> decide
  all_goals decide

private theorem observed_correspondence (world : CandidateWorld) (registry : PublicRegistry) (key : Key)
    (identity : registry.identity = registryId) :
    ReaderEvidenceCorrespondence hash code world registry key (observedAt world registry key) := by
  refine ⟨?_, ?_, ?_⟩
  · intro outputs answer
    have same : world.unspent.filter (fun output => quantity output (activeAsset hash code registryId key) > 0) = outputs :=
      ReaderRead.complete.inj answer
    simpa [identity] using same.symm
  · intro output answer
    exact (Option.some.inj (ReaderRead.complete.inj answer)).symm
  · intro trie answer
    exact (ReaderRead.complete.inj answer).symm

private theorem live_history : HistoryPremises hash code commit release liveWorld liveFold.after 7 :=
  ⟨live_reachable, by decide, by unfold FiniteEncoding; decide, by unfold FiniteCollisionFree; decide⟩
private theorem pending_history : HistoryPremises hash code commit release pendingWorld liveFold.after 7 :=
  ⟨pending_reachable, by decide, by unfold FiniteEncoding; decide, by unfold FiniteCollisionFree; decide⟩
private theorem terminal_history : HistoryPremises hash code commit release terminalWorld terminalFold.after 7 :=
  ⟨terminal_reachable, by decide, by unfold FiniteEncoding; decide, by unfold FiniteCollisionFree; decide⟩
private theorem unknown_history : HistoryPremises hash code commit release terminalWorld terminalFold.after 9 :=
  ⟨terminal_reachable, by decide, by unfold FiniteEncoding; decide, by unfold FiniteCollisionFree; decide⟩

/-- Every positive story is attached to the original reachable-world relation. -/
theorem stories_reachable :
    CandidateReachable hash code commit release genesisWorld ∧
    CandidateReachable hash code commit release liveWorld ∧
    CandidateReachable hash code commit release pendingWorld ∧
    CandidateReachable hash code commit release terminalWorld := by
  exact ⟨genesis_reachable, live_reachable, pending_reachable, terminal_reachable⟩

/-- The concrete stories meet the soundness statements' complete antecedents. -/
theorem story_antecedents :
    HistoryPremises hash code commit release liveWorld liveFold.after 7 ∧
    ReaderEvidenceCorrespondence hash code liveWorld liveFold.after 7 live ∧
    HistoryPremises hash code commit release pendingWorld liveFold.after 7 ∧
    ReaderEvidenceCorrespondence hash code pendingWorld liveFold.after 7 pending ∧
    HistoryPremises hash code commit release terminalWorld terminalFold.after 7 ∧
    ReaderEvidenceCorrespondence hash code terminalWorld terminalFold.after 7 terminal ∧
    HistoryPremises hash code commit release terminalWorld terminalFold.after 9 ∧
    ReaderEvidenceCorrespondence hash code terminalWorld terminalFold.after 9 neverRegistered ∧
    applicationAction .none hash code decode release booking (.bookTermination liveOutput.reference 0) = true := by
  exact ⟨live_history, observed_correspondence liveWorld liveFold.after 7 (by decide),
    pending_history, observed_correspondence pendingWorld liveFold.after 7 (by decide),
    terminal_history, observed_correspondence terminalWorld terminalFold.after 7 (by decide),
    unknown_history, observed_correspondence terminalWorld terminalFold.after 9 (by decide), by decide⟩

/-- Four distinct answers from those exact reachable stories. -/
theorem story_answers :
    readKey hash code commit decode request live = .live liveOutput ∧
    readKey hash code commit decode request pending = .pendingTermination pendingOutput ∧
    readKey hash code commit decode request terminal = .terminal ⟨terminalFold.after.state, terminalFold.after.trie⟩ ∧
    readKey hash code commit decode {request with key := 9} neverRegistered =
      .neverRegistered ⟨terminalFold.after.state, terminalFold.after.trie⟩ := by
  decide

/-- Encode the very same observations for the generic reader executable. -/
def queryFor (request : ReaderRequest) (observed : ReaderObservation) : ReaderQuery :=
  let preimages := [Preimage.active request.registry request.key,
    .terminationApproval request.registry request.key]
  let codes := preimages.map fun p => CodeEntry.mk p (code p)
  let roots := match observed.trie with
    | .complete trie => [RootEntry.mk trie (commit trie)]
    | _ => []
  ⟨request, observed, codes, codes.map (fun entry => ⟨entry.encoded, hash entry.encoded⟩), roots,
    [(1007, .live (OpenDatumApplicationHeld.Fixtures.control 7) 123),
      (2007, .registration OpenDatumApplicationHeld.Fixtures.registrationData),
      (3007, .live {OpenDatumApplicationHeld.Fixtures.control 7 with registry := ⟨registryId.policy + 1, registryId.name⟩} 123),
      (3008, .live {OpenDatumApplicationHeld.Fixtures.control 7 with key := 8} 123),
      (3009, .live {OpenDatumApplicationHeld.Fixtures.control 7 with activeAsset := ⟨registryId.policy + 1, (activeAsset hash code registryId 7).name⟩} 123)]⟩

/-- Positive observations and single-atom evidence defects. Results are computed
by runReaderQuery, not entered into this corpus. -/
def corpus : List (String × ReaderQuery) :=
  [("live", queryFor request {live with state := .missing, trie := .missing}),
   ("pending termination", queryFor request pending),
   ("terminal", queryFor request terminal),
   ("never registered", queryFor {request with key := 9} neverRegistered),
   ("empty asset answer without state", queryFor request {live with activeOutputs := .complete [], state := .missing, trie := .missing}),
   ("failed network read", queryFor request {live with network := .failed "provider unavailable"}),
   ("incomplete asset answer", queryFor request {live with activeOutputs := .incomplete "truncated page"}),
   ("failed asset read", queryFor request {live with activeOutputs := .failed "provider unavailable"}),
   ("failed state read", queryFor request {terminal with state := .failed "provider unavailable"}),
   ("state not found", queryFor request {terminal with state := .complete none}),
   ("failed trie read", queryFor request {terminal with trie := .failed "provider unavailable"}),
   ("wrong network", queryFor request {live with network := .complete 43}),
   ("unknown state policy", queryFor request {live with release := none}),
   ("foreign state policy", queryFor request {live with release := some {release with statePolicy := 11}}),
   ("token at state address", queryFor request {live with activeOutputs := .complete [{liveOutput with credential := registryId.policy}]}),
   ("application credential equals the state policy", queryFor request {live with release := some {release with applicationCredential := registryId.policy}, activeOutputs := .complete [{liveOutput with credential := registryId.policy}]}),
   ("token at another address", queryFor request {live with activeOutputs := .complete [{liveOutput with credential := 60}]}),
   ("token at the application policy credential", queryFor request {live with activeOutputs := .complete [{liveOutput with credential := release.applicationPolicy}]}),
   ("two outputs", queryFor request {live with activeOutputs := .complete [liveOutput, {liveOutput with reference := ⟨40, 0⟩}]}),
   ("non-unit quantity", queryFor request {live with activeOutputs := .complete [{liveOutput with assets := [(activeAsset hash code registryId 7, 2)]}]}),
   ("unrecognised state", queryFor request {terminal with state := .complete (some {terminalFold.after.state with datum := .empty})}),
   ("state with extra assets", queryFor request {terminal with state := .complete (some {terminalFold.after.state with assets := terminalFold.after.state.assets ++ [(⟨90, 91⟩, 1)]})}),
   ("trie root mismatch", queryFor request {terminal with state := .complete (some {terminalFold.after.state with datum := .root 0})}),
   ("unknown holding datum", queryFor request {live with activeOutputs := .complete [{liveOutput with datum := .application 9999}]}),
   ("registration datum with active token", queryFor request {live with activeOutputs := .complete [{liveOutput with datum := .application 2007}]}),
   ("uncovered live deposit", queryFor request {live with activeOutputs := .complete [{liveOutput with lovelace := 6}]}),
   ("live control for another registry", queryFor request {live with activeOutputs := .complete [{liveOutput with datum := .application 3007}]}),
   ("live control for another key", queryFor request {live with activeOutputs := .complete [{liveOutput with datum := .application 3008}]}),
   ("live control names another asset", queryFor request {live with activeOutputs := .complete [{liveOutput with datum := .application 3009}]}),
   ("state at another credential", queryFor request {terminal with state := .complete (some {terminalFold.after.state with credential := 60})}),
   ("state asset under another policy", queryFor request {terminal with state := .complete (some {terminalFold.after.state with assets := [(⟨registryId.policy + 1, registryId.name⟩, 1)]})}),
   ("state asset with another name", queryFor request {terminal with state := .complete (some {terminalFold.after.state with assets := [(⟨registryId.policy, registryId.name + 1⟩, 1)]})}),
   ("non-unit state asset", queryFor request {terminal with state := .complete (some {terminalFold.after.state with assets := [(registryId, 2)]})}),
   ("termination without approval", queryFor request {pending with activeOutputs := .complete [{pendingOutput with assets := [(activeAsset hash code registryId 7, 1)]}]}),
   ("live datum beside a termination approval", queryFor request {pending with activeOutputs := .complete [{pendingOutput with lovelace := 7, datum := .application 1007}]}),
   ("active leaf without token", queryFor request {live with activeOutputs := .complete []}),
   ("known absent leaf without token", queryFor request {terminal with
     state := .complete (some {terminalFold.after.state with datum := .root (commit [(7, .known .absent)])}),
     trie := .complete [(7, .known .absent)]})]

end OpenDatumApplicationHeld.ReaderFixtures
