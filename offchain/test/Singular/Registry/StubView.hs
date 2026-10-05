{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.Registry.StubView
Description : A view whose every read fails unless a row supplies it
License     : Apache-2.0

Rows that drive one builder hand it a view built from 'stubView' with
only the reads the row expects overridden. Any other read fails the row
with its own name rather than answering empty. 'servingView' is the
provider of such a view, for code that acquires one per transaction.
-}
module Singular.Registry.StubView
    ( stubView
    , servingView
    ) where

import Data.ByteString qualified as BS

import Cardano.Ledger.Api.PParams (emptyPParams)
import Singular.Registry.PhaseLog (noPhaseLog)

import Singular.Registry.Provider
    ( ChainPoint (..)
    , Provider (..)
    , SlotNo (..)
    , View (..)
    )

-- | Parameters empty; every effectful read fails, naming itself.
stubView :: View IO
stubView =
    View
        { viewPoint =
            ChainPoint
                { cpNetwork = 42
                , cpEra = "Conway"
                , cpSlot = SlotNo 1
                , cpBlockHash = BS.replicate 32 0
                }
        , viewProtocolParams = emptyPParams
        , viewTimeContext = fail "the stub view supplies no time context"
        , viewResolvedOutputs = \_ -> fail "the stub view resolves no inputs"
        , viewPhaseLog = noPhaseLog
        , viewUTxOsAt = \_ -> fail "the stub view reads no address"
        , viewScriptRegistered = \_ -> fail "the stub view reads no registration"
        , viewEvaluateTx = \_ -> fail "the stub view evaluates nothing"
        , viewPosixMsToSlot = \_ -> fail "the stub view converts no time"
        , viewPosixMsCeilSlot = \_ -> fail "the stub view converts no time"
        }

-- | A provider every acquisition of which is this view.
servingView :: View IO -> Provider IO
servingView v = Provider ($ v)
