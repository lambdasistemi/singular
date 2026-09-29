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

import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as BL
import Data.List (isInfixOf)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Lens.Micro ((&), (.~))
import System.Directory (createDirectoryIfMissing)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import Data.Aeson qualified as Aeson

import Cardano.Ledger.Api.Tx.Out
    ( mkBasicTxOut
    , referenceScriptTxOutL
    )
import Cardano.Ledger.BaseTypes (StrictMaybe (..))
import Cardano.Ledger.Mary.Value (MaryValue (..))

import MPF.Backend.Pure (MPFInMemoryDB (..))

import Singular.CLI.Command
import Singular.CLI.Proof
import Singular.CLI.Receipt
import Singular.CLI.Registry
import Singular.Registry.Deployment
    ( Deployment (..)
    , loadMirror
    , parseOutRef
    , saveMirror
    )
import Singular.Registry.Ledger
    ( AssetName (..)
    , Coin (..)
    , Root (..)
    , TokenId (..)
    )
import Singular.Registry.Node (Wallet (..), loadWallet)
import Singular.Registry.Trie (Trie (..), TrieManager (..))
import Singular.Registry.Trie.Pure (provesAbsent, provesMember)
import Singular.Registry.Trie.PureManager (mkPureTrieManagerFrom)
import Singular.Registry.TxBuilder.Internal
    ( leafActive
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
                        , createWrite = writeSettings
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
                        , entryWrite = writeSettings
                        , entryKey = Key "key"
                        , entryDocument = Just "/e.json"
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
                (\case Insert a -> writeConfirmTimeout (entryWrite a); _ -> Nothing)
                (insert ["--confirm-timeout", "0"])
                `shouldBe` Right (Just 0)
            insert ["--confirm-timeout", "soon"]
                `shouldBe` Left (BadValue "--confirm-timeout" "is not a whole number of seconds")
    it "refuses a write against mainnet" $
        parseCommand
            ( ["registry", "insert", "--key", "6b6579"]
                <> reg
                <> ["--node-socket", "/s", "--network-magic", "764824073"]
                <> wallet
            )
            `shouldSatisfy` isLeftWith (unsafeMentions "764824073")
    it "refuses a write with no node at all rather than spawning one" $
        parseCommand (["registry", "insert", "--key", "6b6579"] <> reg)
            `shouldSatisfy` isLeftWith isUnsafe
    it "names a missing registry directory" $
        parseCommand
            (["registry", "inspect", "--key", "6b6579", "--blueprint", "b"] <> node)
            `shouldBe` Left (MissingFlag "--registry")
  where
    forM5 xs f = mapM_ f xs
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
        "refuses a seed the wallet does not hold, or one that is not ada-only"
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
  where
    submitted s t = phase s t "submitted"
    confirmed s t = phase s t "observed"
    phase s t e =
        JournalEntry
            "insert"
            s
            t
            e
            Nothing
            Nothing
            Nothing
            Nothing
            Nothing
            Nothing

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

withTempDir :: (FilePath -> IO a) -> IO a
withTempDir = withSystemTempDirectory "singular-cli-spec"
