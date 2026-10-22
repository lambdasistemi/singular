{- |
Module      : Main
Description : #177 I177-COMMAND — `update-terminal` from the released archive
License     : Apache-2.0

The second packaged verb the release archive documents. A reviewer with
the extracted archive and no checkout runs it against a devnet and
watches a name end: the open registry boots, a key is registered at a
wallet, and that same key is then terminated — its witness burned out of the
request that took it from the wallet that held it, its leaf committed as
`Terminal`.

> REGISTRY_BLUEPRINT=../onchain/plutus.json nix run .#update-terminal -- --observed out.json

What it observes, in order:

1. the registry boots under the PARAMETERLESS open application and the
   three witness policies, all four pins from @REGISTRY_BLUEPRINT@
   alone — no naming blueprint anywhere;
2. one registration is booked through the shared registration booking and
   folded, and the wallet the request named holds exactly one
   @(activePolicy, key)@ token. This is the prerequisite, EXECUTED rather
   than fabricated: the token the termination destroys is the token this
   fold created, and a fixture dropped into the final state would evidence
   nothing about the transition;
3. one termination is booked at the SAME key through the shared termination
   booking, which spends the wallet's output holding the witness (the
   holder's signature is its spending condition) and takes the whole value
   into the request, and then folded. The wallet's holding goes to zero,
   the fold's mint under the active policy is exactly @(key, -1)@, the
   input that carried the witness is recorded by its outref, and the
   committed leaf reads @Terminal@;
4. a termination of a key the trie does not bind at all can be booked by no
   one — no output holds its witness — and a key that IS active terminates
   in the same run as its accepting control;
5. a termination of a key that is already Terminal is likewise refused at
   the booking, with the story's own termination as its accepting
   control. These two refusals are the booking builder's, before any
   transaction exists, and the observation names that layer; the request
   policy's own refusals are established over its compiled bytes elsewhere.

@--observed PATH@ writes the observation as JSON so a CI step asserts the
OBSERVATION rather than the exit code. Every value in it is read back
from the chain, the transaction, the committed trie or the blueprint;
nothing is a literal written here to make an assertion pass. Where the
cage's refusal trace cannot be recovered from the ledger's error text,
the field is @null@ rather than a guess — the NAMES are asserted at the
Aiken layer, against `state.terminalRefusal`, the construction site the
validator reads.

The whole journey is ONE node session. The prerequisite insert and the
retirement share a devnet because they share a registry; nothing here
asks two independently persistent processes to meet on an ephemeral
chain.

The story is divided among command-local owners, each named below;
this module only turns any failure into the command's exit status:

* "UpdateTerminal.Options" — @--observed@ and the blueprint read;
* "UpdateTerminal.Registry" — the node session, each registry's boot,
  bookings, folds and roots;
* "UpdateTerminal.Steps" — the story's insert and retirement, read back;
* "UpdateTerminal.Controls" — the Absent and Unknown refusals with their
  accepting controls;
* "UpdateTerminal.Observation" — the JSON document;
* "UpdateTerminal.Scenario" — the order they run in.

This verb books through the registration and termination bookings every
producer shares and folds through the library's tagged fold; it carries no
request of the earlier edge-numbered wire.
-}
module Main (main) where

import Control.Exception (SomeException, displayException, try)
import System.Environment (getArgs)
import System.Exit (ExitCode (..), exitWith)
import System.IO (hPutStrLn, stderr)

import UpdateTerminal.Options (observedPathFrom)
import UpdateTerminal.Scenario (updateTerminal)

{- | Run the story; any failure, including a named one from the story
itself, ends the run with @update-terminal: FAILED:@ on standard error
and exit status 1.
-}
main :: IO ()
main = do
    observedPath <- observedPathFrom <$> getArgs
    result <- try @SomeException (updateTerminal observedPath)
    case result of
        Right () -> pure ()
        Left e -> do
            hPutStrLn stderr ("update-terminal: FAILED: " <> displayException e)
            exitWith (ExitFailure 1)
