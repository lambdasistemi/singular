{-# LANGUAGE LambdaCase #-}

{- |
Module      : Singular.State.PreimageSpec
Description : The hashed-name preimages, byte for byte
License     : Apache-2.0

The codec is judged against one committed table of byte vectors,
@test\/fixtures\/preimage-vectors.json@, that the on-chain functions reproduce
as well (the Aiken tests of @validators\/singular_state_preimage_vectors.tests.ak@
are generated from the same file). The table was made by an independent
reference encoder, so no byte in it comes from the code under test.

These cases hold three things. The codec reproduces every vector, byte and
name, and the termination preimage function reproduces its vectors as well.
The table covers the edges of the encoding: a definite-length list, an
indefinite-length list, a chunked byte string and a big number, each found in
the bytes by a CBOR reader and not trusted from the label. The roles are
separated: one constructor per role, numbered as the model, no two vectors
sharing a preimage or a name, a termination named apart from the active token
and the registration approvals of its registry and key, and a preimage without
its constructor naming another token.
-}
module Singular.State.PreimageSpec (spec) where

import Codec.CBOR.Read (deserialiseFromBytes)
import Codec.CBOR.Term (Term (..), decodeTerm)
import Codec.Serialise (serialise)
import Control.Monad (forM_)
import Crypto.Hash (Blake2b_256 (..), hashWith)
import Data.Aeson
    ( FromJSON (..)
    , Object
    , Value
    , eitherDecodeFileStrict
    , withObject
    , (.:)
    )
import Data.Aeson.Types (Parser, parseEither)
import Data.ByteArray qualified as BA
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Lazy qualified as BL
import Data.ByteString.Short qualified as SBS
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Word (Word16, Word64)
import PlutusCore.Data (Data (..))
import PlutusLedgerApi.V3 qualified as P
import PlutusTx.Builtins.Internal (BuiltinByteString (..))
import Test.Hspec
import Text.Read (readMaybe)

import Cardano.Crypto.Hash.Class (hashFromBytes, hashToBytes)
import Cardano.Ledger.BaseTypes (TxIx (..))
import Cardano.Ledger.Hashes (extractHash, unsafeMakeSafeHash)
import Cardano.Ledger.Mary.Value (AssetName (..))
import Cardano.Ledger.TxIn (TxId (..), TxIn (..))

import Singular.Registry.TrieState
    ( RegistryIdentity (..)
    , StatePolicyId (..)
    )
import Singular.State.Preimage
    ( Preimage (..)
    , activeTokenName
    , approvalName
    , configurationTokenName
    , encodePreimage
    , registrationPreimage
    , roleName
    , stateTokenName
    , terminationPreimage
    )

-- | One row of the table, with its inputs read into the codec's types.
data Vector = Vector
    { vectorId :: Text
    , vectorRole :: Text
    , vectorEdges :: Set Text
    , vectorPreimage :: ByteString
    , vectorName :: ByteString
    , vectorInput :: Preimage
    }

instance FromJSON Vector where
    parseJSON = withObject "vector" $ \o -> do
        role <- o .: "role"
        input <- o .: "input"
        Vector
            <$> o .: "id"
            <*> pure role
            <*> (Set.fromList <$> o .: "edges")
            <*> (o .: "preimage" >>= hexBytes)
            <*> (o .: "name" >>= hexBytes)
            <*> inputOf role input

tablePath :: FilePath
tablePath = "test/fixtures/preimage-vectors.json"

loadVectors :: IO [Vector]
loadVectors = do
    table <- eitherDecodeFileStrict tablePath
    case table >>= parseEither (withObject "table" (.: "vectors")) of
        Left why -> fail (tablePath <> ": " <> why)
        Right vectors -> pure vectors

hexBytes :: Text -> Parser ByteString
hexBytes = either fail pure . B16.decode . TE.encodeUtf8

inputOf :: Text -> Value -> Parser Preimage
inputOf role = withObject (T.unpack role) $ \o -> case role of
    "state" -> do
        seed <- o .: "seed"
        State <$> seedOf seed
    "active" -> Active <$> (o .: "registry" >>= registryOf) <*> keyOf o
    "configuration" ->
        ApplicationConfiguration <$> (o .: "registry" >>= registryOf)
    "registration-approval" ->
        RegistrationApproval
            <$> (o .: "registry" >>= registryOf)
            <*> keyOf o
            <*> (o .: "holdingAddress" >>= addressOf)
            <*> (P.DatumHash . BuiltinByteString <$> (o .: "datumHash" >>= hexBytes))
            <*> (P.Lovelace <$> (o .: "deposit" >>= integerOf))
    "termination-approval" ->
        TerminationApproval <$> (o .: "registry" >>= registryOf) <*> keyOf o
    _ -> fail ("the role " <> T.unpack role <> " has no reader")

integerOf :: String -> Parser Integer
integerOf text = maybe (fail ("not a number: " <> text)) pure (readMaybe text)

keyOf :: Object -> Parser ByteString
keyOf o = o .: "key" >>= hexBytes

seedOf :: Object -> Parser TxIn
seedOf o = do
    bytes <- o .: "transactionId" >>= hexBytes
    index <- o .: "outputIndex"
    case hashFromBytes bytes of
        Nothing -> fail "a transaction id is 32 bytes"
        Just hash ->
            pure (TxIn (TxId (unsafeMakeSafeHash hash)) (TxIx (index :: Word16)))

registryOf :: Object -> Parser RegistryIdentity
registryOf o = do
    policy <- o .: "policy" >>= hexBytes
    name <- o .: "name" >>= hexBytes
    pure
        (RegistryIdentity (StatePolicyId policy) (AssetName (SBS.toShort name)))

addressOf :: Object -> Parser P.Address
addressOf o = do
    payment <- o .: "payment" >>= credentialOf
    stake <- o .: "stake"
    P.Address payment
        <$> traverse (fmap P.StakingHash . credentialOf) stake

credentialOf :: (Text, Text) -> Parser P.Credential
credentialOf (kind, hex) = do
    bytes <- BuiltinByteString <$> hexBytes hex
    case kind of
        "key" -> pure (P.PubKeyCredential (P.PubKeyHash bytes))
        "script" -> pure (P.ScriptCredential (P.ScriptHash bytes))
        _ -> fail ("the credential kind " <> T.unpack kind)

-- | The blake2b-256 hash, made here and not by the codec.
blake2b :: ByteString -> ByteString
blake2b = BA.convert . hashWith Blake2b_256

nameBytes :: AssetName -> ByteString
nameBytes (AssetName name) = SBS.fromShort name

-- | The CBOR of a preimage, read back with its list and byte string forms.
termOf :: ByteString -> IO Term
termOf bytes = case deserialiseFromBytes decodeTerm (BL.fromStrict bytes) of
    Left why -> fail ("not CBOR: " <> show why)
    Right (rest, term)
        | BL.null rest -> pure term
        | otherwise -> fail "bytes follow the preimage"

{- | The encoding edges a CBOR term exercises, found in its structure: the
empty list is written definite, any other list indefinite, a byte string of
more than 64 bytes in chunks, a number beyond 64 bits as a tagged big number
(which the reader returns as an integer that no 64-bit word holds).
-}
edgesOf :: Term -> Set Text
edgesOf = \case
    TList items -> Set.insert "definite-length-list" (foldMap edgesOf items)
    TListI items -> Set.insert "indefinite-length-list" (foldMap edgesOf items)
    TBytesI _ -> Set.singleton "chunked-byte-string"
    TTagged _ inner -> edgesOf inner
    TInteger n
        | n >= 2 ^ (64 :: Int) || n < negate (2 ^ (64 :: Int)) ->
            Set.singleton "big-number"
    _ -> Set.empty

-- | The tag of the constructor that opens a preimage.
constructorTag :: Term -> Maybe Word64
constructorTag = \case
    TTagged tag _ -> Just tag
    _ -> Nothing

-- | The number of a role's constructor in the model's @Preimage@.
constructorIndex :: Preimage -> Word64
constructorIndex = \case
    State{} -> 0
    Active{} -> 1
    ApplicationConfiguration{} -> 2
    RegistrationApproval{} -> 3
    TerminationApproval{} -> 4

{- | The name of a vector as the codec makes it, by the function the model
names for the role.
-}
nameByFunction :: Preimage -> AssetName
nameByFunction = \case
    State seed -> stateTokenName seed
    Active registry key -> activeTokenName registry key
    ApplicationConfiguration registry -> configurationTokenName registry
    RegistrationApproval registry key holding datumHash deposit ->
        approvalName
            (registrationPreimage key registry holding datumHash deposit)
    TerminationApproval registry key ->
        approvalName (terminationPreimage key registry)

spec :: Spec
spec = do
    vectors <- runIO loadVectors
    describe "the preimage vectors" $ do
        tableRows vectors
        reproductionRows vectors
        separationRows vectors

tableRows :: [Vector] -> Spec
tableRows vectors = describe "the table" $ do
    it "holds a vector for each role the line builds"
        $ forM_
            [ "state"
            , "active"
            , "configuration"
            , "registration-approval"
            , "termination-approval"
            ]
        $ \role ->
            (role, any ((== role) . vectorRole) vectors) `shouldBe` (role, True)

    it "names the edges each vector exercises, and its bytes show them" $
        forM_ vectors $ \v -> do
            term <- termOf (vectorPreimage v)
            (vectorId v, vectorEdges v) `shouldBe` (vectorId v, edgesOf term)

    it "repeats no preimage and no name" $ do
        distinct (vectorPreimage <$> vectors) `shouldBe` True
        distinct (vectorName <$> vectors) `shouldBe` True

    it
        "covers a definite-length list, an indefinite-length list and a chunked byte string"
        $ Set.fromList
            [ "definite-length-list"
            , "indefinite-length-list"
            , "chunked-byte-string"
            ]
            `shouldSatisfy` (`Set.isSubsetOf` foldMap vectorEdges vectors)

    it "covers the byte string lengths around the chunk size" $ do
        let keyLengths = [BS.length key | Active _ key <- vectorInput <$> vectors]
        forM_ [0, 64, 65, 128, 129] $ \len ->
            (len, len `elem` keyLengths) `shouldBe` (len, True)

    it
        "covers the byte string lengths around the chunk size for a termination"
        $ do
            let keyLengths =
                    [ BS.length key
                    | TerminationApproval _ key <- vectorInput <$> vectors
                    ]
            forM_ [0, 64, 65, 129] $ \len ->
                (len, len `elem` keyLengths) `shouldBe` (len, True)

    it
        "holds two registries that differ only in the policy and only in the name"
        $ do
            let terminations =
                    [ (registry, key)
                    | TerminationApproval registry key <- vectorInput <$> vectors
                    ]
                differing field =
                    [ (a, b)
                    | (a, keyA) <- terminations
                    , (b, keyB) <- terminations
                    , keyA == keyB
                    , field a /= field b
                    ]
                policy (RegistryIdentity p _) = p
                name (RegistryIdentity _ n) = n
                onlyIn same (a, b) = same a == same b
            any (onlyIn name) (differing policy) `shouldBe` True
            any (onlyIn policy) (differing name) `shouldBe` True

    it
        "sets a termination vector beside the active and registration vectors of its registry and key"
        $ do
            let beside t = [o | o <- vectors, isOtherRole o, sameFacts t o]
                isOtherRole o = vectorRole o `elem` ["active", "registration-approval"]
                sameFacts t o = facts (vectorInput t) == facts (vectorInput o)
                facts = \case
                    TerminationApproval registry key -> Just (registry, key)
                    Active registry key -> Just (registry, key)
                    RegistrationApproval registry key _ _ _ -> Just (registry, key)
                    _ -> Nothing
                roles t = vectorRole <$> beside t
                terminations = [v | v <- vectors, vectorRole v == "termination-approval"]
            -- the pairing is not empty: some termination has both roles beside it
            any
                ( \t -> "active" `elem` roles t && "registration-approval" `elem` roles t
                )
                terminations
                `shouldBe` True

reproductionRows :: [Vector] -> Spec
reproductionRows vectors = describe "the codec reproduces every vector" $
    forM_ vectors $ \v -> describe (T.unpack (vectorId v)) $ do
        it "serialises to the bytes of the vector" $
            encodePreimage (vectorInput v) `shouldBe` vectorPreimage v
        it "names the token of the vector" $
            nameBytes (roleName (vectorInput v)) `shouldBe` vectorName v
        it "names it by the function of its role" $
            nameBytes (nameByFunction (vectorInput v)) `shouldBe` vectorName v
        case vectorInput v of
            TerminationApproval registry key ->
                it "builds its preimage by the function of its role" $
                    terminationPreimage key registry `shouldBe` vectorPreimage v
            _ -> pure ()

separationRows :: [Vector] -> Spec
separationRows vectors = describe "the roles are separated" $ do
    it "gives no two vectors the same preimage" $
        distinct (encodePreimage . vectorInput <$> vectors) `shouldBe` True

    it "gives no two vectors the same name" $
        distinct (nameBytes . roleName . vectorInput <$> vectors)
            `shouldBe` True

    it
        "opens every preimage with the constructor the model numbers for its role"
        $ forM_ vectors
        $ \v -> do
            term <- termOf (encodePreimage (vectorInput v))
            (vectorId v, constructorTag term)
                `shouldBe` ( vectorId v
                           , Just (121 + constructorIndex (vectorInput v))
                           )

    it "numbers the reserved constructors as the model" $ do
        let registry = registryIn vectors
        terms <-
            mapM
                (termOf . encodePreimage)
                [ ApplicationConfiguration registry
                , TerminationApproval registry BS.empty
                ]
        constructorTag <$> terms `shouldBe` [Just 123, Just 125]

    it
        "tells an active preimage from a termination preimage of the same fields"
        $ forM_
            [ (registry, key) | Vector{vectorInput = Active registry key} <- vectors
            ]
        $ \(registry, key) -> do
            let active = Active registry key
                termination = TerminationApproval registry key
            encodePreimage active `shouldNotBe` encodePreimage termination
            roleName active `shouldNotBe` roleName termination

    it
        "names a termination apart from the active token and every registration approval of its registry and key"
        $ forM_ vectors
        $ \v -> case vectorInput v of
            TerminationApproval registry key -> do
                let name = nameBytes (approvalName (terminationPreimage key registry))
                    others =
                        [ vectorName o
                        | o <- vectors
                        , vectorRole o `elem` ["active", "registration-approval"]
                        , sameFacts (vectorInput o) registry key
                        ]
                    sameFacts input r k = case input of
                        Active r' k' -> (r', k') == (r, k)
                        RegistrationApproval r' k' _ _ _ -> (r', k') == (r, k)
                        _ -> False
                ( vectorId v
                    , name == vectorName v
                    , name `elem` others
                    , name == nameBytes (activeTokenName registry key)
                    )
                    `shouldBe` (vectorId v, True, False, False)
            _ -> pure ()

    it "names another token for a preimage without its role constructor" $
        forM_ vectors $ \v -> do
            let input = vectorInput v
                name = nameBytes (roleName input)
                withoutConstructor = BS.drop 2 (encodePreimage input)
            -- the control: the name is the hash of the whole preimage
            (vectorId v, blake2b (encodePreimage input))
                `shouldBe` (vectorId v, name)
            (vectorId v, blake2b withoutConstructor)
                `shouldNotBe` (vectorId v, name)

    it "names another token for the bare seed of a state" $
        forM_ [seed | Vector{vectorInput = State seed} <- vectors] $
            \seed@(TxIn (TxId hash) (TxIx index)) -> do
                let bareSeed =
                        BL.toStrict . serialise $
                            Constr
                                0
                                [ B (hashToBytes (extractHash hash))
                                , I (fromIntegral index)
                                ]
                    name = nameBytes (stateTokenName seed)
                -- the control: the name is the hash of the state preimage
                blake2b (encodePreimage (State seed)) `shouldBe` name
                blake2b bareSeed `shouldNotBe` name

distinct :: (Ord a) => [a] -> Bool
distinct xs = Set.size (Set.fromList xs) == length xs

registryIn :: [Vector] -> RegistryIdentity
registryIn vectors = case [r | Vector{vectorInput = Active r _} <- vectors] of
    registry : _ -> registry
    [] -> error "the table holds no active vector"
