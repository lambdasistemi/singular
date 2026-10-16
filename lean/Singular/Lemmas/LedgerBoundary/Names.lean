import Singular.Model.LedgerBoundary

/-! Both inverses of the key-name representation. -/

namespace Singular.LedgerBoundary
open CardanoLedger

theorem keyOfName_keyName (key : Key) : keyOfName (keyName key) = key := by
  induction key using Nat.strongRecOn with
  | ind key ih =>
    rw [keyName]
    split
    · rename_i zero
      simp [keyOfName, zero]
    · rename_i nonzero
      rw [keyOfName, ih ((key - 1) / 256)
        (Nat.lt_of_le_of_lt (Nat.div_le_self _ _) (Nat.sub_lt (Nat.pos_of_ne_zero nonzero) (by decide)))]
      simp only [UInt8.toNat_ofNat', Nat.mod_mod, Nat.reducePow]
      have division := Nat.mod_add_div (key - 1) 256
      rw [Nat.add_right_comm, division, Nat.sub_add_cancel (Nat.pos_of_ne_zero nonzero)]

theorem keyName_keyOfName (name : AssetName) : keyName (keyOfName name) = name := by
  induction name with
  | nil => simp [keyOfName, keyName]
  | cons byte rest ih =>
    rw [keyOfName, keyName]
    have bound := byte.toNat_lt
    have positive : byte.toNat + 1 + 256 * keyOfName rest ≠ 0 := by omega
    rw [dif_neg positive]
    have quotient : (byte.toNat + 1 + 256 * keyOfName rest - 1) / 256 = keyOfName rest := by omega
    have remainder : (byte.toNat + 1 + 256 * keyOfName rest - 1) % 256 = byte.toNat := by omega
    rw [quotient, remainder, UInt8.ofNat_toNat, ih]

end Singular.LedgerBoundary
