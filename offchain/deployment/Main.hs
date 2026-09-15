{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Main
Description : Make a deployment once, and check it afterwards
License     : Apache-2.0

Two commands over one persistent registry.

@deployment deploy@ boots one registry and publishes one set of
reference-script outputs from the joiner's wallet, then writes the
manifest that records them. It refuses to run twice: given a manifest a
node still agrees with, it reports the deployment that already exists
rather than making a second one nobody asked for.

@deployment verify@ asks a node whether it still agrees with a manifest
and prints, claim by claim, what it answered.

Both take their node and wallet from @Singular.Registry.Node@ — the
factory devnet by default, the joiner's node with
@--node-socket@ \/ @--network-magic@ \/ @--wallet-skey@. Deploying
against a devnet the process itself spawns is possible but pointless:
the chain dies with the command. The devnet path exists so the
deployment code is exercised by the same tests every other runner is.
-}
module Main (main) where

import Control.Exception (SomeException, catch, displayException)
import Control.Monad (unless, when)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Short qualified as SBS
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.List (isPrefixOf, sortOn)
import Data.Ord (Down (..))
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import System.Directory (doesFileExist)
import System.Environment (getArgs, lookupEnv)
import System.Exit (ExitCode (..), exitWith)
import System.IO (hPutStrLn, stderr)

import Data.Sequence.Strict qualified as StrictSeq
import Lens.Micro ((&), (.~), (^.))

import Cardano.Crypto.Hash (hashToBytes)
import Cardano.Ledger.Address (decodeAddrEither)
import Cardano.Ledger.Api.Tx (bodyTxL, mkBasicTx, txIdTx)
import Cardano.Ledger.Api.Tx.Body (
    feeTxBodyL,
    inputsTxBodyL,
    mintTxBodyL,
    mkBasicTxBody,
    outputsTxBodyL,
 )
import Cardano.Ledger.Api.Tx.In (TxId (..), TxIn (..))
import Cardano.Ledger.Api.Tx.Out (
    TxOut,
    coinTxOutL,
    getMinCoinTxOut,
    mkBasicTxOut,
    referenceScriptTxOutL,
    valueTxOutL,
 )
import Cardano.Ledger.BaseTypes (Network (..), StrictMaybe (..))
import Cardano.Ledger.Core (Script, hashScript)
import Cardano.Ledger.Hashes (extractHash)
import Cardano.Ledger.Mary.Value (AssetName (..), MaryValue (..), MultiAsset (..))
import Data.Map.Strict qualified as Map
import Ouroboros.Network.Magic (NetworkMagic (..))

import Cardano.Node.Client.E2E.Setup (
    addKeyWitness,
    genesisSignKey,
    rawSerialiseSignKeyDSIGN,
 )
import Cardano.Node.Client.Submitter (SubmitResult (..), Submitter (..))
import Cardano.Tx.Ledger (ConwayTx)
import Singular.Registry.AssetName (deriveAssetName)
import Singular.Registry.Blueprint (
    applyBytesParam,
    extractCompiledCode,
    loadBlueprint,
 )
import Singular.Registry.Config (CageConfig (..))
import Singular.Registry.Deployment
import Singular.Registry.Ledger (Coin (..), ConwayEra, PParams, TokenId (..))
import Singular.Registry.Node (
    NodeSession (..),
    awaitTx,
    bech32Address,
    funderAddr,
    funderSignKey,
    withNode,
 )
import Singular.Registry.Provider qualified as Cage
import Singular.Registry.TxBuilder.Boot (bootTokenImpl)
import Singular.Registry.TxBuilder.Internal (
    ConsumerBinding (..),
    cageAddrFromCfg,
    cagePolicyIdFromCfg,
    computeScriptHash,
    deriveConsumerBinding,
    mkCageScript,
    mkRequestScript,
    scriptFromBytes,
    scriptHashBytes,
    txInToRef,
 )
import Singular.Registry.TxBuilder.Register (
    registerConsumerImpl,
    registerScriptImpl,
 )

-- ---------------------------------------------------------
-- Entry
-- ---------------------------------------------------------

main :: IO ()
main =
    run `catch` \(e :: SomeException) -> do
        hPutStrLn stderr ("deployment: FAILED: " <> displayException e)
        exitWith (ExitFailure 1)

run :: IO ()
run = do
    args <- getArgs
    case [a | a <- args, not ("-" `isPrefixOf` a)] of
        ("deploy" : _) -> doDeploy
        ("verify" : _) -> doVerify
        ("count" : _) -> doCount
        ("genesis-skey" : _) -> doGenesisSkey
        _ ->
            failWith
                "usage: deployment deploy --out MANIFEST [--release TAG] \
                \[--node-socket P --network-magic N --wallet-skey F]\n\
                \       deployment verify --deployment MANIFEST \
                \[--node-socket P --network-magic N --wallet-skey F]"

-- | One narration line: what was done and what was then observed.
emit :: String -> String -> IO ()
emit step detail = putStrLn ("deployment " <> step <> ": " <> detail)

failWith :: String -> IO a
failWith msg = ioError (userError msg)

flagValue :: String -> [String] -> Maybe String
flagValue name = go
  where
    go (a : rest)
        | a == name = case rest of
            (v : _) -> Just v
            [] -> Nothing
        | (name <> "=") `isPrefixOf` a = Just (drop (length name + 1) a)
        | otherwise = go rest
    go [] = Nothing

requireEnv :: String -> IO String
requireEnv name =
    lookupEnv name
        >>= maybe (failWith (name <> " is not set")) pure

-- ---------------------------------------------------------
-- The compiled halves a release ships
-- ---------------------------------------------------------

-- | Everything the two blueprints in this release contribute.
data Compiled = Compiled
    { cStateBytes :: SBS.ShortByteString
    , cRequestBytes :: SBS.ShortByteString
    , cConsumerBytes :: SBS.ShortByteString
    , cAppBytes :: SBS.ShortByteString
    , cRepAppliedBytes :: SBS.ShortByteString
    , cCustodyBytes :: SBS.ShortByteString
    , cStakingBytes :: SBS.ShortByteString
    }

loadCompiled :: IO Compiled
loadCompiled = do
    mpfsPath <- requireEnv "REGISTRY_BLUEPRINT"
    namingPath <- requireEnv "NAMING_BLUEPRINT"
    mbp <- either failWith pure =<< loadBlueprint mpfsPath
    nbp <- either failWith pure =<< loadBlueprint namingPath
    let need what bp title = case extractCompiledCode title bp of
            Just b -> pure b
            Nothing ->
                failWith
                    ( T.unpack title
                        <> " not found in the "
                        <> what
                        <> " blueprint"
                    )
    stateBytes <- need "registry" mbp "state.state"
    requestBytes <- need "registry" mbp "request.request"
    consumerBytes <- need "registry" mbp "consumer.consumer"
    appBytes <- need "naming" nbp "application.application"
    repBytes <- need "naming" nbp "representative.representative"
    custodyBytes <- need "naming" nbp "retirement_custody.retirement_custody"
    stakingBytes <- need "registry" mbp "staking.staking"
    let appHash = computeScriptHash appBytes
    pure
        Compiled
            { cStateBytes = stateBytes
            , cRequestBytes = requestBytes
            , cConsumerBytes = consumerBytes
            , cAppBytes = appBytes
            , cRepAppliedBytes =
                applyBytesParam (scriptHashBytes appHash) repBytes
            , cCustodyBytes = custodyBytes
            , cStakingBytes = stakingBytes
            }

-- | Bind the representative only after the registry seed is known.
bindSeed :: Compiled -> TxIn -> Compiled
bindSeed c seedIn =
    c
        { cRepAppliedBytes =
            applyBytesParam
                (scriptHashBytes (computeScriptHash (cStateBytes c)) <> deriveAssetName (txInToRef seedIn))
                (cRepAppliedBytes c)
        }

bindDeployment :: Compiled -> Deployment -> IO Compiled
bindDeployment c dep = bindSeed c <$> either failWith pure (parseOutRef (depSeedOutRef dep))

-- | The release's compiled halves, in the shape a manifest consumes.
partsOf :: Compiled -> CageParts
partsOf c =
    let ConsumerBinding{cbPin = pin, cbScriptBytes = scriptBytes} =
            deriveConsumerBinding (cConsumerBytes c)
     in CageParts
            { partsStateBytes = cStateBytes c
            , partsRequestBytes = cRequestBytes c
            , partsRepPolicy =
                SBS.toShort (scriptHashBytes (computeScriptHash (cRepAppliedBytes c)))
            , partsConsumerPin = pin
            , partsConsumerScript = scriptBytes
            }

-- ---------------------------------------------------------
-- verify
-- ---------------------------------------------------------

doVerify :: IO ()
doVerify = do
    args <- getArgs
    path <- case deploymentPathFromArgs args of
        Just p -> pure p
        Nothing -> failWith "verify needs --deployment MANIFEST"
    dep <- readDeployment path
    compiled <- loadCompiled >>= (`bindDeployment` dep)
    withNode $ \sess -> do
        claims <- verifyRegisteredDeployment sess dep compiled
        mapM_ (emit "verified") claims
        emit
            "complete"
            (show (length claims) <> " claim(s) hold against this node")

verifyRegisteredDeployment :: NodeSession -> Deployment -> Compiled -> IO [String]
verifyRegisteredDeployment sess dep compiled = do
    claims <- verifyDeployment (nsProvider sess) dep (partsOf compiled)
    credentials <-
        mapM
            check
            [ ("consumer", partsConsumerScript (partsOf compiled))
            , ("representative", cRepAppliedBytes compiled)
            , ("custody", cCustodyBytes compiled)
            , ("staking", cStakingBytes compiled)
            ]
    pure (claims <> credentials)
  where
    check (name, bytes) = do
        registered <- nsScriptRegistered sess (computeScriptHash bytes)
        unless registered $ failWith (name <> " stake credential is not registered on this node")
        pure (name <> " stake credential is registered on this node")

-- ---------------------------------------------------------
-- count
-- ---------------------------------------------------------

{- | Count what a deployment would otherwise create, so a check can say
whether a run created any.

@--what state@ counts outputs at the registry address carrying a token
of the recorded policy: one per registry ever booted under this state
validator. @--what reference@ counts outputs carrying a reference
script at the funding address and an optional additional publisher address
given as @--reference-address-bytes HEX@. A run that attached
leaves both unchanged; a run that booted and published moves both.
-}
doCount :: IO ()
doCount = do
    args <- getArgs
    path <- case deploymentPathFromArgs args of
        Just p -> pure p
        Nothing -> failWith "count needs --deployment MANIFEST"
    what <- case flagValue "--what" args of
        Just w -> pure w
        Nothing -> failWith "count needs --what state|reference"
    dep <- readDeployment path
    compiled <- loadCompiled >>= (`bindDeployment` dep)
    cfg <- either failWith pure (cageConfigFor dep (partsOf compiled))
    withNode $ \sess -> do
        let prov = nsProvider sess
        case what of
            "state" -> do
                utxos <- Cage.queryUTxOs prov (cageAddrFromCfg cfg Testnet)
                print (length [() | (_, o) <- utxos, carriesPolicy cfg o])
            "reference" -> do
                addresses <- case flagValue "--reference-address-bytes" args of
                    Nothing -> pure [funderAddr]
                    Just encoded -> do
                        raw <- either failWith pure (B16.decode (BC.pack encoded))
                        addr <- either (failWith . show) pure (decodeAddrEither raw)
                        pure (Set.toList (Set.fromList [funderAddr, addr]))
                utxos <- concat <$> mapM (Cage.queryUTxOs prov) addresses
                print (length [() | (_, o) <- utxos, hasReferenceScript o])
            _ -> failWith ("count: --what must be state or reference, not " <> what)
  where
    carriesPolicy cfg o =
        let MaryValue _ (MultiAsset m) = o ^. valueTxOutL
         in Map.member (cagePolicyIdFromCfg cfg) m
    hasReferenceScript o = case o ^. referenceScriptTxOutL of
        SJust _ -> True
        SNothing -> False

-- ---------------------------------------------------------
-- genesis-skey
-- ---------------------------------------------------------

{- | Write the factory devnet's genesis signing key in the file form a
joiner supplies, so the devnet attach check can reach its own devnet
through the external path rather than through the devnet path it is
meant to be testing an alternative to.

Devnet only. The key is a constant of the checked-in genesis, public by
construction, and worth nothing on any network anyone uses.
-}
doGenesisSkey :: IO ()
doGenesisSkey = do
    args <- getArgs
    out <- case flagValue "--out" args of
        Just p -> pure p
        Nothing -> failWith "genesis-skey needs --out FILE"
    writeFile
        out
        ( "{\"type\":\"PaymentSigningKeyShelley_ed25519\","
            <> "\"description\":\"Payment Signing Key\",\"cborHex\":\"5820"
            <> BC.unpack (B16.encode (rawSerialiseSignKeyDSIGN genesisSignKey))
            <> "\"}"
        )
    emit "genesis-skey" ("wrote the devnet genesis key to " <> out)

-- ---------------------------------------------------------
-- deploy
-- ---------------------------------------------------------

doDeploy :: IO ()
doDeploy = do
    args <- getArgs
    out <- case flagValue "--out" args of
        Just p -> pure p
        Nothing -> failWith "deploy needs --out MANIFEST"
    let release = maybe "unreleased" T.pack (flagValue "--release" args)
        leanRev = maybe "unrecorded" T.pack (flagValue "--lean-revision" args)
    processTime <- case flagValue "--process-time" args of
        Nothing -> pure 120_000
        Just ms -> case reads ms of
            [(n :: Integer, "")] | n > 0 -> pure n
            _ -> failWith "--process-time needs a positive number of milliseconds"
    retractTime <- case flagValue "--retract-time" args of
        Nothing -> pure 30_000
        Just ms -> case reads ms of
            [(n :: Integer, "")] | n > 0 -> pure n
            _ -> failWith "--retract-time needs a positive number of milliseconds"
    unbound <- loadCompiled
    withNode $ \sess -> do
        refuseIfAlreadyDeployed sess out unbound
        let prov = nsProvider sess
            submit = nsSubmitter sess
            pp = nsPParams sess
        txs <- newIORef []
        (cfg, tok, bootTx, seedIn, compiled) <- bootRegistry prov submit unbound txs processTime retractTime
        registerCredentials sess prov submit cfg compiled txs
        refs <- publishAll prov submit pp cfg tok compiled txs
        bootstrap <- reverse <$> readIORef txs
        let dep =
                Deployment
                    { depRelease = release
                    , depLeanRevision = leanRev
                    , depNetworkMagic = let NetworkMagic m = nsMagic sess in m
                    , depSeedOutRef = renderOutRef seedIn
                    , depCageToken = tokenText tok
                    , depStatePolicy =
                        hexT (scriptHashBytes (cfgScriptHash cfg))
                    , depRequestHash =
                        hexT (scriptHashBytes (hashScript (mkRequestScript cfg tok)))
                    , depApplicationHash =
                        hexT (scriptHashBytes (computeScriptHash (cAppBytes compiled)))
                    , depRepresentativePolicy =
                        hexT (scriptHashBytes (computeScriptHash (cRepAppliedBytes compiled)))
                    , depConsumerHash =
                        hexT (SBS.fromShort (cfgConsumerPin cfg))
                    , depProcessTime = defaultProcessTime cfg
                    , depRetractTime = defaultRetractTime cfg
                    , depTip = let Coin c = defaultTip cfg in c
                    , depReferenceScripts = refs
                    , depBootstrapTxs = bootstrap
                    }
        writeDeployment out dep
        emit "manifest" ("wrote " <> out)
        claims <- verifyRegisteredDeployment sess dep compiled
        mapM_ (emit "verified") claims
        emit
            "complete"
            ( "registry "
                <> T.unpack (tokenText tok)
                <> " booted in "
                <> T.unpack (txText bootTx)
                <> "; "
                <> show (length refs)
                <> " reference scripts published; funded by "
                <> bech32Address funderAddr
            )

{- | A deployment is made once. Given a manifest a node still agrees
with, say so and stop, rather than booting a second registry that
nothing recorded will ever point at.
-}
refuseIfAlreadyDeployed :: NodeSession -> FilePath -> Compiled -> IO ()
refuseIfAlreadyDeployed sess out unbound = do
    there <- doesFileExist out
    when there $ do
        dep <- readDeployment out
        compiled <- bindDeployment unbound dep
        live <-
            (True <$ verifyDeployment (nsProvider sess) dep (partsOf compiled))
                `catch` \(_ :: SomeException) -> pure False
        if live
            then
                failWith
                    ( out
                        <> " already records a deployment this node agrees with \
                           \(registry 0x"
                        <> T.unpack (depCageToken dep)
                        <> "). A deployment is made once; use \
                           \`deployment verify` to check it, or delete the \
                           \manifest to make a new one."
                    )
            else
                failWith
                    ( out
                        <> " already exists but this node does not agree with \
                           \it. Deploying would overwrite the record of a \
                           \deployment that may still be live elsewhere; move \
                           \the file aside deliberately."
                    )

-- | Boot one registry from the funding wallet's largest output.
bootRegistry ::
    Cage.Provider IO ->
    Submitter IO ->
    Compiled ->
    IORef [Text] ->
    Integer ->
    -- | Process window (ms), from @--process-time@.
    Integer ->
    -- | Retract window (ms), from @--retract-time@.
    IO (CageConfig, TokenId, ConwayTx, TxIn, Compiled)
bootRegistry prov submit unbound txs processTime retractTime = do
    utxos <- Cage.queryUTxOs prov funderAddr
    seedIn <- case sortOn (Down . (^. coinTxOutL) . snd) utxos of
        [] -> failWith "the funding wallet has no outputs to seed from"
        ((i, _) : _) -> pure i
    let compiled = bindSeed unbound seedIn
        ConsumerBinding{cbPin = pin, cbScriptBytes = consumerScript} =
            deriveConsumerBinding (cConsumerBytes compiled)
        cfg =
            CageConfig
                { cageScriptBytes = cStateBytes compiled
                , requestScriptBytes = cRequestBytes compiled
                , cfgScriptHash = computeScriptHash (cStateBytes compiled)
                , cageSeed = txInToRef seedIn
                , defaultProcessTime = processTime
                , defaultRetractTime = retractTime
                , defaultTip = Coin 1_000_000
                , cfgRepPolicy =
                    SBS.toShort
                        (scriptHashBytes (computeScriptHash (cRepAppliedBytes compiled)))
                , cfgConsumerPin = pin
                , cfgConsumerScript = consumerScript
                , network = Testnet
                }
    unsigned <- bootTokenImpl cfg prov funderAddr
    signed <- submitted submit txs "boot" unsigned
    let MultiAsset ma = signed ^. bodyTxL . mintTxBodyL
    tok <- case Map.toList (ma Map.! cagePolicyIdFromCfg cfg) of
        [(an, _)] -> pure (TokenId an)
        _ -> failWith "boot minted something other than one registry token"
    emit
        "boot"
        ( "registry 0x"
            <> T.unpack (tokenText tok)
            <> " from seed "
            <> T.unpack (renderOutRef seedIn)
        )
    pure (cfg, tok, signed, seedIn, compiled)

{- | Every stake credential a run withdraws from, registered once.

Four of them: the representative policy used to witness retirement, the pinned
consumer every @Modify@ withdraws, the completion-only custody script
the retirement rows use, and the always-true staking script that serves
the swapped-hook control — its withdraw arm always succeeds, so the
ledger passes it and only the cage's own exact-credential check can
refuse. A registry that attaches cannot register them itself (a second
registration is refused), so a deployment missing one turns that
runner's row into a refusal with no evidence behind it.
-}
registerCredentials ::
    NodeSession ->
    Cage.Provider IO ->
    Submitter IO ->
    CageConfig ->
    Compiled ->
    IORef [Text] ->
    IO ()
registerCredentials sess prov submit cfg compiled txs = do
    registered <- nsScriptRegistered sess (computeScriptHash (cfgConsumerScript cfg))
    if registered
        then emit "credential" "consumer stake credential already registered; reused"
        else do
            consumerTx <- registerConsumerImpl cfg prov funderAddr
            _ <- submitted submit txs "consumer-registration" consumerTx
            emit "credential" "consumer stake credential registered"
    let named name bytes = (name, scriptFromBytes name bytes)
    mapM_
        registerOne
        [ named "representative" (cRepAppliedBytes compiled)
        , named "naming-custody" (cCustodyBytes compiled)
        , named "staking" (cStakingBytes compiled)
        ]
  where
    registerOne (name, script) = do
        registered <- nsScriptRegistered sess (hashScript script)
        if registered
            then emit "credential" (name <> " stake credential already registered; reused")
            else do
                tx <- registerScriptImpl prov funderAddr (hashScript script)
                _ <- submitted submit txs (name <> "-registration") tx
                emit "credential" (name <> " stake credential registered")

{- | Publish the five reference scripts every runner reads: the
registry's state and request validators, the naming application, its
applied representative policy, and the completion-only custody script.

One script per transaction, each spending the change of the last. That
is slower than batching and it is the shape that works on a public
network without a funding pool: every step is confirmed before the next
one needs its output.
-}
publishAll ::
    Cage.Provider IO ->
    Submitter IO ->
    PParams ConwayEra ->
    CageConfig ->
    TokenId ->
    Compiled ->
    IORef [Text] ->
    IO [ReferenceScript]
publishAll prov submit pp cfg tok compiled txs =
    mapM
        one
        [ ("state", mkCageScript cfg)
        , ("request", mkRequestScript cfg tok)
        , ("application", scriptFromBytes "naming-application" (cAppBytes compiled))
        , ("representative", scriptFromBytes "representative" (cRepAppliedBytes compiled))
        , ("custody", scriptFromBytes "naming-custody" (cCustodyBytes compiled))
        ]
  where
    one (role, script) = do
        (txIn, _) <- publishOne prov submit pp txs script
        emit
            "published"
            ( T.unpack role
                <> " reference script at "
                <> T.unpack (renderOutRef txIn)
            )
        pure
            ReferenceScript
                { refRole = role
                , refHash = hexT (scriptHashBytes (hashScript script))
                , refOutRef = renderOutRef txIn
                , refAddress = T.pack (bech32Address funderAddr)
                , refAddressBytes = renderAddrBytes funderAddr
                }

publishOne ::
    Cage.Provider IO ->
    Submitter IO ->
    PParams ConwayEra ->
    IORef [Text] ->
    Script ConwayEra ->
    IO (TxIn, TxOut ConwayEra)
publishOne prov submit pp txs script = do
    utxos <- Cage.queryUTxOs prov funderAddr
    fund <- case sortOn (Down . (^. coinTxOutL) . snd) (adaOnly utxos) of
        [] -> failWith "publish: the funding wallet has no ada-only output"
        (u : _) -> pure u
    let probe =
            mkBasicTxOut funderAddr (MaryValue (Coin 0) mempty)
                & referenceScriptTxOutL .~ SJust script
        Coin minCoin = getMinCoinTxOut pp probe
        refOut =
            mkBasicTxOut funderAddr (MaryValue (Coin (minCoin + 1_000_000)) mempty)
                & referenceScriptTxOutL .~ SJust script
        Coin inCoin = snd fund ^. coinTxOutL
        changeCoin = inCoin - 1_000_000 - (minCoin + 1_000_000)
    unless (changeCoin > 1_000_000) $
        failWith
            ( "publish: the funding output holds "
                <> show inCoin
                <> " lovelace, which does not cover a reference output of "
                <> show (minCoin + 1_000_000)
                <> " plus fees and change"
            )
    let body =
            mkBasicTxBody
                & inputsTxBodyL .~ Set.singleton (fst fund)
                & outputsTxBodyL
                    .~ StrictSeq.fromList
                        [ refOut
                        , mkBasicTxOut funderAddr (MaryValue (Coin changeCoin) mempty)
                        ]
                & feeTxBodyL .~ Coin 1_000_000
    signed <- submitted submit txs "publish" (mkBasicTx body)
    let published = txIdTx signed
    after <- Cage.queryUTxOs prov funderAddr
    -- The output this transaction created, identified by the
    -- transaction rather than by the script: two publishes of the same
    -- script would otherwise be indistinguishable.
    case [u | u@(TxIn i _, o) <- after, i == published, hasScript o] of
        (u : _) -> pure u
        [] ->
            failWith
                "publish: the node accepted the transaction but no output \
                \of it carries the reference script"
  where
    adaOnly us =
        [ u
        | u@(_, o) <- us
        , let MaryValue _ (MultiAsset m) = o ^. valueTxOutL
        , Map.null m
        , o ^. referenceScriptTxOutL == SNothing
        ]
    hasScript o = case o ^. referenceScriptTxOutL of
        SJust s -> hashScript s == hashScript script
        SNothing -> False

-- | Sign with the funding wallet, submit, wait for the chain, record.
submitted :: Submitter IO -> IORef [Text] -> String -> ConwayTx -> IO ConwayTx
submitted submit txs label unsigned = do
    let signed = addKeyWitness funderSignKey unsigned
    result <- submitTx submit signed
    case result of
        Submitted _ -> pure ()
        Rejected reason -> failWith (label <> ": rejected: " <> show reason)
    awaitTx signed
    old <- readIORef txs
    writeIORef txs (txText signed : old)
    pure signed

-- ---------------------------------------------------------
-- Rendering
-- ---------------------------------------------------------

hexT :: BS.ByteString -> Text
hexT = T.pack . BC.unpack . B16.encode

tokenText :: TokenId -> Text
tokenText (TokenId (AssetName n)) = hexT (SBS.fromShort n)

txText :: ConwayTx -> Text
txText tx = let TxId h = txIdTx tx in hexT (hashToBytes (extractHash h))
