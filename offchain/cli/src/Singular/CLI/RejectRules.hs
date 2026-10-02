{-# LANGUAGE LambdaCase #-}

{- |
Module      : Singular.CLI.RejectRules
Description : What decides whether a reject may be built, and what it must refund
License     : Apache-2.0

The decisions of @registry reject@ that need no node and no wallet.

A reject takes every pending request of the registry, in whatever window
it is, because the chain admits it in every window. The protection of a
request's owner, and of the registry's fold, is therefore here: nothing is
built while any pending request is still inside its processing window, in
which the registry may fold it, or its retract window, in which its owner
may take it back.

What the built reject owes each owner is checked as well, from its
outputs: the whole owed amount in the one output designated for that
request, to that request's owner. The chain accepts that shape only; an
amount split across several outputs to the same owner is not a refund it
accepts (#361), so such a transaction is never signed.
-}
module Singular.CLI.RejectRules
    ( -- * Whether
      RejectRefusal (..)
    , OpenRequest (..)
    , Why (..)
    , rejectGate
    , renderRejectRefusal

      -- * What it refunds
    , RefundMismatch (..)
    , refundShape
    , renderRefundMismatch
    ) where

import Data.List (intercalate)
import Data.Text qualified as T

import Cardano.Ledger.TxIn (TxIn)

import Singular.CLI.RequestWindow (Bounds (..))
import Singular.Registry.Deployment (renderOutRef)

-- | Why a pending request is taken as still inside a window.
data Why
    = -- | The view's tip slot, and the slot its retract deadline converts to
      BeforeDeadline Integer Integer
    | -- | The view cannot place the retract deadline in a slot
      DeadlineUnconverted
    deriving stock (Eq, Show)

-- | A pending request still inside a window.
data OpenRequest = OpenRequest
    { openRequest :: TxIn
    , openBounds :: Bounds
    , openWhy :: Why
    }
    deriving stock (Eq, Show)

-- | Why a reject is not built.
data RejectRefusal
    = -- | No request is pending
      NothingToReject
    | -- | These pending requests are still inside a window
      WindowsOpen [OpenRequest]
    deriving stock (Eq, Show)

{- | The pending requests a reject takes, with their bounds, or why it takes
none: the view's tip slot, and each pending request with its bounds and the
slot its retract deadline converts to in that same view, when it does.

A request is past its windows only when the view proves it: its retract
deadline converts to a slot and the tip is at or past it, which is the
library's own phase for a request past both windows
('Singular.Registry.Types.requestPhase'), and no later inclusion can be
before the deadline. A deadline the view cannot place in a slot is taken as
still open, and is named so. No clock of the host's enters the decision.
-}
rejectGate
    :: Integer
    -> [(TxIn, Bounds, Maybe Integer)]
    -> Either RejectRefusal [(TxIn, Bounds)]
rejectGate tip booked
    | null booked = Left NothingToReject
    | null open = Right [(r, b) | (r, b, _) <- booked]
    | otherwise = Left (WindowsOpen open)
  where
    open =
        [ OpenRequest r b why
        | (r, b, slot) <- booked
        , Just why <- [stillOpen slot]
        ]
    stillOpen = \case
        Nothing -> Just DeadlineUnconverted
        Just s
            | tip < s -> Just (BeforeDeadline tip s)
            | otherwise -> Nothing

-- | One line naming the refusal and every request it names.
renderRejectRefusal :: RejectRefusal -> String
renderRejectRefusal = \case
    NothingToReject -> "nothing is pending: there is no request to reject"
    WindowsOpen open ->
        show (length open)
            <> " pending request"
            <> (if length open == 1 then " is" else "s are")
            <> " still inside a window, and a reject takes every pending request, so none is built: "
            <> intercalate "; " (map said open)
  where
    said o =
        T.unpack (renderOutRef (openRequest o))
            <> ": its processing window ends at "
            <> show (processingEnds b)
            <> " ms and its retract window closes at "
            <> show (retractEnds b)
            <> " ms"
            <> case openWhy o of
                BeforeDeadline tip s ->
                    " (slot " <> show s <> "), and the ledger's tip is slot " <> show tip
                DeadlineUnconverted ->
                    ", a time this view cannot place in a slot, so it is taken as still open"
      where
        b = openBounds o

-- | Why a built reject's outputs are not the refunds it owes.
data RefundMismatch
    = -- | Refunds owed, outputs found after the state's
      TooFewOutputs Int Int
    | -- | The designated output of this request pays another recipient
      WrongRecipient Int
    | -- | The request, the amount owed and what its designated output pays
      ShortRefund Int Integer Integer
    deriving stock (Eq, Show)

{- | Check a built reject's refund outputs against what each request owes:
the recipient and the owed lovelace of each request, in order, and the
recipient and lovelace of the outputs that follow the state's. Request @i@'s
designated output is the @i@-th, and must pay its owner at least the whole
owed amount by itself; it returns what each designated output pays.
-}
refundShape
    :: (Eq a)
    => [(a, Integer)]
    -> [(a, Integer)]
    -> Either RefundMismatch [Integer]
refundShape expected actual
    | length actual < length expected =
        Left (TooFewOutputs (length expected) (length actual))
    | otherwise = traverse check (zip3 [0 ..] expected actual)
  where
    check (i, (owner, owed), (paidTo, paid))
        | owner /= paidTo = Left (WrongRecipient i)
        | paid < owed = Left (ShortRefund i owed paid)
        | otherwise = Right paid

-- | One line naming the mismatch.
renderRefundMismatch :: RefundMismatch -> String
renderRefundMismatch = \case
    TooFewOutputs owed found ->
        show owed
            <> " refunds are owed but the reject carries "
            <> show found
            <> " outputs after its state output"
    WrongRecipient i ->
        "the output designated for request number "
            <> show (i + 1 :: Int)
            <> " does not pay that request's owner"
    ShortRefund i owed paid ->
        "the output designated for request number "
            <> show (i + 1 :: Int)
            <> " pays "
            <> show paid
            <> " lovelace by itself, short of the "
            <> show owed
            <> " its owner is owed"
