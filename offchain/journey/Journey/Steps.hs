{- |
Module      : Journey.Steps
Description : The journey's positive steps: boot, book, fold, read back
License     : Apache-2.0

Each step executes one chain action or reads one fact back, narrates it,
and fails the run if the observable did not hold:

* 'stepBoot' — mint the state token, register its trie, read the boot
  state datum;
* 'stepRequest' — BOOK the insert: the approval the registry's open
  application (@open.open@, from @REGISTRY_BLUEPRINT@) mints certifies
  which edge this is, for whom and where it delivers, and
  exactly one request output appears at the request address (narrated
  @request@);
* 'stepApply' — FOLD it as the oracle: the update consumes the request
  output and moves the root on chain (narrated @apply@);
* 'stepReadBack' — decode the state datum again and observe the root
  moved from the boot root.

Booking and folding are separate steps with separate narration lines;
between them the scenario proves the key absent.
-}
module Journey.Steps
    ( journeyKey
    , journeyValue
    , stepBoot
    , stepRequest
    , stepApply
    , stepReadBack
    ) where

import Data.ByteString (ByteString)

import Cardano.Ledger.Api.Tx (txIdTx)
import Cardano.Ledger.Api.Tx.Out (TxOut)
import Cardano.Ledger.BaseTypes (Network (..))
import Cardano.Node.Client.Submitter (Submitter (..))
import Cardano.Tx.Ledger (ConwayTx)

import Journey.Chain (extractTokenId, genesisAddr, submitWithGenesis)
import Journey.Narration (emit, failWith, hex, require, textOf)
import Singular.Registry.Blueprint (NamingCodes)
import Singular.Registry.Config (CageConfig (..))
import Singular.Registry.Ledger (ConwayEra, TokenId (..), TxIn)
import Singular.Registry.Provider qualified as Cage
import Singular.Registry.Trie (TrieManager (..))
import Singular.Registry.TxBuilder.Boot (bootTokenImpl)
import Singular.Registry.TxBuilder.Edges qualified as Edges
import Singular.Registry.TxBuilder.Internal
    ( cageAddrFromCfg
    , cagePolicyIdFromCfg
    , extractCageDatum
    , findStateUtxo
    , leafAbsent
    , requestAddrFromCfg
    )
import Singular.Registry.TxBuilder.Update (updateTokenWithDuties)
import Singular.Registry.Types
    ( CageDatum (..)
    , OnChainRoot (..)
    , OnChainTokenState (..)
    , edgeInsertAbsent
    )

{- | The bounded operation the journey applies: an insert of
'journeyKey' with 'journeyValue'.
-}
journeyKey :: ByteString
journeyKey = "hello"

journeyValue :: ByteString
journeyValue = leafAbsent

{- | Boot a cage: mint the state token, register its trie,
observe the state UTxO and read the boot state datum.
-}
stepBoot
    :: CageConfig
    -> Cage.Provider IO
    -> Submitter IO
    -> TrieManager IO
    -> IO (TokenId, OnChainRoot, ConwayTx)
stepBoot cfg prov submit tm = do
    unsigned <- Cage.withView prov (\v -> bootTokenImpl cfg v genesisAddr)
    signed <- submitWithGenesis submit unsigned
    (tid, tidBytes) <- extractTokenId cfg signed
    createTrie tm tid
    stateUtxos <-
        Cage.withView prov (`Cage.viewUTxOsAt` cageAddrFromCfg cfg Testnet)
    require "boot: state UTxO present at the cage address" $
        not (null stateUtxos)
    bootRoot <- case findStateUtxo (cagePolicyIdFromCfg cfg) tid stateUtxos of
        Nothing ->
            failWith
                "boot: no state UTxO carrying the policy token"
        Just (_, out) -> case extractCageDatum out of
            Just (StateDatum s) -> pure (stateRoot s)
            _ ->
                failWith
                    "boot: state UTxO datum is not a StateDatum"
    emit
        "boot"
        ( "booted cage token_id=0x"
            <> hex tidBytes
            <> " tx="
            <> show (txIdTx signed)
            <> " root=0x"
            <> hex (unOnChainRoot bootRoot)
        )
    pure (tid, bootRoot, signed)

{- | Submit an insert request into the cage's request address
and observe it land.
-}
stepRequest
    :: CageConfig
    -> NamingCodes
    -> Cage.Provider IO
    -> Submitter IO
    -> TokenId
    -> IO Int
stepRequest cfg codes prov submit tid = do
    let reqAddr = requestAddrFromCfg cfg tid Testnet
    before <- Cage.withView prov (`Cage.viewUTxOsAt` reqAddr)
    require "request: request address empty before the request" $
        null before
    -- #157 C4, D-APPROVAL: a tree edge is BOOKED, not merely requested.
    -- The approval the registry's open application mints (its code read
    -- from REGISTRY_BLUEPRINT) certifies which edge this is, for whom and
    -- where it delivers; the request carries it to the fold.
    booked <-
        Edges.bookEdge
            cfg
            codes
            prov
            (submitWithGenesis submit)
            genesisAddr
            tid
            journeyKey
            edgeInsertAbsent
    after <- Cage.withView prov (`Cage.viewUTxOsAt` reqAddr)
    require
        "request: request UTxO observed at the request address"
        (length after == 1)
    emit
        "request"
        ( "submitted insert request key="
            <> textOf journeyKey
            <> " value="
            <> hex journeyValue
            <> " booked_at="
            <> show booked
            <> " request_utxos="
            <> show (length after)
        )
    pure (length after)

{- | Apply the request as the oracle: the update consumes the
request UTxO and moves the trie root on chain.
-}
stepApply
    :: CageConfig
    -> NamingCodes
    -> Cage.Provider IO
    -> Submitter IO
    -> TrieManager IO
    -> TokenId
    -> [(TxIn, TxOut ConwayEra)]
    -> Int
    -> IO ConwayTx
stepApply cfg codes prov submit tm tid refs reqCount = do
    unsigned <- Cage.withView prov $ \v -> do
        ctx <- Edges.registryContextFor cfg codes v refs
        updateTokenWithDuties cfg v tm tid genesisAddr ctx
    signed <- submitWithGenesis submit unsigned
    after <-
        Cage.withView
            prov
            (`Cage.viewUTxOsAt` requestAddrFromCfg cfg tid Testnet)
    require "apply: the request UTxO was consumed" $
        length after < reqCount
    emit
        "apply"
        ( "oracle applied the request tx="
            <> show (txIdTx signed)
            <> " request_utxos "
            <> show reqCount
            <> "->"
            <> show (length after)
        )
    pure signed

{- | Read the resulting state back from the chain: decode the
state UTxO's inline datum and observe that the trie root
moved from the boot root. Returns the authenticated state
as read, for the negative section's unchanged control.
-}
stepReadBack
    :: CageConfig
    -> Cage.Provider IO
    -> TokenId
    -> OnChainRoot
    -> IO OnChainTokenState
stepReadBack cfg prov tid bootRoot = do
    stateUtxos <-
        Cage.withView prov (`Cage.viewUTxOsAt` cageAddrFromCfg cfg Testnet)
    st <- case findStateUtxo (cagePolicyIdFromCfg cfg) tid stateUtxos of
        Nothing ->
            failWith "read-back: no state UTxO carrying the policy token"
        Just (_, out) -> case extractCageDatum out of
            Just (StateDatum s) -> pure s
            _ ->
                failWith
                    "read-back: state UTxO datum is not a StateDatum"
    require
        "read-back: trie root moved from the boot root"
        (stateRoot st /= bootRoot)
    emit
        "read-back"
        ( "state read back root 0x"
            <> hex (unOnChainRoot bootRoot)
            <> " -> 0x"
            <> hex (unOnChainRoot (stateRoot st))
            <> " max_fee="
            <> show (stateMaxFee st)
            <> " process_window_ms="
            <> show (stateProcessTime st)
            <> " retract_window_ms="
            <> show (stateRetractTime st)
        )
    pure st
