import Lean

/-! Leaf states, token kinds and their codecs. -/

namespace Singular
open Lean

/-- The key a leaf is filed under. -/
abbrev Key := Nat

instance : ToJson ByteArray where
  toJson b := toJson (b.toList.map (·.toNat))

instance : FromJson ByteArray where
  fromJson? j := do
    let l : List Nat ← fromJson? j
    if l.all (· < 256) then pure (ByteArray.mk (l.map (fun n => (n % 256).toUInt8)).toArray)
    else throw "byte out of range"

/-- The three lifecycle states — the only leaf vocabulary. -/
inductive State where
  | absent | active | terminal
  deriving Repr, BEq, DecidableEq, ToJson, FromJson

/-- One leaf per key: `unknown` is a non-membership proof, `known s` a
membership proof whose value is `s`. No application payload, no version
counter, no incarnation. -/
inductive Leaf where
  | unknown | known (s : State)
  deriving Repr, BEq, DecidableEq, ToJson, FromJson

/-- The codec byte of a state: `0x00` Absent, `0x01` Active, `0x02` Terminal. -/
def stateByte (s : State) : UInt8 :=
  match s with | .absent => 0x00 | .active => 0x01 | .terminal => 0x02

/-- The leaf codec (frozen sibling contract). Total and injective. -/
def encodeState (s : State) : ByteArray := ByteArray.mk #[stateByte s]

/-- Defined on exactly the three codec bytes; `none` on the empty string, any
longer string and every other byte. A naming-era leaf byte string does not
decode. -/
def decodeState (bytes : ByteArray) : Option State :=
  match bytes.toList with
  | [0x00] => some .absent
  | [0x01] => some .active
  | [0x02] => some .terminal
  | _ => none

/-- Historical wire tags, with their original order. Five encode refused actions. -/
inductive Edge where
  | insertAbsent | insertActive | updateActive | updateTerminal
  | deleteAbsent | deleteActive | witnessTerminal
  deriving Repr, BEq, DecidableEq, ToJson, FromJson

/-- The token kinds the deltas speak about: only the active witness is minted in M1. -/
inductive TokenKind where
  | active
  deriving Repr, BEq, DecidableEq, ToJson, FromJson

/-! The derived `BEq` instances above are structural but not registered as
lawful, so `==` on a *variable* of these types does not reduce to `=` in a
proof. These instances supply that, and nothing else: they add no behaviour,
only the fact that the decidable equality the model already derives agrees with
propositional equality. -/

/-- `ByteArray`'s derived `BEq` is not registered as lawful in core either, and
the root is a `ByteArray`, so a proof about `config.root == rootOf trie` needs
this to reduce to an equation. -/
instance : LawfulBEq ByteArray where
  eq_of_beq {a b} h := by
    cases a; cases b
    simp only [BEq.beq, ByteArray.instBEq.beq] at h
    exact congrArg ByteArray.mk (eq_of_beq h)
  rfl {a} := by
    cases a
    simp only [BEq.beq, ByteArray.instBEq.beq]
    exact beq_self_eq_true (α := Array UInt8) _

instance : LawfulBEq State where
  eq_of_beq {a b} h := by cases a <;> cases b <;> first | rfl | exact absurd h (by decide)
  rfl {a} := by cases a <;> rfl

instance : LawfulBEq Leaf where
  eq_of_beq {a b} h := by
    cases a with
    | unknown =>
      cases b with
      | unknown => rfl
      | known y => cases y <;> exact absurd h (by decide)
    | known x =>
      cases b with
      | unknown => cases x <;> exact absurd h (by decide)
      | known y => cases x <;> cases y <;> first | rfl | exact absurd h (by decide)
  rfl {a} := by
    cases a with
    | unknown => rfl
    | known x => cases x <;> rfl

instance : LawfulBEq Edge where
  eq_of_beq {a b} h := by cases a <;> cases b <;> first | rfl | exact absurd h (by decide)
  rfl {a} := by cases a <;> rfl

instance : LawfulBEq TokenKind where
  eq_of_beq {a b} h := by cases a <;> cases b <;> first | rfl | exact absurd h (by decide)
  rfl {a} := by cases a <;> rfl

end Singular
