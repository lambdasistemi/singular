{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.CLI.Plan
Description : What a command asks of the registry, decided without a wallet key
License     : Apache-2.0

The checks that turn a caller's inputs into the transactions a command
builds, without signing, submitting or journalling: reading a JSON
document, and refusing an outlay past its allowance. Entry-specific
planning (insert, update, terminate) lives in the application, which
depends on this library; this module names no application.
-}
module Singular.CLI.Plan
    ( -- * Reading what the caller names
      readJson

      -- * What it costs
    , refuseOver
    , outlayReport
    ) where

import Control.Monad (unless)
import Data.Aeson (Value, object, (.=))
import Data.Aeson qualified as Aeson

import Singular.CLI.Outlay
    ( Outlay (..)
    , outlayTotal
    , withinAllowance
    )
import Singular.CLI.Receipt (OutcomeClass (..))
import Singular.CLI.Session (failWith, failWithFields)

-- | A JSON document the caller named, or a client refusal saying why not.
readJson :: FilePath -> IO Aeson.Value
readJson path =
    Aeson.eitherDecodeFileStrict' path
        >>= either (failWith ClientRefusal . ((path <> ": ") <>)) pure

{- | Stop before anything is signed, sent or journalled when the measured
outlay passes the approved allowance.
-}
refuseOver :: Maybe Integer -> Outlay -> IO ()
refuseOver allowance outlay =
    unless (withinAllowance allowance outlay) $
        failWithFields
            ClientRefusal
            ( "the measured outlay of "
                <> show (outlayTotal outlay)
                <> " lovelace passes the approved allowance of "
                <> maybe "none" show allowance
            )
            [("outlay", outlayReport allowance outlay)]

-- | The outlay and the allowance it is judged against.
outlayReport :: Maybe Integer -> Outlay -> Value
outlayReport allowance o =
    object
        [ "fee" .= outlayFee o
        , "lockedBond" .= outlayBond o
        , "foldFeeBound" .= outlayFoldBound o
        , "total" .= outlayTotal o
        , "allowance" .= allowance
        , "withinAllowance" .= withinAllowance allowance o
        ]
