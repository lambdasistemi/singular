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
    ( HolderRelease (..)
    , RegistryContext (..)
    )
import Singular.Registry.Types (OnChainRequest (..))

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
                    , hrReleaseOf = \applied pair ->
                        first T.pack (releaseOf applied pair)
                    , hrWithApplication = \applied reference live ctx ->
                        first T.pack (withApplication applied reference live ctx)
                    , hrRequiresToken = False
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
            }

-- | The datum an insertion's request must carry: the holding itself.
checkCarried :: OnChainRequest -> Either String PLC.Data
checkCarried req = case snd (requestDestination req) of
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

{- | How the fold spends one live output and what it releases: the unit
redeemer under the stub script, the protected deposit to the
controller.
-}
releaseOf
    :: SBS.ShortByteString
    -> (TxIn, TxOut ConwayEra)
    -> Either String (TxIn, HolderRelease)
releaseOf _applied (txIn, out) = do
    h <- decodeHolding out
    Right
        ( txIn
        , HolderRelease
            { hrRedeemer = PLC.Constr 0 []
            , hrScript = scriptFromBytes "keri-stub" keriStubScriptBytes
            , hrRecipient = dhController h
            , hrReleased = dhDeposit h
            }
        )

{- | The fold context with the application's part added: the live outputs
as the burn sources a termination draws from, how each is released,
and the output carrying the stub script as a reference script, so a
release spend resolves its script beside the registry's own
references. Without that output the fold attaches the script instead.
-}
withApplication
    :: SBS.ShortByteString
    -> Maybe (TxIn, TxOut ConwayEra)
    -> [(TxIn, TxOut ConwayEra)]
    -> RegistryContext
    -> Either String RegistryContext
withApplication _applied reference live ctx = do
    released <-
        Map.fromList <$> mapM (releaseOf keriStubScriptBytes) live
    pure
        ctx
            { rcHolderUtxos = rcHolderUtxos ctx <> live
            , rcHolderReleases = Map.union (rcHolderReleases ctx) released
            , rcRefUtxos = rcRefUtxos ctx <> maybe [] pure reference
            }
