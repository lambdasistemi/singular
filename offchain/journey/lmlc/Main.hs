{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Main
Description : The LM/LC maintenance and cancellation rows on a real devnet (issue #56)
License     : Apache-2.0

Executes the ten contract rows @LM01..LM04@, @WR01@ and
@LC01..LC06@ against a real devnet node, one narration line per
step, and verifies what the chain then holds. The rows were proved
at model level by epic 15 and at Aiken level by #52; this is the
first time they meet a ledger, so what is under test is the
/composition/: can a real transaction present the context the Aiken
tests constructed, and do the naming scripts and the merged codec
agree the way the correspondence record claims?

Ledger realisation (offchain\/naming-correspondence.md, t52
entries):

  * the claim is a UTxO at the naming application validator carrying
    the four-field naming datum inline (merged 'Naming.Datum'
    codec), and — where the row needs it — the withdraw approval
    whose asset name IS the stored refund destination, minted by the
    application policy's mint purpose on the controller's signature
    (the refund recorded at request time, @WR01@);

  * @LM@ rows spend the claim with a @Maintain@ redeemer and demand
    the controller's key hash among the transaction's required
    signers; only the payment destination is maintainable;

  * @LC@ rows spend a claim with a @Cancel@ redeemer presenting the
    refund; the validator compares the presentation against the
    approval's asset name and demands the approval burned exactly
    once, unsigned — the row witness is @requiredSigners: []@.

Every refusal is asserted on its reason: the node must report a
phase-2 PlutusFailure naming the application validator's script
hash. A fee, missing-input or malformed-CBOR refusal fails the run.
@LC06@ is the one honest exception: the consumed approval's claim is
no longer spendable, so the ledger itself refuses the replay in
phase 1 naming the consumed output — recorded as exactly that
instead of dressed up as a validator refusal.

Controls (env @LMLC_CONTROL@): @valid@ makes LM02's transaction
actually valid, so it succeeds and the refusal guard must fail the
run; @wrong-reason@ matches every refusal against a marker that
cannot occur, so the reason matcher must fail the run naming what
came back. Both exit 1 by design.

Probe (env @LMLC_PROBE@): runs the setup and then only LC01 as the
correspondence record describes it, against whatever blueprint
@NAMING_BLUEPRINT@ names — the instrument that decides whether the
mint purpose can execute the burn the spend purpose demands.

Hermetic run (D-011), from @offchain/@:

> blueprint="$(nix build --quiet --no-link --print-out-paths ../naming-onchain#plutus-blueprint)"
> NAMING_BLUEPRINT="$blueprint" nix run --quiet .#naming-rows
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
import Data.Bits (complement)
import Data.ByteArray (convert)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as Base16
import Data.ByteString.Lazy qualified as BSL
import Data.ByteString.Short qualified as SBS
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Aeson (FromJSON (..), eitherDecode', withObject, (.:))
import Data.List (intercalate, isInfixOf, sortBy)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, isJust)
import Data.Ord (comparing)
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Sequence.Strict qualified as StrictSeq
import Lens.Micro ((&), (.~), (^.))
import PlutusCore.Data qualified as PLC
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
import Cardano.Ledger.Core (Script, extractHash)
import Cardano.Ledger.Credential (Credential (..), StakeReference (..))
import Cardano.Ledger.Hashes (ScriptHash)
import Cardano.Ledger.Mary.Value (MaryValue (..), MultiAsset (..), PolicyID (..))
import Cardano.Ledger.Plutus.ExUnits (ExUnits (..))
import Cardano.Ledger.TxIn (TxId (..))

import Cardano.MPFS.Cage.Blueprint (extractCompiledCode, loadBlueprint)
import Cardano.MPFS.Cage.Ledger (
    AssetName (..),
    Coin (..),
    ConwayEra,
    PParams,
 )
import Cardano.MPFS.Cage.Provider qualified as Cage
import Cardano.MPFS.Cage.TxBuilder.Internal (
    addrKeyHashBytes,
    addrWitnessKeyHash,
    computeScriptHash,
    computeScriptIntegrity,
    mkInlineDatum,
    scriptFromBytes,
    scriptHashBytes,
    spendingIndex,
 )
import Cardano.Node.Client.E2E.Devnet (withCardanoNode)
import Cardano.Node.Client.E2E.Setup (
    addKeyWitness,
    devnetMagic,
    enterpriseAddr,
    genesisAddr,
    genesisDir,
    genesisSignKey,
    keyHashFromSignKey,
    mkSignKey,
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
    = -- | the ten rows.
      MainRun
    | -- | LC01 as the correspondence record describes it, against
      -- whatever blueprint NAMING_BLUEPRINT names.
      Probe
    | -- | LM02's transaction made actually valid: it must succeed,
      -- and the refusal guard must then fail the run (exit 1).
      ControlValid
    | -- | every refusal matched against a marker that cannot occur:
      -- the matcher must fail the run naming what came back.
      ControlWrongReason
    deriving (Eq, Show)

readMode :: IO Mode
readMode =
    lookupEnv "LMLC_PROBE" >>= \case
        Just _ -> pure Probe
        Nothing ->
            lookupEnv "LMLC_CONTROL" >>= \case
                Just "valid" -> pure ControlValid
                Just "wrong-reason" -> pure ControlWrongReason
                Just other
                    | not (null other) ->
                        failWith ("unknown LMLC_CONTROL value " <> other)
                _ -> pure MainRun

-- | The marker the wrong-reason control matches refusals against: by
-- construction no node reason can contain it, so a matched reason can
-- never close a row and the control must fail.
wrongReasonMarker :: String
wrongReasonMarker =
    "wrong-reason-control marker that no node reason can ever contain"

-- ---------------------------------------------------------
-- Ledger-shape constants
-- ---------------------------------------------------------

-- | Flat fee for hand-balanced transactions. Generously above the
-- devnet's minimum (~0.2 ada for a small tx) and above the fee the
-- declared max execution units price in (~8.8 ada).
flatFee :: Integer
flatFee = 10_000_000

-- | maxTxExUnits from the checked-in devnet genesis
-- (e2e-test/genesis/alonzo-genesis.json). Declared units must be <=
-- this; refusal transactions declare exactly it so an oversized real
-- cost can never reject the tx before its validator refuses.
-- | Declared units for hand-balanced transactions. Generous enough
-- that a full datum decode plus the row's guard (~100M steps, ~1.5M
-- mem measured on chain) runs to completion, small enough that a
-- runaway evaluation hits the wall in seconds instead of minutes.
maxUnits :: ExUnits
maxUnits = ExUnits 3_000_000 200_000_000

-- | Lovelace a claim carries. Generously above the flat fee so LC01's
-- refund check is real: owed = claim - fee stays positive and the
-- refund output must pay it.
claimCoin :: Integer
claimCoin = 25_000_000

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
                "issue #56: the LM/LC maintenance and cancellation rows on \
                \a real ledger"
        Probe ->
            emit
                "probe"
                "LC01-cancellation-stored-refund-accepts as the \
                \correspondence record describes it (approval burned \
                \exactly -1), against the blueprint NAMING_BLUEPRINT names"
        ControlValid ->
            emit
                "control"
                "valid-transaction control: LM02 made actually valid, so it \
                \must succeed and the refusal guard must fail the run"
        ControlWrongReason ->
            emit
                "control"
                "wrong-reason control: refusals matched against a marker \
                \that cannot occur, so the matcher must fail the run"
    blueprintPath <- requireEnv "NAMING_BLUEPRINT"
    outcome <-
        try (runMode mode blueprintPath) :: IO (Either SomeException ())
    case outcome of
        Right () -> pure ()
        Left e -> do
            hPutStrLn stderr ("naming-rows: FAILED: " <> displayException e)
            exitWith (ExitFailure 1)

-- ---------------------------------------------------------
-- The run
-- ---------------------------------------------------------

runMode :: Mode -> FilePath -> IO ()
runMode mode blueprintPath = do
    ebp <- loadBlueprint blueprintPath
    bp <- either failWith pure ebp
    appBytes <- case extractCompiledCode "application.application" bp of
        Just bytes -> pure bytes
        Nothing ->
            failWith
                "application.application compiled code not found in the \
                \naming blueprint"
    gDir <- genesisDir
    withCardanoNode gDir $ \sock _startMs -> do
        lsqCh <- newLSQChannel 16
        ltxsCh <- newLTxSChannel 16
        nodeThread <- async $ runNodeClient devnetMagic sock lsqCh ltxsCh
        threadDelay 3_000_000
        verifyConnection nodeThread
        let prov = adaptProvider (mkN2CProvider lsqCh)
            submit = mkN2CSubmitter ltxsCh
        pp <- Cage.queryProtocolParams prov
        let script = scriptFromBytes "naming-application" appBytes
            appHash = computeScriptHash appBytes
            appHex = hex (scriptHashBytes appHash)
            appAddr = Addr Testnet (ScriptHashObj appHash) StakeRefNull
            appPolicy = PolicyID appHash
        checkPinnedApplication appHex
        emit
            "identity"
            ( "application validator hash 0x"
                <> appHex
                <> " (0 parameters: the pinned manifest identity is the \
                   \applied identity this run carries on chain)"
            )
        -- Fixture keys. The controller is the devnet genesis key; the
        -- refund destination and the payment destination are real
        -- devnet enterprise payment-key addresses.
        let ctrlHash = addrKeyHashBytes genesisAddr
            ctrlAddrBytes = serialiseAddr genesisAddr
            refundAddr =
                enterpriseAddr
                    (keyHashFromSignKey (mkSignKey "t56-refund-key-seed-000000000001"))
            refundBytes = serialiseAddr refundAddr
            foldRefundAddr =
                enterpriseAddr
                    (keyHashFromSignKey (mkSignKey "t56-refund-fold-key-seed-0000001"))
            foldRefundBytes = serialiseAddr foldRefundAddr
            destAddr =
                enterpriseAddr
                    (keyHashFromSignKey (mkSignKey "t56-destination-key-seed-0000001"))
            -- Codec-side Addresses (the merged codec's own type, what the
            -- datum carries) decoded from the ledger addresses.
            mustCodec bytes = case decodeAddress bytes of
                Just a -> a
                Nothing ->
                    error
                        "fixture: a devnet address does not decode as the contract's canonical address"
            ctrlAddrCodec = mustCodec ctrlAddrBytes
            destAddrCodec = mustCodec (serialiseAddr destAddr)
            commitmentC = nextControlCommitmentOf ctrlAddrBytes
            commitmentF = nextControlCommitmentOf (serialiseAddr refundAddr)
            mkDatum c =
                NamingDatum
                    { controlAddress = ctrlAddrCodec
                    , paymentDestination = NoDestination
                    , nextControlCommitment = c
                    , retirementQuorum =
                        RetirementQuorum
                            { quorumMembers = [ctrlHash]
                            , quorumThreshold = 1
                            }
                    }
            datumLC = mkDatum commitmentC
            datumLM = mkDatum commitmentC
            datumFold = mkDatum commitmentF
        -- Split the genesis wallet into funding and collateral UTxOs.
        emit "split" "splitting the genesis wallet into funding UTxOs"
        pool <- splitGenesis prov submit
        poolRef <- newIORef pool
        let env =
                Env
                    { envProv = prov
                    , envSubmit = submit
                    , envPp = pp
                    , envPool = poolRef
                    , envScript = script
                    , envScriptHash = appHash
                    , envAppHex = appHex
                    , envAppPolicy = appPolicy
                    , envAppAddr = appAddr
                    , envCtrlHash = ctrlHash
                    , envRefundBytes = refundBytes
                    , envRefundAddr = refundAddr
                    , envDestAddr = destAddr
                    , envDestCodec = destAddrCodec
                    , envFoldRefundBytes = foldRefundBytes
                    }
        -- Setup 1: mint the withdraw approval (the refund recorded at
        -- request time, controller-signed) and create claimLC (with the
        -- approval) and claimLM (without one).
        (txid1, claimLCIn, claimLMIn) <- setupTwoClaims env datumLC datumLM
        _ <- waitConfirmation (txid1 <> " (setup: claimLC, claimLM)")
        -- Setup 2: a second approval and claimFold — the claim the LC04
        -- proof folds for real. One approval per transaction: the mint
        -- purpose mints exactly one.
        (txid2, claimFoldIn) <- setupFoldClaim env datumFold
        _ <- waitConfirmation (txid2 <> " (setup: claimFold)")
        emit
            "setup"
            ( "claims live at the application validator 0x"
                <> appHex
                <> ": claimLC="
                <> showIn claimLCIn
                <> " claimLM="
                <> showIn claimLMIn
                <> " claimFold="
                <> showIn claimFoldIn
                <> "; the refund recorded at request time is the approval's \
                   \asset name 0x"
                <> hex refundBytes
                <> " (minted controller-signed in "
                <> txid1
                <> ")"
            )
        case mode of
            Probe -> runProbe env claimLCIn
            _ -> runRows mode env claimLCIn claimLMIn claimFoldIn
        cancel nodeThread

-- | The environment every row builds against.
data Env = Env
    { envProv :: Cage.Provider IO
    , envSubmit :: Submitter IO
    , envPp :: PParams ConwayEra
    , envPool :: IORef [(TxIn, TxOut ConwayEra)]
    , envScript :: Script ConwayEra
    , envScriptHash :: ScriptHash
    , envAppHex :: String
    , envAppPolicy :: PolicyID
    , envAppAddr :: Addr
    , envCtrlHash :: ByteString
    , envRefundBytes :: ByteString
    , envRefundAddr :: Addr
    , envDestAddr :: Addr
    , envDestCodec :: Address
    , envFoldRefundBytes :: ByteString
    }

-- ---------------------------------------------------------
-- The probe: LC01 against whatever blueprint was named
-- ---------------------------------------------------------

runProbe :: Env -> TxIn -> IO ()
runProbe env claimLCIn = do
    snap <- mustSnap env claimLCIn
    tx <-
        cancelBody
            env
            snap
            (envRefundBytes env)
            (envRefundAddr env)
            (snapCoin snap - flatFee)
            (mintBurn (envAppPolicy env) (envRefundBytes env))
            (Just (withdrawApprovalRedeemer env (envRefundBytes env)))
    emit
        "probe-build"
        ( "LC01 built exactly as the correspondence record describes: the \
          \claim carries the approval (asset name = stored refund 0x"
            <> hex (envRefundBytes env)
            <> "), Cancel presents that refund, the approval burns exactly \
               \-1, the refund pays the claim's lovelace to the bound \
               \destination, nothing else is wrong with the transaction"
        )
    result <- submitTx (envSubmit env) (addKeyWitness genesisSignKey tx)
    case result of
        Submitted _ ->
            emit
                "probe-wall"
                "the transaction was ACCEPTED: the mint purpose executed the \
                \burn — the wall this probe looks for is not there"
        Rejected reason -> do
            let reasonText = T.unpack (TE.decodeUtf8Lenient reason)
                phase2 = "PlutusFailure" `isInfixOf` reasonText
                namesApp = envAppHex env `isInfixOf` reasonText
            when (phase2 && namesApp) $
                emit
                    "probe-wall"
                    ( "WALL CONFIRMED — refused because: "
                        <> reasonText
                        <> " — every condition of LC01 holds, so this is the \
                           \mint purpose refusing the very burn the spend \
                           \purpose demands: one script whose two purposes \
                           \cannot compose in one transaction"
                    )
            unless (phase2 && namesApp) $
                emit
                    "probe-wall"
                    ( "refused, but not by the application validator in phase \
                      \2: "
                        <> reasonText
                    )

-- ---------------------------------------------------------
-- The ten rows
-- ---------------------------------------------------------

runRows :: Mode -> Env -> TxIn -> TxIn -> TxIn -> IO ()
runRows mode env claimLCIn claimLMIn claimFoldIn = do
    -- WR01 — the refund recorded at request time, read back on chain.
    rowWR01 env claimLCIn
    -- The LM group on claimLM.
    a1 <- rowLM01 env claimLMIn
    rowLM02 mode env a1
    rowLM03 env a1
    rowLM04 env a1
    -- LC03 rides A1: a claim without a withdraw approval.
    rowLC03 env a1
    -- LC01 consumes claimLC; LC06 replays against the consumed approval.
    signedLC01 <- rowLC01 env claimLCIn
    rowLC06 env claimLCIn signedLC01
    -- LC02 against claimFold (still carrying its approval), then the
    -- real fold, then LC04 against the folded record.
    claimFoldSnap <- mustSnap env claimFoldIn
    rowLC02 env claimFoldSnap
    recordSnap <- rowFold env claimFoldIn
    rowLC04 env recordSnap
    -- The final no-trace sweep after every refusal.
    finalNoTrace env a1 recordSnap
    emit
        "complete"
        ( "the LM/LC rows executed on a real devnet; every refusal \
          \attributed to its reason, the four proofs shown, the state \
          \after the refusals unchanged"
        )

-- ---------------------------------------------------------
-- WR01 — refund round-trip
-- ---------------------------------------------------------

rowWR01 :: Env -> TxIn -> IO ()
rowWR01 env claimLCIn = do
    snap <- mustSnap env claimLCIn
    let approvalQty = lookup (envRefundBytes env) (snapTokens snap)
    unless (approvalQty == Just 1) $
        failWith
            ( "WR01: the claim does not carry exactly one withdraw approval \
              \named by the recorded refund: observed "
                <> show approvalQty
            )
    decoded <- chainDatumOf env snap "WR01"
    unless
        ( canonicalAddress (controlAddress decoded)
            && nextControlCommitment decoded
                == nextControlCommitmentOf (addressBytes (controlAddress decoded))
        )
        $ failWith "WR01: the chain datum is not the recorded fixture"
    emit
        "row"
        ( "WR01-insert-request-refund-roundtrip: the refund recorded at \
          \request time round-trips on chain — recorded 0x"
            <> hex (envRefundBytes env)
            <> " (the mint redeemer's destination, controller-signed); bound \
               \on chain as the withdraw approval's asset name, quantity 1, \
               \riding claimLC="
            <> showIn claimLCIn
            <> " at the application validator 0x"
            <> envAppHex env
            <> "; the claim's four-field datum decodes with the merged codec; \
               \the round trip completes when LC01 pays this exact address"
        )

-- ---------------------------------------------------------
-- LM01 — maintenance accepts; preservation is proved
-- ---------------------------------------------------------

rowLM01 :: Env -> TxIn -> IO Snap
rowLM01 env claimIn = do
    snap <- mustSnap env claimIn
    current <- chainDatumOf env snap "LM01"
    let destCodec = envDestCodec env
        maintained = current {paymentDestination = SomeDestination destCodec}
    tx <- maintainTx env snap (Just (\d -> d {paymentDestination = SomeDestination destCodec})) True
    let signed = addKeyWitness genesisSignKey tx
    unless
        ( Set.singleton (addrWitnessKeyHash (envCtrlHash env))
            == (signed ^. bodyTxL . reqSignerHashesTxBodyL)
        )
        $ failWith "LM01: the controller must be the required signer"
    submitAccepted env "LM01" signed
    _ <- waitConfirmation (txIdHex signed <> " (LM01)")
    contIn <-
        mustFindUTxO (envProv env) (envAppAddr env) (txIdHex signed) "LM01 continuation"
    contSnap <- mustSnap env contIn
    decoded <- chainDatumOf env contSnap "LM01"
    -- Proof 1: preservation, field by field, read back from the chain.
    let diffs =
            concat
                [ [ "controlAddress changed"
                  | controlAddress decoded /= controlAddress current
                  ]
                , [ "nextControlCommitment changed"
                  | nextControlCommitment decoded
                      /= nextControlCommitment current
                  ]
                , [ "retirementQuorum changed"
                  | retirementQuorum decoded /= retirementQuorum current
                  ]
                ]
    unless (null diffs) $
        failWith
            ( "LM01-preservation: preserved fields were not preserved: "
                <> intercalate "; " diffs
            )
    unless (paymentDestination decoded == SomeDestination destCodec) $
        failWith "LM01-preservation: the payment destination was not maintained"
    assertChainBytes contSnap maintained "LM01"
    emit
        "row"
        ( "LM01-maintenance-accepts: accepted tx="
            <> txIdHex signed
            <> " continuation="
            <> showIn contIn
            <> " (signed maintenance changed the payment destination)"
        )
    emit
        "preservation"
        ( "LM01-preservation: read back from the chain with the merged codec \
          \and compared field by field against the pre-maintenance claim: \
          \controlAddress 0x"
            <> hex (addressBytes (controlAddress decoded))
            <> " unchanged; nextControlCommitment 0x"
            <> hex (nextControlCommitment decoded)
            <> " unchanged; retirementQuorum (threshold "
            <> show (quorumThreshold (retirementQuorum decoded))
            <> ", "
            <> show (length (quorumMembers (retirementQuorum decoded)))
            <> " member) unchanged; paymentDestination none -> 0x"
            <> hex (addressBytes destCodec)
            <> " (the only maintained field); the on-chain bytes equal the \
               \codec encoding of the maintained fixture"
        )
    pure contSnap

-- ---------------------------------------------------------
-- LM02..LM04 — the maintenance refusals
-- ---------------------------------------------------------

-- The v0.2.0 corpus's own tamper bytes (LM03's candidate commitment).
tamperedCommitment :: ByteString
tamperedCommitment =
    BS.pack
        [ 0x15, 0x61, 0xc1, 0x5b, 0x49, 0x80, 0x85, 0x7f
        , 0xb0, 0x6e, 0x4a, 0xb3, 0x5c, 0xc9, 0xbc, 0xec
        , 0xaf, 0x09, 0x0b, 0x0a, 0xa8, 0xbd, 0xef, 0x19
        , 0xf6, 0x33, 0x15, 0x65, 0xa3, 0x33, 0x20, 0x4f
        ]

rowLM02 :: Mode -> Env -> Snap -> IO ()
rowLM02 mode env a1 = case mode of
    ControlValid -> do
        -- The control: the same maintenance, made actually valid (the
        -- controller demanded and witnessed). It must succeed — and
        -- then the refusal guard must fail the run.
        tx <- maintainTx env a1 Nothing True
        result <- submitTx (envSubmit env) (addKeyWitness genesisSignKey tx)
        case result of
            Submitted _ ->
                failWith
                    ( "CONTROL valid-transaction: LM02's transaction, made \
                      \actually valid, SUCCEEDED — the guard did not refuse, \
                      \so this run fails as the control requires (a row's \
                      \transaction made actually valid must fail the run)"
                    )
            Rejected reason ->
                failWith
                    ( "CONTROL valid-transaction: the control transaction was \
                      \unexpectedly refused: "
                        <> T.unpack (TE.decodeUtf8Lenient reason)
                    )
    _ -> do
        tx <- maintainTx env a1 Nothing False
        expectRefused
            mode
            env
            "LM02-maintenance-unauthorized-refused"
            "controller-signature"
            ( "the controller's payment key hash is absent from the required \
              \signers (the row's witness is requiredSigners: []), so the \
              \validator's signature check refuses; the vkey witness present \
              \only pays the funding and collateral inputs"
            )
            tx
        noTrace env a1 "LM02"

rowLM03 :: Env -> Snap -> IO ()
rowLM03 env a1 = do
    tx <-
        maintainTx
            env
            a1
            (Just (\d -> d {nextControlCommitment = tamperedCommitment}))
            True
    expectRefused
        MainRun
        env
        "LM03-maintenance-field-tamper-refused"
        "preserved-field"
        ( "signed, but the continuation's next-control commitment was \
          \tampered with (the v0.2.0 corpus's own tamper bytes), so the \
          \validator's preservation equality refuses"
        )
        tx
    noTrace env a1 "LM03"

rowLM04 :: Env -> Snap -> IO ()
rowLM04 env a1 = do
    let extraMember = BS.map complement (envCtrlHash env)
    tx <-
        maintainTx
            env
            a1
            ( Just
                ( \d ->
                    d
                        { retirementQuorum =
                            (retirementQuorum d)
                                { quorumMembers =
                                    quorumMembers (retirementQuorum d)
                                        <> [extraMember]
                                }
                        }
                )
            )
            True
    expectRefused
        MainRun
        env
        "LM04-maintenance-quorum-alteration-refused"
        "quorum"
        ( "signed, but the continuation's retirement quorum was altered (an \
          \extra member), so the validator's preservation equality refuses"
        )
        tx
    noTrace env a1 "LM04"

-- ---------------------------------------------------------
-- LC03 — no approval, no cancellation
-- ---------------------------------------------------------

rowLC03 :: Env -> Snap -> IO ()
rowLC03 env a1 = do
    -- The claim carries no withdraw approval, so the tx carries no burn
    -- either: well-formed for phase 1, refused in phase 2 at the
    -- approval binding.
    tx <-
        cancelBody
            env
            a1
            (envRefundBytes env)
            (envRefundAddr env)
            smallRefundCoin
            mempty
            Nothing
    expectRefused
        MainRun
        env
        "LC03-insert-attestation-cancellation-refused"
        "withdraw-binding"
        ( "no withdraw approval rides the claim, so there is no stored \
          \destination to compare against and nothing to burn: the \
          \validator's approval-binding destructure refuses"
        )
        tx
    noTrace env a1 "LC03"

-- | Refund size for refusal cancellations: comfortably above min-ADA.
smallRefundCoin :: Integer
smallRefundCoin = 2_500_000

-- ---------------------------------------------------------
-- LC01 — cancellation accepts; the approval is consumed
-- ---------------------------------------------------------

rowLC01 :: Env -> TxIn -> IO ConwayTx
rowLC01 env claimLCIn = do
    snap <- mustSnap env claimLCIn
    let refund = snapCoin snap - flatFee
    tx <-
        cancelBody
            env
            snap
            (envRefundBytes env)
            (envRefundAddr env)
            refund
            (mintBurn (envAppPolicy env) (envRefundBytes env))
            (Just (withdrawApprovalRedeemer env (envRefundBytes env)))
    let signed = addKeyWitness genesisSignKey tx
    unless (Set.null (signed ^. bodyTxL . reqSignerHashesTxBodyL)) $
        failWith "LC01: the row's witness is requiredSigners: []"
    submitAccepted env "LC01" signed
    _ <- waitConfirmation (txIdHex signed <> " (LC01)")
    -- The mint is exactly the burn.
    let MultiAsset mintMA = signed ^. bodyTxL . mintTxBodyL
        burnQty =
            Map.lookup (envAppPolicy env) mintMA
                >>= Map.lookup (AssetName (SBS.toShort (envRefundBytes env)))
    unless (burnQty == Just (-1)) $
        failWith
            ( "LC01: the mint is not exactly the approval burn: "
                <> show burnQty
            )
    -- Proof 2: the approval is consumed — no longer on chain.
    let owed = snapCoin snap - feeOf signed
        feeOf t = let Coin c = t ^. bodyTxL . feeTxBodyL in c
    refundUtxos <- Cage.queryUTxOs (envProv env) (envRefundAddr env)
    let refundCoins = [c | (_, o) <- refundUtxos, let Coin c = o ^. coinTxOutL]
    unless (any (>= owed) refundCoins) $
        failWith
            ( "LC01: the refund did not land at the bound destination: owed "
                <> show owed
                <> ", observed "
                <> show refundCoins
            )
    appUtxos <- Cage.queryUTxOs (envProv env) (envAppAddr env)
    genesisUtxos <- Cage.queryUTxOs (envProv env) genesisAddr
    let approvalLiveIn o = case o ^. valueTxOutL of
            MaryValue _ (MultiAsset ma) ->
                case Map.lookup (envAppPolicy env) ma of
                    Just inner ->
                        isJust
                            ( Map.lookup
                                (AssetName (SBS.toShort (envRefundBytes env)))
                                inner
                            )
                    Nothing -> False
        approvalAnywhere =
            any (approvalLiveIn . snd) (appUtxos <> genesisUtxos <> refundUtxos)
    unless (not approvalAnywhere) $
        failWith
            ( "LC01: an approval token named by the LC refund binding is "
                <> "still live on chain"
            )
    emit
        "row"
        ( "LC01-cancellation-stored-refund-accepts: accepted tx="
            <> txIdHex signed
            <> " — Cancel presented the stored refund 0x"
            <> hex (envRefundBytes env)
            <> ", unsigned (requiredSigners: []), the approval burned exactly \
               \-1"
        )
    emit
        "consumed"
        ( "LC01-approval-consumed: the approval is consumed — burned exactly \
          \once in tx "
            <> txIdHex signed
            <> " and no longer on chain: no UTxO at the application validator \
               \carries any asset under the application policy 0x"
            <> envAppHex env
            <> " (mint supply +1 at request time, -1 here = 0); the refund of "
            <> show owed
            <> " lovelace owed was paid to the bound destination 0x"
            <> hex (envRefundBytes env)
            <> " and observed there"
        )
    pure signed

-- ---------------------------------------------------------
-- LC06 — the replay, against the genuinely consumed approval
-- ---------------------------------------------------------

rowLC06 :: Env -> TxIn -> ConwayTx -> IO ()
rowLC06 env claimIn signedLC01 = do
    appUtxos <- Cage.queryUTxOs (envProv env) (envAppAddr env)
    unless (not (any ((== claimIn) . fst) appUtxos)) $
        failWith "LC06: the claim is unexpectedly still live"
    emit
        "row"
        ( "LC06-cancellation-replay-refused: replaying LC01's exact \
          \cancellation tx="
            <> txIdHex signedLC01
            <> " against the genuinely consumed approval (the claim is no \
               \longer live)"
        )
    result <- submitTx (envSubmit env) signedLC01
    case result of
        Submitted _ ->
            failWith
                "LC06: the replay was ACCEPTED — a consumed approval \
                \authorized cancellation twice"
        Rejected reason -> do
            let reasonText = T.unpack (TE.decodeUtf8Lenient reason)
                allSpent = "All inputs are spent" `isInfixOf` reasonText
            unless allSpent $
                failWith
                    ( "LC06: reason mismatch — expected the ledger to refuse \
                      \the replay in phase 1 naming the consumed output "
                        <> txIdHex signedLC01
                        <> " (the ledger shape of request-unavailable) but the \
                           \node said <"
                        <> reasonText
                        <> ">"
                    )
            emit
                "row"
                ( "LC06-cancellation-replay-refused: REFUSED, reason matched \
                  \(model reason request-unavailable): "
                    <> reasonText
                    <> " — the ledger itself refuses in phase 1, naming the \
                       \consumed output: a consumed UTxO cannot be re-spent, \
                       \so the replay never reaches the validator; recorded as \
                       \exactly that, not dressed up as a validator refusal"
                )

-- ---------------------------------------------------------
-- LC02 — the redirected refund
-- ---------------------------------------------------------

rowLC02 :: Env -> Snap -> IO ()
rowLC02 env claimFoldSnap = do
    let redirectedAddr =
            enterpriseAddr
                (keyHashFromSignKey (mkSignKey "t56-redirected-key-seed-00000001"))
    tx <-
        cancelBody
            env
            claimFoldSnap
            (serialiseAddr redirectedAddr)
            redirectedAddr
            smallRefundCoin
            (mintBurn (envAppPolicy env) (envFoldRefundBytes env))
            (Just (withdrawApprovalRedeemer env (envFoldRefundBytes env)))
    expectRefused
        MainRun
        env
        "LC02-cancellation-redirect-refused"
        "withdraw-refund-address"
        ( "the presented refund differs from the stored one, so the \
          \validator's refund equality refuses; the transaction is otherwise \
          \exactly the accepted LC01 shape"
        )
        tx
    noTrace env claimFoldSnap "LC02"

-- ---------------------------------------------------------
-- The real fold, then LC04
-- ---------------------------------------------------------

rowFold :: Env -> TxIn -> IO Snap
rowFold env claimFoldIn = do
    snap <- mustSnap env claimFoldIn
    current <- chainDatumOf env snap "fold"
    tx <- foldBody env snap current
    let signed = addKeyWitness genesisSignKey tx
    submitAccepted env "fold" signed
    _ <- waitConfirmation (txIdHex signed <> " (fold)")
    recordIn <-
        mustFindUTxO (envProv env) (envAppAddr env) (txIdHex signed) "folded record"
    recordSnap <- mustSnap env recordIn
    emit
        "row"
        ( "fold: claimFold="
            <> showIn claimFoldIn
            <> " folded for real into record="
            <> showIn recordIn
            <> " tx="
            <> txIdHex signed
            <> " — the fold consumed the withdraw approval (burned exactly \
               \once at fold, the record inheriting the value minus it)"
        )
    pure recordSnap

rowLC04 :: Env -> Snap -> IO ()
rowLC04 env recordSnap = do
    tx <-
        cancelBody
            env
            recordSnap
            (envFoldRefundBytes env)
            (envRefundAddr env)
            smallRefundCoin
            mempty
            Nothing
    expectRefused
        MainRun
        env
        "LC04-folded-claim-cancellation-refused"
        "request-unavailable"
        ( "ran after a real fold: the fold consumed the approval (burned at \
          \fold), so the folded record carries no withdraw approval and the \
          \validator's approval-binding destructure refuses the cancellation"
        )
        tx
    noTrace env recordSnap "LC04"

-- ---------------------------------------------------------
-- The final no-trace sweep
-- ---------------------------------------------------------

finalNoTrace :: Env -> Snap -> Snap -> IO ()
finalNoTrace env a1 recordR = do
    now1 <- mustSnap env (snapIn a1)
    now2 <- mustSnap env (snapIn recordR)
    unless (sameSnap a1 now1) $ failWith "final: A1 moved"
    unless (sameSnap recordR now2) $ failWith "final: the folded record moved"
    emit
        "no-trace"
        ( "state unchanged after every refusal — no trace: A1="
            <> showIn (snapIn a1)
            <> " ("
            <> show (snapCoin a1)
            <> " lovelace, tokens "
            <> show (snapTokens a1)
            <> ", datum bytes unchanged) and folded record="
            <> showIn (snapIn recordR)
            <> " ("
            <> show (snapCoin recordR)
            <> " lovelace, tokens "
            <> show (snapTokens recordR)
            <> ", datum bytes unchanged); the refused transactions left the \
               \authenticated state exactly as it was"
        )
  where
    sameSnap a b =
        snapCoin a == snapCoin b
            && snapTokens a == snapTokens b
            && snapDatum a == snapDatum b

-- ---------------------------------------------------------
-- Refusal attribution (the #41 discipline)
-- ---------------------------------------------------------

expectRefused ::
    Mode ->
    Env ->
    String ->
    String ->
    String ->
    ConwayTx ->
    IO ()
expectRefused mode env rowName modelReason guard tx = do
    let signed = addKeyWitness genesisSignKey tx
        wrongReasonMode = mode == ControlWrongReason
        expectedMarker
            | wrongReasonMode = wrongReasonMarker
            | otherwise = envAppHex env
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
                        <> ": expected-rejection-reason <phase-2 PlutusFailure \
                           \naming the application validator> but the node \
                           \rejected with <"
                        <> reasonText
                        <> "> — a phase-1 refusal proves nothing about the guard"
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
                ( rowName
                    <> ": REFUSED, reason matched (model reason "
                    <> modelReason
                    <> "; phase-2 PlutusFailure naming the application validator \
                       \0x"
                    <> envAppHex env
                    <> "): "
                    <> reasonText
                    <> " — "
                    <> guard
                )

-- ---------------------------------------------------------
-- Transaction builders (all hand-balanced: flat fee, change output,
-- max declared units, integrity sealed once)
-- ---------------------------------------------------------

-- | The maintenance transaction: spend the claim with a Maintain
-- redeemer, continue the record at the application validator with
-- @contDatum@, pay the flat fee from the funding input. When
-- @demandsController@, the body demands the controller's signature.
maintainTx ::
    Env ->
    Snap ->
    Maybe (NamingDatum -> NamingDatum) ->
    -- | override the continuation datum (Nothing = identity)
    Bool ->
    -- | demand the controller's signature
    IO ConwayTx
maintainTx env snap overrideM demanded = do
    current <- chainDatumOf env snap "LM"
    let contDatum = maybe current ($ current) overrideM
    (fund, collateral) <- takeFundCollateral env
    let inputs = Set.fromList [snapIn snap, fst fund]
        spendIdx = spendingIndex (snapIn snap) inputs
        redeemers =
            Redeemers
                ( Map.singleton
                    (ConwaySpending (AsIx spendIdx))
                    (Data redeemerMaintain, maxUnits)
                )
        integrity = computeScriptIntegrity (envPp env) redeemers
        contOut =
            scriptOut (envPp env) (envAppAddr env) (snapCoin snap) mempty contDatum
        change = changeOut (snapCoin snap + coinOf fund) flatFee [contOut]
        body =
            mkBasicTxBody
                & inputsTxBodyL .~ inputs
                & collateralInputsTxBodyL .~ Set.singleton (fst collateral)
                & outputsTxBodyL .~ StrictSeq.fromList [contOut, change]
                & feeTxBodyL .~ Coin flatFee
                & reqSignerHashesTxBodyL
                    .~ ( if demanded
                            then Set.singleton (addrWitnessKeyHash (envCtrlHash env))
                            else Set.empty
                       )
                & scriptIntegrityHashTxBodyL .~ integrity
    pure $
        ( mkBasicTx body
            & witsTxL . scriptTxWitsL
                .~ Map.singleton (envScriptHash env) (envScript env)
            & witsTxL . rdmrsTxWitsL .~ redeemers
        )
  where
    coinOf (_, o) = let Coin c = o ^. coinTxOutL in c

-- | The cancellation transaction: spend the claim with a Cancel
-- redeemer presenting @presented@, pay a refund output to
-- @refundAddr@ carrying @refundCoin@, mint @mint@ (with @mintRdmr@
-- when minting or burning under the policy).
cancelBody ::
    Env ->
    Snap ->
    -- | the presented refund
    ByteString ->
    -- | the refund output address
    Addr ->
    Integer ->
    MultiAsset ->
    Maybe PLC.Data ->
    IO ConwayTx
cancelBody env snap presented refundAddr refundCoin mint mintRdmr = do
    (fund, collateral) <- takeFundCollateral env
    let inputs = Set.fromList [snapIn snap, fst fund]
        spendIdx = spendingIndex (snapIn snap) inputs
        spendEntry = (Data (redeemerCancel presented), maxUnits)
        redeemers = case mintRdmr of
            Just mr ->
                Redeemers $
                    Map.fromList
                        [ (ConwaySpending (AsIx spendIdx), spendEntry)
                        , (ConwayMinting (AsIx 0), (Data mr, maxUnits))
                        ]
            Nothing ->
                Redeemers (Map.singleton (ConwaySpending (AsIx spendIdx)) spendEntry)
        integrity = computeScriptIntegrity (envPp env) redeemers
        refundOut =
            plainOut (envPp env) refundAddr refundCoin
        change =
            changeOut (snapCoin snap + coinOf fund) flatFee [refundOut]
        body =
            mkBasicTxBody
                & inputsTxBodyL .~ inputs
                & collateralInputsTxBodyL .~ Set.singleton (fst collateral)
                & outputsTxBodyL .~ StrictSeq.fromList [refundOut, change]
                & feeTxBodyL .~ Coin flatFee
                & mintTxBodyL .~ mint
                & scriptIntegrityHashTxBodyL .~ integrity
    pure $
        ( mkBasicTx body
            & witsTxL . scriptTxWitsL
                .~ Map.singleton (envScriptHash env) (envScript env)
            & witsTxL . rdmrsTxWitsL .~ redeemers
        )
  where
    coinOf (_, o) = let Coin c = o ^. coinTxOutL in c

-- | The real fold: spend the claim with a Fold redeemer, continue the
-- record at the application validator with the same datum, burn the
-- approval exactly once.
foldBody :: Env -> Snap -> NamingDatum -> IO ConwayTx
foldBody env snap current = do
    (fund, collateral) <- takeFundCollateral env
    let inputs = Set.fromList [snapIn snap, fst fund]
        spendIdx = spendingIndex (snapIn snap) inputs
        redeemers =
            Redeemers $
                Map.fromList
                    [
                        ( ConwaySpending (AsIx spendIdx)
                        , (Data (PLC.Constr 2 [PLC.List []]), maxUnits)
                        )
                    ,
                        ( ConwayMinting (AsIx 0)
                        , ( Data (withdrawApprovalRedeemer env (envFoldRefundBytes env))
                          , maxUnits
                          )
                        )
                    ]
        integrity = computeScriptIntegrity (envPp env) redeemers
        recordOut =
            scriptOut (envPp env) (envAppAddr env) (snapCoin snap) mempty current
        change = changeOut (snapCoin snap + coinOf fund) flatFee [recordOut]
        body =
            mkBasicTxBody
                & inputsTxBodyL .~ inputs
                & collateralInputsTxBodyL .~ Set.singleton (fst collateral)
                & outputsTxBodyL .~ StrictSeq.fromList [recordOut, change]
                & feeTxBodyL .~ Coin flatFee
                & mintTxBodyL .~ mintBurn (envAppPolicy env) (envFoldRefundBytes env)
                & scriptIntegrityHashTxBodyL .~ integrity
    pure $
        ( mkBasicTx body
            & witsTxL . scriptTxWitsL
                .~ Map.singleton (envScriptHash env) (envScript env)
            & witsTxL . rdmrsTxWitsL .~ redeemers
        )
  where
    coinOf (_, o) = let Coin c = o ^. coinTxOutL in c

-- | Mint redeemer @WithdrawApproval { controller, destination }@ —
-- this run's controller binding @destination@.
withdrawApprovalRedeemer :: Env -> ByteString -> PLC.Data
withdrawApprovalRedeemer env destination =
    PLC.Constr 0 [PLC.B (envCtrlHash env), PLC.B destination]

-- | An output at the application validator carrying @tokens@ and the
-- inline naming datum, sized at least min-ADA plus margin.
scriptOut ::
    PParams ConwayEra ->
    Addr ->
    Integer ->
    Map.Map PolicyID (Map.Map AssetName Integer) ->
    NamingDatum ->
    TxOut ConwayEra
scriptOut pp addr coin tokens datum =
    let probe :: TxOut ConwayEra
        probe = mkBasicTxOut addr (MaryValue (Coin 0) (MultiAsset tokens))
        minCoin = let Coin c = getMinCoinTxOut pp probe in c
        finalCoin = max coin (minCoin + 1_000_000)
     in mkBasicTxOut
            addr
            (MaryValue (Coin finalCoin) (MultiAsset tokens))
            & datumTxOutL .~ mkInlineDatum (namingDataToData datum)

plainOut :: PParams ConwayEra -> Addr -> Integer -> TxOut ConwayEra
plainOut pp addr coin =
    let probe :: TxOut ConwayEra
        probe = mkBasicTxOut addr (MaryValue (Coin 0) mempty)
        minCoin = let Coin c = getMinCoinTxOut pp probe in c
        finalCoin = max coin (minCoin + 1_000_000)
     in mkBasicTxOut addr (MaryValue (Coin finalCoin) mempty)

changeOut ::
    -- | total input lovelace
    Integer ->
    -- | fee
    Integer ->
    [TxOut ConwayEra] ->
    TxOut ConwayEra
changeOut inCoin fee outs =
    let spent = sum [c | o <- outs, let Coin c = o ^. coinTxOutL]
        change = inCoin - fee - spent
     in if change <= 1_000_000
            then error "naming-rows: change underflow while balancing"
            else mkBasicTxOut genesisAddr (MaryValue (Coin change) mempty)

-- ---------------------------------------------------------
-- Setup transactions
-- ---------------------------------------------------------

-- | Setup 1: mint the withdraw approval (the refund recorded at
-- request time, controller-signed) and create claimLC (with the
-- approval) and claimLM (without one).
setupTwoClaims ::
    Env ->
    NamingDatum ->
    NamingDatum ->
    IO (String, TxIn, TxIn)
setupTwoClaims env datumLC datumLM = do
    (fund, collateral) <- takeFundCollateral env
    let approvalTokens =
            Map.singleton
                (envAppPolicy env)
                (Map.singleton (AssetName (SBS.toShort (envRefundBytes env))) 1)
        claimLCOut =
            scriptOut (envPp env) (envAppAddr env) claimCoin approvalTokens datumLC
        claimLMOut = scriptOut (envPp env) (envAppAddr env) claimCoin mempty datumLM
        redeemers =
            Redeemers
                ( Map.singleton
                    (ConwayMinting (AsIx 0))
                    (Data (withdrawApprovalRedeemer env (envRefundBytes env)), maxUnits)
                )
        integrity = computeScriptIntegrity (envPp env) redeemers
        change = changeOut (coinOf fund) flatFee [claimLCOut, claimLMOut]
        body =
            mkBasicTxBody
                & inputsTxBodyL .~ Set.fromList [fst fund]
                & collateralInputsTxBodyL .~ Set.singleton (fst collateral)
                & outputsTxBodyL .~ StrictSeq.fromList [claimLCOut, claimLMOut, change]
                & feeTxBodyL .~ Coin flatFee
                & mintTxBodyL .~ MultiAsset approvalTokens
                & reqSignerHashesTxBodyL
                    .~ Set.singleton (addrWitnessKeyHash (envCtrlHash env))
                & scriptIntegrityHashTxBodyL .~ integrity
        tx =
            mkBasicTx body
                & witsTxL . scriptTxWitsL
                    .~ Map.singleton (envScriptHash env) (envScript env)
                & witsTxL . rdmrsTxWitsL .~ redeemers
    let signed = addKeyWitness genesisSignKey tx
    submitAccepted env "setup-claims" signed
    utxos <- queryAfterDelay env
    let mine = sortBy (comparing (txInIndex . fst)) (utxosByTxId utxos (txIdHex signed))
    claimLCIn <- pickClaim mine True "claimLC"
    claimLMIn <- pickClaim mine False "claimLM"
    pure (txIdHex signed, claimLCIn, claimLMIn)
  where
    coinOf (_, o) = let Coin c = o ^. coinTxOutL in c
    pickClaim candidates wantApproval label = do
        snaps <- traverse (mustSnap env . fst) candidates
        let matches =
                [ fst cin
                | (cin, s) <- zip candidates snaps
                , (not (null (snapTokens s)) == wantApproval)
                ]
        case matches of
            (cin : _) -> pure cin
            [] -> failWith ("setup: could not distinguish " <> label)

-- | Setup 2: a second approval and claimFold — the claim the LC04
-- proof folds for real. One approval per transaction: the mint
-- purpose mints exactly one.
setupFoldClaim ::
    Env ->
    NamingDatum ->
    IO (String, TxIn)
setupFoldClaim env datumFold = do
    (fund, collateral) <- takeFundCollateral env
    let approvalTokens =
            Map.singleton
                (envAppPolicy env)
                (Map.singleton (AssetName (SBS.toShort (envFoldRefundBytes env))) 1)
        claimOut =
            scriptOut (envPp env) (envAppAddr env) claimCoin approvalTokens datumFold
        redeemers =
            Redeemers
                ( Map.singleton
                    (ConwayMinting (AsIx 0))
                    (Data (withdrawApprovalRedeemer env (envFoldRefundBytes env)), maxUnits)
                )
        integrity = computeScriptIntegrity (envPp env) redeemers
        change = changeOut (coinOf fund) flatFee [claimOut]
        body =
            mkBasicTxBody
                & inputsTxBodyL .~ Set.fromList [fst fund]
                & collateralInputsTxBodyL .~ Set.singleton (fst collateral)
                & outputsTxBodyL .~ StrictSeq.fromList [claimOut, change]
                & feeTxBodyL .~ Coin flatFee
                & mintTxBodyL .~ MultiAsset approvalTokens
                & reqSignerHashesTxBodyL
                    .~ Set.singleton (addrWitnessKeyHash (envCtrlHash env))
                & scriptIntegrityHashTxBodyL .~ integrity
        tx =
            mkBasicTx body
                & witsTxL . scriptTxWitsL
                    .~ Map.singleton (envScriptHash env) (envScript env)
                & witsTxL . rdmrsTxWitsL .~ redeemers
    let signed = addKeyWitness genesisSignKey tx
    submitAccepted env "setup-fold-claim" signed
    utxos <- queryAfterDelay env
    let mine = sortBy (comparing (txInIndex . fst)) (utxosByTxId utxos (txIdHex signed))
    case mine of
        ((cin, _) : _) -> pure (txIdHex signed, cin)
        [] ->
            failWith "setup: claimFold not found at the application validator"
  where
    coinOf (_, o) = let Coin c = o ^. coinTxOutL in c

-- | Split the genesis wallet into funding and collateral UTxOs.
splitGenesis :: Cage.Provider IO -> Submitter IO -> IO [(TxIn, TxOut ConwayEra)]
splitGenesis prov submit = do
    utxos <- Cage.queryUTxOs prov genesisAddr
    (bigIn, bigOut) <- case sortBy (comparing outSortKey) utxos of
        (b : _) -> pure b
        [] -> failWith "split: the genesis wallet has no UTxOs"
    let Coin total = bigOut ^. coinTxOutL
        perSplit = 2_000_000_000
        nSplits = 24 :: Integer
        fee = 1_000_000
        change = total - nSplits * perSplit - fee
    unless (change > 1_000_000) $
        failWith "split: the genesis wallet cannot fund the splits"
    let splitOuts =
            [ mkBasicTxOut genesisAddr (MaryValue (Coin perSplit) mempty)
            | _ <- [1 .. nSplits]
            ]
        changeOut' = mkBasicTxOut genesisAddr (MaryValue (Coin change) mempty)
        body =
            mkBasicTxBody
                & inputsTxBodyL .~ Set.singleton bigIn
                & outputsTxBodyL .~ StrictSeq.fromList (splitOuts <> [changeOut'])
                & feeTxBodyL .~ Coin fee
        splitTx = mkBasicTx body
    result <- submitTx submit (addKeyWitness genesisSignKey splitTx)
    case result of
        Submitted _ -> pure ()
        Rejected reason ->
            failWith
                ( "split: refused: "
                    <> T.unpack (TE.decodeUtf8Lenient reason)
                )
    threadDelay 5_000_000
    after <- Cage.queryUTxOs prov genesisAddr
    let txid = txIdHex splitTx
        mine =
            [ (i, o)
            | (i, o) <- after
            , txInTxIdHex i == txid
            , txInIndex i < nSplits
            ]
    unless (toInteger (length mine) == nSplits) $
        failWith
            ( "split: expected "
                <> show nSplits
                <> " funding UTxOs, found "
                <> show (length mine)
            )
    pure (sortBy (comparing (txInIndex . fst)) mine)
  where
    outSortKey (i, _) = (txInTxIdHex i, txInIndex i)

txInTxIdHex :: TxIn -> String
txInTxIdHex (TxIn (TxId h) _) = hex (hashToBytes (extractHash h))

txInIndex :: TxIn -> Integer
txInIndex (TxIn _ (TxIx i)) = toInteger i

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

-- ---------------------------------------------------------
-- Chain reading
-- ---------------------------------------------------------

data Snap = Snap
    { snapIn :: TxIn
    , snapCoin :: Integer
    , snapTokens :: [(ByteString, Integer)]
    , snapDatum :: Maybe PLC.Data
    }

mustSnap :: Env -> TxIn -> IO Snap
mustSnap env txin = do
    utxos <- Cage.queryUTxOs (envProv env) (envAppAddr env)
    case filter ((== txin) . fst) utxos of
        [(_, o)] -> do
            let Coin c = o ^. coinTxOutL
                tokens = case o ^. valueTxOutL of
                    MaryValue _ (MultiAsset ma) ->
                        maybe
                            []
                            ( Map.toAscList
                                . Map.mapKeys (SBS.fromShort . assetNameBytes)
                            )
                            (Map.lookup (envAppPolicy env) ma)
                datum = datumDataOf o
            pure (Snap txin c tokens datum)
        _ ->
            failWith
                ( "snapshot: "
                    <> showIn txin
                    <> " is not live at the application validator"
                )

mustFindUTxO ::
    Cage.Provider IO ->
    Addr ->
    String ->
    String ->
    IO TxIn
mustFindUTxO prov addr txid label = do
    utxos <- Cage.queryUTxOs prov addr
    let mine = sortBy (comparing (txInIndex . fst)) (utxosByTxId utxos txid)
    case mine of
        ((i, _) : _) -> pure i
        [] ->
            failWith
                ( label
                    <> ": no output of tx "
                    <> txid
                    <> " is live at the application validator"
                )

utxosByTxId ::
    [(TxIn, TxOut ConwayEra)] ->
    String ->
    [(TxIn, TxOut ConwayEra)]
utxosByTxId utxos txid = filter ((== txid) . txInTxIdHex . fst) utxos

datumDataOf :: TxOut ConwayEra -> Maybe PLC.Data
datumDataOf out = case out ^. datumTxOutL of
    Datum bd -> let Data d = binaryDataToData bd in Just d
    _ -> Nothing

-- | On-chain Plutus data as the codec's wire value: exactly the shapes
-- the contract serialises.
wireOf :: PLC.Data -> Maybe WireData
wireOf (PLC.Constr i fs)
    | i >= 0 && i <= 6 = Constr (fromIntegral i) <$> traverse wireOf fs
wireOf (PLC.B b) = Just (WBytes b)
wireOf (PLC.I n) = Just (WInt n)
wireOf (PLC.List xs) = WList <$> traverse wireOf xs
wireOf _ = Nothing

chainDatumOf :: Env -> Snap -> String -> IO NamingDatum
chainDatumOf _env snap label =
    case snapDatum snap >>= wireOf >>= decodeNamingDatum of
        Just d -> pure d
        Nothing ->
            failWith
                ( label
                    <> ": the chain datum does not decode as a naming datum"
                )

assertChainBytes :: Snap -> NamingDatum -> String -> IO ()
assertChainBytes snap expected label =
    case snapDatum snap >>= wireOf >>= serialiseWireData of
        Just chainBytes
            | Just codecBytes <- serialiseNamingDatum expected ->
                unless (chainBytes == codecBytes) $
                    failWith
                        ( label
                            <> ": the on-chain bytes are not the codec encoding: \
                               \chain=0x"
                                <> hex chainBytes
                                <> " codec=0x"
                                <> hex codecBytes
                        )
        _ ->
            failWith
                ( label
                    <> ": the chain datum cannot be serialised as the contract's \
                       \wire bytes"
                )

noTrace :: Env -> Snap -> String -> IO ()
noTrace env before label = do
    now <- mustSnap env (snapIn before)
    unless
        ( snapCoin now == snapCoin before
            && snapTokens now == snapTokens before
            && snapDatum now == snapDatum before
        )
        $ failWith
            ( label
                <> ": the refused transaction moved the state at "
                <> showIn (snapIn before)
            )
    emit
        "no-trace"
        ( label
            <> ": state unchanged — no trace: "
            <> showIn (snapIn before)
            <> " still holds "
            <> show (snapCoin now)
            <> " lovelace, tokens "
            <> show (snapTokens now)
            <> ", datum bytes unchanged"
        )

-- ---------------------------------------------------------
-- Redeemer and datum encodings (exact structural mirrors of the
-- Aiken types)
-- ---------------------------------------------------------

namingDataToData :: NamingDatum -> PLC.Data
namingDataToData nd =
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
    destinationData (SomeDestination a) = PLC.Constr 1 [PLC.B (addressBytes a)]
    quorumData q =
        PLC.Constr
            0
            [ PLC.I (quorumThreshold q)
            , PLC.List (map PLC.B (quorumMembers q))
            ]

redeemerMaintain :: PLC.Data
redeemerMaintain = PLC.Constr 0 []

redeemerCancel :: ByteString -> PLC.Data
redeemerCancel presentedRefund = PLC.Constr 1 [PLC.B presentedRefund]

mintBurn :: PolicyID -> ByteString -> MultiAsset
mintBurn policy name =
    MultiAsset
        (Map.singleton policy (Map.singleton (AssetName (SBS.toShort name)) (-1)))

-- ---------------------------------------------------------
-- Submission helpers
-- ---------------------------------------------------------

submitAccepted :: Env -> String -> ConwayTx -> IO ()
submitAccepted env label signed =
    submitTx (envSubmit env) signed >>= \case
        Submitted _ ->
            emit "submit" (label <> ": accepted tx=" <> txIdHex signed)
        Rejected reason ->
            failWith
                ( label
                    <> ": the node refused an accepting row: "
                    <> T.unpack (TE.decodeUtf8Lenient reason)
                )

waitConfirmation :: String -> IO ()
waitConfirmation what = do
    threadDelay 5_000_000
    emit "confirm" ("confirmed on chain: " <> what)

queryAfterDelay :: Env -> IO [(TxIn, TxOut ConwayEra)]
queryAfterDelay env = do
    threadDelay 5_000_000
    Cage.queryUTxOs (envProv env) (envAppAddr env)

-- ---------------------------------------------------------
-- Pinned identity
-- ---------------------------------------------------------

newtype NamingManifest = NamingManifest
    { manifestValidators :: [ManifestPin]
    }

data ManifestPin = ManifestPin
    { mpTitle :: T.Text
    , mpHash :: T.Text
    }

instance FromJSON NamingManifest where
    parseJSON = withObject "NamingManifest" $ \o ->
        NamingManifest <$> o .: "validators"

instance FromJSON ManifestPin where
    parseJSON = withObject "ManifestPin" $ \o ->
        ManifestPin <$> o .: "title" <*> o .: "hash"

-- | Fail the run unless every manifest pin under
-- @application.application@ equals the hash this run loaded.
checkPinnedApplication :: String -> IO ()
checkPinnedApplication appHex = do
    path <-
        fromMaybe "../naming-onchain/script-identity.json"
            <$> lookupEnv "NAMING_SCRIPT_IDENTITY"
    bytes <- BS.readFile path
    manifest <- either failWith pure (eitherDecode' (BSL.fromStrict bytes))
    let pins =
            [ mpHash p
            | p <- manifestValidators manifest
            , "application.application" `T.isPrefixOf` mpTitle p
            ]
    unless (length pins >= 3) $
        failWith
            "identity: fewer than three application.application pins in the \
            \manifest"
    unless (all (== T.pack appHex) pins) $
        failWith
            ( "identity: the manifest pins "
                <> show pins
                <> " but this run's blueprint hashes to 0x"
                <> appHex
            )

-- ---------------------------------------------------------
-- Narration and plumbing
-- ---------------------------------------------------------

emit :: String -> String -> IO ()
emit step detail = putStrLn ("[lmlc] " <> step <> ": " <> detail)

failWith :: String -> IO a
failWith msg = throwIO (ErrorCall ("naming-rows: " <> msg))

requireEnv :: String -> IO String
requireEnv name =
    lookupEnv name
        >>= maybe (failWith ("missing environment variable " <> name)) pure

hex :: ByteString -> String
hex = T.unpack . TE.decodeUtf8 . Base16.encode

txIdHex :: ConwayTx -> String
txIdHex tx = let TxId h = txIdTx tx in hex (hashToBytes (extractHash h))

showIn :: TxIn -> String
showIn (TxIn (TxId h) (TxIx i)) =
    hex (hashToBytes (extractHash h)) <> "#" <> show i

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

-- | Domain-separated next-control commitment (docs/naming-lifecycle.md).
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
