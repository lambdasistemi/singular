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
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (async, cancel, waitCatch)
import Control.Exception
    ( SomeAsyncException
    , SomeException
    , bracket
    , evaluate
    , finally
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
import Data.Maybe (isNothing)
import Data.Ord (Down (..))
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time.Clock (diffUTCTime, getCurrentTime)
import Lens.Micro ((&), (.~), (^.))
import PlutusCore.Data qualified as PLC
import System.Directory
    ( copyFile
    , createDirectoryIfMissing
    , doesFileExist
    , doesPathExist
    , renameFile
    )
import System.Environment (getEnvironment)
import System.Exit (ExitCode (..))
import System.FilePath (makeRelative, takeDirectory, (</>))
import System.IO
    ( IOMode (..)
    , SeekMode (..)
    , hPutStrLn
    , openFile
    , stderr
    )
import System.Posix.IO
    ( LockRequest (..)
    , OpenFileFlags (..)
    , OpenMode (..)
    , closeFd
    , defaultFileFlags
    , openFd
    , setLock
    )
import System.Posix.Signals (sigKILL, signalProcess)
import System.Process
    ( CreateProcess (..)
    , ProcessHandle
    , StdStream (..)
    , createProcess
    , getPid
    , getProcessExitCode
    , proc
    , readProcessWithExitCode
    , terminateProcess
    , waitForProcess
    )
import System.Timeout (timeout)
import Text.Printf (printf)

import Cardano.Crypto.Hash.Class (hashToBytes, hashWith)
import Cardano.Crypto.Hash.SHA256 (SHA256)
import Cardano.Ledger.Address (Addr (..))
import Cardano.Ledger.Api.PParams
    ( ppMaxBlockExUnitsL
    , ppMaxTxExUnitsL
    )
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
import Cardano.Ledger.Mary.Value (MaryValue (..), MultiAsset (..))
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
    , skipEvalUnits
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

import Conformance.Cli.Admission
    ( lastEventOf
    , lastMaybe
    , sha256Hex
    , submittedIn
    )
import Conformance.Cli.Controls
    ( CliI (..)
    , Command (..)
    , Crafted (..)
    , Observation (..)
    , ProcessEvidence (..)
    , Provocation (..)
    , Receipt (..)
    , Resolved (..)
    , Story
    , Submission (..)
    , Target (..)
    , cliSpecification
    , commandName
    , controlsStory
    , craftedName
    , emptyReceipt
    , obligationBindings
    , provocationName
    , rejectionEvidence
    , resolveObligation
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
    , optSpecification :: FilePath
    {- ^ The CLI's specification, whose rows the client obligations bind;
    by default the one in the repository holding the statement ledger
    -}
    }

parseOptions :: [String] -> Either String Options
parseOptions = go (Options "" "" "" "" 0 "" "" "" "")
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
        "--specification" -> go o{optSpecification = v} rest
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
    let specification
            | null (optSpecification o) =
                takeDirectory (takeDirectory (takeDirectory (optLedger o)))
                    </> cliSpecification
            | otherwise = optSpecification o
    rows <- TE.decodeUtf8 <$> BS.readFile specification
    forM_ obligationBindings $ \b ->
        either
            (fail . ("cli-controls: " <>))
            pure
            (resolveObligation (sha256Hex . TE.encodeUtf8) rows b)
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
    wallet <- loadWallet (fromIntegral (optMagic o)) (optWalletKey o)
    -- One session for every backend action: opening one per action spends
    -- the requests' processing window before their folds are built.
    withNodeMode
        ( External
            ( ExternalNode
                (optSocket o)
                (fromIntegral (optMagic o))
                (optWalletKey o)
            )
        )
        $ \sess ->
            executeStory
                (Env o receipts evidence step (Just (sess, wallet)))
                controlsStory
    pure receipts

data Env = Env
    { envOptions :: Options
    , envReceipts :: FilePath
    , envEvidence :: FilePath
    , envStep :: IORef Int
    , envSession :: Maybe (NodeSession, Wallet)
    -- ^ The one node session every backend action shares
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
    Provoke p t k ->
        recorded
            env
            ("provoke " <> T.pack (provocationName p))
            t
            k
            (provoke env p t k)

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
                , ctlDeposit = storyDeposit
                }
        , envPayload =
            PLC.Map [(PLC.B "control", PLC.B (keyBytes key))]
        }

-- ---------------------------------------------------------
-- The node
-- ---------------------------------------------------------

withNode :: Env -> (NodeSession -> Wallet -> IO a) -> IO a
withNode Env{envSession = Just (sess, wallet)} body = body sess wallet
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
keepBody :: Env -> Int -> ConwayTx -> IO (Text, Text)
keepBody env n tx = do
    let name = printf "step-%03d-%s.cbor.hex" n (T.unpack (txIdHex tx))
        bytes = B16.encode (serialize' (eraProtVerHigh @ConwayEra) tx)
    BS.writeFile (envEvidence env </> name) bytes
    pure (T.pack ("evidence" </> name), hex (sha256 bytes))

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
    (body, bodyDigest) <- keepBody env (rcStep r) signed
    let r0 =
            r
                { rcTxId = Just txid
                , rcEvidence = rcEvidence r <> [body]
                , rcBodyFile = Just body
                , rcBodySha256 = Just bodyDigest
                }
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
    args <- commandArgs env c target key r
    let journal = targetDir env target </> "journal.jsonl"
    before <- journalLines journal
    (status, printed, file) <- singular env r (commandName c) args
    (submissions, resolved) <-
        journalledSubmissions env (drop before <$> journalLines' journal)
    pure
        (fromPrinted r status printed file)
            { rcSubmissions = submissions
            , rcResolved = resolved
            }

-- | The arguments of one ordinary command, writing the files it reads.
commandArgs
    :: Env -> Command -> Target -> String -> Receipt -> IO [String]
commandArgs env c target key r = do
    let o = envOptions env
        dir = targetDir env target
        node =
            ["--node-socket", optSocket o, "--network-magic", show (optMagic o)]
        wallet = ["--wallet-skey", optWalletKey o, "--confirm-timeout", "120"]
        common = ["--registry", dir, "--blueprint", optBlueprint o]
        keyArg = ["--key", T.unpack (hex (keyBytes key))]
    case c of
        Create -> do
            seed <- previewSeed env r "preview" (optWalletKey o) dir Nothing
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

{- | A preview of a create into @dir@ with a wallet: the seed it names. With
a seed, the preview succeeds only while that seed is an unspent output of
the wallet. It writes nothing.
-}
previewSeed
    :: Env
    -> Receipt
    -> String
    -> FilePath
    -> FilePath
    -> Maybe String
    -> IO String
previewSeed env r label skey dir seed = do
    let o = envOptions env
    (_, preview, _) <-
        singular env r label $
            [ "registry"
            , "create"
            , "--preview"
            , "--registry"
            , dir
            , "--blueprint"
            , optBlueprint o
            ]
                <> ["--node-socket", optSocket o, "--network-magic", show (optMagic o)]
                <> ["--wallet-skey", skey]
                <> maybe [] (\s -> ["--seed", s]) seed
    case printedField "seed" preview of
        Just (String s) -> pure (T.unpack s)
        _ -> fail ("the " <> label <> " named no seed")

-- | A command's receipt, filled from what it printed.
fromPrinted :: Receipt -> ExitCode -> Maybe Value -> Text -> Receipt
fromPrinted r status printed file =
    r
        { rcOutcome = case printedField "outcome" printed of
            Just (String s) -> s
            _ -> "no-receipt"
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
    named k = case printedField k printed of
        Just (String s) -> Just s
        _ -> Nothing

printedField :: Aeson.Key -> Maybe Value -> Maybe Value
printedField k v = case v of
    Just (Object m) -> KeyMap.lookup k m
    _ -> Nothing

-- ---------------------------------------------------------
-- Provoked commands
-- ---------------------------------------------------------

{- | Run an ordinary command under a condition of its process, and record
what the process left: the registry's journal before and after, the exit
status, and, as the condition needs, the saved files of a registry it must
not touch and a probe of its seed.
-}
provoke
    :: Env -> Provocation -> Target -> String -> Receipt -> IO Receipt
provoke env p target key r = do
    let o = envOptions env
        work = optWork o
        dir = targetDir env target
        journal = dir </> "journal.jsonl"
        hold = envEvidence env </> printf "step-%03d-hold" (rcStep r)
        seedFile = backendDir env target </> "seed"
        label = provocationName p
    createDirectoryIfMissing True (backendDir env target)
    before <- journalLines journal
    let finishFrom from status printed file extra = do
            ls <- journalLines' journal
            let delta = drop from ls
            (submissions, resolved) <- journalledSubmissions env (pure delta)
            let base = fromPrinted r status printed file
            pure
                base
                    { rcSubmissions = submissions
                    , rcResolved = resolved
                    , rcProcess =
                        Just
                            ( extra
                                ProcessEvidence
                                    { peJournal = T.pack (makeRelative work journal)
                                    , peJournalBefore = from
                                    , peJournalAfter = length ls
                                    , peLastEvent = maybe "" lastEventOf (lastMaybe ls)
                                    , peSubmitted = submittedIn delta
                                    , peExit = exitNumber status
                                    , peWaited = Nothing
                                    , peFilesBefore = []
                                    , peFilesAfter = []
                                    , peSeedProbe = Nothing
                                    }
                            )
                    }
        finish = finishFrom before
        -- the transaction a killed command left accepted, once on the chain
        awaitKilled = do
            ls <- journalLines' journal
            mapM_ (awaitOnChain env) (lastMaybe (submittedIn (drop before ls)))
        plain args = do
            (status, printed, file) <- singular env r label args
            finish status printed file id
        socketTo s args = case break (== "--node-socket") args of
            (pre, flag : _ : post) -> pre <> [flag, s] <> post
            _ -> args
        timeoutTo s args = case break (== "--confirm-timeout") args of
            (pre, flag : _ : post) -> pre <> [flag, s] <> post
            _ -> args
    case p of
        WhileLocked -> do
            args <- commandArgs env Insert target key r
            bracket
                ( openFd
                    (dir </> ".lock")
                    ReadWrite
                    defaultFileFlags{creat = Just 0o644}
                )
                closeFd
                ( \fd -> do
                    setLock fd (WriteLock, AbsoluteSeek, 0, 0)
                    plain args
                )
        SelectorChanged -> do
            args <- commandArgs env Insert target key r
            let config = dir </> "registry.json"
            saved <- BS.readFile config
            changed <- case Aeson.decodeStrict saved of
                Just (Object m) ->
                    pure (Object (KeyMap.insert "confApplication" (String "open.open") m))
                _ -> fail "the saved configuration is not a JSON object"
            (BL.writeFile config (Aeson.encode changed) >> plain args)
                `finally` BS.writeFile config saved
        WithoutProof -> do
            args <- commandArgs env Inspect target key r
            let mirror = dir </> "registry.mirror.json"
                aside = backendDir env target </> "registry.mirror.json.aside"
            renameFile mirror aside
            plain args `finally` renameFile aside mirror
        WithoutNode -> do
            args <- commandArgs env Inspect target key r
            plain (socketTo (work </> "absent.sock") args)
        TerminateKilled -> do
            args <- commandArgs env Terminate target key r
            (status, printed, file) <- killedAt env r label hold "fold" args
            awaitKilled
            finish status printed file id
        UpdateWhileUnresolved -> commandArgs env (Update 3) target key r >>= plain
        CreateKilled -> do
            seed <-
                previewSeed env r "preview" (optWalletKey o) dir Nothing
            writeFile seedFile seed
            let args = createArgs dir (optWalletKey o) seed
            (status, printed, file) <- killedAt env r label hold "boot" args
            awaitKilled
            finish status printed file id
        CreateAgain -> do
            seed <- readFile seedFile
            plain (createArgs dir (optWalletKey o) seed)
        LateCreate -> do
            let late = optStranger o
            first <-
                previewSeed
                    env
                    r
                    "preview-first"
                    (optWalletKey o)
                    (work </> "probe-first")
                    Nothing
            seedLate <-
                previewSeed env r "preview-late" late (work </> "probe-late") Nothing
            when (first == seedLate) $ fail "the two creates name the same seed"
            let lateArgs = createArgs dir late seedLate
                firstArgs = createArgs dir (optWalletKey o) first
            (late', out) <-
                spawnSingular
                    env
                    r
                    label
                    [("SINGULAR_HARNESS_HOLD_BEFORE_LOCK", hold)]
                    lateArgs
            awaitFile (hold <> ".waiting") late'
                >>= flip unless (fail "the late create never reached its hold point")
            (firstStatus, firstPrinted, _) <-
                singular env r "create-first" firstArgs
            unless
                ( firstStatus == ExitSuccess
                    && printedField "outcome" firstPrinted == Just (String "success")
                )
                $ fail "the first create did not complete"
            copies <-
                snapshot (envEvidence env </> printf "step-%03d-before" (rcStep r))
            _ <-
                previewSeed
                    env
                    r
                    "seed-late-held"
                    late
                    (work </> "probe-held")
                    (Just seedLate)
            lockedBefore <- journalLines journal
            writeFile hold ""
            status <- waitForProcess late'
            printed <-
                Aeson.decodeStrict <$> BS.readFile (envEvidence env </> out)
            filesAfter <- digests dir
            (_, _, probe) <-
                singular
                    env
                    r
                    "seed-late-after"
                    [ "registry"
                    , "create"
                    , "--preview"
                    , "--registry"
                    , work </> "probe-after"
                    , "--blueprint"
                    , optBlueprint o
                    , "--node-socket"
                    , optSocket o
                    , "--network-magic"
                    , show (optMagic o)
                    , "--wallet-skey"
                    , late
                    , "--seed"
                    , seedLate
                    ]
            finishFrom lockedBefore status printed (T.pack ("evidence" </> out)) $ \pe ->
                pe
                    { peFilesBefore = copies
                    , peFilesAfter = filesAfter
                    , peSeedProbe = Just probe
                    }
        NodeLost -> do
            args <- timeoutTo "30" <$> commandArgs env (Update 4) target key r
            (victim, out) <-
                spawnSingular
                    env
                    r
                    label
                    [ ("SINGULAR_HARNESS_HOLD_AFTER_SUBMIT", hold)
                    , ("SINGULAR_HARNESS_HOLD_STEP", "update")
                    ]
                    args
            awaitFile (hold <> ".waiting") victim
                >>= flip unless (fail "the update never reached an accepted submission")
            stopNode env
            released <- getCurrentTime
            writeFile hold ""
            status <- waitForProcess victim
            ended <- getCurrentTime
            printed <-
                Aeson.decodeStrict <$> BS.readFile (envEvidence env </> out)
            finish status printed (T.pack ("evidence" </> out)) $ \pe ->
                pe{peWaited = Just (round (diffUTCTime ended released))}
  where
    createArgs registry skey seed =
        let o = envOptions env
        in  [ "registry"
            , "create"
            , "--seed"
            , seed
            , "--registry"
            , registry
            , "--blueprint"
            , optBlueprint o
            , "--node-socket"
            , optSocket o
            , "--network-magic"
            , show (optMagic o)
            , "--wallet-skey"
            , skey
            , "--confirm-timeout"
            , "120"
            ]
    snapshot copyDir = do
        createDirectoryIfMissing True copyDir
        forM_ savedFiles $ \f ->
            copyFile (targetDir env target </> f) (copyDir </> f)
        digests copyDir
    digests d =
        mapM
            ( \f -> do
                bytes <- BS.readFile (d </> f)
                pure
                    ( T.pack (makeRelative (optWork (envOptions env)) (d </> f))
                    , hex (sha256 bytes)
                    )
            )
            savedFiles
    savedFiles =
        [ "registry.json"
        , "registry.pending.json"
        , "state.json"
        , "registry.mirror.json"
        , "journal.jsonl"
        ]

{- | Run a command held by the harness right after the node accepted the
named step, kill it there, and wait until that transaction is on the chain.
-}
killedAt
    :: Env
    -> Receipt
    -> String
    -> FilePath
    -> Text
    -> [String]
    -> IO (ExitCode, Maybe Value, Text)
killedAt env r label hold step args = do
    (victim, out) <-
        spawnSingular
            env
            r
            label
            [ ("SINGULAR_HARNESS_HOLD_AFTER_SUBMIT", hold)
            , ("SINGULAR_HARNESS_HOLD_STEP", T.unpack step)
            ]
            args
    reached <- awaitFile (hold <> ".waiting") victim
    unless reached $ do
        terminateProcess victim
        fail ("the command never reached its accepted " <> T.unpack step)
    getPid victim >>= mapM_ (signalProcess sigKILL)
    status <- waitForProcess victim
    printed <-
        Aeson.decodeStrict <$> BS.readFile (envEvidence env </> out)
    pure (status, printed, T.pack ("evidence" </> out))

{- | Start one @singular@ process with extra environment, its standard output
kept as the printed receipt and its standard error beside it; the printed
file is named relative to the evidence directory.
-}
spawnSingular
    :: Env
    -> Receipt
    -> String
    -> [(String, String)]
    -> [String]
    -> IO (ProcessHandle, FilePath)
spawnSingular env r label extra args = do
    inherited <- getEnvironment
    let base = printf "step-%03d-%s" (rcStep r) label
        out = base <> ".json"
    hOut <- openFile (envEvidence env </> out) WriteMode
    hErr <- openFile (envEvidence env </> base <> ".err") WriteMode
    (_, _, _, ph) <-
        createProcess
            (proc (optSingular (envOptions env)) args)
                { env =
                    Just (extra <> filter ((`notElem` map fst extra) . fst) inherited)
                , std_out = UseHandle hOut
                , std_err = UseHandle hErr
                }
    pure (ph, out)

-- | Wait up to two minutes for a file, while the process lives.
awaitFile :: FilePath -> ProcessHandle -> IO Bool
awaitFile path ph = go (1200 :: Int)
  where
    go 0 = pure False
    go n = do
        there <- doesFileExist path
        alive <- isNothing <$> getProcessExitCode ph
        if there
            then pure True
            else
                if alive
                    then threadDelay 100_000 >> go (n - 1)
                    else pure False

{- | Stop this run's development node: the one node whose configuration
lives under the run's own directory, and wait for its socket to go.
-}
stopNode :: Env -> IO ()
stopNode env = do
    let o = envOptions env
    void $
        readProcessWithExitCode
            "pkill"
            ["-f", "cardano-node run --config " <> optWork o <> "/"]
            ""
    let wait (0 :: Int) = pure ()
        wait n = do
            there <- doesPathExist (optSocket o)
            when there (threadDelay 100_000 >> wait (n - 1))
    wait 100

-- | The exit status as a number; the negated signal for a killed process.
exitNumber :: ExitCode -> Int
exitNumber status = case status of
    ExitSuccess -> 0
    ExitFailure n -> n

{- | Wait, up to two minutes, until the wallet holds an output of the
transaction: a killed command's accepted submission, on the chain.
-}
awaitOnChain :: Env -> Text -> IO ()
awaitOnChain env txid = withNode env $ \sess wallet -> do
    let go (0 :: Int) = pure ()
        go n = do
            utxos <- Cage.queryUTxOs (nsProvider sess) (walletAddr wallet)
            unless
                (any ((== txid) . T.takeWhile (/= '#') . renderOutRef . fst) utxos)
                (threadDelay 200_000 >> go (n - 1))
    go 600

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

{- | A change a control makes to the fold the registry's duties describe.
| Which pending requests a fold folds.
-}
data Selection
    = -- | The one request for this key
      ForKey String
    | -- | The only request pending, whatever its key
      OnlyPending
    | -- | Every request pending, in input order
      EveryPending

data FoldTweak
    = -- | The fold exactly as the duties describe it
      AsOwed
    | -- | The one ada-only output paying the controller holds this much less
      PayLess Integer
    | -- | The fold also spends this key's live holding with @Release@
      AlsoRelease String

{- | Fold the one request pending for @key@ (or, when none is named, the
only request pending), with the registry's duties and the application's
context, building it without local evaluation. Proofs come from a copy of
a saved mirror whose root is the chain's: the backend's own, once one of
its folds was accepted, else the command's.
-}
foldUnevaluated :: Env -> Target -> String -> Receipt -> IO Receipt
foldUnevaluated env target key = foldWith env target (ForKey key) AsOwed False

{- | The same, folded (funded, signed for its fee and paid its change) by
the story's wallet, or by the stranger when asked: a fold is
permissionless, and a folder other than the controller keeps the change
off the controller's key, where the application sums what it is paid.
-}
foldWith
    :: Env
    -> Target
    -> Selection
    -> FoldTweak
    -> Bool
    -> Receipt
    -> IO Receipt
foldWith env target selection tweak byStranger r = do
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
        let selects q = case selection of
                ForKey k -> requestKey q == keyBytes k
                _ -> True
            requests =
                sortOn
                    (fst . fst)
                    [ (u, q)
                    | u@(_, o) <- pending
                    , Just (RequestDatum q) <- [extractCageDatum o]
                    , selects q
                    ]
        chosen <- case (selection, requests) of
            (EveryPending, _ : _) -> pure requests
            (EveryPending, []) -> fail "no request is pending for the fold"
            (_, [one]) -> pure [one]
            (_, us) ->
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
        let envelopes =
                [ envelopeFor reg (addrKeyHashBytes home) (BC.unpack (requestKey q))
                | (_, q) <- chosen
                ]
        ctx0 <- registryContextFor cfg (regCodes reg) prov (attRefUtxos att)
        ctx <-
            either
                fail
                pure
                (withApplication (applied reg) Nothing envelopes live ctx0)
        pp <- Cage.queryProtocolParams prov
        owedDuties <-
            either
                fail
                pure
                ( registryDuties
                    cfg
                    pp
                    oldState
                    ctx
                    (map fst chosen)
                    (map (const True) chosen)
                )
        unless (null (rdInputs owedDuties)) $
            fail "the fold's duties need ordinary inputs; this backend folds none"
        duties <- case tweak of
            AsOwed -> pure owedDuties
            PayLess less ->
                -- What the fold owes the controller, as the statement sums
                -- it: for each termination, the request's deposit back to its
                -- owner and the released holding's protected deposit. The
                -- controller is paid exactly that less @less@, all told: its
                -- largest output is lowered, any smaller one (an approval
                -- returned beside it) kept, and the rest is the folder's
                -- change.
                let owed =
                        sum
                            [ requestDeposit q + storyDeposit
                            | (_, q) <- chosen
                            , requestEdge q == edgeUpdateTerminal
                            ]
                    coin o = let Coin c = o ^. coinTxOutL in c
                in  case sortOn
                        (Down . coin)
                        [o | o <- rdOutputs owedDuties, o ^. addrTxOutL == home] of
                        paid : others
                            | owed > 0
                            , lowered <- owed - less - sum (map coin others)
                            , lowered > 0 ->
                                pure
                                    owedDuties
                                        { rdOutputs =
                                            [ if o == paid then o & coinTxOutL .~ Coin lowered else o
                                            | o <- rdOutputs owedDuties
                                            ]
                                        }
                        _ ->
                            fail
                                "the fold owes the controller nothing it can be paid short of"
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
                    , cfaReqUtxos = map fst chosen
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
            withTrie tm tok $ \t ->
                mapM_ (\(_, q) -> walkEdge t (requestKey q) (requestEdge q)) chosen
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
    ReleaseInOtherFold -> foldWith env target OnlyPending (AlsoRelease key) False r
    FoldPaysShort -> foldWith env target (ForKey key) (PayLess 1) True r
    FoldPaysInFull -> foldWith env target (ForKey key) AsOwed True r
    FoldTwoReleasesShort -> foldWith env target EveryPending (PayLess 1) True r
    FoldTwoReleasesOneFloor ->
        foldWith env target EveryPending (PayLess storyDeposit) True r
    FoldTwoReleasesInFull -> foldWith env target EveryPending AsOwed True r
    FoldMixedShort -> foldWith env target EveryPending (PayLess 1) True r
    FoldMixedInFull -> foldWith env target EveryPending AsOwed True r
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
        -- An asset of another policy the wallet holds: the approval the
        -- application minted at a booking, returned by its fold.
        otherAsset <-
            if c == UpdateAddedAsset
                then case [ u
                          | u@(_, out) <- wallets
                          , MaryValue _ (MultiAsset m) <- [out ^. valueTxOutL]
                          , not (Map.null m)
                          , SNothing <- [out ^. referenceScriptTxOutL]
                          ] of
                    (u : _) -> pure (Just u)
                    [] -> fail "the wallet holds no asset of another policy"
                else pure Nothing
        let extra = case otherAsset of
                Just (_, out)
                    | MaryValue _ (MultiAsset m) <- out ^. valueTxOutL
                    , ((policy, names) : _) <- Map.toList m
                    , ((name, _) : _) <- Map.toList names ->
                        MultiAsset (Map.singleton policy (Map.singleton name 1))
                _ -> mempty
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
                UpdateAddedAsset ->
                    -- The extra asset raises the output's minimum; it is met
                    -- (more than the deposit is allowed), so the asset alone
                    -- differs from an honest continuation.
                    ( let carrying = next & valueTxOutL .~ MaryValue (Coin held) (tokens <> extra)
                      in  [carrying & coinTxOutL .~ Coin (max held (minFor carrying))]
                    , updateRedeemer
                    , mine
                    )
                EarlyWithdrawal ->
                    ([mkBasicTxOut home (hOut ^. valueTxOutL)], releaseRedeemer, mine)
                other -> error ("not a shape against a holding: " <> show other)
            prog :: Tx.TxBuild NoQuery Void ()
            prog = do
                _ <- Tx.spendScript hIn redeemer
                mapM_ (Tx.spend . fst) otherAsset
                mapM_ Tx.output outputs
                Tx.requireSignature (addrWitnessKeyHash signer)
                unless (c == UpdateWithoutScript) $ Tx.reference (fst appRef)
                Tx.collateral (fst feeUtxo)
            skipEval tx =
                let Redeemers rdmrs = tx ^. witsTxL . rdmrsTxWitsL
                    units =
                        skipEvalUnits
                            (pp ^. ppMaxTxExUnitsL)
                            (pp ^. ppMaxBlockExUnitsL)
                            (Map.size rdmrs)
                in  pure (Map.map (const (Right units)) rdmrs)
        built <-
            Tx.build
                (Tx.mkPParamsBound pp)
                (Tx.InterpretIO (const (pure undefined)))
                skipEval
                ([feeUtxo, holding] <> maybe [] pure otherAsset)
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

-- | The protected deposit of every envelope this story inserts.
storyDeposit :: Integer
storyDeposit = 2_000_000

-- | How many lines a registry's journal has; none when it does not exist yet.
journalLines :: FilePath -> IO Int
journalLines path = length <$> journalLines' path

journalLines' :: FilePath -> IO [BC.ByteString]
journalLines' path = do
    there <- doesFileExist path
    if there then BC.lines <$> BS.readFile path else pure []

{- | The submissions a command journalled: each @prepared@ line's step,
transaction and kept body, the body named relative to the run's directory
and digested as it stands now. Beside them, every output the command read
back without submitting it: an @observed@ line whose transaction it never
prepared.
-}
journalledSubmissions
    :: Env -> IO [BC.ByteString] -> IO ([Submission], [Resolved])
journalledSubmissions env fresh = do
    ls <- fresh
    let work = optWork (envOptions env)
        events =
            [ (event, step, txid, KeyMap.lookup "journalBody" o)
            | l <- ls
            , Just (Object o) <- [Aeson.decodeStrict l]
            , Just (String event) <- [KeyMap.lookup "journalEvent" o]
            , Just (String step) <- [KeyMap.lookup "journalStep" o]
            , Just (String txid) <- [KeyMap.lookup "journalTxId" o]
            ]
        prepared =
            [ (step, txid, body)
            | ("prepared", step, txid, Just (String body)) <- events
            ]
        submittedIds = [txid | (_, txid, _) <- prepared]
        resolved =
            [ Resolved{reStep = step, reTxId = txid}
            | ("observed", step, txid, _) <- events
            , txid `notElem` submittedIds
            ]
    submissions <-
        mapM
            ( \(step, txid, body) -> do
                bytes <- BS.readFile (T.unpack body)
                pure
                    Submission
                        { suStep = step
                        , suTxId = txid
                        , suBodyFile = T.pack (makeRelative work (T.unpack body))
                        , suBodySha256 = hex (sha256 bytes)
                        }
            )
            prepared
    pure (submissions, resolved)
