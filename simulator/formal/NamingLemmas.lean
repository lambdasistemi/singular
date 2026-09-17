import Singular.Naming

/-! Proof-side helpers for the naming statements. Nothing here is part of the
public statement inventory. -/

namespace Singular

@[simp] theorem exceptBindOkAny { α β : Type } (x : α) (f : α → Except String β) :
    (Except.bind (Except.ok x : Except String α) f : Except String β) = f x := rfl

@[simp] theorem exceptBindErrAny { α β : Type } (e : String) (f : α → Except String β) :
    (Except.bind (Except.error e : Except String α) f : Except String β) = Except.error e := rfl

end Singular
