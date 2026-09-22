-- | Run-scoped identities. Allocation belongs to actions and context setup;
-- observing a result only looks up identities and cannot allocate them.
module Conformance.Story.Identity (
    Identities, empty, identify, bind, observe, bindings,
) where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map

newtype Identities identity = Identities (Map identity Integer)
    deriving stock (Show, Eq)

empty :: Identities identity
empty = Identities Map.empty

identify :: Ord identity => identity -> Identities identity -> (Integer, Identities identity)
identify identity original@(Identities known) = case Map.lookup identity known of
    Just identifier -> (identifier, original)
    Nothing ->
        let identifier = fromIntegral (Map.size known) + 1
        in (identifier, Identities (Map.insert identity identifier known))

{- | Bind a concrete identity to the abstract identity a scenario names.

Allocation during context and action construction, like 'identify', but the
scenario chooses the identifier instead of the order of encounter. Re-binding
the same pair is accepted; binding a second concrete identity to an identifier
already taken, or re-binding one already bound to a different identifier, is
refused — either would make an observation mean two things.
-}
bind :: Ord identity => identity -> Integer -> Identities identity -> Either String (Identities identity)
bind identity identifier (Identities known) =
    case (Map.lookup identity known, [i | (i, n) <- Map.toList known, n == identifier, i /= identity]) of
        (Just existing, _)
            | existing /= identifier ->
                Left "the scenario binds an identity that is already bound to another identifier"
        (_, _ : _) -> Left "the scenario binds two concrete identities to one identifier"
        _ -> Right (Identities (Map.insert identity identifier known))

observe :: Ord identity => identity -> Identities identity -> Either String Integer
observe identity (Identities known) =
    maybe (Left "observed an identity not established by the context or an action") Right (Map.lookup identity known)

bindings :: Identities identity -> [(identity, Integer)]
bindings (Identities known) = Map.toAscList known
