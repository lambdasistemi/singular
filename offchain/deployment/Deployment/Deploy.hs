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

It refuses to run twice: given a manifest a node still agrees with, it
reports the deployment that already exists rather than making a second
one nobody asked for; given one the node does not agree with, it refuses
to overwrite the record of a deployment that may still be live
elsewhere.
-}
module Deployment.Deploy
    ( deploy
    ) where

import Control.Exception (SomeException, catch)
import Control.Monad (when)
import Data.ByteString.Short qualified as SBS
import Data.IORef (newIORef, readIORef)
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
import Singular.Registry.Config (CageConfig (..))
import Singular.Registry.Deployment
    ( Deployment (..)
    , readDeployment
    , renderOutRef
    , verifyDeployment
    , writeDeployment
    )
import Singular.Registry.Ledger (Coin (..))
import Singular.Registry.Node
    ( Capabilities (..)
    , bech32Address
    , funderAddr
    , withCapabilities
    )
import Singular.Registry.Provider qualified as Cage
import Singular.Registry.TxBuilder.Internal
    ( computeScriptHash
    , mkRequestScript
    , scriptFromBytes
    , scriptHashBytes
    )

-- | Make the deployment these arguments describe, once.
deploy :: [String] -> IO ()
deploy args = do
    DeployOptions
        { deployOut = out
        , deployRelease = release
        , deployLeanRevision = leanRev
        , deployProcessTime = processTime
        , deployRetractTime = retractTime
        } <-
        deployOptions args
    unbound <- loadCompiled
    withCapabilities $ \caps -> do
        let prov = capReads caps
        refuseIfAlreadyDeployed prov out unbound
        txs <- newIORef []
        -- A registry boots only by reference: the state validator is
        -- published before the boot, which resolves it from there.
        (stateIn, _) <-
            publishOne
                prov
                caps
                txs
                (scriptFromBytes "state" (cStateBytes unbound))
        (cfg, tok, bootTx, seedIn, compiled) <-
            bootRegistry prov caps unbound txs processTime retractTime
        registerCredentials prov caps compiled txs
        refs <- publishAll prov caps cfg tok compiled stateIn txs
        bootstrap <- reverse <$> readIORef txs
        magic <- Cage.withView prov (pure . Cage.cpNetwork . Cage.viewPoint)
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
                <> bech32Address funderAddr
            )

{- | A deployment is made once. Given a manifest a node still agrees
with, say so and stop, rather than booting a second registry that
nothing recorded will ever point at.
-}
refuseIfAlreadyDeployed
    :: Cage.Provider IO -> FilePath -> Compiled -> IO ()
refuseIfAlreadyDeployed prov out unbound = do
    there <- doesFileExist out
    when there $ do
        dep <- readDeployment out
        compiled <- bindDeployment unbound dep
        live <-
            ( True
                <$ Cage.withView
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
