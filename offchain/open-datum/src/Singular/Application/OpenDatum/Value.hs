{- |
Module      : Singular.Application.OpenDatum.Value
Description : The open-datum application value the command line composes
License     : Apache-2.0

The registry's application value ('Singular.Registry.Application') for
the open datum: named @open-datum@, folded by the @open-datum@
executable, pinned by script @open_datum.open_datum@ applied to the
registry identity, decoding datums into envelopes and holding keys the
envelope way. The command line composes this value and hands it to the
library; no registry code names this module.
-}
module Singular.Application.OpenDatum.Value
    ( -- * The value
      openDatumApplication

      -- * Its hooks
    , ODDecoder (..)
    , ODHolding (..)
    ) where

import Data.Bifunctor (first)
import Data.ByteString.Short qualified as SBS
import Data.Text (Text)
import Data.Text qualified as T

import Cardano.Ledger.Api.Tx.Out (TxOut)
import Cardano.Ledger.TxIn (TxIn)

import Singular.Application.OpenDatum.Envelope (Control, Envelope)
import Singular.Application.OpenDatum.Release
    ( heldOf
    , liveEnvelope
    , releaseOf
    , withApplication
    )
import Singular.Registry.Application
    ( Application (..)
    , ApplicationPin (..)
    )
import Singular.Registry.Ledger (ConwayEra)
import Singular.Registry.TxBuilder.Update
    ( HolderRelease
    , RegistryContext
    )

-- | How the open datum reads a datum: into the envelope a live output carries.
newtype ODDecoder = ODDecoder
    { runODDecoder :: TxOut ConwayEra -> Either Text Envelope
    }

-- | How the open datum holds keys: the envelope's lookup and release.
data ODHolding = ODHolding
    { odHeldOf :: Control -> TxOut ConwayEra -> Integer
    , odReleaseOf
        :: SBS.ShortByteString
        -> (TxIn, TxOut ConwayEra)
        -> Either Text (TxIn, HolderRelease)
    , odWithApplication
        :: SBS.ShortByteString
        -> Maybe (TxIn, TxOut ConwayEra)
        -> [(TxIn, TxOut ConwayEra)]
        -> RegistryContext
        -> Either Text RegistryContext
    }

-- | The open-datum application value.
openDatumApplication :: Application ODDecoder ODHolding
openDatumApplication =
    Application
        { appName = Just "open-datum"
        , appExecutable = Just "open-datum"
        , appPin = PinByScript "open_datum.open_datum"
        , appDecoder = Just (ODDecoder (first T.pack . liveEnvelope))
        , appHolding =
            Just
                ODHolding
                    { odHeldOf = heldOf
                    , odReleaseOf = \applied pair ->
                        first T.pack (releaseOf applied pair)
                    , odWithApplication = \applied reference live ctx ->
                        first T.pack (withApplication applied reference live ctx)
                    }
        }
