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
import Control.Exception (
    ErrorCall (..),
    SomeException,
    displayException,
    throwIO,
    try,
 )
import Control.Monad (unless)
import Crypto.Hash (Blake2b_256, Digest, hash)
import Data.Aeson (FromJSON (..), eitherDecode', withObject, (.:))
import Data.Bits (complement)
import Data.ByteArray (convert)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as Base16
import Data.ByteString.Lazy qualified as BSL
import Data.ByteString.Short qualified as SBS
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.List (intercalate, isInfixOf, sortBy, sortOn)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, listToMaybe)
import Data.Ord (Down (..), comparing)
import Data.Sequence.Strict qualified as StrictSeq
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Lens.Micro ((&), (.~), (^.))
import PlutusCore.Data qualified as PLC
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..), exitWith)
import System.IO (BufferMode (..), hPutStrLn, hSetBuffering, stderr, stdout)

import Cardano.Crypto.Hash.Class (hashToBytes)
import Cardano.Ledger.Address (Addr (..), serialiseAddr)
import Cardano.Ledger.Alonzo.Scripts (AsIx (..))
import Cardano.Ledger.Api.Scripts.Data (Data (..), Datum (..), binaryDataToData, hashData)
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

import Cardano.Node.Client.E2E.Setup (
    Ed25519DSIGN,
    SignKeyDSIGN,
    addKeyWitness,
    enterpriseAddr,
    keyHashFromSignKey,
    mkSignKey,
 )
import Cardano.Node.Client.Ledger (ConwayTx)
import Cardano.Node.Client.Submitter (SubmitResult (..), Submitter (..))
import Naming.Datum
import Naming.Wire (
    Address (..),
    WireData (..),
    addressBytes,
    decodeAddress,
    serialiseWireData,
 )
import Singular.Registry.AssetName (deriveAssetName)
import Singular.Registry.Blueprint (
    applyBytesParam,
    applyIntParam,
    extractCompiledCode,
    loadBlueprint,
 )
import Singular.Registry.Config (CageConfig (..))
import Singular.Registry.Ledger (
    AssetName (..),
    Coin (..),
    ConwayEra,
    PParams,
    TokenId (..),
 )
import Singular.Registry.Node (
    NodeSession (..),
    awaitChain,
    awaitTx,
    confirmationDelay,
    funderAddr,
    funderSignKey,
    withNode,
 )
import Singular.Registry.Provider qualified as Cage
import Singular.Registry.Trie (TrieManager (..))
import Singular.Registry.Trie.PureManager (mkPureTrieManager)
import Singular.Registry.TxBuilder.Boot (bootTokenImpl)
import Singular.Registry.TxBuilder.Internal (
    addrKeyHashBytes,
    addrWitnessKeyHash,
    appliedApplicationBytes,
    cagePolicyIdFromCfg,
    computeScriptHash,
    computeScriptIntegrity,
    leafActive,
    mkInlineDatum,
    onChainTokenId,
    scriptFromBytes,
    scriptHashBytes,
    spendingIndex,
    txInToRef,
 )
import Singular.Registry.TxBuilder.Update (
    bookEdgeTx,
    foldRefScripts,
    publishRefScriptTx,
    refScriptBatches,
    registryContextFor,
    updateTokenWithDuties,
 )
import Singular.Registry.Types (OnChainOperation (..))

-- ---------------------------------------------------------
-- Run modes
-- ---------------------------------------------------------

data Mode
    = -- | the four maintenance rows.
      MainRun
    | {- | LM02's transaction made actually valid: it must succeed,
      and the refusal guard must then fail the run (exit 1).
      -}
      ControlValid
    | {- | every refusal matched against a marker that cannot occur:
      the matcher must fail the run naming what came back.
      -}
      ControlWrongReason
    deriving (Eq, Show)

readMode :: IO Mode
readMode =
    lookupEnv "LMLC_CONTROL" >>= \case
        Just "valid" -> pure ControlValid
        Just "wrong-reason" -> pure ControlWrongReason
        Just other
            | not (null other) ->
                failWith ("unknown LMLC_CONTROL value " <> other)
        _ -> pure MainRun

{- | The marker the wrong-reason control matches refusals against: by
construction no node reason can contain it, so a matched reason can
never close a row and the control must fail.
-}
wrongReasonMarker :: String
wrongReasonMarker =
    "wrong-reason-control marker that no node reason can ever contain"

-- ---------------------------------------------------------
-- Ledger-shape constants
-- ---------------------------------------------------------

{- | Flat fee for hand-balanced transactions. Generously above the
devnet's minimum (~0.2 ada for a small tx) and above the fee the
declared max execution units price in (~8.8 ada).
-}
flatFee :: Integer
flatFee = 10_000_000

{- | maxTxExUnits from the checked-in devnet genesis
(e2e-test/genesis/alonzo-genesis.json). Declared units must be <=
this; refusal transactions declare exactly it so an oversized real
cost can never reject the tx before its validator refuses.
| Declared units for hand-balanced transactions. Generous enough
that a full datum decode plus the row's guard (~100M steps, ~1.5M
mem measured on chain) runs to completion, small enough that a
runaway evaluation hits the wall in seconds instead of minutes.
-}
maxUnits :: ExUnits
maxUnits = ExUnits 3_000_000 200_000_000

{- | What a booking locks: the tip the registry keeps plus the deposit
that rides to the destination the approval bound. The record the fold
creates holds that deposit minus the tip, and it must clear min-UTxO
carrying its active witness token and the naming datum.
-}
recordBond :: Integer
recordBond = 25_000_000

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
                "issue #56: the LM maintenance rows on a real ledger, \
                \against a record a real registry fold created"
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
    -- #157: a record is not made by hand any more. It is what a fold of
    -- the registry leaves behind, so this runner boots a cage from the
    -- registry blueprint and certifies its activation under the naming
    -- one. Both partitions are inputs.
    registryPath <- requireEnv "REGISTRY_BLUEPRINT"
    blueprintPath <- requireEnv "NAMING_BLUEPRINT"
    outcome <-
        try (runMode mode registryPath blueprintPath) ::
            IO (Either SomeException ())
    case outcome of
        Right () -> pure ()
        Left e -> do
            hPutStrLn stderr ("naming-rows: FAILED: " <> displayException e)
            exitWith (ExitFailure 1)

-- ---------------------------------------------------------
-- The run
-- ---------------------------------------------------------

runMode :: Mode -> FilePath -> FilePath -> IO ()
runMode mode registryPath blueprintPath = do
    ebp <- loadBlueprint blueprintPath
    bp <- either failWith pure ebp
    appBytes <- case extractCompiledCode "application.application" bp of
        Just bytes -> pure bytes
        Nothing ->
            failWith
                "application.application compiled code not found in the \
                \naming blueprint"
    witnessBytes <- case extractCompiledCode "witness.witness.mint" bp of
        Just bytes -> pure bytes
        Nothing ->
            failWith
                "witness.witness.mint compiled code not found in the \
                \naming blueprint"
    erbp <- loadBlueprint registryPath
    rbp <- either failWith pure erbp
    stateBytes <- case extractCompiledCode "state.state" rbp of
        Just bytes -> pure bytes
        Nothing ->
            failWith "state.state compiled code not found in the registry blueprint"
    requestBytes <- case extractCompiledCode "request.request" rbp of
        Just bytes -> pure bytes
        Nothing ->
            failWith "request.request compiled code not found in the registry blueprint"
    withNode $ \sess -> do
        let prov = nsProvider sess
            submit = nsSubmitter sess
            pp = nsPParams sess
        let script = scriptFromBytes "naming-application" appBytes
            appHash = computeScriptHash appBytes
            appHex = hex (scriptHashBytes appHash)
            appAddr = Addr Testnet (ScriptHashObj appHash) StakeRefNull
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
            recordDatum =
                NamingDatum
                    { controlAddress = ctrlAddrCodec
                    , paymentDestination = NoDestination
                    , nextControlCommitment =
                        nextControlCommitmentOf ctrlAddrBytes
                    , retirementQuorum =
                        RetirementQuorum
                            { quorumMembers = [ctrlHash]
                            , quorumThreshold = 1
                            }
                    }
        -- #157: the record the LM rows maintain is not placed by hand.
        -- It is what a real registry fold leaves behind — the cage boots,
        -- an activation of one key is certified by the application
        -- policy and booked, and the fold delivers the active witness
        -- token to the application's own address under the record datum
        -- the approval bound.
        --
        -- It runs BEFORE the funding split: the registry builders take
        -- their own inputs from this wallet, and an output promised to
        -- the row pool must not be one of them.
        recordIn <-
            setupFoldedRecord
                prov
                submit
                pp
                appAddr
                script
                appHex
                stateBytes
                requestBytes
                appBytes
                witnessBytes
                recordDatum
        -- Split what is left into funding and collateral UTxOs.
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
                    , envAppAddr = appAddr
                    , envCtrlHash = ctrlHash
                    , envDestCodec = destAddrCodec
                    }
        runRows mode env recordIn

-- | The environment every row builds against.
data Env = Env
    { envProv :: Cage.Provider IO
    , envSubmit :: Submitter IO
    , envPp :: PParams ConwayEra
    , envPool :: IORef [(TxIn, TxOut ConwayEra)]
    , envScript :: Script ConwayEra
    , envScriptHash :: ScriptHash
    , envAppHex :: String
    , envAppAddr :: Addr
    , envCtrlHash :: ByteString
    , envDestCodec :: Address
    }

-- ---------------------------------------------------------
-- The four maintenance rows
-- ---------------------------------------------------------

{- | The wallet every actor of this run is funded from. On the factory
devnet it is the genesis UTxO key, as it always was; in external-node
mode it is the joiner's own signing key
(`Singular.Registry.Node`). The name is kept so the funding sites
below read unchanged.
-}
genesisAddr :: Addr
genesisAddr = funderAddr

-- | The signing key matching 'genesisAddr'.
genesisSignKey :: SignKeyDSIGN Ed25519DSIGN
genesisSignKey = funderSignKey

runRows :: Mode -> Env -> TxIn -> IO ()
runRows mode env recordIn = do
    -- The LM group, on the record the fold created.
    a1 <- rowLM01 env recordIn
    rowLM02 mode env a1
    rowLM03 env a1
    rowLM04 env a1
    -- The final no-trace sweep after every refusal.
    finalNoTrace env a1
    emit
        "complete"
        ( "the LM rows executed on a real devnet against a record a real \
          \registry fold created; every refusal attributed to its reason, \
          \the proofs shown, the state after the refusals unchanged"
        )

-- ---------------------------------------------------------
-- LM01 — maintenance accepts; preservation is proved
-- ---------------------------------------------------------

rowLM01 :: Env -> TxIn -> IO Snap
rowLM01 env claimIn = do
    snap <- mustSnap env claimIn
    current <- chainDatumOf env snap "LM01"
    let destCodec = envDestCodec env
        maintained = current{paymentDestination = SomeDestination destCodec}
    tx <- maintainTx env snap (Just (\d -> d{paymentDestination = SomeDestination destCodec})) True
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
        [ 0x15
        , 0x61
        , 0xc1
        , 0x5b
        , 0x49
        , 0x80
        , 0x85
        , 0x7f
        , 0xb0
        , 0x6e
        , 0x4a
        , 0xb3
        , 0x5c
        , 0xc9
        , 0xbc
        , 0xec
        , 0xaf
        , 0x09
        , 0x0b
        , 0x0a
        , 0xa8
        , 0xbd
        , 0xef
        , 0x19
        , 0xf6
        , 0x33
        , 0x15
        , 0x65
        , 0xa3
        , 0x33
        , 0x20
        , 0x4f
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
            (Just (\d -> d{nextControlCommitment = tamperedCommitment}))
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
-- The final no-trace sweep
-- ---------------------------------------------------------

finalNoTrace :: Env -> Snap -> IO ()
finalNoTrace env a1 = do
    now1 <- mustSnap env (snapIn a1)
    unless (sameSnap a1 now1) $ failWith "final: A1 moved"
    emit
        "no-trace"
        ( "state unchanged after every refusal — no trace: A1="
            <> showIn (snapIn a1)
            <> " ("
            <> show (snapCoin a1)
            <> " lovelace, tokens "
            <> show (snapTokens a1)
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
                    ( ( if wrongReasonMode
                            then "CONTROL wrong-reason: "
                            else ""
                      )
                        <> rowName
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

{- | The maintenance transaction: spend the claim with a Maintain
redeemer, continue the record at the application validator with
@contDatum@, pay the flat fee from the funding input. When
@demandsController@, the body demands the controller's signature.
-}
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
        -- `maintain` demands the record's whole value be preserved —
        -- its active witness token included — so the continuation
        -- carries exactly what the record held.
        contOut =
            scriptOut
                (envPp env)
                (envAppAddr env)
                (snapCoin snap)
                (let MultiAsset m = snapTokens snap in m)
                contDatum
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

{- | An output at the application validator carrying @tokens@ and the
inline naming datum, sized at least min-ADA plus margin.
-}
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

-- | Split the genesis wallet into funding and collateral UTxOs.
splitGenesis :: Cage.Provider IO -> Submitter IO -> IO [(TxIn, TxOut ConwayEra)]
splitGenesis prov submit = do
    utxos <- Cage.queryUTxOs prov genesisAddr
    -- The largest output, which is what "big" meant all along. Ordering
    -- by transaction id picked the right one only because a devnet this
    -- run booted for itself has exactly one output at this address; a
    -- funding wallet shared with a deployment has many, and the first in
    -- lexical order is an arbitrary small one.
    (bigIn, bigOut) <- case sortOn (Down . outValue) utxos of
        (b : _) -> pure b
        [] -> failWith "split: the funding wallet has no UTxOs"
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
    awaitTx splitTx
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
    outValue (_, o) = let Coin c = o ^. coinTxOutL in c

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
    , snapTokens :: MultiAsset
    {- ^ everything the record holds beside its lovelace. Since #157 a
    record is created by a fold and carries the registry's active
    witness token for its key, and `maintain` demands the whole
    value be preserved, so the snapshot keeps all of it.
    -}
    , snapDatum :: Maybe PLC.Data
    }

mustSnap :: Env -> TxIn -> IO Snap
mustSnap env txin = do
    utxos <- Cage.queryUTxOs (envProv env) (envAppAddr env)
    case filter ((== txin) . fst) utxos of
        [(_, o)] -> do
            let Coin c = o ^. coinTxOutL
                MaryValue _ tokens = o ^. valueTxOutL
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
mustFindUTxO prov addr txid label =
    awaitChain
        ( label
            <> ": no output of tx "
            <> txid
            <> " is live at the application validator"
        )
        $ do
            utxos <- Cage.queryUTxOs prov addr
            let mine =
                    sortBy
                        (comparing (txInIndex . fst))
                        (utxosByTxId utxos txid)
            pure (fst <$> listToMaybe mine)

utxosByTxId ::
    [(TxIn, TxOut ConwayEra)] ->
    String ->
    [(TxIn, TxOut ConwayEra)]
utxosByTxId utxos txid = filter ((== txid) . txInTxIdHex . fst) utxos

datumDataOf :: TxOut ConwayEra -> Maybe PLC.Data
datumDataOf out = case out ^. datumTxOutL of
    Datum bd -> let Data d = binaryDataToData bd in Just d
    _ -> Nothing

{- | On-chain Plutus data as the codec's wire value: exactly the shapes
the contract serialises.
-}
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

-- ---------------------------------------------------------
-- Submission helpers
-- ---------------------------------------------------------

submitAccepted :: Env -> String -> ConwayTx -> IO ()
submitAccepted env = submitAcceptedWith (envSubmit env)

{- | 'submitAccepted' before there is an environment: the record the rows
maintain is folded from the funding wallet directly, ahead of the split
that fills the row pool.
-}
submitAcceptedWith :: Submitter IO -> String -> ConwayTx -> IO ()
submitAcceptedWith submit label signed =
    submitTx submit signed >>= \case
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
    threadDelay confirmationDelay
    emit "confirm" ("confirmed on chain: " <> what)

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

{- | Fail the run unless every manifest pin under
@application.application@ equals the hash this run loaded.
-}
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

-- | Domain-separated next-control commitment (docs/naming-lifecycle.md).
nextControlCommitmentOf :: ByteString -> ByteString
nextControlCommitmentOf bs =
    convert
        ( hash
            ( "singular/naming/next-control/v1"
                <> BS.singleton 0x00
                <> bs
            ) ::
            Digest Blake2b_256
        )

-- ---------------------------------------------------------
-- The record the rows maintain, made by a real fold (#157)
-- ---------------------------------------------------------

{- | Boot a registry, certify one activation of a key under the naming
application policy, book it, and fold it. What the fold leaves behind is
the record: an output at the application validator's own address holding
the registry's active witness token for that key, under the naming datum
whose hash the approval bound.

That is the whole of what changed for these rows. A claim used to be
placed by hand and carry a withdraw approval; a record is what a fold
delivers, and the only thing that can create one is a fold. The
maintenance propositions below are unchanged — they were never about how
the record came to exist.
-}
setupFoldedRecord ::
    Cage.Provider IO ->
    Submitter IO ->
    PParams ConwayEra ->
    -- | the naming application's own address
    Addr ->
    -- | the naming application script
    Script ConwayEra ->
    -- | its hash, for narration
    String ->
    -- | state validator
    SBS.ShortByteString ->
    -- | request validator
    SBS.ShortByteString ->
    -- | naming application validator
    SBS.ShortByteString ->
    -- | unapplied @witness(kind, registry)@ validator
    SBS.ShortByteString ->
    NamingDatum ->
    IO TxIn
setupFoldedRecord prov submit pp appAddr appScript appHex stateBytes requestBytes appBytes witnessBytes recordDatum = do
    utxos <- Cage.queryUTxOs prov genesisAddr
    seedRef <- case sortOn (Down . (\(_, o) -> let Coin c = o ^. coinTxOutL in c)) utxos of
        ((txIn, _) : _) -> pure (txInToRef txIn)
        [] -> failWith "setup: the funding wallet has no UTxOs"
    let cfg =
            CageConfig
                { cageScriptBytes = stateBytes
                , requestScriptBytes = requestBytes
                , cfgScriptHash = computeScriptHash stateBytes
                , cageSeed = seedRef
                , defaultProcessTime = 120_000
                , defaultRetractTime = 30_000
                , defaultTip = Coin 1_000_000
                , -- #157 D-BOOT: all four pins derived for THIS registry
                  -- identity — NYA applied to the ordinary request-validator
                  -- hash, and `witness(kind, registry)` at kinds 0, 1 and 2.
                  cfgApplicationPolicy =
                    SBS.toShort
                        ( scriptHashBytes
                            ( computeScriptHash
                                ( appliedApplicationBytes
                                    (scriptHashBytes (computeScriptHash stateBytes))
                                    ( onChainTokenId
                                        ( TokenId
                                            ( AssetName
                                                (SBS.toShort (deriveAssetName seedRef))
                                            )
                                        )
                                    )
                                    requestBytes
                                    appBytes
                                )
                            )
                        )
                , cfgActivePolicy = witnessPin 1
                , cfgAbsentPolicy = witnessPin 0
                , cfgTerminalPolicy = witnessPin 2
                , cfgConsumerScript = SBS.empty
                , network = Testnet
                }
        witnessPin kind =
            SBS.toShort
                ( scriptHashBytes
                    ( computeScriptHash
                        ( applyBytesParam
                            ( scriptHashBytes (computeScriptHash stateBytes)
                                <> deriveAssetName seedRef
                            )
                            (applyIntParam kind witnessBytes)
                        )
                    )
                )
    unsignedBoot <- bootTokenImpl cfg prov genesisAddr
    signedBoot <- submitSignedRaw submit "cage-boot" unsignedBoot
    tid <- case Map.toList (tokensMinted cfg signedBoot) of
        [(an, _)] -> pure (TokenId an)
        _ -> failWith "setup: the boot minted an unexpected asset set"
    tm <- mkPureTrieManager
    createTrie tm tid
    -- The state validator alone is fifteen kilobytes: a fold that
    -- attaches it beside the request validator and a token policy is
    -- over MaxTxSize before it carries a proof. Published once, the
    -- fold resolves all five scripts from reference outputs.
    refs <-
        concat
            <$> mapM
                publishBatch
                (refScriptBatches (foldRefScripts cfg tid witnessBytes))
    -- The activation's destination (D-DEST, R-NM4): the naming
    -- application's own address, and the record datum it will carry.
    -- `record_destination` demands exactly that of an edge-1 approval.
    let datumData = namingDataToData recordDatum
        destHash =
            hashToBytes (extractHash (hashData (Data datumData :: Data ConwayEra)))
        dest = (serialiseAddr appAddr, destHash)
    unsignedBook <-
        bookEdgeTx
            cfg
            prov
            tid
            appScript
            genesisAddr
            recordKey
            (OpInsert leafActive)
            dest
            []
            recordBond
    _ <- submitSignedRaw submit "book-activation" unsignedBook
    ctx <- registryContextFor cfg prov tid witnessBytes [(destHash, datumData)] refs
    unsignedFold <- updateTokenWithDuties cfg prov tm tid genesisAddr ctx
    signedFold <- submitSignedRaw submit "fold" unsignedFold
    recordIn <-
        mustFindUTxO prov appAddr (txIdHex signedFold) "folded record"
    emit
        "setup"
        ( "registry "
            <> hex (scriptHashBytes (cfgScriptHash cfg))
            <> " booted, the activation of key "
            <> show recordKey
            <> " certified by the application policy 0x"
            <> appHex
            <> " and folded; the record it created lives at the \
               \application validator: "
            <> showIn recordIn
            <> " carrying the active witness token for that key under the \
               \naming datum the approval bound"
        )
    pure recordIn
  where
    publishBatch scripts = do
        unsigned <- publishRefScriptTx pp prov genesisAddr scripts
        signed <- submitSignedRaw submit "publish-references" unsigned
        utxos <- Cage.queryUTxOs prov genesisAddr
        mapM
            ( \ix ->
                let txIn = TxIn (txIdTx signed) (TxIx (fromIntegral ix))
                 in case [o | (i, o) <- utxos, i == txIn] of
                        (o : _) -> pure (txIn, o)
                        [] ->
                            failWith
                                "setup: a published reference output is not \
                                \on chain"
            )
            [0 .. length scripts - 1]

-- | The key the record is the registry's record of.
recordKey :: ByteString
recordKey = "t56-lm-name"

-- | The assets a boot transaction minted under the cage's own policy.
tokensMinted ::
    CageConfig -> ConwayTx -> Map.Map AssetName Integer
tokensMinted cfg tx =
    let MultiAsset ma = tx ^. bodyTxL . mintTxBodyL
     in Map.findWithDefault Map.empty (cagePolicyIdFromCfg cfg) ma

-- | Sign with the funding key, submit, and wait for confirmation.
submitSignedRaw :: Submitter IO -> String -> ConwayTx -> IO ConwayTx
submitSignedRaw submit label unsigned = do
    let signed = addKeyWitness genesisSignKey unsigned
    submitAcceptedWith submit label signed
    _ <- waitConfirmation (txIdHex signed <> " (" <> label <> ")")
    pure signed
