{- |
Module      : Conformance.Run.Cage
Description : Split out of Conformance.Run (#263); see that module's header
License     : Apache-2.0
-}
module Conformance.Run.Cage
    ( ensureRowCage
    , cageTid
    , cageStateUtxo
    , recordDatum
    , recordDatumHash
    , cageUtxos
    , cageRefUtxos
    , ensureStateRef
    , ensureStateRefWith
    , cageUtxosOf
    , defaultTipCoin
    , publishRefScript
    , rowRegistryContext
    ) where

import Conformance.Run.Environment
import Conformance.Run.Submit
import Conformance.Run.Wallet
import Singular.Registry.Evidence qualified as Cage

import Control.Concurrent (threadDelay)
import Control.Exception
    ( displayException
    , throwIO
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
import Lens.Micro ((&), (.~), (^.))

import Cardano.Crypto.Hash.Class (hashToBytes)
import Cardano.Ledger.Plutus.Data (Data (..), hashData)

import Cardano.Ledger.Api.Tx
    ( mkBasicTx
    , mkBasicTxBody
    , txIdTx
    )
import Cardano.Ledger.Api.Tx.Body
    ( feeTxBodyL
    , inputsTxBodyL
    , outputsTxBodyL
    )
import Cardano.Ledger.Api.Tx.Out
    ( coinTxOutL
    , getMinCoinTxOut
    , mkBasicTxOut
    , referenceScriptTxOutL
    )
import Cardano.Ledger.BaseTypes
    ( StrictMaybe (..)
    , TxIx (..)
    )
import Cardano.Ledger.Core
    ( Script
    , extractHash
    , hashScript
    )
import Cardano.Ledger.Mary.Value (MaryValue (..))
import Cardano.Ledger.TxIn (TxIn (..))

import PlutusCore.Data qualified as PLC
import Singular.Registry.Blueprint
    ( NamingCodes (..)
    , applyBytesParam
    , applyDataParam
    )
import Singular.Registry.Capabilities (Capabilities (..))
import Singular.Registry.Config (CageConfig (..))
import Singular.Registry.Ledger
    ( AssetName (..)
    , Coin (..)
    , ConwayEra
    , TokenId (..)
    , TxOut
    )
import Singular.Registry.LedgerProvider (SubmitResult (..))
import Singular.Registry.LedgerProvider qualified as Cage
import Singular.Registry.SessionIO qualified as Cage
import Singular.Registry.Signing (signTx, signedTx)
import Singular.Registry.Trie (TrieManager (..))
import Singular.Registry.TxBuilder.Boot (bootTokenImpl)
import Singular.Registry.TxBuilder.Internal
    ( cageAddrFromCfg
    , cagePolicyIdFromCfg
    , findStateUtxo
    , mkCageScript
    , mkRequestScript
    , scriptFromBytes
    , scriptHashBytes
    , txInToRef
    )
import Singular.Registry.TxBuilder.Update (RegistryContext (..))
import Singular.Registry.Wait (tryOutcome)

import Conformance.Mirror
    ( emit
    , failWith
    , require
    , txIdHex
    )

-- ---------------------------------------------------------
-- Row registries
-- ---------------------------------------------------------

{- | The cage for one row group, booted on first use from a fresh
seed. Rows whose outcome leaves odd state (a transferred owner, a
parked request) get their own cage so the odd state cannot poison a
neighbour row. The windows are the boot datum's phase clocks; rows
retracting or rejecting wait for a phase boundary, so fast windows
keep the run short without weakening any check.
-}
ensureRowCage
    :: Env
    -> String
    -> Integer
    -- ^ process window (ms, phase 1)
    -> Integer
    -- ^ retract window (ms, phase 2)
    -> IO RowCage
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
        r <- tryOutcome bootOnce
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
        unsignedBoot <-
            Cage.withLatest prov (\v -> bootTokenImpl cfg v genesisAddr)
        signedBoot <- submitWithGenesis (envCaps env) unsignedBoot
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

cageStateUtxo :: Env -> RowCage -> IO (TxIn, TxOut ConwayEra)
cageStateUtxo env cage = do
    tid <- cageTid cage
    let cfg = rcCfg cage
    utxos <-
        Cage.withLatest
            (envProv env)
            (`Cage.outputsAt` cageAddrFromCfg cfg (network cfg))
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
    hashToBytes
        (extractHash (hashData (Data recordDatum :: Data ConwayEra)))

-- | The UTxOs sitting at the cage's own address; custody lives among them.
cageUtxos :: Env -> IO [(TxIn, TxOut ConwayEra)]
cageUtxos env =
    Cage.withLatest
        (envProv env)
        (`Cage.outputsAt` cageAddrFromCfg (envCfg env) (network (envCfg env)))

-- | The reference outputs one cage's folds resolve their scripts through.
cageRefUtxos
    :: Env -> CageConfig -> TokenId -> IO [(TxIn, TxOut ConwayEra)]
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
        (envCaps env)
        (cageScriptBytes (envCfg env))

{- | 'ensureStateRef' before the session's environment exists: the
session cage boots before its 'Env' is built, and the state validator
depends on the blueprint alone, not on the seed.
-}
ensureStateRefWith
    :: (Cage.Network, Cage.LedgerProvider Cage.NoWitness IO)
    -> Capabilities Cage.NoWitness IO
    -> SBS.ShortByteString
    -> IO ()
ensureStateRefWith prov submit stateBytes = do
    let script = scriptFromBytes "state" stateBytes
        wanted = hashScript script
    utxos <- Cage.withLatest prov (`Cage.outputsAt` genesisAddr)
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
    Cage.withLatest
        (envProv env)
        (`Cage.outputsAt` cageAddrFromCfg cfg (network cfg))

-- | The tip a cage charges, as a plain integer.
defaultTipCoin :: CageConfig -> Integer
defaultTipCoin cfg = case defaultTip cfg of Coin c -> c

{- | Publish one script as a reference output, once per session.

The state validator alone is fifteen kilobytes: a fold that attaches it,
the request script and a token policy does not fit in a transaction. The
same outputs serve every fold the session builds, so this happens once and
the references are carried in the environment.
-}
publishRefScript
    :: Env -> Script ConwayEra -> IO (TxIn, TxOut ConwayEra)
publishRefScript env = publishRefScriptWith (envProv env) (envCaps env)

-- | 'publishRefScript' from the provider and submitter alone.
publishRefScriptWith
    :: (Cage.Network, Cage.LedgerProvider Cage.NoWitness IO)
    -> Capabilities Cage.NoWitness IO
    -> Script ConwayEra
    -> IO (TxIn, TxOut ConwayEra)
publishRefScriptWith prov submit script = do
    -- One transaction, one view: parameters and the funding outputs.
    (pp, utxos) <- Cage.withLatest prov $ \v ->
        (,) <$> Cage.parameters v <*> Cage.outputsAt v genesisAddr
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
        signedWitnessed = signTx genesisSignKey (mkBasicTx body)
        signed = signedTx signedWitnessed
    result <- submitTxResilient (capSubmit submit) signedWitnessed
    case result of
        SubmitAccepted _ -> capConfirm submit signed
        SubmitRefused reason ->
            failWith
                ( "publishRefScript refused: "
                    <> T.unpack reason
                )
        unavailable -> failWith ("submission unavailable: " <> show unavailable)
    pure (TxIn (txIdTx signed) (TxIx 0), refOut)

{- | The duties context for a row cage: its own three token policies, the
cage script its custody spends run, its UTxOs, the one destination datum
the harness books against, and the reference outputs published at its boot —
read from the view the fold itself is built in.
-}
rowRegistryContext
    :: Env
    -> Cage.Session Cage.NoWitness IO
    -> RowCage
    -> TokenId
    -> IO RegistryContext
rowRegistryContext env0 v cage tid = do
    let env = pinnedTo v env0
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
            , rcHolderReleases = Map.empty
            , rcRefUtxos = rcRefs cage
            }
