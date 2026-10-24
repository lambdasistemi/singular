import NoPin.ApplicationRequests.MoneyClaims
import NoPin.ApplicationRequests.RefundLifecycleFixtures

/-! Hypothetical finite comparisons under #741, not accepted law. Positive
identities and amounts come from the accepted or candidate producers. The
chosen input amounts are registration 23, deposit 7, old cost 13 and old tip 3;
termination 10, old tip 2 and old carrier 8. Fees use separate ordinary inputs. -/
namespace NoPin.ApplicationRequests.Money.Fixtures
open Singular Lean NoPin.ApplicationRequests.Fixtures

/-- Hypothesis under #741, not accepted law; accepted immutable parameters. -/
def configuration : Config := {
  root := rootOf [], minimumTip := 2, processTime := 19, retractTime := 10,
  applicationPolicy := 5, activePolicy := 10, absentPolicy := 11, terminalPolicy := 12,
  registryId := 42, registrationCost := 13, bookingWidth := 1 }
/-- Hypothesis under #741, not accepted law; accepted booking with producer-derived contents and tags. -/
def oldRegistration : Singular.RegistrationBooking :=
  let r : Singular.RegistrationRequest := {
    reference := registration.output.reference, registryId := configuration.registryId,
    key := registration.key, refundAddress := registrationData.refundAddress,
    destination := registrationData.holdingAddress, submittedAt := registrationData.bookedAt,
    registrationCost := configuration.registrationCost, declaredTip := 3, carrierAda := registrationData.deposit,
    contents := ⟨0, [], [], []⟩, datum := some registrationData.initialDatum, nonce := registration.key }
  let tag : Approval := {
    policy := configuration.applicationPolicy, edge := .insertActive,
    key := r.key, owner := r.refundAddress, destination := r.destination,
    assetName := applicationTagAssetName r.key r.refundAddress r.destination r.nonce }
  let r := { r with contents := ⟨registrationDeclaredLovelace r, [tag], [r.trieReadyTag configuration], []⟩ }
  ⟨r, ⟨0, r.submittedAt⟩, r.contents.trieReadyTags, r.contents.applicationTags⟩
/-- Hypothesis under #741, not accepted law; accepted termination payload, separate from protected control. -/
def oldTermination : Singular.TerminationBooking :=
  let r : Singular.TerminationRequest := {
    reference := termination.output.reference, registryId := configuration.registryId,
    key := termination.key, destination := release.applicationCredential, declaredTip := 2, carrierAda := 8,
    singularTags := [configuration.singularTag termination.key], contents := ⟨0, [], [], []⟩,
    nonce := termination.key }
  let r := { r with contents := ⟨terminationDeclaredLovelace r, [], [r.trieReadyTag configuration], []⟩ }
  ⟨r, [⟨r.key, .active, r.destination, none⟩], r.contents.trieReadyTags⟩
/-- Hypothesis under #741, not accepted law; no copied payment oracle. -/
def baseline : Baseline := ⟨configuration, oldRegistration, oldTermination, registrationData.deposit⟩
/-- Hypothesis under #741, not accepted law; retained consumer identity is explicit, not equated with new credentials. -/
def oldApplication : OpenDatumApplication.App := ⟨⟨42, 0⟩, configuration.applicationPolicy⟩
/-- Hypothesis under #741, not accepted law; synthetic old live snapshot for a bounded update observation. -/
def oldLive : OpenDatumApplication.AppOutput := {
  ref := 0, address := OpenDatumApplication.appAddress oldApplication, lovelace := 17,
  assets := [((.active, 8), 1)], envelope := {
    control := ⟨OpenDatumApplication.envelopeVersion, oldApplication.registry, configuration.activePolicy,
      8, 42, registrationData.deposit⟩,
    payload := .int 124 } }
/-- Hypothesis under #741, not accepted law; this snapshot is not a claimed economic/consumer composition. -/
def oldApplicationWorld : OpenDatumApplication.World :=
  { OpenDatumApplication.genesis oldApplication configuration oldApplication.registry with
    outputs := [oldLive], nextRef := 1 }
/-- Hypothesis under #741, not accepted law; payload changes while control, token and deposit stay fixed. -/
def oldSuccessor : OpenDatumApplication.Successor := {
  address := oldLive.address, lovelace := oldLive.lovelace, assets := oldLive.assets,
  envelope := { oldLive.envelope with payload := .int 125 } }
/-- Hypothesis under #741, not accepted law; same transaction creates state and immutable parameter record. -/
def createObservation : ApplicationObservation :=
  let state := { NoPin.ApplicationRequests.Fixtures.registry.state with datum := .root (commit []) }
  let metadata := { RefundLifecycle.Fixtures.configuration with datum := .configuration (parametersOf baseline) }
  let ordinary : ObservedOutput := ⟨seed, 60, state.lovelace + metadata.lovelace, .empty, []⟩
  RefundLifecycle.Fixtures.observation [ordinary] [state, metadata]
    [(registryId, 1), (configurationAsset hash code release registryId, 1)]
    [.configurationCreate registryId seed 1]
/-- Hypothesis under #741, not accepted law; each stage uses the actual application observation. -/
def input (journey : Journey) : Input :=
  let name := match journey with
    | .create => "configurationCreate" | .registrationBooking => "bookRegistration"
    | .registrationFold => "registrationFold" | .update => "liveUpdate"
    | .terminationBooking => "bookTermination" | .terminationFold => "terminationFold"
    | .reclaim | .earlyRejection => "ownerReclaim" | .cleanup => "expiredCleanup"
    | .unsupportedBooking => "bookRegistration" | .liveWithdrawal => "liveUpdate"
  let life := RefundLifecycle.Fixtures.inputFor name
  let life := if journey == .create then
      { life with
        observation := createObservation,
        action := createObservation.actions.head?.getD .approvalBurn }
    else life
  let life := if journey == .cleanup then
      let o := life.observation
      let cleaner : ObservedOutput := ⟨⟨18, 1⟩, funding.processorAddress,
        registration.output.lovelace - registrationData.deposit, .empty, []⟩
      let outputs := o.outputs ++ [cleaner]
      { life with
        observation := { o with
          outputs := outputs
          assets := { o.assets with outputs := outputs.map (fun output => ⟨output.assets⟩) } } }
    else life
  let life := if journey == .earlyRejection then
      { life with observation := { life.observation with interval := ⟨5, 6⟩ } }
    else if journey == .unsupportedBooking then
      { life with observation := { life.observation with actions := [] } }
    else if journey == .liveWithdrawal then
      let outputs := life.observation.outputs.map fun output => { output with credential := 60 }
      { life with observation := { life.observation with outputs } }
    else life
  ⟨life, baseline, registration, termination, registrationData.deposit⟩

end NoPin.ApplicationRequests.Money.Fixtures
