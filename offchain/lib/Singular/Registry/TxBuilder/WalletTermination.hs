{-# LANGUAGE LambdaCase #-}

{- |
Module      : Singular.Registry.TxBuilder.WalletTermination
Description : Probe a wallet for the custody of a key and book its termination
License     : Apache-2.0

The termination of a key whose token sits in the caller's own wallet: the
wallet output holding the key's one active token is the custody, its holder's
signature is the spending condition ('WalletGuarded'), and the shared
termination booking builds the transaction. This module is the one place the
update-terminal story finds that custody, so that what the story calls a
refusal is decided here, from the provider's answers, and can be driven in
process over a stub session.

A probe has two outcomes. It books, or it reports the specific absence of
custody: the registry's state output and the wallet's outputs were read and
no wallet output carries the key's token. Anything else is not an outcome of
the probe: a provider that cannot answer, a registry state that is not there,
several outputs claiming the key, or a booking the builder refuses all
propagate as the failures they are.
-}
module Singular.Registry.TxBuilder.WalletTermination
    ( TerminationProbe (..)
    , CustodyAbsence (..)
    , probeWalletTermination
    , expectNoCustody
    ) where

import Data.ByteString (ByteString)
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Short qualified as SBS
import Data.Map.Strict qualified as Map
import Lens.Micro ((^.))

import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.Api.Tx.Out (TxOut, coinTxOutL, valueTxOutL)
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Mary.Value
    ( AssetName (..)
    , MaryValue (..)
    , MultiAsset (..)
    )
import Cardano.Ledger.TxIn (TxIn)
import Cardano.Slotting.Slot (SlotNo (..))
import Cardano.Tx.Ledger (ConwayTx)

import Singular.Registry.Config (CageConfig (..))
import Singular.Registry.Evidence (NoWitness)
import Singular.Registry.Ledger (ConwayEra, TokenId)
import Singular.Registry.LedgerProvider (Session)
import Singular.Registry.LedgerProvider qualified as Provider
import Singular.Registry.SessionIO qualified as Cage
import Singular.Registry.TxBuilder.Internal
    ( cageAddrFromCfg
    , cagePolicyIdFromCfg
    , findStateUtxo
    , policyIdFromPin
    )
import Singular.Registry.TxBuilder.TerminationBooking
    ( CustodyAuthority (..)
    , TerminationBooking (..)
    , bookTerminationImpl
    )

-- | What probing a wallet for the custody of a key came to.
data TerminationProbe
    = {- | The wallet's outputs were read and none carries the key's token; the
      text says so.
      -}
      NoCustodyToBook String
    | -- | The unsigned termination booking out of the custody found
      Booked ConwayTx

{- | The evidence a negative leg of the story publishes: that the wallet's
outputs were read and none of them carries the key's token. It can only be
had from a probe that reported that absence ('expectNoCustody').
-}
newtype CustodyAbsence = CustodyAbsence {absenceText :: String}
    deriving stock (Eq, Show)

{- | What a negative leg of the story requires of its probe: the specific
absence of custody. A probe that booked is the leg's failure and returns the
booking; the absence is evidence. Whatever else can go wrong while probing is
not a result of the probe and propagates out of it.
-}
expectNoCustody
    :: IO TerminationProbe -> IO (Either ConwayTx CustodyAbsence)
expectNoCustody probe =
    probe >>= \case
        NoCustodyToBook why -> pure (Right (CustodyAbsence why))
        Booked tx -> pure (Left tx)

{- | Probe the wallet for the custody of the key and book its termination
when found. The addition is what the requester pays in beside the custody so
that the request output meets the ledger's minimum.
-}
probeWalletTermination
    :: CageConfig
    -> Session NoWitness IO
    -> TokenId
    -- ^ The registry token
    -> Addr
    -- ^ The wallet: fee payer, change address and holder of the custody
    -> Coin
    -- ^ The ordinary addition
    -> ByteString
    -- ^ The key
    -> IO TerminationProbe
probeWalletTermination cfg v tid payer added key = do
    -- Both reads must succeed before anything is concluded: a probe that
    -- could not read the registry's state or the wallet's outputs has
    -- learned nothing about custody, and says so by failing.
    stateUtxos <- Cage.outputsAt v (cageAddrFromCfg cfg (network cfg))
    stateRef <- case findStateUtxo (cagePolicyIdFromCfg cfg) tid stateUtxos of
        Just (txIn, _) -> pure txIn
        Nothing ->
            ioError
                ( userError
                    "the registry's state output was not found at the registry's address, so nothing is concluded about custody"
                )
    held <- Cage.outputsAt v payer
    case carriers cfg key held of
        [] ->
            pure
                ( NoCustodyToBook
                    ( "the wallet's "
                        <> show (length held)
                        <> " outputs were read and none carries the active witness of key 0x"
                        <> BC.unpack (B16.encode key)
                        <> ", so there is no custody to book against"
                    )
                )
        [custody] -> Booked <$> bookOut cfg v tid stateRef payer added key custody
        several ->
            ioError
                ( userError
                    ( "the wallet holds "
                        <> show (length several)
                        <> " outputs that carry the active witness of key 0x"
                        <> BC.unpack (B16.encode key)
                        <> ": the custody is ambiguous, and no termination is booked or refused for it"
                    )
                )

-- | The termination booking out of the custody found; its refusals are the builder's.
bookOut
    :: CageConfig
    -> Session NoWitness IO
    -> TokenId
    -> TxIn
    -> Addr
    -> Coin
    -> ByteString
    -> (TxIn, TxOut ConwayEra)
    -> IO ConwayTx
bookOut cfg v tid stateRef payer (Coin added) key custody = do
    observed <- Cage.tip v
    let Coin custodyLovelace = snd custody ^. coinTxOutL
        Coin tip = defaultTip cfg
    bookTerminationImpl
        cfg
        v
        tid
        stateRef
        TerminationBooking
            { tbKey = key
            , tbDeclaredTip = Coin tip
            , tbCarrier = Coin (custodyLovelace + added - tip)
            , tbNonce = toInteger (unSlotNo (Provider.observedSlot observed))
            , tbCustody = custody
            , tbOrdinaryAdded = Coin added
            , tbCustodyAuthority = WalletGuarded
            , tbRequiredSigners = []
            }
        payer

-- | The outputs among these that carry the key's active token.
carriers
    :: CageConfig
    -> ByteString
    -> [(TxIn, TxOut ConwayEra)]
    -> [(TxIn, TxOut ConwayEra)]
carriers cfg key = filter holdsKey
  where
    active = policyIdFromPin (cfgActivePolicy cfg)
    holdsKey (_, o) =
        let MaryValue _ (MultiAsset ma) = o ^. valueTxOutL
        in  maybe
                False
                (Map.member (AssetName (SBS.toShort key)))
                (Map.lookup active ma)
