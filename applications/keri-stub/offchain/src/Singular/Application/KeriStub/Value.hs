{- |
Module      : Singular.Application.KeriStub.Value
Description : The keri-stub application value the command line composes
License     : Apache-2.0

The registry's application value ('Singular.Registry.Application') for
the stub: named @keri-stub@, folded by the @keri-stub@ executable,
pinned by hash of its own script, decoding datums into holdings and
holding keys the stub way. The command line composes this value and
hands it to the library; no registry code names this module.
-}
module Singular.Application.KeriStub.Value
    ( -- * The value
      keriStubApplication
    , decodeHolding
    ) where

import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Short qualified as SBS
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Lens.Micro ((^.))

import Cardano.Ledger.Api.Tx.Out (TxOut, datumTxOutL)
import Cardano.Ledger.Plutus.Data
    ( Data (..)
    , Datum (..)
    , binaryDataToData
    )
import PlutusCore.Data qualified as PLC

import Singular.Application.KeriStub.Datum
    ( Holding (..)
    , holdingFromData
    , holdingToData
    )
import Singular.Application.KeriStub.Script
    ( keriStubScriptBytes
    )
import Singular.Registry.Application
    ( Application (..)
    , ApplicationPin (..)
    , DecodedHolding (..)
    , Decoder (..)
    , HoldingRules (..)
    , datumCbor
    , datumHash
    , datumToJson
    )
import Singular.Registry.Config (CageConfig (..))
import Singular.Registry.Ledger
    ( ConwayEra
    , TokenId (..)
    , TxIn
    )
import Singular.Registry.TxBuilder.Internal
    ( computeScriptHash
    , scriptFromBytes
    , scriptHashBytes
    )
import Singular.Registry.TxBuilder.Update
    ( RegistryContext (..)
    )

-- | The keri-stub application value.
keriStubApplication :: Application
keriStubApplication =
    Application
        { appName = Just "keri-stub"
        , appExecutable = Just "keri-stub"
        , appPin = PinByHash pinOfScript
        , appDecoder = Just (Decoder (first T.pack . decodeHolding))
        , appHolding =
            Just
                HoldingRules
                    { hrCheckCarried = first T.pack . checkCarried
                    , hrFindHoldings = findHoldings
                    , hrLiveOutputFor = liveOutputFor
                    , hrWithApplication = \applied reference ctx ->
                        first T.pack (withApplication applied reference ctx)
                    }
        }

-- | The pin: the hash of the stub's own script bytes.
pinOfScript :: SBS.ShortByteString
pinOfScript =
    SBS.toShort
        (scriptHashBytes (computeScriptHash keriStubScriptBytes))

decodeHolding :: TxOut ConwayEra -> Either String DecodedHolding
decodeHolding out = holdingOf <$> liveHolding out

-- | The holding a live output carries inline, or why it carries none.
liveHolding :: TxOut ConwayEra -> Either String Holding
liveHolding out = case out ^. datumTxOutL of
    Datum bd ->
        let Data d = binaryDataToData bd
        in  holdingFromData d
    _ -> Left "the live output carries no inline datum"

-- | A holding as the registry's holding view.
holdingOf :: Holding -> DecodedHolding
holdingOf h =
    let datum = holdingToData h
    in  DecodedHolding
            { dhDatumData = datum
            , dhDatumCbor = datumCbor datum
            , dhDatumHash = datumHash datum
            , dhKey = hdKey h
            , dhDeposit = hdDeposit h
            , dhController = hdController h
            , dhPayload = hdPayload h
            , dhDatumJson = datumToJson datum
            , dhPayloadJson = datumToJson (hdPayload h)
            }

-- | The datum a registration's request must carry: the holding itself.
checkCarried :: Maybe PLC.Data -> Either String PLC.Data
checkCarried carried = case carried of
    Nothing ->
        Left
            "the insertion's request carries no holding: its delivered output would hold none"
    Just datum ->
        case holdingFromData datum of
            Left why ->
                Left
                    ("the holding the insertion's request carries cannot be read: " <> why)
            Right _ -> Right datum

{- | This registry's holdings of a key among the outputs at the
application address: a holding datum naming the key. An output whose
datum cannot be read, or names another key, is not a holding of this
one.
-}
findHoldings
    :: CageConfig
    -> TokenId
    -> ByteString
    -> [(TxIn, TxOut ConwayEra)]
    -> [((TxIn, TxOut ConwayEra), DecodedHolding)]
findHoldings _cfg _tid key outs =
    [ (u, h)
    | u@(_, o) <- outs
    , Right h <- [decodeHolding o]
    , dhKey h == key
    ]

{- | The key's one live holding, or why there is none (same words the
registry's command line uses elsewhere, so every refusal stays
comparable).
-}
liveOutputFor
    :: CageConfig
    -> TokenId
    -> ByteString
    -> [(TxIn, TxOut ConwayEra)]
    -> Either T.Text ((TxIn, TxOut ConwayEra), DecodedHolding)
liveOutputFor cfg tid key outs =
    case findHoldings cfg tid key outs of
        [one] -> Right one
        [] -> Left ("no live output holds key 0x" <> hex key)
        _ ->
            Left
                ( "more than one live output claims key 0x"
                    <> hex key
                )
  where
    hex = T.pack . BC.unpack . B16.encode

{- | The fold context with the application's part added: the stub's script, so
that the fold of a registration finds the script the registry pins for the
application policy when it burns the application tag, and the output carrying
the script as a reference script when the deployment published one. A
termination releases nothing: the custody entered its request when it was
booked.
-}
withApplication
    :: SBS.ShortByteString
    -> Maybe (TxIn, TxOut ConwayEra)
    -> RegistryContext
    -> Either String RegistryContext
withApplication _applied reference ctx =
    Right
        ctx
            { rcWitnessScripts =
                Map.insert
                    applicationScriptKey
                    (scriptFromBytes "keri-stub" keriStubScriptBytes)
                    (rcWitnessScripts ctx)
            , rcRefUtxos = rcRefUtxos ctx <> maybe [] pure reference
            }

{- | Where the stub's script sits among the context's witness scripts, beside
the registry's own, which are keyed by the edge they serve.
-}
applicationScriptKey :: Integer
applicationScriptKey = 100
