{- |
Module      : Main
Description : Make a deployment once, and check it afterwards
License     : Apache-2.0

Four verbs over one persistent registry. The first argument that is not
a flag names the verb; flags may come before or after it.

@deployment deploy@ boots one registry and publishes one set of
reference-script outputs from the joiner's wallet, then writes the
manifest that records them. It refuses to run twice: given a manifest a
node still agrees with, it reports the deployment that already exists
rather than making a second one nobody asked for.

@deployment verify@ asks a node whether it still agrees with a manifest
and prints, claim by claim, what it answered.

@deployment count@ counts the registry outputs or reference outputs a
deployment would otherwise create, so a check can tell whether a run
created any.

@deployment genesis-skey@ writes the factory devnet's public genesis key
in the file form a joiner supplies.

Anything else is refused with the usage text, which names @deploy@ and
@verify@ only. Every refusal and failure ends the run with
@deployment: FAILED:@ on standard error and exit status 1.

The verbs that read or submit use the shared HTTP provider and the caller's
explicit wallet through @Singular.Registry.Runner@. Supply @--koios-url@,
@--network-magic@ and @--wallet-skey@, plus @--network-time@ for a generated
private network. The matching @SINGULAR_@ settings are also supported.
The private devnet launcher supplies those settings for retained CI runners.

Each verb has its own module — "Deployment.Deploy", "Deployment.Verify",
"Deployment.Count", "Deployment.GenesisKey" — over the shared
"Deployment.Options", "Deployment.Compiled", "Deployment.Node" and
"Deployment.Narration". The manifest itself is the library's
"Singular.Registry.Deployment".
-}
module Main (main) where

import Control.Exception (SomeException, catch, displayException)
import Data.List (isPrefixOf)
import System.Environment (getArgs)
import System.Exit (ExitCode (..), exitWith)
import System.IO (hPutStrLn, stderr)

import Deployment.Count (count)
import Deployment.Deploy (deploy)
import Deployment.GenesisKey (genesisSkey)
import Deployment.Narration (failWith)
import Deployment.Options (usage)
import Deployment.Verify (verify)

-- | Run the verb; report any failure and exit with status 1.
main :: IO ()
main =
    run `catch` \(e :: SomeException) -> do
        hPutStrLn stderr ("deployment: FAILED: " <> displayException e)
        exitWith (ExitFailure 1)

-- | Dispatch on the first argument that is not a flag.
run :: IO ()
run = do
    args <- getArgs
    case [a | a <- args, not ("-" `isPrefixOf` a)] of
        ("deploy" : _) -> deploy args
        ("verify" : _) -> verify args
        ("count" : _) -> count args
        ("genesis-skey" : _) -> genesisSkey args
        _ -> failWith usage
