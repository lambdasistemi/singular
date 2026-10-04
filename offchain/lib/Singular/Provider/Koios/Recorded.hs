{-# OPTIONS_GHC -Wno-redundant-constraints #-}

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

import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as BSL
import Data.Text (Text)
import Data.Time (UTCTime)

import Singular.Provider.Koios.Client
    ( Answer
    , RawRequest
    , Transport
    )
import Singular.Provider.Koios.Wire (Body, Call, Method)

{- | The part of a request a fixture is keyed by: call, method, path,
query and body. Headers, such as a bearer token, are never part of it.
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
fixtureRequestOf = notImplemented

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
fixtureFileName = notImplemented

-- | The JSON text of a fixture.
encodeFixture :: Fixture -> BSL.ByteString
encodeFixture = notImplemented

-- | Read a fixture's JSON text.
decodeFixture :: BSL.ByteString -> Either Text Fixture
decodeFixture = notImplemented

-- | Hex SHA-256 of an answer body.
bodySha256 :: ByteString -> Text
bodySha256 = notImplemented

-- | A loaded fixture directory, all under one schema revision.
data FixtureSet = FixtureSet
    { setRevision :: Text
    , setFixtures :: [Fixture]
    }
    deriving stock (Eq, Show)

-- | Why a fixture directory cannot be used.
data FixtureFailure
    = -- | A file that is not a fixture
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
loadFixtureSet = notImplemented

-- | Answer each request from the set; one attempt per request.
recordedTransport :: (Applicative m) => FixtureSet -> Transport m
recordedTransport = notImplemented

notImplemented :: a
notImplemented = error "Singular.Provider.Koios.Recorded: not implemented"
