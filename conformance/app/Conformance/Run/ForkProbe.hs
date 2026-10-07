{- |
Module      : Conformance.Run.ForkProbe
Description : Split out of Conformance.Run (#263); see that module's header
License     : Apache-2.0
-}
module Conformance.Run.ForkProbe (runForkProbe, runForkProbeSession) where

import Conformance.Run.Actor (Actor (..), actorAddress)

import Conformance.Run.Cage (ensureStateRefWith)
import Conformance.Run.Environment
import Conformance.Run.Node (checkHarnessGenesis, withHarnessNode)
import Conformance.Run.Observe
import Conformance.Run.Submit
import Conformance.Run.Wallet
import Control.Monad (void)

import Control.Exception
    ( SomeException
    , displayException
    , try
    )
import Data.ByteString.Short qualified as SBS
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE

import Singular.Registry.Blueprint (NamingCodes (..))
import Singular.Registry.Capabilities (capReads)
import Singular.Registry.Funding (checkFunding, defaultFundingFloor)
import Singular.Registry.SessionIO qualified as Cage
import Singular.Registry.Trie (TrieManager (..))
import Singular.Registry.Trie.PureManager (mkPureTrieManager)
import Singular.Registry.TxBuilder.Boot (bootTokenImpl)
import Singular.Registry.TxBuilder.Edges qualified as RegistryEdges
import Singular.Registry.TxBuilder.Internal
    ( txInToRef
    , walkEdge
    )
import Singular.Registry.TxBuilder.Update (updateTokenWithDuties)
import Singular.Registry.Types
    ( edgeInsertAbsent
    , edgeUpdateActive
    )

import Conformance.ForkKeys (findPresentForkKeys)
import Conformance.Mirror
    ( emit
    , require
    , txIdHex
    )

{- | t81 present-key `Fork` control (P-B): insert K1, P, Q (predicted
`[]`, `Leaf`-class, `Leaf`-class, all accepted), then an update fold
for present K1 whose proof carries `Fork` on the inclusion path — no
`excluding()` involved. Predicted REFUSED (bare `CekError`): the
divergence is about single-branch-sibling `Fork` per se. An ACCEPTED
fold falsifies that and opens a green path for the row (re-marking
stays an owner ruling). No receipts: this is an investigation probe,
not a row; shapes and verdicts are the evidence.
-}
runForkProbe :: IO ()
runForkProbe = do
    blueprintPath <- requireEnv "REGISTRY_BLUEPRINT"
    (stateBytes, requestBytes, namingCodes) <- loadCodes blueprintPath
    checkHarnessGenesis
    nodeVer <- readNodeVersion
    emit "node" nodeVer
    base <- requireBase
    emit "base" base
    bracketTmpDir $ do
        withHarnessNode $
            runForkProbeSession stateBytes requestBytes namingCodes

runForkProbeSession
    :: SBS.ShortByteString
    -> SBS.ShortByteString
    -> NamingCodes
    -> Actor
    -> IO ()
runForkProbeSession stateBytes requestBytes namingCodes caps = do
    let prov = capReads (actorCaps caps)
        submit = caps
    checkFunding prov (actorAddress caps) defaultFundingFloor
    tm <- mkPureTrieManager
    -- Boots by reference: publish the state validator before the seed
    -- is chosen, so the publication cannot spend the seed.
    ensureStateRefWith prov submit stateBytes
    (seed, _) <- largestWalletUtxo caps prov
    let cfg = cageCfg stateBytes requestBytes namingCodes (txInToRef seed)
    unsignedBoot <-
        Cage.withLatest prov (\v -> bootTokenImpl cfg v (actorAddress caps))
    signedBoot <- submitWithGenesis submit unsignedBoot
    tid <- extractTokenId cfg signedBoot
    createTrie tm tid
    refs <-
        RegistryEdges.publishCageRefs
            cfg
            namingCodes
            prov
            (submitWithGenesis submit)
            (actorAddress caps)
            tid
    (keyK, keyP, keyQ, _, _, _) <- findPresentForkKeys
    emit "probe-keys" (show (keyK, keyP, keyQ))
    (_, unsigned1) <- insertProbe tm cfg prov submit tid refs keyK
    require
        "probe setup unexpectedly carries Fork"
        (1 `notElem` proofStepConstrs unsigned1)
    (_, unsignedP) <- insertProbe tm cfg prov submit tid refs keyP
    require
        ( "probe setup P proof unexpected: "
            <> show (proofStepConstrs unsignedP)
        )
        (2 `elem` proofStepConstrs unsignedP)
    (_, unsignedQ) <- insertProbe tm cfg prov submit tid refs keyQ
    require
        ( "probe setup Q unexpectedly carries Fork: "
            <> show (proofStepConstrs unsignedQ)
        )
        (1 `notElem` proofStepConstrs unsignedQ)
    emit
        "probe"
        "update fold for present K1 (inclusion path, no excluding)"
    _ <-
        RegistryEdges.bookEdge
            cfg
            namingCodes
            prov
            (submitWithGenesis submit)
            (actorAddress caps)
            tid
            keyK
            edgeUpdateActive
    probeResult <-
        try @SomeException $
            Cage.withLatest prov $ \v -> do
                ctx <- RegistryEdges.registryContextFor cfg namingCodes v refs
                updateTokenWithDuties cfg v tm tid (actorAddress caps) ctx
    case probeResult of
        Left err -> do
            emit "verdict" "REFUSED as predicted"
            emit "refusal" (take 600 (displayException err))
            emit "complete" "probe done: inclusion-path Fork refused"
        Right unsignedProbe -> do
            emit "verdict" "ACCEPTED against prediction: Fork works on inclusion"
            emit "probe-steps" (show (proofStepConstrs unsignedProbe))
            require
                "accepted probe lacks well-formed Fork neighbor"
                ( 1 `elem` proofStepConstrs unsignedProbe
                    && forkNeighborsWellFormed unsignedProbe
                )
            signedProbe <- submitWithGenesis submit unsignedProbe
            emit "probe-txid" (txIdHex signedProbe)
            emit
                "complete"
                "probe done: inclusion-path Fork ACCEPTED (falsification)"
  where
    insertProbe tmInner cfgInner provInner submitInner tidInner refs key = do
        _ <-
            RegistryEdges.bookEdge
                cfgInner
                namingCodes
                provInner
                (submitWithGenesis submitInner)
                (actorAddress submitInner)
                tidInner
                key
                edgeInsertAbsent
        unsignedFold <- Cage.withLatest provInner $ \v -> do
            ctx <- RegistryEdges.registryContextFor cfgInner namingCodes v refs
            updateTokenWithDuties
                cfgInner
                v
                tmInner
                tidInner
                (actorAddress submitInner)
                ctx
        signedFold <- submitWithGenesis submitInner unsignedFold
        _ <- withTrie tmInner tidInner $ \t ->
            void (walkEdge t key edgeInsertAbsent)
        emit
            ("probe-insert-" <> T.unpack (TE.decodeUtf8Lenient key))
            (show (proofStepConstrs unsignedFold))
        pure (signedFold, unsignedFold)
