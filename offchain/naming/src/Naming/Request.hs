{-# LANGUAGE DerivingStrategies #-}

-- | The insert-request commitment codec and the refund comparison for
-- the initial request, transcribed exactly from the accepted epic-15
-- contract's @simulator/naming-wire.mjs@, @core.mjs@ and
-- @lifecycle-corpus.json@ vector @WR01-insert-request-refund-roundtrip@
-- (v0.2.0, commit @13231f58833b8feb57f4b0f9b1117bfcfba0c07d@, asset
-- sha256 @acbabdf54a271251bd73bf9d84ab2c901107045a7dd77d28a391f22cdd53b0e5@).
--
-- The commitment is @constr(0,[constr(0,[registry, key,
-- applicationPolicy, refundAddress, initial output, scope])])@ — six
-- proposal fields, no seventh. Every @constr@ index here is 0 and every
-- number a non-negative integer, exactly as the reference decoders
-- require. Where this module and the reference disagree, the reference
-- is right and this module is wrong.
module Naming.Request
  ( Representative (..)
  , InitialOutput (..)
  , InsertProposal (..)
  , InsertRequestShape (..)
  , RefundReason (..)
  , RefundComparison (..)
  , withdrawRefundAddress
  , encodeInsertCommitment
  , decodeInsertCommitment
  , insertRequestShape
  , serialiseInsertCommitment
  , deserialiseInsertCommitment
  , matchingInsertCommitment
  , compareRefund
  ) where

import Data.ByteString (ByteString)

import Naming.Wire
    ( WireData (..)
    , deserialiseWireData
    , guardWire
    , serialiseWireData
    )

-- | The representative asset identity inside the initial output.
data Representative = Representative
  { representativeRegistry :: Integer
  , representativeKey :: Integer
  , representativePolicy :: Integer
  , representativeAssetScope :: Integer
  }
  deriving stock (Eq, Show)

-- | The initial output of a proposal.
data InitialOutput = InitialOutput
  { initialRepresentative :: Representative
  , initialQuantity :: Integer
  , initialDestination :: Integer
  , initialDatum :: Integer
  , initialValue :: Integer
  }
  deriving stock (Eq, Show)

-- | The insert proposal carried in the request commitment.
data InsertProposal = InsertProposal
  { registry :: Integer
  , key :: Integer
  , applicationPolicy :: Integer
  , refundAddress :: Integer
  , initial :: InitialOutput
  , scope :: [Integer]
  }
  deriving stock (Eq, Show)

-- | The structural shape the vector records for the request commitment:
-- @{commitmentIndex: 0, commitmentArity: 1, proposalIndex: 0,
-- proposalArity: 6}@.
data InsertRequestShape = InsertRequestShape
  { commitmentIndex :: Int
  , commitmentArity :: Int
  , proposalIndex :: Int
  , proposalArity :: Int
  }
  deriving stock (Eq, Show)

-- | Refusal reason, recorded in the vector's @comparisonResult@.
newtype RefundReason = RefundReason {refundReasonText :: String}
  deriving stock (Eq, Show)

-- | Outcome of comparing a presented refund against the stored one.
data RefundComparison
  = RefundAccepted
  | RefundRefused RefundReason
  deriving stock (Eq, Show)

-- | The reason the contract records when a withdrawal presents a refund
-- address other than the stored one.
withdrawRefundAddress :: RefundReason
withdrawRefundAddress = RefundReason "withdraw-refund-address"

-- | Exact mirror of the contract's @encodeProposal@ wrapped in its
-- single-field @constr(0)@ commitment constructor.
encodeInsertCommitment :: InsertProposal -> WireData
encodeInsertCommitment p =
  Constr 0
    [ Constr 0
        [ WInt (registry p)
        , WInt (key p)
        , WInt (applicationPolicy p)
        , WInt (refundAddress p)
        , encodeOutput (initial p)
        , WList (map WInt (scope p))
        ]
    ]

encodeOutput :: InitialOutput -> WireData
encodeOutput o =
  Constr 0
    [ encodeRepresentative (initialRepresentative o)
    , WInt (initialQuantity o)
    , WInt (initialDestination o)
    , WInt (initialDatum o)
    , WInt (initialValue o)
    ]

encodeRepresentative :: Representative -> WireData
encodeRepresentative r =
  Constr 0
    [ WInt (representativeRegistry r)
    , WInt (representativeKey r)
    , WInt (representativePolicy r)
    , WInt (representativeAssetScope r)
    ]

-- | Exact mirror of the contract's @decodeInsertCommitment@ composed
-- with @decodeProposal@: @constr(0,[proposal])@.
decodeInsertCommitment :: WireData -> Maybe InsertProposal
decodeInsertCommitment (Constr 0 [proposal]) = decodeProposal proposal
decodeInsertCommitment _ = Nothing

decodeProposal :: WireData -> Maybe InsertProposal
decodeProposal
  (Constr 0 [regData, keyData, policyData, refundData, outputData, WList scopeData]) = do
    reg <- asNat regData
    k <- asNat keyData
    policy <- asNat policyData
    refund <- asNat refundData
    output <- decodeOutput outputData
    scope <- traverse asNat scopeData
    pure
      InsertProposal
        { registry = reg
        , key = k
        , applicationPolicy = policy
        , refundAddress = refund
        , initial = output
        , scope = scope
        }
decodeProposal _ = Nothing

decodeOutput :: WireData -> Maybe InitialOutput
decodeOutput
  (Constr 0 [repData, WInt quantity, WInt destination, WInt datum, WInt value]) = do
    rep <- decodeRepresentative repData
    q <- asNat (WInt quantity)
    d <- asNat (WInt destination)
    m <- asNat (WInt datum)
    v <- asNat (WInt value)
    pure
      InitialOutput
        { initialRepresentative = rep
        , initialQuantity = q
        , initialDestination = d
        , initialDatum = m
        , initialValue = v
        }
decodeOutput _ = Nothing

decodeRepresentative :: WireData -> Maybe Representative
decodeRepresentative (Constr 0 [regData, keyData, policyData, scopeData]) = do
  reg <- asNat regData
  k <- asNat keyData
  policy <- asNat policyData
  assetScope <- asNat scopeData
  pure
    Representative
      { representativeRegistry = reg
      , representativeKey = k
      , representativePolicy = policy
      , representativeAssetScope = assetScope
      }
decodeRepresentative _ = Nothing

-- | The contract's @decodeNat@: an integer wire value that is a
-- non-negative safe integer. Wire integers here never exceed 65535, so
-- the safe-integer bound is not reachable; the non-negativity is.
asNat :: WireData -> Maybe Integer
asNat (WInt v)
  | v >= 0 = Just v
asNat _ = Nothing

-- | Exact mirror of the contract's @insertRequestShape@.
insertRequestShape :: WireData -> Maybe InsertRequestShape
insertRequestShape (Constr ci [Constr pj fields]) =
  Just
    InsertRequestShape
      { commitmentIndex = ci
      , commitmentArity = 1
      , proposalIndex = pj
      , proposalArity = length fields
      }
insertRequestShape _ = Nothing

-- | Exact mirror of the contract's @serialiseInsertRequest@ at the
-- commitment level.
serialiseInsertCommitment :: InsertProposal -> Maybe ByteString
serialiseInsertCommitment = serialiseWireData . encodeInsertCommitment

-- | Exact mirror of the contract's @deserialiseInsertCommitment@.
deserialiseInsertCommitment :: ByteString -> Maybe InsertProposal
deserialiseInsertCommitment input = do
  datum <- deserialiseWireData input
  decodeInsertCommitment datum

-- | Exact mirror of the contract's @decodeInsertRequestCommitment@: the
-- bytes decode to a proposal only if that proposal equals the expected
-- one — a redirected refund decodes fine but never matches the request.
matchingInsertCommitment :: InsertProposal -> ByteString -> Maybe InsertProposal
matchingInsertCommitment expected input = do
  proposal <- deserialiseInsertCommitment input
  guardWire (proposal == expected)
  pure proposal

-- | The contract's withdraw-step refund check
-- (@core.mjs@: @if (d.refund.destination !==
-- pending.proposal.refundAddress) fail('withdraw-refund-address')@),
-- which vector @WR01@ records as @comparisonResult@.
compareRefund :: Integer -> Integer -> RefundComparison
compareRefund stored presented
  | presented /= stored = RefundRefused withdrawRefundAddress
  | otherwise = RefundAccepted
