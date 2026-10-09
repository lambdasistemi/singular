{- |
Module      : Negative.Craft
Description : The crafted transactions, written once in the host
License     : Apache-2.0

The holding-spend shapes (controller update, stranger update,
tampered update, release outside a fold) and the termination booking are
built here and nowhere else the shipped binaries use. The harness keeps
its own copy for now as a named residual until the command-line split
cleans it up. Insertion bookings and fold shapes wait for later slices
and stop at a clear client refusal.
-}
module Negative.Craft
    ( -- * Holding spends (first slice)
      HoldingSpend (..)
    , craftHoldingSpend

      -- * Later slices (named, refused for now)
    , BookingShape (..)
    , FoldPayment (..)
    , craftBooking
    , craftFold
    ) where

import Data.Bits (xor)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Map.Strict qualified as Map
import Data.Void (Void)
import Lens.Micro ((&), (.~), (^.))

import Cardano.Ledger.Api.PParams
    ( ppMaxBlockExUnitsL
    , ppMaxTxExUnitsL
    )
import Cardano.Ledger.Api.Scripts.Data (Datum (..))
import Cardano.Ledger.Api.Tx (witsTxL)
import Cardano.Ledger.Api.Tx.Out
    ( TxOut
    , addrTxOutL
    , datumTxOutL
    , mkBasicTxOut
    , valueTxOutL
    )
import Cardano.Ledger.Api.Tx.Wits (Redeemers (..), rdmrsTxWitsL)
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Mary.Value (MaryValue (..))
import Cardano.Tx.Build qualified as Tx
import Cardano.Tx.Ledger (ConwayTx)
import PlutusCore.Data qualified as PLC

import Singular.Application.OpenDatum.Book
    ( terminateApproval
    , terminateDestination
    )
import Singular.Application.OpenDatum.Envelope
    ( Control (..)
    , Envelope (..)
    )
import Singular.Application.OpenDatum.Update
    ( continuationOf
    , releaseRedeemer
    , updateRedeemer
    )
import Singular.CLI.Live
    ( Live (..)
    , Saved (..)
    , applicationReference
    , applied
    , liveOutputFor
    , liveOutputs
    )
import Singular.CLI.Receipt (OutcomeClass (..))
import Singular.CLI.Session (failWith)
import Singular.Registry.Evidence (NoWitness)
import Singular.Registry.Ledger (ConwayEra, TxIn)
import Singular.Registry.LedgerProvider (Session)
import Singular.Registry.SessionIO qualified as Cage
import Singular.Registry.TxBuilder.ConnectedFold (skipEvalUnits)
import Singular.Registry.TxBuilder.Edges
    ( BookingApproval (..)
    , adaOnlyOut
    , bookEdgeTx
    , edgeDeposit
    )
import Singular.Registry.TxBuilder.Internal
    ( addrKeyHashBytes
    , addrWitnessKeyHash
    , scriptFromBytes
    )
import Singular.Registry.Types (edgeUpdateTerminal)
import Singular.Registry.Wallet (Wallet (..))

import Negative.Parse (TamperField (..))

{- | The closed set of holding spends the host crafts. The first slice
runs all four end to end; later slices add booking and fold shapes
beside them.
-}
data HoldingSpend
    = SpendControllerUpdate PLC.Data
    | SpendStrangerUpdate PLC.Data
    | SpendTamperedUpdate TamperField PLC.Data
    | SpendRelease
    deriving stock (Eq, Show)

{- | Which booking the host books. Stranger or honest is not a separate
choice: the booking names the wallet that signs as its payer and owner,
so the controller's own command is the honest booking and a stranger's
the forbidden one; the node tells them apart. Insertions wait for the
third slice.
-}
data BookingShape
    = BookingInsert
    | BookingTerminate
    deriving stock (Eq, Show)

{- | What a fold pays its controller. The honest fold pays exactly what
is owed; the short fold pays less by the named lovelace.
-}
data FoldPayment
    = PayAsOwed
    | PayShort Integer
    deriving stock (Eq, Show)

{- | The query type the holding-spend story programs run under. Empty:
the host builds from what it read, never from a ledger query.
-}
data CraftCtx a

{- | The controller a tampered update names. A stranger names herself:
rewriting the live controller to the signer she submits as. The
controller herself (the second slice's tamper family, per the versioned
rows) cannot name herself — that would be the honest continuation — so
she names the live controller with its last byte flipped: still a
protected-field rewrite the application refuses, derived from the live
envelope with no literal and no second key.
-}
otherController :: Control -> ByteString -> ByteString
otherController ctl signer
    | signer == ctlController ctl = flipLast (ctlController ctl)
    | otherwise = signer

-- | The last byte of a name changed: the same length, another value.
flipLast :: ByteString -> ByteString
flipLast bs
    | BS.null bs = BS.singleton 1
    | otherwise = BS.init bs <> BS.singleton (BS.last bs `xor` 1)

{- | The unsigned holding-spend transaction for one of the four shapes.
Built with fixed execution budgets and no local evaluation, so the node
judges it. Signs nothing here; submission signs with the named key file.
-}
craftHoldingSpend
    :: Session NoWitness IO
    -> Live
    -> (TxIn, TxOut ConwayEra)
    -> Envelope
    -> Wallet
    -> Wallet
    -> HoldingSpend
    -> IO ConwayTx
craftHoldingSpend view live holding@(hIn, hOut) envelope caller signer spend = do
    pp <- Cage.parameters view
    let home = walletAddr caller
        signerBytes = addrKeyHashBytes (walletAddr signer)
    feeUtxo <- pickFee view caller
    let appRef = applicationReference live
        MaryValue (Coin held) tokens = hOut ^. valueTxOutL
        payloadOf = case spend of
            SpendControllerUpdate p -> p
            SpendStrangerUpdate p -> p
            SpendTamperedUpdate _ p -> p
            SpendRelease -> PLC.I 0
        next = continuationOf hOut envelope payloadOf
        ctl = envControl envelope
        theirs = signerBytes
        tamperedOut = case spend of
            SpendTamperedUpdate TamperController _ ->
                continuationOf
                    hOut
                    envelope{envControl = ctl{ctlController = otherController ctl theirs}}
                    payloadOf
            SpendTamperedUpdate TamperDeposit _ ->
                continuationOf
                    hOut
                    envelope{envControl = ctl{ctlDeposit = 1}}
                    payloadOf
            SpendTamperedUpdate TamperToken _ ->
                next & valueTxOutL .~ MaryValue (Coin held) mempty
            SpendTamperedUpdate TamperAddress _ ->
                next & addrTxOutL .~ home
            SpendTamperedUpdate TamperDatum _ ->
                next & datumTxOutL .~ NoDatum
            _ -> next
        (outputs, redeemer) = case spend of
            SpendControllerUpdate _ -> ([next], updateRedeemer)
            SpendStrangerUpdate _ -> ([next], updateRedeemer)
            SpendTamperedUpdate TamperToken _ ->
                (
                    [ tamperedOut
                    , mkBasicTxOut home (MaryValue (Coin held) tokens)
                    ]
                , updateRedeemer
                )
            SpendTamperedUpdate _ _ -> ([tamperedOut], updateRedeemer)
            SpendRelease ->
                ( [mkBasicTxOut home (hOut ^. valueTxOutL)]
                , releaseRedeemer
                )
        prog :: Tx.TxBuild CraftCtx Void ()
        prog = do
            _ <- Tx.spendScript hIn redeemer
            mapM_ Tx.output outputs
            Tx.requireSignature (addrWitnessKeyHash signerBytes)
            case appRef of
                Just (ref, _) -> Tx.reference ref
                Nothing ->
                    Tx.attachScript
                        (scriptFromBytes "open-datum" (applied (liveSaved live)))
            Tx.collateral (fst feeUtxo)
        skipEval tx =
            let Redeemers rdmrs = tx ^. witsTxL . rdmrsTxWitsL
                units =
                    skipEvalUnits
                        (pp ^. ppMaxTxExUnitsL)
                        (pp ^. ppMaxBlockExUnitsL)
                        (Map.size rdmrs)
            in  pure (Map.map (const (Right units)) rdmrs)
    built <-
        Tx.build
            (Tx.mkPParamsBound pp)
            (Tx.InterpretIO (const (pure undefined)))
            skipEval
            [feeUtxo, holding]
            (maybe [] pure appRef)
            home
            prog
    either
        ( failWith ClientRefusal
            . (("the holding spend did not build: " <>) . show)
        )
        pure
        built
  where
    pickFee v w = do
        utxos <- Cage.outputsAt v (walletAddr w)
        case filter (adaOnlyOut . snd) utxos of
            (u : _) -> pure u
            [] ->
                failWith
                    ClientRefusal
                    "the wallet has no ada-only output to fund the transaction"

{- | The unsigned booking for one shape, built unevaluated with stated
budgets so the node judges it: the payer wallet funds it and is named
its owner, with no controller check here. Termination bookings run in
this slice; insertions wait for the third.
-}
craftBooking
    :: Session NoWitness IO
    -> Live
    -> Wallet
    -> ByteString
    -> BookingShape
    -> IO ConwayTx
craftBooking view live payer key shape = case shape of
    BookingInsert ->
        failWith
            ClientRefusal
            "not in this slice: insert bookings arrive in the third slice"
    BookingTerminate -> do
        let s = liveSaved live
        outs <- liveOutputs view s
        ((liveIn, _), _) <-
            either (failWith ClientRefusal) pure (liveOutputFor s key outs)
        appRef <-
            maybe
                ( failWith
                    ClientRefusal
                    "the deployment records no published application reference"
                )
                (pure . fst)
                (applicationReference live)
        let stateIn = fst (liveState live)
            owner = addrKeyHashBytes (walletAddr payer)
            approval =
                ( terminateApproval
                    (applied s)
                    stateIn
                    liveIn
                    key
                    owner
                )
                    { baScriptReference = Just appRef
                    }
        bookEdgeTx
            (savedCfg s)
            view
            (walletAddr payer)
            (savedToken s)
            key
            edgeUpdateTerminal
            terminateDestination
            edgeDeposit
            (Just approval)

-- | A fold for later slices. Refused until the third slice crafts it.
craftFold
    :: Live
    -> FoldPayment
    -> IO ConwayTx
craftFold _ _ =
    failWith
        ClientRefusal
        "not in this slice: folds arrive in the third slice"
