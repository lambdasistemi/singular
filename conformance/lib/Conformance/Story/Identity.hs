-- | Run-scoped identities. Allocation belongs to actions and context setup;
-- observing a result only looks up identities and cannot allocate them.
module Conformance.Story.Identity (
    Identities, empty, identify, observe, bindings,
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

observe :: Ord identity => identity -> Identities identity -> Either String Integer
observe identity (Identities known) =
    maybe (Left "observed an identity not established by the context or an action") Right (Map.lookup identity known)

bindings :: Identities identity -> [(identity, Integer)]
bindings (Identities known) = Map.toAscList known
