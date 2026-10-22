{-# LANGUAGE LambdaCase #-}

{- |
Module      : Singular.Application.KeriStub.Book
Description : One booking through the stub, the way every producer of the registry books
License     : Apache-2.0

What the stub's two producers share. A booking is built by the registry's
registration or termination booking builder, given what the stub owns (the
holding it delivers, the custody it spends, who signs), so that the producer
and the fold meet in the one path the model describes. The command books from
one view, reads the request back live by the request policy's tag before it
journals it observed, and places a registration's processing deadline in that
same view.
-}
module Singular.Application.KeriStub.Book
    ( -- * What is booked
      Booked (..)

      -- * Booking
    , book
    , pendingFields
    , foldAfter
    , managedEntryDir
    , transferOf
    ) where

import Control.Monad (unless)
import Data.Aeson (Value (Null), toJSON)
import Data.ByteString (ByteString)
import Data.Foldable (toList)
import Data.Text (Text)
import Data.Text qualified as T
import Lens.Micro ((^.))

import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.Api.Tx (bodyTxL, txIdTx)
import Cardano.Ledger.Api.Tx.Body (outputsTxBodyL)
import Cardano.Ledger.Api.Tx.Out (TxOut, coinTxOutL)
import Cardano.Ledger.BaseTypes (TxIx (..))
import Cardano.Ledger.TxIn (TxIn (..))
import Cardano.Tx.Ledger (ConwayTx)

import Singular.Application.KeriStub.Value (keriStubApplication)
import Singular.CLI.Attached
import Singular.CLI.Booking
    ( BookingVerb
    , refuseBooking
    )
import Singular.CLI.Command
    ( EntryArgs (..)
    , ProviderSettings (..)
    , RegistryAccess (..)
    , WriteSettings (..)
    )
import Singular.CLI.Fold
    ( Deadline (..)
    , FoldOrigin (..)
    , FoldSpec (..)
    , Folded
    , deadlineJson
    , foldPending
    , registrationDeadline
    )
import Singular.CLI.FoldRules (fundedView)
import Singular.CLI.Live
import Singular.CLI.ManagedState (resolveSignerDir)
import Singular.CLI.Outlay (Outlay)
import Singular.CLI.Plan (refuseOver)
import Singular.CLI.Receipt (OutcomeClass (..))
import Singular.CLI.Registry (hexT)
import Singular.CLI.Session
import Singular.CLI.Trace
    ( EdgeAction (..)
    , Scope (..)
    , What (EdgeStarted)
    , report
    )
import Singular.CLI.Trace qualified as Trace
import Singular.Registry.Evidence qualified as Cage
import Singular.Registry.Ledger (Coin (..), ConwayEra, PParams)
import Singular.Registry.LedgerProvider qualified as Cage
import Singular.Registry.SessionIO qualified as Cage
import Singular.Registry.TxBuilder.Internal
    ( BookedRequest (..)
    , bookedRequestOf
    , extractCageDatum
    , pendingByTag
    )
import Singular.Registry.Types
    ( CageDatum (..)
    , Edge
    , OnChainTokenState
    , edgeName
    )

{- | One booking through the stub: the edge it books, how it is built from one
view paid and refunded by an address, and what it puts out of the wallet,
measured from its body.
-}
data Booked = Booked
    { bookedEdge :: Edge
    , bookedBuild :: Cage.Session Cage.NoWitness IO -> Addr -> IO ConwayTx
    , bookedOutlay
        :: PParams ConwayEra -> [(TxIn, TxOut ConwayEra)] -> ConwayTx -> Outlay
    }

-- | The state a registration's deadline is read under, and the booked request it names.
requestAndState
    :: Cage.Session Cage.NoWitness IO
    -> Saved
    -> TxIn
    -> IO (Maybe (BookedRequest, OnChainTokenState))
requestAndState v s request = do
    pending <- pendingByTag (savedCfg s) v (savedToken s)
    live <- attachLive v s
    pure $ case ( lookup request pending >>= bookedRequestOf (savedCfg s) (savedToken s)
                , extractCageDatum (snd (liveState live))
                ) of
        (Just booked, Just (StateDatum st)) -> Just (booked, st)
        _ -> Nothing

{- | Book one edge, then read the request back live by the request policy's
tag before journalling it observed, and place a registration's processing
deadline in that same view. The booking is built from one view: what it books
is decided there, its fee and collateral balanced and its outlay judged
against the approved allowance, before anything is signed. The refusal every
ordinary verb makes is decided inside the booking's own view as well, so a key
whose entry moved between the pre-check and the build is still refused by
name.
-}
book
    :: Attached
    -> EntryArgs
    -> ByteString
    -> BookingVerb
    -> (Cage.Session Cage.NoWitness IO -> Live -> IO (Booked, r))
    -> IO (ConwayTx, r, Maybe Deadline)
book at a key verb plan = do
    let s = savedOf at
        cfg = savedCfg s
        wc = atWrite at
    (booking, decided) <-
        submitBuiltIn
            wc
            "book"
            ["state", "key outputs"]
            (const (Expectation (Just key) "request" Nothing Nothing Nothing))
            ( \building v -> do
                live <- attachLive v s
                refuseBooking (atTrie at) key verb
                (b, decided) <- plan v live
                let edge = T.pack (edgeName (bookedEdge b))
                place
                    building
                    [InKey key, InEdge (Booking edge)]
                    (EdgeStarted (Booking edge))
                funded <-
                    fundedView (entryFund a) (wcCaller wc) v
                        >>= either (failWith ClientRefusal) pure
                tx <- bookedBuild b funded (wcCaller wc)
                pp <- Cage.parameters v
                refuseOver
                    (entryMaxOutlay a)
                    (bookedOutlay b pp (liveRefs live) tx)
                pure (tx, decided)
            )
    let request = TxIn (txIdTx (confirmedTx booking)) (TxIx 0)
    deadline <-
        readingBack at "book" booking ["requests", "state"] $ \v -> do
            reqs <- pendingByTag cfg v (savedToken s)
            unless (any ((== request) . fst) reqs) $
                failWith
                    Partial
                    "the booking confirmed but its request output is not live"
            requestAndState v s request >>= \case
                Just (BookedRegistration r, st) -> Just <$> registrationDeadline v r st
                Just (BookedTermination _, _) -> pure Nothing
                Nothing ->
                    failWith
                        Partial
                        "the booking's request output or the registry's state carries no readable datum"
    journalObserved
        wc
        "book"
        booking
        ("request " <> txInText request <> " live")
    report
        (wcTracer wc)
        [InRequest (txInText request)]
        (Trace.Booked (txInText request) (deadlineMs <$> deadline))
    pure (confirmedTx booking, decided, deadline)

-- | What a booking-only command's receipt names of its pending request.
pendingFields
    :: ByteString -> ConwayTx -> Maybe Deadline -> [(Text, Value)]
pendingFields requester bookingTx deadline =
    [ ("booking", toJSON (txIdHex bookingTx))
    , ("requester", toJSON (hexT requester))
    , ("request", toJSON (txInText (TxIn (txIdTx bookingTx) (TxIx 0))))
    , ("foldDeadline", maybe Null deadlineJson deadline)
    ]

{- | The fold a command runs after its own booking, by the routine
@keri-stub fold@ runs.
-}
foldAfter :: Attached -> EntryArgs -> ConwayTx -> IO Folded
foldAfter at a booking =
    foldPending
        keriStubApplication
        at
        FoldSpec
            { fsOrigin = Combined booking
            , fsRequest = Nothing
            , fsFund = Nothing
            , fsAllowance = entryMaxOutlay a
            }

{- | The managed journal for a booking command: resolved from the state root
override, the provider network, the registry token and the caller's wallet,
before any lock or journal use.
-}
managedEntryDir :: EntryArgs -> WriteSettings -> IO FilePath
managedEntryDir a ws =
    resolveSignerDir
        (entryStateDir a)
        (providerMagic (writeProvider ws))
        (accessToken (entryAccess a))
        (writeSigner ws)

{- | The lovelace a booking transfers into its request: what the request output
holds, the first output of the booking.
-}
transferOf :: ConwayTx -> Integer
transferOf booking = case toList (booking ^. bodyTxL . outputsTxBodyL) of
    request : _ -> let Coin c = request ^. coinTxOutL in c
    [] -> 0
