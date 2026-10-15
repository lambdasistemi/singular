{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections #-}

{- |
Module      : Singular.CLI.Prepare
Description : Commands choose or prepare the funding output themselves
License     : Apache-2.0

A write command funds and collateralises from an ada-only output of the
caller's wallet. When none suits — every output carries tokens or a
reference script beside the ada, or none holds enough — the command
spends one preparation transaction first that puts the ada it needs into
an output of its own, then continues from that output. This module is the
shared seam 'fold', 'reject' and 'reclaim' call where they call
'fundedView' today.

The rule, in order:

* An explicit @--fund-input@ choice is final: used if it is an ada-only
  output of the wallet, refused with today's text otherwise; never
  prepared around.
* Otherwise the command's natural session shows the wallet narrowed to
  its largest ada-only output with no reference script, so no command
  ever funds or collateralises from a token-carrying output. If the
  command builds against it, nothing else happens.
* If the natural build fails, the seam tells a funding failure from any
  other failure by building the same command again against a session in
  which the payer additionally holds a synthetic, oversized, ada-only
  output. If that build fails too, the failure is not about funding: the
  original failure is reported unchanged, nothing is prepared or spent.
  Asynchronous exceptions are rethrown in both builds, as today.
* Only when the oversized build succeeds and the natural one failed is
  the funding the cause. The oversized build also measures what the
  command needs — its fee, its collateral, the ledger minimum for its
  change — and 'planPreparation' judges the whole thing before anything
  is signed. A short wallet is refused with what is needed, what the
  wallet may spend and the short step, ending that nothing was submitted.
  With @--max-outlay@ below command plus preparation, the command is
  refused before signing naming both amounts. Otherwise one preparation
  transaction is submitted through the ordinary path, the wallet is read
  again, narrowed to the made output, and the command is built for real
  against that view.

The oversized probe overestimates by construction: it overwrites the
largest spendable output's value with a huge ada-only one at its own
reference — which evaluation still resolves on any provider — keeping
every size the fee depends on at or above the real build's, so the
measured requirement covers the real one and a prepared output always
funds. The made output goes first so the journal reads it back as the
transaction's first output.
-}
module Singular.CLI.Prepare
    ( PrepareRefusal (..)
    , prepareFunding
    , measureRequirement
    , overAllowance
    , shortfallRefusal
    , allowanceRefusal
    , explicitRefusal
    , probeCoin
    , preparationFields
    ) where

import Control.Exception
    ( SomeAsyncException
    , SomeException
    , fromException
    , throwIO
    , try
    )
import Control.Monad (when)
import Data.Aeson (Value, object, toJSON, (.=))
import Data.Foldable (toList)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Lens.Micro ((^.))

import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.Api.Tx (bodyTxL, txIdTx)
import Cardano.Ledger.Api.Tx.Body (feeTxBodyL, outputsTxBodyL)
import Cardano.Ledger.Api.Tx.Out
    ( TxOut
    , addrTxOutL
    , getMinCoinTxOut
    , mkBasicTxOut
    )
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Mary.Value (MaryValue (..))
import Cardano.Ledger.TxIn (TxIn (..))
import Cardano.Tx.Ledger (ConwayTx)

import Singular.CLI.FoldRules
    ( emptiedView
    , fundedView
    , overwrittenView
    )
import Singular.CLI.Live (txInText)
import Singular.CLI.Outlay
    ( Outlay (..)
    , collateralOf
    , outlayTotal
    , spendableHeld
    )
import Singular.CLI.Plan (outlayReport)
import Singular.CLI.Receipt (OutcomeClass (..))
import Singular.CLI.Session
    ( ConfirmedSubmission
    , WriteContext (..)
    , expecting
    , failWith
    , journalObserved
    , readStep
    , submitBuilt
    , txIdHex
    )
import Singular.Registry.Evidence qualified as Cage
import Singular.Registry.Ledger (ConwayEra, PParams)
import Singular.Registry.LedgerProvider qualified as Cage
import Singular.Registry.SessionIO qualified as Cage
import Singular.Registry.TxBuilder.Edges (adaOnlyOut, selectFunding)
import Singular.Registry.TxBuilder.Prepare
    ( Preparation (..)
    , PrepareError (..)
    , planPreparation
    , spendableOuts
    )
import Singular.Registry.Wallet (bech32Address)

{- | How a funding decision refuses: already-rendered refusals the caller
reports with its own stop, and the original failure it reports as today.
-}
data PrepareRefusal
    = ExplicitFundingRefusal String
    | OriginalFailure SomeException
    | PreparationShortfall String [(Text, Value)]
    | AllowanceExceeded String [(Text, Value)]

{- | The command's funding, decided: the built transaction with the
preparation that funded it, if one was made. A refusal carries everything
the caller reports; an original failure is reported by the caller exactly
as today. Synchronous failures only: asynchronous exceptions are
rethrown, never reported.
-}
prepareFunding
    :: WriteContext
    -> Text
    -- ^ The command step name: @fold@, @reject@ or @reclaim@.
    -> Addr
    -- ^ The payer wallet.
    -> Maybe TxIn
    -- ^ An explicit @--fund-input@ choice, final when given.
    -> Maybe Integer
    -- ^ The effective allowance: what the command may still put out.
    -> (ConwayTx -> Outlay)
    -- ^ The command's outlay measured from a built transaction.
    -> (Cage.Session Cage.NoWitness IO -> IO ConwayTx)
    -- ^ The command's own build as a function of the session.
    -> Cage.Session Cage.NoWitness IO
    -- ^ The held session.
    -> IO (Either PrepareRefusal ([TxIn], Maybe Preparation, ConwayTx))
prepareFunding wc step addr mFund mAllowance measure build v = do
    wallet <- Cage.outputsAt v addr
    pp <- Cage.parameters v
    case mFund of
        Just x -> do
            r <- fundedView (Just x) addr v
            case mapLeft ExplicitFundingRefusal (fmap ([x],) r) of
                Left refusal -> pure (Left refusal)
                Right (shown, n) -> do
                    tried <- tryBuild build n
                    case tried of
                        -- An explicit choice is final: never prepared around.
                        Right tx -> pure (Right (shown, Nothing, tx))
                        Left e -> pure (Left (OriginalFailure e))
        Nothing -> do
            let spendable = spendableOuts wallet
            natural <- case (selectFunding Nothing wallet, spendable) of
                (_, []) -> pure (Right ([], emptiedView addr v))
                (Right (largestIn, _), _) -> do
                    r <- fundedView (Just largestIn) addr v
                    pure
                        (mapLeft ExplicitFundingRefusal (fmap ([largestIn],) r))
                -- Spendable but no ada-only output: narrow to empty so no
                -- command funds or collateralises from a token-carrying one.
                (Left _, _) -> pure (Right ([], emptiedView addr v))
            case natural of
                Left refusal -> pure (Left refusal)
                Right (shown, n) -> do
                    tried <- tryBuild build n
                    case tried of
                        Right tx -> pure (Right (shown, Nothing, tx))
                        Left naturalE -> case spendable of
                            -- Nothing spendable at all: the natural funding
                            -- error stands as today.
                            [] -> pure (Left (OriginalFailure naturalE))
                            (largestIn, _) : _ -> do
                                probed <-
                                    tryBuild build (overwrittenView addr largestIn (probeOut addr) v)
                                case probed of
                                    Left _ -> pure (Left (OriginalFailure naturalE))
                                    Right overTx -> do
                                        let requirement = measureRequirement pp addr overTx
                                        case planPreparation pp addr requirement wallet of
                                            Left shortfall ->
                                                let (text, fields) =
                                                        shortfallRefusal addr wallet shortfall
                                                in  pure (Left (PreparationShortfall text fields))
                                            Right prep -> do
                                                case overAllowance mAllowance (measure overTx) (prepFee prep) of
                                                    Just (a, o, f) ->
                                                        let (text, fields) = allowanceRefusal a o f Nothing
                                                        in  pure (Left (AllowanceExceeded text fields))
                                                    Nothing -> do
                                                        confirmed <-
                                                            submitPrep wc step addr requirement prep
                                                        buildReal prep confirmed
  where
    mapLeft f = either (Left . f) Right
    buildReal prep _confirmed = do
        realR <-
            readStep (wcTracer wc) (wcSource wc) ["wallet"] (wcCapabilities wc) $ \v2 -> do
                r <- fundedView (Just (prepFunding prep)) addr v2
                case r of
                    Left why -> pure (Left (explicitRefusal step why))
                    Right narrowed -> do
                        b <- tryBuild build narrowed
                        pure (Right b)
        case realR of
            Left refusal -> pure (Left refusal)
            Right (Left e2) -> pure (Left (OriginalFailure e2))
            Right (Right realTx) ->
                case overAllowance mAllowance (measure realTx) (prepFee prep) of
                    Just (a, o, f) ->
                        let (text, fields) = allowanceRefusal a o f (Just (prepFunding prep))
                        in  pure (Left (AllowanceExceeded text fields))
                    Nothing -> pure (Right ([prepFunding prep], Just prep, realTx))

-- | A build that rethrows asynchronous exceptions and reports the rest.
tryBuild
    :: (Cage.Session Cage.NoWitness IO -> IO ConwayTx)
    -> Cage.Session Cage.NoWitness IO
    -> IO (Either SomeException ConwayTx)
tryBuild build s = do
    r <- try (build s)
    case r of
        Right tx -> pure (Right tx)
        Left e -> case fromException e of
            Just (_ :: SomeAsyncException) -> throwIO e
            Nothing -> pure (Left e)

{- | What the command needs, measured from a built transaction: its fee,
its collateral, the ledger minimum for its change. The change floor is the
largest minimum over the payer's outputs, or over every output when the
build pays the payer nothing.
-}
measureRequirement :: PParams ConwayEra -> Addr -> ConwayTx -> Integer
measureRequirement pp payer tx = fee + collateralOf pp tx + changeFloor
  where
    Coin fee = tx ^. (bodyTxL . feeTxBodyL)
    outs = toList (tx ^. (bodyTxL . outputsTxBodyL))
    minsAt =
        [ c
        | o <- outs
        , o ^. addrTxOutL == payer
        , let Coin c = getMinCoinTxOut pp o
        ]
    changeFloor = case minsAt of
        [] -> maximum (0 : [c | o <- outs, let Coin c = getMinCoinTxOut pp o])
        _ -> maximum minsAt

{- | Whether the command plus its preparation passes what is still
approved: the allowance with the outlay it leaves and the preparation
fee, when exceeded.
-}
overAllowance
    :: Maybe Integer -> Outlay -> Integer -> Maybe (Integer, Outlay, Integer)
overAllowance allowance outlay prepFee = case allowance of
    Nothing -> Nothing
    Just a ->
        if outlayTotal outlay + prepFee <= a
            then Nothing
            else Just (a, outlay, prepFee)

{- | The shortfall refusal: what is needed, what the wallet may spend and
the short step, ending that nothing was submitted. Follows the wording of
the measured-cost refusals in 'Plan'.
-}
shortfallRefusal
    :: Addr
    -> [(TxIn, TxOut ConwayEra)]
    -> PrepareError
    -> (String, [(Text, Value)])
shortfallRefusal addr utxos (PrepareShortfall required fee remainderMin _ largest) =
    (text, fields)
  where
    held = spendableHeld utxos
    needed = required + fromMaybe 0 fee + remainderMin
    feePart = maybe "no fee measured" (\f -> show f <> " fee") fee
    text =
        "preparation-unfunded: the wallet holds "
            <> show held
            <> " lovelace but "
            <> show needed
            <> " is required for the preparation ("
            <> show required
            <> " for the command, "
            <> feePart
            <> " and "
            <> show remainderMin
            <> " remainder floor) (client policy); nothing was submitted"
    fields =
        [ ("wallet", toJSON (T.pack (bech32Address addr)))
        , ("held", toJSON held)
        , ("required", toJSON needed)
        , ("shortfall", toJSON (needed - held))
        , ("utxoCount", toJSON (length utxos))
        , ("policy", toJSON ("client" :: Text))
        , ("requiredIs", toJSON ("preparation" :: Text))
        , ("fee", toJSON fee)
        , ("remainderMin", toJSON remainderMin)
        , ("largest", toJSON largest)
        ]

{- | The allowance refusal, naming the command outlay and the preparation
fee against the allowance. Before anything is submitted nothing was;
after the preparation stands confirmed, the command was not signed.
-}
allowanceRefusal
    :: Integer
    -> Outlay
    -> Integer
    -> Maybe TxIn
    -> (String, [(Text, Value)])
allowanceRefusal allowance outlay prepFee mPrep =
    (text, fields)
  where
    both =
        "the measured outlay of "
            <> show (outlayTotal outlay)
            <> " lovelace with the preparation fee of "
            <> show prepFee
            <> " lovelace passes the approved allowance of "
            <> show allowance
    text = case mPrep of
        Nothing -> both <> " (client policy); nothing was submitted"
        Just ref ->
            both
                <> " (client policy); the preparation "
                <> T.unpack (txInText ref)
                <> " stands confirmed and the command was not signed"
    fields =
        [ ("outlay", outlayReport (Just allowance) outlay)
        , ("preparationFee", toJSON prepFee)
        , ("allowance", toJSON allowance)
        ]

{- | An explicit funding choice refused with today's text: the wallet
cannot fund this command with it.
-}
explicitRefusal :: Text -> String -> PrepareRefusal
explicitRefusal step why =
    ExplicitFundingRefusal
        ("the wallet cannot fund the " <> T.unpack step <> ": " <> why)

{- | Submit one judged preparation through the ordinary path: re-plan
against the submission view and refuse on any move since the judgement,
then read the made output back and journal it observed. The preparation
is an ordinary journalled transaction under the command's name; only its
@funding@ expectation is new.
-}
submitPrep
    :: WriteContext
    -> Text
    -> Addr
    -> Integer
    -> Preparation
    -> IO ConfirmedSubmission
submitPrep wc step addr requirement judged = do
    let expectFunding = const (expecting ("funding:" <> T.pack (bech32Address addr)))
    (confirmed, _) <- submitBuilt wc step expectFunding $ \v -> do
        pp <- Cage.parameters v
        utxos <- Cage.outputsAt v addr
        fresh <- case planPreparation pp addr requirement utxos of
            Left _ ->
                failWith
                    ClientRefusal
                    "the wallet changed since the preparation was planned: nothing was submitted"
            Right p -> pure p
        when (txIdTx (prepTx fresh) /= txIdTx (prepTx judged)) $
            failWith
                ClientRefusal
                "the wallet changed since the preparation was planned: nothing was submitted"
        pure (prepTx fresh, fresh)
    funding <-
        readStep (wcTracer wc) (wcSource wc) ["wallet"] (wcCapabilities wc) $ \v ->
            Cage.outputsAt v addr
    let ref = prepFunding judged
    case [o | (i, o) <- funding, i == ref] of
        [o] | adaOnlyOut o -> do
            journalObserved
                wc
                step
                confirmed
                ( "the funding output "
                    <> txInText ref
                    <> " is live, ada only, at the payer's address"
                )
            pure confirmed
        _ ->
            failWith
                Partial
                "the preparation confirmed but its funding output is not live and ada-only"

{- | The receipt fields for a preparation, present only when one was
made: the confirming transaction, the made output reference, what it
holds and the fee. Omitted otherwise, so its absence stays meaningful.
-}
preparationFields :: Maybe Preparation -> [(Text, Value)]
preparationFields = maybe [] (pure . preparationField)

preparationField :: Preparation -> (Text, Value)
preparationField p =
    ( "preparation"
    , object
        [ "transaction" .= txIdHex (prepTx p)
        , "output" .= txInText (prepFunding p)
        , "lovelace" .= prepFundingCoin p
        , "fee" .= prepFee p
        ]
    )

-- | The probe: an oversized ada-only output that dwarfs any command need.
probeCoin :: Integer
probeCoin = 1_000_000_000_000_000

{- | The probe output at the payer's address: an oversized ada-only value
that dwarfs any command need.
-}
probeOut :: Addr -> TxOut ConwayEra
probeOut addr = mkBasicTxOut addr (MaryValue (Coin probeCoin) mempty)
