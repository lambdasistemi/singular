{- |
Module      : Conformance.Run.Control
Description : Split out of Conformance.Run (#263); see that module's header
License     : Apache-2.0
-}
module Conformance.Run.Control (caRows, cgRows, csRows, issue70Rows, issue70AcceptingRows, issue173Rows, issue177Rows, issue258Rows, sequenceRows, canonicalRows, Control (..), readControl, cgKey, cgDeleteKey, cgV1, cgV2, cgV3, cgV4, controlKey, controlVal, forgedValue, cgDeposit) where

import Data.ByteString (ByteString)
import System.Environment (lookupEnv)

import Singular.Registry.TxBuilder.Internal (
    leafAbsent,
    leafActive,
    leafTerminal,
 )

import Conformance.Mirror (failWith)

-- ---------------------------------------------------------
-- Row vocabulary and control modes
-- ---------------------------------------------------------

-- | Row families by explicit membership. Every partition below filters by
-- these lists, never by exclusion: a catch-all partition silently absorbs
-- the next family of rows (CA01-CA05 were once routed into the CS
-- session by a notElem-CG catch-all). A row in no family fails loudly.
caRows, cgRows, csRows, issue70Rows, issue70AcceptingRows, issue173Rows, issue177Rows, issue258Rows, sequenceRows :: [String]
caRows = ["CA01", "CA02", "CA03", "CA04", "CA05"]
cgRows = ["CG02", "CG03", "CG04", "CG05"]
csRows = ["CS01", "CS02", "CS03", "CS04", "CS05", "CS06", "CS07", "CS08"]

-- The issue #70 rows, listed by membership — never by exclusion or
-- position: a partition defined by what it is not silently absorbs
-- whatever the next slice adds.
issue70Rows =
    [ "CG07"
    , "CG09"
    , "CG10"
    , "CG11"
    , "CG12"
    , "CG14"
    , "CG15"
    , "CG19"
    ]

-- The issue #70 rows that close a CL01 receipt when the full session
-- ran: every accepting fold in the session.
issue70AcceptingRows = ["CG11", "CG12", "CG14", "CG19"]

-- The registration chapter: five generic model edge steps, including an
-- occupied-key refusal and a redirected-delivery attempt with its control.
issue173Rows = ["CG21"]

-- The issue #177 row, listed by membership like every other family:
-- CG22 is the updateTerminal retirement — insertActive then
-- updateTerminal at the SAME key in one session — together with its two
-- DISTINCT refusal fixtures, an Unknown key (`key-unknown`) and an
-- Absent key (`not-booked`), each with its own accepting control. It
-- shares no fixture, receipt or assertion with CG21.
issue177Rows = ["CG22"]

-- The issue #258 row: CG23 is the reject and the retract, each refused when
-- its refund or return is tampered with beside its untampered control. It
-- runs apart from CG22 so that each receipt stays under the size bound.
issue258Rows = ["CG23"]
sequenceRows = ["sequence"]

canonicalRows :: [String]
canonicalRows =
    caRows <> cgRows <> csRows <> issue70Rows <> issue173Rows <> issue177Rows <> issue258Rows <> sequenceRows

data Control
    = Normal
    | WrongReason
    | FalseClaim
    | WrongIndex
    | WrongParams
    | FalseDatum
    | MissingWitness
    | -- | CA03 armed: the policy+address-only authenticator must
      -- reject the rival, which it cannot. Proves CA02's rejection
      -- is attributable to the derived name and nothing else.
      NaiveAuthenticator
    | -- | CA04 armed: the unapplied layer's address must pass for
      -- the deployed script, which it cannot. Proves the identity
      -- layers are genuinely distinct and the check can fail.
      UnappliedAddress
    | -- | CS01 armed (#157 D-DEST): a three-element list must validate
      -- against the two-element destination pair, which it cannot —
      -- the fixed tuple is checked at exact arity. Proves the schema
      -- oracle was not loosened into a homogeneous list rule.
      BlueprintWrongArity
    | -- | CS08 armed (#157 X1): the retired SIX-field state encoding
      -- must decode the chain's datum, which it cannot — the datum has
      -- eight fields now. Proves the round-trip row is reading the new
      -- contract and would notice a regression to the old one.
      LegacySixField
    deriving stock (Eq, Show)

readControl :: IO Control
readControl = do
    mode <- lookupEnv "CONFORMANCE_CONTROL"
    case mode of
        Nothing -> pure Normal
        Just "wrong-reason" -> pure WrongReason
        Just "false-claim" -> pure FalseClaim
        Just "wrong-index" -> pure WrongIndex
        Just "wrong-params" -> pure WrongParams
        Just "false-datum" -> pure FalseDatum
        Just "missing-witness" -> pure MissingWitness
        Just "naive-authenticator" -> pure NaiveAuthenticator
        Just "unapplied-address" -> pure UnappliedAddress
        Just "legacy-six-field" -> pure LegacySixField
        Just "blueprint-wrong-arity" -> pure BlueprintWrongArity
        Just other ->
            failWith
                ( "unknown CONFORMANCE_CONTROL value " <> other
                )

-- ---------------------------------------------------------
-- Keys and values
-- ---------------------------------------------------------

{- | The generic rows' keys, and the leaf states they move between.

#157 admits three leaf values and nothing else, so the rows say what they
always said — insert, update, delete, re-insert, occupied-key refusal —
in the only vocabulary the registry has. `cgKey` runs the insert, update
and occupied-key rows; `cgDeleteKey` runs the delete and the re-insert,
because deleting an ACTIVE leaf is the one edge naming never certifies
(N5) and a delete that can fold is a delete of a witnessed absence.
-}
cgKey, cgDeleteKey, cgV1, cgV2, cgV3, cgV4 :: ByteString
cgKey = "cg-row-key"
cgDeleteKey = "cg-delete-key"
cgV1 = leafAbsent
cgV2 = leafActive
cgV3 = leafAbsent
cgV4 = leafAbsent

{- | The control values. A forged claim names a leaf the key does not
hold; there is no byte outside the codec that would reach the comparison
at all, so the forgery is a wrong LEAF, which is what a false claim about
a registry actually looks like.
-}
controlKey, controlVal, forgedValue :: ByteString
controlKey = "cg-control-key"
controlVal = leafAbsent
forgedValue = leafTerminal

{- | The deposit a booking rides with, over and above the tip. The fold
returns it to the destination the request named, or locks it in the
custody an absence creates — it is never the folder's (T6, want-ledger R4).
-}
cgDeposit :: Integer
cgDeposit = 3_000_000
