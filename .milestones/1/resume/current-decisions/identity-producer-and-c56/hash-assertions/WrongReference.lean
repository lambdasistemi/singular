import PlutusCore.UPLC.CekMachine
import SingularBlaster.Scripts
import SingularBlaster.EndWitness

namespace SingularBlaster.HashVectors

/-! Pinned hash-correctness vectors (new tuple: PlutusCore `ed3126b`).

`blake2b_256` is `opaque` with an executable `Cryptograph.Blake2b` body: finite CEK
runs execute the body (what this file checks); an SMT backend would see it
uninterpreted (recorded assumption for any future `#blaster`-over-hashes claim —
no such claim is made here). Variant is explicit C (PV10 target, A-001); the new
pin's bare default is E and is never used (see the default-guard in
`EndWitness.lean`).

Independent reference: python `hashlib` (see `EVIDENCE.md` for the mechanical
comparison procedure; the expected bytes below are the reference digests).
-/

open PlutusCore.UPLC.CekMachine (cekExecuteProgramWithSemanticVariant State)
open PlutusCore.UPLC.Term (Term Program Version Const BuiltinFun)
open PlutusCore.ByteString (ByteString)
open PlutusCore.Default (BuiltinSemanticsVariant)
open SingularBlaster.Scripts (targetSemVar)
open SingularBlaster.EndWitness (bs)

def v3 : Version := Version.Version 1 1 0

def hashProg (f : BuiltinFun) (input : ByteString) : Program :=
  Program.Program v3 (Term.Apply (Term.Builtin f) (Term.Const (Const.ByteString input)))

/-- Reference `blake2b_256("abc")` (python `hashlib`, mechanically compared). -/
def ABC_HASH : ByteString :=
  bs [0xBD, 0xDD, 0x81, 0x3C, 0x63, 0x42, 0x39, 0x72, 0x31, 0x71, 0xEF, 0x3F,
      0xEE, 0x98, 0x56, 0x79, 0x94, 0x96, 0x4E, 0x3B, 0xBB, 0x1C, 0xB3, 0xE4,
      0x27, 0x62, 0x2C, 0x8C, 0x06, 0xD5, 0x23, 0x19]

def hashBytes : State → Option ByteString
  | .Halt (.VCon (.ByteString h)) => some h
  | _ => none

def abcOk : Bool :=
  match hashBytes (cekExecuteProgramWithSemanticVariant targetSemVar
      (hashProg BuiltinFun.Blake2b_256 "abc") [] 1000) with
  | some h => h == ABC_HASH
  | none => false

/-- info: true -/
#guard_msgs in
#eval abcOk

/-- Malformed argument (integer where bytestring expected) must refuse. -/
def badProg : Program :=
  Program.Program v3
    (Term.Apply (Term.Builtin BuiltinFun.Blake2b_256)
      (Term.Const (Const.Integer 42)))

def refused : Bool :=
  match cekExecuteProgramWithSemanticVariant targetSemVar badProg [] 1000 with
  | .Error => true
  | _ => false

/-- info: true -/
#guard_msgs in
#eval refused

end SingularBlaster.HashVectors
