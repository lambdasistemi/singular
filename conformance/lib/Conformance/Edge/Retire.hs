-- | Retire a registration created in this run, then try two ineligible keys.
module Conformance.Edge.Retire (story) where

import Conformance.Lean.Registration (insertActiveRow, registrationDelivery)
import Conformance.Lean.Retirement (updateTerminalRow, retirementEffect)
import Conformance.Story.Specification (clause, theorem)
import Conformance.Story.Live
    ( Context (Context)
    , RetirementRun (RetirementRun)
    , Story
    , expectActiveToken
    , expectAbsentRetirementRefused
    , expectRetired
    , expectUnknownRetirementRefused
    , registerKey
    , retireRegistration
    )

-- | The holder context and the active token are created by real transactions.
story :: Context reg wal -> Context reg wal -> Story reg wal step obs cmp ins ret bat ref (RetirementRun ins ret ref)
story (Context registry holder) (Context otherRegistry _) = do
    registration <- theorem insertActiveRow $
        clause "The holder receives the token that will be retired" registrationDelivery $
            registerKey registry "alice" holder
    expectActiveToken registration holder 1

    retired <- theorem updateTerminalRow $
        clause "Retirement spends and burns that token and leaves the key Terminal" retirementEffect $
            retireRegistration registry registration
    expectRetired retired 0
    absent <- expectAbsentRetirementRefused registry holder retired "never-active"

    -- A rejected request remains pending. Use a fresh registry so the first
    -- refusal cannot be what makes the second attempt fail.
    otherRegistration <- theorem insertActiveRow $
        clause "The comparison holder receives a token in the fresh registry" registrationDelivery $
            registerKey otherRegistry "control" holder
    expectActiveToken otherRegistration holder 1
    otherRetirement <- theorem updateTerminalRow $
        clause "The comparison retirement burns its own registration token" retirementEffect $
            retireRegistration otherRegistry otherRegistration
    expectRetired otherRetirement 0
    unknown <- expectUnknownRetirementRefused otherRegistry otherRetirement "never-registered"
    pure (RetirementRun registration retired absent otherRetirement unknown)
