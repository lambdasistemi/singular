import OpenDatumApplicationHeld.MoneyBaseFixtures
import OpenDatumApplicationHeld.ReaderStatements
import SingularApplicationHeld.ReaderQuery

/-! Concrete proposed reader stories. Reachability certificates remain open
at the statement checkpoint, independently of the executable classifications. -/
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

/-- Every positive story is attached to the original reachable-world relation. -/
theorem stories_reachable :
    CandidateReachable hash code commit release genesisWorld ∧
    CandidateReachable hash code commit release liveWorld ∧
    CandidateReachable hash code commit release pendingWorld ∧
    CandidateReachable hash code commit release terminalWorld := by sorry

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
    applicationAction .none hash code decode release booking (.bookTermination liveOutput.reference 0) = true := by sorry

/-- Four distinct answers from those exact reachable stories. -/
theorem story_answers :
    readKey hash code commit decode request live = .live liveOutput ∧
    readKey hash code commit decode request pending = .pendingTermination pendingOutput ∧
    readKey hash code commit decode request terminal = .terminal ⟨terminalFold.after.state, terminalFold.after.trie⟩ ∧
    readKey hash code commit decode {request with key := 9} neverRegistered =
      .neverRegistered ⟨terminalFold.after.state, terminalFold.after.trie⟩ := by sorry

/-- Encode the very same observations for the generic reader executable. -/
def queryFor (request : ReaderRequest) (observed : ReaderObservation) : ReaderQuery :=
  let preimages := [Preimage.active request.registry request.key,
    .terminationApproval request.registry request.key]
  let codes := preimages.map fun p => CodeEntry.mk p (code p)
  let roots := match observed.trie with
    | .complete trie => [RootEntry.mk trie (commit trie)]
    | _ => []
  ⟨request, observed, codes, codes.map (fun entry => ⟨entry.encoded, hash entry.encoded⟩), roots,
    [(1007, .live (OpenDatumApplicationHeld.Fixtures.control 7) 123)]⟩

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
   ("failed trie read", queryFor request {terminal with trie := .failed "provider unavailable"}),
   ("wrong network", queryFor request {live with network := .complete 43}),
   ("unknown state policy", queryFor request {live with release := none}),
   ("foreign state policy", queryFor request {live with release := some {release with statePolicy := 11}}),
   ("token at state address", queryFor request {live with activeOutputs := .complete [{liveOutput with credential := registryId.policy}]}),
   ("token at another address", queryFor request {live with activeOutputs := .complete [{liveOutput with credential := 60}]}),
   ("two outputs", queryFor request {live with activeOutputs := .complete [liveOutput, {liveOutput with reference := ⟨40, 0⟩}]}),
   ("non-unit quantity", queryFor request {live with activeOutputs := .complete [{liveOutput with assets := [(activeAsset hash code registryId 7, 2)]}]}),
   ("unrecognised state", queryFor request {terminal with state := .complete (some {terminalFold.after.state with datum := .empty})}),
   ("trie root mismatch", queryFor request {terminal with state := .complete (some {terminalFold.after.state with datum := .root 0})}),
   ("unknown holding datum", queryFor request {live with activeOutputs := .complete [{liveOutput with datum := .application 9999}]}),
   ("active leaf without token", queryFor request {live with activeOutputs := .complete []})]

end OpenDatumApplicationHeld.ReaderFixtures
