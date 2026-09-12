{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Main
Description : The seven wrong canonical initializations refused on a real devnet (issue #50)
License     : Apache-2.0

Executes the contract rows @LI02..LI08@ — every wrong way to perform the
canonical initialization — against a real devnet node, one narration
line per row, and verifies each refusal on its reason. Where @LI01@
(issue #47) proved the canonical initialization /can/ be done, these
seven prove it cannot be done /wrongly/: each attempt is well-formed
except for the single substitution under test, the script integrity
hash is re-sealed, and the refusal must come back attributable to that
substitution. A fee, missing-input or malformed-CBOR refusal fails the
run (the #41 discipline, as in #56).

Ledger realisation (offchain\/naming-correspondence.md, #47 entries):
the initialization binds five identities at once — @canonicalSeed@ (the
seed UTxO the transaction consumes), @registry@ (the token minted from
it), @validatorScript@ (the applied state script that mints and
spends), and the @applicationPolicy@ / @representativePolicy@ named by
the frozen partition. The applied state script's mint branch is the
bootstrap enforcement: the redeemer's seed must be an input, the mint
and output 0 must carry exactly one seed-derived token at the script's
own address with an empty root. Substituting an element therefore has
to trip exactly the check that binds it:

  * @LI02@ — the seed input is an alternate UTxO while the redeemer
    still names the canonical seed: phase-2, the seed-is-an-input check
    (model reason @canonical-seed@);

  * @LI03@ — a rival registry from a second seed, internally
    consistent (redeemer names the second seed, mint and output carry
    its token). The frozen bootstrap has no canonical-seed allowlist:
    all its checks pass for a consistent rival. The row's honest
    construction is submitted anyway and what the ledger rules is
    reported as-is; an accepted rival is a finding that the binding
    does not bind against rivals, recorded and summed at the end
    (model reason @canonical-seed@);

  * @LI04@ — the registry identity substituted: the canonical seed is
    spent, the redeemer still names it, but the minted token is named
    by the alternate seed (registry 2's identity): phase-2, the
    exact-quantity check (model reason @registry-authenticity@);

  * @LI05@ — the application policy substituted: the canonical
    initialization exercises no application policy (applicationMint is
    false), so the attempt brings the substituted policy's script into
    the initialization and mints under it; the substituted policy's own
    address discipline refuses (model reason @application-policy@);

  * @LI06@ — the canonical seed again, /after a real LI01/: the
    consumed output cannot be re-spent, so the LEDGER refuses in
    phase 1 naming the consumed input (model reason
    @canonical-seed-consumed@) — recorded exactly as that, not dressed
    up as a validator refusal;

  * @LI07@ — the representative policy substituted: the attempt mints
    a representative under it at initialization; the policy refuses —
    it never moves an asset on its own authority, and no application
    spend rides (model reason @representative-policy@);

  * @LI08@ — the validator script substituted: the initialization is
    performed under a different script identity as mint policy and
    registry address; that script cannot perform the bootstrap and
    refuses (model reason @validator-script@).

After the rows, the canonical state is read back /unchanged/: no
refused attempt left a trace.

Controls (env @LIREFUSALS_CONTROL@): @canonical@ runs the actual
canonical initialization against the armed refusal guard — it
succeeds, and the guard must fail the run (the binding did not bind);
@wrong-reason@ matches every refusal against a marker that cannot
occur, so the reason matcher must fail the run naming what came back.
Both exit 1 by design.

Hermetic run (D-011), from @offchain/@:

> mpfs="$(nix build --quiet --no-link --print-out-paths ../onchain#plutus-blueprint)"
> naming="$(nix build --quiet --no-link --print-out-paths ../naming-onchain#plutus-blueprint)"
> MPFS_BLUEPRINT="$mpfs" NAMING_BLUEPRINT="$naming" nix run --quiet .#li-refusals
-}
module Main (main) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (Async, async, cancel, poll)
import Control.Exception
    ( ErrorCall (..)
    , SomeException
    , displayException
    , throwIO
    , try
    )
import Control.Monad (unless, when)
import Crypto.Hash (Blake2b_256, Digest, hash)
import Data.Aeson (FromJSON (..), eitherDecode', withObject, (.:))
import Data.ByteArray (convert)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as Base16
import Data.ByteString.Lazy qualified as BSL
import Data.ByteString.Short qualified as SBS
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.List (intercalate, isInfixOf, sortBy)
import Data.Map.Strict qualified as Map
import Data.Ord (comparing)
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Sequence.Strict qualified as StrictSeq
import Data.Word (Word32)
import Lens.Micro ((&), (.~), (^.))
import PlutusCore.Data qualified as PLC
import PlutusTx.Builtins.Internal (BuiltinByteString (..))
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..), exitWith)
import System.IO (BufferMode (..), hPutStrLn, hSetBuffering, stderr, stdout)

import Cardano.Crypto.Hash.Class (hashToBytes)
import Cardano.Ledger.Address (Addr (..), serialiseAddr)
import Cardano.Ledger.Alonzo.Scripts (AsIx (..))
import Cardano.Ledger.Api.Scripts.Data (Data (..), Datum (..), binaryDataToData)
import Cardano.Ledger.Api.Tx (bodyTxL, mkBasicTx, txIdTx, witsTxL)
import Cardano.Ledger.Api.Tx.Body (
    collateralInputsTxBodyL,
    feeTxBodyL,
    inputsTxBodyL,
    mintTxBodyL,
    mkBasicTxBody,
    outputsTxBodyL,
    reqSignerHashesTxBodyL,
    scriptIntegrityHashTxBodyL,
 )
import Cardano.Ledger.Api.Tx.In (TxIn (..))
import Cardano.Ledger.Api.Tx.Out (
    TxOut,
    addrTxOutL,
    coinTxOutL,
    datumTxOutL,
    getMinCoinTxOut,
    mkBasicTxOut,
    valueTxOutL,
 )
import Cardano.Ledger.Api.Tx.Wits (
    Redeemers (..),
    rdmrsTxWitsL,
    scriptTxWitsL,
 )
import Cardano.Ledger.BaseTypes (Network (..), TxIx (..))
import Cardano.Ledger.Conway.Scripts (ConwayPlutusPurpose (..))
import Cardano.Ledger.Core (Script, extractHash, hashScript)
import Cardano.Ledger.Credential (Credential (..), StakeReference (..))
import Cardano.Ledger.Hashes (ScriptHash)
import Cardano.Ledger.Mary.Value (MaryValue (..), MultiAsset (..), PolicyID (..))
import Cardano.Ledger.Plutus.ExUnits (ExUnits (..))
import Cardano.Ledger.TxIn (TxId (..))

import Cardano.MPFS.Cage.AssetName (deriveAssetName)
import Cardano.MPFS.Cage.Blueprint (
    applyBytesParam,
    extractCompiledCode,
    loadBlueprint,
 )
import Cardano.MPFS.Cage.Config (CageConfig (..), bootStateFromCfg)
import Cardano.MPFS.Cage.Ledger (
    AssetName (..),
    Coin (..),
    ConwayEra,
    PParams,
    TokenId (..),
 )
import Cardano.MPFS.Cage.Provider qualified as Cage
import Cardano.MPFS.Cage.TxBuilder.Internal (
    addrKeyHashBytes,
    addrWitnessKeyHash,
    cageAddrFromCfg,
    cagePolicyIdFromCfg,
    computeScriptHash,
    computeScriptIntegrity,
    emptyRoot,
    evaluateAndBalance,
    findStateUtxo,
    mkCageScript,
    mkInlineDatum,
    placeholderExUnits,
    scriptFromBytes,
    scriptHashBytes,
    toLedgerData,
    toPlcData,
    txInToRef,
 )
import Cardano.MPFS.Cage.Types (
    CageDatum (..),
    MintRedeemer (..),
    OnChainRoot (..),
    OnChainTxOutRef (..),
 )
import Cardano.Node.Client.E2E.Devnet (withCardanoNode)
import Cardano.Node.Client.E2E.Setup (
    addKeyWitness,
    devnetMagic,
    genesisAddr,
    genesisDir,
    genesisSignKey,
 )
import Cardano.Node.Client.Ledger (ConwayTx)
import Cardano.Node.Client.N2C.Connection (
    newLSQChannel,
    newLTxSChannel,
    runNodeClient,
 )
import Cardano.Node.Client.N2C.Provider (mkN2CProvider)
import Cardano.Node.Client.N2C.Submitter (mkN2CSubmitter)
import Cardano.Node.Client.Provider qualified as N2C
import Cardano.Node.Client.Submitter (SubmitResult (..), Submitter (..))
import Naming.Datum
import Naming.Wire
    ( Address (..)
    , WireData (..)
    , addressBytes
    , canonicalAddress
    , decodeAddress
    , serialiseWireData
    )

-- ---------------------------------------------------------
-- Run modes
-- ---------------------------------------------------------

data Mode
    = -- | the seven rows, then a real LI01, then LI06.
      MainRun
    | -- | the canonical initialization run against the armed refusal
      -- guard: it succeeds, and the guard must fail the run.
      ControlCanonical
    | -- | every refusal matched against a marker that cannot occur:
      -- the matcher must fail the run naming what came back.
      ControlWrongReason
    deriving (Eq, Show)

readMode :: IO Mode
readMode =
    lookupEnv "LIREFUSALS_CONTROL" >>= \case
        Nothing -> pure MainRun
        Just "canonical" -> pure ControlCanonical
        Just "wrong-reason" -> pure ControlWrongReason
        Just other ->
            failWith ("unknown LIREFUSALS_CONTROL value " <> other)

-- | The marker the wrong-reason control matches refusals against: by
-- construction no node reason can contain it, so a matched reason can
-- never close a row and the control must fail.
wrongReasonMarker :: String
wrongReasonMarker =
    "wrong-reason-control marker that no node reason can ever contain"

-- ---------------------------------------------------------
-- Ledger-shape constants (the #56 discipline)
-- ---------------------------------------------------------

-- | Flat fee for hand-balanced refusal transactions: above the
-- devnet's minimum, above the fee the declared max execution units
-- price in (~8.8 ada for two mint purposes) and above the size fee of
-- carrying two script witnesses, so a phase-1 fee refusal can never
-- masquerade as the row's verdict.
flatFee :: Integer
flatFee = 12_000_000

-- | Declared execution units for hand-balanced transactions: the
-- devnet's maxTxExUnits (e2e-test\/genesis\/alonzo-genesis.json).
-- Refusal transactions declare exactly it so an oversized real cost
-- can never reject the tx before its validator refuses.
maxUnits :: ExUnits
maxUnits = ExUnits 3_000_000 200_000_000

-- ---------------------------------------------------------
-- Entry point
-- ---------------------------------------------------------

main :: IO ()
main = do
    hSetBuffering stdout LineBuffering
    hSetBuffering stderr LineBuffering
    mode <- readMode
    case mode of
        MainRun ->
            emit
                "row"
                "issue #50: the seven wrong canonical initializations \
                \refused on a real ledger"
        ControlCanonical ->
            emit
                "control"
                "canonical-attempt control: the actual canonical \
                \initialization run against the armed refusal guard, so it \
                \must succeed and the guard must fail the run"
        ControlWrongReason ->
            emit
                "control"
                "wrong-reason control: refusals matched against a marker \
                \that cannot occur, so the matcher must fail the run naming \
                \what came back"
    mpfsPath <- requireEnv "MPFS_BLUEPRINT"
    namingPath <- requireEnv "NAMING_BLUEPRINT"
    outcome <- try (runMode mode mpfsPath namingPath) :: IO (Either SomeException ())
    case outcome of
        Right () -> do
            putStrLn "exit_status: 0"
            pure ()
        Left e -> do
            hPutStrLn stderr ("li-refusals: FAILED: " <> displayException e)
            hPutStrLn stderr "exit_status: 1"
            exitWith (ExitFailure 1)

-- ---------------------------------------------------------
-- The run
-- ---------------------------------------------------------

runMode :: Mode -> FilePath -> FilePath -> IO ()
runMode mode mpfsPath namingPath = do
    -- The two frozen partitions: the applied state script (the
    -- initialization's bootstrap enforcement, from the MPFS tree) and
    -- the naming application + representative scripts (the policy
    -- identities the binding names, from the naming tree).
    ebp <- loadBlueprint mpfsPath
    mpfsBp <- either failWith pure ebp
    stateBytes <-
        orFail
            (extractCompiledCode "state.state" mpfsBp)
            "state.state compiled code not found in the MPFS blueprint"
    requestBytes <-
        orFail
            (extractCompiledCode "request.request" mpfsBp)
            "request.request compiled code not found in the MPFS blueprint"
    enbp <- loadBlueprint namingPath
    namingBp <- either failWith pure enbp
    appBytes <-
        orFail
            (extractCompiledCode "application.application" namingBp)
            "application.application compiled code not found in the naming blueprint"
    reprBytes <-
        orFail
            (extractCompiledCode "representative.representative.mint" namingBp)
            "representative.representative.mint compiled code not found in the naming blueprint"
    si <- readScriptIdentity =<< identityPathFromEnv
    namingSi <- readNamingIdentity =<< namingIdentityPathFromEnv
    gDir <- genesisDir
    withCardanoNode gDir $ \sock _startMs -> do
        lsqCh <- newLSQChannel 16
        ltxsCh <- newLTxSChannel 16
        nodeThread <- async $ runNodeClient devnetMagic sock lsqCh ltxsCh
        threadDelay 3_000_000
        verifyConnection nodeThread
        let prov = adaptProvider (mkN2CProvider lsqCh)
            submit = mkN2CSubmitter ltxsCh
        _ <- Cage.queryProtocolParams prov
        pp <- Cage.queryProtocolParams prov
        -- Identity: the pinned unapplied state hash must equal the hash
        -- of this run's blueprint code; the applied state script is
        -- derived from it (previousPolicies=[]); the naming application
        -- script has no parameters, so its pinned hash IS its applied
        -- hash; the representative script is applied with the
        -- application policy hash.
        let unappliedHex = hex (scriptHashBytes (computeScriptHash stateBytes))
            appliedBytes = stateBytes
            appliedHash = computeScriptHash appliedBytes
            appliedHex = hex (scriptHashBytes appliedHash)
        checkPinnedUnapplied si "state.state" unappliedHex
        let appHash = computeScriptHash appBytes
            appHex = hex (scriptHashBytes appHash)
            appAddr = Addr Testnet (ScriptHashObj appHash) StakeRefNull
            reprAppliedBytes =
                applyBytesParam (scriptHashBytes appHash) reprBytes
            reprAppliedHash = computeScriptHash reprAppliedBytes
            reprAppliedHex = hex (scriptHashBytes reprAppliedHash)
            reprUnappliedHex = hex (scriptHashBytes (computeScriptHash reprBytes))
        checkPinnedApplication namingSi appHex
        checkPinnedRepresentative namingSi reprUnappliedHex
        emit
            "identity"
            ( "validatorScript=12 applied state script 0x"
                <> appliedHex
                <> " = unapplied 0x"
                <> unappliedHex
                <> " with previousPolicies=[] (the bootstrap mint branch is \
                   \the enforcement the rows meet); applicationPolicy=7 \
                   \naming-application script 0x"
                <> appHex
                <> " (0 parameters: the pinned hash is the applied hash); \
                   \representativePolicy=8 applied 0x"
                <> reprAppliedHex
                <> " = unapplied 0x"
                <> reprUnappliedHex
                <> " with parameter application-policy hash"
            )
        -- World setup: the devnet genesis wallet holds one 30000-ada
        -- UTxO. A designation split turns it into the world the rows
        -- need without ever touching a designated seed again: output 0
        -- is the canonical seed (after the split it is still the
        -- lexically first UTxO of the genesis wallet — the LI01
        -- designation rule), output 1 the alternate seed (401), the
        -- rest fund and collateralise the attempts.
        utxos0 <- Cage.queryUTxOs prov genesisAddr
        (genesisIn, genesisOut) <-
            case sortBy (comparing (outRefSortKey . fst)) utxos0 of
                [g] -> pure g
                _ -> failWith "world: expected exactly one genesis UTxO"
        world <- designateWorld prov submit genesisIn genesisOut
        _ <- waitConfirmation "world designation split"
        utxos1 <- Cage.queryUTxOs prov genesisAddr
        canonicalSeed <- utxoByRef utxos1 (worldCanonicalRef world) "canonical seed"
        altSeed <- utxoByRef utxos1 (worldAltRef world) "alternate seed"
        emit
            "canonical-seed"
            ( "seed identity 400 = outRef "
                <> show (worldCanonicalRef world)
                <> " (lexically first UTxO of the genesis wallet after the \
                   \designation split); seed identity 401 = outRef "
                <> show (worldAltRef world)
                <> " (the lexically second); the canonical registry token \
                   \name is SHA-256 of the canonical seed outRef"
            )
        let cfg =
                CageConfig
                    { cageScriptBytes = appliedBytes
                    , requestScriptBytes = requestBytes
                    , cfgScriptHash = appliedHash
                    , cageSeed = worldCanonicalRef world
                    , defaultProcessTime = 30_000
                    , defaultRetractTime = 30_000
                    , defaultTip = Coin 1_000_000
                    , cfgRepPolicy = SBS.pack (replicate 28 0)
                    , cfgConsumerPin = SBS.pack (replicate 28 0)
                    , network = Testnet
                    }
            scriptAddr = cageAddrFromCfg cfg Testnet
            appliedScript = mkCageScript cfg
            appScript = scriptFromBytes "naming-application" appBytes
            reprAppliedScript = scriptFromBytes "representative" reprAppliedBytes
            canonicalName = deriveAssetName (worldCanonicalRef world)
            altName = deriveAssetName (worldAltRef world)
            ctrlHash = addrKeyHashBytes genesisAddr
        -- The naming checkpoint fixture: the four-field datum the
        -- canonical initialization places on the chain.
        controlAddr <- case decodeAddress (serialiseAddr genesisAddr) of
            Just a | canonicalAddress a -> pure a
            _ ->
                failWith
                    "fixture: the genesis address is not a canonical payment-key address"
        let namingDatum =
                NamingDatum
                    { controlAddress = controlAddr
                    , paymentDestination = NoDestination
                    , nextControlCommitment =
                        nextControlCommitmentOf (addressBytes controlAddr)
                    , retirementQuorum =
                        RetirementQuorum
                            { quorumMembers = [ctrlHash]
                            , quorumThreshold = 1
                            }
                    }
        let env =
                Env
                    { envProv = prov
                    , envSubmit = submit
                    , envPp = pp
                    , envPool = worldPool world
                    , envAppliedScript = appliedScript
                    , envAppliedHash = appliedHash
                    , envAppliedHex = appliedHex
                    , envAppScript = appScript
                    , envAppHash = appHash
                    , envAppHex = appHex
                    , envAppAddr = appAddr
                    , envReprAppliedScript = reprAppliedScript
                    , envReprAppliedHash = reprAppliedHash
                    , envReprAppliedHex = reprAppliedHex
                    , envScriptAddr = scriptAddr
                    , envCfg = cfg
                    , envCtrlHash = ctrlHash
                    , envCanonicalName = canonicalName
                    , envAltName = altName
                    , envNamingDatum = namingDatum
                    }
        case mode of
            ControlCanonical -> runControlCanonical env canonicalSeed
            _ -> runRows mode env canonicalSeed altSeed
        cancel nodeThread

-- | The seven rows in world order: the six fresh-world attempts
-- (canonical seed still unspent — before.consumedSeeds=[]), the real
-- LI01, then LI06 against the genuinely consumed seed, then the
-- no-trace proof.
runRows :: Mode -> Env -> (TxIn, TxOut ConwayEra) -> (TxIn, TxOut ConwayEra) -> IO ()
runRows mode env canonicalSeed altSeed = do
    rowLI02 mode env altSeed
    rowLI03 mode env altSeed
    rowLI04 mode env canonicalSeed altSeed
    rowLI05 mode env canonicalSeed
    rowLI07 mode env canonicalSeed
    rowLI08 mode env canonicalSeed
    li05BoundaryProbe env
    (signedLi01, snapAfterLi01) <- runRealLi01 env canonicalSeed
    rowLI06 env canonicalSeed signedLi01 snapAfterLi01
    finalNoTrace env snapAfterLi01
    emit
        "complete"
        ( "the seven wrong canonical initializations executed on a real \
          \devnet; every refusal attributed to its reason, LI06 after a \
          \real LI01 on the genuinely consumed seed, the canonical state \
          \after the rows unchanged"
        )

-- ---------------------------------------------------------
-- The environment every row builds against
-- ---------------------------------------------------------

data Env = Env
    { envProv :: Cage.Provider IO
    , envSubmit :: Submitter IO
    , envPp :: PParams ConwayEra
    , envPool :: IORef [(TxIn, TxOut ConwayEra)]
    , envAppliedScript :: Script ConwayEra
    , envAppliedHash :: ScriptHash
    , envAppliedHex :: String
    , envAppScript :: Script ConwayEra
    , envAppHash :: ScriptHash
    , envAppHex :: String
    , envAppAddr :: Addr
    , envReprAppliedScript :: Script ConwayEra
    , envReprAppliedHash :: ScriptHash
    , envReprAppliedHex :: String
    , envScriptAddr :: Addr
    , envCfg :: CageConfig
    , envCtrlHash :: ByteString
    , envCanonicalName :: ByteString
    , envAltName :: ByteString
    , envNamingDatum :: NamingDatum
    }


-- ---------------------------------------------------------
-- World designation
-- ---------------------------------------------------------

data World = World
    { worldCanonicalRef :: OnChainTxOutRef
    , worldAltRef :: OnChainTxOutRef
    , worldPool :: IORef [(TxIn, TxOut ConwayEra)]
    }

-- | Split the single genesis UTxO into the designated seeds and the
-- funding pool. Output 0 is the canonical seed; after this
-- transaction it is the lexically first UTxO of the genesis wallet
-- (one txid, lowest index), so the LI01 designation rule names it.
designateWorld ::
    Cage.Provider IO ->
    Submitter IO ->
    TxIn ->
    TxOut ConwayEra ->
    IO World
designateWorld prov submit genesisIn genesisOut = do
    let Coin total = genesisOut ^. coinTxOutL
        nFunders = 16 :: Integer
        funderCoin = 25_000_000
        canonicalCoin = 50_000_000
        altCoin = 2_000_000
        fee = 1_000_000
        outs =
            [ mkBasicTxOut genesisAddr (MaryValue (Coin canonicalCoin) mempty)
            , mkBasicTxOut genesisAddr (MaryValue (Coin altCoin) mempty)
            ]
                <> [ mkBasicTxOut genesisAddr (MaryValue (Coin funderCoin) mempty)
                   | _ <- [1 .. nFunders]
                   ]
        spent = sum [c | o <- outs, let Coin c = o ^. coinTxOutL]
        change = total - spent - fee
        changeOut' = mkBasicTxOut genesisAddr (MaryValue (Coin change) mempty)
        body =
            mkBasicTxBody
                & inputsTxBodyL .~ Set.singleton genesisIn
                & outputsTxBodyL .~ StrictSeq.fromList (outs <> [changeOut'])
                & feeTxBodyL .~ Coin fee
        splitTx = mkBasicTx body
    result <- submitTx submit (addKeyWitness genesisSignKey splitTx)
    case result of
        Submitted _ -> pure ()
        Rejected reason ->
            failWith
                ( "world: the designation split was refused: "
                    <> T.unpack (TE.decodeUtf8Lenient reason)
                )
    threadDelay 5_000_000
    after <- Cage.queryUTxOs prov genesisAddr
    let txid = txIdHex splitTx
        mine =
            sortBy
                (comparing (txInIndex . fst))
                [p | p@(i, _) <- after, txInTxIdHex i == txid, txInIndex i < nFunders + 2]
    unless (toInteger (length mine) == nFunders + 2) $
        failWith
            ( "world: expected "
                <> show (nFunders + 2)
                <> " designated outputs, found "
                <> show (length mine)
            )
    let indexed = [(txInIndex i, p) | p@(i, _) <- mine]
        seed0 = lookup 0 indexed
        seed1 = lookup 1 indexed
        pool = [p | (idx, p) <- indexed, idx >= 2]
    (cIn, _) <- maybe (failWith "world: canonical seed output missing") pure seed0
    (aIn, _) <- maybe (failWith "world: alternate seed output missing") pure seed1
    poolRef <- newIORef pool
    emit
        "world"
        ( "designation split "
            <> txid
            <> ": canonical seed (400) = "
            <> showIn cIn
            <> " (output 0, lexically first after the split); alternate \
               \seed (401) = "
            <> showIn aIn
            <> " (output 1); "
            <> show nFunders
            <> " funding UTxOs of 25 ada behind them"
        )
    pure
        World
            { worldCanonicalRef = txInToRef cIn
            , worldAltRef = txInToRef aIn
            , worldPool = poolRef
            }

-- ---------------------------------------------------------
-- LI02 — the seed substituted
-- ---------------------------------------------------------

-- | The canonical initialization with the seed input substituted: the
-- transaction spends an alternate UTxO while the redeemer still names
-- the canonical seed and the mint still carries the canonical
-- registry token. The applied state script's bootstrap check — the
-- redeemer's seed must be an input — is what binds the canonical
-- seed, and it is exactly what the substitution breaks.
rowLI02 :: Mode -> Env -> (TxIn, TxOut ConwayEra) -> IO ()
rowLI02 mode env altSeed = do
    let canonicalRef = cageSeed (envCfg env)
        mintMA =
            MultiAsset $
                Map.singleton
                    (cagePolicyIdFromCfg (envCfg env))
                    (Map.singleton (AssetName (SBS.toShort (envCanonicalName env))) 1)
        redeemers =
            Redeemers $
                Map.singleton
                    (ConwayMinting (AsIx 0))
                    ( toLedgerData (Minting canonicalRef)
                    , maxUnits
                    )
        scripts =
            Map.singleton (envAppliedHash env) (envAppliedScript env)
        regOut = registryOut env (envScriptAddr env) (cagePolicyIdFromCfg (envCfg env)) (envCanonicalName env)
        cpOut = checkpointOut env (envScriptAddr env)
    tx <-
        buildRefusalTx
            env
            RefusalTx
                { rtxSeed = altSeed
                , rtxMint = mintMA
                , rtxRedeemers = redeemers
                , rtxScripts = scripts
                , rtxOutputs = [regOut, cpOut]
                , rtxChangeTokens = mempty
                , rtxReqSigners = Set.empty
                }
    expectRefused
        mode
        env
        "LI02-alternate-seed-refused"
        "canonical-seed"
        (envAppliedHex env)
        ( "the seed input is the alternate UTxO (seed 401) while the minted \
           \registry identity and the redeemer still name the canonical \
           \seed 400 ("
            <> show canonicalRef
            <> "): the bootstrap check — the redeemer's seed must be an \
               \input — refuses; substituted element: the seed; the \
               \canonical value it should have had: canonical seed 400"
        )
        tx

-- ---------------------------------------------------------
-- LI03 — a rival registry from a second seed
-- ---------------------------------------------------------

 -- A-001 recut: the internally consistent rival — the alternate seed is
-- spent, the redeemer names it, the mint carries its token, output 0 is a
-- valid registry shape for it. The frozen bootstrap has no canonical-seed
-- allowlist, so the LEDGER ACCEPTS it; per the A-001 ruling the row asserts
-- what is true and checkable instead of a refusal that cannot happen: the
-- rival is accepted, its token name differs from the canonical name, and the
-- canonical registry is unaffected (asserted from the chain after LI01).
rowLI03 :: Mode -> Env -> (TxIn, TxOut ConwayEra) -> IO ()
rowLI03 mode env altSeed = case mode of
    ControlWrongReason -> pure () -- the wrong-reason run stops at LI02
    _ -> do
        let altRef = txInToRef (fst altSeed)
            mintMA =
                MultiAsset $
                    Map.singleton
                        (cagePolicyIdFromCfg (envCfg env))
                        (Map.singleton (AssetName (SBS.toShort (envAltName env))) 1)
            redeemers =
                Redeemers $
                    Map.singleton
                        (ConwayMinting (AsIx 0))
                        (toLedgerData (Minting altRef), maxUnits)
            scripts =
                Map.singleton (envAppliedHash env) (envAppliedScript env)
            regOut =
                registryOut
                    env
                    (envScriptAddr env)
                    (cagePolicyIdFromCfg (envCfg env))
                    (envAltName env)
            cpOut = checkpointOut env (envScriptAddr env)
        tx <-
            buildRefusalTx
                env
                RefusalTx
                    { rtxSeed = altSeed
                    , rtxMint = mintMA
                    , rtxRedeemers = redeemers
                    , rtxScripts = scripts
                    , rtxOutputs = [regOut, cpOut]
                    , rtxChangeTokens = mempty
                    , rtxReqSigners = Set.empty
                    }
        let signed = addKeyWitness genesisSignKey tx
        result <- submitTx (envSubmit env) signed
        case result of
            Rejected reason ->
                failWith
                    ( "LI03: the rival was REFUSED ("
                        <> T.unpack (TE.decodeUtf8Lenient reason)
                        <> ") — the A-001 ruling recuts this row to assert the "
                        <> "rival is ACCEPTED; a refusal contradicts the ruled "
                        <> "model and fails the run"
                    )
            Submitted _ -> do
                threadDelay 5_000_000
                -- Read the accepted rival back from the chain and assert
                -- what the ruling requires: it is live at the application
                -- validator, under its own seed-derived name, and that name
                -- differs from the canonical name.
                scriptUtxos <- Cage.queryUTxOs (envProv env) (envScriptAddr env)
                let rivalTokenId = TokenId (AssetName (SBS.toShort (envAltName env)))
                (rivalIn, _) <- case
                    findStateUtxo
                        (cagePolicyIdFromCfg (envCfg env))
                        rivalTokenId
                        scriptUtxos of
                        Just r -> pure r
                        Nothing ->
                            failWith
                                "LI03: the accepted rival registry UTxO is not live at the application validator"
                unless (envAltName env /= envCanonicalName env) $
                    failWith
                        "LI03: the rival name equals the canonical name — derivation broken"
                wallet <- Cage.queryUTxOs (envProv env) genesisAddr
                unless (any ((== cageSeed (envCfg env)) . txInToRef . fst) wallet) $
                    failWith
                        "LI03: the canonical seed is unexpectedly spent before LI01 ran"
                emit
                    "row"
                    ( "LI03: rival ACCEPTED by the ledger, as the A-001 ruling "
                        <> "recuts the row — row LI03-second-seed-rival-registry: "
                        <> "tx="
                        <> txIdHex signed
                        <> " minted the rival registry "
                        <> showIn rivalIn
                        <> " under token 0x"
                        <> hex (envAltName env)
                        <> "; the rival's token name differs from the canonical "
                        <> "name (rival 0x"
                        <> hex (envAltName env)
                        <> " vs canonical 0x"
                        <> hex (envCanonicalName env)
                        <> " — each SHA-256 of its own seed's outRef): name "
                        <> "derivation, not a refusal, is what bounds a rival — "
                        <> "it can never carry the canonical name; the canonical "
                        <> "seed 400 is still unspent; the canonical registry "
                        <> "itself is asserted unaffected from the chain after "
                        <> "the real LI01 below"
                    )

-- ---------------------------------------------------------
-- LI04 — the registry identity substituted
-- ---------------------------------------------------------

-- | The canonical seed is spent and the redeemer still names it, but
-- the minted token — the registry identity — is named by the alternate
-- seed (registry 2's identity), and output 0 carries it. The applied
-- state script's exact-quantity check — the mint under the policy must
-- be exactly the seed-derived token — refuses.
rowLI04 :: Mode -> Env -> (TxIn, TxOut ConwayEra) -> (TxIn, TxOut ConwayEra) -> IO ()
rowLI04 mode env canonicalSeed _altSeed = do
    let canonicalRef = cageSeed (envCfg env)
        mintMA =
            MultiAsset $
                Map.singleton
                    (cagePolicyIdFromCfg (envCfg env))
                    (Map.singleton (AssetName (SBS.toShort (envAltName env))) 1)
        redeemers =
            Redeemers $
                Map.singleton
                    (ConwayMinting (AsIx 0))
                    (toLedgerData (Minting canonicalRef), maxUnits)
        scripts =
            Map.singleton (envAppliedHash env) (envAppliedScript env)
        regOut =
            registryOut
                env
                (envScriptAddr env)
                (cagePolicyIdFromCfg (envCfg env))
                (envAltName env)
        cpOut = checkpointOut env (envScriptAddr env)
    tx <-
        buildRefusalTx
            env
            RefusalTx
                { rtxSeed = canonicalSeed
                , rtxMint = mintMA
                , rtxRedeemers = redeemers
                , rtxScripts = scripts
                , rtxOutputs = [regOut, cpOut]
                , rtxChangeTokens = mempty
                , rtxReqSigners = Set.empty
                }
    expectRefused
        mode
        env
        "LI04-substituted-registry-refused"
        "registry-authenticity"
        (envAppliedHex env)
        ( "the canonical seed is spent and the redeemer names it, but the \
           \minted registry token is named by the alternate seed (registry "
            <> "2's identity, 0x"
            <> hex (envAltName env)
            <> ") instead of the canonical registry token 0x"
            <> hex (envCanonicalName env)
            <> " (SHA-256 of the canonical seed's outRef): the bootstrap "
            <> "exact-quantity check refuses; substituted element: the "
            <> "registry; the canonical value it should have had: registry 1, "
            <> "the token named by canonical seed 400"
        )
        tx

-- ---------------------------------------------------------
-- LI05 — the application policy substituted
-- ---------------------------------------------------------

-- | The canonical initialization exercises no application policy
-- (applicationMint is false), so the substitution manifests by bringing
-- the substituted policy's script into the initialization and minting
-- under it: the attempt mints a token named by the canonical registry
-- identity (what a confounded initializer would do — reuse the
-- registry's name) under the naming application policy. That policy's
-- own address discipline — the mint's asset name must be a canonical
-- address — refuses, naming the substituted policy.
rowLI05 :: Mode -> Env -> (TxIn, TxOut ConwayEra) -> IO ()
rowLI05 mode env canonicalSeed = do
    let canonicalRef = cageSeed (envCfg env)
        appPolicy = PolicyID (envAppHash env)
        bootstrapMA =
            MultiAsset $
                Map.singleton
                    (cagePolicyIdFromCfg (envCfg env))
                    (Map.singleton (AssetName (SBS.toShort (envCanonicalName env))) 1)
        substitutedMA =
            MultiAsset $
                Map.singleton
                    appPolicy
                    (Map.singleton (AssetName (SBS.toShort (envCanonicalName env))) 1)
        mintMA = bootstrapMA <> substitutedMA
        idx = mintIndexOf mintMA appPolicy
        redeemers =
            Redeemers $
                Map.fromList
                    [
                        ( ConwayMinting (AsIx (mintIndexOf mintMA (cagePolicyIdFromCfg (envCfg env))))
                        , (toLedgerData (Minting canonicalRef), maxUnits)
                        )
                    ,
                        ( ConwayMinting (AsIx idx)
                        , ( Data (withdrawApprovalRedeemer (envCtrlHash env) (envCanonicalName env))
                          , maxUnits
                          )
                        )
                    ]
        scripts =
            Map.fromList
                [
                    (envAppliedHash env, envAppliedScript env)
                ,
                    (envAppHash env, envAppScript env)
                ]
        regOut = registryOut env (envScriptAddr env) (cagePolicyIdFromCfg (envCfg env)) (envCanonicalName env)
        cpOut = checkpointOut env (envScriptAddr env)
    tx <-
        buildRefusalTx
            env
            RefusalTx
                { rtxSeed = canonicalSeed
                , rtxMint = mintMA
                , rtxRedeemers = redeemers
                , rtxScripts = scripts
                , rtxOutputs = [regOut, cpOut]
                , rtxChangeTokens = substitutedMA
                , rtxReqSigners = Set.empty
                }
    expectRefused
        mode
        env
        "LI05-substituted-policy-refused"
        "application-policy"
        (envAppHex env)
        ( "the canonical initialization exercises no application policy "
            <> "(applicationMint is false); the attempt brings the substituted "
            <> "application policy 9 (the naming-application script 0x"
            <> envAppHex env
            <> ") into the initialization and mints a token named by the "
            <> "canonical registry identity 0x"
            <> hex (envCanonicalName env)
            <> " under it: the substituted policy's own address discipline "
            <> "(the mint's asset name must be a canonical address) refuses; "
            <> "substituted element: the applicationPolicy; the canonical "
            <> "value it should have had: applicationPolicy 7, which mints "
            <> "nothing at initialization"
        )
        tx

-- | The boundary of LI05's refusal, recorded as evidence: the same
-- substituted policy mint, made well-formed for THAT policy (asset
-- name = a canonical address, the controller signing). It is funded
-- from the pool (never a designated seed, never the canonical seed)
-- and never fails the run — whatever the ledger rules here is the
-- boundary evidence of what LI05's refusal does and does not bind.
li05BoundaryProbe :: Env -> IO ()
li05BoundaryProbe env = do
    ((probeIn, probeOut), _) <- takeFundCollateral env
    let appPolicy = PolicyID (envAppHash env)
        destBytes = serialiseAddr genesisAddr
        mintMA =
            MultiAsset $
                Map.singleton
                    appPolicy
                    (Map.singleton (AssetName (SBS.toShort destBytes)) 1)
        idx = mintIndexOf mintMA appPolicy
        redeemers =
            Redeemers $
                Map.singleton
                    (ConwayMinting (AsIx idx))
                    (Data (withdrawApprovalRedeemer (envCtrlHash env) destBytes), maxUnits)
        scripts = Map.singleton (envAppHash env) (envAppScript env)
    tx <-
        buildRefusalTx
            env
            RefusalTx
                { rtxSeed = (probeIn, probeOut)
                , rtxMint = mintMA
                , rtxRedeemers = redeemers
                , rtxScripts = scripts
                , rtxOutputs = []
                , rtxChangeTokens = mintMA
                , rtxReqSigners = Set.singleton (envCtrlHash env)
                }
    let signed = addKeyWitness genesisSignKey tx
    result <- submitTx (envSubmit env) signed
    case result of
        Submitted _ ->
            emit
                "li05-boundary"
                ( "the well-formed mint under the substituted application policy "
                    <> "was ACCEPTED (tx="
                    <> txIdHex signed
                    <> "): a withdraw-approval-shaped asset named by a canonical "
                    <> "address, controller-signed, passes the policy's own "
                    <> "discipline — LI05's refusal is the substituted policy's "
                    <> "own rule, not the initialization binding refusing a wrong "
                    <> "applicationPolicy; the canonical seed was not spent"
                )
        Rejected reason ->
            emit
                "li05-boundary"
                ( "the well-formed mint under the substituted application policy "
                    <> "was refused: "
                    <> T.unpack (TE.decodeUtf8Lenient reason)
                    <> " — the boundary is narrower than the source suggests"
                )

-- ---------------------------------------------------------
-- LI07 — the representative policy substituted
-- ---------------------------------------------------------

-- | The canonical initialization mints no representative
-- (representativeMint is false). The attempt brings the substituted
-- representative policy's applied script into the initialization and
-- mints a representative under it. The policy never moves an asset on
-- its own authority — a mint must ride an application-spend with a
-- Fold redeemer naming it — and no application spend can ride an
-- initialization, so the substituted policy refuses, naming itself.
rowLI07 :: Mode -> Env -> (TxIn, TxOut ConwayEra) -> IO ()
rowLI07 mode env canonicalSeed = do
    let canonicalRef = cageSeed (envCfg env)
        reprPolicy = PolicyID (envReprAppliedHash env)
        reprName = "t50-li07-representative-probe-01"
        bootstrapMA =
            MultiAsset $
                Map.singleton
                    (cagePolicyIdFromCfg (envCfg env))
                    (Map.singleton (AssetName (SBS.toShort (envCanonicalName env))) 1)
        substitutedMA =
            MultiAsset $
                Map.singleton
                    reprPolicy
                    (Map.singleton (AssetName (SBS.toShort reprName)) 1)
        mintMA = bootstrapMA <> substitutedMA
        idx = mintIndexOf mintMA reprPolicy
        redeemers =
            Redeemers $
                Map.fromList
                    [
                        ( ConwayMinting (AsIx (mintIndexOf mintMA (cagePolicyIdFromCfg (envCfg env))))
                        , (toLedgerData (Minting canonicalRef), maxUnits)
                        )
                    ,
                        ( ConwayMinting (AsIx idx)
                        , (Data (PLC.Constr 0 []), maxUnits) -- MintRepresentative
                        )
                    ]
        scripts =
            Map.fromList
                [
                    (envAppliedHash env, envAppliedScript env)
                ,
                    (envReprAppliedHash env, envReprAppliedScript env)
                ]
        regOut = registryOut env (envScriptAddr env) (cagePolicyIdFromCfg (envCfg env)) (envCanonicalName env)
        cpOut = checkpointOut env (envScriptAddr env)
    tx <-
        buildRefusalTx
            env
            RefusalTx
                { rtxSeed = canonicalSeed
                , rtxMint = mintMA
                , rtxRedeemers = redeemers
                , rtxScripts = scripts
                , rtxOutputs = [regOut, cpOut]
                , rtxChangeTokens = substitutedMA
                , rtxReqSigners = Set.empty
                }
    expectRefused
        mode
        env
        "LI07-substituted-representative-policy-refused"
        "representative-policy"
        (envReprAppliedHex env)
        ( "the canonical initialization mints no representative "
            <> "(representativeMint is false); the attempt brings the substituted "
            <> "representative policy 9 (applied 0x"
            <> envReprAppliedHex env
            <> ") into the initialization and mints a representative under it: "
            <> "the policy never moves an asset on its own authority — the mint "
            <> "must ride an application spend with a Fold redeemer naming it — "
            <> "and no application spend can ride an initialization, so the "
            <> "substituted policy refuses; substituted element: the "
            <> "representativePolicy; the canonical value it should have had: "
            <> "representativePolicy 8, which mints nothing at initialization"
        )
        tx

-- ---------------------------------------------------------
-- LI08 — the validator script substituted
-- ---------------------------------------------------------

-- | The initialization performed under a substituted validator script:
-- everything else stays canonical (canonical seed input, canonical
-- registry token name, bootstrap-shaped registry output), but the mint
-- policy, script witness and registry address all name the substituted
-- script (the naming-application script, 0 parameters, applied hash =
-- pinned hash). That script cannot perform the bootstrap — its mint
-- branch demands an address-shaped asset name — and refuses, proving
-- the initialization is bound to validatorScript 12 because only it
-- can execute the bootstrap.
rowLI08 :: Mode -> Env -> (TxIn, TxOut ConwayEra) -> IO ()
rowLI08 mode env canonicalSeed = do
    let appPolicy = PolicyID (envAppHash env)
        mintMA =
            MultiAsset $
                Map.singleton
                    appPolicy
                    (Map.singleton (AssetName (SBS.toShort (envCanonicalName env))) 1)
        redeemers =
            Redeemers $
                Map.singleton
                    (ConwayMinting (AsIx 0))
                    ( Data (withdrawApprovalRedeemer (envCtrlHash env) (envCanonicalName env))
                    , maxUnits
                    )
        scripts = Map.singleton (envAppHash env) (envAppScript env)
        regOut = registryOut env (envAppAddr env) appPolicy (envCanonicalName env)
        cpOut = checkpointOut env (envAppAddr env)
    tx <-
        buildRefusalTx
            env
            RefusalTx
                { rtxSeed = canonicalSeed
                , rtxMint = mintMA
                , rtxRedeemers = redeemers
                , rtxScripts = scripts
                , rtxOutputs = [regOut, cpOut]
                , rtxChangeTokens = mempty
                , rtxReqSigners = Set.empty
                }
    expectRefused
        mode
        env
        "LI08-substituted-validator-script-refused"
        "validator-script"
        (envAppHex env)
        ( "the initialization is performed under a substituted validator "
            <> "script (validatorScript 13 realized as the naming-application "
            <> "script 0x"
            <> envAppHex env
            <> "): the mint policy, the script witness and the registry address "
            <> "all name it, the canonical seed is spent and the registry token "
            <> "name stays canonical — but the substituted script cannot perform "
            <> "the bootstrap and refuses; substituted element: the "
            <> "validatorScript; the canonical value it should have had: the "
            <> "applied state script 0x"
            <> envAppliedHex env
        )
        tx

-- ---------------------------------------------------------
-- The real LI01 (the grounding initialization)
-- ---------------------------------------------------------

-- | A live canonical object, snapshotted for the no-trace proof.
data CanonicalSnap = CanonicalSnap
    { csRegistryIn :: TxIn
    , csRegistryValue :: MaryValue
    , csRegistryDatum :: Datum ConwayEra
    , csRegistryAddr :: Addr
    , csCheckpointIn :: TxIn
    , csCheckpointValue :: MaryValue
    , csCheckpointDatum :: Datum ConwayEra
    }

-- | Execute the real canonical initialization (LI01's transaction and
-- verifications, from issue #47): consume the canonical seed, mint the
-- registry identity token, create the registry and checkpoint outputs,
-- and verify the witness shape, the seed consumption and the checkpoint
-- datum from the chain. Returns the signed transaction (LI06 replays
-- those exact bytes) and the snapshot the no-trace proof compares
-- against.
runRealLi01 ::
    Env ->
    (TxIn, TxOut ConwayEra) ->
    IO (ConwayTx, CanonicalSnap)
runRealLi01 env canonicalSeed = do
    emit
        "li01"
        ( "executing the real LI01-canonical-initialization-accepts against "
            <> "the canonical seed "
            <> show (cageSeed (envCfg env))
            <> " — the consumed-seed state that LI06's refusal must come from"
        )
    unsigned <-
        buildCanonicalTx
            (envCfg env)
            (envPp env)
            (envProv env)
            canonicalSeed
            []
            (envNamingDatum env)
    let signed = addKeyWitness genesisSignKey unsigned
    result <- submitTx (envSubmit env) signed
    case result of
        Submitted _ -> pure ()
        Rejected reason ->
            failWith
                ( "li01: the node refused the canonical initialization: "
                    <> T.unpack (TE.decodeUtf8Lenient reason)
                )
    let txid = txIdHex signed
    -- The script witness must be exactly the derived applied state
    -- script: the identity the row binds is what ran.
    let witnessHashes =
            Set.fromList
                [ hex (scriptHashBytes sh)
                | sh <- Map.keys (signed ^. witsTxL . scriptTxWitsL)
                ]
    unless (witnessHashes == Set.singleton (envAppliedHex env)) $
        failWith $
            "li01: expected the tx witness to carry exactly the applied hash 0x"
                <> envAppliedHex env
                <> " but it held "
                <> show (Set.toList witnessHashes)
    threadDelay 5_000_000
    -- The mint is exactly the bootstrap asset.
    let MultiAsset mintMap = signed ^. bodyTxL . mintTxBodyL
        expectedMint =
            Map.singleton
                (cagePolicyIdFromCfg (envCfg env))
                (Map.singleton (AssetName (SBS.toShort (envCanonicalName env))) 1)
    unless (mintMap == expectedMint) $
        failWith "li01: the mint is not exactly the bootstrap asset"
    -- Seed consumed, observed from the chain.
    walletAfter <- Cage.queryUTxOs (envProv env) genesisAddr
    let seedStillThere =
            any (\(i, _) -> txInToRef i == cageSeed (envCfg env)) walletAfter
    when seedStillThere $
        failWith
            ( "li01: the canonical seed "
                <> show (cageSeed (envCfg env))
                <> " is still unspent after the initialization tx "
                <> txid
            )
    -- Read the registry and checkpoint outputs back from the chain:
    -- both must be outputs of the LI01 transaction itself, so a rival
    -- registry left on the ledger by LI03's acceptance can never be
    -- mistaken for the canonical objects.
    scriptUtxos <- Cage.queryUTxOs (envProv env) (envScriptAddr env)
    let tokenId = TokenId (AssetName (SBS.toShort (envCanonicalName env)))
        li01Utxos = filter ((== txid) . txInTxIdHex . fst) scriptUtxos
    (regIn, regOut) <- case
        findStateUtxo (cagePolicyIdFromCfg (envCfg env)) tokenId li01Utxos of
            Just r -> pure r
            Nothing -> failWith "li01: no registry UTxO from the LI01 tx is live at the application validator"
    (cpIn, cpOut) <- case
        [ p
        | p@(i, _) <- li01Utxos
        , i /= regIn
        , isNamingDatum (snd p)
        ] of
            [c] -> pure c
            _ -> failWith "li01: expected exactly one checkpoint output from the LI01 tx"
    -- The checkpoint datum decodes with the merged codec and its bytes
    -- are the contract codec's encoding of the fixture.
    decoded <- case datumDataOf cpOut >>= wireOf >>= decodeNamingDatum of
        Just nd -> pure nd
        Nothing -> failWith "li01: the checkpoint datum does not decode as a naming datum"
    let expected = envNamingDatum env
        diffs = datumDiffs expected decoded
    unless (null diffs) $ failWith ("li01: checkpoint mismatch: " <> intercalate "; " diffs)
    let chainBytes = datumDataOf cpOut >>= wireOf >>= serialiseWireData
        codecBytes = serialiseNamingDatum expected
    unless (chainBytes == codecBytes) $
        failWith "li01: the on-chain checkpoint bytes are not the codec's encoding"
    emit
        "li01-accepted"
        ( "LI01-canonical-initialization-accepts executed: tx="
            <> txid
            <> " registry="
            <> showIn regIn
            <> " (token 0x"
            <> hex (envCanonicalName env)
            <> " = SHA-256 of the canonical seed's outRef, quantity 1); "
            <> "checkpoint="
            <> showIn cpIn
            <> " (four-field datum, byte-exact); the canonical seed is consumed "
            <> "— consumedSeeds=[400] — and the state LI06 replays against is "
            <> "the chain's own"
        )
    -- The LI03 rival (accepted per the A-001 ruling) must not have
    -- touched the canonical registry: it is a different UTxO under a
    -- different name, both read back from the chain.
    let rivalTokenId = TokenId (AssetName (SBS.toShort (envAltName env)))
    (rivalIn, _) <- case
        findStateUtxo (cagePolicyIdFromCfg (envCfg env)) rivalTokenId scriptUtxos of
            Just r -> pure r
            Nothing ->
                failWith
                    "li03-canonical: the rival registry is no longer live at the application validator"
    unless (rivalIn /= regIn) $
        failWith "li03-canonical: the rival UTxO is the canonical registry — name collision"
    emit
        "li03-canonical"
        ( "the canonical registry is unaffected by the accepted rival: still "
            <> "live at "
            <> showIn regIn
            <> ", same name 0x"
            <> hex (envCanonicalName env)
            <> ", same datum bytes; the rival persists at "
            <> showIn rivalIn
            <> " under its own name 0x"
            <> hex (envAltName env)
            <> " — distinct UTxO, distinct name; the canonical name is derived "
            <> "from the canonical seed, which LI06 proves can only be consumed once"
        )
    pure
        (
            signed
        ,
            CanonicalSnap
            { csRegistryIn = regIn
            , csRegistryValue = regOut ^. valueTxOutL
            , csRegistryDatum = regOut ^. datumTxOutL
            , csRegistryAddr = regOut ^. addrTxOutL
            , csCheckpointIn = cpIn
            , csCheckpointValue = cpOut ^. valueTxOutL
            , csCheckpointDatum = cpOut ^. datumTxOutL
            }
        )

-- ---------------------------------------------------------
-- LI06 — the canonical seed again, after a real LI01
-- ---------------------------------------------------------

-- | Replaying LI01's EXACT signed transaction: a consumed UTxO cannot
-- be re-spent, so the LEDGER refuses in phase 1, naming the consumed
-- input — the strongest form of the guarantee and recorded exactly as
-- that, not dressed up as a validator refusal (the LC06 precedent).
rowLI06 :: Env -> (TxIn, TxOut ConwayEra) -> ConwayTx -> CanonicalSnap -> IO ()
rowLI06 env canonicalSeed signedLi01 _snap = do
    -- The consumed-seed state is the chain's own: the canonical seed is
    -- gone from the unspent set because a real LI01 consumed it.
    wallet <- Cage.queryUTxOs (envProv env) genesisAddr
    unless (not (any ((== fst canonicalSeed) . fst) wallet)) $
        failWith "LI06: the canonical seed is unexpectedly still live"
    emit
        "li06-build"
        ( "LI06-repeated-canonical-seed-refused: replaying LI01's exact "
            <> "signed transaction tx="
            <> txIdHex signedLi01
            <> " (same bootstrap mint, same registry and checkpoint outputs, "
            <> "redeemer names the canonical seed "
            <> show (cageSeed (envCfg env))
            <> ") after a real LI01 — the canonical seed 400 is already "
            <> "consumed (before.consumedSeeds=[400] is the chain's own state)"
        )
    result <- submitTx (envSubmit env) signedLi01
    case result of
        Submitted _ ->
            failWith
                ( "LI06: the replay was ACCEPTED — a consumed canonical seed "
                    <> "initialized the registry twice (model reason "
                    <> "canonical-seed-consumed)"
                )
        Rejected reason -> do
            let reasonText = T.unpack (TE.decodeUtf8Lenient reason)
                consumed =
                    "All inputs are spent" `isInfixOf` reasonText
                        || "BadInputs" `isInfixOf` reasonText
                        || "already spent" `isInfixOf` reasonText
                        || "inputs are spent" `isInfixOf` reasonText
            unless consumed $
                failWith
                    ( "LI06: reason mismatch — expected the ledger to refuse the "
                        <> "replay in phase 1 naming the consumed output "
                        <> show (cageSeed (envCfg env))
                        <> " but the node said <"
                        <> reasonText
                        <> ">"
                    )
            emit
                "row"
                ( "LI06: REFUSED, reason matched — row LI06-repeated-canonical-seed-refused"
                    <> " (model reason canonical-seed-consumed; LEDGER-level "
                    <> "phase-1 refusal, no validator involved): "
                    <> reasonText
                    <> " — after a real LI01 the canonical seed 400 ("
                    <> show (cageSeed (envCfg env))
                    <> ") is already consumed; a consumed UTxO cannot be "
                    <> "re-spent, so the replay never reaches the validator; "
                    <> "recorded exactly as the ledger-level refusal it is"
                )

-- ---------------------------------------------------------
-- The no-trace proof
-- ---------------------------------------------------------

-- | After the seven rows the canonical state is read back unchanged:
-- the registry and checkpoint outputs the real LI01 created hold the
-- same value, address and datum bytes, and the canonical seed is still
-- absent from the unspent set. A rejected evaluation never applies, so
-- the refused transactions left no trace.
finalNoTrace :: Env -> CanonicalSnap -> IO ()
finalNoTrace env snap = do
    scriptUtxos <- Cage.queryUTxOs (envProv env) (envScriptAddr env)
    reg <- case filter ((== csRegistryIn snap) . fst) scriptUtxos of
        [p] -> pure p
        _ -> failWith "no-trace: the registry UTxO is no longer live at the application validator"
    cp <- case filter ((== csCheckpointIn snap) . fst) scriptUtxos of
        [p] -> pure p
        _ -> failWith "no-trace: the checkpoint output is no longer live at the application validator"
    let (_, regOut) = reg
        (_, cpOut) = cp
        regOK =
            regOut ^. valueTxOutL == csRegistryValue snap
                && regOut ^. datumTxOutL == csRegistryDatum snap
                && regOut ^. addrTxOutL == csRegistryAddr snap
        cpOK =
            cpOut ^. valueTxOutL == csCheckpointValue snap
                && cpOut ^. datumTxOutL == csCheckpointDatum snap
    unless regOK $ failWith "no-trace: the registry UTxO changed after the rows"
    unless cpOK $ failWith "no-trace: the checkpoint output changed after the rows"
    wallet <- Cage.queryUTxOs (envProv env) genesisAddr
    unless (not (any ((== cageSeed (envCfg env)) . txInToRef . fst) wallet)) $
        failWith "no-trace: the canonical seed is unexpectedly unspent again"
    emit
        "no-trace"
        ( "state unchanged after the seven rows — no trace: registry "
            <> showIn (csRegistryIn snap)
            <> " (value and datum bytes unchanged), checkpoint "
            <> showIn (csCheckpointIn snap)
            <> " (value and datum bytes unchanged), canonical seed 400 still "
            <> "consumed nowhere re-appearing; the refused transactions left "
            <> "the canonical state exactly as the real LI01 created it"
        )

-- ---------------------------------------------------------
-- The canonical-attempt control
-- ---------------------------------------------------------

-- | The canonical initialization run against the armed refusal guard:
-- it is actually canonical, so it succeeds — and the run must fail,
-- because a guard that accepts a canonical attempt is a binding that
-- does not bind.
runControlCanonical :: Env -> (TxIn, TxOut ConwayEra) -> IO ()
runControlCanonical env canonicalSeed = do
    unsigned <-
        buildCanonicalTx
            (envCfg env)
            (envPp env)
            (envProv env)
            canonicalSeed
            []
            (envNamingDatum env)
    let signed = addKeyWitness genesisSignKey unsigned
    result <- submitTx (envSubmit env) signed
    case result of
        Submitted _ ->
            failWith
                ( "CONTROL canonical-attempt: the canonical initialization "
                    <> "SUCCEEDED (tx="
                    <> txIdHex signed
                    <> ") while the refusal guard expected a rejection — the "
                    <> "binding did not bind; this run fails as the control "
                    <> "requires"
                )
        Rejected reason ->
            failWith
                ( "CONTROL canonical-attempt: the canonical transaction was "
                    <> "unexpectedly refused: "
                    <> T.unpack (TE.decodeUtf8Lenient reason)
                )

-- ---------------------------------------------------------
-- Transaction builders
-- ---------------------------------------------------------

-- | A hand-balanced refusal transaction (the #56 discipline): seed
-- input plus one pooled funder and collateral, flat fee, declared max
-- execution units, integrity sealed over the redeemers, change back to
-- the genesis wallet.
data RefusalTx = RefusalTx
    { rtxSeed :: (TxIn, TxOut ConwayEra)
    , rtxMint :: MultiAsset
    , rtxRedeemers :: Redeemers ConwayEra
    , rtxScripts :: Map.Map ScriptHash (Script ConwayEra)
    , rtxOutputs :: [TxOut ConwayEra]
    , -- | tokens the change output must carry (the phase-1 value
      -- conservation demands the minted assets ride an output)
      rtxChangeTokens :: MultiAsset
    , -- | key hashes the body demands as required signers (the Plutus
      -- @extra_signatories@ come from here, not from the witness set)
      rtxReqSigners :: Set.Set ByteString
    }

buildRefusalTx :: Env -> RefusalTx -> IO ConwayTx
buildRefusalTx env spec = do
    (fund, collateral) <- takeFundCollateral env
    let seed = [rtxSeed spec]
        allInputs = seed ++ [fund]
        inputsSet = Set.fromList (map fst allInputs)
        integrity = computeScriptIntegrity (envPp env) (rtxRedeemers spec)
        inCoin = sum [c | (_, o) <- allInputs, let Coin c = o ^. coinTxOutL]
        spent = sum [c | o <- rtxOutputs spec, let Coin c = o ^. coinTxOutL]
        change = inCoin - flatFee - spent
        changeOut' :: TxOut ConwayEra
        changeOut' =
            if change <= 1_000_000
                then error "li-refusals: change underflow while balancing"
                else
                    mkBasicTxOut
                        genesisAddr
                        (MaryValue (Coin change) (rtxChangeTokens spec))
        body =
            mkBasicTxBody
                & inputsTxBodyL .~ inputsSet
                & outputsTxBodyL
                    .~ StrictSeq.fromList (rtxOutputs spec ++ [changeOut'])
                & feeTxBodyL .~ Coin flatFee
                & collateralInputsTxBodyL
                    .~ Set.singleton (fst collateral)
                & reqSignerHashesTxBodyL
                    .~ Set.map addrWitnessKeyHash (rtxReqSigners spec)
                & mintTxBodyL .~ rtxMint spec
                & scriptIntegrityHashTxBodyL .~ integrity
    pure $
        mkBasicTx body
            & witsTxL . scriptTxWitsL .~ rtxScripts spec
            & witsTxL . rdmrsTxWitsL .~ rtxRedeemers spec

-- | The bootstrap-shaped registry output: at @addr@, carrying exactly
-- one token under @policy@ named @name@, inline StateDatum with the
-- empty root — the shape the applied state script's mint branch
-- prescribes for output 0.
registryOut :: Env -> Addr -> PolicyID -> ByteString -> TxOut ConwayEra
registryOut env addr policy name =
    let mintMA =
            MultiAsset $
                Map.singleton policy (Map.singleton (AssetName (SBS.toShort name)) 1)
        stateDatum = StateDatum (bootStateFromCfg (envCfg env) (OnChainRoot emptyRoot))
     in mkBasicTxOut addr (MaryValue (Coin 2_000_000) mintMA)
            & datumTxOutL .~ mkInlineDatum (toPlcData stateDatum)

-- | The naming checkpoint output: min-ADA plus margin, the four-field
-- naming datum inline.
checkpointOut :: Env -> Addr -> TxOut ConwayEra
checkpointOut env addr =
    let probe :: TxOut ConwayEra
        probe =
            mkBasicTxOut addr (MaryValue (Coin 0) mempty)
                & datumTxOutL
                    .~ mkInlineDatum (namingDatumToData (envNamingDatum env))
        Coin c = getMinCoinTxOut (envPp env) probe
     in probe & coinTxOutL .~ Coin (c + 1_000_000)

-- | The Conway mint-purpose index of @pid@: the ledger orders mint
-- purposes by the mint map's policy-id order.
mintIndexOf :: MultiAsset -> PolicyID -> Word32
mintIndexOf (MultiAsset ma) pid =
  fromIntegral (length [p | p <- Map.keys ma, p < pid])

-- | Mint redeemer @WithdrawApproval { controller, destination }@ —
-- the naming application policy's mint branch.
withdrawApprovalRedeemer :: ByteString -> ByteString -> PLC.Data
withdrawApprovalRedeemer controller destination =
    PLC.Constr 0 [PLC.B controller, PLC.B destination]

-- ---------------------------------------------------------
-- Refusal attribution (the #41 discipline)
-- ---------------------------------------------------------

-- | Submit @tx@ and require the node to refuse it in phase 2 naming
-- @marker@. In wrong-reason control mode the marker is the impossible
-- one, so the matcher fails naming what came back. In main mode an
-- ACCEPTED attempt fails the run — a refusal the guard cannot produce
-- is a binding that does not bind.
expectRefused ::
    Mode ->
    Env ->
    String ->
    String ->
    String ->
    String ->
    ConwayTx ->
    IO ()
expectRefused mode env rowName modelReason marker guard tx = do
    let signed = addKeyWitness genesisSignKey tx
        wrongReasonMode = mode == ControlWrongReason
        expectedMarker
            | wrongReasonMode = wrongReasonMarker
            | otherwise = marker
    result <- submitTx (envSubmit env) signed
    case result of
        Submitted _ ->
            failWith
                ( rowName
                    <> ": transaction was ACCEPTED — the guard did not hold: "
                    <> guard
                )
        Rejected reason -> do
            let reasonText = T.unpack (TE.decodeUtf8Lenient reason)
                phase2 = "PlutusFailure" `isInfixOf` reasonText
            unless (phase2 || wrongReasonMode) $
                failWith
                    ( rowName
                        <> ": expected-rejection-reason <phase-2 PlutusFailure> but the "
                        <> "node rejected with <"
                        <> reasonText
                        <> "> — a phase-1 refusal proves nothing about the binding"
                    )
            unless (expectedMarker `isInfixOf` reasonText) $
                failWith
                    ( rowName
                        <> ": reason mismatch — expected the refusal to name <"
                        <> expectedMarker
                        <> "> but the node said <"
                        <> reasonText
                        <> ">"
                    )
            emit
                "row"
                ( shortId rowName
                    <> ": REFUSED, reason matched — row "
                    <> rowName
                    <> " (model reason "
                    <> modelReason
                    <> "; phase-2 PlutusFailure naming 0x"
                    <> marker
                    <> "): "
                    <> reasonText
                    <> " — "
                    <> guard
                )

-- | The row id up to the first dash ("LI02-alternate-seed-refused" →
-- "LI02") so the receipt line leads with the row number itself.
shortId :: String -> String
shortId = takeWhile (/= '-')

-- ---------------------------------------------------------
-- The canonical initialization transaction (LI01's builder)
-- ---------------------------------------------------------

-- | Build the canonical initialization transaction exactly as issue
-- #47's runner does: consume the canonical seed, mint exactly one
-- registry identity token named by the seed, create the
-- validator-prescribed registry state UTxO plus the naming checkpoint
-- output. Evaluation and fee balancing come from the same library
-- path, so the accepted row and the LI06 replay are the #47 shape.
buildCanonicalTx ::
    CageConfig ->
    PParams ConwayEra ->
    Cage.Provider IO ->
    (TxIn, TxOut ConwayEra) ->
    [(TxIn, TxOut ConwayEra)] ->
    NamingDatum ->
    IO ConwayTx
buildCanonicalTx cfg pp prov seedUtxo funders namingDatum = do
    let scriptAddr = cageAddrFromCfg cfg Testnet
        mintMA =
            MultiAsset $
                Map.singleton
                    (cagePolicyIdFromCfg cfg)
                    (Map.singleton (AssetName (SBS.toShort seedName)) 1)
        stateDatum = StateDatum (bootStateFromCfg cfg (OnChainRoot emptyRoot))
        stateOut =
            mkBasicTxOut
                scriptAddr
                (MaryValue (Coin 2_000_000) mintMA)
                & datumTxOutL
                    .~ mkInlineDatum (toPlcData stateDatum)
        checkpointData = namingDatumToData namingDatum
        probeOut =
            mkBasicTxOut
                scriptAddr
                (MaryValue (Coin 0) mempty)
                & datumTxOutL .~ mkInlineDatum checkpointData
        checkpointOut' =
            probeOut
                & coinTxOutL
                    .~ Coin
                        ( let Coin c = getMinCoinTxOut pp probeOut
                           in c + 1_000_000
                        )
        script = mkCageScript cfg
        scriptHash = hashScript script
        redeemer = Minting seedRef
        redeemers =
            Redeemers $
                Map.singleton
                    (ConwayMinting (AsIx 0))
                    (toLedgerData redeemer, placeholderExUnits)
        integrity = computeScriptIntegrity pp redeemers
        allInputUtxos = seedUtxo : funders
        body =
            mkBasicTxBody
                & inputsTxBodyL
                    .~ Set.fromList (map fst allInputUtxos)
                & outputsTxBodyL
                    .~ StrictSeq.fromList [stateOut, checkpointOut']
                & mintTxBodyL .~ mintMA
                & collateralInputsTxBodyL
                    .~ Set.singleton (fst (last allInputUtxos))
                & scriptIntegrityHashTxBodyL .~ integrity
        tx =
            mkBasicTx body
                & witsTxL . scriptTxWitsL
                    .~ Map.singleton scriptHash script
                & witsTxL . rdmrsTxWitsL .~ redeemers
    evaluateAndBalance prov pp allInputUtxos genesisAddr tx
  where
    seedIn = fst seedUtxo
    seedRef = txInToRef seedIn
    seedName = deriveAssetName seedRef

-- ---------------------------------------------------------
-- Identity manifests
-- ---------------------------------------------------------

defaultIdentityPath :: FilePath
defaultIdentityPath = "../onchain/script-identity.json"

defaultNamingIdentityPath :: FilePath
defaultNamingIdentityPath = "../naming-onchain/script-identity.json"

identityPathFromEnv :: IO FilePath
identityPathFromEnv =
    lookupEnv "MPFS_SCRIPT_IDENTITY"
        >>= maybe (pure defaultIdentityPath) pure

namingIdentityPathFromEnv :: IO FilePath
namingIdentityPathFromEnv =
    lookupEnv "NAMING_SCRIPT_IDENTITY"
        >>= maybe (pure defaultNamingIdentityPath) pure

data ScriptIdentity = ScriptIdentity
    { siValidators :: [ValidatorPin]
    }

data ValidatorPin = ValidatorPin
    { vpTitle :: T.Text
    , vpHash :: T.Text
    }

instance FromJSON ValidatorPin where
    parseJSON = withObject "ValidatorPin" $ \o ->
        ValidatorPin
            <$> o .: "title"
            <*> o .: "hash"

instance FromJSON ScriptIdentity where
    parseJSON = withObject "ScriptIdentity" $ \o ->
        ScriptIdentity <$> o .: "validators"

readScriptIdentity :: FilePath -> IO ScriptIdentity
readScriptIdentity path = do
    bytes <- BS.readFile path
    either failWith pure (eitherDecode' (BSL.fromStrict bytes))

newtype NamingIdentity = NamingIdentity
    { niValidators :: [ValidatorPin]
    }

instance FromJSON NamingIdentity where
    parseJSON = withObject "NamingIdentity" $ \o ->
        NamingIdentity <$> o .: "validators"

readNamingIdentity :: FilePath -> IO NamingIdentity
readNamingIdentity path = do
    bytes <- BS.readFile path
    either failWith pure (eitherDecode' (BSL.fromStrict bytes))

-- | Fail the run unless every manifest entry under the prefix pins
-- exactly @unappliedHex@, the hash of this run's blueprint raw code.
checkPinnedUnapplied :: ScriptIdentity -> T.Text -> String -> IO ()
checkPinnedUnapplied si prefix unappliedHex =
    case pins of
        [] ->
            failWith
                ( "derived-applied-identity: no pinned unapplied entry for "
                    <> T.unpack prefix
                )
        (h : rest) ->
            unless (all (== h) rest && h == T.pack unappliedHex) $
                failWith $
                    "derived-applied-identity: the manifest pins unapplied hash 0x"
                        <> T.unpack h
                        <> " for "
                        <> T.unpack prefix
                        <> " but this run's blueprint code hashes to 0x"
                        <> unappliedHex
  where
    pins =
        [ vpHash v
        | v <- siValidators si
        , prefix `T.isPrefixOf` vpTitle v
        ]

-- | The naming application script has no parameters: every pinned
-- application.application entry must equal the hash this run loaded
-- (the #56 check).
checkPinnedApplication :: NamingIdentity -> String -> IO ()
checkPinnedApplication ni appHex = do
    let pins = pinsUnder ni "application.application"
    unless (length pins >= 3) $
        failWith
            "identity: fewer than three application.application pins in the naming manifest"
    unless (all (== T.pack appHex) pins) $
        failWith $
            "identity: the naming manifest pins "
                <> show pins
                <> " but this run's application script hashes to 0x"
                <> appHex

-- | The representative script's unapplied pin must equal the hash of
-- this run's raw representative code.
checkPinnedRepresentative :: NamingIdentity -> String -> IO ()
checkPinnedRepresentative ni unappliedHex = do
    let pins = pinsUnder ni "representative.representative.mint"
    unless (length pins >= 1) $
        failWith "identity: no representative.representative.mint pin in the naming manifest"
    unless (all (== T.pack unappliedHex) pins) $
        failWith $
            "identity: the naming manifest pins "
                <> show pins
                <> " but this run's representative script hashes to 0x"
                <> unappliedHex

pinsUnder :: NamingIdentity -> T.Text -> [T.Text]
pinsUnder ni prefix =
    [ vpHash v
    | v <- niValidators ni
    , prefix `T.isPrefixOf` vpTitle v
    ]

-- ---------------------------------------------------------
-- Datum mirror (the four-field naming datum as on-chain data)
-- ---------------------------------------------------------

namingDatumToData :: NamingDatum -> PLC.Data
namingDatumToData nd =
    PLC.Constr
        0
        [ PLC.Constr
            0
            [ PLC.B (addressBytes (controlAddress nd))
            , destinationData (paymentDestination nd)
            , PLC.B (nextControlCommitment nd)
            , quorumData (retirementQuorum nd)
            ]
        ]
  where
    destinationData NoDestination = PLC.Constr 0 []
    destinationData (SomeDestination a) =
        PLC.Constr 1 [PLC.B (addressBytes a)]
    quorumData q =
        PLC.Constr
            0
            [ PLC.I (quorumThreshold q)
            , PLC.List (map PLC.B (quorumMembers q))
            ]

-- | Domain-separated next-control commitment
-- (docs/naming-lifecycle.md): @BLAKE2b-256("singular\/naming\/
-- next-control\/v1" || 0x00 || canonical-address-bytes)@.
nextControlCommitmentOf :: ByteString -> ByteString
nextControlCommitmentOf bs =
    convert
        ( hash
            ( "singular/naming/next-control/v1"
                <> BS.singleton 0x00
                <> bs
            )
            :: Digest Blake2b_256
        )

datumDiffs :: NamingDatum -> NamingDatum -> [String]
datumDiffs e d =
    concat
        [ [
            "controlAddress expected 0x"
                <> hex (addressBytes (controlAddress e))
                <> " but decoded 0x"
                <> hex (addressBytes (controlAddress d))
          | controlAddress e /= controlAddress d
          ]
        , [
            "paymentDestination expected "
                <> destText (paymentDestination e)
                <> " but decoded "
                <> destText (paymentDestination d)
          | paymentDestination e /= paymentDestination d
          ]
        , [
            "nextControlCommitment expected 0x"
                <> hex (nextControlCommitment e)
                <> " but decoded 0x"
                <> hex (nextControlCommitment d)
          | nextControlCommitment e /= nextControlCommitment d
          ]
        , [
            "retirementQuorum expected "
                <> quorumText (retirementQuorum e)
                <> " but decoded "
                <> quorumText (retirementQuorum d)
          | retirementQuorum e /= retirementQuorum d
          ]
        ]

destText :: PaymentDestination -> String
destText NoDestination = "none"
destText (SomeDestination a) = "0x" <> hex (addressBytes a)

quorumText :: RetirementQuorum -> String
quorumText q =
    "threshold="
        <> show (quorumThreshold q)
        <> " members=["
        <> intercalate
            ","
            (map (("0x" <>) . hex) (quorumMembers q))
        <> "]"

-- | On-chain Plutus data as the codec's wire value.
wireOf :: PLC.Data -> Maybe WireData
wireOf (PLC.Constr i fs)
    | i >= 0 && i <= 6 = Constr (fromIntegral i) <$> traverse wireOf fs
wireOf (PLC.B b) = Just (WBytes b)
wireOf (PLC.I n) = Just (WInt n)
wireOf (PLC.List xs) = WList <$> traverse wireOf xs
wireOf _ = Nothing

-- | The raw on-chain Plutus data of an output, if it has an inline
-- datum.
datumDataOf :: TxOut ConwayEra -> Maybe PLC.Data
datumDataOf out = case out ^. datumTxOutL of
    Datum bd -> let Data d = binaryDataToData bd in Just d
    _ -> Nothing

isNamingDatum :: TxOut ConwayEra -> Bool
isNamingDatum o =
    case datumDataOf o >>= wireOf >>= decodeNamingDatum of
        Just _ -> True
        Nothing -> False

-- ---------------------------------------------------------
-- Shared plumbing
-- ---------------------------------------------------------

takeFundCollateral ::
    Env ->
    IO ((TxIn, TxOut ConwayEra), (TxIn, TxOut ConwayEra))
takeFundCollateral env = do
    pool <- readIORef (envPool env)
    case pool of
        (f : c : rest) -> do
            writeIORef (envPool env) rest
            pure (f, c)
        _ -> failWith "the funding pool is exhausted"

utxoByRef ::
    [(TxIn, TxOut ConwayEra)] ->
    OnChainTxOutRef ->
    String ->
    IO (TxIn, TxOut ConwayEra)
utxoByRef utxos ref label =
    case filter ((== ref) . txInToRef . fst) utxos of
        [p] -> pure p
        _ -> failWith ("world: " <> label <> " " <> show ref <> " is not live")

adaptProvider :: N2C.Provider IO -> Cage.Provider IO
adaptProvider p =
    Cage.Provider
        { Cage.queryUTxOs = N2C.queryUTxOs p
        , Cage.queryProtocolParams = N2C.queryProtocolParams p
        , Cage.evaluateTx = N2C.evaluateTx p
        , Cage.posixMsToSlot = N2C.posixMsToSlot p
        , Cage.posixMsCeilSlot = N2C.posixMsCeilSlot p
        }

verifyConnection :: (Show e) => Async (Either e ()) -> IO ()
verifyConnection nodeThread =
    poll nodeThread >>= \case
        Just (Left err) -> failWith ("node connection failed: " <> show err)
        Just (Right (Left err)) ->
            failWith ("node connection error: " <> show err)
        Just (Right (Right ())) ->
            failWith "node connection closed unexpectedly"
        Nothing -> pure ()

waitConfirmation :: String -> IO ()
waitConfirmation what = do
    threadDelay 5_000_000
    emit "confirm" ("confirmed on chain: " <> what)

-- ---------------------------------------------------------
-- Narration helpers
-- ---------------------------------------------------------

emit :: String -> String -> IO ()
emit step detail = putStrLn ("[lirefusals] " <> step <> ": " <> detail)

failWith :: String -> IO a
failWith msg = throwIO (ErrorCall ("li-refusals: " <> msg))

requireEnv :: String -> IO String
requireEnv name =
    lookupEnv name
        >>= maybe
            (failWith ("missing environment variable " <> name))
            pure

orFail :: Maybe a -> String -> IO a
orFail (Just a) _ = pure a
orFail Nothing msg = failWith msg

hex :: ByteString -> String
hex = T.unpack . TE.decodeUtf8 . Base16.encode

txIdHex :: ConwayTx -> String
txIdHex tx = let TxId h = txIdTx tx in hex (hashToBytes (extractHash h))

showIn :: TxIn -> String
showIn (TxIn (TxId h) (TxIx i)) =
    hex (hashToBytes (extractHash h)) <> "#" <> show i

txInTxIdHex :: TxIn -> String
txInTxIdHex (TxIn (TxId h) _) = hex (hashToBytes (extractHash h))

txInIndex :: TxIn -> Integer
txInIndex (TxIn _ (TxIx i)) = toInteger i

-- | The (txid bytes, output index) sort key of an input, so the seed
-- designation is deterministic.
outRefSortKey :: TxIn -> (ByteString, Integer)
outRefSortKey i =
    let r = txInToRef i
        BuiltinByteString b = txOutRefId r
     in (b, txOutRefIdx r)
