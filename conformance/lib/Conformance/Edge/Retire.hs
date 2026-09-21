-- | Retire a registration created in this run, then try two ineligible keys.
module Conformance.Edge.Retire (story, storyWithRemainingTokens, retirement, conjuncts) where

import Conformance.Story.Live
import Conformance.Story.Binding (Binding, mkBoundObligation)
import Conformance.Edge.Register qualified as Register

-- | The holder context and the active token are created by real transactions.
story :: Context r w -> Context r w -> Story r w a t b f (RetirementRun a t f)
story = storyWithRemainingTokens 0

-- | A wrong remaining quantity makes the live observation fail after retirement.
storyWithRemainingTokens :: Integer -> Context r w -> Context r w -> Story r w a t b f (RetirementRun a t f)
storyWithRemainingTokens expected (Context registry holder) (Context otherRegistry _) = do
    linkedTo Register.insertActiveRow Register.conjuncts
    registration <- registerKey registry "alice" holder
    expectActiveToken registration holder 1

    linkedTo retirement conjuncts
    retired <- retireRegistration registry registration
    expectRetired retired expected
    absent <- expectAbsentRetirementRefused registry holder retired "never-active"

    -- A rejected request remains pending. Use a fresh registry so the first
    -- refusal cannot be what makes the second attempt fail.
    otherRegistration <- registerKey otherRegistry "control" holder
    expectActiveToken otherRegistration holder 1
    otherRetirement <- retireRegistration otherRegistry otherRegistration
    expectRetired otherRetirement 0
    unknown <- expectUnknownRetirementRefused otherRegistry otherRetirement "never-registered"
    pure (RetirementRun registration retired absent otherRetirement unknown)

-- | The accepted transaction-level retirement rule.
retirement :: Binding
retirement = mkBoundObligation
    "Singular.Statements.update_terminal_transaction_row"
    "3448ca20f33bba9c3b5092136124f4cb0bf196132f485cae8b1a44343523963b"
    "871c5df529d30357e4da7f6f9f141dc02c103bf6"

-- | Only the claims the live observations check; other theorem clauses remain gaps.
conjuncts :: [String]
conjuncts =
    [ "kindCount s .active r.key = 1"
    , "kindCount t.state .active r.key = 0"
    , "mint := [((.active, r.key), -1)]"
    , "trieGet t.state.trie r.key = .known .terminal"
    , "txOf s' r' lovelace = .error \"key-unknown\""
    , "txOf s' r' lovelace = .error \"not-booked\""
    ]
