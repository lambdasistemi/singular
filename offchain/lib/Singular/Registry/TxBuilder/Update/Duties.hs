{-# LANGUAGE DataKinds #-}
{-# LANGUAGE KindSignatures #-}

{- |
Module      : Singular.Registry.TxBuilder.Update.Duties
Description : Fold duty decisions — what each edge owes
License     : Apache-2.0

The obligations a fold's requests create, computed once, off chain:
what must move under the registry's three token policies, where a
minted token has to land, which custody has to be spent, which holder
input a burn consumes, what returns to the owner, and who has to sign
(the fold: nobody). This is one derivation; the cage computes its own
from the requests it consumes, and the two are deliberately separate.

This module owns no queries and no transaction assembly; see
"Singular.Registry.TxBuilder.Update.Context" and
"Singular.Registry.TxBuilder.Update.Build". The public surface stays
"Singular.Registry.TxBuilder.Update", which re-exports the duties
unchanged (#267).
-}
module Singular.Registry.TxBuilder.Update.Duties
    ( RegistryDuties (..)
    , registryDuties
    ) where

import Data.ByteString.Short qualified as SBS
import Data.Map.Strict qualified as Map
import Lens.Micro ((&), (.~), (^.))
import PlutusCore.Data qualified as PLC

import Cardano.Ledger.Api.Tx.Out
    ( TxOut
    , coinTxOutL
    , datumTxOutL
    , getMinCoinTxOut
    , mkBasicTxOut
    , valueTxOutL
    )
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Core (hashScript)
import Cardano.Ledger.Keys (KeyHash)
import Cardano.Ledger.Mary.Value
    ( AssetName (..)
    , MaryValue (..)
    , MultiAsset (..)
    , PolicyID (..)
    )
import Cardano.Tx.Build (Guard)
import PlutusTx.Builtins.Internal (BuiltinByteString (..))

import Singular.Registry.Config
    ( CageConfig (..)
    )
import Singular.Registry.Ledger
    ( ConwayEra
    , PParams
    , TxIn
    )
import Singular.Registry.TxBuilder.ConnectedFold
    ( ConnectedMint (..)
    , ConnectedSpend (..)
    , RawRedeemer (..)
    )
import Singular.Registry.TxBuilder.Internal.Edges
import Singular.Registry.TxBuilder.Internal.Identity
import Singular.Registry.TxBuilder.Update.Context
    ( HolderRelease (..)
    , RegistryContext (..)
    )
import Singular.Registry.Types
    ( CageDatum (..)
    , OnChainRequest (..)
    , OnChainTokenState (..)
    , UpdateRedeemer (..)
    , edgeDeleteAbsent
    , edgeDeleteActive
    , edgeInsertAbsent
    , edgeUpdateTerminal
    , edgeWitnessTerminal
    )

-- ---------------------------------------------------------
-- Registry-mode obligations (#157 mint-matches-edge-deltas, token-destinations-and-refunds, T1-T6)
-- ---------------------------------------------------------

{- | Everything an edge owes a fold beyond the trie: what must move under
the three token policies, where the minted token has to land, which
custody has to be spent, and who has to sign.

The cage computes these from the requests it consumes (`dutiesOf`,
`dutyOk`); this recomputes them from the same requests so a fold can be
built that discharges them. The two are deliberately separate
derivations — a builder that agrees with the validator by construction
would not catch a disagreement.
-}
data RegistryDuties = RegistryDuties
    { rdMints :: [ConnectedMint]
    , rdOutputs :: [TxOut ConwayEra]
    , rdSpends :: [ConnectedSpend]
    , rdSigners :: [KeyHash Guard]
    , rdInputs :: [(TxIn, TxOut ConwayEra)]
    {- ^ #177 I177-BUILDER: ordinary (non-script) inputs the edge needs
    the transaction to consume. A retirement or a deletion of an
    active key burns an asset it does not create, so the holder UTxO
    carrying that asset has to ride in as an input; a mint of `-1` with nothing to burn is a transaction
    whose only possible outcome is a refusal.
    -}
    }

instance Semigroup RegistryDuties where
    a <> b =
        RegistryDuties
            (rdMints a <> rdMints b)
            (rdOutputs a <> rdOutputs b)
            (rdSpends a <> rdSpends b)
            (rdSigners a <> rdSigners b)
            (rdInputs a <> rdInputs b)

instance Monoid RegistryDuties where
    mempty = RegistryDuties [] [] [] [] []

{- | The obligations this set of requests creates, or the reason they
cannot be met. A fold whose duties cannot be built is a fold that would be
refused on chain; failing here names why, in the builder, where it is
cheap.
-}
registryDuties
    :: CageConfig
    -> PParams ConwayEra
    -> OnChainTokenState
    -> RegistryContext
    -> [(TxIn, TxOut ConwayEra)]
    -> [Bool]
    {- ^ Whether each request is PROCESSED by this fold. A rejected
    request takes no edge: it owes its owner a refund, and the
    approval that certified it was never spent.
    -}
    -> Either String RegistryDuties
registryDuties cfg pp st ctx reqUtxos processed = do
    perRequest <- mconcat <$> mapM one consumed
    returns <- depositReturns (releasesIn perRequest)
    pure (perRequest <> returns)
  where
    -- Unmatched requests are NOT processed: a deficit fold has more
    -- requests than actions, and the tail of it takes no edge.
    consumed = zip reqUtxos (processed <> repeat False)
    net = network cfg
    cageAddr = cageAddrFromCfg cfg net
    tip = stateMaxFee st
    one (_, isProcessed)
        | not isProcessed = Right mempty
    one ((_, reqOut), _) = do
        req <- case extractCageDatum reqOut of
            Just (RequestDatum r) -> Right r
            _ -> Left "registryDuties: a request input carries no request datum"
        let key = requestKey req
            edge = requestEdge req
            dest@(destAddr, _) = requestDestination req
            Coin held = reqOut ^. coinTxOutL
            floorAda = held - tip
        -- #183: the tag IS the edge, so admissibility is a range and
        -- nothing is derived from bytes. A tag outside the table owes
        -- the fold no mint and no destination, because the cage refuses
        -- it `edge-inadmissible` before either is read.
        if edge < edgeInsertAbsent || edge > edgeWitnessTerminal
            then
                if rcAllowInadmissible ctx
                    then
                        -- The cage will refuse this, which is the point:
                        -- a row that exists to watch the refusal needs
                        -- the transaction built, not withheld.
                        approvalReturn req reqOut
                    else
                        Left
                            ( "registryDuties: edge "
                                <> show edge
                                <> " on key "
                                <> show key
                                <> " is not one of the seven admissible edges"
                            )
            else do
                mints <- mintsFor edge key
                rest <- dutiesFor edge key dest destAddr floorAda
                back <-
                    if returnsDeposit edge
                        then pure mempty
                        else approvalReturn req reqOut
                pure (mints <> rest <> back)
    {- An approval is not burned at the fold (approval-asset-binding), so it has to
    land somewhere. It goes back to the owner who booked it, in an output
    of its own: left to the balancer it would settle in the folder's
    change, and the folder's wallet would stop being able to fund a fold
    at all, because collateral must be ada-only. -}
    approvalReturn
        :: OnChainRequest -> TxOut ConwayEra -> Either String RegistryDuties
    approvalReturn req reqOut = do
        let BuiltinByteString owner = requestOwner req
            carried = approvalsOn reqOut
        if Map.null carried
            then pure mempty
            else do
                addr <- case addrFromBytes owner of
                    Just a -> Right a
                    Nothing -> Right (addrFromKeyHashBytes net owner)
                -- The minimum depends on the serialised size, and the coin
                -- field is part of it, so the empty probe understates it.
                -- One more pass at the answer it gives converges.
                let at c = mkBasicTxOut addr (MaryValue (Coin c) (MultiAsset carried))
                    Coin first = getMinCoinTxOut @ConwayEra pp (at 0)
                    Coin settled = getMinCoinTxOut @ConwayEra pp (at first)
                pure mempty{rdOutputs = [at settled]}
    approvalsOn reqOut = case reqOut ^. valueTxOutL of
        MaryValue _ (MultiAsset m) ->
            Map.filterWithKey
                (\p _ -> p == policyIdFromPin (cfgApplicationPolicy cfg))
                m
    mintsFor edge key =
        mconcat
            <$> mapM
                ( \(kind, quantity) -> do
                    script <- case Map.lookup kind (rcWitnessScripts ctx) of
                        Just s -> Right s
                        Nothing ->
                            Left
                                ( "registryDuties: no witness script for kind "
                                    <> show kind
                                )
                    pure
                        mempty
                            { rdMints =
                                [ ConnectedMint
                                    { cmPolicy = PolicyID (hashScript script)
                                    , cmAssets = Map.singleton (AssetName (SBS.toShort key)) quantity
                                    , cmRedeemer = RawRedeemer (PLC.Constr 0 [])
                                    , cmScript = script
                                    }
                                ]
                            }
                )
                (deltaOf edge)
    dutiesFor edge key dest destAddr floorAda
        | edge == 0 = lockCustody key destAddr floorAda
        | edge == 1 = deliver (cfgActivePolicy cfg) key dest floorAda
        | edge == 2 =
            (<>)
                <$> spendCustody key
                <*> deliver (cfgActivePolicy cfg) key dest floorAda
        | edge == 3 = burnSource (cfgActivePolicy cfg) key
        | edge == 4 = spendCustody key
        | edge == 5 = burnSource (cfgActivePolicy cfg) key
        | edge == 6 =
            deliver (cfgTerminalPolicy cfg) key dest floorAda
        | otherwise = Left ("registryDuties: unknown edge " <> show edge)
    -- \| #177 I177-BUILDER, #236: the retirement and the deletion of an
    --    active key burn a token they must first hold. `deltaOf 3` and
    --    `deltaOf 5` are both `[(active, -1)]` with no carrier output, so the
    --    asset the mint destroys has to arrive on an input — the Lean row's
    --    witness input,
    --    the witness input carrying one active token for `r.key`.
    --
    --    Selection is exact in both directions: the policy is THIS registry's
    --    active pin and the name is THIS key, so a holder of another key or
    --    another policy is not a candidate and cannot be swept in. Exactly
    --    one candidate must hold exactly one unit; none, several, or a
    --    different quantity is the state the cage refuses `token-missing`,
    --    and the builder says so here rather than emitting a transaction
    --    whose only possible outcome is that refusal.
    burnSource policy key =
        let policyId = policyIdOf policy
            name = AssetName (SBS.toShort key)
            held out = case out ^. valueTxOutL of
                MaryValue _ (MultiAsset m) ->
                    maybe 0 (Map.findWithDefault 0 name) (Map.lookup policyId m)
            candidates =
                [ (u, q)
                | u@(_, o) <- rcHolderUtxos ctx
                , let q = held o
                , q /= 0
                ]
        in  case candidates of
                -- #299: a holder at an application script is spent with
                -- that application's witness; one at a key is a plain
                -- input, signed by the key that owns it.
                [(u, 1)] -> Right $ case holderRelease u of
                    Just release ->
                        mempty
                            { rdSpends =
                                [ ConnectedSpend
                                    { csUtxo = u
                                    , csRedeemer = RawRedeemer (hrRedeemer release)
                                    , csScript = hrScript release
                                    }
                                ]
                            }
                    Nothing -> mempty{rdInputs = [u]}
                -- A row that exists to watch the CHAIN refuse this edge
                -- needs the transaction built, not withheld: the cage
                -- refuses `key-unknown` or `not-booked` before it ever
                -- reaches the burn, and a builder failure here would
                -- substitute its own reason for the one under test.
                -- Same flag, same reason, as the inadmissible-edge arm.
                _ | rcAllowInadmissible ctx -> Right mempty
                [(_, q)] ->
                    Left
                        ( "registryDuties: the holder of the active witness \
                          \for key "
                            <> show key
                            <> " carries "
                            <> show q
                            <> " of it, not exactly one"
                        )
                [] ->
                    Left
                        ( "registryDuties: no input in hand carries the \
                          \active witness for key "
                            <> show key
                            <> "; an edge that burns it must consume it"
                        )
                _ ->
                    Left
                        ( "registryDuties: more than one input carries the \
                          \active witness for key "
                            <> show key
                            <> "; the burn must name one source"
                        )
    -- token-destinations-and-refunds: the absent token sits at the cage, alone, under a custody datum
    -- naming the address the deposit goes back to. Its sole asset is its key.
    lockCustody key refund floorAda = do
        let value =
                MaryValue
                    (Coin floorAda)
                    ( MultiAsset
                        ( Map.singleton
                            (policyIdOf (cfgAbsentPolicy cfg))
                            (Map.singleton (AssetName (SBS.toShort key)) 1)
                        )
                    )
            out =
                mkBasicTxOut cageAddr value
                    & datumTxOutL .~ mkInlineDatum (toPlcData (AbsentCustody refund))
        requireMinAda "custody" out
        pure mempty{rdOutputs = [out]}
    -- T1/T2: the minted token lands in exactly the output the request
    -- named, carrying the datum the request carries (#419).
    deliver policy key (destAddr, datum) floorAda = do
        addr <- destinationAddr
        let value =
                MaryValue
                    (Coin floorAda)
                    ( MultiAsset
                        ( Map.singleton
                            (policyIdOf policy)
                            (Map.singleton (AssetName (SBS.toShort key)) 1)
                        )
                    )
            out = case datum of
                Nothing -> mkBasicTxOut addr value
                Just d -> mkBasicTxOut addr value & datumTxOutL .~ mkInlineDatum d
        requireMinAda "destination" out
        pure mempty{rdOutputs = [out]}
      where
        destinationAddr = case addrFromBytes destAddr of
            Just a -> Right a
            Nothing ->
                Left
                    ( "registryDuties: the request names an address this \
                      \builder cannot decode: "
                        <> show destAddr
                    )
    -- T4/T5: the custody this edge consumes is spent, and its deposit
    -- goes back to the address it recorded.
    spendCustody key = do
        (utxo, refund, owed) <- findCustody key
        cageScript <- case rcCageScript ctx of
            Just s -> Right s
            Nothing ->
                Left
                    "registryDuties: this edge spends custody, and the \
                    \builder was given no cage script to spend it with"
        let refundAddr = case addrFromBytes refund of
                Just a -> a
                Nothing ->
                    error "registryDuties: custody records an undecodable refund address"
            out = mkBasicTxOut refundAddr (MaryValue (Coin owed) mempty)
        requireMinAda "refund" out
        pure
            mempty
                { rdSpends =
                    [ ConnectedSpend
                        { csUtxo = utxo
                        , csRedeemer = RawRedeemer (toPlcData (Modify []))
                        , csScript = cageScript
                        }
                    ]
                , rdOutputs = [out]
                }
    findCustody key =
        case [ (u, refund, coin)
             | u@(_, o) <- rcCageUtxos ctx
             , Just (AbsentCustody refund) <- [extractCageDatum o]
             , Just (policy, name) <- [custodyAssetOf o]
             , policy == policyIdOf (cfgAbsentPolicy cfg)
             , name == AssetName (SBS.toShort key)
             , let Coin coin = o ^. coinTxOutL
             ] of
            [c] -> Right c
            [] -> Left ("registryDuties: no custody UTxO for key " <> show key)
            _ ->
                Left
                    ("registryDuties: more than one custody UTxO for key " <> show key)
    custodyAssetOf out =
        case out ^. valueTxOutL of
            MaryValue _ (MultiAsset policies) ->
                case [ (policy, name, quantity)
                     | (policy, names) <- Map.toList policies
                     , (name, quantity) <- Map.toList names
                     ] of
                    [(policy, name, 1)] -> Just (policy, name)
                    _ -> Nothing
    requireMinAda what out =
        let Coin minAda = getMinCoinTxOut @ConwayEra pp out
            Coin got = out ^. coinTxOutL
        in  if got >= minAda
                then Right ()
                else
                    Left
                        ( "registryDuties: the "
                            <> what
                            <> " output holds "
                            <> show got
                            <> " lovelace, under the "
                            <> show minAda
                            <> " minimum"
                        )
    policyIdOf = policyIdFromPin
    -- #253: an edge that delivers no token (3, 4, 5) owes the consumed
    -- request's deposit to its owner's key. The cage sums what one fold
    -- owes one key and counts only the outputs paying that key outside the
    -- token carriers, so each owner's deposits go out together, in one
    -- output. The approvals those requests carried (approval-asset-binding: not burned)
    -- ride back in the same output, as a rejected request's refund carries
    -- its approval; an output holding them is never ada-only, so it cannot
    -- be mistaken for a custody refund of the same address and amount.
    returnsDeposit edge =
        edge `elem` [edgeUpdateTerminal, edgeDeleteAbsent, edgeDeleteActive]
    --
    -- #299: an application holder the fold spends releases what its
    -- application owes, to its recipient's key. That is owed in the same
    -- sum, in the same output, as every deposit the fold returns to that
    -- key: one output never pays two floors.
    depositReturns releases = do
        outs <- mapM depositOutput (Map.toList (owedByOwner releases))
        pure mempty{rdOutputs = outs}
    -- A holder is looked up only when some application releases one: a
    -- key-held witness is never keyed into the map.
    holderRelease u
        | Map.null (rcHolderReleases ctx) = Nothing
        | otherwise = Map.lookup (fst u) (rcHolderReleases ctx)
    -- Only a spend under an application's release script can release:
    -- custody spends run the cage script and are never looked up.
    releasesIn duties =
        [ (hrRecipient release, (hrReleased release, Map.empty))
        | spend <- rdSpends duties
        , hashScript (csScript spend) `elem` releaseScripts
        , Just release <-
            [Map.lookup (fst (csUtxo spend)) (rcHolderReleases ctx)]
        ]
    releaseScripts = map (hashScript . hrScript) (Map.elems (rcHolderReleases ctx))
    owedByOwner releases =
        Map.fromListWith
            (\(a, x) (b, y) -> (a + b, Map.unionWith (Map.unionWith (+)) x y))
            $ releases
                <> [ (owner, (held - tip, approvalsOn reqOut))
                   | ((_, reqOut), True) <- consumed
                   , Just (RequestDatum req) <- [extractCageDatum reqOut]
                   , returnsDeposit (requestEdge req)
                   , let BuiltinByteString owner = requestOwner req
                         Coin held = reqOut ^. coinTxOutL
                   ]
    depositOutput (owner, (owed, approvals)) = do
        let out =
                mkBasicTxOut
                    (addrFromKeyHashBytes net owner)
                    (MaryValue (Coin owed) (MultiAsset approvals))
        requireMinAda "deposit" out
        pure out
