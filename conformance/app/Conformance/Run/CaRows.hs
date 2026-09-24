{- |
Module      : Conformance.Run.CaRows
Description : Split out of Conformance.Run (#263); see that module's header
License     : Apache-2.0
-}
module Conformance.Run.CaRows (withCa, designateSplit, runCA01, runCA02, runCA03, runCA04, runCA05, canonicalStateUtxo, rivalStateUtxo, stateUtxoByToken) where

import Conformance.Run.Control
import Conformance.Run.Receipts
import Conformance.Run.Units
import Conformance.Run.Wallet
import Conformance.Run.Submit
import Conformance.Run.Environment
import Conformance.Run.Observe
import Conformance.Run.Manifest

import Data.ByteString.Short qualified as SBS
import Data.IORef (readIORef, writeIORef)
import Data.List (sortOn)
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust)
import Data.Sequence.Strict qualified as StrictSeq
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Lens.Micro ((&), (.~), (^.))

import Cardano.Ledger.Address (Addr (..))

import Cardano.Ledger.Api.Tx (
    mkBasicTx,
    mkBasicTxBody,
 )
import Cardano.Ledger.Api.Tx.Body (
    feeTxBodyL,
    inputsTxBodyL,
    outputsTxBodyL,
 )
import Cardano.Ledger.Api.Tx.Out (
    addrTxOutL,
    coinTxOutL,
    datumTxOutL,
    mkBasicTxOut,
    valueTxOutL,
 )
import Cardano.Ledger.BaseTypes (Network (..))
import Cardano.Ledger.Credential (Credential (..), StakeReference (..))
import Cardano.Ledger.Mary.Value (MaryValue (..))
import Cardano.Ledger.TxIn (TxIn (..))

import Singular.Registry.AssetName (deriveAssetName)
import Singular.Registry.Blueprint (applyPreviousPolicies)
import Singular.Registry.Config (CageConfig (..))
import Singular.Registry.Ledger (
    AssetName (..),
    Coin (..),
    ConwayEra,
    PolicyID (..),
    TokenId (..),
    TxOut,
 )
import Singular.Registry.Provider qualified as Cage
import Singular.Registry.TxBuilder.Boot (bootTokenImpl)
import Singular.Registry.TxBuilder.Internal (
    cageAddrFromCfg,
    cagePolicyIdFromCfg,
    computeScriptHash,
    extractCageDatum,
    findStateUtxo,
    mkInlineDatum,
    requestAddrFromCfg,
    scriptHashBytes,
    toPlcData,
    txInToRef,
 )
import Singular.Registry.Types (
    CageDatum (..),
    OnChainTxOutRef (..),
 )
import Cardano.Node.Client.E2E.Setup (addKeyWitness)
import Cardano.Node.Client.Submitter (
    SubmitResult (..),
    Submitter (..),
 )

import Conformance.Authenticate (
    AuthDecision (..),
    AuthReject (..),
    authenticate,
    authenticateWeak,
 )
import Conformance.Mirror (
    emit,
    failWith,
    hex,
    require,
    txIdHex,
 )
import Conformance.Receipt (
    DerivationEvidence (..),
    DerivationOutcome (..),
    Outcome (..),
    Verdict (..),
    derivationMatches,
    derivationVenue,
 )

withCa :: Env -> String -> (Env -> CaWorld -> IO ()) -> IO ()
withCa env row f = case envCa env of
    Just w -> f env w
    Nothing -> failWith ("row " <> row <> " needs a CA session")


-- ---------------------------------------------------------
-- CA rows (issue #69): canonical identity authentication
-- ---------------------------------------------------------

{- | The designation split: the largest wallet UTxO becomes two
outputs at the genesis wallet — output 0 is the new seed, output 1
the funding remainder. One seed candidate exists per split, so no
boot can ever consume the wrong UTxO as its funder, and the seed's
outRef is published by the split transaction itself.
-}
designateSplit ::
    Cage.Provider IO -> Submitter IO -> String -> IO (TxIn, TxIn)
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
    result <- submitTx submit (addKeyWitness genesisSignKey tx)
    case result of
        Submitted _ -> pure ()
        Rejected reason ->
            failWith
                ( "designation split refused: "
                    <> T.unpack (TE.decodeUtf8Lenient reason)
                )
    awaitTx tx
    after <- Cage.queryUTxOs prov genesisAddr
    let txid = txIdHex tx
        mine =
            sortOn (txInIndex . fst)
                [p | p@(i, _) <- after, txInTxIdHex i == txid]
    case mine of
        [seed, funder] -> pure (fst seed, fst funder)
        _ ->
            failWith
                ( "designation: expected two outputs from the "
                    <> label
                    <> " split, found "
                    <> show (length mine)
                )


{- | CA01: boot the canonical registry from the published seed, then
recompute the token name in Haskell as SHA-256 of the seed's outRef
and match it against the state UTxO read from the chain: exactly
that name at quantity one under the canonical policy. The executing
control: the same derivation over a fabricated outRef must NOT
match. With @false-claim@ armed the fabricated derivation is bound
to the match instead, and the run must fail.
-}
runCA01 :: Env -> CaWorld -> IO ()
runCA01 env w = do
    let cfg = caCfg w
        prov = envProv env
    unsignedBoot <- bootTokenImpl cfg prov genesisAddr
    (mem, cpu) <- measureUnits env unsignedBoot
    let signedBoot = addKeyWitness genesisSignKey unsignedBoot
    result <- submitTxResilient (envSubmit env) signedBoot
    case result of
        Submitted _ -> pure ()
        Rejected reason ->
            failWith
                ( "CA01: the node refused the canonical boot: "
                    <> T.unpack (TE.decodeUtf8Lenient reason)
                )
    awaitTx signedBoot
    let size = txSizeBytes signedBoot
    emitMeasure env "CA01-boot" mem cpu size
    tid <- extractTokenId cfg signedBoot
    writeIORef (caTidRef w) (Just tid)
    writeIORef
        (caBootTxRef w)
        (Just unsignedBoot)
    writeIORef
        (caBootMeasureRef w)
        (Just (txIdHex signedBoot, mem, cpu, size))
    -- read the state UTxO back from the chain at the cage address
    -- (CA04 derives that address independently and cross-checks it)
    (stateIn, stateOut) <- canonicalStateUtxo env w
    let policyBytes =
            scriptHashBytes (policyID (cagePolicyIdFromCfg cfg))
        derivedName = deriveAssetName (caSeedRef w)
        fabricatedRef =
            (caSeedRef w){txOutRefIdx = txOutRefIdx (caSeedRef w) + 1}
        wrongName = deriveAssetName fabricatedRef
        underPolicy =
            Map.lookup policyBytes (outAssets stateOut)
        expectedName = case envControl env of
            FalseClaim -> wrongName
            _ -> derivedName
    require
        "CA01: the state UTxO carries no assets under the canonical policy"
        (maybe False (not . Map.null) underPolicy)
    let chainNames = maybe [] (map fst . Map.toList) underPolicy
    require
        ( "CA01: the canonical policy carries names "
            <> show (map hex chainNames)
            <> ", wanted exactly 0x"
            <> hex expectedName
            <> " at quantity one"
        )
        (fmap Map.toList underPolicy == Just [(expectedName, 1)])
    require
        ( "CA01 control failed: the fabricated outRef's derivation 0x"
            <> hex wrongName
            <> " matches the chain name — the derivation is not \
               \seed-bound"
        )
        (wrongName `notElem` chainNames)
    writeIORef
        (caSnapRef w)
        ( Just
            CaSnap
                { csIn = stateIn
                , csValue = stateOut ^. valueTxOutL
                , csDatum = stateOut ^. datumTxOutL
                }
        )
    writeRowReceipt
        env
        "CA01"
        Accepted
        AgreesWithModel        [txIdHex signedBoot]
        Nothing
        Nothing
        (Just mem)
        (Just cpu)
        (Just size)
        "node-submit"
        Nothing
    emit
        "row"
        ( "CA01: canonical registry token name 0x"
            <> hex derivedName
            <> " = SHA-256 of the published seed's outRef, matched \
               \on chain at quantity one; the fabricated outRef \
               \derives 0x"
            <> hex wrongName
            <> " and does not match (control)"
        )


{- | CA02: initialize a rival registry from a second seed through the
same bootstrap path. The ledger ACCEPTS it — the settled finding
(naming-correspondence.md, "What t50 settled"): a permissionless
ledger cannot prohibit a rival, so canonical identity is a
derivation the consumer authenticates, not a refusal the chain
performs. The row asserts three things, each read back from the
chain: the rival is accepted and live at the applied address, the
two token names differ (each the SHA-256 of its own seed's outRef),
and the canonical registry is unaffected — same UTxO, same value,
same datum bytes as CA01's snapshot. The authentication then rejects
the rival on the derived name while accepting the canonical
registry.
-}
runCA02 :: Env -> CaWorld -> IO ()
runCA02 env w = do
    tidC <- readIORef (caTidRef w)
    require "CA02 needs CA01's canonical registry; run CA01 first" (isJust tidC)
    -- the second designation split: output 0 is the rival seed
    (rivalIn, _) <- designateSplit (envProv env) (envSubmit env) "rival"
    let rivalRef = txInToRef rivalIn
        cfgR = (caCfg w){cageSeed = rivalRef}
        prov = envProv env
    unsignedRival <- bootTokenImpl cfgR prov genesisAddr
    (mem, cpu) <- measureUnits env unsignedRival
    let signedRival = addKeyWitness genesisSignKey unsignedRival
    result <- submitTxResilient (envSubmit env) signedRival
    case result of
        Rejected reason ->
            failWith
                ( "CA02 FINDING: the ledger REFUSED the internally \
                  \consistent rival ("
                    <> T.unpack (TE.decodeUtf8Lenient reason)
                    <> ") — contradicts the settled design \
                       \(naming-correspondence.md, What t50 settled); \
                       \reported, not relabelled"
                )
        Submitted _ -> pure ()
    awaitTx signedRival
    let size = txSizeBytes signedRival
    emitMeasure env "CA02-rival-boot" mem cpu size
    tidR <- extractTokenId cfgR signedRival
    writeIORef (caRivalTidRef w) (Just tidR)
    -- read both registries back from the chain
    (_, rivalOut) <- rivalStateUtxo env w
    (canonIn, canonOut) <- canonicalStateUtxo env w
    let cfg = caCfg w
        policyBytes =
            scriptHashBytes (policyID (cagePolicyIdFromCfg cfg))
        canonicalName = deriveAssetName (caSeedRef w)
        rivalName = deriveAssetName rivalRef
        policyAsset out =
            Map.lookup policyBytes (outAssets out)
    -- 1. the rival was accepted: its UTxO is live, read above
    -- 2. the two token names differ, both read from the chain and
    --    each the SHA-256 of its own seed's outRef
    require
        "CA02: the canonical state's policy assets are not exactly the derived name at quantity one"
        (policyAsset canonOut == Just (Map.singleton canonicalName 1))
    require
        "CA02: the rival state's policy assets are not exactly its own seed's derivation at quantity one"
        (policyAsset rivalOut == Just (Map.singleton rivalName 1))
    require
        ( "CA02: the rival name equals the canonical name — \
          \derivation broken ("
            <> hex rivalName
            <> ")"
        )
        (rivalName /= canonicalName)
    -- 3. the canonical registry is unaffected: same UTxO, value and
    --    datum bytes as CA01's snapshot
    snap <- readIORef (caSnapRef w)
    case snap of
        Nothing -> failWith "CA02: no canonical snapshot; run CA01 first"
        Just s -> do
            require
                "CA02: the canonical registry UTxO moved"
                (csIn s == canonIn)
            require
                "CA02: the canonical registry value changed"
                (csValue s == canonOut ^. valueTxOutL)
            require
                "CA02: the canonical registry datum changed"
                (csDatum s == canonOut ^. datumTxOutL)
    -- the consumer's authentication, on chain-read assets: the
    -- derived canonical name accepts the canonical registry and
    -- rejects the rival
    let authRival =
            authenticate policyBytes canonicalName (outAssets rivalOut)
        authCanon =
            authenticate policyBytes canonicalName (outAssets canonOut)
    require
        ( "CA02: authentication accepted the rival — the derived \
          \name does not bind ("
            <> show authRival
            <> ")"
        )
        (authRival == AuthReject NameMismatch)
    require
        "CA02: authentication rejected the canonical registry"
        (authCanon == AuthAccept)
    -- the receipt records the LEDGER's verdict on the row's tx:
    -- accepted. The authentication's rejection is the assertion
    -- above, never a relabelling of the acceptance.
    writeIORef
        (caRivalMeasure w)
        (Just (txIdHex signedRival, mem, cpu, size))
    writeRowReceipt
        env
        "CA02"
        Accepted
        AgreesWithModel        [txIdHex signedRival]
        Nothing
        Nothing
        (Just mem)
        (Just cpu)
        (Just size)
        "node-submit"
        Nothing
    emit
        "row"
        ( "CA02: rival ACCEPTED by the ledger, as the settled design \
          \requires — tx="
            <> txIdHex signedRival
            <> " live at the applied address under token 0x"
            <> hex rivalName
            <> " vs canonical 0x"
            <> hex canonicalName
            <> " (each SHA-256 of its own seed's outRef); the \
               \canonical registry is unaffected: same UTxO, value \
               \and datum bytes as the CA01 snapshot; authentication \
               \rejects the rival on the derived name"
        )


{- | CA03: the executing negative control that makes CA02 worth
anything. An authenticator checking only policy and address — not
the derived name — ACCEPTS the rival read back from the chain: the
rival is indistinguishable from the canonical registry on every leg
except the name. The same chain-read value bound to the full
authenticator is rejected, so CA02's rejection is attributable to
the derived name alone. Armed (@naive-authenticator@) the row
instead requires the weak authenticator to reject the rival, which
it cannot, and the run fails naming the accepted rival.
-}
runCA03 :: Env -> CaWorld -> IO ()
runCA03 env w = do
    (rivalIn, rivalOut) <- rivalStateUtxo env w
    let cfg = caCfg w
        policyBytes =
            scriptHashBytes (policyID (cagePolicyIdFromCfg cfg))
        canonicalName = deriveAssetName (caSeedRef w)
        weak = authenticateWeak policyBytes (outAssets rivalOut)
        strong = authenticate policyBytes canonicalName (outAssets rivalOut)
    if envControl env == NaiveAuthenticator
        then
            failWith
                ( "CA03 ARMED (naive-authenticator): the policy+address \
                  \authenticator ACCEPTED the rival (UTxO "
                    <> show rivalIn
                    <> "), as designed — the run required the control \
                       \to reject, so the run fails here: without the \
                       \derived-name check the rival passes for the \
                       \canonical registry"
                )
        else pure ()
    require
        ( "CA03: the weak authenticator REJECTED the rival — the \
          \control does not discriminate: policy+address already \
          \excludes the rival, so CA02's rejection is not \
          \attributable to the name check"
        )
        (weak == AuthAccept)
    require
        ( "CA03: the strong authenticator accepted the rival — CA02's \
          \discrimination is gone ("
            <> show strong
            <> ")"
        )
        (strong == AuthReject NameMismatch)
    m <- readIORef (caRivalMeasure w)
    case m of
        Nothing ->
            failWith "CA03: no rival measurements; run CA02 first"
        Just (txid, mem, cpu, size) ->
            writeRowReceipt
                env
                "CA03"
                Accepted
                AgreesWithModel                [txid]
                Nothing
                Nothing
                (Just mem)
                (Just cpu)
                (Just size)
                "node-submit"
                Nothing
    emit
        "row"
        ( "CA03: control fired — the policy+address authenticator \
          \accepts the rival (weak="
            <> show weak
            <> ") while the derived-name check rejects it (strong="
            <> show strong
            <> "): the name is the only discriminator"
        )


{- | CA04: identity derivation per validator by declared arity.
The published manifest (@onchain/script-identity.json@) pins the
state hash and declares parameter count 0; the run requires arity
0, derives the deployment address through the PRODUCTION path
(@cageAddrFromCfg@, the function boot uses) and requires the
actual observed chain address to equal it. Request stays arity 2:
its deployed address must differ from the unapplied request bytes
(live distinctness). One checker decides both the ordinary
derivation and the exact-extra-application (List[]) corruption
against the same observed chain address; the mismatch is observed
and recorded, and the armed flag demands the corrupted derivation
pass (it must fail). The receipt carries typed addresses, arity,
match/distinct/refused outcomes and the explicit off-chain
identity venue — never phase-2 ledger evidence.
-}
runCA04 :: Env -> CaWorld -> IO ()
runCA04 env w = do
    manifest <- readScriptManifest
    let pins = pinsUnder "state.state" manifest
    (pinHash, pinParam) <- case pins of
        [] -> failWith "CA04: the manifest pins no state.state entry"
        (h, p) : rest
            | any ((/= h) . fst) rest ->
                failWith
                    ("CA04: the manifest's pins disagree: " <> show pins)
            | any ((/= p) . snd) rest ->
                failWith
                    ( "CA04: the manifest's parameter counts disagree: "
                        <> show pins
                    )
            | otherwise -> pure (h, p)
    let stateRaw = caRawState w
        unappliedHex = hex (scriptHashBytes (computeScriptHash stateRaw))
    require
        ( "CA04: the pinned unapplied hash 0x"
            <> T.unpack pinHash
            <> " is not this run's blueprint code 0x"
            <> unappliedHex
        )
        (pinHash == T.pack unappliedHex)
    require
        ( "CA04: the manifest declares "
            <> show pinParam
            <> " parameters for state.state, wanted 0 \
               \(zero-parameter state)"
        )
        (pinParam == Just 0)
    -- State arity 0 (NOTE-060, E18 dispositions): the state()
    -- validator takes no parameters — deploy the pinned bytes
    -- directly. The derivation below goes through the PRODUCTION
    -- path (cageAddrFromCfg, the function boot uses), never a
    -- test-only recomputation. Request stays arity 2 (live
    -- distinctness below).
    (stateInCA, stateOut) <- canonicalStateUtxo env w
    let chainAddr = stateOut ^. addrTxOutL
        chainOutref = T.pack (show stateInCA)
        cfg = caCfg w
        -- One checker, both sides (NOTE-067): the same acceptance
        -- decision on the ordinary config and the exact-extra-
        -- application config, with the observed chainAddr held
        -- constant. Separate inequality-only assertions are ruled
        -- out: they pass even if the normal comparison accepts all.
        checkDerivation dcfg =
            let actual = cageAddrFromCfg dcfg (network dcfg)
             in derivationMatches actual chainAddr
        (normalAddr, normalMatches) = checkDerivation cfg
    emit
        "identity"
        ( "CA04: state arity 0 — production derivation "
            <> show normalAddr
            <> " vs chain "
            <> show chainAddr
            <> " (layer equality expected here, carries no weight alone)"
        )
    require "CA04 normal derivation mismatch" normalMatches
    -- Request arity 2 (E18: distinctness retained): the deployed
    -- request address must differ from the unapplied request bytes.
    -- A blanket equal-layers restatement would erase this live
    -- discriminator.
    mTidCA04 <- readIORef (caTidRef w)
    tidCA04 <- case mTidCA04 of
        Just t -> pure t
        Nothing -> failWith "CA04: no token id; run CA01 first"
    let (_, requestBytesCA04, _) = envCodes env
        unappliedReqAddr =
            Addr
                Testnet
                (ScriptHashObj (computeScriptHash requestBytesCA04))
                StakeRefNull
        deployedReqAddr = requestAddrFromCfg cfg tidCA04 (network cfg)
    require
        ( "CA04: request applied layer equals unapplied layer — "
            <> "distinctness lost"
        )
        (deployedReqAddr /= unappliedReqAddr)
    emit
        "identity"
        ( "CA04: request arity 2 distinctness holds (deployed "
            <> show deployedReqAddr
            <> " /= unapplied "
            <> show unappliedReqAddr
            <> ")"
        )
    -- Executed negative, both sides same checker (NOTE-064, E18
    -- venue): the corrupted config differs from cfg in exactly one
    -- thing (the extra List[] application); the observed chain
    -- address is held constant. The mismatch is OBSERVED by the
    -- require below and recorded as DerivRefused — never hardcoded.
    -- Off-chain identity-derivation refusal, not phase-2 ledger
    -- evidence (receipt venue states it).
    let corruptedBytes = applyPreviousPolicies [] stateRaw
        corruptedCfg =
            cfg
                { cageScriptBytes = corruptedBytes
                , cfgScriptHash = computeScriptHash corruptedBytes
                }
        (badAddr, badMatches) = checkDerivation corruptedCfg
        corruptedHex = hex (scriptHashBytes (computeScriptHash corruptedBytes))
    emit
        "identity"
        ( "CA04 derivation [corrupted-List[]]: derived "
            <> show badAddr
            <> " vs chain "
            <> show chainAddr
        )
    require "CA04 corrupted derivation was accepted" (not badMatches)
    emit
        "control"
        ( "CA04: corrupted List[] derivation 0x"
            <> corruptedHex
            <> " refused (mismatch observed via the same checker) — extra application breaks identity"
        )
    if envControl env == UnappliedAddress
        then
            require
                ( "CA04 ARMED (unapplied-address): corrupted derivation "
                    <> show badAddr
                    <> " was required to pass for the deployed script; the chain reports "
                    <> show chainAddr
                    <> " — the check fails for that result, proving it can fail"
                )
                badMatches
        else
            emit
                "control"
                "CA04: armed equality demand available under CONFORMANCE_CONTROL=unapplied-address"
    let derivationEvidence =
            [ DerivationEvidence
                { deValidator = "state.state"
                , deArity = 0
                , deComputed = T.pack (show normalAddr)
                , deReference = T.pack (show chainAddr)
                , deReferenceSource = "chain-observed " <> chainOutref
                , deOutcome = DerivMatch
                , deVenue = derivationVenue
                }
            , DerivationEvidence
                { deValidator = "request.request"
                , deArity = 2
                , deComputed = T.pack (show deployedReqAddr)
                , deReference = T.pack (show unappliedReqAddr)
                , deReferenceSource = "pinned-unapplied"
                , deOutcome = DerivDistinct
                , deVenue = derivationVenue
                }
            , DerivationEvidence
                { deValidator = "state.state"
                , deArity = 0
                , deComputed = T.pack (show badAddr)
                , deReference = T.pack (show chainAddr)
                , deReferenceSource = "chain-observed " <> chainOutref
                , deOutcome = DerivRefused
                , deVenue = derivationVenue
                }
            ]
    m <- readIORef (caBootMeasureRef w)
    case m of
        Nothing -> failWith "CA04: no boot measurements; run CA01 first"
        Just (txid, mem, cpu, size) ->
            writeRowReceipt
                env
                "CA04"
                Accepted
                AgreesWithModel                [txid]
                Nothing
                Nothing
                (Just mem)
                (Just cpu)
                (Just size)
                derivationVenue
                (Just derivationEvidence)
    emit
        "row"
        ( "CA04: pinned state 0x"
            <> unappliedHex
            <> " (0 declared parameters, arity 0) — production derivation "
            <> show normalAddr
            <> " equals the chain-reported address; request arity 2 distinct; corrupted derivation refused via the same checker (receipt carries all three, off-chain venue)"
        )


{- | CA05: a forged output at the canonical address carrying no
registry token is not a registry — and creating it executes
nothing. The protocol specification's rule: creating an output at
Singular's address MUST NOT be treated as execution of its spending
validator. The row shows NO script executed — the accepted
transaction carries no script witness, no redeemer and no mint, and
the node's evaluation reports no purpose — not merely that nothing
bad happened: the same detector fires on the CA01 boot tx, which
carried the state script. The authentication rejects the forgery on
the missing policy token.
-}
runCA05 :: Env -> CaWorld -> IO ()
runCA05 env w = do
    let cfg = caCfg w
        prov = envProv env
        scriptAddr = cageAddrFromCfg cfg (network cfg)
        policyBytes =
            scriptHashBytes (policyID (cagePolicyIdFromCfg cfg))
    -- the forgery mimics the registry as closely as an output can:
    -- the canonical address and the canonical datum itself, minus
    -- the only thing that makes it a registry — the token
    (_, stateOut) <- canonicalStateUtxo env w
    datum <- case extractCageDatum stateOut of
        Just (StateDatum s) -> pure s
        _ -> failWith "CA05: the canonical state has no StateDatum to copy"
    (funderIn, funderOut) <- largestWalletUtxo prov
    let Coin avail = funderOut ^. coinTxOutL
        forgedCoin = 2_000_000
        fee = 500_000
        change = avail - forgedCoin - fee
        forgedOut =
            mkBasicTxOut scriptAddr (MaryValue (Coin forgedCoin) mempty)
                & datumTxOutL .~ mkInlineDatum (toPlcData (StateDatum datum))
        changeOut = mkBasicTxOut genesisAddr (MaryValue (Coin change) mempty)
        body =
            mkBasicTxBody
                & inputsTxBodyL .~ Set.singleton funderIn
                & outputsTxBodyL .~ StrictSeq.fromList [forgedOut, changeOut]
                & feeTxBodyL .~ Coin fee
        unsigned = mkBasicTx body
    require "CA05: the funder is too small for the forgery" (change > forgedCoin)
    require
        "CA05: the forged tx unexpectedly carries script witnesses"
        (null (txScriptWitnesses unsigned))
    evalMap <- Cage.evaluateTx prov unsigned
    require
        ( "CA05: the node evaluated "
            <> show (Map.size evalMap)
            <> " script purposes on a plain payment"
        )
        (Map.null evalMap)
    let signed = addKeyWitness genesisSignKey unsigned
    result <- submitTxResilient (envSubmit env) signed
    case result of
        Rejected reason ->
            failWith
                ( "CA05: the ledger refused the forged output ("
                    <> T.unpack (TE.decodeUtf8Lenient reason)
                    <> ") — creating an output at an address needs \
                       \nobody's permission"
                )
        Submitted _ -> pure ()
    awaitTx signed
    let size = txSizeBytes signed
    emitMeasure env "CA05-forged" 0 0 size
    -- read the forgery back from the chain
    utxos <- Cage.queryUTxOs prov scriptAddr
    forgedLive <- case [o | (i, o) <- utxos, txInTxIdHex i == txIdHex signed] of
        [o] -> pure o
        other ->
            failWith
                ( "CA05: expected the forged output live at the canonical \
                  \address, found "
                    <> show (length other)
                )
    let verdict =
            authenticate
                policyBytes
                (deriveAssetName (caSeedRef w))
                (outAssets forgedLive)
    require
        ( "CA05: authentication accepted the forged output ("
            <> show verdict
            <> ")"
        )
        (verdict == AuthReject PolicyAbsent)
    -- the detector proven able to fire: the same no-script detector
    -- fires on the CA01 boot tx, which carried the state script
    bootTx <- readIORef (caBootTxRef w)
    case bootTx of
        Nothing -> failWith "CA05: no boot tx recorded; run CA01 first"
        Just bt ->
            require
                ( "CA05 control failed: the no-script detector did not \
                  \fire on the boot tx, which carried the state script"
                )
                (not (null (txScriptWitnesses bt)))
    require
        "CA05: the detector reported script execution on the forged payment"
        (null (txScriptWitnesses signed))
    writeRowReceipt
        env
        "CA05"
        Accepted
        AgreesWithModel        [txIdHex signed]
        Nothing
        Nothing
        (Just 0)
        (Just 0)
        (Just size)
        "node-submit"
        Nothing
    emit
        "row"
        ( "CA05: forged output accepted at the canonical address with \
          \NO script executed (no witness, no redeemer, no mint, \
          \empty node evaluation; the same detector fires on the \
          \boot tx) — creating an output is not execution of its \
          \receiving validator; authentication rejects it: no token \
          \under the canonical policy"
        )


-- ---------------------------------------------------------
-- CA helpers
-- ---------------------------------------------------------

-- | The canonical registry's state UTxO, read back from the chain.
canonicalStateUtxo :: Env -> CaWorld -> IO (TxIn, TxOut ConwayEra)
canonicalStateUtxo env w = do
    tid <- readIORef (caTidRef w)
    case tid of
        Nothing ->
            failWith "the canonical registry is not booted; run CA01 first"
        Just t -> stateUtxoByToken env w t


-- | The rival registry's state UTxO, read back from the chain.
rivalStateUtxo :: Env -> CaWorld -> IO (TxIn, TxOut ConwayEra)
rivalStateUtxo env w = do
    tid <- readIORef (caRivalTidRef w)
    case tid of
        Nothing -> failWith "the rival registry is not booted; run CA02 first"
        Just t -> stateUtxoByToken env w t


stateUtxoByToken :: Env -> CaWorld -> TokenId -> IO (TxIn, TxOut ConwayEra)
stateUtxoByToken env w tid = do
    let cfg = caCfg w
    utxos <-
        Cage.queryUTxOs
            (envProv env)
            (cageAddrFromCfg cfg (network cfg))
    case findStateUtxo (cagePolicyIdFromCfg cfg) tid utxos of
        Just u -> pure u
        Nothing ->
            failWith
                ( "no state UTxO carrying token "
                    <> hex (SBS.fromShort (assetNameBytes (unTokenId tid)))
                    <> " is live at the cage address"
                )
