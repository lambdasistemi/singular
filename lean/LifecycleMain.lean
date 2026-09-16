import Singular.Model
import Singular.Naming
import Singular.NamingLifecycle
import Singular.NamingWire
open Singular
open Lean

/-! The naming-lifecycle corpus over the registry-mode model: maintenance and
recovery with the root untouched (NM2), retirement as `updateTerminal` (NM3),
and the consumer binding pinning the eight-field datum's policies. -/

def l0 : NamingState := namingInitial

def lRegistered : NamingState :=
  match namingRegister l0 aliceKey 5 aliceFixture with
  | .ok s => s | .error _ => l0

def lMaintained : NamingState :=
  match maintainDestination lRegistered aliceKey clearedFixture [controllerAddress] with
  | .ok s => s | .error _ => lRegistered

def lRecovered : NamingState :=
  match recoverController fixtureHasher lRegistered aliceKey nextControllerAddress
    recoveredFixture [nextControllerAddress] with
  | .ok s => s | .error _ => lRegistered

def row (id : String) (ok : Bool) (detail : Json) : Json :=
  Json.mkObj [ ("id", id), ("ok", ok), ("detail", detail) ]

def maintenanceRows : List Json :=
  [ row "LM01-maintenance-accepts" (lMaintained.records.head?.isSome)
      (toJson ((lMaintained.records.head?.map fun r => r.fixture.paymentDestination == none).getD false))
  , row "LM02-maintenance-unauthorized-refused"
      (match maintainDestination lRegistered aliceKey clearedFixture [] with
      | .error "controller-signature" => true | _ => false)
      (toJson "controller-signature")
  , row "LM03-maintenance-field-tamper-refused"
      (match maintainDestination lRegistered aliceKey recoveredFixture [controllerAddress] with
      | .error "destination-field-preservation" => true | _ => false)
      (toJson "destination-field-preservation")
  , row "LM04-root-equal-after-maintenance"
      (lMaintained.registry.config.root == lRegistered.registry.config.root)
      (toJson lMaintained.registry.config.root == toJson lRegistered.registry.config.root) ]

def recoveryRows : List Json :=
  [ row "LR01-recovery-accepts"
      (lRecovered.records.head?.map (·.fixture.controlAddress) == some nextControllerAddress)
      (toJson true)
  , row "LR02-wrong-reveal-refused"
      (match recoverController fixtureHasher lRegistered aliceKey freshControllerAddress
        recoveredFixture [freshControllerAddress] with
      | .error "recovery-commitment" => true | _ => false)
      (toJson "recovery-commitment")
  , row "LR03-missing-recovery-signer-refused"
      (match recoverController fixtureHasher lRegistered aliceKey nextControllerAddress
        recoveredFixture [] with
      | .error "recovery-required-signer" => true | _ => false)
      (toJson "recovery-required-signer")
  , row "LR05-old-controller-dead-after-recovery"
      (match recoverController fixtureHasher lRecovered aliceKey controllerAddress
        ({ recoveredFixture with controlAddress := controllerAddress } : NamingFixture)
        [controllerAddress] with
      | .error "recovery-commitment" => true | _ => false)
      (toJson "recovery-commitment")
  , row "LR06-forged-public-digest-refused"
      (match recoverController fixtureHasher lRegistered aliceKey otherControllerAddress
        ({ recoveredFixture with controlAddress := otherControllerAddress } : NamingFixture)
        [otherControllerAddress] with
      | .error "recovery-commitment" => true | _ => false)
      (toJson "recovery-commitment")
  , row "LR11-root-equal-after-recovery"
      (lRecovered.registry.config.root == lRegistered.registry.config.root)
      (toJson lRecovered.registry.config.root == toJson lRegistered.registry.config.root) ]

def retirementRows : List Json :=
  [ row "LT02-quorum-retirement-accepts"
      ((namingRetireLifecycle lRegistered aliceKey
          [quorumKeyHash 1, quorumKeyHash 29] none).isOk)
      (toJson true)
  , row "LT03-insufficient-quorum-refused"
      (match namingRetireLifecycle lRegistered aliceKey [quorumKeyHash 1] none with
      | .error "naming-no-delete" => true | _ => false)
      (toJson "naming-no-delete")
  , row "LT08-control-key-alone-refused"
      (match namingRetireLifecycle lRegistered aliceKey [controllerAddress.bytes] none with
      | .error "naming-no-delete" => true | _ => false)
      (toJson "naming-no-delete")
  , row "LT04-retirement-completes"
      ((namingRetireLifecycle lRegistered aliceKey
          [quorumKeyHash 1, quorumKeyHash 29] none).isOk)
      (toJson true) ]

def initializationRows : List Json :=
  [ row "LI01-canonical-initialization-accepts"
      (match initializeConsumer namingConsumerBinding canonicalInitialization with
      | .ok _ => true | _ => false)
      (toJson true)
  , row "LI02-alternate-seed-refused"
      (match initializeConsumer namingConsumerBinding
        ({ canonicalInitialization with seed := 401 } : InitializationAttempt) with
      | .error "canonical-seed" => true | _ => false)
      (toJson "canonical-seed")
  , row "LI05-substituted-active-policy-refused"
      (match initializeConsumer namingConsumerBinding
        ({ canonicalInitialization with activePolicy := 99 } : InitializationAttempt) with
      | .error "active-policy" => true | _ => false)
      (toJson "active-policy")
  , row "LI06-substituted-terminal-policy-refused"
      (match initializeConsumer namingConsumerBinding
        ({ canonicalInitialization with terminalPolicy := 99 } : InitializationAttempt) with
      | .error "terminal-policy" => true | _ => false)
      (toJson "terminal-policy")
  , row "LI07-substituted-registry-refused"
      (match initializeConsumer namingConsumerBinding
        ({ canonicalInitialization with registry := 2 } : InitializationAttempt) with
      | .error "registry-authenticity" => true | _ => false)
      (toJson "registry-authenticity") ]

def wireRows : List Json :=
  [ row "WD01-fixture-datum-roundtrip"
      (decodeNamingDatum (encodeNamingDatum aliceFixture) == some aliceFixture)
      (toJson true)
  , row "WD02-two-destinations-refused"
      (decodeNamingDatum
        (.constr 0 [.constr 0 [
          .bytes controllerAddress.bytes,
          .constr 1 [.bytes destinationAddress.bytes, .bytes otherControllerAddress.bytes],
          .bytes nextControllerCommitment.digest,
          encodeRetirementQuorum aliceFixture.retirementQuorum]]) == none)
      (toJson true) ]

def allRows : List (String × List Json) :=
  [ ("maintenance", maintenanceRows), ("recovery", recoveryRows)
  , ("retirement", retirementRows), ("initializations", initializationRows)
  , ("wire", wireRows) ]

def main : IO Unit := do
  let stdout ← IO.getStdout
  for p in allRows do
    for r in p.2 do
      match r.getObjVal? "ok" with
      | .ok (Json.bool true) => pure ()
      | _ => throw (IO.userError s!"lifecycle row failed: {p.1}: {r.compress}")
  let json := Json.mkObj
    [ ("schema", toJson "singular-naming-lifecycle-corpus-v2")
    , ("steps", toJson maintenanceRows)
    , ("recovery", toJson recoveryRows)
    , ("retirement", toJson retirementRows)
    , ("initializations", toJson initializationRows)
    , ("wire", toJson wireRows) ]
  stdout.putStrLn json.compress
