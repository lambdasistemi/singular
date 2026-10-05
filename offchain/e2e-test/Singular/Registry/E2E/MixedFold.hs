{-# LANGUAGE DataKinds #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.Registry.E2E.MixedFold
Description : A test-only fold that applies some pending requests and rejects the others
License     : Apache-2.0

No library builder makes a fold that mixes applied and rejected requests:
the connected fold applies every pending request and the reject builder
rejects every one. The replay must still follow the chain on such a fold,
so its evidence needs one on chain. This builder exists only for that
evidence; the production builders are unchanged.

It is the update builder's program with three differences, each the
validator's own rule rather than a choice made here:

- the state's @Modify@ actions pair with the pending requests in ledger
  input order, 'Update' for an applied request and 'Rejected' for the
  others (@fold.ak@ pops one action per own-token request);
- the speculative proofs and the new root walk the applied requests only,
  in that order, through 'walkEdge';
- every rejected request's refund is an output right after the state
  continuation, in consumption order (@settlement.refundFault@), before
  the duties the applied requests owe.

It also takes extra plain inputs and extra reference inputs, so the fold
can carry inputs that look like requests and must take no action.
-}
module Singular.Registry.E2E.MixedFold
    ( mixedFold
    ) where

import Control.Monad (forM)
import Data.List (sortOn)
import Data.Map.Strict qualified as Map
import Data.Ord (Down (..))
import Data.Set qualified as Set
import Data.Void (Void)
import Lens.Micro ((&), (.~), (^.))

import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.Alonzo.Scripts (AsIx)
import Cardano.Ledger.Api.Scripts.Data (Datum (NoDatum))
import Cardano.Ledger.Api.Tx (bodyTxL)
import Cardano.Ledger.Api.Tx.Body (feeTxBodyL)
import Cardano.Ledger.Api.Tx.Out
    ( TxOut
    , coinTxOutL
    , datumTxOutL
    , mkBasicTxOut
    , referenceScriptTxOutL
    , valueTxOutL
    )
import Cardano.Ledger.BaseTypes (StrictMaybe (..))
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Conway.Scripts (ConwayPlutusPurpose)
import Cardano.Ledger.Core (hashScript)
import Cardano.Ledger.Mary.Value (MaryValue (..), MultiAsset (..))
import Cardano.Ledger.Plutus.ExUnits (ExUnits)
import Cardano.Tx.Build qualified as Tx
import Cardano.Tx.Ledger (ConwayTx)

import Singular.Registry.Blueprint (NamingCodes)
import Singular.Registry.Config (CageConfig (..))
import Singular.Registry.Ledger
    ( ConwayEra
    , Root (..)
    , SlotNo
    , TokenId
    , TxIn
    )
import Singular.Registry.Provider qualified as Cage
import Singular.Registry.Services qualified as Services
import Singular.Registry.Trie (Trie (..), TrieManager (..))
import Singular.Registry.TxBuilder.ConnectedFold
    ( ConnectedMint (..)
    , ConnectedSpend (..)
    )
import Singular.Registry.TxBuilder.Edges qualified as Edges
import Singular.Registry.TxBuilder.Internal
    ( cageAddrFromCfg
    , cagePolicyIdFromCfg
    , computeRefund
    , currentPosixMs
    , extractCageDatum
    , findRequestUtxos
    , findStateUtxo
    , mkInlineDatum
    , requestAddrFromCfg
    , toPlcData
    , trySync
    , tryUpperSlots
    , txInToRef
    , walkEdge
    )
import Singular.Registry.TxBuilder.Update
    ( RegistryContext (..)
    , RegistryDuties (..)
    , registryDuties
    )
import Singular.Registry.Types
    ( CageDatum (..)
    , OnChainRequest (..)
    , OnChainRoot (..)
    , OnChainTokenState (..)
    , ProofStep
    , RequestAction (..)
    , UpdateRedeemer (..)
    )

-- | The empty query type the program runs under.
data NoCtx a

{- | The unsigned fold of every pending request of the registry: the ones in
the given set applied, the others rejected. The extra inputs are spent as
plain inputs and the extra references are referenced; the fee input is the
wallet's largest ada-only output that carries no datum and is not one of
them.
-}
mixedFold
    :: CageConfig
    -> NamingCodes
    -> Cage.View IO
    -> TrieManager IO
    -> TokenId
    -> Addr
    -- ^ The folder's wallet: fee, collateral, change and burn sources
    -> [(TxIn, TxOut ConwayEra)]
    -- ^ The registry's published reference scripts
    -> Set.Set TxIn
    -- ^ The pending requests this fold applies
    -> [(TxIn, TxOut ConwayEra)]
    -- ^ Extra plain inputs
    -> [(TxIn, TxOut ConwayEra)]
    -- ^ Extra reference inputs
    -> IO ConwayTx
mixedFold cfg codes v tm tid wallet refs applied extraSpends extraRefs = do
    let net = network cfg
        pp = Cage.viewProtocolParams v
    cageUtxos <- Cage.viewUTxOsAt v (cageAddrFromCfg cfg net)
    requestUtxos <- Cage.viewUTxOsAt v (requestAddrFromCfg cfg tid net)
    walletUtxos <- Cage.viewUTxOsAt v wallet
    stateUtxo@(stateIn, stateOut) <-
        maybe
            (fail "mixedFold: no state output")
            pure
            (findStateUtxo (cagePolicyIdFromCfg cfg) tid cageUtxos)
    let reqUtxos = sortOn fst (findRequestUtxos tid requestUtxos)
        processed = [Set.member i applied | (i, _) <- reqUtxos]
        appliedUtxos = [u | (u, True) <- zip reqUtxos processed]
        rejectedUtxos = [u | (u, False) <- zip reqUtxos processed]
        excluded =
            Set.fromList (map fst (extraSpends <> extraRefs <> refs))
    oldState <- case extractCageDatum stateOut of
        Just (StateDatum s) -> pure s
        _ -> fail "mixedFold: the state output carries no state datum"
    requests <- forM appliedUtxos $ \(_, out) -> case extractCageDatum out of
        Just (RequestDatum r) -> pure r
        _ -> fail "mixedFold: an applied request carries no request datum"
    (proofs, Root newRoot) <-
        withSpeculativeTrie tm tid $ \trie -> do
            ps <-
                mapM (\r -> walkEdge trie (requestKey r) (requestEdge r)) requests
            r <- getRoot trie
            pure (ps, r)
    feeUtxo <-
        case sortOn
            (Down . (^. coinTxOutL) . snd)
            [ u
            | u@(i, o) <- walletUtxos
            , plainAda o
            , Set.notMember i excluded
            ] of
            [] -> fail "mixedFold: no plain ada-only output to fund the fold"
            (u : _) -> pure u
    base <- Edges.registryContextFor cfg codes v refs
    let ctx =
            base
                { rcCageUtxos = cageUtxos
                , rcHolderUtxos =
                    [u | u@(i, _) <- walletUtxos, Set.notMember i excluded]
                , rcRefUtxos = refs
                }
    duties <- case registryDuties cfg pp oldState ctx reqUtxos processed of
        Right d -> pure d
        Left err -> fail ("mixedFold: " <> err)
    upperSlot <- upperSlotFor v oldState appliedUtxos
    let stateRef = txInToRef stateIn
        actions =
            pairActions processed proofs
        newStateOut =
            mkBasicTxOut (cageAddrFromCfg cfg net) (stateOut ^. valueTxOutL)
                & datumTxOutL
                    .~ mkInlineDatum
                        ( toPlcData
                            (StateDatum oldState{stateRoot = OnChainRoot newRoot})
                        )
        refunds =
            [ computeRefund pp net (stateMaxFee oldState) out
            | (_, out) <- rejectedUtxos
            ]
        carried =
            [ hashScript s
            | (_, o) <- refs
            , SJust s <- [o ^. referenceScriptTxOutL]
            ]
        prog :: Tx.TxBuild NoCtx Void ()
        prog = do
            _ <- Tx.spendScript stateIn (Modify actions)
            mapM_ (\(i, _) -> Tx.spendScript i (Contribute stateRef)) reqUtxos
            _ <- Tx.output newStateOut
            Coin _ <- Tx.peek $ \tx ->
                let f = tx ^. bodyTxL . feeTxBodyL
                in  if f > Coin 0 then Tx.Ok f else Tx.Iterate f
            mapM_ Tx.output refunds
            mapM_
                (\sp -> Tx.spendScript (fst (csUtxo sp)) (csRedeemer sp))
                (rdSpends duties)
            mapM_ (Tx.spend . fst) (rdInputs duties)
            mapM_ (Tx.spend . fst) extraSpends
            mapM_
                (\m -> Tx.mint (cmPolicy m) (cmAssets m) (cmRedeemer m))
                (rdMints duties)
            mapM_ Tx.output (rdOutputs duties)
            mapM_ Tx.requireSignature (rdSigners duties)
            mapM_ (Tx.reference . fst) (refs <> extraRefs)
            mapM_
                Tx.attachScript
                ( filter
                    ((`notElem` carried) . hashScript)
                    (map csScript (rdSpends duties) <> map cmScript (rdMints duties))
                )
            Tx.collateral (fst feeUtxo)
            Tx.validTo upperSlot
    result <-
        Tx.build
            (Tx.mkPParamsBound pp)
            (Tx.InterpretIO (const (pure undefined)))
            (evaluate v)
            ( feeUtxo
                : stateUtxo
                : reqUtxos
                    <> map csUtxo (rdSpends duties)
                    <> rdInputs duties
                    <> extraSpends
            )
            (refs <> extraRefs)
            wallet
            prog
    either (fail . ("mixedFold: build failed: " <>) . show) pure result
  where
    plainAda o =
        (case o ^. valueTxOutL of MaryValue _ (MultiAsset m) -> Map.null m)
            && o ^. referenceScriptTxOutL == SNothing
            && o ^. datumTxOutL == NoDatum

{- | One action per pending request in ledger order: the next proof for an
applied one, 'Rejected' for the others.
-}
pairActions :: [Bool] -> [[ProofStep]] -> [RequestAction]
pairActions (True : rest) (p : ps) = Update p : pairActions rest ps
pairActions (True : _) [] = error "mixedFold: fewer proofs than applied requests"
pairActions (False : rest) ps = Rejected : pairActions rest ps
pairActions [] _ = []

-- | The validity upper bound: the earliest processing deadline of the applied requests.
upperSlotFor
    :: Cage.View IO
    -> OnChainTokenState
    -> [(TxIn, TxOut ConwayEra)]
    -> IO SlotNo
upperSlotFor v st appliedUtxos = do
    let deadlines =
            [ requestSubmittedAt r + stateProcessTime st
            | (_, out) <- appliedUtxos
            , Just (RequestDatum r) <- [extractCageDatum out]
            ]
    now <- currentPosixMs
    case deadlines of
        [] -> tryUpperSlots v [now + 30_000, now + 5_000]
        ds ->
            trySync (Services.floorSlot v (minimum ds)) >>= \case
                Right s -> pure s
                Left _ -> tryUpperSlots v [now + 30_000, now + 5_000]

-- | Fixed common script evaluation over the view's raw facts.
evaluate
    :: Cage.View IO
    -> ConwayTx
    -> IO
        (Map.Map (ConwayPlutusPurpose AsIx ConwayEra) (Either String ExUnits))
evaluate v tx = Map.map (either (Left . show) Right) <$> Services.evaluateTx v tx
