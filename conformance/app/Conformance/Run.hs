{- |
Module      : Conformance.Run
Description : The conformance sessions: canonical identity, registry rows and serialization
License     : Apache-2.0

One @run@ boots an isolated devnet per session and executes the requested
rows in canonical order. Every result is read back from the chain.

The registry-identity rows (issue #69) run as their own session: a designation
split publishes a canonical seed, canonical-seed-identity boots the canonical registry
and matches its on-chain token name against the SHA-256 derivation,
rival-seed-authentication initializes a rival registry from a second seed — which the
ledger ACCEPTS (naming-correspondence.md, "What t50 settled": a
permissionless ledger cannot prohibit a rival; canonical identity is
a derivation the consumer authenticates, not a refusal the chain
performs) — and asserts the rival's acceptance, the name difference
and the canonical registry's unaffected state, each read back from
the chain. policy-address-only-authentication-control is the executing control: an authenticator that
checks only policy and address accepts the rival, proving rival-seed-authentication's
rejection is attributable to the derived name alone. applied-validator-identity derives
the applied address from the pinned unapplied hash plus the declared
parameters and compares it with the address the chain reports.
tokenless-output-authentication forges an output at the canonical address carrying no registry
token: creating an output does not execute the receiving script, and
the run must show no script executed — not merely that nothing bad
happened.

The registry rows run as their own session. A row with a program
("Conformance.Edge.Programs") runs it through the generic interpreter, in
registries of its own, so a row's odd state (a parked request) cannot poison
its neighbours; fold-against-superseded-root and surplus-fold-actions, which the model cannot express, run their own
refusals and accepting controls. A held, unmet or failing row ends the
session non-zero, naming every such row.

@CONFORMANCE_CONTROL=wrong-reason@ arms the serialization refusal matcher against
an impossible marker (the run must fail naming what came back; a registry
session refuses it, no registry row matching a refusal against a marker);
@CONFORMANCE_CONTROL=false-claim@, in a registry-identity session, binds the fabricated
wrong-seed derivation to canonical-seed-identity's name match (it must fail).
@CONFORMANCE_CONTROL=naive-authenticator@ makes policy-address-only-authentication-control require the
policy+address-only authenticator to reject the rival, which it
cannot (the run must fail naming the accepted rival);
@CONFORMANCE_CONTROL=unapplied-address@ makes applied-validator-identity require the
unapplied layer's address to pass for the deployed script, which it
cannot (the run must fail). All prove the harness fails when it
should.
-}
module Conformance.Run (runForkProbe, runRows) where

import Conformance.FoldFixture qualified as FoldFixture

import Conformance.Authentication.Programs qualified as Authentication
import Conformance.Edge.Programs (programFor)
import Conformance.Run.Authentication
    ( openIdentitySession
    , runAuthenticationRow
    )
import Conformance.Run.Cage
import Conformance.Run.CgRows
import Conformance.Run.Control
import Conformance.Run.CsRows
import Conformance.Run.Environment
import Conformance.Run.ForkProbe
import Conformance.Run.Node (checkHarnessGenesis, withReplayingNode)
import Conformance.Run.Receipts
import Conformance.Run.Replay (ReplayIndex (..))
import Conformance.Run.Wallet

import Control.Exception
    ( ErrorCall (..)
    , throwIO
    )
import Control.Monad (unless, when)
import Data.ByteString.Short qualified as SBS
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import System.Directory (createDirectoryIfMissing)

import Singular.Registry.Blueprint (NamingCodes (..))
import Singular.Registry.Config (CageConfig)
import Singular.Registry.Ledger
    ( AssetName (..)
    , TokenId (..)
    )
import Singular.Registry.Node
    ( Capabilities (..)
    , checkFunding
    , defaultFundingFloor
    , funderAddr
    )
import Singular.Registry.Provider qualified as Cage
import Singular.Registry.Trie.PureManager (mkPureTrieManager)
import Singular.Registry.TxBuilder.Internal
    ( txInToRef
    )

import Conformance.BlueprintEncoding (runBlueprintEncodingRoundTrip)
import Conformance.Mirror
    ( emit
    , failWith
    , newMirror
    )
import Conformance.ScriptParameters (runScriptParameterApplication)

-- ---------------------------------------------------------
-- Entry point
-- ---------------------------------------------------------

runRows :: [String] -> FilePath -> IO ()
runRows rawRows receiptsDir = do
    rows <- validateRows rawRows
    control <- readControl
    emit "control" (show control)
    let identityRequested = any (`elem` authenticationRows) rows
        cgRequested = any (`elem` cgSessionRows) rows
    -- Armed controls must never pass vacuously: each mode belongs to
    -- one session, and a session it cannot fire in is refused here.
    when (identityRequested && control == WrongReason) $
        failWith
            "wrong-reason arms a refusal matcher, but the registry-identity rows \
            \assert no ledger refusal (the rival is accepted by \
            \design); use naive-authenticator, false-claim or \
            \unapplied-address"
    when (cgRequested && control == WrongReason) $
        failWith
            "wrong-reason arms a refusal matcher, but no registry-operations row matches a \
            \refusal against it; a compared refusal's reason is controlled \
            \by CONFORMANCE_REASON_CONTROL"
    when
        ( cgRequested
            && control `elem` [NaiveAuthenticator, UnappliedAddress, FalseClaim]
        )
        $ failWith
            "naive-authenticator, unapplied-address and false-claim are registry-identity \
            \controls; the registry-operations rows they cannot arm would pass vacuously"
    blueprintPath <- requireEnv "REGISTRY_BLUEPRINT"
    -- Observe tree identity before any side effect: creating the
    -- receipts directory first would always report dirty.
    base <- requireBase
    emit "base" base
    dirty <- requireTreeClean
    emit "tree" (if dirty then "dirty (receipts record it)" else "clean")
    createDirectoryIfMissing True receiptsDir
    let localRows =
            [ r
            | r <- rows
            , r
                `elem` ["blueprint-encoding-round-trip", "script-parameter-application"]
            ]
        devnetRows =
            [ r
            | r <- rows
            , r
                `notElem` ["blueprint-encoding-round-trip", "script-parameter-application"]
            ]
        cgDevnet = [r | r <- devnetRows, r `elem` cgSessionRows]
        identityDevnet = [r | r <- devnetRows, r `elem` authenticationRows]
        wireDevnet = [r | r <- devnetRows, r `elem` wireRows]
        unpartitioned =
            [ r
            | r <- devnetRows
            , r `notElem` (authenticationRows <> wireRows <> cgSessionRows)
            ]
    unless (null unpartitioned) $
        failWith
            ("rows in no partition: " <> unwords unpartitioned)
    mapM_ (runLocalRow blueprintPath receiptsDir base dirty) localRows
    unless (null devnetRows) $ do
        (stateBytes, requestBytes, namingCodes) <- loadCodes blueprintPath
        checkHarnessGenesis
        nodeVer <- readNodeVersion
        emit "node" nodeVer
        let session sessionRows =
                unless (null sessionRows) $
                    bracketTmpDir $
                        withReplayingNode blueprintPath receiptsDir (T.pack nodeVer) $ \caps replayIndex ->
                            runSession
                                sessionRows
                                control
                                (stateBytes, requestBytes, namingCodes)
                                blueprintPath
                                nodeVer
                                base
                                dirty
                                receiptsDir
                                caps
                                replayIndex
        session identityDevnet
        session cgDevnet
        unless (null wireDevnet) $
            bracketTmpDir $ do
                withReplayingNode blueprintPath receiptsDir (T.pack nodeVer) $ \caps replayIndex ->
                    runCSSession
                        wireDevnet
                        control
                        stateBytes
                        requestBytes
                        namingCodes
                        nodeVer
                        base
                        dirty
                        receiptsDir
                        caps
                        replayIndex
    when (null devnetRows) $
        emit
            "complete"
            (show (length localRows) <> "/" <> show (length rows) <> " rows ok")

runLocalRow
    :: FilePath -> FilePath -> String -> Bool -> String -> IO ()
runLocalRow blueprintPath receiptsDir base dirty row = case row of
    "blueprint-encoding-round-trip" -> runBlueprintEncodingRoundTrip blueprintPath receiptsDir base dirty
    "script-parameter-application" -> runScriptParameterApplication blueprintPath receiptsDir base dirty
    _ -> failWith ("run cannot execute local row: " <> row)

validateRows :: [String] -> IO [String]
validateRows [] =
    failWith
        "run needs at least one requirement name; list shows the available names"
validateRows raw = do
    let bad = [r | r <- raw, r `notElem` canonicalRows]
    unless (null bad) $
        failWith ("run cannot execute rows: " <> unwords bad)
    let requested = [r | r <- canonicalRows, r `elem` raw]
    when
        ( any (`elem` authenticationRows) requested
            && any (`elem` cgSessionRows) requested
        )
        $ failWith
            "registry-identity and registry-operations rows run as separate sessions, one devnet \
            \each: run the identity requirements, then the registry operation requirements"
    pure requested

-- ---------------------------------------------------------
-- Session
-- ---------------------------------------------------------

runSession
    :: [String]
    -> Control
    -> (SBS.ShortByteString, SBS.ShortByteString, NamingCodes)
    -> FilePath
    -> String
    -> String
    -> Bool
    -> FilePath
    -> Capabilities
    -> ReplayIndex
    -> IO ()
runSession
    rows
    control
    codes@(stateBytes, requestBytes, namingCodes)
    blueprintPath
    nodeVer
    base
    dirty
    receiptsDir
    caps
    replayIndex = do
        let prov = capReads caps
        checkFunding prov funderAddr defaultFundingFloor
        _ <- Cage.withView prov (pure . Cage.viewProtocolParams)
        let identityMode = any (`elem` authenticationRows) rows
            environment cfg world = do
                tm <- mkPureTrieManager
                mirror <- newMirror
                foldFixture <- FoldFixture.newFixture
                refsRef <- newIORef Nothing
                validUnits <- newIORef (0, 0)
                worlds <- newIORef Map.empty
                key2Ref <- newIORef Nothing
                heldRef <- newIORef []
                unmetRef <- newIORef []
                failedRef <- newIORef []
                liveRecordsRef <- newIORef []
                liveMeasurementsRef <- newIORef []
                pure
                    Env
                        { envCfg = cfg
                        , envProv = prov
                        , envSubmit = capSubmit caps
                        , envConfirm = capConfirm caps
                        , envTm = tm
                        , -- never read: every registry row boots its own
                          -- registries, and the row validator keeps them out
                          -- of a registry-identity session
                          envTid = TokenId (AssetName (SBS.toShort ""))
                        , envMirror = mirror
                        , envControl = control
                        , envBase = base
                        , envDirty = dirty
                        , envFoldFixture = foldFixture
                        , envNode = nodeVer
                        , envBlueprint = blueprintId cfg requestBytes
                        , envReceiptsDir = receiptsDir
                        , envCodes = codes
                        , envBlueprintPath = blueprintPath
                        , envRefs = refsRef
                        , envValidUnits = validUnits
                        , envIdentity = world
                        , envWorlds = worlds
                        , envKey2 = key2Ref
                        , envHeld = heldRef
                        , envUnmet = unmetRef
                        , envFailed = failedRef
                        , envLiveRecords = liveRecordsRef
                        , envLiveMeasurements = liveMeasurementsRef
                        , envReplay = replayIndex
                        }
        (env, bootLine) <-
            if identityMode
                then do
                    -- The session's prologue publishes the canonical seed; its
                    -- registry's boot is the first row's, so none boots here.
                    (cfg, world) <- openIdentitySession prov caps codes
                    env <- environment cfg (Just world)
                    pure
                        ( env
                        , "registry-identity session: the canonical seed is published; \
                          \the consumer derives the canonical name as SHA-256 of its output reference"
                        )
                else do
                    -- Every registry row boots its own registries; the
                    -- session's config is an unbooted placeholder (the seed
                    -- query only names a real UTxO) kept for the record's
                    -- shape.
                    (seedTxIn, _) <- largestWalletUtxo prov
                    env <-
                        environment
                            ( cageCfg stateBytes requestBytes namingCodes (txInToRef seedTxIn)
                                :: CageConfig
                            )
                            Nothing
                    pure (env, "no session cage: every registry row boots its own")
        emit "boot" bootLine
        mapM_
            ( \row ->
                writeIORef (riRow replayIndex) (T.pack row)
                    >> runRow env row
            )
            rows
        if identityMode
            then writeIdentityExecutionUnitsAndTransactionSize env rows
            else writeExecutionUnitsAndTransactionSizeReceipt env rows
        emit
            "complete"
            (show (length rows) <> "/" <> show (length rows) <> " rows ok")
        -- A held, unmet or failing row must never read as a pass:
        -- the session ends non-zero naming every such row.
        held <- readIORef (envHeld env)
        unmet <- readIORef (envUnmet env)
        failed <- readIORef (envFailed env)
        case (held, unmet, failed) of
            ([], [], []) -> pure ()
            _ ->
                throwIO
                    ( ErrorCall
                        (debtReport (reverse held) (reverse unmet) (reverse failed))
                    )

-- ---------------------------------------------------------
-- Rows
-- ---------------------------------------------------------

runRow :: Env -> String -> IO ()
runRow env row = do
    -- A registry-identity row boots from the seed the session designated, so its wallet
    -- is left exactly as the designation left it. Every other row wants
    -- one ada-only output to fund from.
    unless (row `elem` authenticationRows) (consolidateFunding env)
    -- #177 A-003: every boot in this session references the state
    -- validator instead of carrying it inline. Idempotent, so it is
    -- established before the first row and found by every later one.
    ensureStateRef env
    runRowIn env row

-- | One row by what runs it: the registry-identity runners, a program, or its own runner.
runRowIn :: Env -> String -> IO ()
runRowIn env row = case (row, programFor row) of
    _ | Just program <- Authentication.programFor row -> case envIdentity env of
        Just world -> runAuthenticationRow env world program
        Nothing -> failWith (row <> " needs a registry-identity session")
    ("fold-against-superseded-root", _) -> runFoldAgainstSupersededRoot env
    ("surplus-fold-actions", _) -> runSurplusFoldActions env
    ("batch", _) -> runBatchHarness env
    (_, Just program) -> runProgram env program
    _ -> failWith ("run cannot execute row: " <> row)
