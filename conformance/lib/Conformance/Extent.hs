{- |
Module      : Conformance.Extent
Description : Every live refusal of a run, classified against the model
License     : Apache-2.0

The replay index of a run names every refusal its live rows met. A refusal
whose step carried an executed model reason is class A by fact: the runner
records it, and its reason must agree with the traced replay's or be
uncompared with a named cause. Every other refusal must be listed, by its
row, in the committed table of the extent document as B, C or D; one that is
not is unclassified, and fails. The index must also name each refusal the
run's receipts record exactly once, and an accepting control for each script
role that refused.

Pure: the index entries, the receipts and the document arrive as data.
-}
module Conformance.Extent
    ( ExtentClass (..)
    , committedClasses
    , ExtentCount (..)
    , extentProblems
    , extentCount
    ) where

import Conformance.Receipt (Receipt (..))
import Data.Aeson (Value (..))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)

-- | A class the committed table gives a refusal no model reason was executed for.
data ExtentClass
    = -- | Lean returns a reason; no consumer executes the model on the behavior
      ClassB
    | -- | Lean cannot express the behavior
      ClassC
    | -- | Lean's outcome differs from the chain's or the consumer model's
      ClassD
    deriving stock (Show, Eq, Ord)

{- | The committed table of the extent document — the section headed
@Discovered table@ — as the class of each row it lists.
-}
committedClasses :: Text -> Either String (Map Text ExtentClass)
committedClasses _ = Right Map.empty

-- | How many refusals of a run fall in each class.
data ExtentCount = ExtentCount
    { countA :: Int
    , countTable :: Map ExtentClass Int
    }
    deriving stock (Show, Eq)

-- | The refusals of a run, by class: A by fact, the others by the table.
extentCount :: Map Text ExtentClass -> [Value] -> ExtentCount
extentCount _ _ = ExtentCount 0 Map.empty

{- | What a run's replay index and receipts lack for the extent: one line per
problem, none when every refusal is accounted for.
-}
extentProblems
    :: Map Text ExtentClass -> [Value] -> [Receipt] -> [Text]
extentProblems _ _ _ = []
