{- |
Module      : Conformance.Run.Authentication
Description : The authentication vocabulary, executed on the devnet
License     : Apache-2.0

One interpreter for every registry-identity row: it executes the instructions
of "Conformance.Authentication.Programs" against the session's devnet, one
case per instruction, and writes the row's receipt from the transaction its
program cites. A registry the ledger refuses to boot is a finding, reported and
never relabelled; the ledger is expected to accept a rival, and the rival's
rejection is the consumer's authentication, asserted on chain-read assets.

A control demands the opposite of every instruction it arms, so a run under
it must fail where that instruction runs.
-}
module Conformance.Run.Authentication
    ( openIdentitySession
    , runAuthenticationRow
    ) where

import Conformance.Authentication.Programs
    ( Authenticator (..)
    , Citation (..)
    , Decision (..)
    , Instruction (..)
    , Program (..)
    , Seed (..)
    , Subject (..)
    , armedBy
    , instructionReading
    , sessionPrologue
    )
import Conformance.Run.Control
import Conformance.Run.Environment
import Conformance.Run.Manifest
import Conformance.Run.Observe
import Conformance.Run.Receipts
import Conformance.Run.Submit
import Conformance.Run.Units
import Conformance.Run.Wallet

import Control.Monad (when)
import Data.ByteString.Short qualified as SBS
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.List (sortOn)
import Data.Map.Strict qualified as Map
import Data.Sequence.Strict qualified as StrictSeq
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Lens.Micro ((&), (.~), (^.))

import Cardano.Ledger.Address (Addr (..))
import Cardano.Ledger.Api.Tx
    ( mkBasicTx
    , mkBasicTxBody
    )
import Cardano.Ledger.Api.Tx.Body
    ( feeTxBodyL
    , inputsTxBodyL
    , outputsTxBodyL
    )
import Cardano.Ledger.Api.Tx.Out
    ( addrTxOutL
    , coinTxOutL
    , datumTxOutL
    , mkBasicTxOut
    , valueTxOutL
    )
import Cardano.Ledger.BaseTypes (Network (..))
import Cardano.Ledger.Credential
    ( Credential (..)
    , StakeReference (..)
    )
import Cardano.Ledger.Mary.Value (MaryValue (..))
import Cardano.Ledger.TxIn (TxIn (..))

import Singular.Registry.AssetName (deriveAssetName)
import Singular.Registry.Blueprint
    ( NamingCodes
    , applyPreviousPolicies
    )
import Singular.Registry.Config (CageConfig (..))
import Singular.Registry.Ledger
    ( AssetName (..)
    , Coin (..)
    , ConwayEra
    , PolicyID (..)
    , TokenId (..)
    , TxOut
    )
import Singular.Registry.Node
    ( Capabilities (..)
    , SubmitResult (..)
    , signTx
    , signedTx
    , submitSigned
    )
import Singular.Registry.Provider qualified as Cage
import Singular.Registry.TxBuilder.Boot (bootTokenImpl)
import Singular.Registry.TxBuilder.Internal
    ( cageAddrFromCfg
    , cagePolicyIdFromCfg
    , computeScriptHash
    , extractCageDatum
    , findStateUtxo
    , mkInlineDatum
    , requestAddrFromCfg
    , scriptHashBytes
    , toPlcData
    , txInToRef
    )
import Singular.Registry.Types
    ( CageDatum (..)
    , OnChainTxOutRef (..)
    )

import Conformance.Authenticate
    ( AuthDecision (..)
    , AuthReject (..)
    , authenticate
    , authenticateWeak
    )
import Conformance.Mirror
    ( emit
    , failWith
    , hex
    , require
    , txIdHex
    )
import Conformance.Receipt
    ( DerivationEvidence (..)
    , DerivationOutcome (..)
    , Outcome (..)
    , Verdict (..)
    , derivationMatches
    , derivationVenue
    )

{- | Open the identity session: sweep the wallet into one output, then run the
session's prologue, which publishes the canonical seed. The canonical
registry's configuration is the session's.
-}
openIdentitySession
    :: Cage.Provider IO
    -> Capabilities
    -> (SBS.ShortByteString, SBS.ShortByteString, NamingCodes)
    -> IO (CageConfig, IdentityWorld)
openIdentitySession prov caps codes = do
    -- Swept before the designation: afterwards the canonical seed is an
    -- ordinary ada-only output, and a sweep would spend the one the
    -- configuration pins.
    consolidateWallet prov caps
    world <-
        IdentityWorld codes <$> newIORef Map.empty <*> newIORef Nothing
    mapM_
        (publishSeed prov caps world "session prologue")
        sessionPrologue'
    canonical <- seedOf world "session prologue" CanonicalSeed
    pure (publishedConfig canonical, world)
  where
    sessionPrologue' = [seed | PublishSeed seed <- sessionPrologue]

-- | Run one registry-identity row's program and write its receipt.
runAuthenticationRow :: Env -> IdentityWorld -> Program -> IO ()
runAuthenticationRow env world program = do
    evidence <- newIORef []
    mapM_ (step env world evidence row) (programInstructions program)
    measured <- citedMeasure world row (programCites program)
    derivations <- reverse <$> readIORef evidence
    writeRowReceipt
        env
        row
        Accepted
        AgreesWithModel
        [measuredId measured]
        Nothing
        Nothing
        (Just (measuredMem measured))
        (Just (measuredCpu measured))
        (Just (measuredSize measured))
        (if null derivations then "node-submit" else derivationVenue)
        (if null derivations then Nothing else Just derivations)
    emit "row" (row <> ": every instruction held")
  where
    row = programRow program

-- ---------------------------------------------------------
-- One instruction
-- ---------------------------------------------------------

step
    :: Env
    -> IdentityWorld
    -> IORef [DerivationEvidence]
    -> String
    -> Instruction
    -> IO ()
step env world evidence row instruction = do
    case instruction of
        PublishSeed seed -> publishSeed (envProv env) (envCaps env) world row seed
        BootFrom seed -> bootFrom env world row seed
        NameIsSeedDerivation seed -> nameIsDerivation env world label armed seed
        NamesDiffer a b -> do
            nameA <- deriveAssetName . publishedReference <$> seedOf world row a
            nameB <- deriveAssetName . publishedReference <$> seedOf world row b
            require
                (label <> ": the two registries derive the same name 0x" <> hex nameA)
                (nameA /= nameB)
        UnchangedSinceBoot seed -> do
            booted <- bootOf world row seed
            (stateIn, stateOut) <- stateOutput env world row seed
            let (bootIn, bootValue, bootDatum) = bootedState booted
            require
                (label <> ": the registry's state output moved")
                (stateIn == bootIn)
            require
                (label <> ": the registry's state value changed")
                (stateOut ^. valueTxOutL == bootValue)
            require
                (label <> ": the registry's state datum changed")
                (stateOut ^. datumTxOutL == bootDatum)
        ForgeTokenlessOutput -> forgeTokenlessOutput env world label
        Authenticate authenticator subject decision -> do
            assets <- case subject of
                StateOutputOf seed -> outAssets . snd <$> stateOutput env world row seed
                ForgedOutput -> do
                    forged <- readIORef (identityForgery world)
                    case forged of
                        Just f -> pure (outAssets (forgeryOutput f))
                        Nothing -> failWith (row <> ": no forged output exists yet")
            canonical <- seedOf world row CanonicalSeed
            let cfg = publishedConfig canonical
                policy = scriptHashBytes (policyID (cagePolicyIdFromCfg cfg))
                name = deriveAssetName (publishedReference canonical)
                reached = case authenticator of
                    DerivedName -> authenticate policy name assets
                    PolicyOnly -> authenticateWeak policy assets
                wanted = case decision of
                    Accepts -> AuthAccept
                    RejectsOnName -> AuthReject NameMismatch
                    RejectsOnMissingPolicy -> AuthReject PolicyAbsent
            require
                ( label
                    <> ": "
                    <> instructionReading instruction
                    <> " The authentication reached "
                    <> show reached
                    <> (if armed then ", and the armed control demanded otherwise" else "")
                )
                (if armed then reached /= wanted else reached == wanted)
        StateIdentityPinned -> do
            manifest <- readScriptManifest
            let pins = pinsUnder "state.state" manifest
                (stateBytes, _, _) = identityCodes world
                unapplied = hex (scriptHashBytes (computeScriptHash stateBytes))
            case pins of
                [] -> failWith (label <> ": the manifest pins no state.state entry")
                (pinned, parameters) : rest -> do
                    require
                        (label <> ": the manifest's pins disagree: " <> show pins)
                        (all (== (pinned, parameters)) rest)
                    require
                        ( label
                            <> ": the pinned unapplied hash 0x"
                            <> T.unpack pinned
                            <> " is not this run's blueprint code 0x"
                            <> unapplied
                        )
                        (pinned == T.pack unapplied)
                    require
                        ( label
                            <> ": the manifest declares "
                            <> show parameters
                            <> " parameters for state.state, wanted 0"
                        )
                        (parameters == Just 0)
        StateAddressDerived -> do
            canonical <- seedOf world row CanonicalSeed
            (stateIn, stateOut) <- stateOutput env world row CanonicalSeed
            let cfg = publishedConfig canonical
                chainAddr = stateOut ^. addrTxOutL
                (derived, matches) = derivationMatches (cageAddrFromCfg cfg (network cfg)) chainAddr
            require
                ( label
                    <> ": the production derivation "
                    <> show derived
                    <> " is not the chain's "
                    <> show chainAddr
                )
                matches
            record
                ( DerivationEvidence
                    "state.state"
                    0
                    (showText derived)
                    (showText chainAddr)
                    ("chain-observed " <> showText stateIn)
                    DerivMatch
                    derivationVenue
                )
        RequestAddressApplied -> do
            canonical <- seedOf world row CanonicalSeed
            booted <- bootOf world row CanonicalSeed
            let cfg = publishedConfig canonical
                (_, requestBytes, _) = identityCodes world
                unapplied =
                    Addr
                        Testnet
                        (ScriptHashObj (computeScriptHash requestBytes))
                        StakeRefNull
                deployed = requestAddrFromCfg cfg (bootedToken booted) (network cfg)
            require
                (label <> ": the applied request address equals the unapplied one")
                (deployed /= unapplied)
            record
                ( DerivationEvidence
                    "request.request"
                    2
                    (showText deployed)
                    (showText unapplied)
                    "pinned-unapplied"
                    DerivDistinct
                    derivationVenue
                )
        CorruptedDerivationRefused -> do
            canonical <- seedOf world row CanonicalSeed
            (stateIn, stateOut) <- stateOutput env world row CanonicalSeed
            let cfg = publishedConfig canonical
                (stateBytes, _, _) = identityCodes world
                corrupted = applyPreviousPolicies [] stateBytes
                corruptedCfg =
                    cfg
                        { cageScriptBytes = corrupted
                        , cfgScriptHash = computeScriptHash corrupted
                        }
                chainAddr = stateOut ^. addrTxOutL
                (derived, matches) =
                    derivationMatches
                        (cageAddrFromCfg corruptedCfg (network cfg))
                        chainAddr
            if armed
                then
                    require
                        ( label
                            <> ": corrupted derivation "
                            <> show derived
                            <> " was required to pass for the deployed script; the chain reports "
                            <> show chainAddr
                            <> " — the check fails for that result, proving it can fail"
                        )
                        matches
                else
                    require
                        (label <> ": the corrupted derivation was accepted")
                        (not matches)
            record
                ( DerivationEvidence
                    "state.state"
                    0
                    (showText derived)
                    (showText chainAddr)
                    ("chain-observed " <> showText stateIn)
                    DerivRefused
                    derivationVenue
                )
    emit "held" (row <> ": " <> instructionReading instruction)
  where
    control = controlName (envControl env)
    armed = armedBy control instruction
    label = if armed then row <> " ARMED (" <> control <> ")" else row
    record e = modifyIORef' evidence (e :)
    showText :: (Show a) => a -> T.Text
    showText = T.pack . show

-- ---------------------------------------------------------
-- Seeds and registries
-- ---------------------------------------------------------

{- | Publish a seed by a designation split: the largest wallet output becomes
two outputs at the genesis wallet, the first the seed and the second the
remainder. One seed exists per split, so no boot can consume the wrong output.
The canonical seed gets the canonical configuration; any other seed the same
configuration with only the seed changed.
-}
publishSeed
    :: Cage.Provider IO
    -> Capabilities
    -> IdentityWorld
    -> String
    -> Seed
    -> IO ()
publishSeed prov caps world row seed = do
    known <- readIORef (identitySeeds world)
    when (Map.member seed known) $
        failWith (row <> ": " <> show seed <> " is already published")
    (seedIn, _) <- designateSplit prov caps (show seed)
    let reference = txInToRef seedIn
        (stateBytes, requestBytes, namingCodes) = identityCodes world
    config <- case seed of
        CanonicalSeed -> pure (cageCfg stateBytes requestBytes namingCodes reference)
        _ -> case Map.lookup CanonicalSeed known of
            Just canonical -> pure ((publishedConfig canonical){cageSeed = reference})
            Nothing ->
                failWith (row <> ": publish the canonical seed before " <> show seed)
    modifyIORef'
        (identitySeeds world)
        (Map.insert seed (PublishedSeed reference config Nothing))
    emit
        "seed"
        ( show seed
            <> " published at output reference "
            <> show reference
            <> "; its registry's name is SHA-256 of this reference"
        )

designateSplit
    :: Cage.Provider IO -> Capabilities -> String -> IO (TxIn, TxIn)
designateSplit prov submit label = do
    (gIn, gOut) <- largestWalletUtxo prov
    let Coin total = gOut ^. coinTxOutL
        seedCoin = 2_000_000
        fee = 1_000_000
        rest = total - seedCoin - fee
        body =
            mkBasicTxBody
                & inputsTxBodyL .~ Set.singleton gIn
                & outputsTxBodyL
                    .~ StrictSeq.fromList
                        [ mkBasicTxOut genesisAddr (MaryValue (Coin seedCoin) mempty)
                        , mkBasicTxOut genesisAddr (MaryValue (Coin rest) mempty)
                        ]
                & feeTxBodyL .~ Coin fee
        tx = mkBasicTx body
    require
        ("designation: wallet too small for the " <> label <> " split")
        (rest > seedCoin)
    result <- submitSigned (capSubmit submit) (signTx genesisSignKey tx)
    case result of
        Submitted _ -> pure ()
        Rejected reason ->
            failWith
                ( "designation split refused: "
                    <> T.unpack (TE.decodeUtf8Lenient reason)
                )
    capConfirm submit tx
    after <- Cage.withView prov (`Cage.viewUTxOsAt` genesisAddr)
    let txid = txIdHex tx
        mine =
            sortOn
                (txInIndex . fst)
                [p | p@(i, _) <- after, txInTxIdHex i == txid]
    case mine of
        [seedOut, funder] -> pure (fst seedOut, fst funder)
        _ ->
            failWith
                ( "designation: expected two outputs from the "
                    <> label
                    <> " split, found "
                    <> show (length mine)
                )

{- | Boot a registry from a published seed. The ledger must accept it: a
refusal of an internally consistent registry, rival or not, contradicts the
settled design that a permissionless ledger cannot prohibit one, and is
reported as a finding.
-}
bootFrom :: Env -> IdentityWorld -> String -> Seed -> IO ()
bootFrom env world row seed = do
    published <- seedOf world row seed
    case publishedBoot published of
        Just _ ->
            failWith (row <> ": " <> show seed <> "'s registry is already booted")
        Nothing -> pure ()
    let cfg = publishedConfig published
    unsigned <-
        Cage.withView (envProv env) (\v -> bootTokenImpl cfg v genesisAddr)
    (mem, cpu) <- measureUnits env unsigned
    let witnessed = signTx genesisSignKey unsigned
        signed = signedTx witnessed
    result <- submitTxResilient (envSubmit env) witnessed
    case result of
        Submitted _ -> pure ()
        Rejected reason ->
            failWith
                ( row
                    <> " FINDING: the ledger refused the boot of "
                    <> show seed
                    <> "'s registry ("
                    <> T.unpack (TE.decodeUtf8Lenient reason)
                    <> ") — a permissionless ledger cannot prohibit an internally consistent registry; reported, not relabelled"
                )
    confirmTx env signed
    let size = txSizeBytes signed
    emitMeasure env (row <> "-boot") mem cpu size
    token <- extractTokenId cfg signed
    (stateIn, stateOut) <- stateUtxoByToken env cfg token
    let booted =
            Booted
                { bootedToken = token
                , bootedTransaction = unsigned
                , bootedMeasure = Measured (txIdHex signed) mem cpu size
                , bootedState =
                    (stateIn, stateOut ^. valueTxOutL, stateOut ^. datumTxOutL)
                }
    modifyIORef'
        (identitySeeds world)
        (Map.adjust (\p -> p{publishedBoot = Just booted}) seed)

{- | The registry's only name under the canonical policy is the SHA-256 of
its seed's output reference, at quantity one, and the derivation of a
fabricated reference to the same transaction does not appear. Armed, the
fabricated derivation is demanded instead.
-}
nameIsDerivation
    :: Env -> IdentityWorld -> String -> Bool -> Seed -> IO ()
nameIsDerivation env world label armed seed = do
    published <- seedOf world label seed
    (_, stateOut) <- stateOutput env world label seed
    let cfg = publishedConfig published
        reference = publishedReference published
        policy = scriptHashBytes (policyID (cagePolicyIdFromCfg cfg))
        derived = deriveAssetName reference
        fabricated = deriveAssetName reference{txOutRefIdx = txOutRefIdx reference + 1}
        wanted = if armed then fabricated else derived
        underPolicy = Map.lookup policy (outAssets stateOut)
        names = maybe [] Map.keys underPolicy
    require
        ( label
            <> ": the policy carries names "
            <> show (map hex names)
            <> ", wanted exactly 0x"
            <> hex wanted
            <> " at quantity one"
        )
        (fmap Map.toList underPolicy == Just [(wanted, 1)])
    require
        ( label
            <> ": the fabricated reference's derivation 0x"
            <> hex fabricated
            <> " matches the chain name — the derivation is not bound to the seed"
        )
        (fabricated `notElem` names)

{- | Pay an output to the canonical address carrying the canonical state datum
and no token. Creating an output does not execute the receiving script: the
transaction carries no script witness, the node evaluates no purpose for it,
and the same detector finds the script the canonical boot carried.
-}
forgeTokenlessOutput :: Env -> IdentityWorld -> String -> IO ()
forgeTokenlessOutput env world label = do
    canonical <- seedOf world label CanonicalSeed
    booted <- bootOf world label CanonicalSeed
    (_, stateOut) <- stateOutput env world label CanonicalSeed
    let cfg = publishedConfig canonical
        prov = envProv env
        scriptAddr = cageAddrFromCfg cfg (network cfg)
    datum <- case extractCageDatum stateOut of
        Just (StateDatum s) -> pure s
        _ ->
            failWith (label <> ": the canonical state has no state datum to copy")
    (funderIn, funderOut) <- largestWalletUtxo prov
    let Coin available = funderOut ^. coinTxOutL
        forgedCoin = 2_000_000
        fee = 500_000
        change = available - forgedCoin - fee
        forgedOut =
            mkBasicTxOut scriptAddr (MaryValue (Coin forgedCoin) mempty)
                & datumTxOutL .~ mkInlineDatum (toPlcData (StateDatum datum))
        changeOut = mkBasicTxOut genesisAddr (MaryValue (Coin change) mempty)
        unsigned =
            mkBasicTx
                ( mkBasicTxBody
                    & inputsTxBodyL .~ Set.singleton funderIn
                    & outputsTxBodyL .~ StrictSeq.fromList [forgedOut, changeOut]
                    & feeTxBodyL .~ Coin fee
                )
    require
        (label <> ": the funder is too small for the forgery")
        (change > forgedCoin)
    require
        ( label
            <> ": the detector finds no script on the canonical boot, which carried the state script"
        )
        (not (null (txScriptWitnesses (bootedTransaction booted))))
    require
        (label <> ": the forged transaction carries script witnesses")
        (null (txScriptWitnesses unsigned))
    evaluated <- Cage.withView prov (`Cage.viewEvaluateTx` unsigned)
    require
        ( label
            <> ": the node evaluated "
            <> show (Map.size evaluated)
            <> " script purposes on a plain payment"
        )
        (Map.null evaluated)
    let witnessed = signTx genesisSignKey unsigned
        signed = signedTx witnessed
    result <- submitTxResilient (envSubmit env) witnessed
    case result of
        Rejected reason ->
            failWith
                ( label
                    <> ": the ledger refused the forged output ("
                    <> T.unpack (TE.decodeUtf8Lenient reason)
                    <> ") — creating an output at an address needs nobody's permission"
                )
        Submitted _ -> pure ()
    confirmTx env signed
    let size = txSizeBytes signed
    emitMeasure env (label <> "-forged") 0 0 size
    live <- Cage.withView prov (`Cage.viewUTxOsAt` scriptAddr)
    output <- case [o | (i, o) <- live, txInTxIdHex i == txIdHex signed] of
        [o] -> pure o
        other ->
            failWith
                ( label
                    <> ": expected the forged output live at the canonical address, found "
                    <> show (length other)
                )
    require
        (label <> ": the detector reports a script on the forged payment")
        (null (txScriptWitnesses signed))
    modifyIORef'
        (identityForgery world)
        (const (Just (Forgery (Measured (txIdHex signed) 0 0 size) output)))

seedOf :: IdentityWorld -> String -> Seed -> IO PublishedSeed
seedOf world row seed = do
    known <- readIORef (identitySeeds world)
    case Map.lookup seed known of
        Just p -> pure p
        Nothing ->
            failWith
                ( row
                    <> ": "
                    <> show seed
                    <> " is not published; run the rows in inventory order"
                )

bootOf :: IdentityWorld -> String -> Seed -> IO Booted
bootOf world row seed = do
    published <- seedOf world row seed
    case publishedBoot published of
        Just b -> pure b
        Nothing ->
            failWith
                ( row
                    <> ": "
                    <> show seed
                    <> "'s registry is not booted; run the rows in inventory order"
                )

-- | A booted registry's state output, read back from the chain.
stateOutput
    :: Env -> IdentityWorld -> String -> Seed -> IO (TxIn, TxOut ConwayEra)
stateOutput env world row seed = do
    published <- seedOf world row seed
    booted <- bootOf world row seed
    stateUtxoByToken env (publishedConfig published) (bootedToken booted)

stateUtxoByToken
    :: Env -> CageConfig -> TokenId -> IO (TxIn, TxOut ConwayEra)
stateUtxoByToken env cfg token = do
    utxos <-
        Cage.withView
            (envProv env)
            (`Cage.viewUTxOsAt` cageAddrFromCfg cfg (network cfg))
    case findStateUtxo (cagePolicyIdFromCfg cfg) token utxos of
        Just u -> pure u
        Nothing ->
            failWith
                ( "no state output carrying token "
                    <> hex (SBS.fromShort (assetNameBytes (unTokenId token)))
                    <> " is live at the registry address"
                )

-- | The cited transaction's id and measurements.
citedMeasure :: IdentityWorld -> String -> Citation -> IO Measured
citedMeasure world row citation = case citation of
    CitesBootOf seed -> bootedMeasure <$> bootOf world row seed
    CitesForgery -> do
        forged <- readIORef (identityForgery world)
        maybe
            (failWith (row <> ": the receipt cites a forgery no instruction made"))
            (pure . forgeryMeasure)
            forged
