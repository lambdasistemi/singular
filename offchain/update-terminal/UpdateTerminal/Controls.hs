{- |
Module      : UpdateTerminal.Controls
Description : The two refused retirements and the control each one needs
License     : Apache-2.0

Two deliberate refusals, each in a registry where it is the only
refusal, each with its own accepting control through the same builder:

* 'absentRefusal' — in the STORY registry, after the story's own
  retirement (which is its control): a key bound ABSENT by a real
  @insertAbsent@ fold, never booked active, is refused @updateTerminal@.
  The refusal poisons that registry, so nothing follows it there.
* 'unknownRefusal' — in its own registry: first a key that IS active is
  booked and retired (the accepting control; if it is refused the run
  fails, because the refusal would prove nothing about the leaf), then a
  key the trie does not bind at all is refused.

One control cannot serve both: the two refusals cannot share a registry,
and a control from the other registry would not be the same builder
against the same state.

An accepted refusal leg fails the run and is reported, not relabelled.
'refusalTrace' reads a refusal name out of the ledger's error text when
it is there and answers @null@ otherwise; the names are asserted at the
Aiken layer against @state.terminalRefusal@.
-}
module UpdateTerminal.Controls
    ( unknownKey
    , absentKey
    , controlKey
    , absentRefusal
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
    , absentOp
    , book
    , foldAndMirror
    , foldInadmissible
    , insertOp
    , retireOp
    , txIdOf
    )

{- | The Unknown leg's own accepting control, booked and retired in the
second registry before the refusal it controls.
-}
controlKey :: ByteString
controlKey = "update-terminal-demo-control"

-- | A key nothing ever inserted: the trie does not bind it at all.
unknownKey :: ByteString
unknownKey = "update-terminal-demo-unknown"

-- | A key witnessed ABSENT by a real fold, and never booked.
absentKey :: ByteString
absentKey = "update-terminal-demo-absent"

-- | Bind the absent key, then require its retirement to be refused.
absentRefusal :: Registry -> IO String
absentRefusal story = do
    book story absentKey absentOp
    _ <- foldAndMirror story absentKey absentOp
    book story absentKey retireOp
    absentOutcome <- tryOutcome (foldInadmissible story)
    absentDetail <- case absentOutcome of
        Right _ ->
            die
                "the fold ACCEPTED updateTerminal on a key witnessed Absent — \
                \reported, not relabelled"
        Left e -> pure (displayException e)
    say "a key witnessed Absent: REFUSED"
    pure absentDetail

-- | The Unknown leg: its accepting control's txid and the refusal text.
data UnknownLeg = UnknownLeg
    { unknownControlTxid :: T.Text
    , unknownDetail :: String
    }

-- | Retire an active control key, then require an unknown key refused.
unknownRefusal :: Registry -> IO UnknownLeg
unknownRefusal reg = do
    book reg controlKey insertOp
    _ <- foldAndMirror reg controlKey insertOp
    book reg controlKey retireOp
    controlOutcome <-
        tryOutcome (foldAndMirror reg controlKey retireOp)
    controlTxid <- case controlOutcome of
        Right tx -> pure (hex (txIdOf tx))
        Left e ->
            die
                ( "control: a key that IS active was refused retirement, so \
                  \the refusal below would prove nothing about the leaf: "
                    <> displayException e
                )
    book reg unknownKey retireOp
    unknownOutcome <- tryOutcome (foldInadmissible reg)
    detail <- case unknownOutcome of
        Right _ ->
            die
                "the fold ACCEPTED updateTerminal on a key the trie does not \
                \bind — reported, not relabelled"
        Left e -> pure (displayException e)
    say "a key the trie does not bind: REFUSED"
    pure (UnknownLeg controlTxid detail)

-- | The named refusal when the ledger text carries it, @null@ otherwise.
refusalTrace :: String -> String -> Value
refusalTrace name detail
    | name `isInfixOf` detail = String (T.pack name)
    | otherwise = Null
