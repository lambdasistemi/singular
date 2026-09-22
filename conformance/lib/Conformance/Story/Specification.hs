{-# LANGUAGE GADTs #-}
{-# LANGUAGE RoleAnnotations #-}

-- | Reusable theorem and clause structure, independent of registry actions.
module Conformance.Story.Specification
    ( Story
    , Step (..)
    , Theorem
    , bindTheorem
    , theoremBinding
    , TheoremStory
    , Clause (..)
    , clauses
    , LeanCheck
    , bindCheck
    , checkTheorem
    , checkAction
    , action
    , theorem
    , clause
    ) where

import Control.Monad.Operational (Program, singleton)
import Conformance.Story.Binding (Binding)

-- | A bound declaration. Its nominal index identifies the theorem's checks.
type role Theorem nominal
newtype Theorem thm = BoundTheorem Binding

-- | Bind a domain-specific theorem marker to its checked declaration identity.
bindTheorem :: Binding -> Theorem thm
bindTheorem = BoundTheorem

-- | The declaration resolved by execution and named by rendering.
theoremBinding :: Theorem thm -> Binding
theoremBinding (BoundTheorem binding) = binding

-- | A check retains its theorem and supplies an interpreter action for the observation.
type role LeanCheck nominal nominal nominal
data LeanCheck act thm obs = BoundCheck (Theorem thm) (obs -> Story act ())

-- | Domain bindings supply the executable check of an observed result.
bindCheck :: Theorem thm -> (obs -> Story act ()) -> LeanCheck act thm obs
bindCheck = BoundCheck

-- | Resolve the same declaration for the enclosing theorem and its check.
checkTheorem :: LeanCheck act thm obs -> Theorem thm
checkTheorem (BoundCheck binding _) = binding

-- | Run the domain's check through the same interpreter as its actions.
checkAction :: LeanCheck act thm obs -> obs -> Story act ()
checkAction (BoundCheck _ check) = check

-- | A reusable action program with nested theorem-scoped clauses.
type Story act = Program (Step act)

-- | The structure interpreted by both execution and presentation.
data Step act res where
    Action :: act res -> Step act res
    Theorem :: Theorem thm -> TheoremStory thm act res -> Step act res

-- | Clauses belonging to one theorem. The index cannot be changed by coercion.
newtype TheoremStory thm act res = TheoremStory (Program (Clause thm act) res)
    deriving newtype (Functor, Applicative, Monad)

-- | An action's result is checked before it is returned to the surrounding story.
data Clause thm act obs where
    Clause :: String -> LeanCheck act thm obs -> Story act obs -> Clause thm act obs

-- | Expose the clause program to interpreters without permitting reindexing.
clauses :: TheoremStory thm act res -> Program (Clause thm act) res
clauses (TheoremStory program) = program

-- | Lift one domain action into the shared story language.
action :: act res -> Story act res
action = singleton . Action

-- | Execute clauses under their governing theorem.
theorem
    :: Theorem thm
    -> TheoremStory thm act res
    -> Story act res
theorem binding body = singleton (Theorem binding body)

-- | Name an observation and associate its action with a check of the same theorem.
clause
    :: String
    -> LeanCheck act thm obs
    -> Story act obs
    -> TheoremStory thm act obs
clause title check body = TheoremStory (singleton (Clause title check body))
