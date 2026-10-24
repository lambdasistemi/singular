import NoPin.Held.Value

/-! Kernel-checked equality adapters for #741 hypothetical instances, not
accepted behavioral law. They justify Boolean reflexivity on records containing
opaque computed tag names; no hash value or compiler-trust axiom is introduced. -/

deriving instance ReflBEq, LawfulBEq for Singular.TokenKind
deriving instance ReflBEq, LawfulBEq for Singular.Edge
deriving instance ReflBEq, LawfulBEq for Singular.State
deriving instance ReflBEq, LawfulBEq for Singular.Leaf
deriving instance ReflBEq, LawfulBEq for Singular.Interval
deriving instance ReflBEq, LawfulBEq for Singular.OutRef
deriving instance ReflBEq, LawfulBEq for Singular.TokenId
deriving instance ReflBEq, LawfulBEq for Singular.Config
deriving instance ReflBEq, LawfulBEq for Singular.Custody
deriving instance ReflBEq, LawfulBEq for Singular.DatumForm
deriving instance ReflBEq, LawfulBEq for Singular.Holding
deriving instance ReflBEq, LawfulBEq for Singular.RegistryState
deriving instance ReflBEq, LawfulBEq for Singular.Approval
deriving instance ReflBEq, LawfulBEq for Singular.BookingContents
deriving instance ReflBEq, LawfulBEq for Singular.SingularTag
deriving instance ReflBEq, LawfulBEq for Singular.TerminationRequest
deriving instance ReflBEq, LawfulBEq for Singular.TerminationBooking
deriving instance ReflBEq, LawfulBEq for Singular.RegistrationRequest
deriving instance ReflBEq, LawfulBEq for Singular.RegistrationBooking
deriving instance ReflBEq, LawfulBEq for Singular.World
deriving instance ReflBEq, LawfulBEq for NoPin.Held.Control
deriving instance ReflBEq, LawfulBEq for NoPin.Held.Holding
deriving instance ReflBEq, LawfulBEq for NoPin.Held.Pending
deriving instance ReflBEq, LawfulBEq for NoPin.Held.LockedOutput
deriving instance ReflBEq, LawfulBEq for NoPin.Held.PhysicalOutput

deriving instance ReflBEq, LawfulBEq for NoPin.Held.Guard
deriving instance ReflBEq, LawfulBEq for NoPin.Held.Mutation
deriving instance ReflBEq, LawfulBEq for NoPin.Held.LiveSpend
