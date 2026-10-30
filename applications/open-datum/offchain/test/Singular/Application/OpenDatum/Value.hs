{-# LANGUAGE LambdaCase #-}

-- Validator titles in these fixtures are synthetic identity labels; no released script is loaded.

{- |
Module      : Singular.Application.OpenDatum.Value
Description : The open-datum application value the command line composes
License     : Apache-2.0

Synthetic application values for retained generic library and reader tests.
The title strings and scripts are fixture data; they identify no published
contract and do not load a removed blueprint, manifest or pin.
-}
module Singular.Application.OpenDatum.Value
    ( -- * The mode
      Mode (..)
    , modeTitle
    , applicationIn
    , closedDatumApplication

      -- * The value
    , openDatumApplication
    , liveEnvelope
    ) where

import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Short qualified as SBS
import Data.Text qualified as T

import Cardano.Ledger.Api.Tx.Out (TxOut, datumTxOutL, valueTxOutL)
import Cardano.Ledger.Mary.Value (MaryValue (..), MultiAsset (..))
import Cardano.Ledger.Plutus.Data
    ( Data (..)
    , Datum (..)
    , binaryDataToData
    )
import Cardano.Ledger.TxIn (TxIn)
import Data.Map.Strict qualified as Map
import Lens.Micro ((^.))

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
import Singular.Registry.TxBuilder.Internal
    ( policyIdFromPin
    , scriptHashBytes
    )

-- | Which of the two entry points of the application a registry runs.
data Mode = Open | Closed
    deriving stock (Eq, Show, Ord, Bounded, Enum)

-- | The blueprint title a mode pins: injective, one per mode.
modeTitle :: Mode -> T.Text
modeTitle = \case
    Open -> "open_datum.open_datum"
    Closed -> "open_datum.closed_datum"

-- | The application value for a mode: the open value with the mode's pin title.
applicationIn :: Mode -> Application
applicationIn mode = mkApplication (modeTitle mode)

-- | The closed-datum application value: the open one with a different pin title.
closedDatumApplication :: Application
closedDatumApplication = applicationIn Closed

-- | The open-datum application value: the constant every other module names.
openDatumApplication :: Application
openDatumApplication = mkApplication "open_datum.open_datum"

-- | One application value, a mode that picks its pin.
mkApplication :: T.Text -> Application
mkApplication title =
    Application
        { appName = Just "open-datum"
        , appExecutable = Just "open-datum"
        , appPin = PinByScript title
        , appDecoder = Just (Decoder (first T.pack . decodeHolding))
        , appHolding =
            Just
                HoldingRules
                    { hrFindHoldings = findHoldings
                    , hrLiveOutputFor = liveOutputFor
                    , hrRequiresToken = True
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
            }

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

-- | The envelope a live output carries inline, or why it carries none.
liveEnvelope :: TxOut ConwayEra -> Either String Envelope
liveEnvelope out = case out ^. datumTxOutL of
    Datum bd ->
        let Data d = binaryDataToData bd
        in  envelopeFromData d
    _ -> Left "the live output carries no inline datum"

-- | How many of its own key's active token a live output holds.
heldOf :: Control -> TxOut ConwayEra -> Integer
heldOf c out = case out ^. valueTxOutL of
    MaryValue _ (MultiAsset m) ->
        maybe
            0
            (Map.findWithDefault 0 (AssetName (SBS.toShort (ctlKey c))))
            (Map.lookup (policyIdFromPin (SBS.toShort (ctlActivePolicy c))) m)
