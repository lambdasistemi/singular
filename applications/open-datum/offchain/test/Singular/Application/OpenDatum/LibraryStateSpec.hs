{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.Application.OpenDatum.LibraryStateSpec
Description : Seed admission, journal evidence and recovery through library entry points
License     : Apache-2.0

These checks call library functions directly. No command parser or public
route is required to exercise their assertions.
-}
module Singular.Application.OpenDatum.LibraryStateSpec (spec) where

import Cardano.Ledger.Api.Tx.Out
    ( mkBasicTxOut
    , referenceScriptTxOutL
    )
import Cardano.Ledger.BaseTypes (StrictMaybe (SJust))
import Cardano.Ledger.Mary.Value (MaryValue (MaryValue))
import Control.Exception
    ( ErrorCall (..)
    , displayException
    , fromException
    , toException
    )
import Control.Monad (forM_)
import Data.Aeson qualified as Aeson (ToJSON (toJSON), encode)
import Data.ByteString qualified as BS (ByteString, writeFile)
import Data.ByteString.Base16 qualified as B16 (encode)
import Data.ByteString.Char8 qualified as BC (replicate)
import Data.ByteString.Lazy qualified as BL (null)
import Data.List (isInfixOf)
import Data.Map.Strict qualified as Map (empty, lookup)
import Data.Maybe (isJust)
import Data.Set qualified as Set (fromList)
import Data.Text qualified as T (Text, pack, unpack)
import Lens.Micro ((&), (.~))
import MPF.Backend.Pure (MPFInMemoryDB (..))
import Singular.CLI.Proof
    ( AuthError (RootMismatch)
    , Leaf (Active, Terminal, Unknown)
    , authenticatedLeaf
    , leafName
    , rootOfDb
    )
import Singular.CLI.Receipt
    ( JournalEntry (..)
    , OutcomeClass (ClientRefusal, Partial, Success)
    , SubmissionCase
        ( CaseAcknowledged
        , CaseExcluded
        , CaseIncluded
        , CaseRejected
        , CaseRolledBack
        , CaseTimeout
        , CaseUnknown
        )
    , appendJournal
    , caseName
    , exitCodeOf
    , journalPath
    , outcomeName
    , readJournal
    , submissionCase
    , unresolved
    )
import Singular.CLI.Recovery
    ( Inclusion (OffChain, OnChain, Undetermined)
    , excludedAt
    , inclusionOf
    , rollbackEvidence
    )
import Singular.CLI.Registry
    ( IdentityError (RegistryExists, SeedNotAdaOnly, SeedNotInWallet)
    , checkSeed
    , refuseExisting
    , renderIdentityError
    , seedChecks
    , seedHeld
    , selectSeed
    )
import Singular.CLI.Session
    ( CommandFailure (..)
    , admitSubmissions
    )
import Singular.Registry.Deployment (parseOutRef)
import Singular.Registry.Ledger
    ( AssetName (..)
    , Coin (..)
    , Root (..)
    , SlotNo (..)
    , TokenId (..)
    )
import Singular.Registry.LedgerProvider (ReadFailure (..))
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
import Singular.Registry.Wallet (Wallet (walletAddr), loadWallet)
import System.Directory (createDirectoryIfMissing)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec
    ( Spec
    , describe
    , expectationFailure
    , it
    , shouldBe
    , shouldReturn
    , shouldSatisfy
    )

spec :: Spec
spec = do
    creatorChecks
    journal
    localProof
    recovery
    rollback

seedText :: String
seedText = replicate 64 'b' <> "#1"

isLeftWith :: (e -> Bool) -> Either e a -> Bool
isLeftWith predicate = either predicate (const False)

keyFile :: FilePath -> Char -> IO Wallet
keyFile dir c = do
    let path = dir </> (c : ".skey")
    BS.writeFile path (B16.encode (BC.replicate 32 c))
    loadWallet 42 path

creatorChecks :: Spec
creatorChecks = describe "a creator's seed and directory" $ do
    it
        "refuses a seed the wallet does not hold or one that is not ada-only; a sole output is held (#406 slice 2)"
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
                -- the refusal that really refuses or accepts is the seed
                -- selection (it knows whether the state must be published),
                -- not `checkSeed` (which is `seedHeld`): an explicit sole
                -- output while publishing is refused with omit-`--seed`.
                let dummyState = scriptFromBytes "state" "\1"
                case selectSeed
                    (Just seed)
                    [(seed, plain)]
                    undefined
                    dummyState
                    (walletAddr w)
                    True
                    True of
                    Right _ ->
                        expectationFailure
                            "an explicit sole seed was accepted while publishing"
                    Left err -> do
                        let text = renderIdentityError err
                        text `shouldSatisfy` ("omit `--seed`" `isInfixOf`)
                        text `shouldSatisfy` (not . ("second ada-only output" `isInfixOf`))
                selectSeed
                    (Just seed)
                    [(seed, plain)]
                    undefined
                    dummyState
                    (walletAddr w)
                    False
                    True
                    `shouldBe` Right (seed, "output")
                selectSeed
                    (Just seed)
                    [(seed, plain), (other, plain)]
                    undefined
                    dummyState
                    (walletAddr w)
                    True
                    True
                    `shouldBe` Right (seed, "output")
                -- an identity needs only the seed held
                fmap fst (seedHeld seed [(seed, plain)]) `shouldBe` Right seed
                seedHeld seed [(other, plain)]
                    `shouldSatisfy` isLeftWith isNotInWallet
                seedHeld seed [(seed, withScript), (other, plain)]
                    `shouldSatisfy` isLeftWith isNotAdaOnly
    it
        "previews a one-output wallet's identity with no seed refusal; funding is judged later (#406 slice 2)"
        $ do
            seed <- either fail pure (parseOutRef (T.pack seedText))
            other <-
                either fail pure (parseOutRef (T.pack (replicate 64 'c' <> "#0")))
            withTempDir $ \dir -> do
                w <- keyFile dir 'k'
                let plain = mkBasicTxOut (walletAddr w) (MaryValue (Coin 5_000_000) mempty)
                    dummyState = scriptFromBytes "state" "\1"
                -- with a live carrier the seed is an output: auto selects the
                -- largest, explicit names a held output (no PParams needed).
                selectSeed
                    Nothing
                    [(seed, plain)]
                    undefined
                    dummyState
                    (walletAddr w)
                    False
                    False
                    `shouldBe` Right (seed, "output")
                selectSeed
                    (Just seed)
                    [(seed, plain)]
                    undefined
                    dummyState
                    (walletAddr w)
                    False
                    False
                    `shouldBe` Right (seed, "output")
                selectSeed
                    (Just seed)
                    [(seed, plain), (other, plain)]
                    undefined
                    dummyState
                    (walletAddr w)
                    False
                    True
                    `shouldBe` Right (seed, "output")
                -- a preview still refuses a seed the wallet does not hold
                seedChecks False seed [(other, plain)]
                    `shouldSatisfy` isLeftWith isNotInWallet
    it
        "refuses to create over a directory that already holds your state or a journal"
        $ withTempDir
        $ \dir -> do
            refuseExisting (dir </> "fresh") `shouldReturn` Right ()
            let used = dir </> "used"
            createDirectoryIfMissing True used
            BS.writeFile (journalPath used) ""
            refuseExisting used `shouldReturn` Left (RegistryExists used)
    it "ignores retired trie files when admitting a state directory" $
        withTempDir $ \dir -> do
            let used = dir </> "retired-files"
            createDirectoryIfMissing True used
            BS.writeFile (used </> "state.json") "corrupted saved root"
            BS.writeFile (used </> "registry.mirror.json") "corrupted mirror"
            refuseExisting used `shouldReturn` Right ()
  where
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
            read' <- readJournal dir
            -- each line comes back as appended, plus the time of its append
            map (\e -> e{journalTime = Nothing}) read' `shouldBe` entries
            map (isJust . journalTime) read' `shouldBe` map (const True) entries
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
                            (BackendReadFailure "the provider read was unavailable")
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
            , journalSession = Nothing
            , journalObservedTip = Nothing
            , journalKey = Nothing
            , journalExpect = Nothing
            , journalEdge = Nothing
            , journalRootBefore = Nothing
            , journalRootAfter = Nothing
            , journalTransitions = Nothing
            , journalTime = Nothing
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
            , journalSession = Nothing
            , journalObservedTip = Nothing
            , journalKey = Nothing
            , journalExpect = Nothing
            , journalEdge = Nothing
            , journalRootBefore = Nothing
            , journalRootAfter = Nothing
            , journalTransitions = Nothing
            , journalTime = Nothing
            }

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
  where
    phases t = map (jline t)
    outRef c i =
        either error id $
            parseOutRef (T.pack (replicate 64 c <> "#" <> show (i :: Int)))

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
        , journalSession = Nothing
        , journalObservedTip = Nothing
        , journalKey = Nothing
        , journalExpect = Nothing
        , journalEdge = Nothing
        , journalRootBefore = Nothing
        , journalRootAfter = Nothing
        , journalTransitions = Nothing
        , journalTime = Nothing
        }

withTempDir :: (FilePath -> IO a) -> IO a
withTempDir = withSystemTempDirectory "singular-cli-spec"
