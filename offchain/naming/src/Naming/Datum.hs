{-# LANGUAGE DerivingStrategies #-}

-- | The four-field naming datum codec, transcribed exactly from the
-- accepted epic-15 contract's @simulator/naming-wire.mjs@ (v0.2.0, commit
-- @13231f58833b8feb57f4b0f9b1117bfcfba0c07d@, asset sha256
-- @acbabdf54a271251bd73bf9d84ab2c901107045a7dd77d28a391f22cdd53b0e5@).
--
-- The datum has exactly four fields, in this order: 'controlAddress';
-- 'paymentDestination' as an option (@constr(0,[])@ none,
-- @constr(1,[bytes])@ some); the 'nextControlCommitment' 32-byte digest;
-- and the 'retirementQuorum'. There is no fifth field and none may be
-- added. Where this module and the reference disagree, the reference is
-- right and this module is wrong.
module Naming.Datum
  ( PaymentDestination (..)
  , RetirementQuorum (..)
  , NamingDatum (..)
  , DatumAttachment (..)
  , DatumShape (..)
  , encodeNamingDatum
  , decodeNamingDatum
  , namingDatumShape
  , serialiseNamingDatum
  , deserialiseNamingDatum
  , extractNamingDatum
  ) where

import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.List (nub)

import Naming.Wire
    ( Address (..)
    , PaymentCredential (..)
    , WireData (..)
    , canonicalAddress
    , decodeAddress
    , deserialiseWireData
    , guardWire
    , serialiseWireData
    )

-- | The payment destination option: none is @constr(0,[])@, some is
-- @constr(1,[bytes])@.
data PaymentDestination
  = NoDestination
  | SomeDestination Address
  deriving stock (Eq, Show)

-- | The retirement quorum: distinct 28-byte member key hashes and a
-- threshold between 1 and the member count.
data RetirementQuorum = RetirementQuorum
  { quorumMembers :: [ByteString]
  , quorumThreshold :: Integer
  }
  deriving stock (Eq, Show)

-- | The four-field naming datum. The field names are the contract's
-- own; the datum has no fifth field.
data NamingDatum = NamingDatum
  { controlAddress :: Address
  , paymentDestination :: PaymentDestination
  , nextControlCommitment :: ByteString
  , retirementQuorum :: RetirementQuorum
  }
  deriving stock (Eq, Show)

-- | How a datum is attached to an output: inline, or as a hash. The
-- contract accepts only inline.
data DatumAttachment
  = InlineDatum WireData
  | AttachedDatumHash ByteString
  deriving stock (Eq, Show)

-- | The structural shape the contract records for the canonical datum:
-- @{arity: 4, innerIndex: 0, outerIndex: 0}@.
data DatumShape = DatumShape
  { shapeArity :: Int
  , shapeInnerIndex :: Int
  , shapeOuterIndex :: Int
  }
  deriving stock (Eq, Show)

-- | Exact mirror of the contract's @encodeNamingDatum@.
encodeNamingDatum :: NamingDatum -> WireData
encodeNamingDatum fixture =
  Constr 0
    [ Constr 0
        [ WBytes (addressBytes (controlAddress fixture))
        , encodePaymentDestination (paymentDestination fixture)
        , WBytes (nextControlCommitment fixture)
        , encodeRetirementQuorum (retirementQuorum fixture)
        ]
    ]

-- | Exact mirror of the contract's @encodePaymentDestination@.
encodePaymentDestination :: PaymentDestination -> WireData
encodePaymentDestination NoDestination = Constr 0 []
encodePaymentDestination (SomeDestination a) = Constr 1 [WBytes (addressBytes a)]

-- | Exact mirror of the contract's @encodeRetirementQuorum@.
encodeRetirementQuorum :: RetirementQuorum -> WireData
encodeRetirementQuorum q =
  Constr 0 [WInt (quorumThreshold q), WList (map WBytes (quorumMembers q))]

-- | Exact mirror of the contract's @decodeNamingDatum@: outer
-- @constr(0)@ of arity 1 wrapping an inner @constr(0)@ of arity 4, then
-- each field decoded and the whole checked with the contract's
-- @wellFormedFixture@. Anything else is refused.
decodeNamingDatum :: WireData -> Maybe NamingDatum
decodeNamingDatum (Constr 0 [inner]) = decodeInner inner
decodeNamingDatum _ = Nothing

decodeInner :: WireData -> Maybe NamingDatum
decodeInner (Constr 0 [controlData, destinationData, commitmentData, quorumData]) = do
  controlBytes <- asBytes controlData
  commitment <- asBytes commitmentData
  guardWire (BS.length commitment == 32)
  control <- decodeAddress controlBytes
  destination <- decodePaymentDestination destinationData
  quorum <- decodeRetirementQuorum quorumData
  let fixture =
        NamingDatum
          { controlAddress = control
          , paymentDestination = destination
          , nextControlCommitment = commitment
          , retirementQuorum = quorum
          }
  guardWire (wellFormedFixture fixture)
  pure fixture
decodeInner _ = Nothing

asBytes :: WireData -> Maybe ByteString
asBytes (WBytes b) = Just b
asBytes _ = Nothing

-- | Exact mirror of the contract's @decodePaymentDestination@: only
-- @constr(0,[])@ and @constr(1,[bytes])@ with a decodable address are
-- accepted.
decodePaymentDestination :: WireData -> Maybe PaymentDestination
decodePaymentDestination (Constr 0 []) = pure NoDestination
decodePaymentDestination (Constr 1 [WBytes destinationBytes]) =
  SomeDestination <$> decodeAddress destinationBytes
decodePaymentDestination _ = Nothing

-- | Exact mirror of the contract's @decodeRetirementQuorum@:
-- @constr(0,[integer, list])@, non-negative threshold, every member a
-- 28-byte key hash.
decodeRetirementQuorum :: WireData -> Maybe RetirementQuorum
decodeRetirementQuorum (Constr 0 [WInt threshold, WList memberData])
  | threshold >= 0 = do
      members <- traverse asQuorumMember memberData
      pure (RetirementQuorum {quorumMembers = members, quorumThreshold = threshold})
decodeRetirementQuorum _ = Nothing

asQuorumMember :: WireData -> Maybe ByteString
asQuorumMember (WBytes m)
  | BS.length m == 28 = Just m
asQuorumMember _ = Nothing

-- | Exact mirror of the contract's @wellFormedFixture@ (its
-- @fixtureShape@ plus the destination/control difference): the control
-- address is a canonical payment-key address, the payment destination is
-- canonical and never equal to the control address, the commitment is 32
-- bytes, and the threshold is between 1 and the number of distinct
-- members.
wellFormedFixture :: NamingDatum -> Bool
wellFormedFixture f =
  canonicalAddress (controlAddress f)
    && addressPaymentCredential (controlAddress f) == PaymentKey
    && destinationCanonical
    && BS.length (nextControlCommitment f) == 32
    && quorumThreshold q > 0
    && quorumThreshold q <= fromIntegral (length (nub (quorumMembers q)))
    && paymentDestination f /= SomeDestination (controlAddress f)
  where
    q = retirementQuorum f
    destinationCanonical = case paymentDestination f of
      NoDestination -> True
      SomeDestination a -> canonicalAddress a

-- | Exact mirror of the contract's @namingDatumShape@.
namingDatumShape :: WireData -> Maybe DatumShape
namingDatumShape (Constr 0 [Constr 0 fields]) =
  Just DatumShape {shapeArity = length fields, shapeInnerIndex = 0, shapeOuterIndex = 0}
namingDatumShape _ = Nothing

-- | Exact mirror of the contract's @serialiseNamingDatum@.
serialiseNamingDatum :: NamingDatum -> Maybe ByteString
serialiseNamingDatum = serialiseWireData . encodeNamingDatum

-- | Exact mirror of the contract's @deserialiseNamingDatum@.
deserialiseNamingDatum :: ByteString -> Maybe NamingDatum
deserialiseNamingDatum input = do
  datum <- deserialiseWireData input
  decodeNamingDatum datum

-- | Exact mirror of the contract's @extractNamingDatum@: only an inline
-- datum is decoded; an attached datum hash is refused.
extractNamingDatum :: DatumAttachment -> Maybe NamingDatum
extractNamingDatum (InlineDatum d) = decodeNamingDatum d
extractNamingDatum (AttachedDatumHash _) = Nothing
