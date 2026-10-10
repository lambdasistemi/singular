{-# LANGUAGE LambdaCase #-}

{- |
Module      : Singular.Application.OpenDatum.Build
Description : The open-datum envelope, built from the sources a caller names
License     : Apache-2.0

A caller of the open-datum application names six things: the registry's
state asset, the active policy, a key, a controller, a deposit and a
payload. This module reads the three that arrive as text or JSON — key,
deposit and payload — each refusing its bad input under a name of its own,
and builds the 'Envelope' from all six. The version is the only field it
chooses.
-}
module Singular.Application.OpenDatum.Build
    ( -- * The deposit minimum
      minimumDeposit

      -- * Readers
    , KeyEncoding (..)
    , KeyRefusal (..)
    , maxKeyBytes
    , readKey
    , DepositRefusal (..)
    , readDeposit
    , PayloadRefusal (..)
    , readPayload

      -- * The builder
    , buildEnvelope
    ) where

import Control.Monad (when)
import Data.Aeson (Value)
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.Char (digitToInt, isDigit)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE

import PlutusCore.Data qualified as PLC

import Singular.Application.OpenDatum.Envelope
    ( Control (..)
    , Envelope (..)
    , StateAsset
    , dataFromJson
    , envelopeVersion
    )

-- | The least deposit the client builds an envelope with, in lovelace.
minimumDeposit :: Integer
minimumDeposit = 2_000_000

-- | How a key argument spells its bytes.
data KeyEncoding
    = -- | the UTF-8 bytes of the text
      KeyText
    | -- | base16
      KeyHex
    deriving stock (Eq, Show)

-- | Why a key argument is refused.
data KeyRefusal
    = KeyEmpty
    | KeyNotHex
    | -- | the byte length it came to
      KeyTooLong Int
    deriving stock (Eq, Show)

-- | The longest key, in bytes.
maxKeyBytes :: Int
maxKeyBytes = 32

-- | The key bytes an argument spells under the chosen encoding.
readKey :: KeyEncoding -> Text -> Either KeyRefusal ByteString
readKey encoding argument = do
    spelled <- case encoding of
        KeyText -> Right (TE.encodeUtf8 argument)
        KeyHex -> first (const KeyNotHex) (B16.decode (TE.encodeUtf8 argument))
    when (BS.null spelled) $ Left KeyEmpty
    let size = BS.length spelled
    when (size > maxKeyBytes) $ Left (KeyTooLong size)
    pure spelled

-- | Why a deposit argument is refused.
data DepositRefusal
    = DepositNotInteger
    | -- | the deposit it came to
      DepositBelowMinimum Integer
    deriving stock (Eq, Show)

-- | The deposit an optional argument names; absent is 'minimumDeposit'.
readDeposit :: Maybe Text -> Either DepositRefusal Integer
readDeposit = \case
    Nothing -> Right minimumDeposit
    Just argument -> do
        deposit <- maybe (Left DepositNotInteger) Right (integer argument)
        when (deposit < minimumDeposit) $
            Left (DepositBelowMinimum deposit)
        pure deposit
  where
    integer argument = case T.uncons argument of
        Just ('-', digits) -> negate <$> natural digits
        _ -> natural argument
    natural digits
        | not (T.null digits) && T.all isDigit digits =
            Just (T.foldl' (\n c -> n * 10 + toInteger (digitToInt c)) 0 digits)
        | otherwise = Nothing

-- | Why a payload is refused: the reason the datum reader gives.
newtype PayloadRefusal = PayloadNotPlutusData String
    deriving stock (Eq, Show)

-- | The datum a detailed-schema JSON value is.
readPayload :: Value -> Either PayloadRefusal PLC.Data
readPayload = first PayloadNotPlutusData . dataFromJson

{- | The envelope its six sources make, under 'envelopeVersion'.

Arguments, in order: the registry's state asset, the active policy, the
key, the controller's payment key hash, the deposit, the payload.
-}
buildEnvelope
    :: StateAsset
    -> ByteString
    -> ByteString
    -> ByteString
    -> Integer
    -> PLC.Data
    -> Envelope
buildEnvelope registry active key controller deposit payload =
    Envelope
        { envControl =
            Control
                { ctlVersion = envelopeVersion
                , ctlRegistry = registry
                , ctlActivePolicy = active
                , ctlKey = key
                , ctlController = controller
                , ctlDeposit = deposit
                }
        , envPayload = payload
        }
