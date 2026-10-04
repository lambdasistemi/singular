{-# LANGUAGE LambdaCase #-}

{- |
Module      : Singular.Provider.Koios.Recorded
Description : A Koios transport answering from recorded fixtures
License     : Apache-2.0

A 'Transport' that answers each request from a fixture directory
recorded from a live Koios service by the @koios-http@ recorder. The
answers are raw — status, headers and body — so the client pages and
decodes them exactly as it does live answers.

Each fixture is one JSON file holding the request, the Koios schema
revision, the time of recording, the SHA-256 of the answer body and the
answer. Loading a directory refuses a fixture whose body does not match
its hash, a set whose fixtures disagree on the schema revision, two
fixtures for one request, and an empty directory. A request with no
fixture is answered by 'NoRecording', which the client reports as
'Singular.Provider.Koios.Client.NotRecorded'.
-}
module Singular.Provider.Koios.Recorded
    ( -- * Fixtures
      Fixture (..)
    , FixtureRequest (..)
    , fixtureRequestOf
    , fixtureFileName
    , encodeFixture
    , decodeFixture
    , bodySha256

      -- * Fixture sets
    , FixtureSet (..)
    , FixtureFailure (..)
    , loadFixtureSet

      -- * Transport
    , recordedTransport
    ) where

import Control.Exception (IOException, try)
import Crypto.Hash (Digest, SHA256, hash)
import Data.Aeson
    ( Value (..)
    , eitherDecode
    , object
    , withObject
    , (.:)
    , (.=)
    )
import Data.Aeson.Encode.Pretty (encodePretty)
import Data.Aeson.KeyMap qualified as KM
import Data.Aeson.Types (Parser, parseEither)
import Data.ByteArray.Encoding (Base (Base16), convertToBase)
import Data.ByteString (ByteString)
import Data.ByteString.Base16 qualified as Base16
import Data.ByteString.Lazy qualified as BSL
import Data.List (find, isSuffixOf, nub, sort)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (UTCTime)
import System.Directory (listDirectory)
import System.FilePath ((</>))

import Singular.Provider.Koios.Client
    ( Answer (..)
    , Exchange (..)
    , NoAnswer (..)
    , RawRequest (..)
    , Transport (..)
    )
import Singular.Provider.Koios.Wire
    ( Body (..)
    , Call
    , Method (..)
    , callName
    )

{- | The part of a request a fixture is keyed by: call, method, path,
query in sorted order, and body. Headers, such as a bearer token, are
never part of it.
-}
data FixtureRequest = FixtureRequest
    { fixtureCall :: Call
    , fixtureMethod :: Method
    , fixturePath :: Text
    , fixtureQuery :: [(Text, Text)]
    , fixtureBody :: Body
    }
    deriving stock (Eq, Show)

-- | The fixture key of a raw request.
fixtureRequestOf :: RawRequest -> FixtureRequest
fixtureRequestOf raw =
    FixtureRequest
        { fixtureCall = rawCall raw
        , fixtureMethod = rawMethod raw
        , fixturePath = rawPath raw
        , fixtureQuery = sort (rawQuery raw)
        , fixtureBody = rawBody raw
        }

-- | One recorded answer.
data Fixture = Fixture
    { fixtureRequest :: FixtureRequest
    , fixtureRevision :: Text
    -- ^ The Koios schema revision the answer was recorded under
    , fixtureRecordedAt :: UTCTime
    , fixtureSha256 :: Text
    -- ^ Hex SHA-256 of the answer body
    , fixtureAnswer :: Answer
    }
    deriving stock (Eq, Show)

-- | A file name derived from the request alone.
fixtureFileName :: FixtureRequest -> FilePath
fixtureFileName r =
    T.unpack (callName (fixtureCall r))
        <> "-"
        <> take
            16
            (T.unpack (bodySha256 (BSL.toStrict (encodePretty (requestJson r)))))
        <> ".json"

-- | The JSON text of a fixture.
encodeFixture :: Fixture -> BSL.ByteString
encodeFixture f =
    encodePretty $
        object
            [ "request" .= requestJson (fixtureRequest f)
            , "schema_revision" .= fixtureRevision f
            , "recorded_at" .= fixtureRecordedAt f
            , "sha256" .= fixtureSha256 f
            , "answer"
                .= object
                    [ "status" .= answerStatus a
                    , "headers" .= answerHeaders a
                    , "body" .= TE.decodeUtf8Lenient (answerBody a)
                    ]
            ]
  where
    a = fixtureAnswer f

requestJson :: FixtureRequest -> Value
requestJson r =
    object
        [ "call" .= callName (fixtureCall r)
        , "method" .= methodName (fixtureMethod r)
        , "path" .= fixturePath r
        , "query" .= fixtureQuery r
        , "body" .= case fixtureBody r of
            NoBody -> Null
            JsonBody v -> object ["json" .= v]
            CborBody b -> object ["cbor" .= TE.decodeUtf8 (Base16.encode b)]
        ]

methodName :: Method -> Text
methodName = \case
    Get -> "GET"
    Post -> "POST"

-- | Read a fixture's JSON text.
decodeFixture :: BSL.ByteString -> Either Text Fixture
decodeFixture bytes = do
    v <- either (Left . T.pack) Right (eitherDecode bytes)
    either (Left . T.pack) Right (parseEither fixture v)
  where
    fixture = withObject "fixture" $ \o -> do
        req <- o .: "request" >>= requestOf
        answer <- o .: "answer"
        Fixture req
            <$> o .: "schema_revision"
            <*> o .: "recorded_at"
            <*> o .: "sha256"
            <*> answerOf answer
    answerOf = withObject "answer" $ \a ->
        Answer
            <$> a .: "status"
            <*> a .: "headers"
            <*> (TE.encodeUtf8 <$> a .: "body")
    requestOf :: Value -> Parser FixtureRequest
    requestOf = withObject "request" $ \r -> do
        name <- r .: "call"
        call <- case [c | c <- [minBound .. maxBound], callName c == name] of
            c : _ -> pure c
            [] -> fail ("unknown call: " <> T.unpack name)
        method <-
            r .: "method" >>= \case
                "GET" -> pure Get
                "POST" -> pure Post
                other -> fail ("unknown method: " <> T.unpack (other :: Text))
        body <-
            r .: "body" >>= \case
                Null -> pure NoBody
                Object b
                    | Just j <- KM.lookup "json" b -> pure (JsonBody j)
                    | Just (String c) <- KM.lookup "cbor" b ->
                        either fail (pure . CborBody) (Base16.decode (TE.encodeUtf8 c))
                _ -> fail "unknown body"
        FixtureRequest call method
            <$> r .: "path"
            <*> (sort <$> r .: "query")
            <*> pure body

-- | Hex SHA-256 of an answer body.
bodySha256 :: ByteString -> Text
bodySha256 body =
    TE.decodeUtf8 (convertToBase Base16 (hash body :: Digest SHA256))

-- | A loaded fixture directory, all under one schema revision.
data FixtureSet = FixtureSet
    { setRevision :: Text
    , setFixtures :: [Fixture]
    }
    deriving stock (Eq, Show)

-- | Why a fixture directory cannot be used.
data FixtureFailure
    = -- | A file that is not a fixture, or a directory that cannot be read
      FixtureUnreadable FilePath Text
    | -- | A fixture whose body does not hash to its recorded SHA-256
      FixtureHashMismatch FilePath
    | -- | Fixtures recorded under different schema revisions
      RevisionMismatch [(FilePath, Text)]
    | -- | Two fixtures for one request
      DuplicateRequest FilePath FilePath
    | -- | A directory with no fixture
      NoFixtures FilePath
    deriving stock (Eq, Show)

-- | Load every @.json@ fixture of a directory.
loadFixtureSet :: FilePath -> IO (Either FixtureFailure FixtureSet)
loadFixtureSet dir =
    try (listDirectory dir) >>= \case
        Left e ->
            pure (Left (FixtureUnreadable dir (T.pack (show (e :: IOException)))))
        Right entries -> do
            let names = sort (filter (".json" `isSuffixOf`) entries)
            loaded <- traverse load names
            pure (sequence loaded >>= assemble)
  where
    load name = do
        let path = dir </> name
        bytes <- BSL.readFile path
        pure $ case decodeFixture bytes of
            Left e -> Left (FixtureUnreadable path e)
            Right f
                | bodySha256 (answerBody (fixtureAnswer f)) /= fixtureSha256 f ->
                    Left (FixtureHashMismatch path)
                | otherwise -> Right (path, f)
    assemble = \case
        [] -> Left (NoFixtures dir)
        loaded@((_, first') : _)
            | length (nub (map (fixtureRevision . snd) loaded)) > 1 ->
                Left (RevisionMismatch [(p, fixtureRevision f) | (p, f) <- loaded])
            | Just (a, b) <- duplicate loaded -> Left (DuplicateRequest a b)
            | otherwise ->
                Right
                    FixtureSet
                        { setRevision = fixtureRevision first'
                        , setFixtures = map snd loaded
                        }
    duplicate loaded =
        case [ (p, q)
             | ((p, f), i) <- zip loaded [0 :: Int ..]
             , ((q, g), j) <- zip loaded [0 ..]
             , i < j
             , fixtureRequest f == fixtureRequest g
             ] of
            d : _ -> Just d
            [] -> Nothing

-- | Answer each request from the set; one attempt per request.
recordedTransport :: (Applicative m) => FixtureSet -> Transport m
recordedTransport set = Transport $ \raw ->
    let key = fixtureRequestOf raw
    in  pure
            Exchange
                { exchangeAttempts = 1
                , exchangeResult =
                    case find ((== key) . fixtureRequest) (setFixtures set) of
                        Just f -> Right (fixtureAnswer f)
                        Nothing -> Left (NoRecording (describe key))
                }
  where
    describe r =
        methodName (fixtureMethod r)
            <> " "
            <> fixturePath r
            <> T.pack (show (fixtureQuery r))
