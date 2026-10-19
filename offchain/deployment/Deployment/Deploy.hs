{- |
Module      : Deployment.Deploy
Description : @deployment deploy@ — make a deployment once, and record it
License     : Apache-2.0

Boots one registry and publishes one set of reference-script outputs
from the joiner's wallet, then writes the manifest that records them and
verifies it against the same node. In order: refuse if the manifest
already exists; publish the state validator (a registry boots only by
reference); boot from the wallet's largest output that is not that
publication; register the stake credentials; publish the other four
reference scripts; write the manifest; verify it.

A stop before the manifest writes nothing to the manifest path: the
bootstrap transactions submitted so far are narrated as one @partial@
line, oldest first, and the stop is rethrown unchanged.

It refuses to run twice: given a manifest a node still agrees with, it
reports the deployment that already exists rather than making a second
one nobody asked for; given one the node does not agree with, it refuses
to overwrite the record of a deployment that may still be live
elsewhere.
-}
module Deployment.Deploy
    ( deploy
    ) where

import Control.Exception (SomeException, catch, onException)
import Control.Monad (unless, when)
import Data.ByteString.Short qualified as SBS
import Data.IORef (IORef, newIORef, readIORef)
import Data.Text qualified as T
import System.Directory (doesFileExist)

import Cardano.Ledger.Core (hashScript)

import Deployment.Compiled
    ( Compiled (..)
    , bindDeployment
    , loadCompiled
    , partsOf
    )
import Deployment.Narration (emit, failWith, hexT, tokenText, txText)
import Deployment.Node
    ( bootRegistry
    , publishAll
    , publishOne
    , registerCredentials
    , verifyRegisteredDeployment
    )
import Deployment.Options (DeployOptions (..), deployOptions)
import Singular.Registry.Capabilities (Capabilities (..))
import Singular.Registry.Config (CageConfig (..))
import Singular.Registry.Deployment
    ( Deployment (..)
    , readDeployment
    , renderOutRef
    , verifyDeployment
    , writeDeployment
    )
import Singular.Registry.Evidence (NoWitness)
import Singular.Registry.Ledger (Coin (..))
import Singular.Registry.LedgerProvider qualified as Ledger
import Singular.Registry.Runner (withRunner)
import Singular.Registry.SessionIO qualified as Cage
import Singular.Registry.TxBuilder.Internal
    ( computeScriptHash
    , mkRequestScript
    , scriptFromBytes
    , scriptHashBytes
    )
import Singular.Registry.Wallet (Wallet (..), bech32Address)

-- | Make the deployment these arguments describe, once.
deploy :: [String] -> IO ()
deploy args = do
    DeployOptions
        { deployOut = out
        , deployRelease = release
        , deployLeanRevision = leanRev
        , deployProcessTime = processTime
        , deployRetractTime = retractTime
        , deployRegistrationCost = registrationCost
        , deployBookingWidth = bookingWidth
        } <-
        deployOptions args
    unbound <- loadCompiled
    -- \| Owner, lifetime and concurrency contract for the deployment tx
    --    accumulator. It belongs to this single 'deploy' invocation:
    --    created once, threaded explicitly through publication, boot and
    --    registration, read once for the manifest. 'submitted' conses each
    --    accepted transaction newest-first and 'deploy' reverses for the
    --    manifest, so repeated recording is O(1) while the manifest keeps
    --    receipt order. The product is single-threaded: one command submits
    --    in order on the calling thread, so plain 'readIORef'/'writeIORef'
    --    suffice and no thread outlives the command. A stop before the
    --    manifest reports the accumulator through 'reportPartial' below.
    --
    txs <- newIORef []
    withRunner
        ( \wallet caps -> do
            let prov = capReads caps
            refuseIfAlreadyDeployed prov out unbound
            -- A registry boots only by reference: the state validator is
            -- published before the boot, which resolves it from there.
            (stateIn, _) <-
                publishOne
                    wallet
                    prov
                    caps
                    txs
                    (scriptFromBytes "state" (cStateBytes unbound))
            (cfg, tok, bootTx, seedIn, compiled) <-
                bootRegistry
                    wallet
                    prov
                    caps
                    unbound
                    txs
                    processTime
                    retractTime
                    registrationCost
                    bookingWidth
            registerCredentials wallet prov caps compiled txs
            refs <- publishAll wallet prov caps cfg tok compiled stateIn txs
            bootstrap <- reverse <$> readIORef txs
            let Ledger.Network magic = fst prov
            let dep =
                    Deployment
                        { depRelease = release
                        , depLeanRevision = leanRev
                        , depNetworkMagic = magic
                        , depSeedOutRef = renderOutRef seedIn
                        , depCageToken = tokenText tok
                        , depStatePolicy =
                            hexT (scriptHashBytes (cfgScriptHash cfg))
                        , depRequestHash =
                            hexT (scriptHashBytes (hashScript (mkRequestScript cfg tok)))
                        , depApplicationHash =
                            hexT (scriptHashBytes (computeScriptHash (cAppBytes compiled)))
                        , depRepresentativePolicy =
                            hexT (SBS.fromShort (cfgActivePolicy cfg))
                        , depProcessTime = defaultProcessTime cfg
                        , depRetractTime = defaultRetractTime cfg
                        , depTip = let Coin c = defaultTip cfg in c
                        , depRegistrationCost =
                            let Coin c = defaultRegistrationCost cfg in c
                        , depBookingWidth = defaultBookingWidth cfg
                        , depReferenceScripts = refs
                        , depBootstrapTxs = bootstrap
                        }
            writeDeployment out dep
            emit "manifest" ("wrote " <> out)
            claims <- verifyRegisteredDeployment prov dep compiled
            mapM_ (emit "verified") claims
            emit
                "complete"
                ( "registry "
                    <> T.unpack (tokenText tok)
                    <> " booted in "
                    <> T.unpack (txText bootTx)
                    <> "; "
                    <> show (length refs)
                    <> " reference scripts published; funded by "
                    <> bech32Address (walletAddr wallet)
                )
        )
        `onException` reportPartialBestEffort txs

{- | Narrate a deployment that stopped before writing its manifest: the
bootstrap transactions submitted so far, oldest first. Runs on any
throw, including cancellation; the original stop is rethrown unchanged
by 'onException', and nothing is written to the manifest path, so the
no-overwrite rule for an existing manifest is untouched.
-}
reportPartial :: IORef [T.Text] -> IO ()
reportPartial txs = do
    partial <- reverse <$> readIORef txs
    unless (null partial) $
        emit
            "partial"
            ( "no manifest written; bootstrap transactions so far: "
                <> T.unpack (T.intercalate " " partial)
            )

{- | Best-effort partial narration that cannot mask the original stop:
if reporting itself throws (for example stdout is closed), the
original exception still propagates unchanged from 'onException'.
-}
reportPartialBestEffort :: IORef [T.Text] -> IO ()
reportPartialBestEffort txs =
    reportPartial txs `catch` \(_ :: SomeException) -> pure ()

{- | A deployment is made once. Given a manifest a node still agrees
with, say so and stop, rather than booting a second registry that
nothing recorded will ever point at.
-}
refuseIfAlreadyDeployed
    :: (Ledger.Network, Ledger.LedgerProvider NoWitness IO)
    -> FilePath
    -> Compiled
    -> IO ()
refuseIfAlreadyDeployed prov out unbound = do
    there <- doesFileExist out
    when there $ do
        dep <- readDeployment out
        compiled <- bindDeployment unbound dep
        live <-
            ( True
                <$ Cage.withLatest
                    prov
                    (\v -> verifyDeployment v dep (partsOf compiled))
            )
                `catch` \(_ :: SomeException) -> pure False
        if live
            then
                failWith
                    ( out
                        <> " already records a deployment this node agrees with \
                           \(registry 0x"
                        <> T.unpack (depCageToken dep)
                        <> "). A deployment is made once; use \
                           \`deployment verify` to check it, or delete the \
                           \manifest to make a new one."
                    )
            else
                failWith
                    ( out
                        <> " already exists but this node does not agree with \
                           \it. Deploying would overwrite the record of a \
                           \deployment that may still be live elsewhere; move \
                           \the file aside deliberately."
                    )
