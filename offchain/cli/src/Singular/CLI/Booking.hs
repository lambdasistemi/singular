{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.CLI.Booking
Description : The early booking refusal every ordinary verb checks (#486)
License     : Apache-2.0

A booking names a key for an edge. Lean @transition@ admits
@insertActive@ only from @unknown@ and @updateTerminal@ only from
@active@; every other combination is refused at the fold. Booking one
anyway submits a transaction the chain can only refuse, after signing
it and paying for it. This module decides that refusal early, from the
attached registry's view of the key's leaf, before anything is signed:
a taken key, a terminal key, an unknown key for update and terminate,
and every other case the Lean table rules out.

The decision is pure and written once, here, in the registry packages,
so any application that depends on them gets the same refusal by
calling it in its own planning. The booking primitive
("Singular.Registry.TxBuilder.Edges") and the application builders do
not call it and stay permissive: the negative host books taken keys
through them to show the chain's own refusal at the fold. The fold
keeps validating on its own; the early refusal never replaces it, and
stays labelled client policy: the Lean model does not require it.
-}
module Singular.CLI.Booking
    ( -- * What is booked
      BookingVerb (..)
    , bookingVerbName
    , bookingEdgeName
    , requiredLeaf

      -- * The decision
    , BookingRefusal (..)
    , bookingRefusal
    , refusalReason
    , refusalFields

      -- * The check
    , refuseBooking
    , precheckBooking
    ) where

import Data.Aeson (Value, toJSON)
import Data.ByteString (ByteString)
import Data.Either (fromRight)
import Data.Set (Set)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE

import Singular.CLI.Command (RegistryAccess)
import Singular.CLI.Live
    ( TrieContext
    , attachLive
    , openTrie
    , requireTrieSelection
    , resolveSaved
    , trieLeaf
    )
import Singular.CLI.Proof
    ( Leaf (..)
    , leafName
    , renderAuthError
    )
import Singular.CLI.Receipt (OutcomeClass (..))
import Singular.CLI.Registry (hexT)
import Singular.CLI.Session
    ( Env (..)
    , failWith
    , failWithFields
    , readStep
    )
import Singular.Registry.Application (Application)
import Singular.Registry.ProviderSettings (ProviderSettings)
import Singular.Registry.StateToken (ReferenceRole)

{- | The verbs that book, or read like a booking: an insertion books
@insertActive@, a termination books @updateTerminal@, and a payload
update needs the key live exactly as a termination does.
-}
data BookingVerb
    = BookInsert
    | BookUpdate
    | BookTerminate
    deriving stock (Eq, Show, Enum, Bounded)

-- | The verb as receipts and reasons name it.
bookingVerbName :: BookingVerb -> Text
bookingVerbName = \case
    BookInsert -> "insert"
    BookUpdate -> "update"
    BookTerminate -> "terminate"

-- | The edge the verb books, as the model names it.
bookingEdgeName :: BookingVerb -> Text
bookingEdgeName = \case
    BookInsert -> "insertActive"
    BookUpdate -> "update"
    BookTerminate -> "updateTerminal"

{- | The leaf the verb needs: the before-leaf of the edge it books. An
update books no edge but needs the key live, which is the same leaf a
termination needs.
-}
requiredLeaf :: BookingVerb -> Leaf
requiredLeaf = \case
    BookInsert -> Unknown
    BookUpdate -> Active
    BookTerminate -> Active

{- | A booking the current entry rules out: the key, the verb, the leaf
found and the leaf required.
-}
data BookingRefusal = BookingRefusal
    { brKey :: ByteString
    , brVerb :: BookingVerb
    , brFound :: Leaf
    , brRequired :: Leaf
    }
    deriving stock (Eq, Show)

{- | The pure decision: does the key's current entry rule out this
request for its verb. Nothing when the found leaf is the required one:
Lean @transition@ admits @insertActive@ only from @unknown@ and
@updateTerminal@ only from @active@, and an update needs the key live.
-}
bookingRefusal
    :: BookingVerb -> ByteString -> Leaf -> Maybe BookingRefusal
bookingRefusal verb key found
    | found == requiredLeaf verb = Nothing
    | otherwise =
        Just
            BookingRefusal
                { brKey = key
                , brVerb = verb
                , brFound = found
                , brRequired = requiredLeaf verb
                }

-- | The key as a reason names it: its text, or its hex when not UTF-8.
displayKey :: ByteString -> Text
displayKey key = fromRight (hexT key) (TE.decodeUtf8' key)

{- | The refusal as a receipt's reason carries it: what the key is,
labelled client policy.
-}
refusalReason :: BookingRefusal -> String
refusalReason r =
    T.unpack (displayKey (brKey r)) <> " " <> state <> " (client policy)"
  where
    state = case (brVerb r, brFound r) of
        (BookInsert, Active) -> "is already registered"
        (BookInsert, Terminal) -> "is already retired"
        (BookInsert, Absent) -> "is absent and cannot be registered"
        (BookUpdate, Unknown) -> "is not registered"
        (BookUpdate, Terminal) -> "is already retired"
        (BookUpdate, Absent) -> "is absent and cannot be updated"
        (BookTerminate, Unknown) -> "is not registered"
        (BookTerminate, Terminal) -> "is already retired"
        (BookTerminate, Absent) -> "is absent and cannot be retired"
        _ -> "cannot be booked"

-- | The refusal's receipt fields: the key, the edge, the leaves, the label.
refusalFields :: BookingRefusal -> [(Text, Value)]
refusalFields r =
    [ ("key", toJSON (hexT (brKey r)))
    , ("verb", toJSON (bookingVerbName (brVerb r)))
    , ("edge", toJSON (bookingEdgeName (brVerb r)))
    , ("leafFound", toJSON (leafName (brFound r)))
    , ("leafRequired", toJSON (leafName (brRequired r)))
    , ("policy", toJSON ("client" :: Text))
    ]

{- | Refuse the booking the key's current entry rules out, from the
attached lineage's view of its leaf. An unprovable leaf stops with the
proof's own refusal instead of a decision.
-}
refuseBooking :: TrieContext -> ByteString -> BookingVerb -> IO ()
refuseBooking context key verb = do
    found <-
        either (failWith StaleState . renderAuthError) pure
            =<< trieLeaf context key key
    case bookingRefusal verb key found of
        Nothing -> pure ()
        Just refusal ->
            failWithFields
                ClientRefusal
                (refusalReason refusal)
                (refusalFields refusal)

{- | The reads-only pre-check every ordinary submit verb runs before any
signing key is read: the same refusal decided from a fresh read view,
with no wallet, no journal and no lock. It runs as one timed read step
naming the booking's inputs, so a refusal closes that read before it is
reported; preview paths hold no key already, and the in-build checks
keep the same refusal where the booking is decided.
-}
precheckBooking
    :: Application
    -> Env
    -> ProviderSettings
    -> FilePath
    -> RegistryAccess
    -> Set ReferenceRole
    -> ByteString
    -> BookingVerb
    -> IO ()
precheckBooking app env settings blueprint access roles key verb = do
    release <-
        envLoadRelease env app blueprint
            >>= either (failWith ClientRefusal) pure
    envReads env settings $ \caps ->
        readStep (envTracer env) (envSource env) ["state", "key outputs"] caps $ \v -> do
            saved <- resolveSaved app "" release access roles Nothing v
            live <- attachLive v saved
            context <- openTrie saved
            requireTrieSelection saved live context
            refuseBooking context key verb
