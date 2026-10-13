{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.CLI.Plan
Description : What a command asks of the registry, decided without a wallet key
License     : Apache-2.0

The checks that turn a caller's inputs into the transactions a command
builds, without signing, submitting or journalling: reading a JSON
document, and refusing an outlay past its allowance. Entry-specific
planning (insert, update, terminate) lives in the application, which
depends on this library; this module names no application.
-}
module Singular.CLI.Plan
    ( -- * Reading what the caller names
      readJson

      -- * What it costs
    , refuseOver
    , refuseUnderfunded
    , emptyFields
    , faucetStep
    , resolveFunding
    , outlayReport
    ) where

import Control.Monad (unless)
import Data.Aeson (Value, object, toJSON, (.=))
import Data.Aeson qualified as Aeson
import Data.Text (Text)
import Data.Text qualified as T

import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.Api.Tx.Out (TxOut)
import Cardano.Ledger.TxIn (TxIn)

import Singular.CLI.Outlay
    ( Outlay (..)
    , outlayTotal
    , walletHeld
    , walletShortfall
    , withinAllowance
    )
import Singular.CLI.Receipt (OutcomeClass (..))
import Singular.CLI.Session (failWith, failWithFields)
import Singular.Registry.Ledger (ConwayEra)
import Singular.Registry.TxBuilder.Edges (selectFunding)
import Singular.Registry.Wallet (bech32Address)

-- | A JSON document the caller named, or a client refusal saying why not.
readJson :: FilePath -> IO Aeson.Value
readJson path =
    Aeson.eitherDecodeFileStrict' path
        >>= either (failWith ClientRefusal . ((path <> ": ") <>)) pure

{- | Stop before anything is signed, sent or journalled when the measured
outlay passes the approved allowance.
-}
refuseOver :: Maybe Integer -> Outlay -> IO ()
refuseOver allowance outlay =
    unless (withinAllowance allowance outlay) $
        failWithFields
            ClientRefusal
            ( "the measured outlay of "
                <> show (outlayTotal outlay)
                <> " lovelace passes the approved allowance of "
                <> maybe "none" show allowance
            )
            [("outlay", outlayReport allowance outlay)]

-- | The outlay and the allowance it is judged against.
outlayReport :: Maybe Integer -> Outlay -> Value
outlayReport allowance o =
    object
        [ "fee" .= outlayFee o
        , "lockedBond" .= outlayBond o
        , "foldFeeBound" .= outlayFoldBound o
        , "total" .= outlayTotal o
        , "allowance" .= allowance
        , "withinAllowance" .= withinAllowance allowance o
        ]

{- | Stop before anything is signed, sent or journalled when
the wallet holds less than what the operation needs. The
shortfall refusal carries the wallet address, what it holds,
what is required, the shortfall, the UTxO count, that the
policy is the client's, and whether what is required is the
fold reserve or the measured outlay. An empty wallet or a
foreign funding output is refused by 'emptyFields' instead,
which carries the wallet address, the UTxO count, what it
holds and the client policy, and no required or shortfall.
-}
refuseUnderfunded
    :: Addr
    -> [(TxIn, TxOut ConwayEra)]
    -> Integer
    -> Text
    -> IO ()
refuseUnderfunded addr utxos required requiredWhat =
    case walletShortfall utxos required of
        Nothing -> pure ()
        Just (held, shortfall) ->
            failWithFields
                ClientRefusal
                ( "the wallet holds "
                    <> show held
                    <> " lovelace but "
                    <> show required
                    <> " is required for "
                    <> T.unpack requiredWhat
                    <> " (client policy)"
                )
                [ ("wallet", toJSON (T.pack (bech32Address addr)))
                , ("held", toJSON held)
                , ("required", toJSON required)
                , ("shortfall", toJSON shortfall)
                , ("utxoCount", toJSON (length utxos))
                , ("policy", toJSON ("client" :: Text))
                , ("requiredIs", toJSON requiredWhat)
                ]

{- | What an empty wallet or a foreign funding output refusal
carries: the wallet address, the UTxO count, what it holds
and the client policy. No required or shortfall applies
there; leave them out.
-}
emptyFields :: Addr -> [(TxIn, TxOut ConwayEra)] -> [(Text, Value)]
emptyFields addr utxos =
    [ ("wallet", toJSON (T.pack (bech32Address addr)))
    , ("utxoCount", toJSON (length utxos))
    , ("held", toJSON (walletHeld utxos))
    , ("policy", toJSON ("client" :: Text))
    ]

{- | The faucet step an empty wallet refusal ends with: how
to fund the wallet, in the floor's own words.
-}
faucetStep :: String
faucetStep =
    "Fund this address, then rerun. On preprod the faucet is "
        <> "https://docs.cardano.org/cardano-testnets/tools/faucet"
        <> ". It pays a single output; send one self-payment "
        <> "afterwards so the wallet also holds an ada-only "
        <> "output to spend as collateral."

{- | The wallet output a write is funded from, or the refusal
that stops it before anything is built: the caller's chosen
output when it is an ada-only output of the wallet, else the
largest ada-only output. A wallet with no ada-only output is
refused with the wallet address and the faucet step; a foreign
funding choice from a funded wallet is refused with the wallet
address and without it. Both carry the wallet fields and the
client policy.
-}
resolveFunding
    :: Addr
    -> [(TxIn, TxOut ConwayEra)]
    -> Maybe TxIn
    -> IO (TxIn, TxOut ConwayEra)
resolveFunding addr utxos chosen =
    case selectFunding chosen utxos of
        Right funded -> pure funded
        Left msg -> case selectFunding Nothing utxos of
            Left _ ->
                failWithFields
                    ClientRefusal
                    ( msg
                        <> " for wallet "
                        <> bech32Address addr
                        <> " (client policy). "
                        <> faucetStep
                    )
                    (emptyFields addr utxos)
            Right _ ->
                failWithFields
                    ClientRefusal
                    ( msg
                        <> " for wallet "
                        <> bech32Address addr
                        <> " (client policy)"
                    )
                    (emptyFields addr utxos)
