{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

{- |
Module      : Main
Description : #173 A173-COMMAND — `insert-active` from the released archive
License     : Apache-2.0

The packaged verb the release archive documents. A reviewer with the
extracted archive and no checkout runs it against a devnet and watches
the open registry boot, fold one certified `insertActive`, and hand the
active token to the wallet the request named.

> REGISTRY_BLUEPRINT=../onchain/plutus.json nix run .#insert-active -- --observed out.json

What it observes, in order:

1. the registry boots under the PARAMETERLESS open application and the
   three witness policies, all four pins from @REGISTRY_BLUEPRINT@
   alone — no naming blueprint anywhere;
2. one @insertActive@ folds and exactly one @(activePolicy, key)@ token
   lands in the output at the wallet the request named;
3. a FRESH key through the same builder also folds — the accepting
   control, taken BEFORE the duplicate because a refused request is
   never consumed and would otherwise poison the fold that follows it;
4. a SECOND @insertActive@ at the same key is REFUSED.

@--observed PATH@ writes the observation as JSON so a CI step asserts
the OBSERVATION rather than the exit code. Every value in it is read
back from the chain or from the blueprint; nothing is a literal written
here to make an assertion pass. Where the cage's refusal trace cannot
be recovered from the ledger's error text, the field is @null@ rather
than a guess.

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
import Cardano.Ledger.Api.Tx (bodyTxL, txIdTx)
import Cardano.Ledger.Api.Tx.Body (mintTxBodyL)
import Cardano.Ledger.Api.Tx.Out (referenceScriptTxOutL)
import Cardano.Ledger.BaseTypes (Network (Testnet), StrictMaybe (SNothing))
import Cardano.Ledger.Core (valueTxOutL)
import Cardano.Ledger.Hashes (extractHash)
import Cardano.Ledger.Mary.Value (MaryValue (..), MultiAsset (..))
import Cardano.Ledger.TxIn (TxId (..))
import Cardano.Node.Client.E2E.Setup (addKeyWitness, genesisAddr)
import Cardano.Node.Client.Submitter (SubmitResult (..), Submitter (..))
import Cardano.Tx.Ledger (ConwayTx)
import Data.ByteString.Base16 qualified as Base16
import Data.ByteString.Short qualified as SBS
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
import Singular.Registry.Ledger (AssetName (..), Coin (..), TokenId (..))
import Singular.Registry.Node (NodeSession (..), awaitTx, funderSignKey, withNode)
import Singular.Registry.Provider qualified as Cage
import Singular.Registry.Trie (Trie (..), TrieManager (..))
import Singular.Registry.Trie.PureManager (mkPureTrieManager)
import Singular.Registry.TxBuilder.Boot (bootTokenImpl)
import Singular.Registry.TxBuilder.Edges qualified as Edges
import Singular.Registry.TxBuilder.Internal (
    cageAddrFromCfg,
    cagePolicyIdFromCfg,
    computeScriptHash,
    extractCageDatum,
    findStateUtxo,
    leafActive,
    policyIdFromPin,
    scriptFromBytes,
    scriptHashBytes,
    txInToRef,
 )
import Singular.Registry.TxBuilder.Update (updateTokenWithDuties)
import Singular.Registry.Types (
    CageDatum (..),
    OnChainTokenState (..),
    OnChainTxOutRef,
    edgeInsertActive,
 )

-- ---------------------------------------------------------
-- The story's fixed inputs
-- ---------------------------------------------------------

-- | The key the documented run books.
storyKey :: ByteString
storyKey = "insert-active-demo"

-- | A second, never-booked key: the accepting control.
controlKey :: ByteString
controlKey = "insert-active-demo-control"

{- | The open story names a WALLET. 'Edges.edgeDestinationOf' would send
an @insertActive@ to the APPLICATION's script address, which is right
for naming and wrong here: @open.ak@ is a minting policy with no
spending arm, so a token routed there is locked forever.
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
    result <- try @SomeException (insertActive observedPath)
    case result of
        Right () -> pure ()
        Left e -> do
            hPutStrLn stderr ("insert-active: FAILED: " <> displayException e)
            exitWith (ExitFailure 1)

observedPathFrom :: [String] -> Maybe FilePath
observedPathFrom = \case
    ("--observed" : p : _) -> Just p
    (_ : rest) -> observedPathFrom rest
    [] -> Nothing

die :: String -> IO a
die msg = do
    hPutStrLn stderr ("insert-active: " <> msg)
    exitWith (ExitFailure 1)

say :: String -> IO ()
say = putStrLn . ("insert-active: " <>)

insertActive :: Maybe FilePath -> IO ()
insertActive observedPath = do
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
    -- BEFORE the seed is chosen. The publication spends the wallet's
    -- largest ada-only output, which a seed picked first could be, and
    -- boot would then look for a UTxO the publication had spent.
    _ <-
        Edges.publishRefScript
            prov
            (submitWithGenesis submit)
            genesisAddr
            (scriptFromBytes "state" stateBytes)
    utxos <- Cage.queryUTxOs prov genesisAddr
    -- #177 A-003: never seed from the reference publication. Boot
    -- REFERENCES that output, and a transaction may not both spend and
    -- reference the same one.
    seedRef <- case filter (\(_, o) -> o ^. referenceScriptTxOutL == SNothing) utxos of
        [] -> die "the genesis wallet has no spendable UTxO to seed the registry with"
        ((txIn, _) : _) -> pure (txInToRef txIn)

    codes <- loadRegistryCodesFromEnv
    let cfg = cageCfg stateBytes requestBytes codes seedRef
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

    unsignedBoot <- bootTokenImpl cfg prov genesisAddr
    signedBoot <- submitWithGenesis submit unsignedBoot
    (tid, tidBytes) <- extractTokenId cfg signedBoot
    createTrie tm tid
    stateUtxos <- Cage.queryUTxOs prov (cageAddrFromCfg cfg Testnet)
    bootState <- case findStateUtxo (cagePolicyIdFromCfg cfg) tid stateUtxos of
        Just (_, out) -> case extractCageDatum out of
            Just (StateDatum s) -> pure s
            _ -> die "boot: the state UTxO carries no eight-field state datum"
        Nothing -> die "boot: no state UTxO carrying the registry policy token"
    say ("booted registry token 0x" <> T.unpack (hex tidBytes))

    refs <-
        Edges.publishCageRefs
            cfg
            codes
            prov
            (submitWithGenesis submit)
            genesisAddr
            tid

    let book key =
            Edges.bookEdgeTo
                cfg
                codes
                prov
                (submitWithGenesis submit)
                genesisAddr
                tid
                key
                edgeInsertActive
                walletDestination
        {- The mirroring below is not bookkeeping. The speculative
        session inside `updateTokenWithDuties` starts from the
        committed trie and is discarded, so a caller that does not
        commit each landed fold re-proves the next one against the BOOT
        state: fold 2 submits an empty proof and fails. -}
        foldOnce key = do
            ctx <- Edges.registryContextFor cfg codes prov refs
            tx <- updateTokenWithDuties cfg prov tm tid genesisAddr ctx
            signed <- submitWithGenesis submit tx
            withTrie tm tid $ \t -> do
                _ <- insert t key leafActive
                pure ()
            pure signed

    _ <- book storyKey
    foldTx <- foldOnce storyKey
    let foldTxid = hex (txIdOf foldTx)
    say ("folded insertActive tx=" <> T.unpack foldTxid)

    held <- activeHeldAt prov cfg storyKey
    say ("active tokens at the named wallet: " <> show held)

    _ <- book controlKey
    controlOutcome <- try @SomeException (foldOnce controlKey)
    controlTxid <- case controlOutcome of
        Right tx -> pure (hex (txIdOf tx))
        Left e ->
            die
                ( "control: a FRESH key was refused, so the duplicate \
                  \refusal below would prove nothing about occupancy: "
                    <> displayException e
                )

    _ <- book storyKey
    duplicate <- try @SomeException (foldOnce storyKey)
    dupRefusal <- case duplicate of
        Right _ ->
            die
                "the fold ACCEPTED a second insertActive on a key the trie \
                \already binds — reported, not relabelled"
        Left e -> pure (displayException e)
    say "the same key again: REFUSED"

    let traceSeen
            | "key-exists" `isInfixOf` dupRefusal = String "key-exists"
            | otherwise = Null
        observation =
            object
                [ "edge" .= ("insertActive" :: T.Text)
                , "key" .= hex storyKey
                , "open"
                    .= object
                        [ "policy" .= openPolicy
                        , "parameters" .= openParams
                        ]
                , "active" .= object ["policy" .= activePolicy]
                , "registry"
                    .= object
                        [ "token" .= hex tidBytes
                        , "maxFee" .= stateMaxFee bootState
                        ]
                , "requested"
                    .= object ["address" .= hex (fst walletDestination)]
                , "fold" .= object ["txid" .= foldTxid]
                , "wallet"
                    .= object
                        [ "address" .= hex (fst walletDestination)
                        , "assets"
                            .= [ object
                                    [ "policy" .= activePolicy
                                    , "name" .= hex storyKey
                                    , "quantity" .= held
                                    ]
                               ]
                        ]
                , "key-exists"
                    .= object
                        [ "outcome" .= ("refused" :: T.Text)
                        , -- The ledger's EvalFailure carries an EMPTY Plutus
                          -- log list, so the cage's trace is usually not
                          -- recoverable. `null` rather than a guess; the
                          -- NAME is asserted at the Aiken layer.
                          "trace" .= traceSeen
                        , "detail" .= T.pack (take 2000 dupRefusal)
                        , -- The control belongs to the refusal it controls:
                          -- a FRESH key through the SAME builder, folded in
                          -- the same run. Without it, "refused" is
                          -- consistent with "this command cannot fold at
                          -- all".
                          "control"
                            .= object
                                [ "key" .= hex controlKey
                                , "outcome" .= ("accepted" :: T.Text)
                                , "txid" .= controlTxid
                                ]
                        ]
                ]
    case observedPath of
        Nothing -> pure ()
        Just p -> do
            BL.writeFile p (encodePretty observation)
            say ("observation written to " <> p)
    if held == 1
        then say "OK — one active token at the named wallet, duplicate refused"
        else
            die
                ( "the named wallet holds "
                    <> show held
                    <> " active tokens for this key, not exactly one"
                )

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
