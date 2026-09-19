{-# LANGUAGE NumericUnderscores #-}

{- |
Module      : Singular.Registry.TxBuilder.Boot
Description : Boot token minting transaction
License     : Apache-2.0

Builds the minting transaction for a new cage
token. Picks a wallet UTxO as seed for asset-name
derivation, mints +1 token at the cage policy, and
creates a State UTxO with empty root and configured
default parameters.
-}
module Singular.Registry.TxBuilder.Boot (
    bootTokenImpl,
) where

import Data.ByteString.Short qualified as SBS
import Data.Map.Strict qualified as Map
import Data.Sequence.Strict qualified as StrictSeq
import Data.Set qualified as Set
import Lens.Micro ((&), (.~), (^.))

import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.Alonzo.Scripts (AsIx (..))
import Cardano.Ledger.Alonzo.TxBody (
    scriptIntegrityHashTxBodyL,
 )
import Cardano.Ledger.Api.Tx (
    bodyTxL,
    estimateMinFeeTx,
    mkBasicTx,
    witsTxL,
 )
import Cardano.Ledger.Api.Tx.Body (
    collateralInputsTxBodyL,
    collateralReturnTxBodyL,
    feeTxBodyL,
    inputsTxBodyL,
    referenceInputsTxBodyL,
    totalCollateralTxBodyL,
    mintTxBodyL,
    mkBasicTxBody,
    outputsTxBodyL,
 )
import Cardano.Ledger.Api.Tx.Out (
    coinTxOutL,
    datumTxOutL,
    mkBasicTxOut,
    referenceScriptTxOutL,
 )
import Cardano.Ledger.Api.Tx.Wits (
    Redeemers (..),
    rdmrsTxWitsL,
    scriptTxWitsL,
 )
import Cardano.Ledger.BaseTypes (StrictMaybe (..))
import Cardano.Ledger.Conway.Scripts (
    ConwayPlutusPurpose (..),
 )
import Cardano.Ledger.Api.PParams (PParams, ppCollateralPercentageL)
import Cardano.Ledger.BaseTypes (Inject (inject))
import Cardano.Ledger.Core (TxOut, hashScript)
import Cardano.Ledger.Mary.Value (
    MaryValue (..),
    MultiAsset (..),
 )
import Cardano.Ledger.TxIn (TxIn)
import Data.Foldable (toList)
import Data.List (find, sortOn)
import Data.Ord (Down (..))

import Cardano.Tx.Ledger (ConwayTx)
import Singular.Registry.AssetName (deriveAssetName)
import Singular.Registry.Config (
    CageConfig (..),
    bootStateFromCfg,
 )
import Singular.Registry.Ledger (
    AssetName (..),
    Coin (..),
    ConwayEra,
 )
import Singular.Registry.Provider (Provider (..))
import Singular.Registry.TxBuilder.Internal
import Singular.Registry.Types (
    CageDatum (..),
    MintRedeemer (..),
    OnChainRoot (..),
    OnChainTxOutRef,
 )

-- | Locate the wallet UTxO whose on-chain reference matches @cageSeed@.
lookupSeed ::
    OnChainTxOutRef ->
    [(TxIn, TxOut ConwayEra)] ->
    Maybe (TxIn, TxOut ConwayEra)
lookupSeed target =
    find (\(tin, _) -> txInToRef tin == target)

{- | The state validator, published as a reference output at the payer's
own address, if one is already there (#177).

The boot transaction attaches the state validator INLINE, and that
validator is fifteen kilobytes against a sixteen-kilobyte transaction
cap: the whole registry has a few hundred bytes of room, and #177's
retirement guard did not fit in them. Referencing the script instead of
carrying it returns the entire fifteen kilobytes to the budget.

Discovery rather than a new argument, because `bootTokenImpl` has
twenty-five callers and every one of them boots from a wallet the
publisher writes to. A session publishes once — `publishStateRef` — and
every boot after it references. A wallet with no publication still boots
with the script inline, exactly as before, so no caller is broken by
this and none is silently changed either: the two paths differ only in
where the ledger reads the same script from.
-}
lookupStateRef ::
    CageConfig ->
    [(TxIn, TxOut ConwayEra)] ->
    Maybe (TxIn, TxOut ConwayEra)
lookupStateRef cfg =
    find
        ( \(_, out) -> case out ^. referenceScriptTxOutL of
            SJust s -> hashScript s == cfgScriptHash cfg
            SNothing -> False
        )

-- | Build a boot-token minting transaction.
bootTokenImpl ::
    CageConfig ->
    Provider IO ->
    Addr ->
    IO ConwayTx
bootTokenImpl cfg prov addr = do
    pp <- queryProtocolParams prov
    utxos <- queryUTxOs prov addr
    -- The seed UTxO is carried in the mint redeemer. We MUST consume
    -- that exact UTxO -- any other input would fail the validator's
    -- `find_input(inputs, seed)` check. Locate it in the caller's
    -- wallet and use it as the seed input.
    let seedRefOnChain = cageSeed cfg
    seedUtxo <- case lookupSeed seedRefOnChain utxos of
        Just u -> pure u
        Nothing ->
            error
                "bootToken: cfg's cageSeed UTxO is not in the\
                \ caller's wallet — cfg may have been built for\
                \ a different seed than the wallet currently\
                \ holds"
    let (seedRef, _seedOut) = seedUtxo
        -- A shared wallet also holds persistent reference publications.
        -- Extra funding inputs must leave those outputs available to runners.
        -- #177 A-003: the boot references a fifteen-kilobyte script and
        -- pays Conway's size tier for it, so its fee is an order of
        -- magnitude larger than before and its collateral must cover
        -- 150%% of that. Fund from the wallet's LARGEST spendable
        -- output rather than whichever happens to come first.
        rest =
            sortOn
                (Down . (^. coinTxOutL) . snd)
                (filter (\u@(_, out) -> u /= seedUtxo && out ^. referenceScriptTxOutL == SNothing) utxos)
        allInputUtxos = case rest of
            [] -> [seedUtxo]
            (u : _) -> [seedUtxo, u]
        assetNameBs =
            deriveAssetName seedRefOnChain
        assetName =
            AssetName
                (SBS.toShort assetNameBs)
    let policyId =
            cagePolicyIdFromCfg cfg
        mintMA =
            MultiAsset
                $ Map.singleton
                    policyId
                $ Map.singleton
                    assetName
                    1
    -- Ownerless registry (ruling NOTE-028/A-003): the state datum carries
    -- no owner and no stake script. Issue #77 E-001 repair: it carries the
    -- expected representative policy from the cage configuration (honest
    -- applied hash for naming cages, zeros for registry-only cages).
    let stateDatum = StateDatum (bootStateFromCfg cfg (OnChainRoot emptyRoot))
        datumData = toPlcData stateDatum
    let scriptAddr =
            cageAddrFromCfg
                cfg
                (network cfg)
        outValue =
            MaryValue
                (Coin 2_000_000)
                mintMA
        txOut =
            mkBasicTxOut
                scriptAddr
                outValue
                & datumTxOutL
                    .~ mkInlineDatum
                        datumData
    let script = mkCageScript cfg
        scriptHash = hashScript script
        -- #177: reference the published state validator when the wallet
        -- carries one, and fall back to the inline witness when it does
        -- not. Fifteen kilobytes of transaction budget turn on this.
        stateRef = lookupStateRef cfg utxos
        redeemer = Minting seedRefOnChain
        mintPurpose =
            ConwayMinting (AsIx 0)
        redeemers =
            Redeemers $
                Map.singleton
                    mintPurpose
                    ( toLedgerData redeemer
                    , placeholderExUnits
                    )
    let integrity =
            computeScriptIntegrity
                pp
                redeemers
        body =
            mkBasicTxBody
                & inputsTxBodyL
                    .~ Set.singleton
                        seedRef
                & outputsTxBodyL
                    .~ StrictSeq.singleton
                        txOut
                & mintTxBodyL .~ mintMA
                & collateralInputsTxBodyL
                    .~ Set.singleton
                        ( fst $
                            last
                                allInputUtxos
                        )
                & scriptIntegrityHashTxBodyL
                    .~ integrity
                & referenceInputsTxBodyL
                    .~ maybe Set.empty (Set.singleton . fst) stateRef
        tx =
            mkBasicTx body
                & witsTxL . scriptTxWitsL
                    .~ maybe
                        (Map.singleton scriptHash script)
                        (const Map.empty)
                        stateRef
                & witsTxL . rdmrsTxWitsL
                    .~ redeemers
    balanced <-
        evaluateAndBalance
            prov
            pp
            allInputUtxos
            addr
            tx
    -- #177 A-003: the balancer estimates with zero reference-script
    -- bytes, which under-pays a boot that references fifteen kilobytes
    -- of state validator.
    pure
        ( declareCollateral pp allInputUtxos addr
            (payForReferenceScripts pp (SBS.length (cageScriptBytes cfg)) balanced)
        )

{- | Pay for the reference script the boot now resolves through (#177
A-003).

Conway charges a size tier for every byte of script a transaction
REFERENCES, on top of the ordinary fee. The balancer this builder uses
estimates with zero reference-script bytes — a reasonable default for a
transaction that references none — so a boot that references fifteen
kilobytes of state validator under-pays and the ledger refuses it
`FeeTooSmallUTxO`.

The balanced transaction is therefore re-costed against the bytes it
actually references, and the difference is moved out of the change
output into the fee. The change output is the last one, because that is
where the balancer appends it.

Nothing here invents a fee: `estimateMinFeeTx` is the ledger's own
estimator, given the byte count this transaction's own reference inputs
carry.
-}
payForReferenceScripts ::
    PParams ConwayEra ->
    -- | the compiled bytes of the script this boot references
    Int ->
    ConwayTx ->
    ConwayTx
payForReferenceScripts pp stateBytes tx =
    let refBytes =
            if Set.null (tx ^. bodyTxL . referenceInputsTxBodyL)
                then 0
                else stateBytes
        Coin currentFee = tx ^. bodyTxL . feeTxBodyL
        Coin needed = estimateMinFeeTx pp tx 1 0 refBytes
        delta = needed - currentFee
     in if refBytes == 0 || delta <= 0
            then tx
            else
                let outs = toList (tx ^. bodyTxL . outputsTxBodyL)
                 in case reverse outs of
                        [] -> tx
                        (change : earlier) ->
                            let Coin changeCoin = change ^. coinTxOutL
                                changePaid =
                                    change & coinTxOutL .~ Coin (changeCoin - delta)
                             in tx
                                    & bodyTxL . feeTxBodyL .~ Coin needed
                                    & bodyTxL . outputsTxBodyL
                                        .~ StrictSeq.fromList
                                            (reverse (changePaid : earlier))

{- | Declare the collateral this boot actually needs (#177 A-003).

Conway sizes required collateral as a percentage of the FEE, and the
reference-script tier raised this boot's fee by roughly 700 kilolovelace.
The collateral the builder had already committed was sized for the
earlier, smaller fee, so the ledger refused with `InsufficientCollateral`
even though the input backing it holds the wallet's whole balance.

Rather than leave the amount implicit, the transaction now SAYS what it
is putting up: `totalCollateral` at the ledger's own requirement, and a
collateral return carrying the rest of the input back. Both are derived
from the fee this transaction actually pays and the protocol's own
percentage — nothing here is a chosen number.
-}
declareCollateral ::
    PParams ConwayEra ->
    [(TxIn, TxOut ConwayEra)] ->
    Addr ->
    ConwayTx ->
    ConwayTx
declareCollateral pp resolvable changeAddr tx =
    let collateral = tx ^. bodyTxL . collateralInputsTxBodyL
        backing =
            sum
                [ c
                | (i, o) <- resolvable
                , Set.member i collateral
                , let Coin c = o ^. coinTxOutL
                ]
        Coin fee = tx ^. bodyTxL . feeTxBodyL
        percent = toInteger (pp ^. ppCollateralPercentageL)
        required = (fee * percent + 99) `div` 100
        back = backing - required
     in if Set.null collateral || backing <= required
            then tx
            else
                tx
                    & bodyTxL . totalCollateralTxBodyL .~ SJust (Coin required)
                    & bodyTxL . collateralReturnTxBodyL
                        .~ SJust (mkBasicTxOut changeAddr (inject (Coin back)))
