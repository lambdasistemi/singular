{- | The registration comparison, as one named thing.

This is the comparison the registration chapter has always run, moved out of the
runner so that what it covers can be stated and checked rather than inferred by
reading it. The semantics are unchanged: the delivery observation and the
holder's quantity are each compared with the model's expected observation, and
the registration fails if either differs.

What is new is that the result says which of the model's __declared__
observations it accounted for, and which names the model cannot observe it
carried. Both are derived from the comparison that actually ran — the compared
objects' own fields, intersected with the declared surface — so a comparison
that covers a projection cannot report otherwise.
-}
module Conformance.Compare.Registration (
    Declared (..),
    Delivery (..),
    Difference (..),
    Agreement (..),
    declaredSurface,
    deliveryObservation,
    compareRegistration,
    rootOf,
    approvalAssetName,
    edgeOrdinal,
) where

import Data.Aeson (Value (..), object, (.:), (.=))
import Data.Maybe (fromMaybe)
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.Aeson.Types (parseEither)
import Data.Bits (shiftR, xor, (.&.))
import Data.List (sort, sortOn)
import Data.Text (Text)
import Data.Word (Word64, Word8)

-- | What the model says it can see, read off the driver surface.
data Declared = Declared
    { declaredObservations :: [Text]
    -- ^ every observation a comparison result must account for
    , declaredUnobservable :: [Text]
    -- ^ names the model has no vocabulary for; these never earn a pass
    }
    deriving (Eq, Show)

-- | The delivery the registration chapter presents to the model, in model ids.
data Delivery = Delivery
    { deliveryAddress :: Integer
    , deliveryPolicy :: Integer
    , deliveryKey :: Integer
    , deliveryQuantity :: Integer
    }
    deriving (Eq, Show)

-- | One disagreement, named by the model field it is about.
data Difference = Difference
    { differenceObservation :: Text
    , differenceExpected :: Value
    , differenceObserved :: Value
    }
    deriving (Eq, Show)

-- | What a comparison established, and what it deliberately did not.
data Agreement = Agreement
    { agreementCompared :: [Text]
    -- ^ declared observations this comparison actually accounted for
    , agreementUnobserved :: [Text]
    -- ^ declared unobservable names the result carried, never compared
    }
    deriving (Eq, Show)

-- | Read the declared surface out of a driver corpus value.
declaredSurface :: Value -> Either String Declared
declaredSurface = parseEither $ \value -> do
    surface <- case value of
        Object fields -> fields .: "surface"
        _ -> fail "driver corpus is not an object"
    observations <- surface .: "observations"
    unobservable <- surface .: "unobservable"
    pure Declared{declaredObservations = observations, declaredUnobservable = unobservable}

-- | Exactly the object this chapter has always compared.
deliveryObservation :: Delivery -> Value
deliveryObservation delivery =
    object
        [ "address" .= deliveryAddress delivery
        , "policy" .= deliveryPolicy delivery
        , "key" .= deliveryKey delivery
        , "quantity" .= deliveryQuantity delivery
        ]

{- | Compare an observed registration with the model's declared boundary.

Both sides are an @observations@ object in the model's vocabulary: the expected
one from the driver corpus row, the observed one translated from the chain.

Every declared observation must be present on both sides and must agree. A name
the model cannot observe must not appear at all: an observed object that carried
one would be claiming to have seen what the model has no vocabulary for, so it
is reported rather than passed over. Those names are carried in the result,
never compared.
-}
compareRegistration :: Declared -> Value -> Value -> Either [Difference] Agreement
compareRegistration declared expected observed =
    case claimed <> missing <> disagreeing of
        [] ->
            Right
                Agreement
                    { agreementCompared = sort (declaredObservations declared)
                    , agreementUnobserved = sort (declaredUnobservable declared)
                    }
        differences -> Left differences
  where
    fieldsOf value = case value of
        Object fields -> map Key.toText (KM.keys fields)
        _ -> []
    at name value = case value of
        Object fields -> KM.lookup (Key.fromText name) fields
        _ -> Nothing
    -- Claiming to have observed something the model cannot observe.
    claimed =
        [ Difference name Null (fromMaybe Null (at name observed))
        | name <- sort (declaredUnobservable declared)
        , name `elem` fieldsOf observed
        ]
    {- The one named unobservable that lives inside an observation rather than
    beside it: a ledger makes every output carry a minimum ada, and the model
    says nothing about it, so a transaction output's `lovelace` is a logical
    zero. It is removed from both sides before `tx` is compared — every other
    field of every input, output, mint, refund and signer list still has to
    agree — and it is never counted as a passing observation. -}
    withoutOutputMinimumAda name value
        | name /= "tx" = value
        | otherwise = case value of
            Object fields -> case KM.lookup "outputs" fields of
                Just outputs -> Object (KM.insert "outputs" (stripOutputs outputs) fields)
                Nothing -> value
            _ -> value
    stripOutputs value = case value of
        Array outputs -> Array (fmap dropLovelace outputs)
        _ -> value
    dropLovelace value = case value of
        Object fields -> Object (KM.delete "lovelace" fields)
        _ -> value
    -- A declared observation absent from either side is not accounted for.
    missing =
        [ Difference name (fromMaybe Null (at name expected)) (fromMaybe Null (at name observed))
        | name <- sort (declaredObservations declared)
        , at name expected == Nothing || at name observed == Nothing
        ]
    disagreeing =
        [ Difference name left right
        | name <- sort (declaredObservations declared)
        , Just left <- [withoutOutputMinimumAda name <$> at name expected]
        , Just right <- [withoutOutputMinimumAda name <$> at name observed]
        , left /= right
        ]

{- | @Singular.rootOf@: FNV-1a over the sorted (key, leaf byte) pairs.

A second site computing a model function, so it is not trusted on sight: a
control requires it to reproduce every accepted corpus row's root from that
row's own trie.
-}
rootOf :: [(Integer, Word8)] -> [Word8]
rootOf leaves = u64bytes (fnv1a (concatMap commit (sortOn fst leaves)))
  where
    commit (key, leaf) =
        let byte = fromIntegral (key `mod` 256)
         in u64bytes (fnv1a [byte]) <> [byte, leaf]

fnv1a :: [Word8] -> Word64
fnv1a = foldl step 14695981039346656037
  where
    step accumulator byte = (accumulator `xor` fromIntegral byte) * 16777619

u64bytes :: Word64 -> [Word8]
u64bytes value =
    [fromIntegral ((value `shiftR` place) .&. 0xFF) | place <- [56, 48, 40, 32, 24, 16, 8, 0]]


{- | @Singular.edgeOrdinal@: the byte each edge commits under. -}
edgeOrdinal :: Text -> Maybe Word8
edgeOrdinal edge = lookup edge table
  where
    table =
        [ ("insertAbsent", 0)
        , ("insertActive", 1)
        , ("updateActive", 2)
        , ("updateTerminal", 3)
        , ("deleteAbsent", 4)
        , ("deleteActive", 5)
        , ("witnessTerminal", 6)
        ]

{- | @Singular.approvalAssetName@, which @datumHash@ also is.

FNV-1a over the scoping tuple, masked to 32 bits: the model's stand-in for
@blake2b_256(edge ‖ key ‖ owner ‖ destination)@. A second site computing a model
function, so like 'rootOf' it is not trusted on sight — a control requires it to
reproduce every approval asset name and destination commitment in the committed
corpus, from that row's own request.
-}
approvalAssetName :: Text -> Integer -> Integer -> Integer -> Maybe Integer
approvalAssetName edge key owner destination = do
    ordinal <- edgeOrdinal edge
    let byte value = fromIntegral (value `mod` 256)
    pure (fromIntegral (fnv1a [ordinal, byte key, byte owner, byte destination] .&. 0xFFFFFFFF))
