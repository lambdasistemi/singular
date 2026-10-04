{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.CLI.TrieRefusalSpec
Description : Every trie refusal a command prints names its registry and transaction
License     : Apache-2.0

A person reading a refused command's receipt must learn which registry was
refused and, where the refusal is about one transaction, which one. Every
refusal class is printed here through the commands' own stop
('failTrie') and through an inspect's proof error, for two registries and
two transactions, so a receipt that names a constant, or drops the payload,
does not pass. The payload is one @trieRefusal@ field, so it can never
overwrite a field the receipt already carries. The expected spellings are the identities' own bytes and the
transaction's own hash, hex-encoded here, never the renderer's output.
-}
module Singular.CLI.TrieRefusalSpec (spec) where

import Control.Exception (try)
import Control.Monad (forM_)
import Data.Aeson (Value (..), object, toJSON, (.=))
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Short qualified as SBS
import Data.List (nub, sort)
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Test.Hspec

import Cardano.Crypto.Hash (hashToBytes)
import Cardano.Ledger.Hashes (extractHash)
import Cardano.Ledger.TxIn (TxId (..), TxIn (..))

import Singular.CLI.Live (failTrie)
import Singular.CLI.Proof
    ( AuthError (..)
    , authErrorFields
    , renderAuthError
    )
import Singular.CLI.Session (CommandFailure (..))
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

-- | Every class and every reason, over two registries, with and without a transaction.
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
            <> [RootDoesNotChain who tx rootA rootB]
            <> [ UndecodableRequest who tx why
               | why <-
                    [ UndecodableStateOutput
                    , MissingRedeemer
                    , NotModify
                    , ActionCount 2 1
                    , EdgeOutOfRange 99
                    , UnreadableRecord "a journal root is not hex"
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

-- | The registry as the receipt must spell it, from the identity's own bytes.
registryJson :: RegistryIdentity -> Value
registryJson (RegistryIdentity (StatePolicyId policy) (AssetName name)) =
    object ["policy" .= hex policy, "name" .= hex (SBS.fromShort name)]

-- | The transaction as the receipt must spell it, from its own hash.
txJson :: TxId -> Value
txJson (TxId h) = toJSON (hex (hashToBytes (extractHash h)))

hex :: ByteString -> Text
hex = T.pack . BC.unpack . B16.encode

-- | What a refusal must name: its registry, and its transaction where one exists.
subject :: TrieFailure -> (Maybe Value, Maybe Value)
subject f =
    ( Just (registryJson (failureRegistry f))
    , txJson <$> failureTransaction f
    )

{- | What the printed fields name, read from the one @trieRefusal@ object;
nothing when the fields are anything else.
-}
printedSubject :: [(Text, Value)] -> (Maybe Value, Maybe Value)
printedSubject = \case
    [("trieRefusal", Object payload)] ->
        ( KeyMap.lookup "registry" payload
        , KeyMap.lookup "transaction" payload
        )
    _ -> (Nothing, Nothing)

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
        "names the registry and, where one exists, the transaction, in a command's receipt"
        $ forM_ samples
        $ \f -> do
            stopped <- try (failTrie f)
            case stopped of
                Left (CommandFailure _ why fields) -> do
                    (show f, why)
                        `shouldBe` (show f, "TrieState " <> T.unpack (trieFailureName f))
                    (show f, printedSubject fields) `shouldBe` (show f, subject f)
                Right () -> expectationFailure ("the command did not stop on " <> show f)

    it
        "names the registry and, where one exists, the transaction, in an inspect's refusal"
        $ forM_ samples
        $ \f -> do
            let err = TrieRefusal f
            (show f, renderAuthError err)
                `shouldBe` (show f, "TrieState " <> T.unpack (trieFailureName f))
            (show f, printedSubject (authErrorFields err))
                `shouldBe` (show f, subject f)
