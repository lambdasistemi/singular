{- |
Module      : Singular.Application.OpenDatum.Requests.Refusal
Description : Why a request builder declines to build a transaction
License     : Apache-2.0

A request builder returns a 'Refusal' instead of a transaction it knows the
open-datum request validator, or the ledger, would refuse. Every refusal names
a fact about the chain or the arguments the caller can act on. A failed read
of the chain is not a refusal: it throws, as the other builders' reads do.

The booking command raises two more before it builds, from the registry state
of the key it books.
-}
module Singular.Application.OpenDatum.Requests.Refusal
    ( Refusal (..)
    , Operation (..)
    ) where

import Data.Text (Text)

import Cardano.Ledger.Coin (Coin)
import Cardano.Ledger.Hashes (ScriptHash)
import Cardano.Ledger.TxIn (TxIn)

-- | The operations that spend a pending registration by time.
data Operation
    = -- | The refund address takes everything back inside its window.
      Reclaim
    | -- | Anyone returns the deposit once the window has ended.
      Cleanup
    deriving stock (Eq, Show)

-- | Why a builder declined.
data Refusal
    = -- | The registry has no configuration record at the request address.
      NoConfiguration
    | {- | The registry has several configuration records, so the one a
      booking must read is not decided; the count found.
      -}
      AmbiguousConfiguration Int
    | -- | The payer's address holds no ADA-only output for fee and collateral.
      PayerHasNoFunding
    | -- | The payer's payment credential is a script, which cannot sign.
      PayerIsNotAKey
    | -- | The configuration's booking width holds no usable validity window.
      BookingWidthTooNarrow Integer
    | {- | The deposit is below the minimum ADA of the holding it commits, so
      no fold could ever deliver it; the deposit and that minimum.
      -}
      DepositBelowHolding Coin Coin
    | -- | The holding to spend is not on the chain.
      HoldingNotFound TxIn
    | -- | The output is not a live holding of this application.
      NotALiveHolding TxIn
    | -- | The payer's payment key is not the holding's controller.
      PayerIsNotController
    | -- | The output to spend is not on the chain.
      PendingNotFound TxIn
    | -- | The output is not a pending registration of this script.
      NotAPendingRegistration TxIn
    | -- | The refund address is a script and cannot sign a reclaim.
      RefundAddressIsScript
    | {- | The payer is not the refund address: one wallet signs a reclaim and
      funds it, and the fee covers that one signature.
      -}
      PayerIsNotRefundAddress
    | -- | The chain has not reached the window of the operation.
      WindowNotOpen Operation
    | -- | The chain is past the window of the operation.
      WindowClosed Operation
    | -- | The reference output named for the script is not on the chain.
      ReferenceScriptMissing TxIn
    | {- | The reference output carries no script, or another one: the hash
      it carries, when it carries a script, and the expected hash.
      -}
      ReferenceScriptMismatch TxIn (Maybe ScriptHash) ScriptHash
    | {- | The registry state holds the key as active, with or without a
      termination booked; the key as text.
      -}
      KeyAlreadyRegistered Text
    | {- | The registry state holds the key as registered and then terminated;
      the key as text.
      -}
      KeyWasTerminated Text
    | -- | The transaction builder itself failed; its message.
      BuildFailed Text
    deriving stock (Eq, Show)
