{-# LANGUAGE DataKinds #-}

{- |
Module      : Singular.Registry.TxBuilder.Internal.Lookup
Description : UTxO lookup, balancing, script integrity and time helpers
License     : Apache-2.0

One owner for where a builder finds its inputs and closes its
transaction: UTxO lookup by input, state and request
('findUtxoByTxIn', 'findStateUtxo', 'findRequestUtxos'), spending-index
computation, script evaluation and balancing ('evaluateAndBalance'),
script-integrity hashing, rejected-row refund outputs
('computeRefund'), and POSIX-time to slot conversion
('currentPosixMs', 'trySlots').

This is the lookup-and-balance owner extracted from
@Singular.Registry.TxBuilder.Internal@; the public module re-exports
it and is its only intended consumer surface.
-}
module Singular.Registry.TxBuilder.Internal.Lookup
    ( -- * UTxO lookup
      findUtxoByTxIn
    , findStateUtxo
    , findRequestUtxos

      -- * Indexing
    , spendingIndex

      -- * Script integrity
    , computeScriptIntegrity

      -- * Evaluate and balance
    , evaluateAndBalance
    , evaluateAndBalanceReferencing
    , placeholderExUnits

      -- * Time and slot helpers
    , currentPosixMs
    , trySlots
    , tryUpperSlots
    , trySync

      -- * Refund computation
    , computeRefund
    ) where

import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.Alonzo.PParams
    ( LangDepView
    , getLanguageView
    )
import Cardano.Ledger.Alonzo.Tx
    ( ScriptIntegrity (..)
    , ScriptIntegrityHash
    , hashScriptIntegrity
    )
import Cardano.Ledger.Alonzo.TxBody
    ( scriptIntegrityHashTxBodyL
    )
import Cardano.Ledger.Alonzo.TxWits
    ( Redeemers (..)
    , TxDats (..)
    )
import Cardano.Ledger.Api.Tx
    ( bodyTxL
    , witsTxL
    )
import Cardano.Ledger.Api.Tx.Body
    ( inputsTxBodyL
    )
import Cardano.Ledger.Api.Tx.Out
    ( TxOut
    , coinTxOutL
    , getMinCoinTxOut
    , mkBasicTxOut
    , valueTxOutL
    )
import Cardano.Ledger.Api.Tx.Wits
    ( rdmrsTxWitsL
    )
import Cardano.Ledger.BaseTypes
    ( Inject (..)
    , Network
    , StrictMaybe (..)
    )
import Cardano.Ledger.Mary.Value
    ( MaryValue (..)
    , MultiAsset (..)
    , PolicyID (..)
    )
import Cardano.Ledger.Plutus.ExUnits (ExUnits (..))
import Cardano.Ledger.Plutus.Language (Language (PlutusV3))
import Cardano.Ledger.TxIn (TxIn)
import Cardano.Slotting.Slot (SlotNo)
import Cardano.Tx.Balance
    ( BalanceResult (..)
    , balanceTx
    )
import Cardano.Tx.Ledger (ConwayTx)
import Control.Exception
    ( SomeAsyncException
    , SomeException
    , fromException
    , throwIO
    , try
    )
import Data.ByteString.Short qualified as SBS
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Time.Clock.POSIX (getPOSIXTime)
import Data.Word (Word32)
import Lens.Micro ((&), (.~), (^.))
import PlutusTx.Builtins.Internal (BuiltinByteString (..))
import Singular.Registry.Ledger
    ( AssetName (..)
    , Coin (..)
    , ConwayEra
    , PParams
    , TokenId (..)
    )
import Singular.Registry.Provider (View (..))
import Singular.Registry.TxBuilder.Internal.Identity
    ( addrFromKeyHashBytes
    , extractCageDatum
    , extractOwnerBytes
    )
import Singular.Registry.Types
    ( CageDatum (..)
    , OnChainRequest (..)
    , OnChainTokenId (..)
    )

{- | Placeholder execution units used in the initial
unbalanced transaction.
-}
placeholderExUnits :: ExUnits
placeholderExUnits = ExUnits 0 0

{- | Evaluate script execution units and balance
a transaction.
-}
evaluateAndBalance
    :: View IO
    -> PParams ConwayEra
    -> [(TxIn, TxOut ConwayEra)]
    -- ^ All input UTxOs (fee + script)
    -> Addr
    -- ^ Change address
    -> ConwayTx
    -- ^ Unbalanced tx with placeholder ExUnits
    -> IO ConwayTx
evaluateAndBalance prov pp inputUtxos =
    evaluateAndBalanceReferencing prov pp inputUtxos []

{- | 'evaluateAndBalance' for a transaction that reads scripts from
reference outputs (#300): the resolved outputs are handed to the balancer,
which charges the ledger's per-byte tier for every reference-script byte the
transaction references, exactly as the node will.
-}
evaluateAndBalanceReferencing
    :: View IO
    -> PParams ConwayEra
    -> [(TxIn, TxOut ConwayEra)]
    -- ^ All input UTxOs (fee + script)
    -> [(TxIn, TxOut ConwayEra)]
    -- ^ The resolved reference outputs
    -> Addr
    -- ^ Change address
    -> ConwayTx
    -- ^ Unbalanced tx with placeholder ExUnits
    -> IO ConwayTx
evaluateAndBalanceReferencing prov pp inputUtxos refUtxos changeAddr tx =
    measure withInputs >>= settle (6 :: Int)
  where
    withInputs =
        tx
            & bodyTxL . inputsTxBodyL
                .~ foldl
                    (\s (tin, _) -> Set.insert tin s)
                    (tx ^. bodyTxL . inputsTxBodyL)
                    inputUtxos

    -- What the node's evaluator says every redeemer costs; a failing script
    -- stops the build, it is never declared.
    measure t = do
        evalResult <- viewEvaluateTx prov t
        case [(p, e) | (p, Left e) <- Map.toList evalResult] of
            [] ->
                pure (Map.fromList [(p, eu) | (p, Right eu) <- Map.toList evalResult])
            failures ->
                error $
                    "evaluateAndBalance: script eval failed: " <> show failures

    -- The transaction with these units declared and its fee and change
    -- balanced for them.
    balanced units =
        let Redeemers declared = tx ^. witsTxL . rdmrsTxWitsL
            newRedeemers =
                Redeemers
                    ( Map.mapWithKey
                        (\purpose (dat, eu) -> (dat, Map.findWithDefault eu purpose units))
                        declared
                    )
            patched =
                tx
                    & witsTxL . rdmrsTxWitsL .~ newRedeemers
                    & bodyTxL . scriptIntegrityHashTxBodyL
                        .~ computeScriptIntegrity pp newRedeemers
        in  case balanceTx pp inputUtxos refUtxos changeAddr patched of
                Left err -> error $ "evaluateAndBalance: " <> show err
                Right br -> balancedTx br

    {- A script reads its own transaction: the fee and the change it is
    balanced to are part of what it is evaluated on, and the fee in turn
    depends on the units declared. The units measured on the body before
    balancing can therefore fall short of what the balanced body needs, and a
    node that re-runs the script refuses a declaration that is a few units too
    small. The balanced body is measured again, and the declaration raised
    and the body balanced again until the body the node will see is one its
    own measurement fits inside. -}
    settle 0 _ =
        error
            "evaluateAndBalance: the declared units did not settle on the balanced body"
    settle n units = do
        let candidate = balanced units
        seen <- measure candidate
        if Map.isSubmapOfBy fits seen units
            then pure candidate
            else settle (n - 1) (Map.unionWith raise units seen)

    fits (ExUnits m s) (ExUnits m' s') = m <= m' && s <= s'
    raise (ExUnits m s) (ExUnits m' s') = ExUnits (max m m') (max s s')

-- | Find a UTxO by its 'TxIn'.
findUtxoByTxIn
    :: TxIn
    -> [(TxIn, TxOut ConwayEra)]
    -> Maybe (TxIn, TxOut ConwayEra)
findUtxoByTxIn needle =
    find' (\(tin, _) -> tin == needle)
  where
    find' _ [] = Nothing
    find' p (x : xs)
        | p x = Just x
        | otherwise = find' p xs

-- | Find the state UTxO for a token.
findStateUtxo
    :: PolicyID
    -> TokenId
    -> [(TxIn, TxOut ConwayEra)]
    -> Maybe (TxIn, TxOut ConwayEra)
findStateUtxo policyId tid = find' isState
  where
    assetName = unTokenId tid
    isState (_, txOut) =
        case txOut ^. valueTxOutL of
            MaryValue _ (MultiAsset ma) ->
                case Map.lookup policyId ma of
                    Just assets ->
                        Map.member assetName assets
                    Nothing -> False
    find' _ [] = Nothing
    find' p (x : xs)
        | p x = Just x
        | otherwise = find' p xs

-- | Find all request UTxOs for a token.
findRequestUtxos
    :: TokenId
    -> [(TxIn, TxOut ConwayEra)]
    -> [(TxIn, TxOut ConwayEra)]
findRequestUtxos tid = filter isRequest
  where
    targetName = unTokenId tid
    isRequest (_, txOut) =
        case extractCageDatum txOut of
            Just (RequestDatum req) ->
                let OnChainRequest
                        { requestToken =
                            OnChainTokenId
                                (BuiltinByteString bs)
                        } = req
                in  AssetName (SBS.toShort bs)
                        == targetName
            _ -> False

-- | Compute the spending index of a 'TxIn'.
spendingIndex :: TxIn -> Set.Set TxIn -> Word32
spendingIndex needle inputs =
    let sorted = Set.toAscList inputs
    in  go 0 sorted
  where
    go _ [] =
        error "spendingIndex: TxIn not in set"
    go n (x : xs)
        | x == needle = n
        | otherwise = go (n + 1) xs

-- | Compute the 'ScriptIntegrityHash'.
computeScriptIntegrity
    :: PParams ConwayEra
    -> Redeemers ConwayEra
    -> StrictMaybe ScriptIntegrityHash
computeScriptIntegrity pp rdmrs =
    let langViews :: Set.Set LangDepView
        langViews =
            Set.singleton
                (getLanguageView pp PlutusV3)
        emptyDats :: TxDats ConwayEra
        emptyDats = TxDats mempty
    in  SJust
            ( hashScriptIntegrity
                (ScriptIntegrity rdmrs emptyDats langViews)
            )

-- | Get current POSIX time in milliseconds.
currentPosixMs :: IO Integer
currentPosixMs = do
    t <- getPOSIXTime
    pure $ floor (t * 1000)

{- | Try converting successive POSIX ms values to
slots, returning the first that succeeds.
-}
trySlots
    :: View IO -> [Integer] -> IO SlotNo
trySlots _ [] =
    error
        "posixMsToSlot: all fallbacks \
        \past horizon"
trySlots p (ms : rest) = do
    r <-
        try @SomeException
            (viewPosixMsCeilSlot p ms)
    case r of
        Right s -> pure s
        Left _ -> trySlots p rest

{- | Compute a rejected row's refund output (NOTE-014 item A2, delegated
routing): exactly `input lovelace − tip`, floored at min-UTxO with the
top-up funded visibly. No fee share is deducted here and none is
invented (fees ride funding inputs; the validator pins per-owner floors
and exact lock accumulation instead of an aggregate envelope). THE shared
helper for every rejected-refund emission — `Reject` and manual paths
call it; processed rows emit no refunds at all (their bond locks).
-}
computeRefund
    :: PParams ConwayEra
    -> Network
    -> Integer
    -> TxOut ConwayEra
    -> TxOut ConwayEra
computeRefund pp net tipAmount reqOut =
    let Coin reqVal = reqOut ^. coinTxOutL
        rawRefund =
            Coin (reqVal - tipAmount)
        refundAddr =
            addrFromKeyHashBytes
                net
                (extractOwnerBytes reqOut)
        draft =
            mkBasicTxOut
                refundAddr
                (inject rawRefund)
        minCoin = getMinCoinTxOut pp draft
    in  mkBasicTxOut
            refundAddr
            (inject (max rawRefund minCoin))

{- | Try converting successive POSIX ms values to slots, rounding down, and
return the first that succeeds: an upper validity bound.

'trySlots' rounds up, which is right for a lower bound but not for an upper
one. A time in the horizon's last slot converts, since the time is inside
the horizon, and rounding up then yields the horizon slot itself, which is
exclusive: the node cannot translate a bound there, and evaluation fails
@TimeTranslationPastHorizon@. Rounding down keeps the bound inside the
horizon whenever the time is.
-}
tryUpperSlots
    :: View IO -> [Integer] -> IO SlotNo
tryUpperSlots _ [] =
    error
        "posixMsToSlot: all fallbacks \
        \past horizon"
tryUpperSlots p (ms : rest) = do
    r <- trySync (viewPosixMsToSlot p ms)
    case r of
        Right s -> pure s
        Left _ -> tryUpperSlots p rest

{- | Run an action, returning its synchronous failure; an asynchronous
exception — a cancellation, a timeout — is rethrown, never taken for a
conversion that failed and so never answered by a fallback.
-}
trySync :: IO a -> IO (Either SomeException a)
trySync action = do
    r <- try action
    case r of
        Left e
            | Just (_ :: SomeAsyncException) <- fromException e -> throwIO e
        _ -> pure r
