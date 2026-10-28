{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.Application.OpenDatum.Inspect
Description : Present open datum's refinement of the neutral registry answer
License     : Apache-2.0

No additional chain query or signature is required. The current application
reader decodes an active holding; every neutral refusal and unavailable result
keeps its meaning and process status.
-}
module Singular.Application.OpenDatum.Inspect (openDatumInspection) where

import Data.Aeson (encode, object, (.=))
import Data.ByteString.Lazy qualified as BL
import Data.Text.Encoding qualified as TE
import Singular.Application.OpenDatum.Reader qualified as App
import Singular.Application.OpenDatum.Requests.Records
    ( ProtectedControl (..)
    )
import Singular.CLI.Inspect (Inspection (..), hex, neutralInspection)
import Singular.Reader qualified as R
import Singular.Registry.ContractTable (ApplicationIdentity)
import Singular.Registry.PlainJson
    ( PayloadView (..)
    , payloadView
    , schemaName
    )
import Singular.Registry.StateToken (renderStateToken)
import Singular.State.Lineage (registryAsset)

-- | The application's decoded control and payload, or the retained neutral answer.
openDatumInspection
    :: R.ReaderRequest
    -> Maybe ApplicationIdentity
    -> R.NeutralReaderAnswer
    -> Inspection
openDatumInspection request published neutral =
    case App.refineReaderAnswer request published neutral of
        App.Live _ control payload ->
            let view = payloadView payload
                protected =
                    object
                        [ "registry"
                            .= (renderStateToken <$> registryAsset (controlRegistry control))
                        , "keyHex" .= hex (controlKey control)
                        , "controller" .= hex (controlController control)
                        , "activeAsset" .= renderStateToken (controlActiveAsset control)
                        , "deposit" .= controlDeposit control
                        ]
            in  base
                    { inspectionAnswer = "pending-termination"
                    , inspectionFields =
                        inspectionFields base
                            <> [ "control" .= protected
                               , "envelope" .= lookup "datum" (inspectionFields base)
                               , "deposit" .= controlDeposit control
                               , "payload" .= viewJson view
                               , "payloadSchema" .= schemaName (viewSchema view)
                               ]
                    , inspectionLines =
                        inspectionLines base
                            <> [ "Control: " <> TE.decodeUtf8 (BL.toStrict (encode protected))
                               , "Deposit (lovelace): "
                                    <> TE.decodeUtf8 (BL.toStrict (encode (controlDeposit control)))
                               , "Payload ("
                                    <> schemaName (viewSchema view)
                                    <> "): "
                                    <> TE.decodeUtf8 (BL.toStrict (encode (viewJson view)))
                               ]
                    }
        App.PendingTermination _ -> base{inspectionAnswer = "pending-termination"}
        App.Terminal state -> neutralInspection request published (R.Terminal state)
        App.NeverRegistered state -> neutralInspection request published (R.NeverRegistered state)
        App.Unavailable name why -> neutralInspection request published (R.Unavailable name why)
        App.Refused why -> neutralInspection request published (R.Refused why)
  where
    base = neutralInspection request published neutral
