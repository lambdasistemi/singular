{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.Registry.E2E.ReplayHistory
Description : One registry's public history, made on a devnet with the library builders
License     : Apache-2.0

The replay is checked against what the chain itself accepted, so its
history is made here, on a real devnet, and nothing about it is typed in.
One registry is created and folded with the library's own builders
through the two edges the command line books, @ then
@updateTerminal@ on one key, then a fold that rejects a request, then a
fold that applies one request and rejects the others.

Every transaction goes through one recording submitter, which resolves
each input the transaction spends or references from the outputs of the
wallet at the start and of every transaction recorded since. The history
handed to the replay is the state token's: @create@ and the folds, with
the resolutions of exactly those transactions, which is what a ledger
provider serves. After each fold the state output and its root are read
back from the chain.

The mixed fold carries two inputs that look like requests and must take no
action: a spent wallet output whose inline request datum names another
registry's token, and a reference input whose inline request datum names
this registry's token. Its requests are booked until their booking order
differs from their ledger order, and the one it applies is a request whose
position differs between the two orders.
-}
module Singular.Registry.E2E.ReplayHistory
    ( History (..)
    , StatePoint (..)
    , MixedFold (..)
    , recordHistory
    ) where

import Control.Monad (forM, unless, when)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Short qualified as SBS
import Data.Foldable (toList)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.List (sort, sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Ord (Down (..))
import Data.Sequence.Strict qualified as StrictSeq
import Data.Set qualified as Set
import Lens.Micro ((&), (.~), (^.))

import Cardano.Ledger.Address (Addr, serialiseAddr)
import Cardano.Ledger.Api.Tx (bodyTxL, mkBasicTx, txIdTx)
import Cardano.Ledger.Api.Tx.Body
    ( feeTxBodyL
    , inputsTxBodyL
    , mkBasicTxBody
    , outputsTxBodyL
    , referenceInputsTxBodyL
    )
import Cardano.Ledger.Api.Tx.Out
    ( TxOut
    , coinTxOutL
    , datumTxOutL
    , mkBasicTxOut
    , referenceScriptTxOutL
    , valueTxOutL
    )
import Cardano.Ledger.BaseTypes (StrictMaybe (..), TxIx (..))
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Mary.Value
    ( AssetName (..)
    , MaryValue (..)
    , MultiAsset (..)
    , PolicyID (..)
    )
import Cardano.Ledger.TxIn (TxIn (..))
import Cardano.Node.Client.E2E.Setup (genesisAddr)
import Cardano.Tx.Ledger (ConwayTx)
import PlutusTx.Builtins.Internal (BuiltinByteString (..))

import Singular.Registry.AssetName (deriveAssetName)
import Singular.Registry.Blueprint
    ( NamingCodes
    , loadRegistryCodesFromEnv
    )
import Singular.Registry.Config (CageConfig (..))
import Singular.Registry.Driver qualified as Driver
import Singular.Registry.Ledger (ConwayEra, Root (..), TokenId (..))
import Singular.Registry.Node (Capabilities (..))
import Singular.Registry.Provider qualified as Cage
import Singular.Registry.TrieState
    ( RegistryIdentity (..)
    , StatePolicyId (..)
    )
import Singular.Registry.TxBuilder.Edges qualified as Edges
import Singular.Registry.TxBuilder.Internal
    ( addrFromKeyHashBytes
    , cageAddrFromCfg
    , cagePolicyIdFromCfg
    , extractCageDatum
    , findStateUtxo
    , mkInlineDatum
    , scriptHashBytes
    , toPlcData
    , txInToRef
    )
import Singular.Registry.TxBuilder.Reject (rejectRequestsWithRefs)
import Singular.Registry.Types
    ( CageDatum (..)
    , Edge
    , OnChainRequest (..)
    , OnChainRoot (..)
    , OnChainTokenId (..)
    , OnChainTokenState (..)
    , edgeInsertActive
    , edgeUpdateTerminal
    )

import Singular.Registry.E2E.CageSpec (submitWithGenesis, withE2E)
import Singular.Registry.E2E.MixedFold (mixedFold)

-- | A state output and the root the chain holds there, read back from the chain.
data StatePoint = StatePoint
    { pointTx :: ConwayTx
    -- ^ The transaction that made the state output
    , pointOutput :: TxIn
    -- ^ The state output, as the chain's UTxO set names it
    , pointRoot :: Root
    -- ^ The root in its state datum, as the chain holds it
    , pointLabel :: String
    }

-- | The mixed fold and the facts its checks need.
data MixedFold = MixedFold
    { mixedBooked :: [TxIn]
    -- ^ Its requests, in the order they were booked
    , mixedApplied :: TxIn
    -- ^ The one request it applies
    , mixedDecoySpent :: TxIn
    -- ^ A spent wallet output with another registry's inline request datum
    , mixedDecoyReferenced :: TxIn
    -- ^ A reference input with this registry's inline request datum
    }

-- | One registry's history, as a ledger provider would serve it.
data History = History
    { historyToken :: RegistryIdentity
    , historyCreate :: StatePoint
    , historyFolds :: [StatePoint]
    -- ^ In the order they were submitted
    , historyResolved :: Map TxIn (TxOut ConwayEra)
    -- ^ Every input @create@ and the folds spend or reference
    , historyMixed :: MixedFold
    , historyStranger :: TxIn
    -- ^ An output reference no registry here was created from
    }

-- | The recording submitter's state: every known output, and what each transaction resolved.
data Recorder = Recorder
    { recKnown :: IORef (Map TxIn (TxOut ConwayEra))
    , recResolved :: IORef (Map TxIn (Map TxIn (TxOut ConwayEra)))
    -- ^ Keyed by the transaction's own first output reference
    }

{- | Make the history on a fresh devnet. The devnet is gone when this
returns; everything the checks need is in the answer.
-}
recordHistory
    :: SBS.ShortByteString -> SBS.ShortByteString -> IO History
recordHistory stateBytes requestBytes =
    withE2E stateBytes requestBytes $ \cfg prov caps tm -> do
        codes <- loadRegistryCodesFromEnv
        wallet <- Cage.withView prov (`Cage.viewUTxOsAt` genesisAddr)
        rec <-
            Recorder <$> newIORef (Map.fromList wallet) <*> newIORef Map.empty
        let submit = recordingSubmit caps rec
        reg <- Driver.bootRegistry cfg codes prov submit genesisAddr tm
        let tid = Driver.registryTokenId reg
            refs = Driver.registryRefs reg
            PolicyID policy = cagePolicyIdFromCfg cfg
            token =
                RegistryIdentity
                    (StatePolicyId (scriptHashBytes policy))
                    (unTokenId tid)
        create <- statePoint cfg prov tid (Driver.registryBootTx reg) "create"
        let single label key edge dest = do
                outcome <- Driver.foldEdgeTo reg key edge dest
                statePoint cfg prov tid (Driver.foFoldTx outcome) label
            wallet' = (serialiseAddr genesisAddr, BS.empty)
        -- The two edges the command line books, on one key.
        edgeFolds <-
            sequence
                [ single "insertActive" "replay-key-c" edgeInsertActive wallet'
                , single "updateTerminal" "replay-key-c" edgeUpdateTerminal wallet'
                ]
        -- A fold that rejects its one request.
        _ <-
            book cfg codes prov submit tid "replay-key-e" edgeInsertActive wallet'
        rejectTx <-
            Cage.withView
                prov
                (\v -> rejectRequestsWithRefs cfg v tid genesisAddr refs)
                >>= submit
        rejected <- statePoint cfg prov tid rejectTx "reject"
        -- Folds return approvals and tokens to the wallet with their
        -- change, so its largest output is no longer plain ada; bookings
        -- fund from plain ada only.
        splitPlainAda prov submit
        -- The mixed fold.
        booked <- bookUntilOrdersDiffer cfg codes prov submit tid wallet'
        let ledgerOrder = sort booked
        appliedIn <-
            case [l | (l, b) <- zip ledgerOrder booked, l /= b] of
                (l : _) -> pure l
                [] -> fail "ORDER-WITNESS: booking order equals ledger order"
        (decoySpent, decoyReferenced) <- makeDecoys cfg prov submit tid
        mixedTx <-
            Cage.withView prov $ \v ->
                mixedFold
                    cfg
                    codes
                    v
                    tm
                    tid
                    genesisAddr
                    refs
                    (Set.singleton appliedIn)
                    [decoySpent]
                    [decoyReferenced]
        signedMixed <- submit mixedTx
        mixed <- statePoint cfg prov tid signedMixed "mixed"
        let folds = edgeFolds <> [rejected, mixed]
        resolutions <- readIORef (recResolved rec)
        resolved <-
            Map.unions
                <$> forM
                    (create : folds)
                    ( \p ->
                        maybe
                            (fail ("recorder: no resolution for " <> pointLabel p))
                            pure
                            (Map.lookup (firstOutput (pointTx p)) resolutions)
                    )
        pure
            History
                { historyToken = token
                , historyCreate = create
                , historyFolds = folds
                , historyResolved = resolved
                , historyMixed =
                    MixedFold
                        { mixedBooked = booked
                        , mixedApplied = appliedIn
                        , mixedDecoySpent = fst decoySpent
                        , mixedDecoyReferenced = fst decoyReferenced
                        }
                , historyStranger = fst decoyReferenced
                }

{- | Submit through the suite's genesis signer, first resolving every input
the transaction spends or references from the known outputs. An input the
recorder cannot resolve fails the scenario: the history would be missing
material, and the replay's verdict on it would mean nothing.
-}
recordingSubmit :: Capabilities -> Recorder -> ConwayTx -> IO ConwayTx
recordingSubmit caps rec unsigned = do
    known <- readIORef (recKnown rec)
    let body = unsigned ^. bodyTxL
        wanted =
            Set.toList (body ^. inputsTxBodyL)
                <> Set.toList (body ^. referenceInputsTxBodyL)
    resolved <- forM wanted $ \i -> case Map.lookup i known of
        Just o -> pure (i, o)
        Nothing ->
            fail ("recorder: no recorded transaction produced " <> show i)
    signed <- submitWithGenesis caps unsigned
    putStrLn
        ( "[replay-history] landed "
            <> show (txIdTx signed)
            <> " spending "
            <> show (length wanted)
            <> " resolved inputs"
        )
    let produced =
            Map.fromList
                [ (TxIn (txIdTx signed) (TxIx ix), o)
                | (ix, o) <- zip [0 ..] (toList (signed ^. bodyTxL . outputsTxBodyL))
                ]
    modifyIORef' (recKnown rec) (Map.union produced)
    modifyIORef'
        (recResolved rec)
        (Map.insert (firstOutput signed) (Map.fromList resolved))
    pure signed

firstOutput :: ConwayTx -> TxIn
firstOutput tx = TxIn (txIdTx tx) (TxIx 0)

-- | The state output the chain holds after a transaction, and its root.
statePoint
    :: CageConfig
    -> Cage.Provider IO
    -> TokenId
    -> ConwayTx
    -> String
    -> IO StatePoint
statePoint cfg prov tid tx label = do
    utxos <-
        Cage.withView
            prov
            (`Cage.viewUTxOsAt` cageAddrFromCfg cfg (network cfg))
    (i, out) <-
        maybe
            (fail ("no state output after " <> label))
            pure
            (findStateUtxo (cagePolicyIdFromCfg cfg) tid utxos)
    unless (i == firstOutput tx) $
        fail
            ( "the state output after "
                <> label
                <> " is "
                <> show i
                <> ", not the first output of the transaction that made it"
            )
    case extractCageDatum out of
        Just (StateDatum s) ->
            pure (StatePoint tx i (Root (unOnChainRoot (stateRoot s))) label)
        _ ->
            fail ("the state output after " <> label <> " carries no state datum")

book
    :: CageConfig
    -> NamingCodes
    -> Cage.Provider IO
    -> Edges.SubmitSigned
    -> TokenId
    -> ByteString
    -> Edge
    -> (ByteString, ByteString)
    -> IO TxIn
book cfg codes prov submit = Edges.bookEdgeTo cfg codes prov submit genesisAddr

{- | Book @insertActive@ requests on fresh keys until there are at least
three and their booking order differs from their ledger order. Six
bookings in the ledger's order happen once in 720; that fails the setup.
-}
bookUntilOrdersDiffer
    :: CageConfig
    -> NamingCodes
    -> Cage.Provider IO
    -> Edges.SubmitSigned
    -> TokenId
    -> (ByteString, ByteString)
    -> IO [TxIn]
bookUntilOrdersDiffer cfg codes prov submit tid dest = go (1 :: Int) []
  where
    go n acc
        | length acc >= 3 && sort acc /= acc = pure acc
        | n > 6 = fail "ORDER-WITNESS: six bookings landed in ledger order"
        | otherwise = do
            i <-
                book
                    cfg
                    codes
                    prov
                    submit
                    tid
                    ("replay-mixed-" <> BS.singleton (0x30 + fromIntegral n))
                    edgeInsertActive
                    dest
            go (n + 1) (acc <> [i])

{- | Two outputs that look like requests and must take no action in a fold:
one at the wallet whose inline request datum names another registry's
token (the fold spends it), and one at an address nobody spends whose
inline request datum names this registry's token (the fold references it).
-}
makeDecoys
    :: CageConfig
    -> Cage.Provider IO
    -> Edges.SubmitSigned
    -> TokenId
    -> IO ((TxIn, TxOut ConwayEra), (TxIn, TxOut ConwayEra))
makeDecoys cfg prov submit tid = do
    utxos <- Cage.withView prov (`Cage.viewUTxOsAt` genesisAddr)
    fund <-
        case [ u
             | u@(_, o) <- utxos
             , plainAda o
             , o ^. coinTxOutL > Coin 50_000_000
             ] of
            (u : _) -> pure u
            [] -> fail "makeDecoys: no plain wallet output to fund the decoys"
    let AssetName own = unTokenId tid
        other = deriveAssetName (txInToRef (fst fund))
        datumFor tokenName =
            mkInlineDatum
                ( toPlcData
                    ( RequestDatum
                        OnChainRequest
                            { requestToken = OnChainTokenId (BuiltinByteString tokenName)
                            , requestOwner = BuiltinByteString (BS.replicate 28 0x11)
                            , requestKey = "replay-decoy"
                            , requestEdge = edgeInsertActive
                            , requestDeposit = 0
                            , requestSubmittedAt = 0
                            , requestDestination = (BS.empty, BS.empty)
                            }
                    )
                )
        decoy addr tokenName =
            mkBasicTxOut addr (MaryValue (Coin 5_000_000) mempty)
                & datumTxOutL .~ datumFor tokenName
        spentDecoy = decoy genesisAddr other
        referencedDecoy = decoy (lockedAddr cfg) (SBS.fromShort own)
        fee = 1_000_000
        Coin inCoin = snd fund ^. coinTxOutL
        body =
            mkBasicTxBody
                & inputsTxBodyL .~ Set.singleton (fst fund)
                & outputsTxBodyL
                    .~ StrictSeq.fromList
                        [ spentDecoy
                        , referencedDecoy
                        , mkBasicTxOut
                            genesisAddr
                            (MaryValue (Coin (inCoin - fee - 10_000_000)) mempty)
                        ]
                & feeTxBodyL .~ Coin fee
    signed <- submit (mkBasicTx body)
    let tx = txIdTx signed
    when (other == SBS.fromShort own) $
        fail "makeDecoys: the stranger token is this registry's"
    pure
        ((TxIn tx (TxIx 0), spentDecoy), (TxIn tx (TxIx 1), referencedDecoy))
  where
    plainAda o =
        (case o ^. valueTxOutL of MaryValue _ (MultiAsset m) -> Map.null m)
            && o ^. referenceScriptTxOutL == SNothing
            && o ^. datumTxOutL == mempty'
    mempty' = (mkBasicTxOut genesisAddr mempty :: TxOut ConwayEra) ^. datumTxOutL

-- | An address no key here signs for, where the referenced decoy rests.
lockedAddr :: CageConfig -> Addr
lockedAddr cfg = addrFromKeyHashBytes (network cfg) (BS.replicate 28 0xcd)

{- | Split the wallet's largest output into four plain ada outputs and the
rest, which keeps every token the output carried.
-}
splitPlainAda :: Cage.Provider IO -> Edges.SubmitSigned -> IO ()
splitPlainAda prov submit = do
    utxos <- Cage.withView prov (`Cage.viewUTxOsAt` genesisAddr)
    (i, o) <-
        case sortOn
            (Down . (^. coinTxOutL) . snd)
            [u | u@(_, out) <- utxos, out ^. referenceScriptTxOutL == SNothing] of
            u : _ -> pure u
            [] -> fail "splitPlainAda: the wallet is empty"
    let MaryValue (Coin c) assets = o ^. valueTxOutL
        piece = 1_000_000_000
        fee = 1_000_000
        plain = mkBasicTxOut genesisAddr (MaryValue (Coin piece) mempty)
        rest =
            mkBasicTxOut
                genesisAddr
                (MaryValue (Coin (c - 4 * piece - fee)) assets)
        body =
            mkBasicTxBody
                & inputsTxBodyL .~ Set.singleton i
                & outputsTxBodyL .~ StrictSeq.fromList (replicate 4 plain <> [rest])
                & feeTxBodyL .~ Coin fee
    unless (c > 5 * piece) $
        fail
            ("splitPlainAda: the largest wallet output holds only " <> show c)
    _ <- submit (mkBasicTx body)
    pure ()
