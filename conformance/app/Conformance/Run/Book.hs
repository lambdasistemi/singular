{-# LANGUAGE LambdaCase #-}

{- |
Module      : Conformance.Run.Book
Description : Split out of Conformance.Run (#263); see that module's header
License     : Apache-2.0
-}
module Conformance.Run.Book
    ( rowRequestInsert
    , speculativeInsert
    , speculativeApplyAll
    , keyProof
    , speculativeStep
    , rowCommit
    , pendingRequests
    , bookEdge
    , edgeDestination
    , edgeDestinationFor
    , edgeReferences
    ) where

import Conformance.Run.Cage
import Conformance.Run.Control
import Conformance.Run.Environment
import Conformance.Run.Observe
import Conformance.Run.Submit

import Control.Monad (unless, void)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.List (sortOn)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Ord (Down (..))
import Data.Sequence.Strict qualified as StrictSeq
import Data.Set qualified as Set
import Data.Text qualified as T
import Lens.Micro ((&), (.~), (^.))

import Cardano.Ledger.Address
    ( Addr (..)
    , serialiseAddr
    )

import Cardano.Ledger.Api.Tx
    ( mkBasicTx
    , mkBasicTxBody
    , txIdTx
    )
import Cardano.Ledger.Api.Tx.Body
    ( feeTxBodyL
    , inputsTxBodyL
    , outputsTxBodyL
    , referenceInputsTxBodyL
    , reqSignerHashesTxBodyL
    )
import Cardano.Ledger.Api.Tx.Out
    ( coinTxOutL
    , datumTxOutL
    , getMinCoinTxOut
    , mkBasicTxOut
    , valueTxOutL
    )
import Cardano.Ledger.BaseTypes (TxIx (..))
import Cardano.Ledger.Credential
    ( Credential (..)
    , StakeReference (..)
    )
import Cardano.Ledger.Mary.Value (MaryValue (..))
import Cardano.Ledger.TxIn (TxIn (..))

import Cardano.Node.Client.E2E.Setup
    ( Ed25519DSIGN
    , SignKeyDSIGN
    )
import Singular.Registry.Blueprint (NamingCodes (..))
import Singular.Registry.Config (CageConfig (..))
import Singular.Registry.Ledger
    ( Coin (..)
    , ConwayEra
    , PolicyID (..)
    , Root (..)
    , TokenId (..)
    , TxOut
    )
import Singular.Registry.LedgerProvider (SubmitResult (..))
import Singular.Registry.SessionIO qualified as Cage
import Singular.Registry.Signing (signTx, signedTx)
import Singular.Registry.Trie (TrieManager (..))
import Singular.Registry.Trie qualified as CageTrie
import Singular.Registry.TxBuilder.Edges qualified as RegistryEdges
import Singular.Registry.TxBuilder.Internal
    ( addrKeyHashBytes
    , addrWitnessKeyHash
    , approvalName
    , computeScriptHash
    , currentPosixMs
    , extractCageDatum
    , findRequestUtxos
    , mkInlineDatum
    , mkRequestDatumWith
    , policyIdFromPin
    , requestAddrFromCfg
    , scriptHashBytes
    , walkEdge
    )
import Singular.Registry.Types
    ( CageDatum (..)
    , Edge
    , OnChainRequest (..)
    , ProofStep (..)
    , edgeInsertAbsent
    , edgeInsertActive
    , edgeWitnessTerminal
    )

import Conformance.Mirror
    ( emit
    , failWith
    , hex
    , require
    )

{- | Book one absence on a row cage's registry (#157 A-009, D-001).

The issue-70 rows used to create a bare request: no destination, no
approval, and a value the leaf codec does not admit. A request like that is
not a registry-mode booking at all, and a fold of it could only ever be
refused. Every row request is now the insertAbsent edge — the one edge that
needs no signature, because anyone may witness that a name is free — with
the deposit's refund address as its destination and the approval that
certifies it riding along.

The key is the row's own; the value is the absent leaf, because that is
what an absence witness says.
-}
rowRequestInsert
    :: Env
    -> RowCage
    -> ByteString
    -> ByteString
    -> IO (TxIn, TxOut ConwayEra)
rowRequestInsert env cage key _val = do
    let cfg = rcCfg cage
    tid <- cageTid cage
    dest <- edgeDestination env edgeInsertAbsent
    (reqIn, reqOut) <-
        bookEdge
            env
            cfg
            tid
            genesisAddr
            genesisSignKey
            key
            edgeInsertAbsent
            dest
            []
            (defaultTipCoin cfg + cgDeposit)
    pure (reqIn, reqOut)

-- | Speculatively apply one request's insert; proof steps + new root.
speculativeInsert
    :: Env
    -> RowCage
    -> TokenId
    -> ByteString
    -> ByteString
    -> IO ([ProofStep], Root)
speculativeInsert env _cage tid key val =
    withSpeculativeTrie (envTm env) tid $ \trie -> do
        _ <- CageTrie.insert trie key val
        steps <- fromMaybe [] <$> CageTrie.getProofSteps trie key
        r <- CageTrie.getRoot trie
        pure (steps, r)

{- | Speculatively apply every request's own op (read from its
datum), keeping proof steps aligned with the request order given.
-}
speculativeApplyAll
    :: Env
    -> RowCage
    -> TokenId
    -> [(TxIn, TxOut ConwayEra)]
    -> IO ([[ProofStep]], Root)
speculativeApplyAll env _cage tid reqs =
    withSpeculativeTrie (envTm env) tid $ \trie -> do
        ps <- mapM (applyOne trie) reqs
        r <- CageTrie.getRoot trie
        pure (ps, r)
  where
    applyOne trie (_, out) =
        -- #183: the edge names the move and its leaf bytes, from the
        -- table the cage reads (#157 read-preserves-intermediate-root: a read proves its key and
        -- leaves it alone).
        speculativeStep trie key edge
      where
        (key, edge) = case extractCageDatum out of
            Just (RequestDatum rq) ->
                (requestKey rq, requestEdge rq)
            _ -> error "speculative: pending UTxO has no request datum"

{- | One request's step of a speculative fold: its proof, and the trie moved
as the edge moves it.
-}
speculativeStep
    :: (Monad m) => CageTrie.Trie m -> ByteString -> Edge -> m [ProofStep]
speculativeStep trie key edge
    | edge == edgeInsertAbsent || edge == edgeInsertActive =
        walkEdge trie key edge
    | otherwise =
        CageTrie.lookup trie key >>= \case
            Just _ -> walkEdge trie key edge
            -- A key the trie does not hold: the edge cannot move it, and the
            -- script can only refuse it against an exclusion proof.
            Nothing -> keyProof trie key

{- | The proof a fold carries for one key on the trie as it stands: the
key's inclusion proof when the trie holds it, else the exclusion proof —
the steps an insertion of that key carries, which is what the state script
checks a key's absence against (@mpf.miss@). The key is inserted to read
those steps and deleted again, so the trie is left as it was.
-}
keyProof
    :: (Monad m) => CageTrie.Trie m -> ByteString -> m [ProofStep]
keyProof trie key =
    CageTrie.getProofSteps trie key >>= \case
        Just inclusion -> pure inclusion
        Nothing -> do
            exclusion <- walkEdge trie key edgeInsertAbsent
            _ <- CageTrie.delete trie key
            pure exclusion

{- | Commit a landed edge to a row cage's trie (#157 read-preserves-intermediate-root: a read
commits nothing, which `walkEdge` already knows).
-}
rowCommit :: Env -> RowCage -> ByteString -> Edge -> IO ()
rowCommit env cage key edge = do
    tid <- cageTid cage
    withTrie (envTm env) tid $ \t -> void (walkEdge t key edge)

-- | Every pending request UTxO of a row cage, in tx-input order.
pendingRequests :: Env -> RowCage -> IO [(TxIn, TxOut ConwayEra)]
pendingRequests env cage = do
    tid <- cageTid cage
    let cfg = rcCfg cage
    reqUtxos <-
        Cage.withLatest
            (envProv env)
            (`Cage.outputsAt` requestAddrFromCfg cfg tid (network cfg))
    pure (sortOn fst (findRequestUtxos tid reqUtxos))

{- | Book one registry-mode edge (#157 seven-admitted-edges, tree-edge-admission-by-approval, request-destination-binding): create the request
and, for a tree edge, mint the approval that certifies it under the
registry's pinned application policy. A Terminal read carries none (#240).

Which edges carry an approval, what it is and how the booking transaction
carries it are the library's decision, 'RegistryEdges.bookingApproval' and
'RegistryEdges.certifyBooking'; this booking constructs none of its own.
The approval's asset name IS the binding — the edge index, the key, the
owner and the destination, hashed together — and the cage recomputes it
from the request at fold time. A booking and a fold therefore cannot
disagree about what was certified: a drift makes the honest fold refuse
with `approval-binding` rather than pass quietly.

Which signature or reference the naming application demands is the edge's
own business (naming-approval-rules): an absence witness needs none, an activation needs
the controller, and a deletion needs the custody's refund address and the
custody itself in view.
-}
bookEdge
    :: Env
    -> CageConfig
    -> TokenId
    -> Addr
    -> SignKeyDSIGN Ed25519DSIGN
    -> ByteString
    -- ^ Registry key
    -> Edge
    -> (ByteString, ByteString)
    -- ^ Destination: address bytes and datum hash
    -> [(TxIn, TxOut ConwayEra)]
    -- ^ Reference inputs the certifying arm reads (custody, for a deletion)
    -> Integer
    -- ^ Bond: the tip plus the deposit that rides to the destination
    -> IO (TxIn, TxOut ConwayEra)
bookEdge env cfg tid payerAddr payerSk key edge dest refIns bond = do
    let (_, _, codes) = envCodes env
        prov = envProv env
    -- #183: the tag IS the edge. A row that books one outside the table
    -- is booking something the cage refuses `edge-inadmissible`, which
    -- no row here asks for, so it is caught at the booking.
    unless (edge >= edgeInsertAbsent && edge <= edgeWitnessTerminal) $
        failWith
            ( "bookEdge: edge "
                <> show edge
                <> " on key "
                <> show key
                <> " is not one of the seven admissible edges"
            )
    -- One transaction, one view: parameters and the payer's outputs.
    (pp, utxos) <- Cage.withLatest prov $ \v ->
        (,) <$> Cage.parameters v <*> Cage.outputsAt v payerAddr
    (feeIn, feeOut) <- case sortOn (Down . (^. coinTxOutL) . snd) utxos of
        [] -> failWith "bookEdge: payer wallet has no UTxOs"
        (u : _) -> pure u
    -- A spent approval is not burned at the fold, so it comes back to the
    -- funder and rides in the wallet from then on. The booking carries
    -- whatever its input holds through to its own change, and collateral,
    -- spent only when an approval is minted, is taken from an ada-only
    -- output, which is all the ledger accepts.
    collateralIn <- case sortOn
        (Down . (^. coinTxOutL) . snd)
        (filter (adaOnlyOut . snd) utxos) of
        [] ->
            failWith
                "bookEdge: payer wallet has no ada-only output for collateral"
        ((i, _) : _) -> pure i
    now <- currentPosixMs
    let MaryValue (Coin feeBal) carried = feeOut ^. valueTxOutL
        Coin tipVal = defaultTip cfg
        -- A tree-edge booking runs the application's mint arm, and the
        -- fee it owes scales with the budget declared for it.
        fee = 2_000_000
        change = feeBal - bond - fee
        owner = addrKeyHashBytes payerAddr
        approval = RegistryEdges.bookingApproval codes edge key owner dest
        requestAddr = requestAddrFromCfg cfg tid (network cfg)
        -- #183: the datum binds the DEPOSIT, not the tip. The output
        -- holds `bond` = tip + deposit and the fold checks
        -- `deposit == held - tip`; the min-ADA check below is what
        -- keeps the two equal, because a bond raised to meet min-ADA
        -- would break the equality silently.
        datum = mkRequestDatumWith tid payerAddr key edge (bond - tipVal) now dest
        reqOut =
            mkBasicTxOut
                requestAddr
                (MaryValue (Coin bond) (maybe mempty RegistryEdges.baAsset approval))
                & datumTxOutL .~ mkInlineDatum datum
        Coin minAda = getMinCoinTxOut @ConwayEra pp reqOut
    require
        ("bookEdge: payer wallet too small (" <> show feeBal <> ")")
        (change > 0)
    require
        ("bookEdge: bond under min-ADA: " <> show bond)
        (bond >= minAda)
    let body =
            mkBasicTxBody
                & inputsTxBodyL .~ Set.singleton feeIn
                & referenceInputsTxBodyL .~ Set.fromList (map fst refIns)
                & outputsTxBodyL
                    .~ StrictSeq.fromList
                        [ reqOut
                        , mkBasicTxOut payerAddr (MaryValue (Coin change) carried)
                        ]
                & feeTxBodyL .~ Coin fee
                & reqSignerHashesTxBodyL
                    .~ Set.singleton (addrWitnessKeyHash owner)
        unsigned =
            RegistryEdges.certifyBooking pp collateralIn approval (mkBasicTx body)
        signedWitnessed = signTx payerSk unsigned
        signed = signedTx signedWitnessed
    result <- submitTxResilient (envSubmit env) signedWitnessed
    case result of
        SubmitAccepted _ -> confirmTx env signed
        SubmitRefused reason ->
            failWith
                ( "bookEdge refused (edge "
                    <> show edge
                    <> ", key "
                    <> show key
                    <> "): "
                    <> T.unpack reason
                )
        unavailable -> failWith ("submission unavailable: " <> show unavailable)
    emit
        "booked"
        ( "edge "
            <> show edge
            <> " on key "
            <> show key
            <> maybe
                " with no approval"
                ( const
                    (" certified by approval 0x" <> hex (approvalName edge key owner dest))
                )
                approval
        )
    pure (TxIn (txIdTx signed) (TxIx 0), reqOut)

{- | Where an edge delivers (#157 request-destination-binding, naming-approval-rules).

An absence names the address its deposit comes back to, and no datum. An
activation names the naming application's own address and the record datum
it will carry — that is what `record_destination` demands of it. A deletion
and a termination name nothing at all.
-}
edgeDestination :: Env -> Edge -> IO (ByteString, ByteString)
edgeDestination env = edgeDestinationFor env genesisAddr

{- | `edgeDestination` for a named payer: an absence binds the address its
deposit comes back to, and that is the payer's own.
-}
edgeDestinationFor
    :: Env -> Addr -> Edge -> IO (ByteString, ByteString)
edgeDestinationFor env payerAddr edge = do
    let (_, _, codes) = envCodes env
        appHash = computeScriptHash (ncApplication codes)
        appAddr = Addr (network (envCfg env)) (ScriptHashObj appHash) StakeRefNull
    pure $ case edge of
        0 -> (serialiseAddr payerAddr, BS.empty)
        1 -> (serialiseAddr appAddr, recordDatumHash)
        2 -> (serialiseAddr appAddr, recordDatumHash)
        6 -> (serialiseAddr payerAddr, BS.empty)
        _ -> (BS.empty, BS.empty)

{- | What the certifying arm needs to read. A deletion is authorised by the
custody's own refund address, which naming reads from the custody UTxO as a
reference input.
-}
edgeReferences
    :: Env -> ByteString -> Edge -> IO [(TxIn, TxOut ConwayEra)]
edgeReferences env key edge = case edge of
    4 -> do
        utxos <- cageUtxos env
        let absentPolicy =
                scriptHashBytes
                    (policyID (policyIdFromPin (cfgAbsentPolicy (envCfg env))))
        case [ u
             | u@(_, o) <- utxos
             , outAssets o == Map.singleton absentPolicy (Map.singleton key 1)
             , Just (AbsentCustody _) <- [extractCageDatum o]
             ] of
            [u] -> pure [u]
            _ ->
                failWith
                    ("edgeReferences: no single custody UTxO for key " <> show key)
    _ -> pure []
