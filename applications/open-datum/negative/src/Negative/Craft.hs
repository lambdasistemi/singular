{-# LANGUAGE LambdaCase #-}

{- |
Module      : Negative.Craft
Description : The crafted transactions, written once in the host
License     : Apache-2.0

The holding-spend shapes (controller update, stranger update,
tampered update, release outside a fold), the insertion and termination
bookings and the unevaluated fold are built here and nowhere else the shipped
binaries use. The harness keeps its own copy for now as a named
residual until the command-line split cleans it up.
-}
module Negative.Craft
    ( -- * Holding spends (first slice)
      HoldingSpend (..)
    , craftHoldingSpend

      -- * Bookings and folds
    , BookingShape (..)
    , FoldPayment (..)
    , FoldSelection (..)
    , craftBooking
    , craftFold
    , donationOf
    , selectFoldRequests
    ) where

import Control.Monad (foldM, void)
import Data.Bits (xor)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Foldable (toList)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.List (sortOn)
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map
import Data.Ord (Down (..))
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Traversable (mapAccumL)
import Data.Void (Void)
import Lens.Micro (over, (%~), (&), (.~), (^.))

import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.Api.PParams
    ( ppMaxBlockExUnitsL
    , ppMaxTxExUnitsL
    )
import Cardano.Ledger.Api.Scripts.Data (Datum (..))
import Cardano.Ledger.Api.Tx (bodyTxL, witsTxL)
import Cardano.Ledger.Api.Tx.Body
    ( outputsTxBodyL
    , reqSignerHashesTxBodyL
    , treasuryDonationTxBodyL
    )
import Cardano.Ledger.Api.Tx.Out
    ( TxOut
    , addrTxOutL
    , coinTxOutL
    , datumTxOutL
    , mkBasicTxOut
    , referenceScriptTxOutL
    , valueTxOutL
    )
import Cardano.Ledger.Api.Tx.Wits (Redeemers (..), rdmrsTxWitsL)
import Cardano.Ledger.BaseTypes (StrictMaybe (..))
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Core (hashScript)
import Cardano.Ledger.Mary.Value (MaryValue (..))
import Cardano.Slotting.Slot (SlotNo (..))
import Cardano.Tx.Build qualified as Tx
import Cardano.Tx.Ledger (ConwayTx)
import PlutusCore.Data qualified as PLC

import Singular.Application.OpenDatum.Book
    ( bookTerminationRedeemer
    )
import Singular.Application.OpenDatum.Envelope
    ( Control (..)
    , Envelope (..)
    , envelopeFromData
    )
import Singular.Application.OpenDatum.Holding (withApplication)
import Singular.Application.OpenDatum.InsertEnvelope (insertEnvelope)
import Singular.Application.OpenDatum.Plan (Booked (..), planInsert)
import Singular.Application.OpenDatum.Update
    ( continuationOf
    , releaseRedeemer
    , updateRedeemer
    )
import Singular.Application.OpenDatum.Value (openDatumApplication)
import Singular.CLI.Live
    ( Live (..)
    , Saved (..)
    , applicationReference
    , applied
    , coinOf
    , liveOutputFor
    , liveOutputs
    , newStatePoint
    , savedIdentity
    )
import Singular.CLI.Receipt (OutcomeClass (..))
import Singular.CLI.Session (failWith)
import Singular.Registry.Application (DecodedHolding (..))
import Singular.Registry.Config (CageConfig (..))
import Singular.Registry.Evidence (NoWitness)
import Singular.Registry.Ledger
    ( ConwayEra
    , Root (..)
    , TokenId (..)
    , TxIn
    )
import Singular.Registry.LedgerProvider (Session)
import Singular.Registry.LedgerProvider qualified as LP
import Singular.Registry.SessionIO qualified as Cage
import Singular.Registry.Trie (Trie (..), TrieManager (..))
import Singular.Registry.Trie.PureManager (mkPureTrieManager)
import Singular.Registry.TrieState qualified as TS
import Singular.Registry.TrieState.Lineage (lineageTrieState)
import Singular.Registry.TxBuilder.ConnectedFold
    ( ConnectedFoldArgs (..)
    , ConnectedMint (..)
    , connectedFoldTx
    , skipEvalUnits
    )
import Singular.Registry.TxBuilder.Edges
    ( adaOnlyOut
    , registryContextFor
    )
import Singular.Registry.TxBuilder.Internal
    ( BookedRequest (..)
    , addrKeyHashBytes
    , addrWitnessKeyHash
    , bookedKey
    , bookedRequestOf
    , extractCageDatum
    , leafAbsent
    , leafActive
    , leafTerminal
    , onChainTokenId
    , pendingByTag
    , scriptFromBytes
    )
import Singular.Registry.TxBuilder.TerminationBooking
    ( CustodyAuthority (..)
    , TerminationBooking (..)
    , bookTerminationImpl
    )
import Singular.Registry.TxBuilder.Update
    ( RegistryContext (..)
    , taggedMints
    )
import Singular.Registry.Types
    ( CageDatum (..)
    , OnChainRequest (..)
    , OnChainRoot (..)
    , OnChainTokenState (..)
    )
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
the forbidden one; the node tells them apart. An insertion carries its
payload and deposit; a termination reads its live output.
-}
data BookingShape
    = BookingInsert PLC.Data Integer
    | BookingTerminate
    deriving stock (Eq, Show)

{- | What a fold pays its controller. The honest fold pays exactly what
is owed; the short fold pays less by the named lovelace.
-}
data FoldPayment
    = PayAsOwed
    | PayShort Integer
    deriving stock (Eq, Show)

{- | Which pending requests a fold takes. The plain @fold@ form takes
everything pending; a named key takes the one request pending for that
key, so a refused fold leaves its request pending for a later fold of
a different key to ignore.
-}
data FoldSelection
    = FoldKey ByteString
    | FoldEvery
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
    let appRef = applicationReference openDatumApplication live
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

{- | The unsigned booking for one shape, built by the registry's shared
registration or termination booking, as the producers build it: the payer
wallet funds it and is named its owner and its refund, with no controller
check here. A taken or terminated key still reaches the builder, and the
booking is a request only: the registry's fold refuses it later, so the
node judges the fold.

The shared builders evaluate the scripts they build for, so a booking an
application script refuses is not built at all; a booking the host means the
node to judge has to be built for what the script accepts and then changed
in the one fact under test. A termination is built naming the live
controller as its required signer, which the application's spend accepts,
and its required signer is then replaced by the wallet that signs: for the
controller's own command nothing changes, and for a stranger's the node is
the one that refuses the spend.
-}
craftBooking
    :: Session NoWitness IO
    -> Live
    -> Wallet
    -> ByteString
    -> BookingShape
    -> IO ConwayTx
craftBooking view live payer key shape = case shape of
    BookingInsert payload deposit -> do
        let s = liveSaved live
            owner = addrKeyHashBytes (walletAddr payer)
            envelope =
                insertEnvelope
                    (savedCfg s)
                    (savedToken s)
                    key
                    owner
                    deposit
                    payload
        booked <- planInsert view live envelope
        bookedBuild booked view (walletAddr payer)
    BookingTerminate -> do
        let s = liveSaved live
            cfg = savedCfg s
            owner = addrKeyHashBytes (walletAddr payer)
        outs <- liveOutputs openDatumApplication view s
        (holding, held') <-
            either
                (failWith ClientRefusal)
                pure
                (liveOutputFor openDatumApplication s key outs)
        envelope <-
            either
                (failWith ClientRefusal)
                pure
                (envelopeFromData (dhDatumData held'))
        observed <- Cage.tip view
        let Coin held = snd holding ^. coinTxOutL
            Coin tip = defaultTip cfg
            controller = ctlController (envControl envelope)
        accepted <-
            bookTerminationImpl
                cfg
                view
                (savedToken s)
                (fst (liveState live))
                TerminationBooking
                    { tbKey = key
                    , tbDeclaredTip = Coin tip
                    , tbCarrier = Coin (held - tip)
                    , tbNonce = toInteger (unSlotNo (LP.observedSlot observed))
                    , tbCustody = holding
                    , tbOrdinaryAdded = Coin 0
                    , tbCustodyAuthority =
                        ScriptGuarded (applied s) (bookTerminationRedeemer 0)
                    , tbRequiredSigners = [controller]
                    }
                (walletAddr payer)
        pure $
            over
                (bodyTxL . reqSignerHashesTxBodyL)
                (const (Set.singleton (addrWitnessKeyHash owner)))
                accepted

{- | The pending requests one fold takes, in input order, with the
bookings they are. @FoldEvery@ takes everything pending (at least one);
@FoldKey k@ takes the one request with that key. Pending means booked: found
by the request policy's tag through the view, and a genuine booking of this
registry.
-}
selectFoldRequests
    :: Session NoWitness IO
    -> Live
    -> FoldSelection
    -> IO [((TxIn, TxOut ConwayEra), BookedRequest)]
selectFoldRequests view live selection = do
    let s = liveSaved live
        cfg = savedCfg s
        tok = savedToken s
    pending <- pendingByTag cfg view tok
    let selects q = case selection of
            FoldKey k -> bookedKey q == k
            FoldEvery -> True
        requests =
            sortOn
                (fst . fst)
                [ (u, q)
                | u@(_, o) <- pending
                , Just q <- [bookedRequestOf cfg tok o]
                , selects q
                ]
    case (selection, requests) of
        (FoldEvery, _ : _) -> pure requests
        (FoldEvery, []) ->
            failWith ClientRefusal "no request is pending for the fold"
        (FoldKey _, [one]) -> pure [one]
        _ ->
            failWith
                ClientRefusal
                "the fold needs exactly one pending request for the named key"

{- | The unsigned fold of the selected pending requests, built
unevaluated with stated budgets so the node judges it: signed and
funded by the folder wallet (a fold is permissionless; the folder may
be a stranger), with no local evaluation and no client check beyond
finding its inputs. @PayShort n@ lowers the treasury donation the fold
makes by @n@ lovelace and leaves the lovelace with the folder's change, so
the body still balances and the registry's validators are the ones that
refuse. Returns the transaction with the folded requests' outrefs and keys.
-}
craftFold
    :: Session NoWitness IO
    -> Live
    -> Wallet
    -> FoldSelection
    -> FoldPayment
    -> IO (ConwayTx, [(TxIn, ByteString)])
craftFold view live folder selection payment = do
    let s = liveSaved live
        cfg = savedCfg s
        tok = savedToken s
        feeAddr = walletAddr folder
        (stateIn, stateOut) = liveState live
    oldState <- case extractCageDatum stateOut of
        Just (StateDatum st) -> pure st
        _ ->
            failWith
                ClientRefusal
                "the registry's state output carries no state datum"
    let OnChainRoot chain = stateRoot oldState
    chosen <- selectFoldRequests view live selection
    let reqUtxos = map fst chosen
        chosenKeys =
            [ (tin, bookedKey q)
            | ((tin, _), q) <- chosen
            ]
    tm <-
        hostPublicFoldTrie view s stateIn chain
            >>= either
                (failWith ClientRefusal . show)
                pure
    ctx0 <- registryContextFor cfg (savedCodes s) view (liveRefs live)
    ctx <-
        either
            (failWith ClientRefusal)
            pure
            (withApplication (applied s) Nothing ctx0)
    mints <-
        either
            (failWith ClientRefusal)
            pure
            ( taggedMints
                cfg
                ctx
                [(tin, q) | ((tin, _), q) <- chosen]
            )
    wallets <- Cage.outputsAt view feeAddr
    feeUtxo <- case sortOn (Down . coinOf . snd) (filter (adaOnlyOut . snd) wallets) of
        (u : _) -> pure u
        [] ->
            failWith
                ClientRefusal
                "the folder has no ada-only output to fund the fold"
    let carried =
            [ hashScript sc
            | (_, o) <- rcRefUtxos ctx
            , SJust sc <- [o ^. referenceScriptTxOutL]
            ]
        owed = map cmScript mints
    (unsigned, _) <-
        connectedFoldTx
            ConnectedFoldArgs
                { cfaCfg = cfg
                , cfaSession = view
                , cfaTrie = tm
                , cfaToken = tok
                , cfaFeeAddr = feeAddr
                , cfaStateUtxo = (stateIn, stateOut)
                , cfaReqUtxos = reqUtxos
                , cfaFeeUtxo = feeUtxo
                , cfaSpends = []
                , cfaMints = mints
                , cfaOutputs = []
                , cfaSigners = []
                , cfaRefUtxos = rcRefUtxos ctx
                , cfaAttachScripts = filter ((`notElem` carried) . hashScript) owed
                , cfaSkipEval = True
                , cfaAdjustRoot = id
                }
    shortened <- applyPayShort feeAddr payment unsigned
    pure (shortened, chosenKeys)

-- | The lovelace a transaction donates to the treasury.
donationOf :: ConwayTx -> Integer
donationOf tx =
    let Coin donated = tx ^. bodyTxL . treasuryDonationTxBodyL in donated

{- | Lower the treasury donation the fold makes by the named lovelace and
give the lovelace to the folder's change, the last output paying the folder:
the body still balances, and the donation is the one fact the registry's
validators check that is now wrong. The honest payment leaves the fold
untouched.
-}
applyPayShort :: Addr -> FoldPayment -> ConwayTx -> IO ConwayTx
applyPayShort _ PayAsOwed tx = pure tx
applyPayShort feeAddr (PayShort n) tx
    | n <= 0 =
        failWith
            ClientRefusal
            "pay-short needs a positive number of lovelace"
    | Coin donated <- tx ^. bodyTxL . treasuryDonationTxBodyL
    , donated < n =
        failWith
            ClientRefusal
            "the fold donates less than the lovelace asked to hold back"
    | otherwise = case reverse [i | (i, o) <- indexed, o ^. addrTxOutL == feeAddr] of
        i : _ -> pure (shortened i)
        [] ->
            failWith
                ClientRefusal
                "no output pays the folder it could be given the held-back lovelace"
  where
    indexed = zip [0 :: Int ..] (toList (tx ^. bodyTxL . outputsTxBodyL))
    lowered (Coin d) = Coin (d - n)
    shortened i =
        over
            (bodyTxL . outputsTxBodyL)
            (snd . mapAccumL (\j o -> (j + 1, raise i j o)) (0 :: Int))
            (over (bodyTxL . treasuryDonationTxBodyL) lowered tx)
    raise i j o
        | i == j = o & coinTxOutL %~ (\(Coin c) -> Coin (c + n))
        | otherwise = o

{- | The mutable trie for one fold, rebuilt here (never from a saved
mirror) from fresh authenticated public replay: the keys come from the
very history stream the lineage backend validates, their current leaves
only from its snapshot, and the rebuilt root must chain before anything
is built. Host-local copy of the harness @publicFoldTrie@; the harness
copy stays as the named residual.
-}
hostPublicFoldTrie
    :: Session NoWitness IO
    -> Saved
    -> TxIn
    -> ByteString
    -> IO (Either TS.TrieFailure (TrieManager IO))
hostPublicFoldTrie session saved stateIn chain = do
    keys <- newIORef Set.empty
    let TokenId name = savedToken saved
        token = TokenId name
        selection =
            TS.TrieSelection
                (savedIdentity saved)
                (newStatePoint session stateIn)
                (Root chain)
        tracked =
            session
                { LP.history = \asset range ->
                    fmap
                        (fmap (hostRecordKeys token keys))
                        (LP.history session asset range)
                }
    answer <-
        TS.withTrieState (lineageTrieState tracked) selection $ \snapshot -> do
            watched <- readIORef keys
            hostMaterializeFoldTrie snapshot watched
    pure $ case answer of
        Left why -> Left why
        Right inner -> inner

{- | Observe consumed request keys without interpreting their edges or
roots.
-}
hostRecordKeys
    :: TokenId
    -> IORef (Set ByteString)
    -> LP.HistoryStream IO
    -> LP.HistoryStream IO
hostRecordKeys token keys stream =
    LP.HistoryStream $
        LP.nextBlock stream >>= \case
            Left why -> pure (Left why)
            Right Nothing -> pure (Right Nothing)
            Right (Just (block, rest)) -> do
                modifyIORef' keys $
                    Set.union $
                        Set.fromList
                            [ requestKey request
                            | record <- NE.toList (LP.blockTransactions block)
                            , (_, output) <- LP.spentOutputs record
                            , Just (RequestDatum request) <- [extractCageDatum output]
                            , requestToken request == onChainTokenId token
                            ]
                pure (Right (Just (block, hostRecordKeys token keys rest)))

{- | Materialize authenticated current leaves into the ordinary MPF
producer. Deleted keys prove @Unknown@ and are omitted. A missing key
cannot silently give a partial trie: it changes the root and refuses
before building.
-}
hostMaterializeFoldTrie
    :: TS.TrieSnapshot IO
    -> Set ByteString
    -> IO (Either TS.TrieFailure (TrieManager IO))
hostMaterializeFoldTrie snapshot keys = do
    manager <- mkPureTrieManager
    let who@(TS.RegistryIdentity _ name) = TS.trieIdentity snapshot
        token = TokenId name
    createTrie manager token
    withTrie manager token $ \trie -> do
        filled <- foldM (fill trie) (Right ()) (Set.toList keys)
        case filled of
            Left why -> pure (Left why)
            Right () -> do
                rebuilt <- getRoot trie
                pure $
                    if rebuilt == TS.trieRoot snapshot
                        then Right manager
                        else
                            Left
                                ( TS.RootDoesNotChain
                                    who
                                    Nothing
                                    (TS.RootsPart rebuilt (TS.trieRoot snapshot))
                                )
  where
    fill _ failure@(Left _) _ = pure failure
    fill trie (Right ()) key =
        TS.leafAt snapshot key >>= \case
            Left why -> pure (Left why)
            Right leaf -> case leaf of
                TS.Unknown -> pure (Right ())
                TS.Absent -> inserted leafAbsent
                TS.Active -> inserted leafActive
                TS.Terminal -> inserted leafTerminal
              where
                inserted bytes = do
                    void (insert trie key bytes)
                    pure (Right ())
