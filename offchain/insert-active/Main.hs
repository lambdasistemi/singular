{- |
Module      : Main
Description : #173 A173-COMMAND — `insert-active` from the released archive
License     : Apache-2.0

The packaged verb the release archive documents. A reviewer with the
extracted archive and no checkout runs it against a devnet and watches
the open registry boot, fold one certified `insertActive`, and hand the
active token to the wallet the request named.

> REGISTRY_BLUEPRINT=../onchain/plutus.json nix run .#insert-active -- --observed out.json

What it observes, in order:

1. the registry boots under the PARAMETERLESS open application and the
   three witness policies, all four pins from @REGISTRY_BLUEPRINT@
   alone — no naming blueprint anywhere;
2. one @insertActive@ folds and exactly one @(activePolicy, key)@ token
   lands in the output at the wallet the request named;
3. a FRESH key through the same builder also folds — the accepting
   control, taken BEFORE the duplicate because a refused request is
   never consumed and would otherwise poison the fold that follows it;
4. a SECOND @insertActive@ at the same key is REFUSED.

@--observed PATH@ writes the observation as JSON so a CI step asserts
the OBSERVATION rather than the exit code. Every value in it is read
back from the chain or from the blueprint; nothing is a literal written
here to make an assertion pass. Where the cage's refusal trace cannot
be recovered from the ledger's error text, the field is @null@ rather
than a guess.

The story is divided among command-local owners, each named below;
this module only turns any failure into the command's exit status:

* "InsertActive.Options" — @--observed@ and the blueprint read;
* "InsertActive.Steps" — boot, booking, fold and the wallet read;
* "InsertActive.Controls" — the accepting control and the duplicate
  refusal;
* "InsertActive.Observation" — the JSON document;
* "InsertActive.Scenario" — the order they run in.

Issue #183 re-cuts the request wire for every edge. This verb ships on
the PRE-#183 bytes and is re-baselined there; no claim is made here
about the wire after it.
-}
module Main (main) where

import Control.Exception (SomeException, displayException, try)
import System.Environment (getArgs)
import System.Exit (ExitCode (..), exitWith)
import System.IO (hPutStrLn, stderr)

import InsertActive.Options (observedPathFrom)
import InsertActive.Scenario (insertActive)

{- | Run the story; any failure, including a named one from the story
itself, ends the run with @insert-active: FAILED:@ on standard error and
exit status 1.
-}
main :: IO ()
main = do
    observedPath <- observedPathFrom <$> getArgs
    result <- try @SomeException (insertActive observedPath)
    case result of
        Right () -> pure ()
        Left e -> do
            hPutStrLn stderr ("insert-active: FAILED: " <> displayException e)
            exitWith (ExitFailure 1)
