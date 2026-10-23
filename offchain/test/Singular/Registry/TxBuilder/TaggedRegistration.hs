{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.Registry.TxBuilder.TaggedRegistration
Description : What a registration booking carries on the tagged-request law
License     : Apache-2.0

A registration is booked as a tagged request: the request output carries the
registration datum (constructor 3 of the cage datum) naming the registry, the
key and the refund address, and the transaction mints one tag under each of
the request policy and the application policy. The earlier law booked an
untagged request (constructor 0) and minted an approval under the application
policy.

One observation serves every route that books a registration. It reads the
transaction a route submitted, the request output's datum by the library's own
reader, and compares the datum's kind, registry, key and refund address with
the values the caller passed in, and the mint with the two policies the
registry pins. It tests the request output and the mint, nothing else: not the
fee, the collateral, the destination or the fold.
-}
module Singular.Registry.TxBuilder.TaggedRegistration
    ( carriesTaggedRegistration
    ) where

import Data.ByteString (ByteString)
import Data.Foldable (toList)
import Data.Map.Strict qualified as Map
import Lens.Micro ((^.))
import PlutusTx.Builtins.Internal (BuiltinByteString (..))
import Test.Hspec

import Cardano.Ledger.Api.Tx (bodyTxL)
import Cardano.Ledger.Api.Tx.Body (mintTxBodyL, outputsTxBodyL)
import Cardano.Ledger.Api.Tx.Out (addrTxOutL)
import Cardano.Ledger.BaseTypes (Network (Testnet))
import Cardano.Ledger.Mary.Value (MultiAsset (..))
import Cardano.Tx.Ledger (ConwayTx)

import Singular.Registry.Config (CageConfig (..))
import Singular.Registry.TxBuilder.BookingFixture
    ( cfg
    , payer
    , requestPin
    , tokenId
    )
import Singular.Registry.TxBuilder.Internal
    ( addrKeyHashBytes
    , extractCageDatum
    , onChainTokenId
    , policyIdFromPin
    , requestAddrFromCfg
    )
import Singular.Registry.Types
    ( CageDatum (..)
    , OnChainRegistrationRequest (..)
    )

-- | The kind of cage datum, with the constructor index the wire gives it.
kindOf :: CageDatum -> String
kindOf d = case d of
    RequestDatum _ -> "RequestDatum (constructor 0)"
    StateDatum _ -> "StateDatum (constructor 1)"
    AbsentCustody _ -> "AbsentCustody (constructor 2)"
    RegistrationDatum _ -> "RegistrationDatum (constructor 3)"
    TerminationDatum _ -> "TerminationDatum (constructor 4)"

{- | The registration booking a route submitted carries the tagged request:
its one request output holds the registration datum for this registry, the
key asked for and the payer as the refund address, and it mints one tag under
each pinned policy and nothing else. The key is the one the caller passed.
-}
carriesTaggedRegistration :: ByteString -> ConwayTx -> IO ()
carriesTaggedRegistration key tx = do
    let requests =
            [ o
            | o <- toList (tx ^. bodyTxL . outputsTxBodyL)
            , o ^. addrTxOutL == requestAddrFromCfg cfg tokenId Testnet
            ]
    datum <- case requests of
        [o] ->
            maybe
                (fail "the request output carries no cage datum")
                pure
                (extractCageDatum o)
        outs ->
            fail ("the booking has " <> show (length outs) <> " request outputs")
    case datum of
        RegistrationDatum r -> do
            regRegistry r `shouldBe` onChainTokenId tokenId
            regKey r `shouldBe` key
            regRefundAddress r
                `shouldBe` BuiltinByteString (addrKeyHashBytes payer)
            let MultiAsset minted = tx ^. bodyTxL . mintTxBodyL
            Map.map (sum . Map.elems) minted
                `shouldBe` Map.fromList
                    [ (policyIdFromPin requestPin, 1)
                    , (policyIdFromPin (cfgApplicationPolicy cfg), 1)
                    ]
        other ->
            expectationFailure
                ( "the request output carries a "
                    <> kindOf other
                    <> ", not the tagged RegistrationDatum (constructor 3)"
                )
