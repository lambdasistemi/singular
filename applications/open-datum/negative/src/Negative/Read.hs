{- |
Module      : Negative.Read
Description : The before and after reads around a refusal
License     : Apache-2.0

After every refusal the host reads the registry state output, the
key's holding, the wallet's outputs, the pending requests and the held
deposit again. The pair passes only when the state root, the holding's
output reference, value and datum, the wallet's outputs, the pending
requests and the deposit are equal before and after.
-}
module Negative.Read
    ( -- * Readings
      Around (..)
    , readAround
    , unchanged
    ) where

import Control.Exception (fromException, throwIO, try)
import Data.Aeson (Value, toJSON)
import Data.Aeson qualified as Aeson
import Data.ByteString (ByteString)
import Data.Text qualified as T
import Lens.Micro ((^.))

import Cardano.Ledger.Api.Scripts.Data (Datum (..), binaryDataToData)
import Cardano.Ledger.Api.Tx.Out (datumTxOutL)
import Cardano.Ledger.Plutus.Data (Data (..))
import Singular.Application.OpenDatum.Envelope
    ( envelopeFromData
    , envelopeToJson
    )
import Singular.Application.OpenDatum.Value (openDatumApplication)
import Singular.CLI.Attached (Attached (..), reading, savedOf)
import Singular.CLI.Live
    ( Live (..)
    , attachLive
    , coinOf
    , liveOutputFor
    , liveOutputs
    , observedRoot
    , txInText
    , valueJson
    )
import Singular.CLI.Receipt (OutcomeClass (..))
import Singular.CLI.Registry (hexT)
import Singular.CLI.Session (CommandFailure (..))
import Singular.Registry.Application
    ( DecodedHolding (..)
    , datumToJson
    )
import Singular.Registry.SessionIO qualified as Cage
import Singular.Registry.Wallet (Wallet (..))

import Negative.Craft (FoldSelection (..), selectFoldRequests)

{- | One comparable record: the registry state output, the key's
holding, the wallet's outputs, the pending requests and the held
deposit, read together from the node.
-}
data Around = Around
    { aroundState :: Value
    , aroundHolding :: Value
    , aroundWallet :: Value
    , aroundPending :: Value
    , aroundDeposit :: Value
    }
    deriving stock (Eq, Show)

{- | Read the registry state output, the key's holding, the wallet's
outputs, the pending requests and the held deposit as one comparable
record. Every field comes from the node; nothing is typed. The pending
requests reuse the fold's own reading; an empty registry reads no
pending request. The deposit is the holding output's lovelace, null
with no holding.
-}
readAround :: Attached -> ByteString -> Wallet -> IO Around
readAround at key wallet = do
    let s = savedOf at
    live <- reading at (`attachLive` s)
    outs <- reading at (\v -> liveOutputs openDatumApplication v s)
    walletOuts <- reading at (`Cage.outputsAt` walletAddr wallet)
    pendingResult <-
        try (reading at (\v -> selectFoldRequests v live FoldEvery))
    pendingReqs <- case pendingResult of
        Right reqs -> pure reqs
        Left e -> case fromException e of
            Just (CommandFailure ClientRefusal _ _) -> pure []
            _ -> throwIO e
    let stateJson = case observedRoot live of
            Right root ->
                Aeson.object
                    [ ("stateOutput", toJSON (txInText (fst (liveState live))))
                    , ("root", toJSON (hexT root))
                    ]
            Left _ ->
                Aeson.object
                    [ ("stateOutput", toJSON (txInText (fst (liveState live))))
                    , ("root", toJSON ("unreadable" :: T.Text))
                    ]
        holdingRes = liveOutputFor openDatumApplication s key outs
        holdingJson = case holdingRes of
            Right ((txin, txout), dh) -> case envelopeFromData (dhDatumData dh) of
                Right envelope ->
                    Aeson.object
                        [ ("output", toJSON (txInText txin))
                        , ("value", valueJson txout)
                        , ("envelope", envelopeToJson envelope)
                        ]
                Left _ ->
                    Aeson.object
                        [ ("output", toJSON ("none" :: T.Text))
                        , ("value", toJSON ("none" :: T.Text))
                        , ("envelope", toJSON ("none" :: T.Text))
                        ]
            Left _ ->
                Aeson.object
                    [ ("output", toJSON ("none" :: T.Text))
                    , ("value", toJSON ("none" :: T.Text))
                    , ("envelope", toJSON ("none" :: T.Text))
                    ]
        walletJson =
            toJSON
                [ Aeson.object
                    [ ("output", toJSON (txInText i))
                    , ("value", valueJson o)
                    ]
                | (i, o) <- walletOuts
                ]
        pendingJson =
            toJSON
                [ Aeson.object
                    [ ("output", toJSON (txInText tin))
                    , ("value", valueJson tout)
                    , ("datum", requestDatum tout)
                    ]
                | ((tin, tout), _) <- pendingReqs
                ]
        depositJson = case holdingRes of
            Right ((_, tout), _) -> toJSON (coinOf tout)
            Left _ -> Aeson.Null
        requestDatum tout = case tout ^. datumTxOutL of
            Datum bd -> case binaryDataToData bd of
                Data d -> datumToJson d
            _ -> Aeson.Null
    pure (Around stateJson holdingJson walletJson pendingJson depositJson)

{- | Whether state root, holding output reference, value and datum,
wallet outputs, pending requests and deposit are equal before and
after.
-}
unchanged :: Around -> Around -> Bool
unchanged before after =
    aroundState before == aroundState after
        && aroundHolding before == aroundHolding after
        && aroundWallet before == aroundWallet after
        && aroundPending before == aroundPending after
        && aroundDeposit before == aroundDeposit after
