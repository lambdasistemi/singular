{- |
Module      : Journey.Scenario
Description : The bounded registry journey, in the order it runs
License     : Apache-2.0

'journey' is the whole command below its outer failure handler: read
the environment, print the pinned identities, load the blueprint, and
run the eleven steps in one node session ('runJourney'):

boot, publish references, book the insert, prove the key absent, fold
it, derive and check the applied identities, prove the key present and
refuse a false claim, read the state back, then the negative cases and
their unchanged-state control.

Each step's owner: "Journey.Steps" (boot, request, apply, read-back),
"Journey.Proofs" (verify-absent, verify-present, false claim),
"Journey.Identity" (identity header and derived-applied-identity),
"Journey.Controls" (the refused transactions and their control).
-}
module Journey.Scenario (
    journey,
) where

import Data.ByteString.Short qualified as SBS
import Data.IORef (newIORef)
import Lens.Micro ((^.))

import Cardano.Ledger.Api.Tx.Out (referenceScriptTxOutL)
import Cardano.Ledger.BaseTypes (StrictMaybe (..))
import MPF.Backend.Pure (emptyMPFInMemoryDB)

import Journey.Chain (cageCfg, genesisAddr, submitWithGenesis)
import Journey.Controls (stepReject)
import Journey.Identity (
    ScriptIdentity,
    printIdentity,
    readScriptIdentity,
    stepDerivedIdentity,
 )
import Journey.Narration (emit, failWith)
import Journey.Options (identityPathFromEnv, requireEnv)
import Journey.Proofs (stepVerifyAbsent, stepVerifyPresent)
import Journey.Steps (stepApply, stepBoot, stepReadBack, stepRequest)
import Singular.Registry.Blueprint (
    extractCompiledCode,
    loadBlueprint,
    loadRegistryCodesFromEnv,
 )
import Singular.Registry.Node (NodeSession (..), withNode)
import Singular.Registry.Provider qualified as Cage
import Singular.Registry.Trie.PureManager (mkPureTrieManager)
import Singular.Registry.TxBuilder.Edges qualified as Edges
import Singular.Registry.TxBuilder.Internal (scriptFromBytes, txInToRef)

-- | Read the environment and identities, then run the journey.
journey :: IO ()
journey = do
    blueprintPath <- requireEnv "REGISTRY_BLUEPRINT"
    identityPath <- identityPathFromEnv
    si <- readScriptIdentity identityPath
    printIdentity si
    ebp <- loadBlueprint blueprintPath
    bp <- either failWith pure ebp
    case ( extractCompiledCode "state.state" bp
         , extractCompiledCode "request.request" bp
         , extractCompiledCode "staking.staking" bp
         ) of
        (Just stateBytes, Just requestBytes, Just stakingBytes) ->
            runJourney si stateBytes requestBytes stakingBytes
        _ ->
            failWith
                "state.state, request.request or staking.staking \
                \compiled code not found in blueprint"

{- | The eleven steps against one node session, from the three
validators' compiled code.
-}
runJourney ::
    ScriptIdentity ->
    SBS.ShortByteString ->
    SBS.ShortByteString ->
    SBS.ShortByteString ->
    IO ()
runJourney si stateBytes requestBytes stakingBytes = do
    withNode $ \sess -> do
        let prov = nsProvider sess
            submit = nsSubmitter sess
        tm <- mkPureTrieManager
        -- The proof mirror: an in-memory trie kept in step with
        -- the operations the journey applies on chain. It builds
        -- the proofs; the roots those proofs are checked against
        -- are always read back from the chain's state datum
        -- (D-013), never from this trie.
        mirrorRef <- newIORef emptyMPFInMemoryDB
        -- Verify the connection carries queries before building on it.
        _ <- Cage.queryProtocolParams prov
        -- #177 A-003: publish the state validator as a reference output
        -- BEFORE the seed is chosen, so the publication cannot spend
        -- the very output the seed pins. Boot then references the
        -- fifteen-kilobyte script instead of carrying it inline.
        stateRef <-
            Edges.publishRefScript
                prov
                (submitWithGenesis submit)
                genesisAddr
                (scriptFromBytes "state" stateBytes)
        -- Pick the boot seed from the genesis wallet. The state
        -- script is unparameterized; boot carries the seed in the
        -- mint redeemer.
        utxos <- Cage.queryUTxOs prov genesisAddr
        -- #177 A-003: never seed from the reference publication; boot
        -- references that output and cannot also spend it.
        seedRef <- case filter (\(_, o) -> o ^. referenceScriptTxOutL == SNothing) utxos of
            [] ->
                failWith
                    "genesis wallet has no spendable UTxO; cannot pick a boot seed"
            (txIn, _) : _ -> pure (txInToRef txIn)
        codes <- loadRegistryCodesFromEnv
        let cfg = cageCfg stateBytes requestBytes codes seedRef
        (tokenId, bootRoot, bootTx) <- stepBoot cfg prov submit tm
        -- The state validator alone is fifteen kilobytes: a fold that
        -- attaches it, the request validator and a token policy does not
        -- fit in a transaction. Published once, every purpose resolves
        -- through these instead.
        refs <-
            Edges.publishCageRefs
                cfg
                codes
                prov
                (submitWithGenesis submit)
                genesisAddr
                tokenId
        emit
            "references"
            ( show (length refs)
                <> " scripts published as reference outputs"
            )
        reqCount <- stepRequest cfg codes prov submit tokenId
        stepVerifyAbsent cfg prov mirrorRef tokenId
        appliedTx <- stepApply cfg codes prov submit tm tokenId refs reqCount
        stepDerivedIdentity
            si
            cfg
            stateBytes
            requestBytes
            stakingBytes
            tokenId
            bootTx
            appliedTx
            (stateRef : refs)
        stepVerifyPresent cfg prov mirrorRef tokenId
        appliedState <- stepReadBack cfg prov tokenId bootRoot
        stepReject cfg codes prov submit tm tokenId refs appliedState
        emit "complete" "11/11 journey steps ok"
