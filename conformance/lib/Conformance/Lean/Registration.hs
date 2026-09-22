-- | The delivery projection proved by the registration theorem. Expectations
-- are computed by the packaged Lean executable, never reconstructed here.
module Conformance.Lean.Registration (
    InsertActive, registrationDelivery, insertActiveRow,
) where

import Conformance.Story.Binding (mkBoundObligation)
import Conformance.Story.Specification (LeanCheck, Theorem, bindCheck, bindTheorem)
import Conformance.Story.Live (LiveI (CheckRegistrationDelivery))

-- | The registration declaration, distinct from every other theorem marker.
data InsertActive

-- | The check runs through the registry interpreter under this theorem.
registrationDelivery :: LeanCheck (LiveI reg wal ins ret bat ref) InsertActive ins
registrationDelivery = bindCheck insertActiveRow CheckRegistrationDelivery

insertActiveRow :: Theorem InsertActive
insertActiveRow = bindTheorem $ mkBoundObligation
    "Singular.Statements.insert_active_transaction_row"
    "bfb4e3174839b649a883244b97053ea52985cb3eeea1d3eb4475bb273e841737"
    "265c595edd72eab10f3b08a36cb010ad407cf48b"
