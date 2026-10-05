{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.CLI.TrieRefusalSpec
Description : Every trie refusal a command prints names its registry, transaction and cause
License     : Apache-2.0

A person reading a refused command's receipt must learn which registry was
refused, which transaction the refusal is about where there is one, and
why. Every refusal class with every cause is printed here through the
commands' own stop ('failTrie') and through an inspect's proof error, over
two registries and two transactions. The printed reason, outcome class,
exit status and the whole @trieRefusal@ field must equal what this module
expects.

The expectation is written here, not read from the renderer: the names, the
causes and their field names are spelled out below, the outcome classes and
exits are the ones commands printed before the refusals carried a payload
(the command stop at @cli/src/Singular/CLI/Live.hs:529-536@ and
'Singular.CLI.Receipt.exitCodeOf' at that revision), and every identity,
root, output and key is hex-encoded here from the sample's own bytes.
-}
module Singular.CLI.TrieRefusalSpec (spec) where

import Control.Exception (try)
import Control.Monad (forM_)
import Data.Aeson (Value (..), object, toJSON, (.=))
import Data.Aeson.Key qualified as Key
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Short qualified as SBS
import Data.List (nub, sort)
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import System.Exit (ExitCode (..))
import Test.Hspec

import Cardano.Crypto.Hash (hashToBytes)
import Cardano.Ledger.BaseTypes (TxIx (..))
import Cardano.Ledger.Hashes (extractHash)
import Cardano.Ledger.TxIn (TxId (..), TxIn (..))

import Singular.CLI.Live (failTrie)
import Singular.CLI.Proof
    ( AuthError (..)
    , authErrorFields
    , renderAuthError
    )
import Singular.CLI.Receipt (exitCodeOf, outcomeName)
import Singular.CLI.Session (CommandFailure (..))
import Singular.CLI.TrieHistory (journalRoot)
import Singular.Registry.Deployment (parseOutRef)
import Singular.Registry.Ledger (AssetName (..), Root (..))
import Singular.Registry.TrieState

-- | The refusal classes, one per constructor; 'classOf' is total.
data RefusalClass
    = ClassHistoryIncomplete
    | ClassRootDoesNotChain
    | ClassUndecodableRequest
    | ClassWrongRegistry
    | ClassStaleState
    | ClassMissingProof
    deriving stock (Eq, Ord, Show, Enum, Bounded)

classOf :: TrieFailure -> RefusalClass
classOf = \case
    HistoryIncomplete{} -> ClassHistoryIncomplete
    RootDoesNotChain{} -> ClassRootDoesNotChain
    UndecodableRequest{} -> ClassUndecodableRequest
    WrongRegistry{} -> ClassWrongRegistry
    StaleState{} -> ClassStaleState
    MissingProof{} -> ClassMissingProof

registryA, registryB :: RegistryIdentity
registryA =
    RegistryIdentity
        (StatePolicyId (BS.replicate 28 0xa1))
        (AssetName "registry-a")
registryB =
    RegistryIdentity
        (StatePolicyId (BS.replicate 28 0xb2))
        (AssetName "registry-b")

outRef :: Char -> Int -> TxIn
outRef c ix = case parseOutRef
    (T.replicate 64 (T.singleton c) <> "#" <> T.pack (show ix)) of
    Right i -> i
    Left why -> error why

txA, txB :: TxId
txA = let TxIn t _ = outRef 'a' 0 in t
txB = let TxIn t _ = outRef 'b' 0 in t

rootA, rootB :: Root
rootA = Root (BS.replicate 32 0x11)
rootB = Root (BS.replicate 32 0x22)

selection :: RegistryIdentity -> Int -> Root -> TrieSelection
selection who n =
    TrieSelection
        who
        (StatePoint (SessionId "refusal") Unbound (outRef 'c' n))

-- | Every class and every cause, over two registries, with and without a transaction.
samples :: [TrieFailure]
samples =
    concat
        [ [ HistoryIncomplete who tx why
          | why <-
                [ MissingTransaction
                , UnresolvedInput (outRef 'd' 1)
                , ConflictingResolution (outRef 'd' 2)
                , ConflictingCopies
                , NoStateInput
                , ForkedStateOutput (outRef 'd' 3)
                , OutsideLineage
                ]
          ]
            <> [ RootDoesNotChain who tx why
               | why <-
                    [RootsPart rootA rootB, UnreadableRoot "a journal root is not hex"]
               ]
            <> [ UndecodableRequest who tx why
               | why <-
                    [ UndecodableStateOutput
                    , MissingRedeemer
                    , NotModify
                    , ActionCount 2 1
                    , EdgeOutOfRange 99
                    , UnreadableRecord "a journal key is not hex"
                    ]
               ]
            <> [ WrongRegistry who tx why
               | why <-
                    [ SelectionNotState
                    , CreateMint
                    , SeedNotSpent
                    , SeedName
                    , CreateOutput
                    , OtherRegistry (other who)
                    , UnknownRegistry
                    ]
               ]
            <> [ StaleState who tx why
               | why <-
                    [ StaleRoot rootA rootB
                    , StaleSelection (selection who 1 rootA) (selection who 2 rootB)
                    , StaleOutput (outRef 'e' 0) (outRef 'e' 1)
                    , NoSelection
                    ]
               ]
            <> [MissingProof who why | why <- [NoProofFor "some-key", NoLocalTrie]]
        | (who, tx) <-
            [ (registryA, Just txA)
            , (registryB, Just txB)
            , (registryA, Nothing)
            , (registryB, Nothing)
            ]
        ]
  where
    other who = if who == registryA then registryB else registryA

-- ---------------------------------------------------------
-- The expectation, written independently of the renderer
-- ---------------------------------------------------------

-- | What a command must print for a refusal: reason, outcome, exit, payload.
data Printed = Printed
    { printedReason :: String
    , printedOutcome :: Text
    , printedExit :: ExitCode
    , printedFields :: [(Text, Value)]
    }
    deriving stock (Eq, Show)

expected :: TrieFailure -> Printed
expected f =
    Printed
        { printedReason = "TrieState " <> name
        , printedOutcome = outcome
        , printedExit = ExitFailure exit
        , printedFields =
            [
                ( "trieRefusal"
                , object
                    ( ["registry" .= registryJson who]
                        <> maybe [] (\t -> ["transaction" .= txHex t]) tx
                        <> map (\(k, v) -> Key.fromText k .= v) cause
                    )
                )
            ]
        }
  where
    -- Outcome classes and exits as commands printed them before the payload.
    staleState = ("stale-state", 14)
    clientRefusal = ("client-refusal", 10)
    proofMissing = ("proof-missing", 17)
    (name, who, tx, (outcome, exit), cause) = case f of
        HistoryIncomplete w t why ->
            ("HistoryIncomplete", w, t, staleState, incomplete why)
        RootDoesNotChain w t why ->
            ("RootDoesNotChain", w, t, staleState, parting why)
        UndecodableRequest w t why ->
            ("UndecodableRequest", w, t, clientRefusal, undecodable why)
        WrongRegistry w t why ->
            ("WrongRegistry", w, t, clientRefusal, mismatch why)
        StaleState w t why ->
            ("StaleState", w, t, staleState, staleness why)
        MissingProof w why ->
            ("MissingProof", w, Nothing, proofMissing, missing why)
    causeOnly c = [("cause", String c)]
    withOutput c i = causeOnly c <> [("output", String (outRefText i))]
    incomplete = \case
        MissingTransaction -> causeOnly "missing-transaction"
        UnresolvedInput i -> withOutput "unresolved-input" i
        ConflictingResolution i -> withOutput "conflicting-resolution" i
        ConflictingCopies -> causeOnly "conflicting-copies"
        NoStateInput -> causeOnly "no-state-input"
        ForkedStateOutput i -> withOutput "forked-state-output" i
        OutsideLineage -> causeOnly "outside-lineage"
    parting = \case
        RootsPart rebuilt recorded ->
            causeOnly "roots-part"
                <> [ ("rebuiltRoot", String (rootHex rebuilt))
                   , ("recordedRoot", String (rootHex recorded))
                   ]
        UnreadableRoot what -> causeOnly "unreadable-root" <> [("record", String what)]
    undecodable = \case
        UndecodableStateOutput -> causeOnly "undecodable-state-output"
        MissingRedeemer -> causeOnly "missing-redeemer"
        NotModify -> causeOnly "not-modify"
        ActionCount given found ->
            causeOnly "action-count"
                <> [("actions", toJSON given), ("requests", toJSON found)]
        EdgeOutOfRange edge -> causeOnly "edge-out-of-range" <> [("edge", toJSON edge)]
        UnreadableRecord what -> causeOnly "unreadable-record" <> [("record", String what)]
    mismatch = \case
        SelectionNotState -> causeOnly "selection-not-state"
        CreateMint -> causeOnly "create-mint"
        SeedNotSpent -> causeOnly "seed-not-spent"
        SeedName -> causeOnly "seed-name"
        CreateOutput -> causeOnly "create-output"
        OtherRegistry o -> causeOnly "other-registry" <> [("otherRegistry", registryJson o)]
        UnknownRegistry -> causeOnly "unknown-registry"
    staleness = \case
        StaleRoot selected current ->
            causeOnly "stale-root"
                <> [ ("selectedRoot", String (rootHex selected))
                   , ("currentRoot", String (rootHex current))
                   ]
        StaleSelection selected held ->
            causeOnly "stale-selection"
                <> [("selected", selectionJson selected), ("held", selectionJson held)]
        StaleOutput selected made ->
            causeOnly "stale-output"
                <> [ ("selectedOutput", String (outRefText selected))
                   , ("madeOutput", String (outRefText made))
                   ]
        NoSelection -> causeOnly "no-selection"
    missing = \case
        NoProofFor key -> causeOnly "no-proof" <> [("key", String (hex key))]
        NoLocalTrie -> causeOnly "no-local-trie"

registryJson :: RegistryIdentity -> Value
registryJson (RegistryIdentity (StatePolicyId policy) (AssetName name)) =
    object ["policy" .= hex policy, "name" .= hex (SBS.fromShort name)]

selectionJson :: TrieSelection -> Value
selectionJson (TrieSelection _ point root) =
    object
        [ "output" .= outRefText (pointOutput point)
        , "root" .= rootHex root
        ]

txHex :: TxId -> Text
txHex (TxId h) = hex (hashToBytes (extractHash h))

outRefText :: TxIn -> Text
outRefText (TxIn t (TxIx ix)) = txHex t <> "#" <> T.pack (show ix)

rootHex :: Root -> Text
rootHex (Root r) = hex r

hex :: ByteString -> Text
hex = T.pack . BC.unpack . B16.encode

-- | What the command stop printed for a refusal.
stopped :: TrieFailure -> IO (Either String Printed)
stopped f =
    try (failTrie f) >>= \case
        Left (CommandFailure c why fields) ->
            pure (Right (Printed why (outcomeName c) (exitCodeOf c) fields))
        Right () -> pure (Left ("the command did not stop on " <> show f))

spec :: Spec
spec = describe "A trie refusal, as a command prints it" $ do
    it
        "is sampled for every refusal class, two registries and two transactions"
        $ do
            sort (nub (map classOf samples)) `shouldBe` [minBound .. maxBound]
            nub (map failureRegistry samples) `shouldSatisfy` ((== 2) . length)
            nub (mapMaybe failureTransaction samples)
                `shouldSatisfy` ((== 2) . length)

    it
        "prints its name, outcome, exit, registry, transaction and cause in a command's receipt"
        $ forM_ samples
        $ \f -> do
            printed <- stopped f
            (show f, printed) `shouldBe` (show f, Right (expected f))

    it
        "prints its name, registry, transaction and cause in an inspect's refusal"
        $ forM_ samples
        $ \f -> do
            let err = TrieRefusal f
                want = expected f
            (show f, renderAuthError err, authErrorFields err)
                `shouldBe` (show f, printedReason want, printedFields want)

    describe "a journal root an accepted fold records" $ do
        it "reads a hex root" $
            journalRoot registryA Nothing (Just (rootHex rootA))
                `shouldBe` Right rootA

        it
            "refuses a root that is not hex as a root that does not chain, stale state, exit 14"
            $ do
                refusal <-
                    either pure (fail . ("a non-hex root was read: " <>) . show) $
                        journalRoot registryA Nothing (Just "not-a-hex-root")
                classOf refusal `shouldBe` ClassRootDoesNotChain
                printed <- stopped refusal
                fmap
                    (\p -> (printedReason p, printedOutcome p, printedExit p))
                    printed
                    `shouldBe` Right ("TrieState RootDoesNotChain", "stale-state", ExitFailure 14)
                printed `shouldBe` Right (expected refusal)

        it
            "refuses a missing root as an incomplete history, stale state, exit 14"
            $ do
                refusal <-
                    either pure (fail . ("a missing root was read: " <>) . show) $
                        journalRoot registryA Nothing Nothing
                classOf refusal `shouldBe` ClassHistoryIncomplete
                printed <- stopped refusal
                fmap
                    (\p -> (printedReason p, printedOutcome p, printedExit p))
                    printed
                    `shouldBe` Right ("TrieState HistoryIncomplete", "stale-state", ExitFailure 14)
