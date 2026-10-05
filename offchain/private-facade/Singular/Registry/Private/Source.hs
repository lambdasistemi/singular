{-# LANGUAGE DataKinds #-}
{-# LANGUAGE PatternSynonyms #-}

{- | Raw private-devnet facts from a real acquired LSQ. This module exports
neither a registry provider nor a compatibility view. The HTTP fixture owns
this connection; a packaged command only receives the fixture's HTTP URL.
-}
module Singular.Registry.Private.Source
    ( LedgerSource (..)
    , readLedgerSource
    , TimeSourceFacts (..)
    , timeFactsOf
    , readTimeSourceFacts
    , OutputSourceFacts (..)
    , readOutputSourceFacts
    , readRegistrations
    ) where

import Cardano.Ledger.Api.Tx.Out (TxOut)
import Cardano.Ledger.Coin (Coin)
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Core (PParams)
import Cardano.Ledger.Credential (Credential)
import Cardano.Ledger.Keys (KeyRole (Staking))
import Cardano.Ledger.State (UTxO (..))
import Cardano.Ledger.TxIn (TxIn)
import Cardano.Node.Client.N2C.LocalStateQuery
    ( queryAcquiredLSQ
    , withAcquiredLSQ
    )
import Cardano.Node.Client.N2C.Types (LSQChannel)
import Cardano.Node.Client.Types (Block)
import Cardano.Slotting.Slot (EpochNo)
import Cardano.Slotting.Time (SystemStart)
import Codec.Serialise (serialise)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LBS
import Data.Map.Strict (Map)
import Data.Set (Set)
import Ouroboros.Consensus.Cardano.Block
    ( pattern QueryIfCurrentConway
    )
import Ouroboros.Consensus.Cardano.Node ()
import Ouroboros.Consensus.HardFork.Combinator.Ledger.Query
    ( QueryHardFork (GetInterpreter)
    , pattern QueryHardFork
    )
import Ouroboros.Consensus.Ledger.Query
    ( Query (BlockQuery, GetChainBlockNo, GetChainPoint, GetSystemStart)
    )
import Ouroboros.Consensus.Protocol.Praos.Header ()
import Ouroboros.Consensus.Shelley.Ledger.NetworkProtocolVersion ()
import Ouroboros.Consensus.Shelley.Ledger.Query
    ( pattern GetCurrentPParams
    , pattern GetEpochNo
    , pattern GetFilteredDelegationsAndRewardAccounts
    , pattern GetUTxOWhole
    )
import Ouroboros.Consensus.Shelley.Ledger.SupportsProtocol ()
import Ouroboros.Network.Block (BlockNo, Point)
import Ouroboros.Network.Point (WithOrigin)

data LedgerSource = LedgerSource
    { sourcePoint :: Point Block
    , sourceBlockNo :: WithOrigin BlockNo
    , sourceEpoch :: EpochNo
    , sourceParameters :: PParams ConwayEra
    , sourceOutputs :: Map TxIn (TxOut ConwayEra)
    , sourceSystemStart :: SystemStart
    , sourceEraHistory :: ByteString
    }

readLedgerSource :: LSQChannel -> IO LedgerSource
readLedgerSource channel = withAcquiredLSQ channel $ \handle -> do
    let query :: Query Block result -> IO result
        query = queryAcquiredLSQ handle
    point <- query GetChainPoint
    height <- query GetChainBlockNo
    epoch <-
        expectConway "epoch"
            =<< query (BlockQuery (QueryIfCurrentConway GetEpochNo))
    parameters <-
        expectConway "parameters"
            =<< query (BlockQuery (QueryIfCurrentConway GetCurrentPParams))
    UTxO outputs <-
        expectConway "UTxO"
            =<< query (BlockQuery (QueryIfCurrentConway GetUTxOWhole))
    start <- query GetSystemStart
    history <-
        LBS.toStrict . serialise
            <$> query (BlockQuery (QueryHardFork GetInterpreter))
    pure
        (LedgerSource point height epoch parameters outputs start history)

{- | Time publication needs these three raw facts, not a fresh whole UTxO
and parameter dump for every empty block. They still share one acquisition.
-}
data TimeSourceFacts = TimeSourceFacts
    { timeSourcePoint :: Point Block
    , timeSourceSystemStart :: SystemStart
    , timeSourceEraHistory :: ByteString
    }

timeFactsOf :: LedgerSource -> TimeSourceFacts
timeFactsOf source =
    TimeSourceFacts
        (sourcePoint source)
        (sourceSystemStart source)
        (sourceEraHistory source)

readTimeSourceFacts :: LSQChannel -> IO TimeSourceFacts
readTimeSourceFacts channel = withAcquiredLSQ channel $ \handle -> do
    point <- queryAcquiredLSQ handle GetChainPoint
    start <- queryAcquiredLSQ handle GetSystemStart
    history <-
        LBS.toStrict . serialise
            <$> queryAcquiredLSQ handle (BlockQuery (QueryHardFork GetInterpreter))
    pure (TimeSourceFacts point start history)

-- | A current output response needs the exact acquired point and full UTxO.
data OutputSourceFacts = OutputSourceFacts
    { outputSourcePoint :: Point Block
    , outputSourceOutputs :: Map TxIn (TxOut ConwayEra)
    }

readOutputSourceFacts :: LSQChannel -> IO OutputSourceFacts
readOutputSourceFacts channel = withAcquiredLSQ channel $ \handle -> do
    point <- queryAcquiredLSQ handle GetChainPoint
    UTxO outputs <-
        expectConway "UTxO"
            =<< queryAcquiredLSQ
                handle
                (BlockQuery (QueryIfCurrentConway GetUTxOWhole))
    pure (OutputSourceFacts point outputs)

readRegistrations
    :: LSQChannel
    -> Set (Credential Staking)
    -> IO (Point Block, Map (Credential Staking) Coin)
readRegistrations channel credentials = withAcquiredLSQ channel $ \handle -> do
    point <- queryAcquiredLSQ handle GetChainPoint
    rewards <-
        snd
            <$> ( expectConway "registration"
                    =<< queryAcquiredLSQ
                        handle
                        ( BlockQuery
                            ( QueryIfCurrentConway
                                (GetFilteredDelegationsAndRewardAccounts credentials)
                            )
                        )
                )
    pure (point, rewards)

expectConway :: String -> Either failure result -> IO result
expectConway operation =
    either
        ( const
            (fail ("private facade " <> operation <> ": node is not in Conway"))
        )
        pure
