{- |
Module      : Negative.Read
Description : The before and after reads around a refusal
License     : Apache-2.0

After every refusal the host reads the registry state output, the
key's holding and the wallet's outputs again. The pair passes only
when the state root, the holding's output reference, value and datum,
and the wallet's outputs are equal before and after.
-}
module Negative.Read
    ( -- * Readings
      Around (..)
    , readAround
    , unchanged
    ) where

import Data.Aeson (Value, toJSON)
import Data.Aeson qualified as Aeson
import Data.ByteString (ByteString)
import Data.Text qualified as T

import Singular.Application.OpenDatum.Envelope
    ( envelopeFromData
    , envelopeToJson
    )
import Singular.Application.OpenDatum.Value (openDatumApplication)
import Singular.CLI.Attached (Attached (..), reading, savedOf)
import Singular.CLI.Live
    ( Live (..)
    , attachLive
    , liveOutputFor
    , liveOutputs
    , observedRoot
    , txInText
    , valueJson
    )
import Singular.CLI.Registry (hexT)
import Singular.Registry.Application (DecodedHolding (..))
import Singular.Registry.SessionIO qualified as Cage
import Singular.Registry.Wallet (Wallet (..))

{- | One comparable record: the registry state output, the key's
holding and the wallet's outputs, read together from the node.
-}
data Around = Around
    { aroundState :: Value
    , aroundHolding :: Value
    , aroundWallet :: Value
    }
    deriving stock (Eq, Show)

{- | Read the registry state output, the key's holding and the wallet's
outputs as one comparable record. Every field comes from the node;
nothing is typed.
-}
readAround :: Attached -> ByteString -> Wallet -> IO Around
readAround at key wallet = do
    let s = savedOf at
    live <- reading at (`attachLive` s)
    outs <- reading at (\v -> liveOutputs openDatumApplication v s)
    walletOuts <- reading at (`Cage.outputsAt` walletAddr wallet)
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
        holdingJson = case liveOutputFor openDatumApplication s key outs of
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
    pure (Around stateJson holdingJson walletJson)

{- | Whether state root, holding output reference, value and datum, and
wallet outputs are equal before and after.
-}
unchanged :: Around -> Around -> Bool
unchanged before after =
    aroundState before == aroundState after
        && aroundHolding before == aroundHolding after
        && aroundWallet before == aroundWallet after
