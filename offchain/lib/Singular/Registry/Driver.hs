{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

{- |
Module      : Singular.Registry.Driver
Description : Booting a registry and folding its edges, obligations discharged
License     : Apache-2.0

A fold's speculative session starts from the manager's COMMITTED trie and
is discarded ('updateTokenWithDuties'). So a caller that lands a fold and
does not mirror the edge into its manager builds the next proof against a
root the chain no longer has. The library stays correct throughout; the
caller is silently wrong, and the failure surfaces at the NEXT fold, which
looks like a defect somewhere else entirely. That cost three devnet runs
and an escalation on #173.

The obligation lived in a comment, so each new caller could forget it.
This module is where it lives now.

A caller cannot reach a fold except through a 'Registry', and the only way
to obtain one is 'bootRegistry'. 'foldEdge' books the edge, builds the
fold, submits it, mirrors it, and proves on both sides that the manager
and the chain agree:

  * BEFORE building, the manager's root must equal the chain's. A caller
    that landed a fold behind this driver's back is rejected HERE, naming
    both roots, rather than at some later unrelated fold.
  * AFTER mirroring, the two must agree again, and the root must have
    moved. A root that does not move across a landed fold is the #173
    defect, and it would otherwise be invisible.

What this module does NOT do is assert anything about the edge's meaning.
Booting, folding and keeping the mirror in step are its whole subject;
every caller keeps its own assertions and its own output.
-}
module Singular.Registry.Driver (
    -- * The registry handle
    Registry,
    registryConfig,
    registryTokenId,
    registryRefs,
    registryBootTx,

    -- * Booting
    bootRegistry,

    -- * Folding one edge
    foldEdge,
    foldEdgeTo,
    FoldOutcome (..),

    -- * Reading the two roots
    chainRoot,
    mirrorRoot,
    renderRoot,

    -- * Deriving the token a boot minted
    tokenIdOfBootTx,
) where

import Control.Monad (unless, void, when)
import Data.ByteString (ByteString)
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Char8 qualified as BS8
import Data.ByteString.Lazy qualified as BSL
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Lens.Micro ((^.))

import Cardano.Ledger.Api.Tx (bodyTxL, witsTxL)
import Cardano.Ledger.Api.Tx.Body (
    collateralInputsTxBodyL,
    feeTxBodyL,
    mintTxBodyL,
    referenceInputsTxBodyL,
 )
import Cardano.Ledger.Api.Tx.Out (coinTxOutL)
import Cardano.Ledger.Api.Tx.Wits (scriptTxWitsL)
import Cardano.Ledger.Binary (serialize)
import Cardano.Ledger.Core (eraProtVerHigh)
import Cardano.Ledger.Mary.Value (MultiAsset (..))
import Cardano.Tx.Ledger (ConwayTx)

import Singular.Registry.Blueprint (NamingCodes)
import Singular.Registry.Config (CageConfig (..))
import Singular.Registry.Ledger (
    Addr,
    AssetName (..),
    Coin (..),
    ConwayEra,
    Root (..),
    TokenId (..),
    TxIn,
    TxOut,
 )
import Singular.Registry.Provider qualified as Cage
import Singular.Registry.Trie (Trie (..), TrieManager (..))
import Singular.Registry.TxBuilder.Boot (bootTokenImpl)
import Singular.Registry.TxBuilder.Edges (SubmitSigned)
import Singular.Registry.TxBuilder.Edges qualified as Edges
import Singular.Registry.TxBuilder.Internal (
    cageAddrFromCfg,
    cagePolicyIdFromCfg,
    extractCageDatum,
    findStateUtxo,
    walkEdge,
 )
import Singular.Registry.TxBuilder.Update (updateTokenWithDuties)
import Singular.Registry.Types (
    CageDatum (..),
    Edge,
    OnChainRoot (..),
    OnChainTokenState (..),
 )

{- | A booted registry, with everything a fold of its edges needs. The
constructor is deliberately NOT exported: 'bootRegistry' is the only way
to obtain one, so there is no state in which a caller holds the means to
fold and has not been through the boot that publishes the references and
creates the trie.
-}
data Registry = Registry
    { regCfg :: CageConfig
    , regCodes :: NamingCodes
    , regProv :: Cage.Provider IO
    , regSubmit :: SubmitSigned
    , regPayer :: Addr
    , regTm :: TrieManager IO
    , regTid :: TokenId
    , regRefs :: [(TxIn, TxOut ConwayEra)]
    , regBootTx :: ConwayTx
    }

-- | The configuration this registry was booted against.
registryConfig :: Registry -> CageConfig
registryConfig = regCfg

-- | The token the boot minted.
registryTokenId :: Registry -> TokenId
registryTokenId = regTid

{- | The published reference outputs every fold resolves its scripts
through. A caller that books an edge itself needs them.
-}
registryRefs :: Registry -> [(TxIn, TxOut ConwayEra)]
registryRefs = regRefs

-- | The signed boot transaction, for a caller that reports on it.
registryBootTx :: Registry -> ConwayTx
registryBootTx = regBootTx

{- | Boot a registry: mint its token, create its trie, and publish the
cage references every later fold resolves through.

The state validator alone is fifteen kilobytes against a sixteen-kilobyte
transaction cap, so the references are published once here rather than
attached per fold ('Edges.publishCageRefs'). The boot itself resolves
the state validator through a publication already in the payer's
wallet, and is refused `StateValidatorNotPublished` without one.
-}
bootRegistry ::
    CageConfig ->
    NamingCodes ->
    Cage.Provider IO ->
    SubmitSigned ->
    -- | The payer, which is also where boot outputs land
    Addr ->
    TrieManager IO ->
    IO Registry
bootRegistry cfg codes prov submit payer tm = do
    bootWallet <- Cage.queryUTxOs prov payer
    unsignedBoot <- bootTokenImpl cfg prov payer
    let bootScripts = unsignedBoot ^. witsTxL . scriptTxWitsL
        bootRefs = unsignedBoot ^. bodyTxL . referenceInputsTxBodyL
        bootBytes =
            BSL.length (serialize (eraProtVerHigh @ConwayEra) unsignedBoot)
    -- The boot budget, printed rather than taken on trust: the state
    -- validator is fifteen kilobytes against a sixteen-kilobyte cap, so
    -- a reader of a run needs to see the room that is left.
    putStrLn
        ( "[boot] bytes="
            <> show bootBytes
            <> " inline-scripts="
            <> show (Map.size bootScripts)
            <> " reference-inputs="
            <> show (Set.size bootRefs)
            <> " fee="
            <> show (unsignedBoot ^. bodyTxL . feeTxBodyL)
            <> " collateral-coins="
            <> show
                [ c
                | i <- Set.toList (unsignedBoot ^. bodyTxL . collateralInputsTxBodyL)
                , (j, o) <- bootWallet
                , i == j
                , let Coin c = o ^. coinTxOutL
                ]
            <> " wallet-coins="
            <> show [c | (_, o) <- bootWallet, let Coin c = o ^. coinTxOutL]
        )
    signedBoot <- submit unsignedBoot
    tid <- tokenIdOfBootTx cfg signedBoot
    createTrie tm tid
    refs <- Edges.publishCageRefs cfg codes prov submit payer tid
    -- The boot is not booted until the chain holds its state UTxO.
    stateUtxos <- Cage.queryUTxOs prov (cageAddrFromCfg cfg (network cfg))
    when (null stateUtxos) $
        error "bootRegistry: the cage address holds no UTxO after the boot"
    pure
        Registry
            { regCfg = cfg
            , regCodes = codes
            , regProv = prov
            , regSubmit = submit
            , regPayer = payer
            , regTm = tm
            , regTid = tid
            , regRefs = refs
            , regBootTx = signedBoot
            }

{- | What one landed fold did, as the caller's receipt. The two roots are
the evidence that the mirror moved with the chain rather than behind it.
-}
data FoldOutcome = FoldOutcome
    { foKey :: ByteString
    , foEdge :: Edge
    , foBooking :: TxIn
    -- ^ the request this fold consumed
    , foFoldTx :: ConwayTx
    -- ^ the signed fold, on chain
    , foRootBefore :: Root
    -- ^ the committed mirror root before the fold
    , foRootAfter :: Root
    -- ^ the committed mirror root after it, equal to the chain's
    }

{- | Book one edge, fold it, and commit it into the manager before any
later proof is built.

The order is not the caller's to get wrong, and the two root checks are
not the caller's to remember. See the module header for why both exist.
-}
foldEdge :: Registry -> ByteString -> Edge -> IO FoldOutcome
foldEdge reg key edge = foldEdgeWith reg key edge Nothing

{- | Fold one edge whose delivery goes to an explicitly named
destination rather than the one the edge would route to by itself.

The naming application routes an `insertActive` to its own script
address; a harness that has no spending arm there names a wallet
instead. That is the only difference, so it is a parameter here rather
than a second driver.
-}
foldEdgeTo ::
    Registry ->
    ByteString ->
    Edge ->
    -- | destination address and datum, as `Edges.bookEdgeTo` takes them
    (ByteString, ByteString) ->
    IO FoldOutcome
foldEdgeTo reg key edge dest = foldEdgeWith reg key edge (Just dest)

foldEdgeWith ::
    Registry ->
    ByteString ->
    Edge ->
    Maybe (ByteString, ByteString) ->
    IO FoldOutcome
foldEdgeWith reg key edge mDest = do
    rootBefore <- mirrorRoot reg
    onChainBefore <- chainRoot reg
    -- The precondition nobody had. A caller that landed a fold behind
    -- this driver — built, submitted, and did not mirror — is rejected
    -- HERE, before a proof is built against a root the chain no longer
    -- has. Without it the omission is invisible until some later fold
    -- fails for a reason that has nothing to do with it.
    unless (unRoot rootBefore == unOnChainRoot onChainBefore) $
        error
            ( "foldEdge: the manager is out of step with the chain before \
              \folding "
                <> show key
                <> " (mirror "
                <> renderRoot (unRoot rootBefore)
                <> ", chain "
                <> renderRoot (unOnChainRoot onChainBefore)
                <> "): a fold landed without being committed into the \
                   \manager"
            )
    booking <- case mDest of
        Nothing ->
            Edges.bookEdge
                (regCfg reg)
                (regCodes reg)
                (regProv reg)
                (regSubmit reg)
                (regPayer reg)
                (regTid reg)
                key
                edge
        Just dest ->
            Edges.bookEdgeTo
                (regCfg reg)
                (regCodes reg)
                (regProv reg)
                (regSubmit reg)
                (regPayer reg)
                (regTid reg)
                key
                edge
                dest
    ctx <-
        Edges.registryContextFor
            (regCfg reg)
            (regCodes reg)
            (regProv reg)
            (regRefs reg)
    unsigned <-
        updateTokenWithDuties
            (regCfg reg)
            (regProv reg)
            (regTm reg)
            (regTid reg)
            (regPayer reg)
            ctx
    -- Building a fold is not folding it: the edge only lands once the
    -- transaction is on chain, and only then may the mirror move.
    signed <- regSubmit reg unsigned
    withTrie (regTm reg) (regTid reg) $ \t -> void (walkEdge t key edge)
    rootAfter <- mirrorRoot reg
    when (unRoot rootBefore == unRoot rootAfter) $
        error
            ( "foldEdge: the committed mirror root did not move across a \
              \landed fold of "
                <> show key
                <> " — the next fold would re-prove against a stale root"
            )
    onChain <- chainRoot reg
    unless (unRoot rootAfter == unOnChainRoot onChain) $
        error
            ( "foldEdge: after folding "
                <> show key
                <> " the mirror root and the chain root disagree (mirror "
                <> renderRoot (unRoot rootAfter)
                <> ", chain "
                <> renderRoot (unOnChainRoot onChain)
                <> ")"
            )
    pure
        FoldOutcome
            { foKey = key
            , foEdge = edge
            , foBooking = booking
            , foFoldTx = signed
            , foRootBefore = rootBefore
            , foRootAfter = rootAfter
            }

-- | The committed root the manager holds for this registry.
mirrorRoot :: Registry -> IO Root
mirrorRoot reg = withTrie (regTm reg) (regTid reg) getRoot

{- | The root the chain holds, read off the state UTxO at the cage
address.
-}
chainRoot :: Registry -> IO OnChainRoot
chainRoot reg = do
    let cfg = regCfg reg
    utxos <- Cage.queryUTxOs (regProv reg) (cageAddrFromCfg cfg (network cfg))
    case findStateUtxo (cagePolicyIdFromCfg cfg) (regTid reg) utxos of
        Nothing ->
            error "chainRoot: no state UTxO carrying the policy token"
        Just (_, out) -> case extractCageDatum out of
            Just (StateDatum s) -> pure (stateRoot s)
            _ -> error "chainRoot: state UTxO datum is not a StateDatum"

{- | The token a boot transaction minted, read off its own mint field.
Six harnesses each carried a copy of this; it belongs here.
-}
tokenIdOfBootTx :: CageConfig -> ConwayTx -> IO TokenId
tokenIdOfBootTx cfg tx =
    let MultiAsset ma = tx ^. bodyTxL . mintTxBodyL
     in case Map.toList (Map.findWithDefault Map.empty (cagePolicyIdFromCfg cfg) ma) of
            [(AssetName an, _)] -> pure (TokenId (AssetName an))
            assets ->
                error
                    ( "tokenIdOfBootTx: the boot minted "
                        <> show (length assets)
                        <> " assets under the cage policy, not one"
                    )

{- | A root as the driver's diagnostics render it: lowercase hex, no
quoting. A caller that wants to assert on a rejection's text builds the
same string from a root it read itself, so the assertion binds the
values rather than the phrasing.
-}
renderRoot :: ByteString -> String
renderRoot = BS8.unpack . B16.encode
