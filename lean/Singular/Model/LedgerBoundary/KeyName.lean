import Singular.Model.LedgerBoundary.Instance

/-! A key names its token through a bijective numeral system. -/

namespace Singular.LedgerBoundary
open CardanoLedger

/-- Bijective base 256, least-significant digit first: the empty string is zero,
and a byte b contributes b+1, followed by 256 times the remaining digits.
Every finite byte string, including leading or trailing zero bytes, has its own
natural key. This is an abstraction, not a KERI identifier derivation. -/
def keyOfName : AssetName → Key
  | [] => 0
  | byte :: rest => byte.toNat + 1 + 256 * keyOfName rest

def keyName (key : Key) : AssetName :=
  if h : key = 0 then []
  else UInt8.ofNat ((key - 1) % 256) :: keyName ((key - 1) / 256)
termination_by key
decreasing_by
  change (key - 1) / 256 < key
  exact Nat.lt_of_le_of_lt (Nat.div_le_self _ _) (Nat.sub_lt (Nat.pos_of_ne_zero h) (by decide))

def tokenOf (world : RegistryWorld) (kind : TokenKind) (registry : AssetClass)
    (key : Key) : AssetClass := ⟨world.policyId kind registry, keyName key⟩

/-- The compiled state rule agrees with the admitted model batch and its exact
keyed mint. The batch and result are witnessed here; this premise does not
assert that any compiled validator has been checked. -/
def StateScriptFolds (world : RegistryWorld) (registry : AssetClass) : Prop :=
  ∀ tx input, input ∈ tx.inputs →
    input.resolved.address.payment = .script (world.hash .state) →
    input.resolved.value.assets.quantity registry = 1 →
    tx.redeemerOf (.spend input.reference) = some .fold →
    world.stateRule ⟨.spend input.reference, .fold, tx⟩ = true →
    ∃ state batch witness result,
      input.resolved.datum = some (.state state) ∧
      admittedFoldBatch state batch witness = .ok result ∧
      tx.validTo = some witness.validTo ∧
      ∀ kind key, tx.mint.quantity (tokenOf world kind registry key) =
        assetKind result.mint (kind, key)

end Singular.LedgerBoundary
