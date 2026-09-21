-- | Register a real key, observe its token, then exercise the refusal boundaries.
module Conformance.Edge.Register (story, insertActiveRow, conjuncts) where

import Conformance.Story.Live
import Conformance.Lean.Registration (insertActiveRow, registrationDelivery)
import Conformance.Fold.KeyedMint qualified as Batch

-- | The caller supplies an empty open registry and a funded recipient.
story :: Context r w -> Story r w a t b f (RegistrationRun r a b f)
story (Context registry recipient) = do
    registration <- theorem insertActiveRow $
        clause "Registration delivers one active token to the requested recipient"
            registrationDelivery $
                registerKey registry "alice" recipient
    expectActiveToken registration recipient 1

    fresh <- registerFreshKey registry "bob" recipient
    expectActiveToken fresh recipient 1
    batch <- Batch.story registry recipient
    duplicate <- expectDuplicateRegistrationRefused registry registration fresh
    pure (RegistrationRun registry registration fresh batch duplicate)

-- | Verbatim Lean anchors used by this subject.
conjuncts :: [String]
conjuncts = [ "address := some r.output"
          , "assets := [((.active, r.key), 1)]"
          , "kindCount t.state .active r.key = 1"
          , "mint := [((.active, r.key), 1)]"
          , "openPolicyParameters = []"
          , "refunds := []"
          , "signers := []"
          , "lovelaceCoversTip s.config lovelace = true"
          , "destinationDatumBinds r = true"
          , "onlyRootChanged s.config t.state.config = true"
          , "txOf t.state r₂ lovelace = .error \"key-exists\""
    ]
