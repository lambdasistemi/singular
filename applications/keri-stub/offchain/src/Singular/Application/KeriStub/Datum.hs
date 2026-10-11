{-# LANGUAGE LambdaCase #-}

{- |
Module      : Singular.Application.KeriStub.Datum
Description : The stub holding datum, its codec
License     : Apache-2.0

A stub holding carries its 'Holding' inline: the key, the controller's
payment key hash, the protected deposit in lovelace and an opaque
identifier prefix as payload, over Plutus data as:

@
Holding = Constr 0 [B key, B controller, I deposit, payload]
@

The payload is any Plutus @PLC.Data@, so no payload is refused for
what it says.
-}
module Singular.Application.KeriStub.Datum
    ( -- * The holding
      Holding (..)
    , maxKeyBytes

      -- * Plutus data
    , holdingToData
    , holdingFromData
    ) where

import Data.ByteString (ByteString)
import Data.ByteString qualified as BS

import PlutusCore.Data qualified as PLC

-- | A registry key is 1 to 32 bytes.
maxKeyBytes :: Int
maxKeyBytes = 32

-- | A stub holding: what the decoder fills the registry's view from.
data Holding = Holding
    { hdKey :: ByteString
    -- ^ The key the holding belongs to
    , hdController :: ByteString
    -- ^ The controller's payment key hash (28 bytes)
    , hdDeposit :: Integer
    -- ^ The protected deposit, in lovelace
    , hdPayload :: PLC.Data
    -- ^ The opaque identifier prefix, unread by the registry
    }
    deriving stock (Eq, Show)

-- | The holding as Plutus data.
holdingToData :: Holding -> PLC.Data
holdingToData h =
    PLC.Constr
        0
        [ PLC.B (hdKey h)
        , PLC.B (hdController h)
        , PLC.I (hdDeposit h)
        , hdPayload h
        ]

-- | The holding a datum encodes, or why it is not one.
holdingFromData :: PLC.Data -> Either String Holding
holdingFromData = \case
    PLC.Constr 0 [k, c, d, p] -> do
        key <- keyFrom k
        controller <- controllerFrom c
        deposit <- depositFrom d
        pure (Holding key controller deposit p)
    _ ->
        Left
            "the holding is not Constr 0 [key, controller, deposit, payload]"
  where
    keyFrom = \case
        PLC.B key
            | BS.null key ->
                Left
                    "the holding key is empty: a registry key is 1 to 32 bytes"
            | BS.length key > maxKeyBytes ->
                Left
                    ( "the holding key names "
                        <> show (BS.length key)
                        <> " bytes; a registry key is at most 32 bytes"
                    )
            | otherwise -> Right key
        _ -> Left "the holding key is not bytes"
    controllerFrom = \case
        PLC.B controller
            | BS.length controller /= 28 ->
                Left
                    ( "the holding controller names "
                        <> show (BS.length controller)
                        <> " bytes; a payment key hash is 28 bytes"
                    )
            | otherwise -> Right controller
        _ -> Left "the holding controller is not bytes"
    depositFrom = \case
        PLC.I deposit
            | deposit < 0 ->
                Left
                    "the holding deposit is negative: a deposit is lovelace, never below zero"
            | otherwise -> Right deposit
        _ -> Left "the holding deposit is not an integer"
