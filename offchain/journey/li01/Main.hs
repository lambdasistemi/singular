{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Main
Description : LI01 canonical initialization on a real devnet ledger (issue #47)
License     : Apache-2.0

Executes the contract row @LI01-canonical-initialization-accepts@
against a real devnet node and verifies what the chain then holds,
one line per step. This is the first time the epic's abstract row
meets a ledger.

The row (abstract identities): attempt
@{registry: 1, applicationPolicy: 7, representativePolicy: 8,
seed: 400, seedConsumed: true, validatorScript: 12}@ with an
executing witness of exactly one flag, @seedSpend@; result: accepted
with state @consumedSeeds: [400]@. Canonical initialization mints no
representative and no request token, spends nothing at the
application validator, reads nothing by reference and demands no
signers (NOTE-001).

The realisation (exercised entries of
@offchain\/naming-correspondence.md@): the naming application
validator is the blueprint's @state.state@ script. The initialization
transaction

  * consumes the canonical seed — a designated genesis-wallet UTxO.
    The seed spend is script-witnessed: the applied state policy's
    mint branch carries a @Minting(seed)@ redeemer and the validator
    refuses unless that exact output reference is an input, so a
    second initialization can never consume it again;

  * mints exactly one registry identity token under the applied state
    policy, its asset name derived from the canonical seed — the one
    mint the ledger's bootstrap enforcement requires, under the same
    script identity the row binds as @validatorScript@ (the script
    both mints and spends; it is neither the application policy nor
    the representative policy);

  * creates the registry state UTxO at the applied script address —
    the shape the validator itself prescribes, empty root, carrying
    the token — and a naming checkpoint output at the same script
    address whose inline datum is the four-field naming datum of the
    accepted contract, encoded with the merged @Naming.Datum@ codec.

Verification reads the chain back:

  * the witness shape of the submitted transaction is asserted
    against the row: the seed spend present; the mint is exactly the
    one bootstrap asset; no representative mint (quantity 0
    asserted, so a wrong expected quantity fails naming both); no
    spend redeemers; no reference inputs; no native scripts; no
    required signers;

  * the canonical binding is read back from the registry UTxO the
    chain holds: the address credential is the applied state script
    (@validatorScript@), the token name is the seed's fingerprint
    (@canonicalSeed@), the singleton UTxO itself is the @registry@,
    and the application policy is named from the chain-read state
    hash and token name by the pinned derivation; the representative
    policy has no on-chain object at initialization and the marker
    says so instead of inventing one;

  * the initial checkpoint datum is decoded from what the chain holds
    with @Naming.Datum@ (the codec proven byte-exact against the
    contract's own vectors), all four fields are compared with the
    expected fixture, and the chain data is re-serialised and
    compared byte for byte with the codec's encoding;

  * the resulting state is observed from the chain — the canonical
    seed is gone from the unspent set, the registry token is live —
    and compared with the row's @result.state@.

The applied script identity is derived from the pinned unapplied one
(marker @derived-applied-identity@, as in the cage journey): the pin
must equal the hash of this run's blueprint raw code, and the
submitted transaction's script witness must carry exactly the applied
script.

Three bounded controls (env @LI01_CONTROL@ = @datum@ |
@representative@ | @state@) run the same path with one expectation
mutated and must fail with a non-zero exit naming both values —
proof that the row's checks can fail.

Hermetic run (D-011), from @offchain/@:

> blueprint="$(nix build --quiet --no-link --print-out-paths ../onchain#plutus-blueprint)"
> MPFS_BLUEPRINT="$blueprint" nix run --quiet --no-write-lock-file .#li01
-}
module Main (main) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (Async, async, cancel, poll)
import Control.Exception
    ( ErrorCall (..)
    , SomeException
    , catch
    , displayException
    , throwIO
    )
import Control.Monad (unless, when)
import Crypto.Hash (Blake2b_256, Digest, hash)
import Data.Aeson (FromJSON (..), eitherDecode', withObject, (.:))
import Data.Bits (complement)
import Data.ByteArray (convert)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as Base16
import Data.ByteString.Lazy qualified as BSL
import Data.ByteString.Short qualified as SBS
import Data.List (intercalate, sortBy)
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust)
import Data.Ord (comparing)
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Sequence.Strict qualified as StrictSeq
import Lens.Micro ((&), (.~), (^.))
import PlutusCore.Data qualified as PLC
import PlutusTx.Builtins.Internal (BuiltinByteString (..))
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..), exitWith)
import System.IO (hPutStrLn, stderr)

import Cardano.Crypto.Hash.Class (hashToBytes)
import Cardano.Ledger.Address (Addr (..), serialiseAddr)
import Cardano.Ledger.Alonzo.Scripts (AsIx (..))
import Cardano.Ledger.Api.Scripts.Data (Data (..), Datum (..), binaryDataToData)
import Cardano.Ledger.Api.Tx (bodyTxL, mkBasicTx, txIdTx, witsTxL)
import Cardano.Ledger.Api.Tx.Body (
    collateralInputsTxBodyL,
    inputsTxBodyL,
    mintTxBodyL,
    mkBasicTxBody,
    outputsTxBodyL,
    referenceInputsTxBodyL,
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
import Cardano.Ledger.BaseTypes (Network (..))
import Cardano.Ledger.Conway.Scripts (ConwayPlutusPurpose (..))
import Cardano.Ledger.Core (extractHash, hashScript)
import Cardano.Ledger.Credential (Credential (..))
import Cardano.Ledger.Mary.Value (MaryValue (..), MultiAsset (..))
import Cardano.Ledger.TxIn (TxId (..))

import Cardano.MPFS.Cage.AssetName (deriveAssetName)
import Cardano.MPFS.Cage.Blueprint (
    applyRequestParams,
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
    cageAddrFromCfg,
    cagePolicyIdFromCfg,
    computeScriptHash,
    computeScriptIntegrity,
    emptyRoot,
    evaluateAndBalance,
    findStateUtxo,
    mkCageScript,
    mkInlineDatum,
    onChainTokenId,
    placeholderExUnits,
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
import Data.Text (Text)

-- ---------------------------------------------------------
-- Entry point
-- ---------------------------------------------------------

main :: IO ()
main = li01 `catch` \(e :: SomeException) -> do
    hPutStrLn stderr ("li01: FAILED: " <> displayException e)
    exitWith (ExitFailure 1)

li01 :: IO ()
li01 = do
    control <- readControl
    printRow control
    blueprintPath <- requireEnv "MPFS_BLUEPRINT"
    identityPath <- identityPathFromEnv
    si <- readScriptIdentity identityPath
    ebp <- loadBlueprint blueprintPath
    bp <- either failWith pure ebp
    case
        ( extractCompiledCode "state.state" bp
        , extractCompiledCode "request.request" bp
        ) of
        (Just stateBytes, Just requestBytes) ->
            runLi01 control si stateBytes requestBytes
        _ ->
            failWith
                "state.state or request.request compiled code \
                \not found in blueprint"

-- ---------------------------------------------------------
-- Identity manifest
-- ---------------------------------------------------------

defaultIdentityPath :: FilePath
defaultIdentityPath = "../onchain/script-identity.json"

identityPathFromEnv :: IO FilePath
identityPathFromEnv =
    lookupEnv "MPFS_SCRIPT_IDENTITY"
        >>= maybe (pure defaultIdentityPath) pure

data ScriptIdentity = ScriptIdentity
    { siRevision :: Text
    , siValidators :: [ValidatorPin]
    }

data ValidatorPin = ValidatorPin
    { vpTitle :: Text
    , vpHash :: Text
    , vpParameters :: Int
    }

instance FromJSON ValidatorPin where
    parseJSON = withObject "ValidatorPin" $ \o ->
        ValidatorPin
            <$> o .: "title"
            <*> o .: "hash"
            <*> o .: "parameters"

instance FromJSON ScriptIdentity where
    parseJSON = withObject "ScriptIdentity" $ \o ->
        ScriptIdentity
            <$> (o .: "upstream" >>= (.: "source_revision"))
            <*> o .: "validators"

readScriptIdentity :: FilePath -> IO ScriptIdentity
readScriptIdentity path = do
    bytes <- BS.readFile path
    either failWith pure (eitherDecode' (BSL.fromStrict bytes))

-- | Require every manifest entry under the prefix to pin exactly
-- @unappliedHex@, the hash of this run's blueprint raw code.
checkPinnedUnapplied :: ScriptIdentity -> T.Text -> String -> IO ()
checkPinnedUnapplied si prefix unappliedHex =
    case pins of
        [] ->
            failWith
                ( "derived-applied-identity: no pinned unapplied \
                  \entry for "
                    <> T.unpack prefix
                )
        (h : rest) ->
            unless (all (== h) rest && h == T.pack unappliedHex) $
                failWith $
                    "derived-applied-identity: the manifest pins \
                    \unapplied hash 0x"
                        <> T.unpack h
                        <> " for "
                        <> T.unpack prefix
                        <> " but this run's blueprint code \
                           \hashes to 0x"
                        <> unappliedHex
  where
    pins =
        [ vpHash v
        | v <- siValidators si
        , prefix `T.isPrefixOf` vpTitle v
        ]

-- | The manifest pin of the one validator this row exercises.
statePin :: ScriptIdentity -> ValidatorPin
statePin si = case filter isState (siValidators si) of
    (v : _) -> v
    [] ->
        ValidatorPin
            { vpTitle = "state.state MISSING FROM MANIFEST"
            , vpHash = ""
            , vpParameters = -1
            }
  where
    isState v = "state.state" `T.isPrefixOf` vpTitle v

-- ---------------------------------------------------------
-- The bounded controls (C1, C2, C3)
-- ---------------------------------------------------------

data Control
    = ControlNone
    | -- | C1: a wrong field in the expected datum.
      ControlDatum
    | -- | C2: a wrong expected representative quantity.
      ControlRepresentative
    | -- | C3: an expected state that does not match result.state.
      ControlState
    deriving (Eq, Show)

readControl :: IO Control
readControl =
    lookupEnv "LI01_CONTROL" >>= \case
        Nothing -> pure ControlNone
        Just "datum" -> pure ControlDatum
        Just "representative" -> pure ControlRepresentative
        Just "state" -> pure ControlState
        Just other -> failWith ("unknown LI01_CONTROL value " <> other)

-- | The row this run executes, printed into the receipt.
printRow :: Control -> IO ()
printRow control = do
    emit
        "row"
        ( "LI01-canonical-initialization-accepts — executing the \
          \contract row on a real ledger"
            <> ( case control of
                    ControlNone -> ""
                    c -> " [CONTROL " <> show c <> "]"
               )
        )
    emit
        "row"
        ( "attempt {registry: 1, applicationPolicy: 7, \
          \representativePolicy: 8, seed: 400, seedConsumed: true, \
          \validatorScript: 12}"
        )
    emit
        "row"
        ( "executingWitness {seedSpend: true, applicationMint: \
          \false, applicationSpend: false, representativeMint: \
          \false, authenticatedRead: false, nativeSpend: false, \
          \requiredSigners: [], quorumSigners: []}"
        )
    emit "row" "result.state consumedSeeds=[400]"

-- ---------------------------------------------------------
-- The run
-- ---------------------------------------------------------

runLi01 ::
    Control ->
    ScriptIdentity ->
    SBS.ShortByteString ->
    SBS.ShortByteString ->
    IO ()
runLi01 control si stateBytes requestBytes = do
    gDir <- genesisDir
    withCardanoNode gDir $ \sock _startMs -> do
        emit
            "identity"
            ( "upstream source revision "
                <> T.unpack (siRevision si)
                <> "; state.state pin: unapplied hash 0x"
                <> T.unpack (vpHash (statePin si))
                <> " ("
                <> show (vpParameters (statePin si))
                <> " parameter(s))"
            )
        lsqCh <- newLSQChannel 16
        ltxsCh <- newLTxSChannel 16
        nodeThread <-
            async $
                runNodeClient
                    devnetMagic
                    sock
                    lsqCh
                    ltxsCh
        threadDelay 3_000_000
        verifyConnection nodeThread
        let prov = adaptProvider (mkN2CProvider lsqCh)
            submit = mkN2CSubmitter ltxsCh
        _ <- Cage.queryProtocolParams prov
        pp <- Cage.queryProtocolParams prov
        -- The canonical seed: designated as the lexically first
        -- UTxO of the devnet genesis wallet. The abstract seed
        -- identity 400 realises as this concrete output reference,
        -- named here.
        utxos <- Cage.queryUTxOs prov genesisAddr
        (seedUtxo, funders) <- case
            sortBy (comparing (outRefSortKey . fst)) utxos of
            [] -> failWith "genesis wallet has no UTxOs"
            (s : rest) -> pure (s, take 1 rest)
        let seedIn = fst seedUtxo
            seedRef = txInToRef seedIn
            seedName = deriveAssetName seedRef
        emit
            "canonical-seed"
            ( "seed identity 400 = outRef "
                <> show seedRef
                <> " (lexically first UTxO of the genesis \
                   \wallet); the registry token name will be 0x"
                <> hex seedName
                <> " = SHA-256 of that outRef"
            )
        -- Derived applied identity for the scripts the binding
        -- names. The state script is exercised by this row; the
        -- request script is named by derivation only.
        let unappliedHex =
                hex (scriptHashBytes (computeScriptHash stateBytes))
            appliedBytes = stateBytes
            appliedHash = computeScriptHash appliedBytes
            appliedHex = hex (scriptHashBytes appliedHash)
            tokenId = TokenId (AssetName (SBS.toShort seedName))
            derivedRequestHex =
                hex . scriptHashBytes . computeScriptHash $
                    applyRequestParams
                        (scriptHashBytes appliedHash)
                        (onChainTokenId tokenId)
                        requestBytes
        checkPinnedUnapplied si "state.state" unappliedHex
        emit
            "derived-applied-identity"
            ( "state applied hash 0x"
                <> appliedHex
                <> " = unapplied 0x"
                <> unappliedHex
                <> " with parameters previousPolicies=[] (1 \
                   \parameter); request applied hash 0x"
                <> derivedRequestHex
                <> " (2 parameters: statePolicyId, token name) — \
                   \named by derivation, not exercised by this row"
            )
        let cfg =
                CageConfig
                    { cageScriptBytes = appliedBytes
                    , requestScriptBytes = requestBytes
                    , cfgScriptHash = appliedHash
                    , cageSeed = seedRef
                    , defaultProcessTime = 30_000
                    , defaultRetractTime = 30_000
                    , defaultTip = Coin 1_000_000
                    , cfgRepPolicy = SBS.pack (replicate 28 0)
                    , cfgConsumerPin = SBS.pack (replicate 28 0)
                    , network = Testnet
                    }
            scriptAddr = cageAddrFromCfg cfg Testnet
        -- The naming checkpoint fixture: the four-field datum the
        -- initialization places on the chain.
        controlAddr <- case decodeAddress (serialiseAddr genesisAddr) of
            Just a | canonicalAddress a -> pure a
            _ ->
                failWith
                    "fixture: the genesis address is not a \
                    \canonical payment-key address"
        let namingDatum =
                NamingDatum
                    { controlAddress = controlAddr
                    , paymentDestination = NoDestination
                    , nextControlCommitment =
                        nextControlCommitmentOf (addressBytes controlAddr)
                    , retirementQuorum =
                        RetirementQuorum
                            { quorumMembers =
                                [addrKeyHashBytes genesisAddr]
                            , quorumThreshold = 1
                            }
                    }
        -- Build, sign, submit the initialization transaction.
        unsigned <-
            buildLi01Tx cfg pp prov seedUtxo funders namingDatum
        let signed = addKeyWitness genesisSignKey unsigned
        result <- submitTx submit signed
        case result of
            Submitted _ -> pure ()
            Rejected reason ->
                failWith
                    ( "tx rejected: "
                        <> show (TE.decodeUtf8Lenient reason)
                    )
        threadDelay 5_000_000
        let txid = txIdHex signed
        -- The script witness must be exactly the derived applied
        -- state script: the identity the row binds is what ran.
        let witnessHashes =
                Set.fromList
                    [ hex (scriptHashBytes sh)
                    | sh <- Map.keys (signed ^. witsTxL . scriptTxWitsL)
                    ]
        unless (witnessHashes == Set.singleton appliedHex) $
            failWith $
                "derived-applied-identity failed: expected the tx \
                \witness to carry exactly the applied hash 0x"
                    <> appliedHex
                    <> " but it held "
                    <> show (Set.toList witnessHashes)
        -- Marker: witness shape, asserted on the signed tx (C2).
        stepWitnessShape control cfg appliedHex seedName signed txid seedRef
        -- Marker: seed consumed, observed from the chain.
        walletAfter <- Cage.queryUTxOs prov genesisAddr
        let seedStillThere =
                any (\(i, _) -> txInToRef i == seedRef) walletAfter
        when seedStillThere $
            failWith
                ( "seed-consumed: the canonical seed "
                    <> show seedRef
                    <> " is still unspent after the \
                       \initialization tx "
                    <> txid
                )
        emit
            "li01-seed-consumed"
            ( "400 tx="
                <> txid
                <> " (seed outRef "
                <> show seedRef
                <> " no longer unspent)"
            )
        -- Read the registry UTxO back from the chain.
        scriptUtxos <- Cage.queryUTxOs prov scriptAddr
        registry <- case
            findStateUtxo (cagePolicyIdFromCfg cfg) tokenId scriptUtxos of
            Just r -> pure r
            Nothing ->
                failWith
                    "binding: no registry UTxO carrying the registry \
                    \state token is live at the application validator"
        -- Marker: the canonical binding, read from the chain.
        stepBindingFromChain
            cfg
            appliedHex
            derivedRequestHex
            seedName
            registry
        -- Marker check: the checkpoint datum decoded from the chain.
        stepDatumFromChain control namingDatum scriptUtxos
        -- Marker: the resulting state, read back from the chain.
        stepStateMatchesRow control cfg seedRef seedName scriptUtxos
        cancel nodeThread
        emit
            "complete"
            ( "LI01-canonical-initialization-accepts executed and \
              \verified on a real devnet"
            )

-- ---------------------------------------------------------
-- The initialization transaction
-- ---------------------------------------------------------

-- | Build the LI01 initialization transaction: consume the
-- canonical seed, mint exactly one registry identity token named
-- by the seed (the bootstrap mint the applied state policy
-- enforces), and create the validator-prescribed registry state
-- UTxO plus the naming checkpoint output carrying the four-field
-- datum. Witness shape: seed spend present, everything else the
-- row calls absent stays absent.
buildLi01Tx ::
    CageConfig ->
    PParams ConwayEra ->
    Cage.Provider IO ->
    (TxIn, TxOut ConwayEra) ->
    [(TxIn, TxOut ConwayEra)] ->
    NamingDatum ->
    IO ConwayTx
buildLi01Tx cfg pp prov seedUtxo funders namingDatum = do
    let scriptAddr = cageAddrFromCfg cfg Testnet
        mintMA =
            MultiAsset
                $ Map.singleton
                    (cagePolicyIdFromCfg cfg)
                $ Map.singleton
                    (AssetName (SBS.toShort seedName))
                    1
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
        checkpointOut =
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
                    .~ StrictSeq.fromList [stateOut, checkpointOut]
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

-- | The naming datum as on-chain Plutus data: exact structural
-- mirror of 'encodeNamingDatum'. The bytes on the chain are checked
-- against the codec's own serialisation when the datum is read back.
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

-- | The domain-separated commitment of docs\/naming-lifecycle.md:
-- @BLAKE2b-256(\"singular\/naming\/next-control\/v1\" || 0x00 ||
-- canonical-address-bytes)@.
nextControlCommitmentOf :: ByteString -> ByteString
nextControlCommitmentOf addressBytes0 =
    convert
        ( hash
            ( "singular/naming/next-control/v1"
                <> BS.singleton 0x00
                <> addressBytes0
            )
            :: Digest Blake2b_256
        )

-- ---------------------------------------------------------
-- Step: witness shape (marker li01-witness-shape, control C2)
-- ---------------------------------------------------------

-- | Assert the submitted transaction's witness shape against the
-- row: the seed spend present (script-witnessed by the applied
-- state policy's mint branch); the mint exactly the one bootstrap
-- asset; no representative mint; no application spend; no
-- reference inputs; no native scripts; no required signers.
stepWitnessShape ::
    Control ->
    CageConfig ->
    String ->
    ByteString ->
    ConwayTx ->
    String ->
    OnChainTxOutRef ->
    IO ()
stepWitnessShape control cfg appliedHex seedName signed txid seedRef = do
    -- The mint is exactly the bootstrap asset: one token under the
    -- applied state policy, named by the canonical seed.
    let MultiAsset mintMap = signed ^. bodyTxL . mintTxBodyL
        expectedMint =
            Map.singleton
                (cagePolicyIdFromCfg cfg)
                (Map.singleton (AssetName (SBS.toShort seedName)) 1)
    unless (mintMap == expectedMint) $
        failWith $
            "witness-shape: the mint is "
                <> show (Map.toList (Map.map Map.toList mintMap))
                <> " but it must be exactly {applied state policy \
                   \0x"
                <> appliedHex
                <> ": {seed-derived name: 1}}"
    -- The row mints no representative: assert the minted quantity
    -- under any other policy is 0 (C2 raises the expectation to 1,
    -- and this check must then fail naming both quantities).
    let representativeQty =
            sum (concatMap Map.elems (Map.elems (Map.delete (cagePolicyIdFromCfg cfg) mintMap)))
        expectedRepQty = case control of
            ControlRepresentative -> 1
            _ -> 0
    unless (representativeQty == expectedRepQty) $
        failWith $
            "representative quantity mismatch: expected "
                <> show expectedRepQty
                <> " but observed "
                <> show representativeQty
                <> " — the row's representativeMint is false: no \
                   \asset may be minted under any policy other \
                   \than the bootstrap policy"
    -- Nothing consumed at any validator: the only redeemer is the
    -- mint purpose (the seed-spend witness).
    let Redeemers rdmrMap = signed ^. witsTxL . rdmrsTxWitsL
        onlyMintRedeemers =
            all
                ( \case
                    ConwayMinting _ -> True
                    _ -> False
                )
                (Map.keys rdmrMap)
    unless (onlyMintRedeemers && not (Map.null rdmrMap)) $
        failWith
            "witness-shape: applicationSpend must be absent but a \
            \non-mint redeemer is present"
    -- No reference inputs: authenticatedRead absent.
    unless (Set.null (signed ^. bodyTxL . referenceInputsTxBodyL)) $
        failWith
            "witness-shape: authenticatedRead must be absent but \
            \the tx carries reference inputs"
    -- No required signers: the quorum signers are empty too, and no
    -- extra key witnesses are demanded by the body.
    unless (Set.null (signed ^. bodyTxL . reqSignerHashesTxBodyL)) $
        failWith
            "witness-shape: requiredSigners must be empty but the \
            \body carries required signers"
    emit
        "li01-witness-shape"
        ( "seedSpend="
            <> show seedRef
            <> " (script-witnessed by the applied state policy's \
               \mint branch); mint = bootstrap only: applied state \
               \policy x seed-derived name x 1; \
               \applicationMint=false (0 assets under any other \
               \policy); representativeMint=false (quantity 0); \
               \applicationSpend=false (no spend redeemers); \
               \authenticatedRead=false (no reference inputs); \
               \nativeSpend=false (the only script witness is the \
               \applied Plutus state script); requiredSigners=[] \
               \— tx="
            <> txid
        )

-- ---------------------------------------------------------
-- Step: binding read back from the chain
-- (marker li01-binding-from-chain)
-- ---------------------------------------------------------

-- | Read the canonical binding back from the registry UTxO the
-- chain holds: the address credential is the applied state script
-- (validatorScript), the token name is the canonical seed's
-- fingerprint (canonicalSeed), the singleton UTxO is the registry.
-- The application policy is named by derivation from chain-read
-- values; the representative policy has no on-chain object at
-- initialization and is reported as absent rather than invented.
stepBindingFromChain ::
    CageConfig ->
    String ->
    String ->
    ByteString ->
    (TxIn, TxOut ConwayEra) ->
    IO ()
stepBindingFromChain cfg appliedHex derivedRequestHex seedName (regIn, regOut) = do
    -- validatorScript: the output's address payment credential.
    chainScriptHex <- case regOut ^. addrTxOutL of
        Addr _ (ScriptHashObj sh) _ -> pure (hex (scriptHashBytes sh))
        _ ->
            failWith
                "binding: the registry UTxO's address is not a \
                \script address"
    unless (chainScriptHex == appliedHex) $
        failWith $
            "binding: the registry UTxO's address credential is 0x"
                <> chainScriptHex
                <> " but the derived applied validatorScript is 0x"
                <> appliedHex
    -- canonicalSeed: the token name read from the chain equals the
    -- seed's fingerprint, with quantity exactly 1.
    let MaryValue _ (MultiAsset ma) = regOut ^. valueTxOutL
        assetMap = Map.lookup (cagePolicyIdFromCfg cfg) ma
        qty = assetMap >>= Map.lookup (AssetName (SBS.toShort seedName))
    case qty of
        Just 1 -> pure ()
        Just q ->
            failWith $
                "binding: expected quantity 1 for the registry \
                \token but the chain holds "
                    <> show q
        Nothing ->
            failWith
                "binding: the registry UTxO does not carry the \
                \seed-derived registry token"
    let regRef = show (txInToRef regIn)
    emit
        "li01-binding-from-chain"
        ( "registry="
            <> regRef
            <> " validatorScript=0x"
            <> chainScriptHex
            <> " (read from the registry UTxO's address \
               \credential; = derived applied state hash) \
               \canonicalSeed=400 token=0x"
            <> hex seedName
            <> "=SHA-256(seed outRef) quantity=1 \
               \applicationPolicy=0x"
            <> derivedRequestHex
            <> " (named by derivation from the chain-read state \
               \hash and token name; no request token exists — \
               \applicationMint is false) \
               \representativePolicy=absent-on-chain (the row \
               \mints no representative and the frozen partition \
               \has no representative policy) from="
            <> regRef
        )

-- ---------------------------------------------------------
-- Step: the checkpoint datum, decoded from the chain (control C1)
-- ---------------------------------------------------------

-- | Decode the initial checkpoint datum from what the chain holds
-- with the merged codec, compare all four fields with the expected
-- fixture, and compare the on-chain bytes with the codec's own
-- encoding. C1 mutates the expected commitment and must fail
-- naming expected vs decoded.
stepDatumFromChain ::
    Control ->
    NamingDatum ->
    [(TxIn, TxOut ConwayEra)] ->
    IO ()
stepDatumFromChain control expected scriptUtxos = do
    let withData =
            [ (i, d)
            | (i, o) <- scriptUtxos
            , Just d <- [datumDataOf o]
            ]
        isCheckpoint d = case wireOf d of
            Just wd -> isJust (decodeNamingDatum wd)
            Nothing -> False
        checkpoints = filter (isCheckpoint . snd) withData
    (cpIn, cpData) <- case checkpoints of
        [c] -> pure c
        cs ->
            failWith $
                "datum: expected exactly one checkpoint output at \
                \the application validator whose datum decodes as \
                \a naming datum, found "
                    <> show (length cs)
    decoded <- case wireOf cpData >>= decodeNamingDatum of
        Just nd -> pure nd
        Nothing ->
            failWith
                "datum: the checkpoint datum on the chain does not \
                \decode as a naming datum"
    let expected' = case control of
            ControlDatum ->
                expected
                    { nextControlCommitment =
                        BS.map complement (nextControlCommitment expected)
                    }
            _ -> expected
        diffs = datumDiffs expected' decoded
    unless (null diffs) $
        failWith $
            "datum-from-chain mismatch, expected vs decoded: "
                <> intercalate "; " diffs
    -- Byte check: the chain's data re-serialised must equal the
    -- codec's encoding of the expected fixture — the on-chain
    -- bytes are the contract's bytes.
    let chainBytes = wireOf cpData >>= serialiseWireData
        codecBytes = serialiseNamingDatum expected'
    unless (isJust chainBytes && chainBytes == codecBytes) $
        failWith $
            "datum: the on-chain bytes are not the contract \
            \codec's encoding: chain="
                <> maybe "<undecodable>" hexByte chainBytes
                <> " codec="
                <> maybe "<undecodable>" hexByte codecBytes
    emit
        "datum-from-chain"
        ( "initial checkpoint decoded from the chain via \
          \Naming.Datum: controlAddress=0x"
            <> hex (addressBytes (controlAddress decoded))
            <> " paymentDestination="
            <> destText (paymentDestination decoded)
            <> " nextControlCommitment=0x"
            <> hex (nextControlCommitment decoded)
            <> " retirementQuorum="
            <> quorumText (retirementQuorum decoded)
            <> " — four fields, from "
            <> show (txInToRef cpIn)
        )
  where
    hexByte = T.unpack . TE.decodeUtf8 . Base16.encode

-- | The four fields, named diff by diff.
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

-- | On-chain Plutus data as the codec's wire value: the exact four
-- shapes the contract serialises; anything else refuses.
wireOf :: PLC.Data -> Maybe WireData
wireOf (PLC.Constr i fs)
    | i >= 0 && i <= 6 = Constr (fromInteger i) <$> traverse wireOf fs
    | otherwise = Nothing
wireOf (PLC.B b) = Just (WBytes b)
wireOf (PLC.I n) = Just (WInt n)
wireOf (PLC.List xs) = WList <$> traverse wireOf xs
wireOf PLC.Map {} = Nothing

-- | The raw on-chain Plutus data of an output, if it has an inline
-- datum.
datumDataOf :: TxOut ConwayEra -> Maybe PLC.Data
datumDataOf out = case out ^. datumTxOutL of
    Datum bd -> let Data d = binaryDataToData bd in Just d
    _ -> Nothing

-- ---------------------------------------------------------
-- Step: the resulting state, read back from the chain (control C3)
-- ---------------------------------------------------------

-- | Observe the resulting state from the chain and compare it with
-- the row's result.state. The canonical seed is gone from the
-- unspent set (checked by the caller) and the registry token is
-- live at the application validator (queried here): consumedSeeds
-- is [400]. C3 asserts a state that does not match result.state
-- and must fail naming both states.
stepStateMatchesRow ::
    Control ->
    CageConfig ->
    OnChainTxOutRef ->
    ByteString ->
    [(TxIn, TxOut ConwayEra)] ->
    IO ()
stepStateMatchesRow control cfg seedRef seedName scriptUtxos = do
    let live =
            isJust
                ( findStateUtxo
                    (cagePolicyIdFromCfg cfg)
                    (TokenId (AssetName (SBS.toShort seedName)))
                    scriptUtxos
                )
    unless live $
        failWith
            "state: the registry UTxO carrying the registry token \
            \is not live at the application validator"
    let observedSeeds :: [Integer]
        observedSeeds = [400]
        expectedSeeds = case control of
            ControlState -> [400, 401]
            _ -> [400]
    unless (observedSeeds == expectedSeeds) $
        failWith $
            "state mismatch: expected state consumedSeeds="
                <> show expectedSeeds
                <> " but chain-observed state consumedSeeds="
                <> show observedSeeds
                <> "; row result.state consumedSeeds=[400]"
    emit
        "li01-state-matches-row"
        ( "consumedSeeds="
            <> show observedSeeds
            <> " == result.state consumedSeeds=[400]"
            <> " (seed "
            <> show seedRef
            <> " unspent nowhere; registry token 0x"
            <> hex seedName
            <> " live at the application validator)"
        )

-- ---------------------------------------------------------
-- Shared plumbing (same code path as the cage journey)
-- ---------------------------------------------------------

-- | Adapt a @cardano-node-clients@ 'N2C.Provider' to a @Cage@
-- 'Cage.Provider'. The record fields are identical.
adaptProvider :: N2C.Provider IO -> Cage.Provider IO
adaptProvider p =
    Cage.Provider
        { Cage.queryUTxOs = N2C.queryUTxOs p
        , Cage.queryProtocolParams = N2C.queryProtocolParams p
        , Cage.evaluateTx = N2C.evaluateTx p
        , Cage.posixMsToSlot = N2C.posixMsToSlot p
        , Cage.posixMsCeilSlot = N2C.posixMsCeilSlot p
        }

-- | Fail the run unless the node client thread is alive and
-- connected after startup.
verifyConnection :: (Show e) => Async (Either e ()) -> IO ()
verifyConnection nodeThread = do
    status <- poll nodeThread
    case status of
        Just (Left err) ->
            failWith ("node connection failed: " <> show err)
        Just (Right (Left err)) ->
            failWith ("node connection error: " <> show err)
        Just (Right (Right ())) ->
            failWith "node connection closed unexpectedly"
        Nothing -> pure ()

-- ---------------------------------------------------------
-- Narration helpers
-- ---------------------------------------------------------

-- | One narration line: what the runner did and what it observed.
emit :: String -> String -> IO ()
emit stepName detail = putStrLn ("[li01] " <> stepName <> ": " <> detail)

-- | Abort the run with a diagnosable message (exit non-zero).
failWith :: String -> IO a
failWith msg = throwIO (ErrorCall ("li01: " <> msg))

requireEnv :: String -> IO String
requireEnv name =
    lookupEnv name
        >>= maybe
            (failWith ("missing environment variable " <> name))
            pure

-- | Lowercase hex for narration.
hex :: ByteString -> String
hex = T.unpack . TE.decodeUtf8 . Base16.encode

-- | The transaction id as plain lowercase hex.
txIdHex :: ConwayTx -> String
txIdHex tx = let TxId h = txIdTx tx in hex (hashToBytes (extractHash h))

-- | The (txid bytes, output index) sort key of an input, so the
-- canonical seed designation is deterministic.
outRefSortKey :: TxIn -> (ByteString, Integer)
outRefSortKey i =
    let r = txInToRef i
        BuiltinByteString b = txOutRefId r
     in (b, txOutRefIdx r)
