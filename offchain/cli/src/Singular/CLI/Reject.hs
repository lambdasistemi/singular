{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- |
Module      : Singular.CLI.Reject
Description : @singular registry reject@: clear the registry's expired requests
License     : Apache-2.0

A request nobody folded and its owner did not take back stays pending, and
the registry's fold, which takes every pending request, is blocked behind
it. @registry reject@ is the way out: an ordinary command, signed and funded
by the wallet that runs it, that rejects the registry's pending requests
with the library's reject builder and the registry's published reference
scripts. The builder takes every pending request, so the command is built
only when none is still inside its processing or retract window
("Singular.CLI.RejectRules"), and refuses by name, before anything is
signed, when one is, and when nothing is pending.

A reject carries no admission and does not move the registry: the state
output is continued unchanged, so its public root stays the same. Each rejected request's owner is refunded the
request's value less the tip, in the one output designated for that
request; the wallet that runs the reject keeps the tip. The built
transaction is checked before it is signed to carry exactly those refunds in
that shape, and its receipt reports the value actually locked in each
request and what went to whom, read back from the chain.
-}
module Singular.CLI.Reject
    ( runReject
    ) where

import Control.Exception
    ( SomeAsyncException
    , SomeException
    , fromException
    , throwIO
    , try
    )
import Control.Monad (forM, unless)
import Data.Aeson (Value, object, toJSON, (.=))
import Data.ByteString (ByteString)
import Data.Foldable (toList)
import Data.List (isPrefixOf, sortOn)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Lens.Micro ((^.))

import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.Api.Tx (bodyTxL, txIdTx)
import Cardano.Ledger.Api.Tx.Body (inputsTxBodyL, outputsTxBodyL)
import Cardano.Ledger.Api.Tx.Out (TxOut, addrTxOutL)
import Cardano.Ledger.BaseTypes (Network (Testnet), TxIx (..))
import Cardano.Ledger.TxIn (TxIn (..))
import Cardano.Tx.Ledger (ConwayTx)

import Cardano.Slotting.Slot qualified as Cage
import Singular.CLI.Attached
import Singular.CLI.Command (RejectArgs (..))
import Singular.CLI.Fold (slotAt)
import Singular.CLI.FoldRules (fundedView)
import Singular.CLI.Live
import Singular.CLI.Outlay (updateOutlay)
import Singular.CLI.Plan (refuseOver)
import Singular.CLI.Receipt (OutcomeClass (..))
import Singular.CLI.Registry (hexT)
import Singular.CLI.RejectRules
import Singular.CLI.RequestWindow (Bounds (..), windowOf)
import Singular.CLI.Session
import Singular.Registry.Ledger (ConwayEra)
import Singular.Registry.LedgerProvider qualified as Cage
import Singular.Registry.SessionIO qualified as Cage
import Singular.Registry.TxBuilder.Internal
    ( addrFromKeyHashBytes
    , extractCageDatum
    , extractOwnerBytes
    , findRequestUtxos
    , requestAddrFromCfg
    )
import Singular.Registry.TxBuilder.Reject (rejectRequestsWithRefs)
import Singular.Registry.Types
    ( CageDatum (..)
    , Edge
    , OnChainRequest (..)
    , OnChainTokenState (..)
    , edgeName
    )
import Singular.Registry.Wallet (Wallet (..), bech32Address)

-- | One pending request the reject takes, and what it is owed.
data Row = Row
    { rowRequest :: TxIn
    , rowOwner :: ByteString
    -- ^ The request owner's payment key hash
    , rowKey :: ByteString
    , rowEdge :: Edge
    , rowLocked :: TxOut ConwayEra
    -- ^ The request output, with whatever it actually holds
    , rowBounds :: Bounds
    , rowRecipient :: Addr
    -- ^ Where the owner is paid
    }

-- | What the reject's view decided before anything was signed.
data Plan = Plan
    { plRows :: [Row]
    , plTip :: Integer
    , plTipSlot :: Integer
    , plRootBefore :: ByteString
    , plReturned :: [Integer]
    -- ^ What each request's designated output pays, from the built body
    }

-- | A rejected request, read back after the reject confirmed.
data Rejected = Rejected
    { rjTx :: ConwayTx
    , rjPlan :: Plan
    , rjRejector :: ByteString
    }

{- | @singular registry reject@: reject the registry's pending requests, signed
and funded by this wallet, and journal it.
-}
runReject :: RejectArgs -> IO Value
runReject a =
    attached
        (rejectRegistry a)
        (rejectBlueprint a)
        (rejectWrite a)
        "reject"
        $ \at -> do
            rejected <- rejectPending at a
            pure (receipt "reject" Success (rejectedFields rejected))

rejectPending :: Attached -> RejectArgs -> IO Rejected
rejectPending at a = do
    let s = savedOf at
        cfg = savedCfg s
        wc = atWrite at
        addr = walletAddr (wcWallet wc)
        requestAddr = requestAddrFromCfg cfg (savedToken s) Testnet
    rootBefore <- selectedTrieRoot (atTrie at)
    (tx, plan) <-
        submitBuilt
            wc
            "reject"
            (const (expecting "state"))
            ( \v -> do
                allAtRequestAddr <- Cage.outputsAt v requestAddr
                let pending = sortOn fst (findRequestUtxos (savedToken s) allAtRequestAddr)
                    pendingIns = map fst pending
                live <- attachLive v s
                st <- case extractCageDatum (snd (liveState live)) of
                    Just (StateDatum st) -> pure st
                    _ ->
                        stop
                            ClientRefusal
                            "the registry's state output carries no state datum"
                            []
                booked <-
                    forM pending $ \(i, o) -> case extractCageDatum o of
                        Just (RequestDatum r) -> pure (i, o, r)
                        _ -> stop ClientRefusal "a pending request carries no request datum" []
                observed <- Cage.tip v
                let tipSlot = toInteger (Cage.unSlotNo (Cage.observedSlot observed))
                    boundsOf r =
                        windowOf
                            (requestSubmittedAt r)
                            (stateProcessTime st)
                            (stateRetractTime st)
                slotted <-
                    forM booked $ \(i, _, r) -> do
                        let b = boundsOf r
                        slot <- slotAt v (retractEnds b)
                        pure (i, b, toInteger . Cage.unSlotNo <$> slot)
                taken <- either (refuse tipSlot) pure (rejectGate tipSlot slotted)
                let rows =
                        [ Row
                            { rowRequest = i
                            , rowOwner = extractOwnerBytes o
                            , rowKey = requestKey r
                            , rowEdge = requestEdge r
                            , rowLocked = o
                            , rowBounds = b
                            , rowRecipient = addrFromKeyHashBytes Testnet (extractOwnerBytes o)
                            }
                        | ((i, o, r), (_, b)) <- zip booked taken
                        ]
                    tip = stateMaxFee st
                funded <-
                    fundedView (rejectFund a) addr v
                        >>= either
                            ( \why ->
                                stop ClientRefusal ("the wallet cannot fund the reject: " <> why) []
                            )
                            pure
                built <-
                    try
                        ( rejectRequestsWithRefs
                            cfg
                            funded
                            (savedToken s)
                            addr
                            (liveRefs live)
                        )
                unsigned <- case built of
                    Right t -> pure t
                    Left (e :: SomeException)
                        | Just (_ :: SomeAsyncException) <- fromException e -> throwIO e
                        | otherwise ->
                            stop
                                ClientRefusal
                                ( "its reject could not be built, so nothing is rejected: "
                                    <> briefly (show e)
                                )
                                []
                -- It takes every pending request and no other request output.
                let spent = Set.fromList (toList (unsigned ^. bodyTxL . inputsTxBodyL))
                    atRequestAddr = map fst allAtRequestAddr
                    missed = [i | i <- pendingIns, i `Set.notMember` spent]
                    strays =
                        [ i
                        | i <- atRequestAddr
                        , i `elem` Set.toList spent
                        , i `notElem` pendingIns
                        ]
                unless (null missed && null strays) $
                    stop
                        ConcurrentWriter
                        ( "the built reject does not spend exactly the pending requests ("
                            <> T.unpack (T.intercalate ", " (map txInText (missed <> strays)))
                            <> "); it is not submitted"
                        )
                        []
                -- Output 0 continues the state, then one designated refund per request.
                refundOuts <- case toList (unsigned ^. bodyTxL . outputsTxBodyL) of
                    o : os | Just (StateDatum _) <- extractCageDatum o -> pure os
                    _ ->
                        stop
                            ClientRefusal
                            "the built reject does not begin with the state's continuation, so it is not signed"
                            []
                let owed = [coinOf (rowLocked r) - tip | r <- rows]
                returned <-
                    either
                        ( \why ->
                            stop
                                ClientRefusal
                                ( "the built reject is not signed: "
                                    <> renderRefundMismatch why
                                )
                                []
                        )
                        pure
                        ( refundShape
                            (zip (map rowRecipient rows) owed)
                            [(o ^. addrTxOutL, coinOf o) | o <- refundOuts]
                        )
                refuseOver (rejectMaxOutlay a) (updateOutlay unsigned)
                pure
                    ( unsigned
                    , Plan
                        { plRows = rows
                        , plTip = tip
                        , plTipSlot = tipSlot
                        , plRootBefore = rootBefore
                        , plReturned = returned
                        }
                    )
            )
    -- Observed: every rejected request output is gone, the root is where it was,
    -- and each refund is live at its owner's address as built.
    after <-
        reading at $ \v -> do
            left <- Cage.outputsAt v requestAddr
            live <- attachLive v s
            owners <-
                forM (Set.toList (Set.fromList (map rowRecipient (plRows plan)))) $ \o ->
                    (,) o <$> Cage.outputsAt v o
            pure (left, live, Map.fromList owners)
    let (leftover, afterLive, ownerOuts) = after
        rejectedIns = map rowRequest (plRows plan)
    unless (null [i | i <- rejectedIns, i `elem` map fst leftover]) $
        failWith
            Partial
            "the reject confirmed but a rejected request output is still live"
    onChain <- either (failWith Partial) pure (observedRoot afterLive)
    unless (onChain == plRootBefore plan) $
        failWith StaleState "the registry's root moved during a reject"
    local <- selectedTrieRoot (atTrie at)
    unless (onChain == local) $
        failWith
            StaleState
            ( "after the reject the ledger holds root 0x"
                <> T.unpack (hexT onChain)
                <> " but the replay reaches to 0x"
                <> T.unpack (hexT local)
            )
    let txid = txIdTx tx
    unless
        ( and
            [ any
                (\(i, o) -> i == TxIn txid (TxIx (fromIntegral ix)) && coinOf o == paid)
                (Map.findWithDefault [] (rowRecipient r) ownerOuts)
            | (ix, r, paid) <- zip3 [1 :: Int ..] (plRows plan) (plReturned plan)
            ]
        )
        $ failWith
            Partial
            "the reject confirmed but a refund is not live at its owner as built"
    journalObserved
        wc
        "reject"
        tx
        ( T.pack (show (length rejectedIns))
            <> " request(s) rejected and refunded; root unchanged"
        )
    pure Rejected{rjTx = tx, rjPlan = plan, rjRejector = callerKey at}
  where
    refuse tip = \case
        NothingToReject ->
            stop
                ClientRefusal
                (renderRejectRefusal NothingToReject)
                [("tipSlot", toJSON tip)]
        refusal@(WindowsOpen open) ->
            stop
                ClientRefusal
                (renderRejectRefusal refusal)
                [ ("tipSlot", toJSON tip)
                , ("pendingRequests", toJSON (map openJson open))
                ]
    openJson o =
        object
            [ "request" .= txInText (openRequest o)
            , "processingEnds" .= processingEnds (openBounds o)
            , "retractEnds" .= retractEnds (openBounds o)
            , "retractEndsSlot"
                .= case openWhy o of
                    BeforeDeadline _ s -> Just s
                    DeadlineUnconverted -> Nothing
            , "unplaced"
                .= (openWhy o == DeadlineUnconverted)
            ]

-- | The reject's receipt: every request rejected and what went to whom.
rejectedFields :: Rejected -> [(Text, Value)]
rejectedFields Rejected{rjTx = tx, rjPlan = plan, rjRejector = rejector} =
    [ ("reject", toJSON (txIdHex tx))
    , ("rejector", toJSON (hexT rejector))
    ,
        ( "rejected"
        , toJSON
            (zipWith row [1 :: Int ..] (zip (plRows plan) (plReturned plan)))
        )
    , ("root", toJSON (hexT (plRootBefore plan)))
    , ("tipSlot", toJSON (plTipSlot plan))
    ]
  where
    row ix (r, paid) =
        object
            [ "request" .= txInText (rowRequest r)
            , "owner" .= hexT (rowOwner r)
            , "key" .= hexT (rowKey r)
            , "edge" .= edgeName (rowEdge r)
            , "locked" .= valueJson (rowLocked r)
            , "tip" .= plTip plan
            , "returned"
                .= object
                    [ "recipient" .= T.pack (bech32Address (rowRecipient r))
                    , "output" .= (txIdHex tx <> "#" <> T.pack (show ix))
                    , "index" .= ix
                    , "lovelace" .= paid
                    ]
            , "topUp" .= max 0 (paid - (coinOf (rowLocked r) - plTip plan))
            , "processingEnds" .= processingEnds (rowBounds r)
            , "retractEnds" .= retractEnds (rowBounds r)
            ]

-- | Stop before anything is signed: nothing was submitted.
stop :: OutcomeClass -> String -> [(Text, Value)] -> IO a
stop = failWithFields

{- | A build failure's own words, without the script bytes and context a
Plutus failure carries after them.
-}
briefly :: String -> String
briefly = go
  where
    go s
        | "(PlutusWithContext" `isPrefixOf` s = "…"
        | otherwise = case s of
            [] -> []
            (c : rest) -> c : go rest
