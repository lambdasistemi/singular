{-# LANGUAGE DerivingStrategies #-}

-- | Wire-level data model and byte serialisation for the Singular naming
-- contract, transcribed exactly from the accepted epic-15 contract's
-- @simulator/naming-wire.mjs@ and @simulator/naming.mjs@ (v0.2.0, commit
-- @13231f58833b8feb57f4b0f9b1117bfcfba0c07d@, asset sha256
-- @acbabdf54a271251bd73bf9d84ab2c901107045a7dd77d28a391f22cdd53b0e5@).
--
-- The serialiser and parser mirror the reference function for function:
-- same canonical heads, same refusals, same requirement to consume the
-- whole input. Where this module and the reference disagree, the
-- reference is right and this module is wrong.
module Naming.Wire
  ( WireData (..)
  , serialiseWireData
  , deserialiseWireData
  , PaymentCredential (..)
  , AddressForm (..)
  , Address (..)
  , decodeAddress
  , encodeAddress
  , canonicalAddress
  , guardWire
  ) where

import Data.ByteString (ByteString)
import Data.ByteString qualified as BS

-- | Untyped PlutusData-shaped wire value: exactly the four shapes the
-- contract's @serialiseWireData@ accepts.
data WireData
  = Constr Int [WireData]
  | WBytes ByteString
  | WInt Integer
  | WList [WireData]
  deriving stock (Eq, Show)

-- | Serialise to the contract's byte form. @constr(i, fields)@ becomes
-- @D8 (79+i) 9F … FF@ with @i < 7@; byte strings are at most 64 bytes
-- with the canonical head (direct length below 24, otherwise @58@ plus
-- one length byte); unsigned integers use the canonical unsigned head
-- (direct below 24, @18@ below 256, @19@ plus two bytes below 65536);
-- lists are indefinite (@9F … FF@). Nothing else serialises.
serialiseWireData :: WireData -> Maybe ByteString
serialiseWireData (Constr index fields)
  | index >= 0 && index < 7 = do
      parts <- traverse serialiseWireData fields
      pure $
        BS.pack [0xd8, 0x79 + fromIntegral index, 0x9f]
          <> BS.concat parts
          <> BS.singleton 0xff
serialiseWireData (WBytes b)
  | n <= 64 =
      pure $
        if n < 24
          then BS.cons (fromIntegral (0x40 + n)) b
          else BS.pack [0x58, fromIntegral n] <> b
  where
    n = BS.length b
serialiseWireData (WInt v)
  | v >= 0, v < 24 = pure (BS.pack [fromIntegral v])
  | v >= 0, v < 256 = pure (BS.pack [0x18, fromIntegral v])
  | v >= 0, v < 65536 =
      pure (BS.pack [0x19, fromIntegral (v `div` 256), fromIntegral (v `mod` 256)])
serialiseWireData (WList fields) = do
  parts <- traverse serialiseWireData fields
  pure (BS.singleton 0x9f <> BS.concat parts <> BS.singleton 0xff)
-- Guard fall-throughs: byte strings over 64 bytes and negative or
-- oversized integers do not serialise, exactly as in the reference.
serialiseWireData _ = Nothing

-- | Parse the contract's byte form back, refusing exactly what the
-- reference parser refuses: non-canonical heads (a @58@ byte-string head
-- must carry 24..64 bytes, @18@/@19@ integer heads must be the shortest
-- form), unsupported heads, and truncated input — the whole input must
-- be consumed.
deserialiseWireData :: ByteString -> Maybe WireData
deserialiseWireData input = do
  (value, rest) <- parseWireData input
  guardWire (BS.null rest)
  pure value

-- | @Maybe@-flavoured guard, the analogue of the reference's repeated
-- @=== null@ refusals.
guardWire :: Bool -> Maybe ()
guardWire True = Just ()
guardWire False = Nothing

parseWireData :: ByteString -> Maybe (WireData, ByteString)
parseWireData input = case BS.uncons input of
  Nothing -> Nothing
  Just (header, rest)
    | header == 0xd8
    , Just (tag, rest2) <- BS.uncons rest
    , tag >= 0x79
    , tag < 0x80
    , Just (0x9f, rest3) <- BS.uncons rest2 -> do
        (fields, remaining) <- parseWireItems rest3
        pure (Constr (fromIntegral tag - 0x79) fields, remaining)
    | header == 0x9f -> do
        (fields, remaining) <- parseWireItems rest
        pure (WList fields, remaining)
    | header >= 0x40, header < 0x58 ->
        let len = fromIntegral (header - 0x40)
        in guardWire (BS.length rest >= len)
             >> pure (WBytes (BS.take len rest), BS.drop len rest)
    | header == 0x58
    , Just (len8, rest2) <- BS.uncons rest
    , len8 >= 24
    , len8 <= 64 ->
        let len = fromIntegral len8
        in guardWire (BS.length rest2 >= len)
             >> pure (WBytes (BS.take len rest2), BS.drop len rest2)
    | header < 24 -> pure (WInt (fromIntegral header), rest)
    | header == 0x18
    , Just (v, rest2) <- BS.uncons rest
    , v >= 24 ->
        pure (WInt (fromIntegral v), rest2)
    | header == 0x19
    , Just (high, rest2) <- BS.uncons rest
    , Just (low, rest3) <- BS.uncons rest2
    , let v = fromIntegral high * 256 + fromIntegral low
    , v >= 256 ->
        pure (WInt v, rest3)
    | otherwise -> Nothing

parseWireItems :: ByteString -> Maybe ([WireData], ByteString)
parseWireItems = go []
  where
    go acc input = case BS.uncons input of
      Just (0xff, rest) -> pure (reverse acc, rest)
      Just _ -> do
        (value, rest) <- parseWireData input
        go (value : acc) rest
      Nothing -> Nothing

-- | Payment credential kind, as in the contract's @naming.mjs@.
data PaymentCredential
  = PaymentKey
  | ScriptCredential
  deriving stock (Eq, Show)

-- | Address form, as in the contract's @naming.mjs@.
data AddressForm
  = EnterpriseForm
  | BaseForm
  deriving stock (Eq, Show)

-- | A decoded Shelley-style address: the bytes plus the fields the
-- contract's @decodeAddress@ recovers from the header byte.
data Address = Address
  { addressBytes :: ByteString
  , addressForm :: AddressForm
  , addressNetwork :: Int
  , addressPaymentCredential :: PaymentCredential
  , addressPaymentHash :: ByteString
  , addressStakeCredential :: Maybe PaymentCredential
  , addressStakeHash :: ByteString
  }
  deriving stock (Eq, Show)

-- | Exact mirror of the contract's @decodeAddress@: header byte kinds
-- 6–7 are enterprise addresses (29 bytes), kinds 0–3 are base addresses
-- (57 bytes), everything else is refused.
decodeAddress :: ByteString -> Maybe Address
decodeAddress bytes = case BS.uncons bytes of
  Nothing -> Nothing
  Just (header, payload)
    | (kind == 6 || kind == 7) && BS.length payload == 28 ->
        Just
          Address
            { addressBytes = bytes
            , addressForm = EnterpriseForm
            , addressNetwork = network
            , addressPaymentCredential = if kind == 6 then PaymentKey else ScriptCredential
            , addressPaymentHash = payload
            , addressStakeCredential = Nothing
            , addressStakeHash = BS.empty
            }
    | kind < 4 && BS.length payload == 56 ->
        Just
          Address
            { addressBytes = bytes
            , addressForm = BaseForm
            , addressNetwork = network
            , addressPaymentCredential = if even kind then PaymentKey else ScriptCredential
            , addressPaymentHash = BS.take 28 payload
            , addressStakeCredential = Just (if kind < 2 then PaymentKey else ScriptCredential)
            , addressStakeHash = BS.drop 28 payload
            }
    | otherwise -> Nothing
    where
      kind = fromIntegral header `div` 16 :: Int
      network = fromIntegral header `mod` 16 :: Int

-- | Exact mirror of the contract's @encodeAddress@.
encodeAddress :: Address -> Maybe ByteString
encodeAddress a
  | addressNetwork a >= 16 = Nothing
  | BS.length (addressPaymentHash a) /= 28 = Nothing
  | addressForm a == EnterpriseForm
  , Nothing <- addressStakeCredential a
  , BS.null (addressStakeHash a) =
      pure $
        BS.cons
          ( fromIntegral
              ( (6 + credentialOffset (addressPaymentCredential a)) * 16
                  + addressNetwork a
              )
          )
          (addressPaymentHash a)
  | addressForm a == BaseForm
  , Just stake <- addressStakeCredential a
  , BS.length (addressStakeHash a) == 28 =
      pure $
        BS.cons
          ( fromIntegral
              ( (credentialOffset (addressPaymentCredential a)
                  + 2 * credentialOffset stake)
                * 16
                + addressNetwork a
              )
          )
          (addressPaymentHash a <> addressStakeHash a)
  | otherwise = Nothing
  where
    credentialOffset PaymentKey = 0 :: Int
    credentialOffset ScriptCredential = 1

-- | The contract's @canonicalAddress@: the bytes decode to the address
-- and the address encodes back to the same bytes.
canonicalAddress :: Address -> Bool
canonicalAddress a =
  decodeAddress (addressBytes a) == Just a
    && encodeAddress a == Just (addressBytes a)
