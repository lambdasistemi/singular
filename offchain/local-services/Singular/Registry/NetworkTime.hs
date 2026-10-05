{-# LANGUAGE DataKinds #-}

{- |
Module      : Singular.Registry.NetworkTime
Description : Pure conversions over validated, pinned network data
License     : Apache-2.0

The trusted manifest pins exact genesis and node era-history bytes. Validation
binds their network, start time and captured horizon before any conversion.
The final era's end is opened under NOTE030; its slot length and epoch size
stay pinned. Builders must check the provider's protocol major against the pin.
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
    , networkProtocolMajor
    , validateProtocolMajor
    , ledgerHorizon
    , capValidityUpper
    ) where

import Control.Exception (Exception)
import Control.Monad (unless, when)
import Control.Monad.Trans.Except (runExcept)
import Crypto.Hash (Digest, SHA256, hash)
import Data.Aeson
    ( FromJSON (..)
    , eitherDecodeStrict'
    , withObject
    , withScientific
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
import Data.Word (Word32, Word64)

import Cardano.Slotting.EpochInfo
    ( EpochInfo
    , epochInfoEpoch
    , epochInfoFirst
    , hoistEpochInfo
    )
import Cardano.Slotting.Slot
    ( EpochNo (..)
    , EpochSize (..)
    , SlotNo (..)
    )
import Cardano.Slotting.Time (RelativeTime (..), SystemStart (..))
import Codec.Serialise
    ( DeserialiseFailure
    , deserialiseOrFail
    , serialise
    )
import Ouroboros.Consensus.HardFork.History.EpochInfo
    ( interpreterToEpochInfo
    )
import Ouroboros.Consensus.HardFork.History.EraParams (EraParams (..))
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
    , timeProtocolMajor :: Word64
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
            <*> value .: "protocolMajor"
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
    | TimeBeforeHistory Integer
    | EraBeyondPinned Word64 Word64
    | WindowPastLedgerHorizon SlotNo SlotNo (Maybe SlotNo) SlotNo
    deriving stock (Eq, Show)

instance Exception NetworkTimeFailure

type NetworkEras = '[(), (), (), (), (), (), (), ()]

-- | A validated immutable context. Its constructor is private.
data NetworkTime = NetworkTime
    { timeInterpreter :: Interpreter NetworkEras
    , networkSystemStart :: SystemStart
    , networkMagic :: Word32
    , networkProtocolMajor :: Word64
    , ledgerSecurityParam :: Integer
    , ledgerActiveSlotsCoeff :: Rational
    , ledgerEpochLength :: Integer
    }

data GenesisIdentity
    = GenesisIdentity Word32 SystemStart Word64 Rational Word64

instance FromJSON GenesisIdentity where
    parseJSON = withObject "network genesis" $ \value ->
        GenesisIdentity
            <$> value .: "networkMagic"
            <*> (SystemStart <$> value .: "systemStart")
            <*> value .: "securityParam"
            <*> ( value .: "activeSlotsCoeff"
                    >>= withScientific "active slot coefficient" (pure . toRational)
                )
            <*> value .: "epochLength"

{- | Bind exact generated genesis and the held node's raw history. This
factory is solely for magic 42; public preprod uses its reviewed package.
The source determines the recorded finite end and protocol major. Conversion
opens only the final era's end; the captured bytes remain unchanged.
-}
generatedNetworkTime
    :: Word32
    -> Word64
    -> Text
    -> ByteString
    -> ByteString
    -> Either NetworkTimeFailure NetworkTime
generatedNetworkTime requested major source genesis history = do
    unless (requested == 42) (Left (UnknownTimeNetwork requested))
    GenesisIdentity actual (SystemStart start) _ _ _ <-
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
                , timeProtocolMajor = major
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
    GenesisIdentity actual start@(SystemStart utcStart) k f epochLength <-
        first (InvalidTimeGenesis . Text.pack) (eitherDecodeStrict' genesis)
    unless
        (k > 0 && f > 0 && f <= 1 && epochLength > 0)
        (Left (InvalidTimeGenesis "invalid ledger horizon parameters"))
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
    case reverse eras of
        finalEra : _ ->
            unless
                (eraEpochSize (eraParams finalEra) == EpochSize epochLength)
                (Left (TimeSourceMismatch "genesis and final-era epoch length"))
        [] -> Left (InvalidEraHistory "empty era extent")
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
    openSummary <-
        first
            (InvalidEraHistory . Text.pack . show)
            ( deserialiseOrFail (serialise (openFinalEra eras))
                :: Either DeserialiseFailure (Summary NetworkEras)
            )
    pure
        ( NetworkTime
            (mkInterpreter openSummary)
            start
            requested
            (timeProtocolMajor manifest)
            (toInteger k)
            f
            (toInteger epochLength)
        )
  where
    openFinalEra [finalEra] = [finalEra{eraEnd = EraUnbounded}]
    openFinalEra (era : rest) = era : openFinalEra rest
    openFinalEra [] = []
    skippedAtGenesis era =
        boundSlot (eraStart era) == 0
            && boundEpoch (eraStart era) == EpochNo 0
            && getRelativeTime (boundTime (eraStart era)) == 0
            && eraEnd era == EraEnd (eraStart era)
    checkHash name expected bytes =
        unless
            (expected == convert (hash bytes :: Digest SHA256))
            (Left (TimeSourceMismatch name))

-- | Floor conversion over the pinned history with an open final era.
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
timeInSlot context ms = do
    when (relativeMs < 0) (Left (TimeBeforeHistory ms))
    first (const (TimePastHorizon ms)) $
        interpretQuery (timeInterpreter context) (wallclockToSlot relative)
  where
    SystemStart start = networkSystemStart context
    relativeMs = fromInteger ms / 1000 - utcTimeToPOSIXSeconds start
    relative = RelativeTime relativeMs

-- | Named era safety refusal. This must run on raw parameters before building.
validateProtocolMajor
    :: NetworkTime -> Word64 -> Either NetworkTimeFailure ()
validateProtocolMajor context actual =
    unless (actual == networkProtocolMajor context) $
        Left (EraBeyondPinned (networkProtocolMajor context) actual)

{- | The moving ledger translation limit, independently of the captured
history's end. Arithmetic stays unbounded until the checked SlotNo result.
The epoch anchor comes from the pinned history; the size comes from genesis.
-}
ledgerHorizon
    :: NetworkTime -> SlotNo -> Either NetworkTimeFailure SlotNo
ledgerHorizon context tip = do
    future <-
        checkedSlot
            ( toInteger (unSlotNo tip)
                + ceiling
                    ( fromInteger (3 * ledgerSecurityParam context)
                        / ledgerActiveSlotsCoeff context
                    )
            )
    epoch <-
        first
            InvalidEraHistory
            (epochInfoEpoch (networkEpochInfo context) future)
    anchor <-
        first
            InvalidEraHistory
            (epochInfoFirst (networkEpochInfo context) epoch)
    checkedSlot $
        if future == anchor
            then toInteger (unSlotNo anchor)
            else toInteger (unSlotNo anchor) + ledgerEpochLength context
  where
    checkedSlot n
        | n >= 0 && n <= toInteger (maxBound :: Word64) =
            Right (SlotNo (fromInteger n))
        | otherwise =
            Left (TimeSourceMismatch "ledger horizon exceeds slot range")

{- | Select an exclusive upper bound inside the existing window and observed
ledger horizon, with a usable slot after the observed tip. An omitted body
lower adds no constraint. The refusal retains the actual optional window.
-}
capValidityUpper
    :: NetworkTime
    -> SlotNo
    -> Maybe SlotNo
    -> SlotNo
    -> Either NetworkTimeFailure SlotNo
capValidityUpper context tip lower upper = do
    horizon <- ledgerHorizon context tip
    let capped = min upper (horizon - 1)
        effectiveLower =
            max
                (maybe 0 (toInteger . unSlotNo) lower)
                (toInteger (unSlotNo tip) + 1)
    if toInteger (unSlotNo capped) <= effectiveLower
        then Left (WindowPastLedgerHorizon tip horizon lower upper)
        else Right capped

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

-- | The ledger evaluator uses the same pinned, open-final-era interpreter.
networkEpochInfo :: NetworkTime -> EpochInfo (Either Text)
networkEpochInfo context =
    hoistEpochInfo
        (first (Text.pack . show) . runExcept)
        (interpreterToEpochInfo (timeInterpreter context))
