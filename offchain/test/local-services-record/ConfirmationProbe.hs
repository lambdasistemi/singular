{-# LANGUAGE TypeApplications #-}

{- |
Module      : ConfirmationProbe
Description : The existing confirmation deadline over fresh local time facts
License     : Apache-2.0

This read-only probe exercises the existing deadline caller while the recorder
holds the actual generated node context. It neither signs nor submits.
-}
module ConfirmationProbe (probeConfirmation) where

import Cardano.Ledger.Allegra.Scripts (ValidityInterval (..))
import Cardano.Ledger.Api.PParams (ppProtocolVersionL)
import Cardano.Ledger.Api.Tx (mkBasicTx, vldtTxBodyL)
import Cardano.Ledger.Api.Tx.Body (mkBasicTxBody)
import Cardano.Ledger.BaseTypes (ProtVer (..), StrictMaybe (..))
import Cardano.Ledger.Binary (getVersion)
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Core (PParams)
import Cardano.Node.Client.Provider qualified as Node
import Cardano.Slotting.Slot (SlotNo (..))
import Cardano.Slotting.Time (SystemStart (..))
import Control.Exception (SomeException, displayException, try)
import Crypto.Hash (Digest, SHA256, hash)
import Data.Aeson (encode, object, (.=))
import Data.ByteArray (convert)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Lazy qualified as LBS
import Data.ByteString.Short qualified as SBS
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Text (Text)
import Data.Text.Encoding (decodeUtf8)
import Data.Time.Clock.POSIX (utcTimeToPOSIXSeconds)
import Data.Word (Word32)
import Lens.Micro ((&), (.~), (^.))
import Ouroboros.Consensus.HardFork.Combinator.AcrossEras
    ( OneEraHash (..)
    )
import Ouroboros.Network.Block qualified as Chain
import Singular.Registry.NetworkTime
    ( NetworkTimeManifest (..)
    , validateNetworkTime
    )
import Singular.Registry.Node (confirmDeadline)
import Singular.Registry.PhaseLog (noPhaseLog)
import Singular.Registry.Provider
    ( ChainPoint (..)
    , Provider (..)
    , View (..)
    )
import System.FilePath ((</>))

-- | Observe the caller's requested times and exact local range refusals.
probeConfirmation
    :: FilePath
    -> Word32
    -> Node.LedgerSnapshot
    -> SystemStart
    -> BS.ByteString
    -> SlotNo
    -> PParams ConwayEra
    -> IO ()
probeConfirmation output magic snapshot (SystemStart start) history horizon pp = do
    genesis <- BS.readFile (output </> "shelley-genesis.json")
    let manifest =
            NetworkTimeManifest
                { timeNetworkMagic = magic
                , timeSystemStartMs = floor (utcTimeToPOSIXSeconds start * 1000)
                , timeGenesisSha256 = digest genesis
                , timeEraHistorySha256 = digest history
                , timeHorizonSlot = horizon
                , timeProtocolMajor = getVersion (pvMajor (pp ^. ppProtocolVersionL))
                , timeSourceIdentity =
                    "exact generated context; same held recorder acquisition"
                }
    context <-
        either
            (fail . show)
            pure
            (validateNetworkTime magic manifest genesis history)
    point <- case Node.ledgerChainPoint snapshot of
        Chain.GenesisPoint -> fail "ConfirmationProbeAtOrigin"
        Chain.BlockPoint slot (OneEraHash header) ->
            pure
                ( ChainPoint
                    magic
                    (Node.ledgerCurrentEra snapshot)
                    slot
                    (SBS.fromShort header)
                )
    requests <- newIORef (0 :: Int)
    let unused :: IO a
        unused = fail "ConfirmationProbeUnexpectedRawRead"
        view =
            View
                { viewPoint = point
                , viewProtocolParams = pp
                , viewTimeContext = modifyIORef' requests (+ 1) >> pure context
                , viewResolvedOutputs = const unused
                , viewPhaseLog = noPhaseLog
                , viewUTxOsAt = const unused
                , viewScriptRegistered = const unused
                }
        tx =
            mkBasicTx
                ( mkBasicTxBody
                    & vldtTxBodyL .~ ValidityInterval SNothing (SJust (SlotNo 1))
                )
    result <- try @SomeException (confirmDeadline (Provider ($ view)) tx)
    calls <- readIORef requests
    LBS.writeFile (output </> "confirmation-probe.json") $
        encode $
            object
                [ "networkMagic" .= magic
                , "point" .= show point
                , "genesisSha256" .= hexDigest genesis
                , "eraHistorySha256" .= hexDigest history
                , "horizonSlot" .= horizon
                , "rawContextReads" .= calls
                , "callerResult" .= either displayException show result
                , "limits"
                    .= ( "Existing caller through common time only; raw adapter migration and journey not established"
                            :: Text
                       )
                ]
    either (fail . displayException) (const (pure ())) result
  where
    digest bytes = convert (hash bytes :: Digest SHA256)
    hexDigest = decodeUtf8 . B16.encode . digest
