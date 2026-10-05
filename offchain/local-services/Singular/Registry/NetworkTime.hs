{-# LANGUAGE DataKinds #-}

{- |
Module      : Singular.Registry.NetworkTime
Description : Pure conversions over validated, pinned network data
License     : Apache-2.0

The trusted manifest pins exact genesis and node era-history bytes. Validation
binds their network, start time and finite horizon before any conversion. The
consensus interpreter supplies the arithmetic; no safe zone is extended.
-}
module Singular.Registry.NetworkTime
    ( NetworkTime
    , NetworkTimeManifest (..)
    , NetworkTimeFailure (..)
    , validateNetworkTime
    , generatedNetworkTime
    , posixMsFloorSlot
    , posixMsCeilingSlot
    , slotStartMs
    , networkEpochInfo
    , networkSystemStart
    , networkMagic
    ) where

import Control.Exception (Exception)
import Control.Monad (unless, when)
import Control.Monad.Trans.Except (runExcept)
import Crypto.Hash (Digest, SHA256, hash)
import Data.Aeson
    ( FromJSON (..)
    , eitherDecodeStrict'
    , withObject
    , (.:)
    )
import Data.Bifunctor (first)
import Data.ByteArray (convert)
import Data.ByteString (ByteString)
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Lazy qualified as LBS
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding (encodeUtf8)
import Data.Time.Clock (NominalDiffTime)
import Data.Time.Clock.POSIX (utcTimeToPOSIXSeconds)
import Data.Word (Word32)

import Cardano.Slotting.EpochInfo (EpochInfo, hoistEpochInfo)
import Cardano.Slotting.Slot (EpochNo (..), SlotNo)
import Cardano.Slotting.Time (RelativeTime (..), SystemStart (..))
import Codec.Serialise
    ( DeserialiseFailure
    , deserialiseOrFail
    , serialise
    )
import Ouroboros.Consensus.HardFork.History.EpochInfo
    ( interpreterToEpochInfo
    )
import Ouroboros.Consensus.HardFork.History.Qry
    ( Interpreter
    , interpretQuery
    , mkInterpreter
    , slotToWallclock
    , wallclockToSlot
    )
import Ouroboros.Consensus.HardFork.History.Summary
    ( Bound (..)
    , EraEnd (..)
    , EraSummary (..)
    , Summary
    , invariantSummary
    , summaryBounds
    )

{- | Trusted source identities, supplied by the reviewed packaged manifest
or materialized from the exact private-devnet generator output.
-}
data NetworkTimeManifest = NetworkTimeManifest
    { timeNetworkMagic :: Word32
    , timeSystemStartMs :: Integer
    , timeGenesisSha256 :: ByteString
    , timeEraHistorySha256 :: ByteString
    , timeHorizonSlot :: SlotNo
    , timeSourceIdentity :: Text
    }
    deriving stock (Eq, Show)

instance FromJSON NetworkTimeManifest where
    parseJSON = withObject "network time source manifest" $ \value ->
        NetworkTimeManifest
            <$> value .: "networkMagic"
            <*> value .: "systemStartMs"
            <*> (value .: "genesisSha256" >>= hashBytes)
            <*> (value .: "eraHistorySha256" >>= hashBytes)
            <*> value .: "horizonSlot"
            <*> value .: "sourceIdentity"
      where
        hashBytes = either fail pure . B16.decode . encodeUtf8

-- | Named validation and range refusals; never an estimated answer.
data NetworkTimeFailure
    = UnknownTimeNetwork Word32
    | WrongTimeNetwork Word32 Word32
    | TimeSourceMismatch Text
    | InvalidTimeGenesis Text
    | InvalidEraHistory Text
    | MissingTimeHorizon
    | TimePastHorizon Integer
    | SlotPastHorizon SlotNo
    deriving stock (Eq, Show)

instance Exception NetworkTimeFailure

type NetworkEras = '[(), (), (), (), (), (), (), ()]

-- | A validated immutable context. Its constructor is private.
data NetworkTime = NetworkTime
    { timeInterpreter :: Interpreter NetworkEras
    , networkSystemStart :: SystemStart
    , networkMagic :: Word32
    }

data GenesisIdentity = GenesisIdentity Word32 SystemStart

instance FromJSON GenesisIdentity where
    parseJSON = withObject "network genesis" $ \value ->
        GenesisIdentity
            <$> value .: "networkMagic"
            <*> (SystemStart <$> value .: "systemStart")

{- | Bind exact generated genesis and the held node's raw history. This
factory is solely for magic 42; public preprod uses its reviewed package.
The source determines the finite end; no caller supplies a larger horizon.
-}
generatedNetworkTime
    :: Word32
    -> Text
    -> ByteString
    -> ByteString
    -> Either NetworkTimeFailure NetworkTime
generatedNetworkTime requested source genesis history = do
    unless (requested == 42) (Left (UnknownTimeNetwork requested))
    GenesisIdentity actual (SystemStart start) <-
        first (InvalidTimeGenesis . Text.pack) (eitherDecodeStrict' genesis)
    summary <-
        first
            (InvalidEraHistory . Text.pack . show)
            ( deserialiseOrFail (LBS.fromStrict history)
                :: Either DeserialiseFailure (Summary NetworkEras)
            )
    horizon <- case snd (summaryBounds summary) of
        EraUnbounded -> Left MissingTimeHorizon
        EraEnd end -> Right (boundSlot end)
    let digest bytes = convert (hash bytes :: Digest SHA256)
        manifest =
            NetworkTimeManifest
                { timeNetworkMagic = actual
                , timeSystemStartMs = floor (utcTimeToPOSIXSeconds start * 1000)
                , timeGenesisSha256 = digest genesis
                , timeEraHistorySha256 = digest history
                , timeHorizonSlot = horizon
                , timeSourceIdentity = source
                }
    validateNetworkTime requested manifest genesis history

-- | Validate every advertised byte identity before decoding the history.
validateNetworkTime
    :: Word32
    -> NetworkTimeManifest
    -> ByteString
    -> ByteString
    -> Either NetworkTimeFailure NetworkTime
validateNetworkTime requested manifest genesis history = do
    unless
        (requested == 1 || requested == 42)
        (Left (UnknownTimeNetwork requested))
    unless
        (requested == timeNetworkMagic manifest)
        (Left (WrongTimeNetwork requested (timeNetworkMagic manifest)))
    when
        (Text.null (timeSourceIdentity manifest))
        (Left (TimeSourceMismatch "source identity is absent"))
    checkHash "genesis" (timeGenesisSha256 manifest) genesis
    checkHash "era history" (timeEraHistorySha256 manifest) history
    GenesisIdentity actual start@(SystemStart utcStart) <-
        first (InvalidTimeGenesis . Text.pack) (eitherDecodeStrict' genesis)
    unless
        (actual == requested)
        (Left (WrongTimeNetwork requested actual))
    unless
        ( floor (utcTimeToPOSIXSeconds utcStart * 1000)
            == timeSystemStartMs manifest
        )
        (Left (TimeSourceMismatch "genesis system start"))
    eras <-
        first
            (InvalidEraHistory . Text.pack . show)
            ( deserialiseOrFail (LBS.fromStrict history)
                :: Either DeserialiseFailure [EraSummary]
            )
    unless
        (not (null eras) && length eras <= 8)
        (Left (InvalidEraHistory "empty or unsupported era extent"))
    summary <-
        first
            (InvalidEraHistory . Text.pack . show)
            ( deserialiseOrFail (LBS.fromStrict history)
                :: Either DeserialiseFailure (Summary NetworkEras)
            )
    -- A generated Cardano devnet skips historical eras at genesis. The
    -- consensus interpreter accepts that zero-duration prefix; its generic
    -- summary invariant expects every era to be nonempty. Validate the
    -- remaining eras with that invariant, without changing the interpreter.
    let activeEras = dropWhile skippedAtGenesis eras
    when
        (null activeEras)
        (Left (InvalidEraHistory "history contains no active era"))
    activeSummary <-
        first
            (InvalidEraHistory . Text.pack . show)
            ( deserialiseOrFail (serialise activeEras)
                :: Either DeserialiseFailure (Summary NetworkEras)
            )
    first
        (InvalidEraHistory . Text.pack)
        (runExcept (invariantSummary activeSummary))
    let (beginning, end) = summaryBounds summary
    unless
        (boundSlot beginning == 0 && getRelativeTime (boundTime beginning) == 0)
        (Left (InvalidEraHistory "history does not start at genesis"))
    horizon <- case end of
        EraUnbounded -> Left MissingTimeHorizon
        EraEnd bound -> Right (boundSlot bound)
    unless
        (horizon == timeHorizonSlot manifest)
        (Left (TimeSourceMismatch "conversion horizon"))
    pure (NetworkTime (mkInterpreter summary) start requested)
  where
    skippedAtGenesis era =
        boundSlot (eraStart era) == 0
            && boundEpoch (eraStart era) == EpochNo 0
            && getRelativeTime (boundTime (eraStart era)) == 0
            && eraEnd era == EraEnd (eraStart era)
    checkHash name expected bytes =
        unless
            (expected == convert (hash bytes :: Digest SHA256))
            (Left (TimeSourceMismatch name))

{- | Floor conversion. Times before genesis retain the existing slot-zero
clamp; a time at or beyond the finite horizon refuses.
-}
posixMsFloorSlot
    :: NetworkTime -> Integer -> Either NetworkTimeFailure SlotNo
posixMsFloorSlot context ms = do
    (slot, _, _) <- timeInSlot context ms
    pure slot

-- | Ceiling conversion; an exact slot boundary equals its floor.
posixMsCeilingSlot
    :: NetworkTime -> Integer -> Either NetworkTimeFailure SlotNo
posixMsCeilingSlot context ms = do
    (slot, elapsed, _) <- timeInSlot context ms
    pure (if elapsed == 0 then slot else slot + 1)

timeInSlot
    :: NetworkTime
    -> Integer
    -> Either NetworkTimeFailure (SlotNo, NominalDiffTime, NominalDiffTime)
timeInSlot context ms =
    first (const (TimePastHorizon ms)) $
        interpretQuery (timeInterpreter context) (wallclockToSlot relative)
  where
    SystemStart start = networkSystemStart context
    relative =
        RelativeTime
            (max 0 (fromInteger ms / 1000 - utcTimeToPOSIXSeconds start))

-- | POSIX milliseconds at a slot's start, using the same pinned history.
slotStartMs
    :: NetworkTime -> SlotNo -> Either NetworkTimeFailure Integer
slotStartMs context slot = do
    (relative, _) <-
        first (const (SlotPastHorizon slot)) $
            interpretQuery (timeInterpreter context) (slotToWallclock slot)
    let SystemStart start = networkSystemStart context
    pure
        ( floor
            ((utcTimeToPOSIXSeconds start + getRelativeTime relative) * 1000)
        )

-- | The ledger evaluator's epoch information over the unchanged interpreter.
networkEpochInfo :: NetworkTime -> EpochInfo (Either Text)
networkEpochInfo context =
    hoistEpochInfo
        (first (Text.pack . show) . runExcept)
        (interpreterToEpochInfo (timeInterpreter context))
