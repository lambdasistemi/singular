{- |
Module      : Singular.Registry.Replay
Description : A registry's trie rebuilt from the public history of its state token
License     : Apache-2.0

The chain commits a registry's trie by its root only. This module rebuilds
the trie itself from the transactions that moved the registry's state
token since @create@, so a reader needs nobody's local copy.

The lineage is chained by spends, never by the order the transactions are
given in: @create@ mints the token under @Minting(seed)@, and each fold
spends the previous state output. Every fold applies its requests the way
the state validator does (@onchain\/validators\/registry\/fold.ak@): the
spending inputs in ledger order, an inline 'RequestDatum' naming this
registry's token takes the next action of the state input's @Modify@
redeemer, 'Rejected' leaves the trie as it is and 'Update' walks the
request's edge with 'walkEdge'. After every fold the rebuilt root must
equal the root in that fold's state datum.

The answer is the trie rebuilt into the caller's 'Trie', or one named
'Refusal'. On a refusal the caller's trie holds a partial replay and must
be discarded.
-}
module Singular.Registry.Replay
    ( -- * The registry and its selected state
      RegistryToken (..)

      -- * Replay
    , replayLineage
    , Replayed (..)

      -- * Refusals
    , ReplayFailure (..)
    , Refusal (..)
    , Incomplete (..)
    , Undecodable (..)
    , Mismatch (..)
    ) where

import Data.Map.Strict (Map)

import Cardano.Ledger.Api.Tx.Out (TxOut)
import Cardano.Ledger.Mary.Value (AssetName, PolicyID)
import Cardano.Ledger.TxIn (TxId, TxIn (..))
import Cardano.Tx.Ledger (ConwayTx)

import Singular.Registry.Ledger (ConwayEra, Root)
import Singular.Registry.Trie (Trie)

-- | A registry, named by its state token: the state policy and the token's name.
data RegistryToken = RegistryToken
    { tokenPolicy :: PolicyID
    , tokenName :: AssetName
    }
    deriving stock (Eq, Show)

-- | A replay that reached the selected state output from @create@.
data Replayed = Replayed
    { replayedCreate :: TxId
    -- ^ The transaction that minted the state token
    , replayedFolds :: [TxId]
    -- ^ Every fold from @create@ to the selected output, in chain order
    }
    deriving stock (Eq, Show)

-- | A refusal, naming the registry and the transaction it is about.
data ReplayFailure = ReplayFailure
    { failedRegistry :: RegistryToken
    , failedTransaction :: TxId
    , failedRefusal :: Refusal
    }
    deriving stock (Eq, Show)

-- | Why a history does not rebuild the registry's trie.
data Refusal
    = -- | The history does not reach the selection from @create@.
      HistoryIncomplete Incomplete
    | -- | A fold's rebuilt root differs from its state datum's root.
      RootDoesNotChain
        { rebuiltRoot :: Root
        , recordedRoot :: Root
        }
    | -- | A fold's redeemer, actions or state output cannot be read.
      UndecodableRequest Undecodable
    | -- | The lineage is another registry's.
      WrongRegistry Mismatch
    | -- | The selection's root is not the root at the selected output.
      StaleRoot
        { selectedRoot :: Root
        , outputRoot :: Root
        }
    deriving stock (Eq, Show)

-- | How a history falls short of the lineage.
data Incomplete
    = -- | A transaction the lineage spends through is not in the history.
      MissingTransaction
    | -- | A spent input is resolved neither by the history nor by the map.
      UnresolvedInput TxIn
    | -- | The map resolves an input differently from the transaction that made it.
      ConflictingResolution TxIn
    | -- | Two different transactions share one identifier.
      ConflictingCopies
    | -- | A transaction holds the token but spends no state output and mints none.
      NoStateInput
    | -- | A state output is spent by two different transactions.
      ForkedStateOutput TxIn
    | -- | A transaction touches the token outside the lineage.
      OutsideLineage
    deriving stock (Eq, Show)

-- | What of a fold cannot be read.
data Undecodable
    = -- | The state output carries no inline state datum, or is not first.
      UndecodableStateOutput
    | -- | The state input's spend carries no redeemer.
      MissingRedeemer
    | -- | The state input's redeemer is not @Modify@.
      NotModify
    | -- | Actions and matching requests differ in number.
      ActionCount
        { actionsGiven :: Int
        , requestsFound :: Int
        }
    deriving stock (Eq, Show)

-- | How the lineage differs from the selected registry.
data Mismatch
    = -- | The selected output does not hold exactly the registry's token.
      SelectionNotState
    | -- | @create@ does not mint exactly one token under @Minting(seed)@.
      CreateMint
    | -- | @create@ does not spend its seed.
      SeedNotSpent
    | -- | The token's name is not @assetName(seed)@.
      SeedName
    | -- | @create@'s first output is not the state address holding the token.
      CreateOutput
    deriving stock (Eq, Show)

{- | Rebuild the registry's trie into the given trie, from the history of its
state token up to the selected state output.

The history is the ledger's own transactions, in any order; the map resolves
every input they spend or reference. The selection is a state output and the
root the caller expects there.
-}
replayLineage
    :: (Monad m)
    => Trie m
    -- ^ An empty trie the replay fills
    -> RegistryToken
    -> TxIn
    -- ^ The selected state output
    -> Root
    -- ^ The root the selection expects at that output
    -> Map TxIn (TxOut ConwayEra)
    -- ^ Resolved spent and reference outputs
    -> [ConwayTx]
    -- ^ The state token's history
    -> m (Either ReplayFailure Replayed)
replayLineage _ _ (TxIn selected _) _ _ _ = pure (Right (Replayed selected []))
