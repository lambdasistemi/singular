{-# LANGUAGE LambdaCase #-}

{- | Read-view phase observations, using the common phase log owner.
The process log has one public implementation; this module owns only the
node adapter's acquired-view observations.
-}
module Singular.Registry.Node.PhaseLog
    ( module Singular.Registry.PhaseLog
    , loggedProvider
    ) where

import Cardano.Ledger.Plutus.ExUnits (ExUnits (..))
import Cardano.Slotting.Slot (SlotNo (..))
import Control.Exception (SomeException (..), finally, throwIO, try)
import Control.Monad (unless)
import Data.Aeson ((.=))
import Data.ByteString (ByteString)
import Data.ByteString.Base16 qualified as B16
import Data.Either (rights)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text.Encoding qualified as TE
import Data.Typeable (typeOf)
import Singular.Registry.PhaseLog
import Singular.Registry.Provider
    ( ChainPoint (..)
    , Provider (..)
    , View (..)
    )

{- | The provider, logged: each acquisition and each read of each view it
hands out is one line. A disabled log leaves the provider as it is.
-}
loggedProvider :: PhaseLog -> Provider IO -> Provider IO
loggedProvider lg inner
    | not (phaseLogEnabled lg) = inner
    | otherwise = Provider $ \act -> do
        elapsed <- startTimer
        acquired <- newIORef False
        let acquiring v = do
                writeIORef acquired True
                ms <- elapsed
                let point = viewPoint v
                logPhase
                    lg
                    "view"
                    [ "duration_ms" .= ms
                    , "outcome" .= ("ok" :: Text)
                    , "slot" .= unSlotNo (cpSlot point)
                    , "hash" .= hexText (cpBlockHash point)
                    , "era" .= cpEra point
                    ]
                held <- startTimer
                act (logged lg v)
                    `finally` ( held
                                    >>= \ms' ->
                                        logPhase lg "view-release" ["held_ms" .= ms']
                              )
        try @SomeException (withView inner acquiring) >>= \case
            Right a -> pure a
            Left e@(SomeException cause) -> do
                got <- readIORef acquired
                unless got $ do
                    ms <- elapsed
                    logPhase
                        lg
                        "view"
                        [ "duration_ms" .= ms
                        , "outcome" .= ("failed" :: Text)
                        , "error_class" .= show (typeOf cause)
                        ]
                throwIO e

-- | A view whose every read is one @query@ line.
logged :: PhaseLog -> View IO -> View IO
logged lg v =
    v
        { viewUTxOsAt = query "utxosAt" length . viewUTxOsAt v
        , viewTimeContext = query "networkTime" (const 1) (viewTimeContext v)
        , viewResolvedOutputs =
            query "resolvedOutputs" length . viewResolvedOutputs v
        , viewPhaseLog = lg
        , viewScriptRegistered =
            query "scriptRegistered" (const 1) . viewScriptRegistered v
        , viewEvaluateTx = \tx -> do
            r <- query "evaluateTx" Map.size (viewEvaluateTx v tx)
            logPhase lg "eval" (exUnitFields r)
            pure r
        , viewPosixMsToSlot =
            query "posixMsToSlot" (const 1) . viewPosixMsToSlot v
        , viewPosixMsCeilSlot =
            query "posixMsCeilSlot" (const 1) . viewPosixMsCeilSlot v
        }
  where
    query :: Text -> (a -> Int) -> IO a -> IO a
    query = queryPhase lg
    exUnitFields r =
        let done = rights (Map.elems r)
            total f = sum [toInteger (f u) | u <- done]
        in  [ "redeemers" .= Map.size r
            , "failed" .= (Map.size r - length done)
            , "mem" .= total (\(ExUnits m _) -> m)
            , "steps" .= total (\(ExUnits _ s) -> s)
            ]

hexText :: ByteString -> Text
hexText = TE.decodeUtf8 . B16.encode
