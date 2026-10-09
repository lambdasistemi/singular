{- |
Module      : Singular.Registry.Surface
Description : The safe capability surface for builders and commands
License     : Apache-2.0

Everything the registry builders (the main library) and the shipped
@singular@ commands may name: the abstract session, the named read
services, the opaque wallet funding boundary and the plain nomination
types. Nothing here exposes session fields or constructors, the generic
output-query mechanism, history plumbing, unrestricted session wrapping,
evidence internals or provider modules; those stay in @local-services@ (and the
kernel), which production builders and commands must not import. Output
reads are fixed-query named runners (A-001 §2); evidence is unwrapped
with 'value' only, never constructed. The
test, harness and provider closures keep their raw dependencies.

Each re-export below names its defining module beside the group. Names
not listed are deliberately unavailable: a builder or command that
needs one states that concrete consumer conflict before relying on it.
-}
module Singular.Registry.Surface
    ( -- * Abstract session (Singular.Registry.LedgerProvider)
      Session
    , NoWitness
    , SessionBinding (..)
    , SessionId (..)
    , Network (..)

      -- * Named read services (Singular.Registry.SessionIO)
    , outputsAtAddress
    , outputsAtTxIn
    , outputsHolding
    , outputsCarrying
    , mintRecordOf
    , readOutputsAt
    , fundableOutputsAt
    , fundedView
    , sessionScope
    , parameters
    , tip
    , slotStart
    , floorSlot
    , ceilingSlot
    , evaluateTx
    , validityUpper
    , ServiceFailure (..)

      -- * Capabilities (Singular.Registry.Capabilities)
    , Capabilities
    , sessionReceipt
    , withCapSession
    , submitCap
    , confirmCap

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
    , fundingView
    , selectFunding
    , SeedRefusal (..)
    , seedOf
    , carriersOf
    , carriesReference
    , burnCandidates

      -- * Wallet holding (Singular.Registry.Wallet)
    , Wallet (..)
    , loadWallet
    , bech32Address

      -- * Plain nomination types (Singular.Registry.LedgerProvider)
    , Asset
    , MintRecord (..)
    , ReadFailure (..)
    , SubmitResult (..)
    , TipObservation (..)
    , HistoryFailure
    , isHistoryReadFailure
    , Outputs

      -- * Plain ledger types (Singular.Registry.Ledger)
    , ConwayEra
    , ConwayTxBody
    , Addr
    , TxId
    , TxIn
    , TxOut
    , Coin (..)
    , MaryValue
    , PParams
    , PolicyID (..)
    , AssetName (..)
    , SlotNo (..)
    , ScriptHash (..)
    , TokenId (..)
    , Root (..)

      -- * Signing (Singular.Registry.Signing)
    , SignedTx
    , signTx
    , signedTx

      -- * Traces (Singular.Registry.Trace)
    , BackendEvent (..)
    , BodyBuild (..)
    , BodyEnd (..)
    , ErrorClass (..)
    , ReadEvent (..)
    , Evaluation (..)
    , HorizonEnd (..)
    , HorizonWait (..)
    , Query (..)
    , QueryEnd (..)
    , ValiditySelection (..)
    , ViewOpening (..)
    , ViewRelease (..)
    , timedTrace
    , startTimer
    , isoNow

      -- * Provider settings (Singular.Registry.ProviderSettings)
    , ProviderSettings (..)

      -- * Waiting (Singular.Registry.WaitTypes, Singular.Registry.Wait)
    , WaitFailure (..)
    , WaitStage (..)
    , tryOutcome

      -- * Evidence unwrapping (Singular.Registry.Evidence)
    , Evidenced (value)

      -- * Phase rendering (Singular.Registry.TraceRender)
    , appendPhaseLine
    , backendPhase
    , readPhase

      -- * Time acquisition (Singular.Registry.TimeSource)
    , TimeSource (..)
    ) where

import Singular.Registry.Capabilities
    ( Capabilities
    , confirmCap
    , sessionReceipt
    , submitCap
    , withCapSession
    )
import Singular.Registry.Evidence
    ( Evidenced (value)
    , NoWitness
    , SessionBinding (..)
    , SessionId (..)
    )
import Singular.Registry.Ledger
    ( Addr
    , AssetName (..)
    , Coin (..)
    , ConwayEra
    , ConwayTxBody
    , MaryValue
    , PParams
    , PolicyID (..)
    , Root (..)
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
    , SubmitResult (..)
    , TipObservation (..)
    , isHistoryReadFailure
    )
import Singular.Registry.ProviderSettings (ProviderSettings (..))
import Singular.Registry.SessionIO
    ( ceilingSlot
    , evaluateTx
    , floorSlot
    , fundableOutputsAt
    , fundedView
    , mintRecordOf
    , outputsAtAddress
    , outputsAtTxIn
    , outputsCarrying
    , outputsHolding
    , parameters
    , readOutputsAt
    , sessionScope
    , slotStart
    , tip
    , validityUpper
    )
import Singular.Registry.SessionServices (ServiceFailure (..))
import Singular.Registry.Signing (SignedTx, signTx, signedTx)
import Singular.Registry.TimeSource (TimeSource (..))
import Singular.Registry.Trace
    ( BackendEvent (..)
    , BodyBuild (..)
    , BodyEnd (..)
    , ErrorClass (..)
    , Evaluation (..)
    , HorizonEnd (..)
    , HorizonWait (..)
    , Query (..)
    , QueryEnd (..)
    , ReadEvent (..)
    , ValiditySelection (..)
    , ViewOpening (..)
    , ViewRelease (..)
    , isoNow
    , startTimer
    , timedTrace
    )
import Singular.Registry.TraceRender
    ( appendPhaseLine
    , backendPhase
    , readPhase
    )
import Singular.Registry.Wait (tryOutcome)
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
    , carriesReference
    , chosenFunding
    , covering
    , coveringFunding
    , fundable
    , fundingOutputs
    , fundingView
    , narrowFunding
    , renderFundingRefusal
    , seedOf
    , selectFunding
    , walletOutputs
    )
