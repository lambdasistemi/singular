{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NumericUnderscores #-}

{- | Execute the ordinary CLI's refusal controls against a node.

Every action leaves one receipt and never stops the story: a step that
cannot be taken records why, and the verdicts computed later from the
receipts say which clauses that leaves uncovered or unmet.

* A command is the @singular@ executable, run as a person runs it; its
  receipt is the command's own printed receipt, kept beside ours.
* A booking is the library call @insert@ makes, 'bookEdgeWith' with the
  application's insertion approval, and nothing after it.
* An unevaluated fold is the registry's own duties for that one request
  ('registryDuties', with the application's context) built by
  'connectedFoldTx' with local evaluation skipped, so the node judges it.
  Its proofs come from a copy of the registry's saved mirror, checked
  against the root the chain holds before anything is built.
* A readback is the registry's state root, the key's holding at the
  application, the pending requests and the wallet, read from the node.

A registry's configuration is derived here again from the release and the
saved deployment record, and its pins compared with the ones the command
saved, so a disagreement between this reader and the command is a
refusal rather than a silent choice.
-}
module Conformance.Cli.Backend (runControls) where

import Control.Applicative ((<|>))
import Control.Concurrent.Async (async, cancel, waitCatch)
import Control.Exception
    ( SomeAsyncException
    , SomeException
    , evaluate
    , fromException
    , throwIO
    , try
    )
import Control.Monad (forM_, unless, void, when)
import Control.Monad.Operational
    ( Program
    , ProgramViewT (Return, (:>>=))
    , view
    )
import Data.Aeson (Value (..))
import Data.Aeson qualified as Aeson
import Data.Aeson.Encode.Pretty (encodePretty)
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Bits (xor)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as BL
import Data.ByteString.Short qualified as SBS
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.List (sortOn)
import Data.Map.Strict qualified as Map
import Data.Ord (Down (..))
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Lens.Micro ((&), (.~), (^.))
import PlutusCore.Data qualified as PLC
import System.Directory (createDirectoryIfMissing)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO (hPutStrLn, stderr)
import System.Process (readProcessWithExitCode)
import System.Timeout (timeout)
import Text.Printf (printf)

import Cardano.Crypto.Hash.Class (hashToBytes, hashWith)
import Cardano.Crypto.Hash.SHA256 (SHA256)
import Cardano.Ledger.Address (Addr (..))
import Cardano.Ledger.Api.Scripts.Data (Datum (..))
import Cardano.Ledger.Api.Tx (txIdTx, witsTxL)
import Cardano.Ledger.Api.Tx.Out
    ( TxOut
    , addrTxOutL
    , coinTxOutL
    , datumTxOutL
    , getMinCoinTxOut
    , mkBasicTxOut
    , referenceScriptTxOutL
    , valueTxOutL
    )
import Cardano.Ledger.Api.Tx.Wits (Redeemers (..), rdmrsTxWitsL)
import Cardano.Ledger.BaseTypes (Network (Testnet), StrictMaybe (..))
import Cardano.Ledger.Binary (serialize')
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Core (Script, eraProtVerHigh, hashScript)
import Cardano.Ledger.Credential
    ( Credential (..)
    , StakeReference (..)
    )
import Cardano.Ledger.Hashes (extractHash)
import Cardano.Ledger.Mary.Value (MaryValue (..))
import Cardano.Ledger.TxIn (TxId (..), TxIn (..))
import Cardano.Node.Client.E2E.Setup (addKeyWitness)
import Cardano.Node.Client.Submitter
    ( SubmitResult (..)
    , Submitter (..)
    )
import Cardano.Tx.Build qualified as Tx
import Cardano.Tx.Ledger (ConwayTx)
import Data.Void (Void)

import Singular.Application.OpenDatum.Book
    ( insertApproval
    , insertDestination
    , terminateApproval
    , terminateDestination
    )
import Singular.Application.OpenDatum.Envelope
    ( Control (..)
    , Envelope (..)
    , StateAsset (..)
    , envelopeToJson
    , envelopeVersion
    , registryBytes
    )
import Singular.Application.OpenDatum.Release
    ( heldOf
    , liveEnvelope
    , withApplication
    )
import Singular.Application.OpenDatum.Script
    ( Application (..)
    , loadApplicationCodes
    )
import Singular.Application.OpenDatum.Update
    ( continuationOf
    , releaseRedeemer
    , updateRedeemer
    )
import Singular.Registry.AssetName (deriveAssetName)
import Singular.Registry.Blueprint
    ( NamingCodes (..)
    , extractCompiledCode
    , loadBlueprint
    )
import Singular.Registry.Config (CageConfig (..))
import Singular.Registry.Config.Application (cageConfigForApplication)
import Singular.Registry.Deployment
    ( Attached (..)
    , CageParts (..)
    , Deployment (..)
    , attach
    , loadMirror
    , parseOutRef
    , renderOutRef
    , saveMirror
    )
import Singular.Registry.Ledger
    ( AssetName (..)
    , ConwayEra
    , Root (..)
    , TokenId (..)
    )
import Singular.Registry.Node
    ( ExternalNode (..)
    , NodeMode (..)
    , NodeSession (..)
    , Wallet (..)
    , awaitTxWindow
    , loadWallet
    , withNodeMode
    )
import Singular.Registry.Provider qualified as Cage
import Singular.Registry.Trie (Trie (..), TrieManager (..))
import Singular.Registry.Trie.PureManager (mkPureTrieManagerFrom)
import Singular.Registry.TxBuilder.ConnectedFold
    ( ConnectedFoldArgs (..)
    , ConnectedMint (..)
    , ConnectedSpend (..)
    , connectedFoldTx
    , generousUnits
    )
import Singular.Registry.TxBuilder.Edges
    ( BookingApproval (..)
    , adaOnlyOut
    , bookEdgeWith
    , edgeDeposit
    , registryContextFor
    )
import Singular.Registry.TxBuilder.Internal
    ( addrKeyHashBytes
    , addrWitnessKeyHash
    , computeScriptHash
    , extractCageDatum
    , requestAddrFromCfg
    , scriptFromBytes
    , scriptHashBytes
    , txInToRef
    , walkEdge
    )
import Singular.Registry.TxBuilder.Update
    ( RegistryContext (..)
    , RegistryDuties (..)
    , registryDuties
    )
import Singular.Registry.Types
    ( CageDatum (..)
    , OnChainRequest (..)
    , OnChainRoot (..)
    , OnChainTokenState (..)
    , edgeInsertActive
    , edgeUpdateTerminal
    )

import Conformance.Cli.Controls
    ( CliI (..)
    , Command (..)
    , Crafted (..)
    , Observation (..)
    , Receipt (..)
    , Story
    , Target (..)
    , commandName
    , controlsStory
    , craftedName
    , emptyReceipt
    , rejectionEvidence
    , resolveStatement
    , statementBindings
    , validateControls
    )
import Conformance.Cli.Proof (leafText, provenLeaf)
import Conformance.NodeRejection (boundedNodeReason)
import Conformance.Story.Specification
    ( Clause (..)
    , Step (..)
    , checkAction
    , clauses
    )

-- ---------------------------------------------------------
-- Options
-- ---------------------------------------------------------

data Options = Options
    { optSingular :: FilePath
    , optBlueprint :: FilePath
    , optLedger :: FilePath
    , optSocket :: FilePath
    , optMagic :: Int
    , optWalletKey :: FilePath
    , optWork :: FilePath
    , optStranger :: FilePath
    -- ^ A second funded wallet, never a controller in the story
    }

parseOptions :: [String] -> Either String Options
parseOptions = go (Options "" "" "" "" 0 "" "" "")
  where
    go o [] = do
        forM_
            [ ("--singular", optSingular o)
            , ("--blueprint", optBlueprint o)
            , ("--ledger", optLedger o)
            , ("--node-socket", optSocket o)
            , ("--wallet-skey", optWalletKey o)
            , ("--work", optWork o)
            , ("--stranger-skey", optStranger o)
            ]
            $ \(name, v) -> when (null v) (Left (name <> " is required"))
        when (optMagic o <= 0) (Left "--network-magic is required")
        Right o
    go o (flag : v : rest) = case flag of
        "--singular" -> go o{optSingular = v} rest
        "--blueprint" -> go o{optBlueprint = v} rest
        "--ledger" -> go o{optLedger = v} rest
        "--node-socket" -> go o{optSocket = v} rest
        "--network-magic" -> case reads v of
            [(n, "")] -> go o{optMagic = n} rest
            _ -> Left ("--network-magic is not a number: " <> v)
        "--wallet-skey" -> go o{optWalletKey = v} rest
        "--work" -> go o{optWork = v} rest
        "--stranger-skey" -> go o{optStranger = v} rest
        _ -> Left ("unknown option " <> flag)
    go _ [flag] = Left (flag <> " needs a value")

-- ---------------------------------------------------------
-- Running the story
-- ---------------------------------------------------------

{- | Resolve the bound statements, refuse an incomplete story, then run it,
leaving one receipt per action. Returns the receipts' directory.
-}
runControls :: [String] -> IO FilePath
runControls args = do
    o <- either (fail . ("cli-controls: " <>)) pure (parseOptions args)
    ledger <-
        Aeson.eitherDecodeFileStrict' (optLedger o)
            >>= either (fail . ("statement ledger: " <>)) pure
    forM_ statementBindings $ \b ->
        either (fail . ("cli-controls: " <>)) pure (resolveStatement ledger b)
    either
        (fail . ("cli-controls: story refused: " <>))
        pure
        (validateControls controlsStory)
    let receipts = optWork o </> "receipts"
        evidence = optWork o </> "evidence"
    mapM_
        (createDirectoryIfMissing True)
        [receipts, evidence, optWork o </> "targets"]
    step <- newIORef (0 :: Int)
    let env = Env o receipts evidence step
    executeStory env controlsStory
    pure receipts

data Env = Env
    { envOptions :: Options
    , envReceipts :: FilePath
    , envEvidence :: FilePath
    , envStep :: IORef Int
    }

-- | Walk the story in order: every action, inside clauses and checks too.
executeStory :: Env -> Story' a -> IO a
executeStory env program = case view program of
    Return a -> pure a
    Action i :>>= next -> perform env i >>= executeStory env . next
    Theorem _ body :>>= next -> executeClauses env (clauses body) >>= executeStory env . next
  where
    executeClauses :: Env -> ClauseProgram thm b -> IO b
    executeClauses e p = case view p of
        Return b -> pure b
        Clause _ leanCheck body :>>= next -> do
            obs <- executeStory e body
            executeStory e (checkAction leanCheck obs)
            executeClauses e (next obs)

type Story' = Story

type ClauseProgram thm = Program (Clause thm CliI)

perform :: Env -> CliI a -> IO a
perform env i = case i of
    Require _ _ -> pure ()
    Run c t k ->
        recorded
            env
            ("run " <> T.pack (commandName c))
            t
            k
            (runCommand env c t k)
    Book t k -> recorded env "book" t k (book env t k)
    FoldUnevaluated t k -> recorded env "fold-unevaluated" t k (foldUnevaluated env t k)
    Observe t k -> recorded env "observe" t k (observe env t k)
    Craft c t k ->
        recorded
            env
            ("craft " <> T.pack (craftedName c))
            t
            k
            (craft env c t k)

{- | Number the action, run it, and write its receipt. An exception is the
action's own outcome, @client-error@, never a stop of the story.
-}
recorded
    :: Env
    -> Text
    -> Target
    -> String
    -> (Receipt -> IO Receipt)
    -> IO Receipt
recorded env name (Target t) k body = do
    n <- readIORef (envStep env)
    modifyIORef' (envStep env) (+ 1)
    let blank = emptyReceipt n name (T.pack t) (T.pack k)
    outcome <- try (body blank)
    r <- case outcome of
        Right r -> pure r
        Left (e :: SomeException)
            | Just (_ :: SomeAsyncException) <- fromException e -> throwIO e
            | otherwise ->
                pure
                    blank
                        { rcOutcome = "client-error"
                        , rcReason = Just (boundedNodeReason 600 (T.pack (show e)))
                        }
    BL.writeFile
        (envReceipts env </> printf "step-%03d.json" n)
        (encodePretty r <> "\n")
    hPutStrLn
        stderr
        ( "cli-controls: step "
            <> show n
            <> " "
            <> T.unpack name
            <> " "
            <> t
            <> (if null k then "" else " " <> k)
            <> ": "
            <> T.unpack (rcOutcome r)
        )
    pure r

-- ---------------------------------------------------------
-- Registries
-- ---------------------------------------------------------

targetDir :: Env -> Target -> FilePath
targetDir env (Target t) = optWork (envOptions env) </> "targets" </> t

-- | A key label as the bytes the registry names it by.
keyBytes :: String -> ByteString
keyBytes = BC.pack

hex :: ByteString -> Text
hex = TE.decodeUtf8 . B16.encode

-- | A registry as this reader derives it from the release and the record.
data Registry = Registry
    { regCfg :: CageConfig
    , regCodes :: NamingCodes
    , regToken :: TokenId
    , regDeployment :: Deployment
    }

{- | Read @registry.json@, derive its configuration again, and refuse any
pin that differs from the one the command saved.
-}
openRegistry :: Env -> Target -> IO Registry
openRegistry env target = do
    let dir = targetDir env target
    saved <-
        Aeson.eitherDecodeFileStrict' (dir </> "registry.json")
            >>= either (fail . ("registry.json: " <>)) pure
    (dep, pins) <- case saved of
        Object o
            | Just d <- KeyMap.lookup "confDeployment" o
            , Just (Object p) <- KeyMap.lookup "confPins" o
            , Aeson.Success dep <- Aeson.fromJSON d ->
                pure (dep, p)
        _ -> fail "registry.json carries no deployment record and pins"
    bp <-
        loadBlueprint (optBlueprint (envOptions env)) >>= either fail pure
    let code name =
            maybe
                (fail ("the blueprint carries no " <> name))
                pure
                (extractCompiledCode (T.pack name) bp)
    stateCode <- code "state.state"
    requestCode <- code "request.request"
    codes <-
        either fail pure (loadApplicationCodes OpenDatumApplication bp)
    (cfg, pinned) <-
        either
            fail
            pure
            ( cageConfigForApplication
                OpenDatumApplication
                codes
                stateCode
                requestCode
                dep
            )
    let derived =
            [ ("pinState", hex (scriptHashBytes (cfgScriptHash cfg)))
            , ("pinApplication", hex (SBS.fromShort (cfgApplicationPolicy cfg)))
            , ("pinAbsent", hex (SBS.fromShort (cfgAbsentPolicy cfg)))
            , ("pinActive", hex (SBS.fromShort (cfgActivePolicy cfg)))
            , ("pinTerminal", hex (SBS.fromShort (cfgTerminalPolicy cfg)))
            ]
    forM_ derived $ \(name, value) ->
        unless (KeyMap.lookup name pins == Just (String value)) $
            fail
                ( "the saved "
                    <> show name
                    <> " is not the one this release and seed give (0x"
                    <> T.unpack value
                    <> ")"
                )
    seedIn <- either fail pure (parseOutRef (depSeedOutRef dep))
    pure
        Registry
            { regCfg = cfg
            , regCodes = pinned
            , regToken =
                TokenId (AssetName (SBS.toShort (deriveAssetName (txInToRef seedIn))))
            , regDeployment = dep
            }

partsOf :: CageConfig -> CageParts
partsOf cfg =
    CageParts
        { partsStateBytes = cageScriptBytes cfg
        , partsRequestBytes = requestScriptBytes cfg
        , partsApplicationPolicy = cfgApplicationPolicy cfg
        , partsActivePolicy = cfgActivePolicy cfg
        , partsAbsentPolicy = cfgAbsentPolicy cfg
        , partsTerminalPolicy = cfgTerminalPolicy cfg
        , partsConsumerScript = cfgConsumerScript cfg
        }

applied :: Registry -> SBS.ShortByteString
applied = ncApplication . regCodes

tokenBytes :: Registry -> ByteString
tokenBytes r = let TokenId (AssetName n) = regToken r in SBS.fromShort n

applicationAddr :: Registry -> Addr
applicationAddr r =
    Addr
        Testnet
        (ScriptHashObj (computeScriptHash (applied r)))
        StakeRefNull

{- | The envelope every insertion of @key@ in this story carries: this
registry, its active policy, the key, the wallet as controller, and a
fixed payload. The command and the booking are handed the same one.
-}
envelopeFor :: Registry -> ByteString -> String -> Envelope
envelopeFor r controller key =
    Envelope
        { envControl =
            Control
                { ctlVersion = envelopeVersion
                , ctlRegistry =
                    StateAsset (scriptHashBytes (cfgScriptHash (regCfg r))) (tokenBytes r)
                , ctlActivePolicy = SBS.fromShort (cfgActivePolicy (regCfg r))
                , ctlKey = keyBytes key
                , ctlController = controller
                , ctlDeposit = 2_000_000
                }
        , envPayload =
            PLC.Map [(PLC.B "control", PLC.B (keyBytes key))]
        }

-- ---------------------------------------------------------
-- The node
-- ---------------------------------------------------------

withNode :: Env -> (NodeSession -> Wallet -> IO a) -> IO a
withNode env body = do
    let o = envOptions env
    wallet <- loadWallet (fromIntegral (optMagic o)) (optWalletKey o)
    withNodeMode
        ( External
            ( ExternalNode
                (optSocket o)
                (fromIntegral (optMagic o))
                (optWalletKey o)
            )
        )
        (`body` wallet)

txIdHex :: ConwayTx -> Text
txIdHex tx = let TxId h = txIdTx tx in hex (hashToBytes (extractHash h))

-- | Keep a transaction's body beside the receipts.
keepBody :: Env -> Int -> ConwayTx -> IO Text
keepBody env n tx = do
    let name = printf "step-%03d-%s.cbor.hex" n (T.unpack (txIdHex tx))
    BS.writeFile
        (envEvidence env </> name)
        (B16.encode (serialize' (eraProtVerHigh @ConwayEra) tx))
    pure (T.pack ("evidence" </> name))

{- | Sign and submit, then wait, bounded, for the chain to confirm it. The
receipt records which of those the transaction reached.
-}
submitAndConfirm
    :: Env
    -> NodeSession
    -> Wallet
    -> Receipt
    -> ConwayTx
    -> IO (Receipt, ConwayTx)
submitAndConfirm env sess wallet r unsigned = do
    let signed = addKeyWitness (walletSignKey wallet) unsigned
        txid = txIdHex signed
    body <- keepBody env (rcStep r) signed
    let r0 = r{rcTxId = Just txid, rcEvidence = rcEvidence r <> [body]}
    answer <- try (submitTx (nsSubmitter sess) signed)
    case answer of
        Left (e :: SomeException) ->
            pure
                ( r0
                    { rcOutcome = "submit-unknown"
                    , rcReason = Just (boundedNodeReason 600 (T.pack (show e)))
                    }
                , signed
                )
        Right (Rejected reason) -> do
            let text = show reason
                (phaseWords, failed) = rejectionEvidence text
                name = printf "step-%03d-rejection.txt" (rcStep r)
                bytes = BC.pack text
            BS.writeFile (envEvidence env </> name) bytes
            pure
                ( r0
                    { rcOutcome = "ledger-refused"
                    , rcRefusingScripts = failed
                    , rcPhaseWords = phaseWords
                    , rcRejectionFile = Just (T.pack ("evidence" </> name))
                    , rcRejectionSha256 = Just (hex (sha256 bytes))
                    , rcReason = Just (boundedNodeReason 600 (T.pack text))
                    }
                , signed
                )
        Right (Submitted _) -> do
            waiter <- async (awaitTxWindow signed (T.unpack txid))
            seen <- timeout 120_000_000 (waitCatch waiter)
            case seen of
                Just (Right ()) -> pure (r0{rcOutcome = "accepted"}, signed)
                Just (Left e) ->
                    pure
                        ( r0
                            { rcOutcome = "unconfirmed"
                            , rcReason = Just (T.pack (show e))
                            }
                        , signed
                        )
                Nothing -> do
                    void (async (cancel waiter))
                    pure
                        ( r0
                            { rcOutcome = "unconfirmed"
                            , rcReason = Just "no confirmation within 120 seconds"
                            }
                        , signed
                        )

-- ---------------------------------------------------------
-- Commands
-- ---------------------------------------------------------

runCommand
    :: Env -> Command -> Target -> String -> Receipt -> IO Receipt
runCommand env c target key r = do
    let o = envOptions env
        dir = targetDir env target
        node =
            ["--node-socket", optSocket o, "--network-magic", show (optMagic o)]
        wallet = ["--wallet-skey", optWalletKey o, "--confirm-timeout", "120"]
        common = ["--registry", dir, "--blueprint", optBlueprint o]
        keyArg = ["--key", T.unpack (hex (keyBytes key))]
    args <- case c of
        Create -> do
            (_, preview, _) <-
                singular env r "preview" $
                    ["registry", "create", "--preview"] <> common <> node <> wallet
            seed <- case field "seed" preview of
                Just (String s) -> pure (T.unpack s)
                _ -> fail "the preview named no seed"
            pure
                (["registry", "create", "--seed", seed] <> common <> node <> wallet)
        Insert -> do
            reg <- openRegistry env target
            w <- loadWallet (fromIntegral (optMagic o)) (optWalletKey o)
            let e = envelopeFor reg (addrKeyHashBytes (walletAddr w)) key
                path = envEvidence env </> printf "step-%03d-envelope.json" (rcStep r)
            BL.writeFile path (encodePretty (envelopeToJson e))
            pure
                ( ["registry", "insert"]
                    <> common
                    <> keyArg
                    <> ["--envelope", path]
                    <> node
                    <> wallet
                )
        Terminate ->
            pure (["registry", "terminate"] <> common <> keyArg <> node <> wallet)
        Update n -> do
            let path = envEvidence env </> printf "step-%03d-payload.json" (rcStep r)
            BL.writeFile path (encodePretty (payloadOf n))
            pure
                ( ["registry", "update"]
                    <> common
                    <> keyArg
                    <> ["--payload", path]
                    <> node
                    <> wallet
                )
        Inspect -> pure (["registry", "inspect"] <> common <> keyArg <> node)
    (status, printed, file) <- singular env r (commandName c) args
    let outcome = case field "outcome" printed of
            Just (String s) -> s
            _ -> "no-receipt"
        named k = case field k printed of
            Just (String s) -> Just s
            _ -> Nothing
    pure
        r
            { rcOutcome = outcome
            , rcTxId = named "fold" <|> named "booking"
            , rcPendingRequest = named "pendingRequest"
            , rcReason =
                maybe
                    (Just (T.pack ("exit " <> show status)))
                    (Just . T.take 600)
                    (named "reason")
            , rcEvidence = rcEvidence r <> [file]
            , rcCommand = printed
            }
  where
    field k v = case v of
        Just (Object m) -> KeyMap.lookup k m
        _ -> Nothing

{- | One @singular@ process. Its printed receipt and its standard error are
kept; the parsed receipt is returned when it is JSON.
-}
singular
    :: Env
    -> Receipt
    -> String
    -> [String]
    -> IO (ExitCode, Maybe Value, Text)
singular env r label args = do
    (status, out, err) <-
        readProcessWithExitCode (optSingular (envOptions env)) args ""
    let base = printf "step-%03d-%s" (rcStep r) label
    writeFile (envEvidence env </> base <> ".json") out
    writeFile (envEvidence env </> base <> ".err") err
    pure
        ( status
        , Aeson.decodeStrict (BC.pack out)
        , T.pack ("evidence" </> base <> ".json")
        )

-- ---------------------------------------------------------
-- Booking, unevaluated fold, readback
-- ---------------------------------------------------------

-- | The application's published reference output.
applicationReference
    :: Registry -> Attached -> IO (TxIn, TxOut ConwayEra)
applicationReference reg att =
    case [ u
         | u@(_, o) <- attRefUtxos att
         , SJust sc <- [o ^. referenceScriptTxOutL]
         , hashScript sc == computeScriptHash (applied reg)
         ] of
        (u : _) -> pure u
        [] -> fail "the deployment records no published application reference"

book :: Env -> Target -> String -> Receipt -> IO Receipt
book env target key r = do
    reg <- openRegistry env target
    withNode env $ \sess wallet -> do
        let prov = nsProvider sess
            cfg = regCfg reg
        att <- attach prov (regDeployment reg) (partsOf cfg)
        (appRef, _) <- applicationReference reg att
        let e = envelopeFor reg (addrKeyHashBytes (walletAddr wallet)) key
            approval =
                (insertApproval Testnet (applied reg) (fst (attStateUtxo att)) e)
                    { baScriptReference = Just appRef
                    }
            dest = insertDestination Testnet (applied reg) e
        result <- newIORef Nothing
        let submit unsigned = do
                (r', signed) <- submitAndConfirm env sess wallet r unsigned
                modifyIORef' result (const (Just r'))
                unless (rcOutcome r' == "accepted") $
                    fail ("the booking was not accepted: " <> T.unpack (rcOutcome r'))
                pure signed
        attempt <-
            try
                ( bookEdgeWith
                    cfg
                    prov
                    submit
                    (walletAddr wallet)
                    (regToken reg)
                    (keyBytes key)
                    edgeInsertActive
                    dest
                    (ctlDeposit (envControl e))
                    (Just approval)
                )
        recordedSubmission <- readIORef result
        case (attempt, recordedSubmission) of
            (_, Just r') -> pure r'
            (Left (err :: SomeException), Nothing) ->
                pure
                    r
                        { rcOutcome = "client-error"
                        , rcReason = Just (boundedNodeReason 600 (T.pack (show err)))
                        }
            (Right _, Nothing) -> fail "the booking returned without submitting"

-- | A change a control makes to the fold the registry's duties describe.
data FoldTweak
    = -- | The fold exactly as the duties describe it
      AsOwed
    | -- | The one output paying the controller holds one lovelace less
      PayShort
    | -- | The fold also spends this key's live holding with @Release@
      AlsoRelease String

{- | Fold the one request pending for @key@ (or, when none is named, the
only request pending), with the registry's duties and the application's
context, building it without local evaluation. Proofs come from a copy of
a saved mirror whose root is the chain's: the backend's own, once one of
its folds was accepted, else the command's.
-}
foldUnevaluated :: Env -> Target -> String -> Receipt -> IO Receipt
foldUnevaluated env target key = foldWith env target (Just key) AsOwed False

{- | The same, folded (funded, signed for its fee and paid its change) by
the story's wallet, or by the stranger when asked: a fold is
permissionless, and a folder other than the controller keeps the change
off the controller's key, where the application sums what it is paid.
-}
foldWith
    :: Env
    -> Target
    -> Maybe String
    -> FoldTweak
    -> Bool
    -> Receipt
    -> IO Receipt
foldWith env target requested tweak byStranger r = do
    let dir = targetDir env target
        backendManifest = backendDir env target </> "registry.json"
        opts = envOptions env
    reg <- openRegistry env target
    stranger <-
        loadWallet (fromIntegral (optMagic opts)) (optStranger opts)
    withNode env $ \sess wallet -> do
        let folder = if byStranger then stranger else wallet
        let prov = nsProvider sess
            cfg = regCfg reg
            tok = regToken reg
            home = walletAddr wallet
            stateHash = hex (scriptHashBytes (cfgScriptHash cfg))
            appHash = hex (scriptHashBytes (computeScriptHash (applied reg)))
            r0 =
                r
                    { rcEvaluation = Just "skipped"
                    , rcStateValidator = Just stateHash
                    , rcApplication = Just appHash
                    }
        att <- attach prov (regDeployment reg) (partsOf cfg)
        let (stateIn, stateOut) = attStateUtxo att
        oldState <- case extractCageDatum stateOut of
            Just (StateDatum st) -> pure st
            _ -> fail "the registry's state output carries no state datum"
        pending <- Cage.queryUTxOs prov (requestAddrFromCfg cfg tok Testnet)
        let requests =
                [ (u, q)
                | u@(_, o) <- pending
                , Just (RequestDatum q) <- [extractCageDatum o]
                , maybe True ((== requestKey q) . keyBytes) requested
                ]
        (request, req) <- case requests of
            [one] -> pure one
            us ->
                fail
                    ( show (length us)
                        <> " requests are pending for the fold; it needs exactly one"
                    )
        let OnChainRoot chain = stateRoot oldState
            opened manifest = do
                saved <- loadMirror manifest
                if Map.member tok saved
                    then do
                        (tm, dump) <- mkPureTrieManagerFrom saved
                        Root local <- withTrie tm tok getRoot
                        pure [(tm, dump) | local == chain]
                    else pure []
        mine <- opened backendManifest
        theirs <- opened (dir </> "registry.json")
        (tm, dump) <- case mine <> theirs of
            (m : _) -> pure m
            [] ->
                fail
                    ( "no saved mirror commits to the chain's root 0x"
                        <> T.unpack (hex chain)
                    )
        live <- Cage.queryUTxOs prov (applicationAddr reg)
        let e =
                envelopeFor
                    reg
                    (addrKeyHashBytes home)
                    (BC.unpack (requestKey req))
        ctx0 <- registryContextFor cfg (regCodes reg) prov (attRefUtxos att)
        ctx <-
            either fail pure (withApplication (applied reg) Nothing [e] live ctx0)
        pp <- Cage.queryProtocolParams prov
        owedDuties <-
            either fail pure (registryDuties cfg pp oldState ctx [request] [True])
        unless (null (rdInputs owedDuties)) $
            fail "the fold's duties need ordinary inputs; this backend folds none"
        duties <- case tweak of
            AsOwed -> pure owedDuties
            PayShort ->
                case [o | o <- rdOutputs owedDuties, o ^. addrTxOutL == home] of
                    [paid] ->
                        let Coin c = paid ^. coinTxOutL
                        in  pure
                                owedDuties
                                    { rdOutputs =
                                        [ if o == paid then o & coinTxOutL .~ Coin (c - 1) else o
                                        | o <- rdOutputs owedDuties
                                        ]
                                    }
                    ps ->
                        fail
                            ( show (length ps)
                                <> " outputs pay the controller; the short payment needs exactly one"
                            )
            AlsoRelease key -> case holdingsOf reg key live of
                [holding@(_, hOut)] ->
                    pure
                        owedDuties
                            { rdSpends =
                                rdSpends owedDuties
                                    <> [ ConnectedSpend
                                            { csUtxo = holding
                                            , csRedeemer = releaseRedeemer
                                            , csScript = scriptFromBytes "open-datum" (applied reg)
                                            }
                                       ]
                            , rdOutputs =
                                rdOutputs owedDuties
                                    <> [mkBasicTxOut home (hOut ^. valueTxOutL)]
                            }
                hs ->
                    fail
                        ( show (length hs)
                            <> " live holdings for the released key; it needs one"
                        )
        wallets <- Cage.queryUTxOs prov (walletAddr folder)
        feeUtxo <-
            case sortOn
                (Down . (^. coinTxOutL) . snd)
                (filter (adaOnlyOut . snd) wallets) of
                (u : _) -> pure u
                [] -> fail "the folder has no ada-only output to fund the fold"
        let carried =
                [ hashScript s
                | (_, o) <- rcRefUtxos ctx
                , SJust s <- [o ^. referenceScriptTxOutL]
                ]
            owed :: [Script ConwayEra]
            owed = map csScript (rdSpends duties) <> map cmScript (rdMints duties)
        (unsigned, _) <-
            connectedFoldTx
                ConnectedFoldArgs
                    { cfaCfg = cfg
                    , cfaProvider = prov
                    , cfaTrie = tm
                    , cfaToken = tok
                    , cfaFeeAddr = walletAddr folder
                    , cfaStateUtxo = (stateIn, stateOut)
                    , cfaReqUtxos = [request]
                    , cfaFeeUtxo = feeUtxo
                    , cfaPp = pp
                    , cfaSpends = rdSpends duties
                    , cfaMints = rdMints duties
                    , cfaOutputs = rdOutputs duties
                    , cfaSigners = rdSigners duties
                    , cfaRefUtxos = rcRefUtxos ctx
                    , cfaAttachScripts = filter ((`notElem` carried) . hashScript) owed
                    , cfaSkipEval = True
                    , cfaAdjustRoot = id
                    }
        void (evaluate unsigned)
        result <- fst <$> submitAndConfirm env sess folder r0 unsigned
        -- The chain took the edge: the backend's mirror takes it too.
        when (rcOutcome result == "accepted") $ do
            withTrie tm tok $ \t -> void (walkEdge t (requestKey req) (requestEdge req))
            createDirectoryIfMissing True (backendDir env target)
            dump >>= saveMirror backendManifest
        pure result

-- | Where the backend keeps its own copy of a target's mirror.
backendDir :: Env -> Target -> FilePath
backendDir env (Target t) = optWork (envOptions env) </> "backend" </> t

observe :: Env -> Target -> String -> Receipt -> IO Receipt
observe env target key r = do
    reg <- openRegistry env target
    withNode env $ \sess wallet -> do
        let prov = nsProvider sess
            cfg = regCfg reg
            identity = scriptHashBytes (cfgScriptHash cfg) <> tokenBytes reg
        att <- attach prov (regDeployment reg) (partsOf cfg)
        root <- case extractCageDatum (snd (attStateUtxo att)) of
            Just (StateDatum st) -> let OnChainRoot b = stateRoot st in pure b
            _ -> fail "the registry's state output carries no state datum"
        live <- Cage.queryUTxOs prov (applicationAddr reg)
        let holdings =
                [ (i, o)
                | (i, o) <- live
                , Right e <- [liveEnvelope o]
                , let c = envControl e
                , ctlVersion c == envelopeVersion
                , registryBytes (ctlRegistry c) == identity
                , ctlActivePolicy c == SBS.fromShort (cfgActivePolicy cfg)
                , ctlKey c == keyBytes key
                , heldOf c o == 1
                ]
        holding <- case holdings of
            [] -> pure Nothing
            [u] -> pure (Just u)
            _ -> fail "more than one live output claims the key"
        pending <-
            Cage.queryUTxOs prov (requestAddrFromCfg cfg (regToken reg) Testnet)
        wallets <- Cage.queryUTxOs prov (walletAddr wallet)
        leaf <- authenticatedLeaf env target reg root key
        let lovelace o = let Coin c = o ^. coinTxOutL in c
        pure
            r
                { rcOutcome = "observed"
                , rcStateValidator = Just (hex (scriptHashBytes (cfgScriptHash cfg)))
                , rcObservation =
                    Just
                        Observation
                            { obRoot = hex root
                            , obHolding = renderOutRef . fst <$> holding
                            , obHoldingLovelace = lovelace . snd <$> holding
                            , obPending = map (renderOutRef . fst) (sortOn fst pending)
                            , obPendingLovelace = sum (map (lovelace . snd) pending)
                            , obWalletLovelace = sum (map (lovelace . snd) wallets)
                            , obLeaf = leaf
                            }
                }

-- ---------------------------------------------------------
-- Payloads and hand-built transactions
-- ---------------------------------------------------------

-- | The story's payloads, as the command reads them: unrelated shapes.
payloadOf :: Int -> Value
payloadOf n = case n of
    1 ->
        Aeson.object
            [ "constructor" Aeson..= (3 :: Int)
            , "fields"
                Aeson..= [ Aeson.object ["bytes" Aeson..= ("626f62" :: Text)]
                         , Aeson.object
                            ["int" Aeson..= (123_456_789_012_345_678_901_234_567_890 :: Integer)]
                         ]
            ]
    _ ->
        Aeson.object
            [ "list"
                Aeson..= [ Aeson.object
                            [ "map"
                                Aeson..= [ Aeson.object
                                            [ "k" Aeson..= Aeson.object ["int" Aeson..= (-1 :: Int)]
                                            , "v" Aeson..= Aeson.object ["bytes" Aeson..= ("00ff" :: Text)]
                                            ]
                                         ]
                            ]
                         , Aeson.object ["list" Aeson..= ([] :: [Value])]
                         ]
            ]

-- | The key's live holdings at the application, as this registry's.
holdingsOf
    :: Registry
    -> String
    -> [(TxIn, TxOut ConwayEra)]
    -> [(TxIn, TxOut ConwayEra)]
holdingsOf reg key live =
    [ (i, o)
    | (i, o) <- live
    , Right e <- [liveEnvelope o]
    , let c = envControl e
    , ctlVersion c == envelopeVersion
    , registryBytes (ctlRegistry c)
        == scriptHashBytes (cfgScriptHash (regCfg reg)) <> tokenBytes reg
    , ctlActivePolicy c == SBS.fromShort (cfgActivePolicy (regCfg reg))
    , ctlKey c == keyBytes key
    , heldOf c o == 1
    ]

-- | The empty query GADT a hand-built program runs under.
data NoQuery a

{- | Build one hand-made transaction against the key's live holding and
submit it without local evaluation, so the node's verdict is the
receipt's. Every shape spends the holding once under the applied script,
read by reference, with the wallet's largest ada-only output as fee and
collateral.
-}
craft :: Env -> Crafted -> Target -> String -> Receipt -> IO Receipt
craft env c target key r = case c of
    BookingByStranger -> craftBooking env c target key r
    BookingOtherDestination -> craftBooking env c target key r
    BookingShortDeposit -> craftBooking env c target key r
    BookingNoDatum -> craftBooking env c target key r
    EnvelopeOtherStateName -> craftBooking env c target key r
    EnvelopeOtherStatePolicy -> craftBooking env c target key r
    EnvelopeOtherRegistry -> craftBooking env c target key r
    TerminateBooking -> craftTermination env False target key r
    TerminateBookingByStranger -> craftTermination env True target key r
    ReleaseInOtherFold -> foldWith env target Nothing (AlsoRelease key) False r
    FoldPaysShort -> foldWith env target (Just key) PayShort True r
    FoldPaysInFull -> foldWith env target (Just key) AsOwed True r
    _ -> craftHolding env c target key r

-- | A hand-built transaction against the key's live holding.
craftHolding
    :: Env -> Crafted -> Target -> String -> Receipt -> IO Receipt
craftHolding env c target key r = do
    let o = envOptions env
    reg <- openRegistry env target
    stranger <- loadWallet (fromIntegral (optMagic o)) (optStranger o)
    withNode env $ \sess wallet -> do
        let prov = nsProvider sess
            appHash = hex (scriptHashBytes (computeScriptHash (applied reg)))
            r0 = r{rcEvaluation = Just "skipped", rcApplication = Just appHash}
            mine = addrKeyHashBytes (walletAddr wallet)
            theirs = addrKeyHashBytes (walletAddr stranger)
        att <- attach prov (regDeployment reg) (partsOf (regCfg reg))
        appRef <- applicationReference reg att
        live <- Cage.queryUTxOs prov (applicationAddr reg)
        holding@(hIn, hOut) <- case holdingsOf reg key live of
            [u] -> pure u
            us ->
                fail
                    ( show (length us)
                        <> " live holdings for the key; the story needs exactly one"
                    )
        e <- either fail pure (liveEnvelope hOut)
        let ctl = envControl e
        unless (ctlController ctl == mine) $
            fail "the holding's controller is not this story's wallet"
        pp <- Cage.queryProtocolParams prov
        wallets <- Cage.queryUTxOs prov (walletAddr wallet)
        feeUtxo <-
            case sortOn
                (Down . (^. coinTxOutL) . snd)
                (filter (adaOnlyOut . snd) wallets) of
                (u : _) -> pure u
                [] -> fail "the wallet has no ada-only output to fund the transaction"
        let MaryValue (Coin held) tokens = hOut ^. valueTxOutL
            payload = PLC.Constr 7 [PLC.I (fromIntegral (rcStep r))]
            next = continuationOf hOut e payload
            with c' = continuationOf hOut e{envControl = c'} payload
            home = walletAddr wallet
            minFor out =
                let Coin first = getMinCoinTxOut pp out
                    Coin settled = getMinCoinTxOut pp (out & coinTxOutL .~ Coin first)
                in  settled
            tokenAway =
                let probe = mkBasicTxOut home (MaryValue (Coin 0) tokens)
                in  mkBasicTxOut home (MaryValue (Coin (minFor probe)) tokens)
            (outputs, redeemer, signer) = case c of
                HonestUpdate -> ([next], updateRedeemer, mine)
                UpdateWithoutScript -> ([next], updateRedeemer, mine)
                UpdateByStranger -> ([next], updateRedeemer, theirs)
                UpdateOtherController ->
                    ([with ctl{ctlController = theirs}], updateRedeemer, mine)
                UpdateDepositTampered -> ([with ctl{ctlDeposit = 1}], updateRedeemer, mine)
                UpdateEscaped -> ([next & addrTxOutL .~ home], updateRedeemer, mine)
                UpdateTokenLeft ->
                    ( [next & valueTxOutL .~ MaryValue (Coin held) mempty, tokenAway]
                    , updateRedeemer
                    , mine
                    )
                UpdateShortDeposit ->
                    ( [next & coinTxOutL .~ Coin (ctlDeposit ctl - 1)]
                    , updateRedeemer
                    , mine
                    )
                UpdateWithoutDatum -> ([next & datumTxOutL .~ NoDatum], updateRedeemer, mine)
                EarlyWithdrawal ->
                    ([mkBasicTxOut home (hOut ^. valueTxOutL)], releaseRedeemer, mine)
                other -> error ("not a shape against a holding: " <> show other)
            prog :: Tx.TxBuild NoQuery Void ()
            prog = do
                _ <- Tx.spendScript hIn redeemer
                mapM_ Tx.output outputs
                Tx.requireSignature (addrWitnessKeyHash signer)
                unless (c == UpdateWithoutScript) $ Tx.reference (fst appRef)
                Tx.collateral (fst feeUtxo)
            skipEval tx =
                let Redeemers rdmrs = tx ^. witsTxL . rdmrsTxWitsL
                in  pure (Map.map (const (Right generousUnits)) rdmrs)
        built <-
            Tx.build
                (Tx.mkPParamsBound pp)
                (Tx.InterpretIO (const (pure undefined)))
                skipEval
                [feeUtxo, holding]
                [appRef | c /= UpdateWithoutScript]
                home
                prog
        unsigned <-
            either
                (fail . ("the transaction did not build: " <>) . show)
                pure
                built
        let witnessed =
                if c == UpdateByStranger
                    then addKeyWitness (walletSignKey stranger) unsigned
                    else unsigned
        fst <$> submitAndConfirm env sess wallet r0 witnessed

-- | The last byte of a name or hash, changed: the same length, another value.
flipLast :: ByteString -> ByteString
flipLast bs
    | BS.null bs = BS.singleton 1
    | otherwise = BS.init bs <> BS.singleton (BS.last bs `xor` 1)

{- | Submit a booking through 'bookEdgeWith', signed by @payer@, and
record the node's verdict. A booking is never evaluated locally: its
approval carries stated budgets, so the node judges every one.
-}
bookedBy
    :: Env
    -> NodeSession
    -> Wallet
    -> Receipt
    -> ((ConwayTx -> IO ConwayTx) -> IO ConwayTx)
    -> IO Receipt
bookedBy env sess payer r building = do
    result <- newIORef Nothing
    let submit unsigned = do
            (r', signed) <- submitAndConfirm env sess payer r unsigned
            modifyIORef' result (const (Just r'))
            unless (rcOutcome r' == "accepted") $
                fail ("the booking was not accepted: " <> T.unpack (rcOutcome r'))
            pure signed
    attempt <- try (building submit)
    recordedSubmission <- readIORef result
    case (attempt, recordedSubmission) of
        (_, Just r') -> pure r'
        (Left (err :: SomeException), Nothing) ->
            pure
                r
                    { rcOutcome = "client-error"
                    , rcReason = Just (boundedNodeReason 600 (T.pack (show err)))
                    }
        (Right _, Nothing) -> fail "the booking returned without submitting"

{- | An insertion booking of @key@ with one field changed from the booking
the ordinary insert makes: its payer, its destination, its request deposit,
or the registry its envelope names.
-}
craftBooking
    :: Env -> Crafted -> Target -> String -> Receipt -> IO Receipt
craftBooking env c target key r = do
    let o = envOptions env
    reg <- openRegistry env target
    stranger <- loadWallet (fromIntegral (optMagic o)) (optStranger o)
    withNode env $ \sess wallet -> do
        let prov = nsProvider sess
            cfg = regCfg reg
            appHash = hex (scriptHashBytes (computeScriptHash (applied reg)))
            r0 = r{rcEvaluation = Just "skipped", rcApplication = Just appHash}
            honest = envelopeFor reg (addrKeyHashBytes (walletAddr wallet)) key
            ctl = envControl honest
            StateAsset statePolicy stateName = ctlRegistry ctl
            named asset = honest{envControl = ctl{ctlRegistry = asset}}
            e = case c of
                EnvelopeOtherStateName -> named (StateAsset statePolicy (flipLast stateName))
                EnvelopeOtherStatePolicy -> named (StateAsset (flipLast statePolicy) stateName)
                EnvelopeOtherRegistry ->
                    named (StateAsset (flipLast statePolicy) (flipLast stateName))
                _ -> honest
            payer = if c == BookingByStranger then stranger else wallet
        att <- attach prov (regDeployment reg) (partsOf cfg)
        (appRef, _) <- applicationReference reg att
        let approval =
                (insertApproval Testnet (applied reg) (fst (attStateUtxo att)) e)
                    { baScriptReference = Just appRef
                    }
            (address, datumHash) = insertDestination Testnet (applied reg) e
            dest = case c of
                BookingOtherDestination -> (flipLast address, datumHash)
                BookingNoDatum -> (address, BS.empty)
                _ -> (address, datumHash)
            deposit =
                ctlDeposit (envControl e)
                    - (if c == BookingShortDeposit then 1 else 0)
        bookedBy env sess payer r0 $ \submit ->
            bookEdgeWith
                cfg
                prov
                submit
                (walletAddr payer)
                (regToken reg)
                (keyBytes key)
                edgeInsertActive
                dest
                deposit
                (Just approval)

{- | The termination booking the ordinary terminate makes, by the
controller, or the same booking by another wallet owning its request.
-}
craftTermination
    :: Env -> Bool -> Target -> String -> Receipt -> IO Receipt
craftTermination env byStranger target key r = do
    let o = envOptions env
    reg <- openRegistry env target
    stranger <- loadWallet (fromIntegral (optMagic o)) (optStranger o)
    withNode env $ \sess wallet -> do
        let prov = nsProvider sess
            cfg = regCfg reg
            appHash = hex (scriptHashBytes (computeScriptHash (applied reg)))
            r0 = r{rcEvaluation = Just "skipped", rcApplication = Just appHash}
            payer = if byStranger then stranger else wallet
        att <- attach prov (regDeployment reg) (partsOf cfg)
        (appRef, _) <- applicationReference reg att
        live <- Cage.queryUTxOs prov (applicationAddr reg)
        (liveIn, _) <- case holdingsOf reg key live of
            [u] -> pure u
            us ->
                fail
                    ( show (length us)
                        <> " live holdings for the key; the booking needs one"
                    )
        let approval =
                ( terminateApproval
                    (applied reg)
                    (fst (attStateUtxo att))
                    liveIn
                    (keyBytes key)
                    (addrKeyHashBytes (walletAddr payer))
                )
                    { baScriptReference = Just appRef
                    }
        bookedBy env sess payer r0 $ \submit ->
            bookEdgeWith
                cfg
                prov
                submit
                (walletAddr payer)
                (regToken reg)
                (keyBytes key)
                edgeUpdateTerminal
                terminateDestination
                edgeDeposit
                (Just approval)

-- | The SHA-256 digest of bytes kept beside a receipt.
sha256 :: ByteString -> ByteString
sha256 = hashToBytes . hashWith @SHA256 id

{- | The key's leaf, proven against the chain's root ('provenLeaf') from the
tree nodes of a saved mirror: the backend's own copy, else the command's.
A copy that commits to another root, or whose nodes prove no single leaf,
answers nothing; neither copy is ever written.
-}
authenticatedLeaf
    :: Env -> Target -> Registry -> ByteString -> String -> IO (Maybe Text)
authenticatedLeaf env target reg chain key = go manifests
  where
    manifests =
        [ backendDir env target </> "registry.json"
        , targetDir env target </> "registry.json"
        ]
    go [] = pure Nothing
    go (manifest : rest) = do
        saved <- loadMirror manifest
        case Map.lookup (regToken reg) saved of
            Nothing -> go rest
            Just db ->
                provenLeaf db (keyBytes key) chain >>= \case
                    Right leaf -> pure (Just (leafText leaf))
                    Left _ -> go rest
