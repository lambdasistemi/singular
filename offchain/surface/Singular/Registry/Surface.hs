{- |
Module      : Singular.Registry.Surface
Description : The safe capability surface for builders and commands
License     : Apache-2.0

Everything the registry builders (the main library) and the shipped
@singular@ commands may name: the abstract session, the named read
services, the opaque wallet funding boundary and the plain nomination
types. Nothing here exposes session fields or constructors, output
queries, history plumbing, unrestricted session wrapping, evidence
internals or provider modules; those stay in @local-services@ (and the
kernel), which production builders and commands must not import. The
test, harness and provider closures keep their raw dependencies.

Each re-export below names its defining module beside the group. Names
not listed are deliberately unavailable: a builder or command that
needs one states that concrete consumer conflict before relying on it.
-}
module Singular.Registry.Surface
    ( -- * Abstract session (Singular.Registry.LedgerProvider)
      Session
    , NoWitness
    , Network (..)

      -- * Named read services (Singular.Registry.SessionIO)
    , outputsAt
    , parameters
    , tip
    , slotStart
    , floorSlot
    , ceilingSlot
    , evaluateTx
    , validityUpper
    , ServiceFailure (..)

      -- * Opaque wallet funding (Singular.Registry.WalletOutputs)
    , WalletOutputs
    , walletOutputs
    , fundable
    , fundingOutputs
    , coveringFunding
    , covering
    , FundingRefusal (..)
    , renderFundingRefusal
    , chosenFunding
    , FundingViewRefusal (..)
    , narrowFunding
    , SeedRefusal (..)
    , seedOf
    , carriersOf
    , burnCandidates

      -- * Wallet holding (Singular.Registry.Wallet)
    , Wallet (..)
    , loadWallet
    , bech32Address

      -- * Plain nomination types (Singular.Registry.LedgerProvider)
    , Asset
    , MintRecord (..)
    , ReadFailure (..)
    , TipObservation (..)
    , HistoryFailure
    , Outputs

      -- * Plain ledger types (Singular.Registry.Ledger)
    , ConwayEra
    , Addr
    , TxId
    , TxIn
    , TxOut
    , Coin (..)
    , MaryValue
    , PolicyID (..)
    , AssetName (..)
    , SlotNo (..)
    , ScriptHash (..)
    , TokenId (..)

      -- * Signing (Singular.Registry.Signing)
    , SignedTx
    , signTx
    , signedTx

      -- * Traces (Singular.Registry.Trace)
    , BodyBuild (..)
    , BodyEnd (..)
    , ReadEvent (..)
    , Evaluation (..)
    , timedTrace

      -- * Provider settings (Singular.Registry.ProviderSettings)
    , ProviderSettings (..)

      -- * Waiting (Singular.Registry.WaitTypes)
    , WaitFailure (..)
    , WaitStage (..)

      -- * Phase rendering (Singular.Registry.TraceRender)
    , appendPhaseLine
    , backendPhase
    , readPhase

      -- * Time acquisition (Singular.Registry.TimeSource)
    , TimeSource (..)
    ) where

import Singular.Registry.Evidence (NoWitness)
import Singular.Registry.Ledger
    ( Addr
    , AssetName (..)
    , Coin (..)
    , ConwayEra
    , MaryValue
    , PolicyID (..)
    , ScriptHash (..)
    , SlotNo (..)
    , TokenId (..)
    , TxId
    , TxIn
    , TxOut
    )
import Singular.Registry.LedgerProvider
    ( Asset
    , HistoryFailure
    , MintRecord (..)
    , Network (..)
    , Outputs
    , ReadFailure (..)
    , Session
    , TipObservation (..)
    )
import Singular.Registry.ProviderSettings (ProviderSettings (..))
import Singular.Registry.SessionIO
    ( ceilingSlot
    , evaluateTx
    , floorSlot
    , outputsAt
    , parameters
    , slotStart
    , tip
    , validityUpper
    )
import Singular.Registry.SessionServices (ServiceFailure (..))
import Singular.Registry.Signing (SignedTx, signTx, signedTx)
import Singular.Registry.TimeSource (TimeSource (..))
import Singular.Registry.Trace
    ( BodyBuild (..)
    , BodyEnd (..)
    , Evaluation (..)
    , ReadEvent (..)
    , timedTrace
    )
import Singular.Registry.TraceRender
    ( appendPhaseLine
    , backendPhase
    , readPhase
    )
import Singular.Registry.WaitTypes (WaitFailure (..), WaitStage (..))
import Singular.Registry.Wallet
    ( Wallet (..)
    , bech32Address
    , loadWallet
    , walletAddr
    )
import Singular.Registry.WalletOutputs
    ( FundingRefusal (..)
    , FundingViewRefusal (..)
    , SeedRefusal (..)
    , WalletOutputs
    , burnCandidates
    , carriersOf
    , chosenFunding
    , covering
    , coveringFunding
    , fundable
    , fundingOutputs
    , narrowFunding
    , renderFundingRefusal
    , seedOf
    , walletOutputs
    )
