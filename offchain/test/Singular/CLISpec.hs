{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.CLISpec
Description : Focused rows for the packaged singular registry commands
License     : Apache-2.0

The @singular@ command is one process per registry command over a saved
registry directory. These rows run its effect-free parts over the real
modules: the command line refusals that must happen before any file,
node or key is read; the saved identity's checks against the network,
wallet, seed and pins a later process brings; the journal that keeps a submission a dying process
never saw confirmed; and the local proof of a key's leaf against the
root the ledger holds.

Every compared identity is produced at run time: wallet addresses come
from 'loadWallet' over key files these rows write, roots from the trie
the edges walked, reservations from the builder's own submitted body.
Node, ledger and cross-process behaviour are the archive check's rows,
not these.
-}
module Singular.CLISpec (spec) where

import Control.Concurrent (threadDelay)
import Control.Exception
    ( ErrorCall (..)
    , SomeException
    , displayException
    , fromException
    , toException
    , try
    )
import Control.Monad (forM_, unless)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as BL
import Data.List (isInfixOf, sort)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Lens.Micro ((&), (.~))
import System.Directory (createDirectoryIfMissing, listDirectory)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Process (forkProcess, getProcessStatus)
import System.Posix.Signals (sigKILL, signalProcess)
import Test.Hspec

import Data.Aeson qualified as Aeson

import Cardano.Ledger.Address (Addr (..))
import Cardano.Ledger.Api.Tx.Out
    ( mkBasicTxOut
    , referenceScriptTxOutL
    )
import Cardano.Ledger.BaseTypes (Network (..), StrictMaybe (..))
import Cardano.Ledger.Credential
    ( Credential (..)
    , StakeReference (..)
    )
import Cardano.Ledger.Keys (coerceKeyRole)
import Cardano.Ledger.Mary.Value (MaryValue (..))

import MPF.Backend.Pure (MPFInMemoryDB (..))

import Singular.CLI.Command

import Singular.CLI.Proof
import Singular.CLI.Receipt
import Singular.CLI.Recovery
import Singular.CLI.Registry
import Singular.CLI.Session (CommandFailure (..), admitSubmissions)
import Singular.Registry.Deployment
    ( Deployment (..)
    , loadMirror
    , mirrorPathFor
    , parseOutRef
    , renderOutRef
    , saveMirror
    )
import Singular.Registry.Ledger
    ( AssetName (..)
    , Coin (..)
    , Root (..)
    , SlotNo (..)
    , TokenId (..)
    )
import Singular.Registry.Node (Wallet (..), bech32Address, loadWallet)
import Singular.Registry.Node.IndexerView (IndexerViewFailure (..))
import Singular.Registry.Trie (Trie (..), TrieManager (..))
import Singular.Registry.Trie.Pure (provesAbsent, provesMember)
import Singular.Registry.Trie.PureManager (mkPureTrieManagerFrom)
import Singular.Registry.TxBuilder.Internal
    ( addrFromKeyHashBytes
    , leafActive
    , leafTerminal
    , scriptFromBytes
    , walkEdge
    )
import Singular.Registry.Types
    ( edgeInsertActive
    , edgeUpdateTerminal
    )

spec :: Spec
spec = describe "singular registry commands" $ do
    commandLine
    savedIdentity
    journal
    localProof
    recovery
    rollback

-- ---------------------------------------------------------
-- The command line
-- ---------------------------------------------------------

node :: [String]
node = ["--node-socket", "/run/node.socket", "--network-magic", "42"]

wallet :: [String]
wallet = ["--wallet-skey", "/keys/payment.skey"]

reg :: [String]
reg = ["--registry", "/srv/reg", "--blueprint", "/srv/plutus.json"]

commandLine :: Spec
commandLine = describe "the command line" $ do
    it "answers help at the top and under registry" $ do
        parseCommand ["--help"] `shouldBe` Right Help
        parseCommand ["registry", "--help"] `shouldBe` Right Help
        parseCommand [] `shouldBe` Right Help
    it "names the five commands and only them in its usage" $ do
        forM5 ["create", "insert", "update", "terminate", "inspect"] $ \c ->
            usage `shouldSatisfy` isInfixOf ("singular registry " <> c)
        usage `shouldNotSatisfy` isInfixOf "registry delete"
    it "refuses a command it does not support" $
        parseCommand ["registry", "delete"]
            `shouldSatisfy` isLeftWith isUnknown
    it "reads a create with its seed, wallet and node" $
        parseCommand
            ( ["registry", "create", "--seed", seedText]
                <> reg
                <> node
                <> wallet
            )
            `shouldBe` Right
                ( Create
                    CreateArgs
                        { createRegistry = "/srv/reg"
                        , createBlueprint = "/srv/plutus.json"
                        , createMode = Submit writeSettings
                        , createSeed = Just seedText
                        , createPreview = False
                        , createReceipt = Nothing
                        }
                )
    it "reads an insert at a hex key with its envelope" $
        parseCommand
            ( ["registry", "insert", "--key", "6b6579", "--envelope", "/e.json"]
                <> reg
                <> node
                <> wallet
            )
            `shouldBe` Right
                ( Insert
                    EntryArgs
                        { entryRegistry = "/srv/reg"
                        , entryBlueprint = "/srv/plutus.json"
                        , entryMode = Submit writeSettings
                        , entryKey = Key "key"
                        , entryDocument = Just "/e.json"
                        , entryFund = Nothing
                        , entryMaxOutlay = Nothing
                        , entryReceipt = Nothing
                        }
                )
    it "refuses an insert without its envelope" $
        parseCommand
            (["registry", "insert", "--key", "6b6579"] <> reg <> node <> wallet)
            `shouldSatisfy` isLeftWith isMissing
    it "reads an update with its payload, and refuses one without" $ do
        parseCommand
            ( ["registry", "update", "--key", "6b6579", "--payload", "/p.json"]
                <> reg
                <> node
                <> wallet
            )
            `shouldSatisfy` \case
                Right (Update e) -> entryDocument e == Just "/p.json"
                _ -> False
        parseCommand
            (["registry", "update", "--key", "6b6579"] <> reg <> node <> wallet)
            `shouldSatisfy` isLeftWith isMissing
    it "refuses a key that is not hex" $ do
        parseCommand
            (["registry", "insert", "--key", "zz"] <> reg <> node <> wallet)
            `shouldSatisfy` isLeftWith isMalformed
        parseCommand
            (["registry", "terminate", "--key", "abc"] <> reg <> node <> wallet)
            `shouldSatisfy` isLeftWith isMalformed
    it "accepts a key of exactly 32 bytes and refuses 33" $ do
        let hexOf n = replicate (2 * n) 'a'
        parseCommand
            (["registry", "inspect", "--key", hexOf maxKeyBytes] <> reg <> node)
            `shouldSatisfy` either (const False) (const True)
        parseCommand
            ( ["registry", "inspect", "--key", hexOf (maxKeyBytes + 1)]
                <> reg
                <> node
            )
            `shouldBe` Left (KeyOversized (maxKeyBytes + 1))
    it "refuses a signing key on inspect" $
        parseCommand
            (["registry", "inspect", "--key", "6b6579"] <> reg <> node <> wallet)
            `shouldBe` Left SigningKeyNotAccepted
    it "refuses a write with a partial node and wallet setting" $
        parseCommand
            ( ["registry", "insert", "--key", "6b6579"]
                <> reg
                <> ["--node-socket", "/run/node.socket"]
            )
            `shouldSatisfy` isLeftWith (unsafeMentions "partially configured")
    it
        "reads a confirmation timeout on a write and refuses one that is not seconds"
        $ do
            let insert extra =
                    parseCommand
                        ( ["registry", "insert", "--key", "6b6579", "--envelope", "/e.json"]
                            <> reg
                            <> node
                            <> wallet
                            <> extra
                        )
            fmap
                ( \case
                    Insert EntryArgs{entryMode = Submit w} -> writeConfirmTimeout w
                    _ -> Nothing
                )
                (insert ["--confirm-timeout", "0"])
                `shouldBe` Right (Just 0)
            insert ["--confirm-timeout", "soon"]
                `shouldBe` Left (BadValue "--confirm-timeout" "is not a whole number of seconds")
    preview
    it "refuses a write against mainnet" $
        parseCommand
            ( ["registry", "insert", "--key", "6b6579"]
                <> reg
                <> ["--node-socket", "/s", "--network-magic", "764_824_073"]
                <> wallet
            )
            `shouldSatisfy` isLeftWith (unsafeMentions "764_824_073")
    it "refuses a write with no node at all rather than spawning one" $
        parseCommand (["registry", "insert", "--key", "6b6579"] <> reg)
            `shouldSatisfy` isLeftWith isUnsafe
    it "names a missing registry directory" $
        parseCommand
            (["registry", "inspect", "--key", "6b6579", "--blueprint", "b"] <> node)
            `shouldBe` Left (MissingFlag "--registry")
    it
        "reads every command under the indexer backend as it reads it under \
        \the default (#324)"
        $ forM5 commands
        $ \line -> do
            parseCommand line `shouldSatisfy` either (const False) (const True)
            parseCommand (line <> ["--backend", "indexer"])
                `shouldBe` parseCommand line
    it
        "refuses a backend it does not name on every command, before \
        \anything runs (#324)"
        $ forM5 commands
        $ \line ->
            parseCommand (line <> ["--backend", "nodes"])
                `shouldBe` Left
                    (BadValue "--backend" "names node or indexer, not nodes")
  where
    commands =
        [ ["registry", "create", "--seed", seedText] <> reg <> node <> wallet
        , ["registry", "insert", "--key", "6b6579", "--envelope", "/e.json"]
            <> reg
            <> node
            <> wallet
        , ["registry", "update", "--key", "6b6579", "--payload", "/p.json"]
            <> reg
            <> node
            <> wallet
        , ["registry", "terminate", "--key", "6b6579"] <> reg <> node <> wallet
        , ["registry", "inspect", "--key", "6b6579"] <> reg <> node
        ]
    forM5 xs f = mapM_ f xs
    preview = previewRows
    writeSettings =
        WriteSettings
            { writeNode = NodeSettings "/run/node.socket" 42
            , writeWalletKey = "/keys/payment.skey"
            , writeConfirmTimeout = Nothing
            }
    isUnknown = \case UnknownCommand _ -> True; _ -> False
    isMalformed = \case KeyMalformed _ -> True; _ -> False
    isMissing = \case MissingFlag _ -> True; _ -> False
    isUnsafe = \case UnsafeSettings _ -> True; _ -> False
    unsafeMentions s = \case
        UnsafeSettings m -> s `isInfixOf` m
        _ -> False

isLeftWith :: (e -> Bool) -> Either e a -> Bool
isLeftWith p = either p (const False)

seedText :: String
seedText = replicate 64 'b' <> "#1"

-- ---------------------------------------------------------
-- The saved identity
-- ---------------------------------------------------------

keyFile :: FilePath -> Char -> IO Wallet
keyFile dir c = do
    let path = dir </> (c : ".skey")
    BS.writeFile path (B16.encode (BC.replicate 32 c))
    loadWallet 42 path

pins :: Pins
pins = Pins "aa" "bb" "cc" "dd" "ee"

deployment :: Deployment
deployment =
    Deployment
        { depRelease = "test"
        , depLeanRevision = "test"
        , depNetworkMagic = 42
        , depSeedOutRef = T.pack seedText
        , depCageToken = "00"
        , depStatePolicy = "aa"
        , depRequestHash = "ff"
        , depApplicationHash = "bb"
        , depRepresentativePolicy = "dd"
        , depProcessTime = 30_000
        , depRetractTime = 30_000
        , depTip = 1_000_000
        , depReferenceScripts = []
        , depBootstrapTxs = []
        }

savedIdentity :: Spec
savedIdentity = describe "the saved identity" $ do
    it "records the booting wallet's public address and never its key" $
        withTempDir $ \dir -> do
            w <- keyFile dir 'k'
            let conf = mkRegistryConfig 42 (walletAddr w) pins deployment
            writeConfig dir conf
            back <- readConfig dir
            back `shouldBe` conf
            raw <- BS.readFile (configPath dir)
            BS.isInfixOf (BC.replicate 32 'k') raw `shouldBe` False
            BS.isInfixOf "6b6b6b6b6b6b6b6b" raw `shouldBe` False
            confWalletAddress conf `shouldNotBe` ""
    it "refuses another network" $ withTempDir $ \dir -> do
        w <- keyFile dir 'k'
        let conf = mkRegistryConfig 42 (walletAddr w) pins deployment
        checkNetwork conf 42 `shouldBe` Right ()
        checkNetwork conf 1 `shouldBe` Left (NetworkMismatch 42 1)
    it "refuses a wallet other than the one it was booted from" $
        withTempDir $ \dir -> do
            w <- keyFile dir 'k'
            other <- keyFile dir 'o'
            let conf = mkRegistryConfig 42 (walletAddr w) pins deployment
            checkWallet conf (walletAddr w) `shouldBe` Right ()
            checkWallet conf (walletAddr other)
                `shouldSatisfy` isLeftWith isWallet
    it "refuses a blueprint whose pins differ, naming the pin" $
        withTempDir $ \dir -> do
            w <- keyFile dir 'k'
            let conf = mkRegistryConfig 42 (walletAddr w) pins deployment
            checkPins conf pins `shouldBe` Right ()
            checkPins conf pins{pinTerminal = "e0"}
                `shouldBe` Left (PinMismatch "terminal" "ee" "e0")
            checkPins conf pins{pinApplication = "b0"}
                `shouldBe` Left (PinMismatch "application" "bb" "b0")
    it
        "refuses a seed the wallet does not hold, one that is not ada-only, or one with no funding beside it"
        $ do
            seed <- either fail pure (parseOutRef (T.pack seedText))
            other <-
                either fail pure (parseOutRef (T.pack (replicate 64 'c' <> "#0")))
            withTempDir $ \dir -> do
                w <- keyFile dir 'k'
                let plain = mkBasicTxOut (walletAddr w) (MaryValue (Coin 5_000_000) mempty)
                    withScript =
                        plain & referenceScriptTxOutL .~ SJust (scriptFromBytes "s" "\1")
                fmap fst (checkSeed seed [(other, plain), (seed, plain)])
                    `shouldBe` Right seed
                checkSeed seed [(other, plain)]
                    `shouldSatisfy` isLeftWith isNotInWallet
                checkSeed seed [(seed, withScript)]
                    `shouldSatisfy` isLeftWith isNotAdaOnly
                -- the seed stays unspent while the first publication is paid from
                -- another ada-only output: a wallet with only the seed, or whose
                -- other outputs hold a script, cannot create
                checkSeed seed [(seed, plain)]
                    `shouldSatisfy` isLeftWith isNoFunding
                checkSeed seed [(seed, plain), (other, withScript)]
                    `shouldSatisfy` isLeftWith isNoFunding
                -- an identity needs only the seed held: a preview of such a
                -- wallet computes it and reports the refusal above
                fmap fst (seedHeld seed [(seed, plain)]) `shouldBe` Right seed
                seedHeld seed [(other, plain)]
                    `shouldSatisfy` isLeftWith isNotInWallet
                seedHeld seed [(seed, withScript), (other, plain)]
                    `shouldSatisfy` isLeftWith isNotAdaOnly
    it
        "previews a one-output wallet's identity, naming the refusal its create meets, and refuses that create"
        $ do
            seed <- either fail pure (parseOutRef (T.pack seedText))
            other <-
                either fail pure (parseOutRef (T.pack (replicate 64 'c' <> "#0")))
            withTempDir $ \dir -> do
                w <- keyFile dir 'k'
                let plain = mkBasicTxOut (walletAddr w) (MaryValue (Coin 5_000_000) mempty)
                    refusal fields = Prelude.lookup "createRefusal" fields
                -- the preview's accepting control: the seed alone is enough
                case seedChecks False seed [(seed, plain)] of
                    Right fields -> case refusal fields of
                        Just (Aeson.String why) ->
                            T.unpack why
                                `shouldSatisfy` ( \s ->
                                                    seedText `isInfixOf` s
                                                        && "only ada-only output" `isInfixOf` s
                                                )
                        other' -> expectationFailure ("createRefusal is " <> show other')
                    Left e -> expectationFailure ("the preview refused: " <> show e)
                -- with funding beside the seed it reports no refusal
                fmap refusal (seedChecks False seed [(seed, plain), (other, plain)])
                    `shouldBe` Right (Just Aeson.Null)
                -- the create itself refuses the one-output wallet, and adds nothing
                -- when it can proceed
                seedChecks True seed [(seed, plain)]
                    `shouldSatisfy` isLeftWith isNoFunding
                seedChecks True seed [(seed, plain), (other, plain)]
                    `shouldBe` Right []
                -- a preview still refuses a seed the wallet does not hold
                seedChecks False seed [(other, plain)]
                    `shouldSatisfy` isLeftWith isNotInWallet
    it
        "refuses to create over a directory that already holds a registry or a journal"
        $ withTempDir
        $ \dir -> do
            refuseExisting (dir </> "fresh") `shouldReturn` Right ()
            let used = dir </> "used"
            createDirectoryIfMissing True used
            BS.writeFile (journalPath used) ""
            refuseExisting used `shouldReturn` Left (RegistryExists used)
    it "keeps the proof mirror's root across a save and a load" $
        withTempDir $ \dir -> do
            (db, root) <- walked [(key, edgeInsertActive)]
            let manifest = configPath dir
                tid = TokenId (AssetName "tok")
            saveMirror manifest (Map.singleton tid db)
            loaded <- loadMirror manifest
            case Map.lookup tid loaded of
                Nothing -> expectationFailure "the mirror lost the registry"
                Just back -> rootOfDb back `shouldReturn` root
  where
    isWallet = \case WalletMismatch _ _ -> True; _ -> False
    isNotInWallet = \case SeedNotInWallet _ -> True; _ -> False
    isNotAdaOnly = \case SeedNotAdaOnly _ -> True; _ -> False
    isNoFunding = \case NoFundingBesideSeed _ -> True; _ -> False

-- ---------------------------------------------------------
-- The journal
-- ---------------------------------------------------------

journal :: Spec
journal = describe "the journal of a write" $ do
    it "keeps every appended line, in order, across a reread" $
        withTempDir $ \dir -> do
            let entries =
                    [submitted "boot" "t1", confirmed "boot" "t1", submitted "book" "t2"]
            mapM_ (appendJournal dir) entries
            readJournal dir `shouldReturn` entries
    it "names the submission a process never saw confirmed" $ do
        unresolved [submitted "boot" "t1"]
            `shouldBe` Just (submitted "boot" "t1")
        unresolved [submitted "boot" "t1", confirmed "boot" "t1"]
            `shouldBe` Nothing
        unresolved
            [submitted "boot" "t1", confirmed "boot" "t1", submitted "fold" "t3"]
            `shouldBe` Just (submitted "fold" "t3")
        unresolved [] `shouldBe` Nothing
    it "gives every outcome class its own name and exit status" $ do
        let classes = [minBound .. maxBound] :: [OutcomeClass]
        length (Set.fromList (map outcomeName classes))
            `shouldBe` length classes
        length (Set.fromList (map (show . exitCodeOf) classes))
            `shouldBe` length classes
        exitCodeOf Success `shouldBe` ExitSuccess
        Aeson.encode (map outcomeName classes) `shouldSatisfy` (not . BL.null)
    it
        "a command that sent a transaction never ends as a client refusal: \
        \an unclassified or refusing failure after a send ends partial, \
        \naming every transaction sent and keeping its fields (#324)"
        $ do
            let refusal =
                    ErrorCall
                        ( displayException
                            (IndexerRestoring (Just (SlotNo 5113)) (Just (SlotNo 7019)))
                        )
                held = ("pendingRequest", Aeson.toJSON ("ab#0" :: T.Text))
                failures =
                    [ (toException refusal, displayException refusal, [])
                    ,
                        ( toException (CommandFailure ClientRefusal "refused here" [held])
                        , "refused here"
                        , [held]
                        )
                    ]
                sends =
                    [ ([submitted "book" "t2"], ["t2"])
                    , ([phase "fold" "t3" "submit-unknown"], ["t3"])
                    ,
                        (
                            [ submitted "boot" "t1"
                            , confirmed "boot" "t1"
                            , submitted "book" "t2"
                            , phase "fold" "t3" "prepared"
                            , phase "fold" "t3" "submit-unknown"
                            ]
                        , ["t1", "t2", "t3"]
                        )
                    ]
            forM_ sends $ \(since, sent) ->
                forM_ failures $ \(e, why, fields) ->
                    case fromException (admitSubmissions since e) of
                        Just (CommandFailure c reason kept) -> do
                            c `shouldBe` Partial
                            reason `shouldSatisfy` isInfixOf why
                            mapM_ (\t -> reason `shouldSatisfy` isInfixOf (T.unpack t)) sent
                            Prelude.lookup "submitted" kept `shouldBe` Just (Aeson.toJSON sent)
                            filter ((/= "submitted") . fst) kept `shouldBe` fields
                        Nothing -> expectationFailure ("kept unclassified: " <> show e)
    it
        "a failure after a send that the command classified otherwise keeps \
        \its class (#324)"
        $ forM_ (filter (/= ClientRefusal) [minBound .. maxBound])
        $ \c ->
            case fromException
                ( admitSubmissions
                    [submitted "book" "t2"]
                    (toException (CommandFailure c "why" []))
                ) of
                Just (CommandFailure c' why _) -> (c', why) `shouldBe` (c, "why")
                Nothing -> expectationFailure "lost its class"
    it
        "with nothing sent, no line or only prepared and rejected ones, every \
        \failure is kept (#324)"
        $ forM_
            [[], [phase "fold" "t3" "prepared", phase "fold" "t3" "rejected"]]
        $ \since -> do
            forM_ [minBound .. maxBound] $ \c ->
                case fromException
                    (admitSubmissions since (toException (CommandFailure c "why" []))) of
                    Just (CommandFailure c' why _) -> (c', why) `shouldBe` (c, "why")
                    Nothing -> expectationFailure "lost its class"
            fromException (admitSubmissions since (toException (ErrorCall "x")))
                `shouldBe` Just (ErrorCall "x")
  where
    submitted s t = phase s t "submitted"
    confirmed s t = phase s t "observed"
    phase s t e =
        JournalEntry
            { journalCommand = "insert"
            , journalStep = s
            , journalTxId = t
            , journalEvent = e
            , journalDetail = Nothing
            , journalInputs = Nothing
            , journalBody = Nothing
            , journalBodyHash = Nothing
            , journalNetwork = Nothing
            , journalEra = Nothing
            , journalChainPoint = Nothing
            , journalKey = Nothing
            , journalExpect = Nothing
            , journalEdge = Nothing
            , journalRootBefore = Nothing
            , journalRootAfter = Nothing
            }

-- ---------------------------------------------------------
-- The local proof of a leaf
-- ---------------------------------------------------------

key :: BS.ByteString
key = "update-terminal-demo"

{- | The trie after these edges, and its root, both from the edge walk
the fold builder itself uses.
-}
walked
    :: [(BS.ByteString, Integer)] -> IO (MPFInMemoryDB, BS.ByteString)
walked steps = do
    let tid = TokenId (AssetName "tok")
    (tm, dump) <- mkPureTrieManagerFrom Map.empty
    createTrie tm tid
    Root root <-
        withTrie tm tid $ \t -> do
            mapM_ (uncurry (walkEdge t)) steps
            getRoot t
    dbs <- dump
    case Map.lookup tid dbs of
        Just db -> pure (db, root)
        Nothing -> fail "the trie manager lost the trie"

localProof :: Spec
localProof = describe "a key's leaf proven against the observed root" $ do
    it "is Active after an insertActive, Terminal after an updateTerminal" $ do
        (active, activeRoot) <- walked [(key, edgeInsertActive)]
        authenticatedLeaf active key activeRoot `shouldReturn` Right Active
        (terminal, terminalRoot) <-
            walked [(key, edgeInsertActive), (key, edgeUpdateTerminal)]
        authenticatedLeaf terminal key terminalRoot
            `shouldReturn` Right Terminal
    it "is Unknown for a key the trie never bound, beside one it did" $ do
        (db, root) <-
            walked [(key, edgeInsertActive), ("other", edgeInsertActive)]
        authenticatedLeaf db "never-bound" root `shouldReturn` Right Unknown
        authenticatedLeaf db "other" root `shouldReturn` Right Active
    it "refuses when the ledger's root is not the saved trie's" $ do
        (active, activeRoot) <- walked [(key, edgeInsertActive)]
        (_, terminalRoot) <-
            walked [(key, edgeInsertActive), (key, edgeUpdateTerminal)]
        authenticatedLeaf active key terminalRoot
            `shouldReturn` Left (RootMismatch activeRoot terminalRoot)
    it "reads the authenticated tree, never the auxiliary key index" $ do
        -- The saved mirror carries the tree nodes and, beside them, a
        -- key index the tree does not commit to. Erasing or emptying
        -- the index leaves the root as it was, so it must change no
        -- answer: a bound key stays bound, an unbound one stays unbound.
        (db, root) <-
            walked [(key, edgeInsertActive), ("other", edgeInsertActive)]
        let erased = db{mpfInMemoryKV = Map.empty}
        rootOfDb erased `shouldReturn` root
        authenticatedLeaf erased key root `shouldReturn` Right Active
        authenticatedLeaf erased "other" root `shouldReturn` Right Active
        authenticatedLeaf erased "never-bound" root
            `shouldReturn` Right Unknown
        (terminal, terminalRoot) <-
            walked [(key, edgeInsertActive), (key, edgeUpdateTerminal)]
        authenticatedLeaf terminal{mpfInMemoryKV = Map.empty} key terminalRoot
            `shouldReturn` Right Terminal
    it
        "checks every proof against the root it is given, not the tree's own"
        $ do
            (db, root) <- walked [(key, edgeInsertActive)]
            (_, otherRoot) <-
                walked [(key, edgeInsertActive), (key, edgeUpdateTerminal)]
            provesMember db root key leafActive `shouldBe` True
            provesMember db otherRoot key leafActive `shouldBe` False
            provesMember db root key leafTerminal `shouldBe` False
            provesAbsent db root key `shouldBe` False
            provesAbsent db root "never-bound" `shouldBe` True
            provesAbsent db otherRoot "never-bound" `shouldBe` False
    it "reads the same through a saved mirror whose key index was dropped" $
        withTempDir $ \dir -> do
            (db, root) <- walked [(key, edgeInsertActive)]
            let manifest = configPath dir
                tid = TokenId (AssetName "tok")
            saveMirror manifest (Map.singleton tid db{mpfInMemoryKV = Map.empty})
            loaded <- loadMirror manifest
            case Map.lookup tid loaded of
                Nothing -> expectationFailure "the mirror lost the registry"
                Just back -> authenticatedLeaf back key root `shouldReturn` Right Active
    it "names the four leaves in the model's words" $
        map leafName [minBound .. maxBound]
            `shouldBe` ["unknown", "absent", "active", "terminal"]

-- ---------------------------------------------------------
-- Recovery after an uncertain submission
-- ---------------------------------------------------------

recovery :: Spec
recovery = describe "recovery after an uncertain submission" $ do
    it "reads each transaction's case from its journalled phases" $ do
        let lines' =
                [ line "a" "prepared"
                , line "a" "submitted"
                , line "u" "prepared"
                , line "u" "submit-unknown"
                , line "r" "prepared"
                , line "r" "rejected"
                , line "i" "prepared"
                , line "i" "submitted"
                , line "i" "confirmed"
                , line "o" "prepared"
                , line "o" "submitted"
                , line "o" "confirmed"
                , line "o" "observed"
                , line "t" "prepared"
                , line "t" "submitted"
                , line "t" "unconfirmed"
                , line "k" "prepared"
                , line "x" "prepared"
                , line "x" "submit-unknown"
                , line "x" "confirmed"
                ]
        map
            (submissionCase lines')
            ["a", "u", "r", "i", "o", "t", "k", "x", "none"]
            `shouldBe` [ Just CaseAcknowledged
                       , Just CaseUnknown
                       , Just CaseRejected
                       , Just CaseIncluded
                       , Just CaseIncluded
                       , Just CaseTimeout
                       , Just CaseUnknown
                       , Just CaseIncluded
                       , Nothing
                       ]
    it
        "applies a journalled fold's edge only from its root before, and only onto the ledger's root"
        $ do
            (_, r0) <- walked [("other", edgeInsertActive)]
            (_, r1) <-
                walked [("other", edgeInsertActive), (key, edgeInsertActive)]
            (_, r2) <-
                walked
                    [ ("other", edgeInsertActive)
                    , (key, edgeInsertActive)
                    , ("third", edgeInsertActive)
                    ]
            let fold = foldLine (hexT r0) (hexT r1)
            mirrorDecision (hexT r0) (hexT r1) fold `shouldBe` ApplyEdge
            mirrorDecision (hexT r1) (hexT r1) fold `shouldBe` AlreadyApplied
            mirrorDecision (hexT r0) (hexT r2) fold `shouldBe` EdgeStale
            mirrorDecision (hexT r2) (hexT r1) fold `shouldBe` EdgeStale
            mirrorDecision (hexT r0) (hexT r1) (line "b" "prepared")
                `shouldBe` NoEdge
    it
        "never applies an edge twice: once walked, the same line is already applied"
        $ do
            (_, r0) <- walked [("other", edgeInsertActive)]
            (_, r1) <-
                walked [("other", edgeInsertActive), (key, edgeInsertActive)]
            let fold = foldLine (hexT r0) (hexT r1)
                tid = TokenId (AssetName "tok")
            (db0, _) <- walked [("other", edgeInsertActive)]
            (tm, _) <- mkPureTrieManagerFrom (Map.singleton tid db0)
            mirrorDecision (hexT r0) (hexT r1) fold `shouldBe` ApplyEdge
            Root now <-
                withTrie tm tid $ \t -> walkEdge t key edgeInsertActive >> getRoot t
            now `shouldBe` r1
            mirrorDecision (hexT now) (hexT r1) fold `shouldBe` AlreadyApplied
    it "leaves state.json whole under a writer killed mid-replacement" $
        withTempDir $ \dir -> do
            let commitment r c =
                    LocalState
                        { localVersion = 1
                        , localToken = "746f6b"
                        , localRoot = r
                        , localLastTx = Just (T.replicate 2_000_000 c)
                        , localLastSlot = Nothing
                        }
                old = commitment "aa" "a"
                new = commitment "bb" "b"
            writeLocalState dir old
            killedWriter
                40
                (\i -> writeLocalState dir (if even i then new else old))
                $ do
                    back <- try (readLocalState dir)
                    case back of
                        Right s
                            | s == old || s == new -> pure ()
                            | otherwise ->
                                expectationFailure "state.json holds a third commitment"
                        Left (e :: SomeException) ->
                            expectationFailure
                                ("state.json is torn: " <> take 160 (show e))
    it "leaves the mirror whole under a writer killed mid-replacement" $
        withTempDir $ \dir -> do
            let manifest = configPath dir
                tid = TokenId (AssetName "tok")
                keys n =
                    [ (BC.pack ("key-" <> show i), edgeInsertActive) | i <- [1 .. n :: Int]
                    ]
            (small, _) <- walked (keys 300)
            (large, _) <- walked (keys 600)
            saveMirror manifest (Map.singleton tid small)
            oldBytes <- BS.readFile (mirrorFile manifest)
            saveMirror manifest (Map.singleton tid large)
            newBytes <- BS.readFile (mirrorFile manifest)
            killedWriter
                40
                ( \i ->
                    saveMirror
                        manifest
                        (Map.singleton tid (if even i then small else large))
                )
                $ do
                    now <- BS.readFile (mirrorFile manifest)
                    unless (now == oldBytes || now == newBytes) $
                        expectationFailure
                            ( "the mirror is torn: "
                                <> show (BS.length now)
                                <> " bytes, neither the old "
                                <> show (BS.length oldBytes)
                                <> " nor the new "
                                <> show (BS.length newBytes)
                            )
    it "leaves no partial file behind a completed replacement" $
        withTempDir $ \dir -> do
            (db, _) <- walked [(key, edgeInsertActive)]
            saveMirror
                (configPath dir)
                (Map.singleton (TokenId (AssetName "tok")) db)
            writeLocalState
                dir
                (LocalState 1 "746f6b" "aa" Nothing Nothing)
            sort <$> listDirectory dir
                `shouldReturn` ["registry.mirror.json", "state.json"]
  where
    line t e =
        JournalEntry
            { journalCommand = "insert"
            , journalStep = "fold"
            , journalTxId = t
            , journalEvent = e
            , journalDetail = Nothing
            , journalInputs = Nothing
            , journalNetwork = Nothing
            , journalEra = Nothing
            , journalBody = Nothing
            , journalBodyHash = Nothing
            , journalChainPoint = Nothing
            , journalKey = Nothing
            , journalExpect = Nothing
            , journalEdge = Nothing
            , journalRootBefore = Nothing
            , journalRootAfter = Nothing
            }
    foldLine from to =
        (line "f" "prepared")
            { journalKey = Just (hexT key)
            , journalEdge = Just edgeInsertActive
            , journalRootBefore = Just from
            , journalRootAfter = Just to
            }
    mirrorFile = mirrorPathFor

-- ---------------------------------------------------------
-- Rollback and exclusion
-- ---------------------------------------------------------

rollback :: Spec
rollback = describe "a rolled-back inclusion and an excluded transaction" $ do
    it "names the seven cases a submission meets, each distinctly" $
        map caseName [minBound .. maxBound]
            `shouldBe` [ "acknowledged"
                       , "unknown"
                       , "rejected"
                       , "included"
                       , "timeout"
                       , "rolled-back"
                       , "excluded"
                       ]
    it
        "reads a transaction's case from the latest of its journalled phases"
        $ do
            let lines' =
                    phases
                        "b"
                        ["prepared", "submitted", "confirmed", "observed", "rolled-back"]
                        <> phases "c" ["prepared", "submitted", "confirmed", "rolled-back"]
                        <> phases
                            "i"
                            [ "prepared"
                            , "submitted"
                            , "confirmed"
                            , "observed"
                            , "rolled-back"
                            , "confirmed"
                            ]
                        <> phases
                            "o"
                            [ "prepared"
                            , "submitted"
                            , "confirmed"
                            , "observed"
                            , "rolled-back"
                            , "confirmed"
                            , "observed"
                            ]
                        <> phases
                            "x"
                            [ "prepared"
                            , "submitted"
                            , "confirmed"
                            , "observed"
                            , "rolled-back"
                            , "excluded"
                            ]
                        <> phases "u" ["prepared", "submit-unknown", "excluded"]
                        <> phases "t" ["prepared", "submitted", "unconfirmed", "excluded"]
                        <> phases "k" ["prepared", "excluded"]
            map (submissionCase lines') ["b", "c", "i", "o", "x", "u", "t", "k"]
                `shouldBe` [ Just CaseRolledBack
                           , Just CaseRolledBack
                           , Just CaseIncluded
                           , Just CaseIncluded
                           , Just CaseExcluded
                           , Just CaseExcluded
                           , Just CaseExcluded
                           , Just CaseExcluded
                           ]
    it
        "leaves a rolled-back transaction unresolved and settles an excluded one"
        $ do
            let rolled =
                    phases
                        "b"
                        ["prepared", "submitted", "confirmed", "observed", "rolled-back"]
                excluded = rolled <> phases "b" ["excluded"]
            fmap journalEvent (unresolved rolled) `shouldBe` Just "rolled-back"
            unresolved excluded `shouldBe` Nothing
    it
        "reads inclusion from a view's live outputs: output live, an input live, or neither"
        $ do
            let out0 = outRef 'f' 0
                spent = [outRef 'a' 0, outRef 'b' 1, outRef 'c' 2]
                live = Set.fromList
            inclusionOf (live [out0]) out0 spent `shouldBe` OnChain
            inclusionOf
                (live [outRef 'b' 1, outRef 'c' 2, outRef 'e' 0])
                out0
                spent
                `shouldBe` OffChain [outRef 'b' 1, outRef 'c' 2]
            inclusionOf (live [outRef 'e' 0]) out0 spent `shouldBe` Undetermined
            inclusionOf (live []) out0 [] `shouldBe` Undetermined
    it
        "rolls back only an included transaction a live input shows off the chain"
        $ do
            let gone = OffChain [outRef 'a' 0, outRef 'b' 1]
            rollbackEvidence (Just CaseIncluded) gone
                `shouldBe` Just [outRef 'a' 0, outRef 'b' 1]
            rollbackEvidence (Just CaseIncluded) Undetermined `shouldBe` Nothing
            rollbackEvidence (Just CaseIncluded) OnChain `shouldBe` Nothing
            forM_
                [ CaseAcknowledged
                , CaseUnknown
                , CaseRejected
                , CaseTimeout
                , CaseRolledBack
                , CaseExcluded
                ]
                $ \c -> rollbackEvidence (Just c) gone `shouldBe` Nothing
            rollbackEvidence Nothing gone `shouldBe` Nothing
    it
        "excludes an unresolved transaction not on the chain once the tip reaches its upper bound"
        $ do
            let gone = OffChain [outRef 'a' 0]
                bound = Just (SlotNo 500)
            forM_ [CaseAcknowledged, CaseUnknown, CaseTimeout, CaseRolledBack] $ \c -> do
                excludedAt (SlotNo 500) bound (Just c) gone `shouldBe` True
                excludedAt (SlotNo 900) bound (Just c) gone `shouldBe` True
                excludedAt (SlotNo 499) bound (Just c) gone `shouldBe` False
                excludedAt (SlotNo 900) Nothing (Just c) gone `shouldBe` False
                excludedAt (SlotNo 900) bound (Just c) OnChain `shouldBe` False
                excludedAt (SlotNo 900) bound (Just c) Undetermined `shouldBe` False
            forM_ [CaseIncluded, CaseRejected, CaseExcluded] $ \c ->
                excludedAt (SlotNo 900) bound (Just c) gone `shouldBe` False
    it
        "returns the mirror to the root before the earliest rolled-back fold, rebuilt from the folds still on chain"
        $ do
            (_, r0) <- walked []
            (_, r1) <- walked [("k1", edgeInsertActive)]
            (_, r2) <- walked [("k1", edgeInsertActive), ("k2", edgeInsertActive)]
            (_, r3) <-
                walked
                    [ ("k1", edgeInsertActive)
                    , ("k2", edgeInsertActive)
                    , ("k2", edgeUpdateTerminal)
                    ]
            (_, r4) <-
                walked
                    [ ("k1", edgeInsertActive)
                    , ("k2", edgeInsertActive)
                    , ("k4", edgeInsertActive)
                    ]
            let f1 = foldPrepared "f1" "k1" edgeInsertActive r0 r1
                f2 = foldPrepared "f2" "k2" edgeInsertActive r1 r2
                f3 = foldPrepared "f3" "k2" edgeUpdateTerminal r2 r3
                lost = foldPrepared "lost" "k9" edgeInsertActive r1 r1
                settled t = phases t ["submitted", "confirmed", "observed"]
                history =
                    [f1]
                        <> settled "f1"
                        <> [lost]
                        <> phases "lost" ["submit-unknown", "excluded"]
                        <> [f2]
                        <> settled "f2"
                        <> [f3]
                        <> settled "f3"
                        <> phases "book" ["prepared", "submitted", "confirmed", "observed"]
            rewindOf history `shouldBe` Nothing
            rewindOf (history <> phases "book" ["rolled-back"]) `shouldBe` Nothing
            rewindOf (history <> phases "f3" ["rolled-back"])
                `shouldBe` Just (Rewind (hexT r2) [f1, f2])
            rewindOf
                (history <> phases "f3" ["rolled-back"] <> phases "f2" ["rolled-back"])
                `shouldBe` Just (Rewind (hexT r1) [f1])
            rewindOf
                (history <> phases "f3" ["rolled-back", "excluded"])
                `shouldBe` Just (Rewind (hexT r2) [f1, f2])
            -- A fold built after the rollback was built on the returned root:
            -- the rewind is done, until that fold is rolled back in turn.
            let f4 = foldPrepared "f4" "k4" edgeInsertActive r2 r4
                rebuilt =
                    history
                        <> phases "f3" ["rolled-back", "excluded"]
                        <> [f4]
                        <> phases "f4" ["submitted", "confirmed", "observed"]
            rewindOf rebuilt `shouldBe` Nothing
            rewindOf (rebuilt <> phases "f4" ["rolled-back"])
                `shouldBe` Just (Rewind (hexT r2) [f1, f2])
            rewindOf
                ( history
                    <> phases "f3" ["rolled-back"]
                    <> phases "f3" ["confirmed", "observed"]
                )
                `shouldBe` Nothing
    it
        "replays fold edges from the empty trie, each from its journalled root before to its root after"
        $ do
            (_, r0) <- walked []
            (_, r1) <- walked [("k1", edgeInsertActive)]
            (_, r2) <- walked [("k1", edgeInsertActive), ("k2", edgeInsertActive)]
            let f1 = foldPrepared "f1" "k1" edgeInsertActive r0 r1
                f2 = foldPrepared "f2" "k2" edgeInsertActive r1 r2
                replayed folds = do
                    let tid = TokenId (AssetName "tok")
                    (tm, _) <- mkPureTrieManagerFrom Map.empty
                    createTrie tm tid
                    withTrie tm tid (`replayFolds` folds)
            replayed [f1, f2] `shouldReturn` Right r2
            replayed [f1] `shouldReturn` Right r1
            replayed [] `shouldReturn` Right r0
            -- A fold that does not start from the root reached, or does not
            -- end at its journalled root after, stops the replay.
            isLeft <$> replayed [f2] `shouldReturn` True
            isLeft <$> replayed [f1, f2{journalRootAfter = Just (hexT r1)}]
                `shouldReturn` True
  where
    phases t = map (jline t)
    outRef c i =
        either error id $
            parseOutRef (T.pack (replicate 64 c <> "#" <> show (i :: Int)))
    foldPrepared t k edge from to =
        (jline t "prepared")
            { journalKey = Just (hexT k)
            , journalEdge = Just edge
            , journalRootBefore = Just (hexT from)
            , journalRootAfter = Just (hexT to)
            }
    isLeft = either (const True) (const False)

-- | A bare journal line of one phase of one transaction.
jline :: T.Text -> T.Text -> JournalEntry
jline t e =
    JournalEntry
        { journalCommand = "insert"
        , journalStep = "fold"
        , journalTxId = t
        , journalEvent = e
        , journalDetail = Nothing
        , journalInputs = Nothing
        , journalNetwork = Nothing
        , journalEra = Nothing
        , journalBody = Nothing
        , journalBodyHash = Nothing
        , journalChainPoint = Nothing
        , journalKey = Nothing
        , journalExpect = Nothing
        , journalEdge = Nothing
        , journalRootBefore = Nothing
        , journalRootAfter = Nothing
        }

{- | Start a process that rewrites a file over and over, kill it at a
different moment each round, and run the check on what it left.
-}
killedWriter :: Int -> (Int -> IO ()) -> IO () -> IO ()
killedWriter rounds write check = forM_ [1 .. rounds] $ \r -> do
    pid <- forkProcess (mapM_ write [0 ..])
    threadDelay (2_000 + (r * 7_919) `mod` 40_000)
    signalProcess sigKILL pid
    _ <- getProcessStatus True False pid
    check

withTempDir :: (FilePath -> IO a) -> IO a
withTempDir = withSystemTempDirectory "singular-cli-spec"

-- ---------------------------------------------------------
-- The read-only preparation route
-- ---------------------------------------------------------

{- | @--preview@ names the caller by a public address and holds no key: the
parse refuses a key before anything is read, and the address is checked
against the network and for being an enterprise address. The addresses
are produced here from key hashes, never typed.
-}
previewRows :: Spec
previewRows = describe "--preview" $ do
    let payerHash = BS.replicate 28 0x5a
        strangerHash = BS.replicate 28 0x7b
        addrOf = addrFromKeyHashBytes
        textOf net h = bech32Address (addrOf net h)
        baseAddr = case addrOf Testnet payerHash of
            Addr net (KeyHashObj k) _ ->
                Addr net (KeyHashObj k) (StakeRefBase (KeyHashObj (coerceKeyRole k)))
            other -> other
        previewNode magic = ["--node-socket", "/run/node.socket", "--network-magic", magic]
        insertPreview extra =
            parseCommand
                ( [ "registry"
                  , "insert"
                  , "--preview"
                  , "--key"
                  , "6b6579"
                  , "--envelope"
                  , "/e.json"
                  ]
                    <> reg
                    <> extra
                )
    it "reads a preview as a node and a public address, with no key" $
        insertPreview
            (previewNode "1" <> ["--wallet-address", textOf Testnet payerHash])
            `shouldBe` Right
                ( Insert
                    EntryArgs
                        { entryRegistry = "/srv/reg"
                        , entryBlueprint = "/srv/plutus.json"
                        , entryMode =
                            Preview
                                (NodeSettings "/run/node.socket" 1)
                                (textOf Testnet payerHash)
                        , entryKey = Key "key"
                        , entryDocument = Just "/e.json"
                        , entryFund = Nothing
                        , entryMaxOutlay = Nothing
                        , entryReceipt = Nothing
                        }
                )
    it "refuses a signing key beside --preview before anything is read" $
        insertPreview
            ( previewNode "1"
                <> ["--wallet-address", textOf Testnet payerHash]
                <> wallet
            )
            `shouldBe` Left PreviewTakesNoKey
    it "names a missing address, and a missing node" $ do
        insertPreview (previewNode "1")
            `shouldBe` Left (MissingFlag "--wallet-address")
        insertPreview ["--wallet-address", textOf Testnet payerHash]
            `shouldBe` Left (MissingFlag "--node-socket")
    it
        "reads the funding output and the allowance a write or a preview may use"
        $ do
            let funded = replicate 64 '3' <> "#1"
                parsed =
                    insertPreview
                        ( previewNode "1"
                            <> ["--wallet-address", textOf Testnet payerHash]
                            <> ["--fund-input", funded, "--max-outlay", "12000000"]
                        )
            fmap
                ( \case
                    Insert a -> (fmap renderOutRef (entryFund a), entryMaxOutlay a)
                    _ -> (Nothing, Nothing)
                )
                parsed
                `shouldBe` Right (Just (T.pack funded), Just 12_000_000)
            insertPreview
                (previewNode "1" <> ["--wallet-address", "x", "--fund-input", "nope"])
                `shouldSatisfy` isLeftWith (\case BadValue "--fund-input" _ -> True; _ -> False)
            insertPreview
                (previewNode "1" <> ["--wallet-address", "x", "--max-outlay", "0"])
                `shouldSatisfy` isLeftWith (\case BadValue "--max-outlay" _ -> True; _ -> False)
    it "reads a create preview for a public address with an optional seed" $ do
        let create extra =
                parseCommand
                    ( ["registry", "create", "--preview"]
                        <> reg
                        <> previewNode "1"
                        <> extra
                    )
        fmap
            ( \case
                Create a -> Just (createMode a, createPreview a, createSeed a)
                _ -> Nothing
            )
            (create ["--wallet-address", textOf Testnet payerHash])
            `shouldBe` Right
                ( Just
                    ( Preview (NodeSettings "/run/node.socket" 1) (textOf Testnet payerHash)
                    , True
                    , Nothing
                    )
                )
        create
            ["--wallet-address", textOf Testnet payerHash, "--wallet-skey", "/k"]
            `shouldBe` Left PreviewTakesNoKey
    it "refuses an address on a command that signs" $ do
        parseCommand
            ( ["registry", "insert", "--key", "6b6579", "--envelope", "/e.json"]
                <> reg
                <> node
                <> wallet
                <> ["--wallet-address", textOf Testnet payerHash]
            )
            `shouldSatisfy` isLeftWith (\case BadValue "--wallet-address" _ -> True; _ -> False)
    describe
        "a spending constraint a command does not enforce is refused, never ignored"
        $ do
            let funded = replicate 64 '3' <> "#1"
                create extra =
                    parseCommand
                        ( ["registry", "create", "--seed", funded]
                            <> reg
                            <> node
                            <> wallet
                            <> extra
                        )
                inspect extra =
                    parseCommand
                        (["registry", "inspect", "--key", "6b6579"] <> reg <> node <> extra)
                terminate extra =
                    parseCommand
                        ( ["registry", "terminate", "--key", "6b6579"]
                            <> reg
                            <> node
                            <> wallet
                            <> extra
                        )
            it "refuses a create that states a maximum outlay or a funding input" $ do
                create ["--max-outlay", "1"]
                    `shouldBe` Left (UnsupportedFlag "--max-outlay" "create")
                create ["--fund-input", funded]
                    `shouldBe` Left (UnsupportedFlag "--fund-input" "create")
                create ["--fund-input", funded, "--max-outlay", "1"]
                    `shouldSatisfy` isLeftWith (\case UnsupportedFlag _ "create" -> True; _ -> False)
            it "refuses them on an inspect too" $ do
                inspect ["--max-outlay", "1"]
                    `shouldBe` Left (UnsupportedFlag "--max-outlay" "inspect")
                inspect ["--fund-input", funded]
                    `shouldBe` Left (UnsupportedFlag "--fund-input" "inspect")
            it
                "still reads them on the commands that enforce them, and a create without them"
                $ do
                    fmap
                        (\case Terminate a -> entryMaxOutlay a; _ -> Nothing)
                        (terminate ["--max-outlay", "1"])
                        `shouldBe` Right (Just 1)
                    create [] `shouldSatisfy` either (const False) (const True)
                    inspect [] `shouldSatisfy` either (const False) (const True)
    describe "the public address" $ do
        it "round-trips a payment key hash for each network" $ do
            parseEnterpriseAddress 1 (textOf Testnet payerHash)
                `shouldBe` Right (addrOf Testnet payerHash)
            parseEnterpriseAddress 764_824_073 (textOf Mainnet payerHash)
                `shouldBe` Right (addrOf Mainnet payerHash)
        it "tells two callers apart" $
            parseEnterpriseAddress 1 (textOf Testnet payerHash)
                `shouldNotBe` parseEnterpriseAddress 1 (textOf Testnet strangerHash)
        it "refuses another network's address" $ do
            parseEnterpriseAddress 1 (textOf Mainnet payerHash)
                `shouldSatisfy` isLeftContaining "another network"
            parseEnterpriseAddress 764_824_073 (textOf Testnet payerHash)
                `shouldSatisfy` isLeftContaining "another network"
        it "refuses an address that carries a stake part" $
            parseEnterpriseAddress 1 (bech32Address baseAddr)
                `shouldSatisfy` isLeftContaining "enterprise"
        it "refuses text that is not an address, and a corrupted checksum" $ do
            parseEnterpriseAddress 1 "not an address"
                `shouldSatisfy` isLeftContaining "not bech32"
            let text = textOf Testnet payerHash
                corrupted = init text <> (if last text == 'q' then "p" else "q")
            parseEnterpriseAddress 1 corrupted
                `shouldSatisfy` isLeftContaining "not bech32"
  where
    isLeftContaining needle = \case
        Left why -> needle `isInfixOf` why
        Right _ -> False
