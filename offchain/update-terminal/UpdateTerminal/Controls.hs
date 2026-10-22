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
the observation says so.

What a leg may publish is only the specific absence of custody: the probe read
the registry's state and the wallet's outputs and none of the outputs carries
the key's token ('CustodyAbsence'). A provider that cannot answer, a state
that is not there, several outputs claiming the key, or a booking the builder
refuses are not that absence: the probe fails with the cause and so does the
run. The request policy's own refusal of a booking that
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

import Singular.Registry.TxBuilder.WalletTermination
    ( CustodyAbsence (..)
    , expectNoCustody
    )
import Singular.Registry.Wait (tryOutcome)
import UpdateTerminal.Narration (die, hex, say)
import UpdateTerminal.Registry
    ( Registry
    , bookInsert
    , bookRetire
    , foldAndMirror
    , insertOp
    , probeRetire
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
terminalRefusal :: Registry -> IO CustodyAbsence
terminalRefusal story = do
    probed <- expectNoCustody (probeRetire story storyKey)
    absence <- case probed of
        Left _ -> die "a termination of an already terminal key was BOOKED"
        Right found -> pure found
    say "an already terminal key: no booking can be built"
    pure absence

-- | The Unknown leg: its accepting control's txid and the refusal text.
data UnknownLeg = UnknownLeg
    { unknownControlTxid :: T.Text
    , unknownDetail :: CustodyAbsence
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
    probed <- expectNoCustody (probeRetire reg unknownKey)
    absence <- case probed of
        Left _ ->
            die
                "a termination of a key the trie does not bind was BOOKED"
        Right found -> pure found
    say "a key the trie does not bind: no booking can be built"
    pure (UnknownLeg controlTxid absence)

-- | The named refusal when the ledger text carries it, @null@ otherwise.
refusalTrace :: String -> String -> Value
refusalTrace name detail
    | name `isInfixOf` detail = String (T.pack name)
    | otherwise = Null
