{- |
Module      : Main
Description : The bounded registry journey, verified against a real devnet
License     : Apache-2.0

One command that runs the bounded journey against a real devnet
node and verifies it, one line per step:

  boot a cage, submit a request, prove the key absent, apply
  the request, prove the key present with the expected value,
  reject a false claim, read the resulting state back, then
  submit three transactions the on-chain validators must
  refuse — a forged state-token identity, a tampered
  certified output and a dropped proof witness —
  and prove the authenticated state took no trace from them.
  (`End` refuses for every party under the ownerless ruling;
  that evidence belongs to the separate, retained repair-rows
  runner, currently unverified under #172, not to this journey.)

The three negative cases are registry negative cases. They
exercise the imported validators' identity, certified-output and
witness guards; no Singular naming behaviour
exists in this runner.

Verification follows D-013: the library builds proofs
('mkMPFExclusionProof', 'mkMPFInclusionProof'); off-chain each
proof is folded to the root it implies and that root is compared
against the root read back from the chain's state datum — never
against a root this runner derived from the same trie.

This is the vehicle for Singular's naming claim, not the claim:
nothing this runner prints describes a name as claimed, registered
or maintained. It exercises the registry protocol only.

It uses the same code path as the end-to-end suite — 'bootTokenImpl',
'requestEdgeImpl', 'updateTokenImpl' and a real node-to-client
connection to a real 'cardano-node' spawned as a subprocess. No
mocks, no stubbed node.

At start it prints the upstream source revision and the pinned
validator hashes read from @onchain/script-identity.json@. Those
pins are the /unapplied/ blueprint identities — the stable,
reviewable scripts issue #34 enforces — not the hashes a
transaction carries: the request validator takes 2 parameters, so
applying them changes its hash, while the state and staking
validators take none, so their applied and unapplied hashes
coincide. The run therefore also reports the /applied/ hashes it
actually used, with the request validator's parameters named, and
asserts the derivation between the two layers (marker
@derived-applied-identity@): each applied hash must equal the hash
of the unapplied blueprint code with this instance's parameters
applied, or the run fails naming both hashes and the parameters.
The state line still prints @previousPolicies=[]@ and
@(1 parameter)@: that wording is kept byte for byte as existing
narration and is not the state validator's arity, which the
manifest pins as 0 and the run checks by hashing the raw code.

The journey is divided among command-local owners; this module only
turns any failure into the command's exit status:

* "Journey.Options" — the environment it reads;
* "Journey.Identity" — the pinned identities and their derivation;
* "Journey.Steps" — boot, booking, fold and read-back;
* "Journey.Proofs" — the authenticated-state checks and the false claim;
* "Journey.Controls" and "Journey.Malformations" — the refused
  transactions and the unchanged-state control;
* "Journey.Chain" and "Journey.Narration" — shared plumbing;
* "Journey.Scenario" — the order the steps run in.
-}
module Main (main) where

import Control.Exception (SomeException, catch, displayException)
import System.Exit (ExitCode (..), exitWith)
import System.IO (hPutStrLn, stderr)

import Journey.Scenario (journey)

{- | Run the journey; any failure ends it with @journey: FAILED:@ on
standard error and exit status 1.
-}
main :: IO ()
main =
    journey `catch` \(e :: SomeException) -> do
        hPutStrLn stderr ("journey: FAILED: " <> displayException e)
        exitWith (ExitFailure 1)
