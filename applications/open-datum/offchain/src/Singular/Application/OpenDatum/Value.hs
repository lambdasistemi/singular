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
    ) where

import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Short qualified as SBS
import Data.Text qualified as T

import Cardano.Ledger.Api.Tx.Out (TxOut)
import Cardano.Ledger.TxIn (TxIn)
import PlutusCore.Data qualified as PLC

import Singular.Application.OpenDatum.Envelope
    ( Control (..)
    , Envelope (..)
    , dataToJson
    , envelopeCbor
    , envelopeFromData
    , envelopeHash
    , envelopeToData
    , envelopeVersion
    , registryBytes
    )
import Singular.Application.OpenDatum.Release
    ( heldOf
    , liveEnvelope
    , releaseOf
    , withApplication
    )
import Singular.Registry.Application
    ( Application (..)
    , ApplicationPin (..)
    , DecodedHolding (..)
    , Decoder (..)
    , HoldingRules (..)
    )
import Singular.Registry.Config (CageConfig (..))
import Singular.Registry.Ledger
    ( AssetName (..)
    , ConwayEra
    , TokenId (..)
    )
import Singular.Registry.TxBuilder.Internal (scriptHashBytes)
import Singular.Registry.Types (OnChainRequest (..))

-- | The open-datum application value.
openDatumApplication :: Application
openDatumApplication =
    Application
        { appName = Just "open-datum"
        , appExecutable = Just "open-datum"
        , appPin = PinByScript "open_datum.open_datum"
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
                    }
        }

-- | A live output's envelope as a holding view.
decodeHolding :: TxOut ConwayEra -> Either String DecodedHolding
decodeHolding out = do
    e <- liveEnvelope out
    pure (holdingOf e)

-- | An envelope as the registry's holding view.
holdingOf :: Envelope -> DecodedHolding
holdingOf e =
    let c = envControl e
        datum = envelopeToData e
    in  DecodedHolding
            { dhDatumData = datum
            , dhDatumCbor = envelopeCbor e
            , dhDatumHash = envelopeHash e
            , dhKey = ctlKey c
            , dhDeposit = ctlDeposit c
            , dhController = ctlController c
            , dhPayload = envPayload e
            , dhDatumJson = dataToJson datum
            , dhPayloadJson = dataToJson (envPayload e)
            }

-- | The datum an insertion's request must carry: the envelope itself.
checkCarried :: OnChainRequest -> Either String PLC.Data
checkCarried req = case snd (requestDestination req) of
    Nothing ->
        Left
            "the insertion's request carries no envelope: its delivered output would hold none"
    Just datum ->
        case envelopeFromData datum of
            Left why ->
                Left
                    ("the envelope the insertion's request carries cannot be read: " <> why)
            Right _ -> Right datum

{- | This registry's holdings of a key among the outputs at the application
address: an envelope of version 1 naming this registry's full state asset,
its pinned active policy and the key, over exactly one of the key's active
token. An output anyone paid under an envelope naming another registry,
policy or key is not a holding of this one.
-}
findHoldings
    :: CageConfig
    -> TokenId
    -> ByteString
    -> [(TxIn, TxOut ConwayEra)]
    -> [((TxIn, TxOut ConwayEra), DecodedHolding)]
findHoldings cfg tid key outs =
    [ (u, holdingOf e)
    | u@(_, o) <- outs
    , Right e <- [liveEnvelope o]
    , let c = envControl e
    , ctlVersion c == envelopeVersion
    , registryBytes (ctlRegistry c) == identity
    , ctlActivePolicy c == SBS.fromShort (cfgActivePolicy cfg)
    , ctlKey c == key
    , heldOf c o == 1
    ]
  where
    identity =
        scriptHashBytes (cfgScriptHash cfg)
            <> let TokenId (AssetName n) = tid in SBS.fromShort n

{- | The key's one live holding, or why there is none (same words as the
command line used before the value, so every refusal stays byte-identical).
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
