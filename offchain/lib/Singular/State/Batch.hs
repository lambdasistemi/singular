{- |
Module      : Singular.State.Batch
Description : Order public requests and find their greatest buildable prefix
License     : Apache-2.0

Selection reads only the supplied values. Every larger prefix is tried before
the selected one, so a later success cannot be missed by assuming a cost law.
Only a typed capacity refusal permits a shorter attempt.
-}
module Singular.State.Batch
    ( BatchSelection (..)
    , orderByTake
    , largestFittingPrefix
    ) where

import Data.List (sortOn)
import Data.Ord (Down (..))
import Data.Word (Word32)

import Singular.State.Refusal (CapacityLimit, Refusal (..))

-- | The selected prefix, the rest counted, and the actual builder result.
data BatchSelection a b = BatchSelection
    { selectedRequests :: [a]
    -- ^ Every request included in the successful probe, in its build order.
    , requestsLeft :: Int
    -- ^ All supplied requests beyond the selected prefix, including the cap.
    , selectedBuild :: b
    -- ^ The result returned by that successful probe.
    , nextCapacity :: Maybe CapacityLimit
    -- ^ The actual refusal of the next prefix, absent at the whole set or cap.
    }
    deriving stock (Eq, Show)

-- | Greatest take first; equal takes use the output reference ascending.
orderByTake
    :: (Ord bid, Ord reference)
    => (a -> bid) -> (a -> reference) -> [a] -> [a]
orderByTake takeOf referenceOf = sortOn (\request -> (Down (takeOf request), referenceOf request))

{- | Try prefixes in descending size, stopping on the first success or any
noncapacity refusal. The next-prefix boundary is the immediately preceding
failed probe; all still larger prefixes have also been refused for capacity.
-}
largestFittingPrefix
    :: (Monad m)
    => ([a] -> m (Either Refusal b))
    -> Maybe Word32
    -> [a]
    -> m (Either Refusal (BatchSelection a b))
largestFittingPrefix build cap requests = go bounded Nothing
  where
    count = length requests
    bounded =
        fromInteger
            (min (toInteger count) (maybe (toInteger count) toInteger cap))
    go 0 boundary = pure (Left (maybe NothingToFold CapacityExceeded boundary))
    go size boundary = do
        let prefix = take size requests
        result <- build prefix
        case result of
            Left (CapacityExceeded limit) -> go (size - 1) (Just limit)
            Left refusal -> pure (Left refusal)
            Right built -> pure (Right (BatchSelection prefix (count - size) built boundary))
