{- |
Module      : Conformance.Edge.Programs
Description : Every registry row as a program over the registry's operations
License     : Apache-2.0

The registry rows of the inventory, each either a program over the story
language's instructions — an edge composition, or a tamper of an edge's
transaction — or named outside the model's vocabulary with its reason.
-}
module Conformance.Edge.Programs
    ( Program (..)
    , Registry (..)
    , Wallet (..)
    , WalletRole (..)
    , Expected (..)
    , Standing (..)
    , Chapter (..)
    , Kind (..)
    , Classification (..)
    , programs
    , programFor
    , outsideVocabulary
    , classify
    , classifyGroup
    , kindOf
    , recordsOf
    , displayStory
    , displayCohort
    ) where

import Conformance.Story.Live (EdgeRequest, Story)
import Data.Text (Text)

-- | A registry a program acts on, booted fresh for its row.
data Registry = Registry
    { registryName :: String
    -- ^ the name the run boots it under
    , registryReading :: String
    -- ^ the name the book reads
    , registryProcessingMs :: Integer
    , registryRetractionMs :: Integer
    }
    deriving stock (Eq, Show)

-- | Which wallet of the run a program's wallet is.
data WalletRole
    = -- | the wallet the run signs and funds every fold with
      RunnerWallet
    | -- | a second wallet the run funds once
      SecondWallet
    | -- | a wallet that books requests and receives no fold's change
      OwnerWallet
    deriving stock (Eq, Show)

-- | A wallet a program names, beside the name the book reads.
data Wallet = Wallet
    { walletRole :: WalletRole
    , walletReading :: String
    }
    deriving stock (Eq, Show)

-- | What one compared record of a program must show.
data Expected
    = -- | the chain and the model reach the same outcome, for the same reason
      Agrees
    | {- | a recorded disagreement, never a pass: the chain's and the model's
      outcomes, the reason the traced replay admits for the chain, and the
      issue that tracks it
      -}
      Diverges
        { divergenceChain :: Text
        , divergenceModel :: Text
        , divergenceTrace :: Text
        , divergenceIssue :: Text
        }
    deriving stock (Eq, Show)

-- | How a program row stands against the consuming project's requirement.
data Standing
    = -- | the row's outcome is what the requirement asks
      Agreement
    | -- | the consuming project's theorem and the model disagree; held
      Held
        { heldFor :: String
        , heldLean :: String
        , heldConsumer :: String
        }
    | -- | the requirement is kept unmet by a ruling
      Unmet
        { unmetRuling :: String
        , unmetRegistry :: String
        , unmetConsumer :: String
        }
    deriving stock (Eq, Show)

-- | A program the book renders as a chapter of its own.
data Chapter = Chapter
    { chapterTitle :: String
    , chapterIntroduction :: String
    , chapterSummary :: String
    -- ^ how the run's results open, before the counts
    }
    deriving stock (Eq, Show)

-- | One row's program.
data Program = Program
    { programRow :: String
    , programRegistries :: [Registry]
    , programWallets :: [Wallet]
    , programCohort
        :: forall reg wal
         . [reg]
        -> [wal]
        -> Either String [(reg, EdgeRequest wal)]
    {- ^ requests booked before the first instruction, each in its registry;
    a story that needs no request pending before it starts books none
    -}
    , programStory
        :: forall reg wal step obs cmp
         . [reg]
        -> [wal]
        -> Either String (Story reg wal step obs cmp ())
    , programExpected :: [Expected]
    -- ^ one per compared record, in order
    , programStanding :: Standing
    , programControls :: [String]
    -- ^ the story controls the row admits
    , programChapter :: Maybe Chapter
    }

-- | Whether a program composes edges or tampers with an edge's transaction.
data Kind = EdgeComposition | Tamper
    deriving stock (Eq, Show)

-- | How a registry row is run.
data Classification
    = -- | a program of this kind
      Composed Kind
    | -- | outside the model's vocabulary, for this reason
      Outside Text
    deriving stock (Eq, Show)

-- | Every program, the book's chapters first, in book order.
programs :: [Program]
programs = []

-- | The program of a row, if it has one.
programFor :: String -> Maybe Program
programFor row = case [p | p <- programs, programRow p == row] of
    [p] -> Just p
    _ -> Nothing

-- | The registry rows the model cannot express, each with its reason.
outsideVocabulary :: [(Text, Text)]
outsideVocabulary = []

-- | A program's kind, read off its instructions.
kindOf :: Program -> Either String Kind
kindOf _ = Left "no kind"

-- | How many records a program compares: one per compared request, one per batch.
recordsOf :: Program -> Either String Int
recordsOf _ = Left "no records"

-- | How one registry row is run.
classify :: Text -> Either String Classification
classify row = Left (show row <> " is not classified")

{- | Every row of the registry group classified exactly once. An empty group,
or a program or reason for a row the group does not hold, is refused.
-}
classifyGroup :: [Text] -> Either String [(Text, Classification)]
classifyGroup = traverse (\row -> (,) row <$> classify row)

-- | A program's story over the display names the book reads.
displayStory
    :: Program -> Either String (Story String String String String String ())
displayStory p =
    programStory
        p
        (map registryReading (programRegistries p))
        (map walletReading (programWallets p))

-- | A program's cohort over the display names the book reads.
displayCohort
    :: Program -> Either String [(String, EdgeRequest String)]
displayCohort p =
    programCohort
        p
        (map registryReading (programRegistries p))
        (map walletReading (programWallets p))
