{- |
Module      : InsertActive.Controls
Description : The duplicate refusal and the accepting control it needs
License     : Apache-2.0

Two deliberate legs, run after the story's own fold, in this order:

1. 'freshKeyControl' books and folds a FRESH key through the same
   builder. It is taken BEFORE the duplicate because a refused request is
   never consumed and would otherwise poison the fold that follows it.
   Without it, a refusal is consistent with "this command cannot fold at
   all"; if it is refused the run fails rather than reporting a refusal
   that proves nothing about occupancy.
2. 'duplicateRefusal' books the story's key a second time and requires
   the fold to be REFUSED. An accepted duplicate fails the run and is
   reported, not relabelled.

'refusalTrace' reads the cage's refusal name out of the ledger's error
text when it is there and answers @null@ otherwise: the ledger's
evaluation failure usually carries an empty Plutus log, and the name is
asserted at the Aiken layer rather than guessed here.
-}
module InsertActive.Controls
    ( controlKey
    , freshKeyControl
    , duplicateRefusal
    , refusalTrace
    ) where

import Control.Exception (displayException)
import Data.Aeson (Value (..))
import Data.ByteString (ByteString)
import Data.List (isInfixOf)
import Data.Text qualified as T

import InsertActive.Narration (die, hex, say)
import InsertActive.Steps (Story, book, foldOnce, storyKey, txIdOf)
import Singular.Registry.Wait (tryOutcome)

-- | A second, never-booked key: the accepting control.
controlKey :: ByteString
controlKey = "insert-active-demo-control"

-- | Fold a fresh key through the same builder; its transaction id, in hex.
freshKeyControl :: Story -> IO T.Text
freshKeyControl story = do
    book story controlKey
    controlOutcome <- tryOutcome (foldOnce story controlKey)
    case controlOutcome of
        Right tx -> pure (hex (txIdOf tx))
        Left e ->
            die
                ( "control: a FRESH key was refused, so the duplicate \
                  \refusal below would prove nothing about occupancy: "
                    <> displayException e
                )

-- | Book the story's key again and require the fold to be refused.
duplicateRefusal :: Story -> IO String
duplicateRefusal story = do
    book story storyKey
    duplicate <- tryOutcome (foldOnce story storyKey)
    dupRefusal <- case duplicate of
        Right _ ->
            die
                "the fold ACCEPTED a second insertActive on a key the trie \
                \already binds — reported, not relabelled"
        Left e -> pure (displayException e)
    say "the same key again: REFUSED"
    pure dupRefusal

-- | @key-exists@ when the refusal text names it, @null@ otherwise.
refusalTrace :: String -> Value
refusalTrace dupRefusal
    | "key-exists" `isInfixOf` dupRefusal = String "key-exists"
    | otherwise = Null
