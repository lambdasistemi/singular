{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

{- |
Module      : Main
Description : #177 I177-COMMAND — `update-terminal` from the released archive
License     : Apache-2.0

The second packaged verb the release archive documents. A reviewer with
the extracted archive and no checkout runs it against a devnet and
watches a name end: the open registry boots, a key is booked ACTIVE at a
wallet, and that same key is then RETIRED — its witness burned out of the
wallet that held it, its leaf committed as `Terminal`.

> REGISTRY_BLUEPRINT=../onchain/plutus.json nix run .#update-terminal -- | The Unknown leg's own accepting control, booked and retired in the
-- second registry before the refusal it controls. The Absent leg has a
-- different control: the story's own retirement, in the first registry.
-- One control cannot serve both, because the two refusals cannot share
-- a registry.
controlKey :: ByteString--observed out.json

What it observes, in order:

1. the registry boots under the PARAMETERLESS open application and the
   three witness policies, all four pins from @REGISTRY_BLUEPRINT@
   alone — no naming blueprint anywhere;
2. one @insertActive@ folds and the wallet the request named holds
   exactly one @(activePolicy, key)@ token. This is the prerequisite,
   EXECUTED rather than fabricated: the token the retirement destroys is
   the token this fold created, and a fixture dropped into the final
   state would evidence nothing about the transition;
3. one @updateTerminal@ folds at the SAME key. The wallet's holding goes
   to zero, the transaction's mint under the active policy is exactly
   @(key, -1)@, the input that carried the witness is recorded by its
   outref, and the committed leaf reads @Terminal@;
4. @updateTerminal@ on a key the trie does not bind at all is REFUSED,
   and a key that IS active retires in the same run as its accepting
   control;
5. @updateTerminal@ on a key witnessed only ABSENT is REFUSED, with its
   own accepting control.

@--observed PATH@ writes the observation as JSON so a CI step asserts the
OBSERVATION rather than the exit code. Every value in it is read back
from the chain, the transaction, the committed trie or the blueprint;
nothing is a literal written here to make an assertion pass. Where the
cage's refusal trace cannot be recovered from the ledger's error text,
the field is @null@ rather than a guess — the NAMES are asserted at the
Aiken layer, against `state.terminalRefusal`, the construction site the
validator reads.

The whole journey is ONE node session. The prerequisite insert and the
retirement share a devnet because they share a registry; nothing here
asks two independently persistent processes to meet on an ephemeral
chain.

Issue #183 re-cuts the request wire for every edge. This verb ships on
the PRE-#183 bytes and is re-baselined there; no claim is made here
about the wire after it.
-}
module Main (main) where

import Control.Exception (SomeException, displayException, try)
import Data.Aeson (Value (..), object, (.=))
import Data.Aeson.Encode.Pretty (encodePretty)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as BL
import Data.ByteString.Short (fromShort)
import Data.List (isInfixOf)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import System.Environment (getArgs, lookupEnv)
import System.Exit (ExitCode (..), exitWith)
import System.IO (hPutStrLn, stderr)

import Cardano.Crypto.Hash.Class (hashToBytes)
import Cardano.Ledger.Address (serialiseAddr)
import Cardano.Ledger.Api.Tx (bodyTxL, txIdTx, witsTxL)
import Cardano.Ledger.Api.Tx.Body (mintTxBodyL, referenceInputsTxBodyL)
import Cardano.Ledger.Api.Tx.Out (TxOut, referenceScriptTxOutL)
import Cardano.Ledger.Api.Tx.Wits (scriptTxWitsL)
import Cardano.Ledger.BaseTypes (Network (Testnet), StrictMaybe (SNothing))
import Cardano.Ledger.Binary (serialize)
import Cardano.Ledger.Core (eraProtVerHigh, valueTxOutL)
import Cardano.Ledger.Hashes (extractHash)
import Cardano.Ledger.Mary.Value (MaryValue (..), MultiAsset (..))
import Cardano.Ledger.TxIn (TxId (..), TxIn, txInToText)
import Cardano.Node.Client.E2E.Setup (addKeyWitness, genesisAddr)
import Cardano.Node.Client.Submitter (SubmitResult (..), Submitter (..))
import Cardano.Tx.Ledger (ConwayTx)
import Data.ByteString.Base16 qualified as Base16
import Data.ByteString.Short qualified as SBS
import Data.Set qualified as Set
import Data.Text.Encoding qualified as TE
import Lens.Micro ((^.))

import Singular.Registry.AssetName (deriveAssetName)
import Singular.Registry.Blueprint (
    Blueprint (..),
    NamingCodes,
    Validator (..),
    extractCompiledCode,
    loadBlueprint,
    loadRegistryCodesFromEnv,
 )
import Singular.Registry.Config (CageConfig (..))
import Singular.Registry.Ledger (AssetName (..), Coin (..), ConwayEra, Root (..), TokenId (..))
import Singular.Registry.Node (NodeSession (..), awaitTx, funderSignKey, withNode)
import Singular.Registry.Provider qualified as Cage
import Singular.Registry.Trie (Trie (..), TrieManager (..))
import Singular.Registry.Trie.Pure ()
import Singular.Registry.Trie.PureManager (mkPureTrieManager)
import Singular.Registry.TxBuilder.Boot (bootTokenImpl)
import Singular.Registry.TxBuilder.Edges qualified as Edges
import Singular.Registry.TxBuilder.Internal (
    cageAddrFromCfg,
    cagePolicyIdFromCfg,
    computeScriptHash,
    extractCageDatum,
    findStateUtxo,
    policyIdFromPin,
    scriptFromBytes,
    scriptHashBytes,
    txInToRef,
    walkEdge,
 )
import Singular.Registry.TxBuilder.Update (
    RegistryContext (..),
    updateTokenWithDuties,
 )
import Singular.Registry.Types (
    CageDatum (..),
    Edge,
    OnChainRoot (..),
    OnChainTokenState (..),
    OnChainTxOutRef,
    edgeInsertAbsent,
    edgeInsertActive,
    edgeUpdateTerminal,
 )

-- ---------------------------------------------------------
-- The story's fixed inputs
-- ---------------------------------------------------------

{- | One booted registry: its config, its token, the reference outputs
its folds resolve through, and the boot transaction itself.

There is more than one per run because a refused fold never consumes the
request that caused it. That request stays pending, the next fold picks
it up, and the second refusal becomes evidence about the first. Each
refusal therefore gets a registry of its own.
-}
data Registry = Registry
    { regCfg :: CageConfig
    , regTid :: TokenId
    , regRefs :: [(TxIn, TxOut ConwayEra)]
    , regBootTx :: ConwayTx
    , regTidBytes :: ByteString
    }

-- | The key the documented run books and then retires.
storyKey :: ByteString
storyKey = "update-terminal-demo"

{- | The Unknown leg's own accepting control, booked and retired in the
second registry before the refusal it controls.

The Absent leg has a DIFFERENT control: the story's own retirement, in
the first registry. One control cannot serve both, because the two
refusals cannot share a registry — a refused fold never consumes its
request — and a control from the other registry would not be the same
builder against the same state.
-}
controlKey :: ByteString
controlKey = "update-terminal-demo-control"

-- | A key nothing ever inserted: the trie does not bind it at all.
unknownKey :: ByteString
unknownKey = "update-terminal-demo-unknown"

-- | A key witnessed ABSENT by a real fold, and never booked.
absentKey :: ByteString
absentKey = "update-terminal-demo-absent"

{- | The open story names a WALLET. 'Edges.edgeDestinationOf' would send
the active token to the APPLICATION's script address, which is right for
naming and wrong here: @open.ak@ is a minting policy with no spending
arm, so a token routed there is locked forever and could never be
retired.
-}
walletDestination :: (ByteString, ByteString)
walletDestination = (serialiseAddr genesisAddr, "")

hex :: ByteString -> T.Text
hex = TE.decodeUtf8 . Base16.encode

-- ---------------------------------------------------------
-- Entry point
-- ---------------------------------------------------------

main :: IO ()
main = do
    observedPath <- observedPathFrom <$> getArgs
    result <- try @SomeException (updateTerminal observedPath)
    case result of
        Right () -> pure ()
        Left e -> do
            hPutStrLn stderr ("update-terminal: FAILED: " <> displayException e)
            exitWith (ExitFailure 1)

observedPathFrom :: [String] -> Maybe FilePath
observedPathFrom = \case
    ("--observed" : p : _) -> Just p
    (_ : rest) -> observedPathFrom rest
    [] -> Nothing

die :: String -> IO a
die msg = do
    hPutStrLn stderr ("update-terminal: " <> msg)
    exitWith (ExitFailure 1)

say :: String -> IO ()
say = putStrLn . ("update-terminal: " <>)

updateTerminal :: Maybe FilePath -> IO ()
updateTerminal observedPath = do
    path <-
        lookupEnv "REGISTRY_BLUEPRINT" >>= \case
            Just p | not (null p) -> pure p
            _ ->
                die
                    "REGISTRY_BLUEPRINT is not set (point it at the \
                    \archive's onchain/plutus.json)"
    loaded <- loadBlueprint path
    bp <- case loaded of
        Left err -> die ("registry blueprint does not parse: " <> err)
        Right b -> pure b
    -- The parameter count is READ from the blueprint entry, never
    -- written down here: it is the fact that makes the open policy's
    -- compiled hash its policy id, so a blueprint that grew a parameter
    -- must change this observation rather than be contradicted by it.
    openParams <- case [v | v <- validators bp, vTitle v == "open.open.mint"] of
        (v : _) -> pure (vParameters v)
        [] -> die "open.open.mint not found in REGISTRY_BLUEPRINT"
    case ( extractCompiledCode "state.state" bp
         , extractCompiledCode "request.request" bp
         ) of
        (Just stateBytes, Just requestBytes) ->
            run observedPath stateBytes requestBytes openParams
        _ -> die "state.state or request.request not found in REGISTRY_BLUEPRINT"

run ::
    Maybe FilePath ->
    SBS.ShortByteString ->
    SBS.ShortByteString ->
    Int ->
    IO ()
run observedPath stateBytes requestBytes openParams = withNode $ \sess -> do
    let prov = nsProvider sess
        submit = nsSubmitter sess
    tm <- mkPureTrieManager
    _ <- Cage.queryProtocolParams prov
    -- #177 A-003: publish the state validator as a reference output
    -- BEFORE any seed is chosen. The publication spends the wallet's
    -- largest ada-only output, which a seed picked first could be, and
    -- boot would then look for a UTxO the publication had spent.
    _ <-
        Edges.publishRefScript
            prov
            (submitWithGenesis submit)
            genesisAddr
            (scriptFromBytes "state" stateBytes)
    codes <- loadRegistryCodesFromEnv

    {- One registry cannot carry two refusals.

    A refused fold never consumes the request that caused it, so that
    request stays pending and the NEXT fold picks it up — and refuses
    again, for the first request's reason rather than its own. The
    second refusal would then be evidence about the first.

    So each refusal gets a registry of its own, with its own accepting
    control folded in it before the bad one. Three boots, one node
    session, one wallet. -}
    let bootRegistry label = do
            utxos <- Cage.queryUTxOs prov genesisAddr
            -- Never seed from the reference publication: boot REFERENCES
            -- that output and may not also spend it.
            seedRef <- case filter (\(_, o) -> o ^. referenceScriptTxOutL == SNothing) utxos of
                [] -> die "the genesis wallet has no spendable UTxO to seed a registry with"
                ((txIn, _) : _) -> pure (txInToRef txIn)
            let cfg = cageCfg stateBytes requestBytes codes seedRef
            unsignedBoot <- bootTokenImpl cfg prov genesisAddr
            signedBoot <- submitWithGenesis submit unsignedBoot
            (tid, tidBytes) <- extractTokenId cfg signedBoot
            createTrie tm tid
            refs <-
                Edges.publishCageRefs
                    cfg
                    codes
                    prov
                    (submitWithGenesis submit)
                    genesisAddr
                    tid
            say (label <> ": booted registry token 0x" <> T.unpack (hex tidBytes))
            pure (Registry cfg tid refs signedBoot tidBytes)

        book reg key op =
            Edges.bookEdgeTo
                (regCfg reg)
                codes
                prov
                (submitWithGenesis submit)
                genesisAddr
                (regTid reg)
                key
                op
                walletDestination
        {- The mirroring below is not bookkeeping. The speculative
        session inside `updateTokenWithDuties` starts from the committed
        trie and is discarded, so a caller that does not commit each
        landed fold re-proves the next one against the BOOT state: the
        retirement would submit a proof for a root the chain left
        behind. -}
        foldOnce reg = foldWith reg False
        {- `inadmissible` is what lets a REFUSAL leg reach the chain. An
        honest builder refuses to construct a fold it can see the cage
        will reject, which is right for the story and wrong for a row
        whose whole point is the cage's own reason: without this the
        observation would record the BUILDER's message instead. -}
        foldWith reg inadmissible = do
            ctx0 <- Edges.registryContextFor (regCfg reg) codes prov (regRefs reg)
            let ctx = ctx0{rcAllowInadmissible = inadmissible}
            tx <-
                updateTokenWithDuties
                    (regCfg reg)
                    prov
                    tm
                    (regTid reg)
                    genesisAddr
                    ctx
            submitWithGenesis submit tx
        -- #183: the edge names the leaf bytes the local mirror must
        -- write, exactly as it names the ones the cage walks.
        mirror reg key edge = withTrie tm (regTid reg) $ \t ->
            () <$ walkEdge t key edge
        foldAndMirror reg key op = do
            tx <- foldOnce reg
            mirror reg key op
            pure tx
        rootNow reg = withTrie tm (regTid reg) getRoot

    -- ---------------------------------------------------------
    -- Registry one: the story, and the Absent refusal it controls
    -- ---------------------------------------------------------
    {- Both registries are booted HERE, before any fold. A fold returns
    its approval to this wallet, and a boot needs an ada-only output to
    fund and collateralise from; booting the second one after the story
    would find every remaining output carrying a token. -}
    story <- bootRegistry "story"
    unknownReg <- bootRegistry "unknown-leg"
    let cfg = regCfg story
        openPolicy = hex (SBS.fromShort (cfgApplicationPolicy cfg))
        activePolicy = hex (SBS.fromShort (cfgActivePolicy cfg))
    say
        ( "open application policy "
            <> T.unpack openPolicy
            <> " (parameters: "
            <> show openParams
            <> ")"
        )
    say ("active witness policy   " <> T.unpack activePolicy)
    stateUtxos <- Cage.queryUTxOs prov (cageAddrFromCfg cfg Testnet)
    bootState <- case findStateUtxo (cagePolicyIdFromCfg cfg) (regTid story) stateUtxos of
        Just (_, out) -> case extractCageDatum out of
            Just (StateDatum s) -> pure s
            _ -> die "boot: the state UTxO carries no eight-field state datum"
        Nothing -> die "boot: no state UTxO carrying the registry policy token"
    let bootObs = bootObservation cfg (regBootTx story)

    -- 1. the prerequisite, executed rather than fabricated.
    rootBeforeInsert <- rootNow story
    _ <- book story storyKey insertOp
    insertTx <- foldAndMirror story storyKey insertOp
    rootActive <- rootNow story
    heldBefore <- activeHeldAt prov cfg storyKey
    say ("active tokens at the named wallet after the insert: " <> show heldBefore)

    -- The exact input the burn will consume, recorded BEFORE it is
    -- spent: the wallet UTxO carrying this key's one active witness.
    source <- activeSourceOf prov cfg storyKey

    -- 2. the edge under test, at the same key, in the same session.
    --    This retirement is also the ACCEPTING CONTROL for the Absent
    --    refusal below: same registry, same builder, and the only thing
    --    that differs there is the leaf.
    _ <- book story storyKey retireOp
    retireTx <- foldAndMirror story storyKey retireOp
    rootTerminal <- rootNow story
    heldAfter <- activeHeldAt prov cfg storyKey
    chainRoot <- committedRoot prov cfg (regTid story)
    say ("active tokens at the named wallet after the retirement: " <> show heldAfter)

    -- 3. the Absent key: bound by a real insertAbsent fold, never
    --    booked. Its refusal poisons this registry, so nothing follows
    --    it here.
    _ <- book story absentKey absentOp
    _ <- foldAndMirror story absentKey absentOp
    _ <- book story absentKey retireOp
    absentOutcome <- try @SomeException (foldWith story True)
    absentDetail <- case absentOutcome of
        Right _ ->
            die
                "the fold ACCEPTED updateTerminal on a key witnessed Absent — \
                \reported, not relabelled"
        Left e -> pure (displayException e)
    say "a key witnessed Absent: REFUSED"

    -- ---------------------------------------------------------
    -- Registry two: the Unknown refusal, with its own control
    -- ---------------------------------------------------------
    _ <- book unknownReg controlKey insertOp
    _ <- foldAndMirror unknownReg controlKey insertOp
    _ <- book unknownReg controlKey retireOp
    controlOutcome <- try @SomeException (foldAndMirror unknownReg controlKey retireOp)
    controlTxid <- case controlOutcome of
        Right tx -> pure (hex (txIdOf tx))
        Left e ->
            die
                ( "control: a key that IS active was refused retirement, so \
                  \the refusal below would prove nothing about the leaf: "
                    <> displayException e
                )
    _ <- book unknownReg unknownKey retireOp
    unknownOutcome <- try @SomeException (foldWith unknownReg True)
    unknownDetail <- case unknownOutcome of
        Right _ ->
            die
                "the fold ACCEPTED updateTerminal on a key the trie does not \
                \bind — reported, not relabelled"
        Left e -> pure (displayException e)
    say "a key the trie does not bind: REFUSED"

    let tidBytes = regTidBytes story
        absentControlTxid = hex (txIdOf retireTx)
    let traceOf name detail
            | name `isInfixOf` detail = String (T.pack name)
            | otherwise = Null
        observation =
            object
                [ "edge" .= ("updateTerminal" :: T.Text)
                , "open"
                    .= object
                        [ "policy" .= openPolicy
                        , "parameters" .= openParams
                        ]
                , "registry"
                    .= object
                        [ "token" .= hex tidBytes
                        , "maxFee" .= stateMaxFee bootState
                        ]
                , "boot" .= bootObs
                , "requested" .= object ["address" .= hex (fst walletDestination)]
                , "retirement"
                    .= object
                        [ "activePolicy" .= activePolicy
                        , "key" .= hex storyKey
                        , "insertTxid" .= hex (txIdOf insertTx)
                        , "retireTxid" .= hex (txIdOf retireTx)
                        , "roots"
                            .= object
                                [ "beforeInsert" .= hex (unRoot rootBeforeInsert)
                                , "active" .= hex (unRoot rootActive)
                                , "terminal" .= hex (unRoot rootTerminal)
                                ]
                        , "quantities"
                            .= object
                                [ "before" .= heldBefore
                                , "after" .= heldAfter
                                ]
                        , -- What the RETIREMENT transaction actually
                          -- moved under the active policy, read off its
                          -- own mint field.
                          "mint" .= mintedActive retireTx cfg
                        , -- The input the burn consumed, read off the
                          -- chain before it was spent. A mint of -1
                          -- with no such input is the shape the cage
                          -- refuses `token-missing`.
                          "source" .= source
                        , -- The LEAF, observed where a leaf can be
                          -- observed: `Trie.lookup` answers with the
                          -- key's hash rather than its value, while a
                          -- trie with a different leaf at this key has a
                          -- different root. The chain reached this root
                          -- through the validator's own `mpf.update`
                          -- and the mirror through an independent local
                          -- trie.
                          "leaf"
                            .= if chainRoot == unRoot rootTerminal
                                then String "Terminal"
                                else Null
                        , "unknown"
                            .= object
                                [ "outcome" .= ("refused" :: T.Text)
                                , -- The ledger's EvalFailure carries an
                                  -- EMPTY Plutus log list, so the cage's
                                  -- trace is usually not recoverable.
                                  -- `null` rather than a guess; the NAME
                                  -- is asserted at the Aiken layer.
                                  "trace" .= traceOf "key-unknown" unknownDetail
                                , "detail" .= T.pack (take 2000 unknownDetail)
                                , "controlTxid" .= controlTxid
                                , "distinguisher"
                                    .= ( "the control retired a key that IS \
                                         \Active in this same registry; this \
                                         \one was never inserted at all" ::
                                            T.Text
                                       )
                                ]
                        , "absent"
                            .= object
                                [ "outcome" .= ("refused" :: T.Text)
                                , "trace" .= traceOf "not-booked" absentDetail
                                , "detail" .= T.pack (take 2000 absentDetail)
                                , "controlTxid" .= absentControlTxid
                                , "distinguisher"
                                    .= ( "the control retired a key that IS \
                                         \Active in this same registry; this \
                                         \one was witnessed Absent" ::
                                            T.Text
                                       )
                                ]
                        ]
                ]
    case observedPath of
        Nothing -> pure ()
        Just p -> do
            BL.writeFile p (encodePretty observation)
            say ("observation written to " <> p)

    -- The exit code repeats what the observation already says, so a
    -- caller that does not read the JSON still fails on a broken run.
    if heldBefore == 1 && heldAfter == 0 && chainRoot == unRoot rootTerminal
        then say "OK — the witness was burned from its holder and the leaf is Terminal"
        else
            die
                ( "the retirement did not complete: held "
                    <> show heldBefore
                    <> " -> "
                    <> show heldAfter
                    <> ", chain root "
                    <> T.unpack (hex chainRoot)
                    <> " against the mirror's "
                    <> T.unpack (hex (unRoot rootTerminal))
                )

-- | The three C2 rows this story walks (#183).
insertOp, absentOp, retireOp :: Edge
insertOp = edgeInsertActive
absentOp = edgeInsertAbsent
retireOp = edgeUpdateTerminal

-- | Exactly the quantity held under the ACTIVE policy at this key.
activeHeldAt :: Cage.Provider IO -> CageConfig -> ByteString -> IO Integer
activeHeldAt prov cfg key = do
    walletUtxos <- Cage.queryUTxOs prov genesisAddr
    let policy = policyIdFromPin (cfgActivePolicy cfg)
    pure $
        sum
            [ q
            | (_, out) <- walletUtxos
            , let MaryValue _ (MultiAsset ma) = out ^. valueTxOutL
            , (p, names) <- Map.toList ma
            , p == policy
            , (AssetName n, q) <- Map.toList names
            , SBS.fromShort n == key
            ]

{- | The wallet UTxO carrying this key's active witness, by outref and
quantity, read off the chain before the retirement spends it.
-}
activeSourceOf :: Cage.Provider IO -> CageConfig -> ByteString -> IO Value
activeSourceOf prov cfg key = do
    walletUtxos <- Cage.queryUTxOs prov genesisAddr
    let policy = policyIdFromPin (cfgActivePolicy cfg)
        carriers =
            [ (txIn, q)
            | (txIn, out) <- walletUtxos
            , let MaryValue _ (MultiAsset ma) = out ^. valueTxOutL
            , (p, names) <- Map.toList ma
            , p == policy
            , (AssetName n, q) <- Map.toList names
            , SBS.fromShort n == key
            ]
    case carriers of
        [(txIn, q)] ->
            pure $
                object
                    [ "outref" .= txInToText txIn
                    , "policy" .= hex (SBS.fromShort (cfgActivePolicy cfg))
                    , "name" .= hex key
                    , "quantity" .= q
                    ]
        _ ->
            die
                ( "the wallet does not hold exactly one carrier of this key's \
                  \active witness: "
                    <> show (length carriers)
                )

{- | Everything the transaction moves under the ACTIVE policy, by key.
The policy comes from the booted config, so a burn under another policy
is absent here rather than silently counted.
-}
mintedActive :: ConwayTx -> CageConfig -> [Value]
mintedActive tx cfg =
    let MultiAsset ma = tx ^. bodyTxL . mintTxBodyL
        policy = policyIdFromPin (cfgActivePolicy cfg)
     in [ object
            [ "policy" .= hex (SBS.fromShort (cfgActivePolicy cfg))
            , "name" .= hex (SBS.fromShort n)
            , "quantity" .= q
            ]
        | (p, names) <- Map.toList ma
        , p == policy
        , (AssetName n, q) <- Map.toList names
        ]

-- | Sign with the devnet genesis key, submit, wait.
submitWithGenesis :: Submitter IO -> ConwayTx -> IO ConwayTx
submitWithGenesis submit unsigned = do
    let signed = addKeyWitness funderSignKey unsigned
    result <- submitTx submit signed
    case result of
        Submitted _ -> pure ()
        Rejected reason -> die ("tx rejected: " <> show reason)
    awaitTx signed
    pure signed

{- | The registry token this boot minted, and its raw name bytes for
narration.
-}
extractTokenId :: CageConfig -> ConwayTx -> IO (TokenId, ByteString)
extractTokenId cfg tx =
    let MultiAsset ma = tx ^. bodyTxL . mintTxBodyL
        assets = Map.toList (ma Map.! cagePolicyIdFromCfg cfg)
     in case assets of
            [(AssetName an, _)] -> pure (TokenId (AssetName an), fromShort an)
            _ -> die ("boot: unexpected mint assets: " <> show (length assets))

-- | A transaction's own id, as the observation records it.
txIdOf :: ConwayTx -> ByteString
txIdOf tx =
    let TxId h = txIdTx tx
     in hashToBytes (extractHash h)

cageCfg ::
    SBS.ShortByteString ->
    SBS.ShortByteString ->
    NamingCodes ->
    OnChainTxOutRef ->
    CageConfig
cageCfg stateBytes requestBytes codes seed =
    let stateHash = computeScriptHash stateBytes
        registryId = scriptHashBytes stateHash <> deriveAssetName seed
        (appPin, absentPin, activePin, terminalPin) =
            Edges.namingPins codes registryId
     in CageConfig
            { cageScriptBytes = stateBytes
            , requestScriptBytes = requestBytes
            , cfgScriptHash = stateHash
            , cageSeed = seed
            , defaultProcessTime = 30_000
            , defaultRetractTime = 30_000
            , defaultTip = Coin 1_000_000
            , cfgApplicationPolicy = appPin
            , cfgActivePolicy = activePin
            , cfgAbsentPolicy = absentPin
            , cfgTerminalPolicy = terminalPin
            , cfgConsumerScript = SBS.empty
            , network = Testnet
            }

{- | The registry's own committed root, read off the state UTxO on
chain. This is how a LEAF is observed: `Trie.lookup` answers with the
key's hash rather than its value and cannot see one, while a trie with a
different leaf at a key has a different root.
-}
committedRoot :: Cage.Provider IO -> CageConfig -> TokenId -> IO ByteString
committedRoot prov cfg tid = do
    utxos <- Cage.queryUTxOs prov (cageAddrFromCfg cfg Testnet)
    case findStateUtxo (cagePolicyIdFromCfg cfg) tid utxos of
        Just (_, out) -> case extractCageDatum out of
            Just (StateDatum s) -> pure (unOnChainRoot (stateRoot s))
            _ -> die "the state UTxO carries no state datum"
        Nothing -> die "no state UTxO carrying the registry policy token"

{- | What the BOOT transaction carries (#177 A-003).

The retirement guard grew the state validator past what a boot
transaction carrying it inline can hold. The repair was to reference the
published script instead, and this is the observation that says so: the
transaction's own serialized size, how many scripts ride in its witness
set, and how many reference inputs it resolves through.

`stateScriptInline` is the fact under test. It is computed from the
transaction, not asserted about it: the state script's hash is looked
for among the witnesses actually attached.
-}
bootObservation :: CageConfig -> ConwayTx -> Value
bootObservation cfg tx =
    object
        [ "bytes" .= (fromIntegral (BL.length (serialize (eraProtVerHigh @ConwayEra) tx)) :: Integer)
        , "inlineScripts" .= (fromIntegral (Map.size (tx ^. witsTxL . scriptTxWitsL)) :: Integer)
        , "referenceInputs" .= (fromIntegral (Set.size (tx ^. bodyTxL . referenceInputsTxBodyL)) :: Integer)
        , "stateScriptInline"
            .= Map.member (cfgScriptHash cfg) (tx ^. witsTxL . scriptTxWitsL)
        ]
