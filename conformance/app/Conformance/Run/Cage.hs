{- |
Module      : Conformance.Run.Cage
Description : Split out of Conformance.Run (#263); see that module's header
License     : Apache-2.0
-}
module Conformance.Run.Cage (ensureRowCage, cageTid, ensureStakeKit, registerStakeCredential, cageStateUtxo, recordDatum, recordDatumHash, cageUtxos, registryContext, sessionRefUtxos, cageRefUtxos, ensureStateRef, ensureStateRefWith, cageUtxosOf, defaultTipCoin, publishRefScript, rowRegistryContext) where

import Conformance.Run.Wallet
import Conformance.Run.Submit
import Conformance.Run.Environment
import Conformance.Run.Manifest

import Control.Concurrent (threadDelay)
import Control.Exception (
    SomeException,
    displayException,
    throwIO,
    try,
 )
import Data.ByteString (ByteString)
import Data.ByteString.Short qualified as SBS
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.List (sortOn)
import Data.Map.Strict qualified as Map
import Data.Ord (Down (..))
import Data.Sequence.Strict qualified as StrictSeq
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Lens.Micro ((&), (.~), (^.))

import Cardano.Crypto.Hash.Class (hashToBytes)
import Cardano.Ledger.Plutus.Data (Data (..), hashData)

import Cardano.Ledger.Api.PParams (ppKeyDepositL)
import Cardano.Ledger.Api.Tx (
    bodyTxL,
    estimateMinFeeTx,
    mkBasicTx,
    mkBasicTxBody,
    txIdTx,
 )
import Cardano.Ledger.Api.Tx.Body (
    certsTxBodyL,
    feeTxBodyL,
    inputsTxBodyL,
    outputsTxBodyL,
 )
import Cardano.Ledger.Api.Tx.Out (
    referenceScriptTxOutL,
    coinTxOutL,
    getMinCoinTxOut,
    mkBasicTxOut,
 )
import Cardano.Ledger.BaseTypes (
    StrictMaybe (..),
    TxIx (..),
 )
import Cardano.Ledger.Conway.TxCert (ConwayDelegCert (..), ConwayTxCert (..))
import Cardano.Ledger.Core (
    Script,
    extractHash,
    hashScript,
 )
import Cardano.Ledger.Credential (Credential (..))
import Cardano.Ledger.Hashes (ScriptHash)
import Cardano.Ledger.Mary.Value (MaryValue (..))
import Cardano.Ledger.TxIn (TxIn (..))

import Singular.Registry.Blueprint (
    NamingCodes (..),
    applyBytesParam,
    applyDataParam,
    extractCompiledCode,
    loadBlueprint,
 )
import Singular.Registry.Config (CageConfig (..))
import Singular.Registry.Ledger (
    AssetName (..),
    Coin (..),
    ConwayEra,
    TokenId (..),
    TxOut,
 )
import Singular.Registry.Provider qualified as Cage
import Singular.Registry.Trie (TrieManager (..))
import Singular.Registry.TxBuilder.Boot (bootTokenImpl)
import Singular.Registry.TxBuilder.Internal (
    cageAddrFromCfg,
    cagePolicyIdFromCfg,
    computeScriptHash,
    findStateUtxo,
    mkCageScript,
    mkRequestScript,
    scriptHashBytes,
    scriptFromBytes,
    txInToRef,
 )
import Singular.Registry.TxBuilder.Update (RegistryContext (..))
import Cardano.Node.Client.E2E.Setup (addKeyWitness)
import Cardano.Node.Client.Submitter (SubmitResult (..), Submitter)
import PlutusCore.Data qualified as PLC

import Conformance.Mirror (
    emit,
    failWith,
    hex,
    require,
    txIdHex,
 )

-- ---------------------------------------------------------
-- Issue #70 machinery: cages, the second wallet, the stake kit
-- ---------------------------------------------------------

{- | The cage for one row group, booted on first use from a fresh
seed. Rows whose outcome leaves odd state (a transferred owner, a
parked request) get their own cage so the odd state cannot poison a
neighbour row. The windows are the boot datum's phase clocks; rows
retracting or rejecting wait for a phase boundary, so fast windows
keep the run short without weakening any check.
-}
ensureRowCage ::
    Env ->
    String ->
    -- | process window (ms, phase 1)
    Integer ->
    -- | retract window (ms, phase 2)
    Integer ->
    IO RowCage
ensureRowCage env name processMs retractMs = do
    worlds <- readIORef (envWorlds env)
    case Map.lookup name worlds of
        Just w -> pure w
        Nothing -> do
            -- The library builders below choose their own fee and
            -- collateral inputs, and choose them by position rather than
            -- by size. One ada-only output leaves them nothing to get
            -- wrong.
            consolidateFunding env
            -- Boot with retry: the node supervisor can be mid-
            -- reconnect when a row group starts (its connection loss
            -- is transient); a failed attempt leaves nothing behind —
            -- each attempt takes a fresh seed.
            w <- bootCageAttempt (3 :: Int)
            writeIORef (envWorlds env) (Map.insert name w worlds)
            pure w
  where
    bootCageAttempt n = do
        r <- try @SomeException bootOnce
        case r of
            Right w -> pure w
            Left e
                | n > 1 -> do
                    emit
                        "boot"
                        ( "boot attempt failed ("
                            <> take 200 (displayException e)
                            <> "); retrying"
                        )
                    threadDelay 5_000_000
                    bootCageAttempt (n - 1)
                | otherwise -> throwIO e
    bootOnce :: IO RowCage
    bootOnce = do
        let (stateBytes, requestBytes, namingCodes) = envCodes env
            prov = envProv env
        -- Sweep, then carve: seeding from the largest output would strand
        -- the funding in the cage and leave the change to fund and
        -- collateralise the boot.
        consolidateFunding env
        seedTxIn <- carveSeed env
        let cfg =
                cageCfgWith
                    stateBytes
                    requestBytes
                    namingCodes
                    (txInToRef seedTxIn)
                    processMs
                    retractMs
        unsignedBoot <- bootTokenImpl cfg prov genesisAddr
        signedBoot <- submitWithGenesis (envSubmit env) unsignedBoot
        tid <- extractTokenId cfg signedBoot
        createTrie (envTm env) tid
        tidRef <- newIORef (Just tid)
        unitsRef <- newIORef (0, 0)
        published <- cageRefUtxos env cfg tid

        let w = RowCage cfg tidRef unitsRef published
        emit
            "cage"
            ( name
                <> " booted bootTx="
                <> txIdHex signedBoot
                <> " processMs="
                <> show processMs
                <> " retractMs="
                <> show retractMs
            )
        pure w


cageTid :: RowCage -> IO TokenId
cageTid rc = do
    t <- readIORef (rcTid rc)
    case t of
        Just tid -> pure tid
        Nothing -> failWith "row cage is not booted"


{- | The stake_script hook's kit (CG14/CG15): the blueprint's
staking validator, its hash cross-checked against the pinned
manifest, the credential registered on the devnet (a withdrawal
from an unregistered account is a phase-1 error, not a verdict on
the hook), and the cage booted with the hook in its datum.
-}
ensureStakeKit :: Env -> IO StakeKit
ensureStakeKit env = do
    kit <- readIORef (envStake env)
    case kit of
        Just k -> pure k
        Nothing -> do
            ebp <- loadBlueprint (envBlueprintPath env)
            bp <- case ebp of
                Left err -> failWith ("blueprint does not parse: " <> err)
                Right b -> pure b
            bytes <- case extractCompiledCode "staking.staking" bp of
                Just b -> pure b
                Nothing ->
                    failWith
                        "the blueprint carries no staking.staking validator"
            let h = computeScriptHash bytes
                hHex = hex (scriptHashBytes h)
            manifest <- readScriptManifest
            case pinsUnder "staking.staking" manifest of
                [] ->
                    failWith
                        "the script manifest pins no staking.staking entry"
                pins ->
                    require
                        ( "the staking pin disagrees with this run's \
                           \blueprint: "
                            <> show pins
                            <> " vs 0x"
                            <> hHex
                        )
                        (all ((== T.pack hHex) . fst) pins)
            registerStakeCredential env bytes h
            cage <-
                ensureRowCage
                    env
                    "cg-stake"
                    60_000
                    300_000
            let k = StakeKit bytes h cage
            writeIORef (envStake env) (Just k)
            pure k


{- | Register the staking credential: a @RegTxCert@ paying the key
deposit. Registration carries no script witness — the blueprint's
staking validator implements only the withdraw handler, so a cert
purpose would run its fail branch, and the node does not demand a
witness for a registration. The deposit is paid; nobody withdraws
it back — a devnet-bound residue, recorded, not hidden.
-}
registerStakeCredential ::
    Env -> SBS.ShortByteString -> ScriptHash -> IO ()
registerStakeCredential env _bytes h = do
    let prov = envProv env
        cred = ScriptHashObj h
    pp <- Cage.queryProtocolParams prov
    (funderIn, funderOut) <- largestWalletUtxo prov
    let Coin avail = funderOut ^. coinTxOutL
        depositCoin = pp ^. ppKeyDepositL
        Coin deposit = depositCoin
        build feeAmt =
            mkBasicTx
                ( mkBasicTxBody
                    & inputsTxBodyL .~ Set.singleton funderIn
                    & certsTxBodyL
                        .~ StrictSeq.fromList
                            [ ConwayTxCertDeleg
                                ( ConwayRegCert
                                    cred
                                    (SJust depositCoin)
                                )
                            ]
                    & feeTxBodyL .~ Coin feeAmt
                )
    let Coin estFee = estimateMinFeeTx pp (build 0) 1 0 0
        fee = estFee + 50_000
        change = avail - fee - deposit
        changeOut = mkBasicTxOut genesisAddr (MaryValue (Coin change) mempty)
        Coin minAda = getMinCoinTxOut @ConwayEra pp changeOut
    require
        ( "registration: wallet output under min-ADA after fee+deposit: "
            <> show change
        )
        (change >= minAda)
    let tx =
            build fee
                & bodyTxL . outputsTxBodyL
                    .~ StrictSeq.fromList
                        [ mkBasicTxOut
                            genesisAddr
                            (MaryValue (Coin change) mempty)
                        ]
    signed <- pure (addKeyWitness genesisSignKey tx)
    result <- submitTxResilient (envSubmit env) signed
    case result of
        Submitted _ -> pure ()
        Rejected reason ->
            failWith
                ( "CG14/CG15 COULD NOT EXECUTE — registration of the \
                   \staking credential refused: "
                    <> T.unpack (TE.decodeUtf8Lenient reason)
                )
    awaitTx signed
    emit
        "stake"
        ( "staking credential 0x"
            <> hex (scriptHashBytes h)
            <> " registered (deposit "
            <> show deposit
            <> ") regTx="
            <> txIdHex signed
        )


cageStateUtxo :: Env -> RowCage -> IO (TxIn, TxOut ConwayEra)
cageStateUtxo env cage = do
    tid <- cageTid cage
    let cfg = rcCfg cage
    utxos <- Cage.queryUTxOs (envProv env) (cageAddrFromCfg cfg (network cfg))
    case findStateUtxo (cagePolicyIdFromCfg cfg) tid utxos of
        Just u -> pure u
        Nothing -> failWith "row cage: no state UTxO"


{- | The record datum a booking's destination binds, and its hash. The
cage checks only that the receiving output carries a datum hashing to what
the approval bound — naming's own validators do not run at fold time — so
the harness needs one datum it can produce on both sides and nothing more.
-}
recordDatum :: PLC.Data
recordDatum = PLC.B "cg-record"


recordDatumHash :: ByteString
recordDatumHash =
    hashToBytes (extractHash (hashData (Data recordDatum :: Data ConwayEra)))


-- | The UTxOs sitting at the cage's own address; custody lives among them.
cageUtxos :: Env -> IO [(TxIn, TxOut ConwayEra)]
cageUtxos env =
    Cage.queryUTxOs
        (envProv env)
        (cageAddrFromCfg (envCfg env) (network (envCfg env)))


{- | Everything a fold of tree edges needs in hand: the three token
policies this registry pins, the cage script custody spends run, the cage's
own UTxOs, and the one destination datum the harness books against.
-}
registryContext :: Env -> IO RegistryContext
registryContext env = do
    refs <- sessionRefUtxos env
    let cfg = envCfg env
        (_, _, codes) = envCodes env
        registryId =
            scriptHashBytes (cfgScriptHash cfg)
                <> SBS.fromShort (assetNameBytes (unTokenId (envTid env)))
        witnessAt kind =
            scriptFromBytes
                ("witness-" <> show kind)
                ( applyBytesParam
                    registryId
                    (applyDataParam (PLC.I kind) (ncWitness codes))
                )
    utxos <- cageUtxos env
    pure
        RegistryContext
            { rcWitnessScripts =
                Map.fromList [(k, witnessAt k) | k <- [0, 1, 2]]
            , rcCageScript = Just (mkCageScript cfg)
            , rcCageUtxos = utxos
            , rcDatums = [(recordDatumHash, recordDatum)]
            , rcAllowInadmissible = False
            , rcHolderUtxos = []
            , rcRefUtxos = refs
            }


{- | The session's reference outputs, published on first use: the cage,
the request validator and the three token policies.
-}
sessionRefUtxos :: Env -> IO [(TxIn, TxOut ConwayEra)]
sessionRefUtxos env = do
    cached <- readIORef (envRefs env)
    case cached of
        Just refs -> pure refs
        Nothing -> do
            refs <- cageRefUtxos env (envCfg env) (envTid env)
            writeIORef (envRefs env) (Just refs)
            pure refs


-- | The reference outputs one cage's folds resolve their scripts through.
cageRefUtxos ::
    Env -> CageConfig -> TokenId -> IO [(TxIn, TxOut ConwayEra)]
cageRefUtxos env cfg tid = do
            let (_, _, codes) = envCodes env
                registryId =
                    scriptHashBytes (cfgScriptHash cfg)
                        <> SBS.fromShort (assetNameBytes (unTokenId tid))
                witnessAt kind =
                    scriptFromBytes
                        ("witness-" <> show kind)
                        ( applyBytesParam
                            registryId
                            (applyDataParam (PLC.I kind) (ncWitness codes))
                        )
            refs <-
                mapM
                    (publishRefScript env)
                    ( [ mkCageScript cfg
                      , mkRequestScript cfg tid
                      ]
                        <> map witnessAt [0, 1, 2]
                    )
            emit
                "references"
                ( show (length refs)
                    <> " scripts published as reference outputs; folds resolve \
                       \every purpose through them"
                )
            pure refs


{- | Sweep the funder's ada-only outputs back into one.

Every fold returns the approval it consumed to the booker in an output of
its own, and every booking and publication leaves change, so the wallet
fragments as a session runs. A builder that picks collateral without
weighing it then picks a small output and the ledger refuses the
transaction for a collateral shortfall. One output, one choice.

Reference outputs are left alone: they are what the folds resolve their
scripts through.
-}

{- | Publish the state validator as a reference output once per session,
before any boot (#177, A-003).

A registry boots only by reference: the boot resolves the state
validator through a publication in the funding wallet and is refused
`StateValidatorNotPublished` without one, because that validator is
fifteen kilobytes against a sixteen-kilobyte transaction cap.

Every cage in a session shares the same state script — only the seed
differs — so one publication serves every boot. Idempotent by
discovery, and the funding sweep already spares outputs carrying
reference scripts, so it publishes once and finds it thereafter.
-}
ensureStateRef :: Env -> IO ()
ensureStateRef env =
    ensureStateRefWith
        (envProv env)
        (envSubmit env)
        (cageScriptBytes (envCfg env))

{- | 'ensureStateRef' before the session's environment exists: the
session cage boots before its 'Env' is built, and the state validator
depends on the blueprint alone, not on the seed.
-}
ensureStateRefWith ::
    Cage.Provider IO -> Submitter IO -> SBS.ShortByteString -> IO ()
ensureStateRefWith prov submit stateBytes = do
    let script = scriptFromBytes "state" stateBytes
        wanted = hashScript script
    utxos <- Cage.queryUTxOs prov genesisAddr
    let published =
            [ ()
            | (_, out) <- utxos
            , SJust s <- [out ^. referenceScriptTxOutL]
            , hashScript s == wanted
            ]
    case published of
        (_ : _) -> pure ()
        [] -> do
            _ <- publishRefScriptWith prov submit script
            emit
                "state-ref"
                "published the state validator as a reference output; \
                \boots reference it instead of carrying it inline"


-- | The UTxOs at a given cage's own address; custody lives among them.
cageUtxosOf :: Env -> CageConfig -> IO [(TxIn, TxOut ConwayEra)]
cageUtxosOf env cfg =
    Cage.queryUTxOs (envProv env) (cageAddrFromCfg cfg (network cfg))


-- | The tip a cage charges, as a plain integer.
defaultTipCoin :: CageConfig -> Integer
defaultTipCoin cfg = case defaultTip cfg of Coin c -> c


{- | Publish one script as a reference output, once per session.

The state validator alone is fifteen kilobytes: a fold that attaches it,
the request script and a token policy does not fit in a transaction. The
same outputs serve every fold the session builds, so this happens once and
the references are carried in the environment.
-}
publishRefScript :: Env -> Script ConwayEra -> IO (TxIn, TxOut ConwayEra)
publishRefScript env = publishRefScriptWith (envProv env) (envSubmit env)

-- | 'publishRefScript' from the provider and submitter alone.
publishRefScriptWith ::
    Cage.Provider IO ->
    Submitter IO ->
    Script ConwayEra ->
    IO (TxIn, TxOut ConwayEra)
publishRefScriptWith prov submit script = do
    pp <- Cage.queryProtocolParams prov
    utxos <- Cage.queryUTxOs prov genesisAddr
    fund <- case sortOn (Down . (^. coinTxOutL) . snd) utxos of
        [] -> failWith "publishRefScript: the funding wallet has no output"
        (u : _) -> pure u
    let probe =
            mkBasicTxOut genesisAddr (MaryValue (Coin 0) mempty)
                & referenceScriptTxOutL .~ SJust script
        Coin minCoin = getMinCoinTxOut @ConwayEra pp probe
        refCoin = minCoin + 1_000_000
        refOut =
            mkBasicTxOut genesisAddr (MaryValue (Coin refCoin) mempty)
                & referenceScriptTxOutL .~ SJust script
        fee = 1_000_000
        Coin inCoin = snd fund ^. coinTxOutL
        changeCoin = inCoin - fee - refCoin
    require
        ( "publishRefScript: funding output holds "
            <> show inCoin
            <> ", which does not cover a reference output of "
            <> show refCoin
            <> " plus fees"
        )
        (changeCoin > 1_000_000)
    let body =
            mkBasicTxBody
                & inputsTxBodyL .~ Set.singleton (fst fund)
                & outputsTxBodyL
                    .~ StrictSeq.fromList
                        [ refOut
                        , mkBasicTxOut genesisAddr (MaryValue (Coin changeCoin) mempty)
                        ]
                & feeTxBodyL .~ Coin fee
        signed = addKeyWitness genesisSignKey (mkBasicTx body)
    result <- submitTxResilient submit signed
    case result of
        Submitted _ -> awaitTx signed
        Rejected reason ->
            failWith
                ( "publishRefScript refused: "
                    <> T.unpack (TE.decodeUtf8Lenient reason)
                )
    pure (TxIn (txIdTx signed) (TxIx 0), refOut)


{- | The duties context for a row cage: its own three token policies, the
cage script its custody spends run, its UTxOs, the one destination datum
the harness books against, and the reference outputs published at its boot.
-}
rowRegistryContext :: Env -> RowCage -> TokenId -> IO RegistryContext
rowRegistryContext env cage tid = do
    let cfg = rcCfg cage
        (_, _, codes) = envCodes env
        registryId =
            scriptHashBytes (cfgScriptHash cfg)
                <> SBS.fromShort (assetNameBytes (unTokenId tid))
        witnessAt kind =
            scriptFromBytes
                ("witness-" <> show kind)
                ( applyBytesParam
                    registryId
                    (applyDataParam (PLC.I kind) (ncWitness codes))
                )
    utxos <- cageUtxosOf env cfg
    pure
        RegistryContext
            { rcWitnessScripts = Map.fromList [(k, witnessAt k) | k <- [0, 1, 2]]
            , rcCageScript = Just (mkCageScript cfg)
            , rcCageUtxos = utxos
            , rcDatums = [(recordDatumHash, recordDatum)]
            , rcAllowInadmissible = False
            , rcHolderUtxos = []
            , rcRefUtxos = rcRefs cage
            }
