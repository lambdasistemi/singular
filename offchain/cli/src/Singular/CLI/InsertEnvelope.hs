{- |
Module      : Singular.CLI.InsertEnvelope
Description : The envelope an insert books, from the sources the command holds
License     : Apache-2.0

An insert holds a saved registry, the key it was given, the payment key
hash of whoever signs (or, for a preview, of the address named), a deposit
and a payload. This is the one place they become the open-datum envelope:
the state asset from the registry's script hash and saved token, the
active policy from its saved config, the rest as given. Nothing about the
registry or the caller is typed anywhere else.
-}
module Singular.CLI.InsertEnvelope
    ( insertEnvelope
    ) where

import Data.ByteString (ByteString)
import Data.ByteString.Short qualified as SBS
import PlutusCore.Data qualified as PLC

import Singular.Application.OpenDatum.Build (buildEnvelope)
import Singular.Application.OpenDatum.Envelope
    ( Envelope
    , StateAsset (..)
    )
import Singular.Registry.Config (CageConfig (..))
import Singular.Registry.Ledger (AssetName (..), TokenId (..))
import Singular.Registry.TxBuilder.Internal (scriptHashBytes)

{- | The envelope an insert books.

Arguments, in order: the registry's saved config and token, the key, the
controller's payment key hash, the deposit, the payload.
-}
insertEnvelope
    :: CageConfig
    -> TokenId
    -> ByteString
    -> ByteString
    -> Integer
    -> PLC.Data
    -> Envelope
insertEnvelope cfg (TokenId (AssetName name)) =
    buildEnvelope
        (StateAsset (scriptHashBytes (cfgScriptHash cfg)) (SBS.fromShort name))
        (SBS.fromShort (cfgActivePolicy cfg))
