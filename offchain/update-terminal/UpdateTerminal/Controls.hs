{- |
Module      : UpdateTerminal.Controls
Description : The two refused retirements and the control each one needs
License     : Apache-2.0

Two deliberate refusals: retirement of an already terminal key in the story
registry, and retirement of an unknown key in its own registry. Each has an
active-key accepting control in the same registry. Under the tagged law a
termination is booked out of the custody that holds the key's witness, so a
key that is terminal or was never inserted has no custody to book against:
the refusal is the booking builder's, before any transaction is built, and
the observation says so. The request policy's own refusal of a booking that
spends no custody is established over its compiled bytes in the builder's
rows, and its refusals of forged bookings by the negative host. Absent leaves
are unreachable from M1 genesis.
-}
module UpdateTerminal.Controls
    ( unknownKey
    , controlKey
    , terminalRefusal
    , UnknownLeg (..)
    , unknownRefusal
    , refusalTrace
    ) where

import Control.Exception (displayException)
import Data.Aeson (Value (..))
import Data.ByteString (ByteString)
import Data.List (isInfixOf)
import Data.Text qualified as T

import Singular.Registry.Wait (tryOutcome)
import UpdateTerminal.Narration (die, hex, say)
import UpdateTerminal.Registry
    ( Registry
    , bookInsert
    , bookRetire
    , foldAndMirror
    , insertOp
    , retireOp
    , txIdOf
    )
import UpdateTerminal.Steps (storyKey)

{- | The Unknown leg's own accepting control, booked and retired in the
second registry before the refusal it controls.
-}
controlKey :: ByteString
controlKey = "update-terminal-demo-control"

-- | A key nothing ever inserted: the trie does not bind it at all.
unknownKey :: ByteString
unknownKey = "update-terminal-demo-unknown"

{- | The story key has already been permanently retired: its witness is gone,
so no wallet output holds it and the termination booking has no custody to
spend. The refusal is the booking builder's, before any transaction exists;
the request policy's own refusal of a booking that spends no custody is
established over its compiled bytes, not here.
-}
terminalRefusal :: Registry -> IO String
terminalRefusal story = do
    outcome <- tryOutcome (bookRetire story storyKey)
    detail <- case outcome of
        Right _ -> die "a termination of an already terminal key was BOOKED"
        Left e -> pure (displayException e)
    say "an already terminal key: no booking can be built"
    pure detail

-- | The Unknown leg: its accepting control's txid and the refusal text.
data UnknownLeg = UnknownLeg
    { unknownControlTxid :: T.Text
    , unknownDetail :: String
    }

-- | Retire an active control key, then require an unknown key refused.
unknownRefusal :: Registry -> IO UnknownLeg
unknownRefusal reg = do
    _ <- bookInsert reg controlKey
    _ <- foldAndMirror reg controlKey insertOp
    controlOutcome <-
        tryOutcome
            ( do
                _ <- bookRetire reg controlKey
                foldAndMirror reg controlKey retireOp
            )
    controlTxid <- case controlOutcome of
        Right tx -> pure (hex (txIdOf tx))
        Left e ->
            die
                ( "control: a key that IS active was refused retirement, so \
                  \the refusal below would prove nothing about the leaf: "
                    <> displayException e
                )
    unknownOutcome <- tryOutcome (bookRetire reg unknownKey)
    detail <- case unknownOutcome of
        Right _ ->
            die
                "a termination of a key the trie does not bind was BOOKED"
        Left e -> pure (displayException e)
    say "a key the trie does not bind: no booking can be built"
    pure (UnknownLeg controlTxid detail)

-- | The named refusal when the ledger text carries it, @null@ otherwise.
refusalTrace :: String -> String -> Value
refusalTrace name detail
    | name `isInfixOf` detail = String (T.pack name)
    | otherwise = Null
