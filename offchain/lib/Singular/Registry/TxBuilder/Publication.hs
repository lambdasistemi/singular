{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.Registry.TxBuilder.Publication
Description : Registry funding, publication and configuration identity
License     : Apache-2.0

Funding selection, reference-script publication and configuration identity
for the registry commands. The publication arithmetic is shared with the
command preview; every input and amount is derived from the supplied view.
-}
module Singular.Registry.TxBuilder.Publication
    ( -- * Submission
      SubmitSigned

      -- * Derived identity
    , registryIdOf
    , witnessScriptOf
    , applicationPins

      -- * Reference outputs
    , publishRefScript
    , publishRefScriptReserving
    , publishRefScriptTx
    , PublicationFundingError (..)
    , selectPublicationInputs
    , firstPublicationChange
    , publicationFee
    , publicationMinChange
    , publicationRefCoin
    , publishStateRef
    , publishStateRefReserving
    , stateRefIn
    , adaOnlyOut
    , selectFunding
    ) where

import Data.ByteString (ByteString)
import Data.ByteString.Short qualified as SBS
import Data.List (sortOn)
import Data.Map.Strict qualified as Map
import Data.Ord (Down (..))
import Data.Sequence.Strict qualified as StrictSeq
import Data.Set qualified as Set
import Lens.Micro ((&), (.~), (^.))

import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.Api.PParams (ppCoinsPerUTxOByteL, ppMaxTxSizeL)
import Cardano.Ledger.Api.Tx (mkBasicTx, txIdTx)
import Cardano.Ledger.Api.Tx.Body
    ( feeTxBodyL
    , inputsTxBodyL
    , mkBasicTxBody
    , outputsTxBodyL
    )
import Cardano.Ledger.Api.Tx.Out
    ( TxOut
    , coinTxOutL
    , getMinCoinTxOut
    , mkBasicTxOut
    , referenceScriptTxOutL
    , valueTxOutL
    )
import Cardano.Ledger.BaseTypes (StrictMaybe (..), TxIx (..))
import Cardano.Ledger.Coin (CoinPerByte (..))
import Cardano.Ledger.Compactible (fromCompact)
import Cardano.Ledger.Core (PParams, Script, hashScript)
import Cardano.Ledger.Mary.Value (MaryValue (..), MultiAsset (..))
import Cardano.Ledger.TxIn (TxIn (..))
import Cardano.Tx.Ledger (ConwayTx)
import PlutusCore.Data qualified as PLC
import Singular.Registry.AssetName (deriveAssetName)
import Singular.Registry.Blueprint.Load (ApplicationCodes (..))
import Singular.Registry.Blueprint.Params
    ( applyBytesParam
    , applyDataParam
    )
import Singular.Registry.Config (CageConfig (..))
import Singular.Registry.Evidence qualified as Cage
import Singular.Registry.Ledger (Coin (..), ConwayEra)
import Singular.Registry.LedgerProvider qualified as Cage
import Singular.Registry.SessionIO qualified as Cage
import Singular.Registry.TxBuilder.Internal.Identity
    ( computeScriptHash
    , mkCageScript
    , scriptFromBytes
    , scriptHashBytes
    )

{- | Sign a built transaction with the payer's key, submit it, and wait
for it. The caller owns its own signing key and its own confirmation
discipline, so it supplies this rather than the module guessing either.
-}
type SubmitSigned = ConwayTx -> IO ConwayTx

{- | The registry id a witness policy is parameterized by: the state
policy plus the token name this cage's seed determined.
-}
registryIdOf :: CageConfig -> ByteString
registryIdOf cfg =
    scriptHashBytes (cfgScriptHash cfg) <> deriveAssetName (cageSeed cfg)

-- | The witness policy script of one token kind.
witnessScriptOf
    :: CageConfig -> ApplicationCodes -> Integer -> Script ConwayEra
witnessScriptOf cfg codes kind =
    scriptFromBytes
        ("witness-" <> show kind)
        ( applyBytesParam
            (registryIdOf cfg)
            (applyDataParam (PLC.I kind) (ncWitness codes))
        )

{- | The two pins a registry identity carries (#157 genesis-policy-pins), derived
from the supplied application and token-policy code: the application validator
for the approval, and @witness(1, registry)@ for the active token.

The registry id the witness policies are parameterized by depends on the
state script hash and the boot seed, so this takes them directly rather
than a configuration that does not exist yet.
-}
applicationPins
    :: ApplicationCodes
    -> ByteString
    -- ^ The registry id: state script hash then boot token name
    -> (SBS.ShortByteString, SBS.ShortByteString)
    -- ^ Application, active
applicationPins codes registryId =
    ( pinOf (ncApplication codes)
    , witnessPin 1
    )
  where
    pinOf = SBS.toShort . scriptHashBytes . computeScriptHash
    witnessPin kind =
        pinOf
            ( applyBytesParam
                registryId
                (applyDataParam (PLC.I kind) (ncWitness codes))
            )

{- | Can this output fund a transaction? It must hold ada and nothing
else, because it doubles as collateral, and it must not be one of the
published reference outputs, because a transaction may not both spend an
output and reference it.
-}
adaOnlyOut :: TxOut ConwayEra -> Bool
adaOnlyOut out =
    (case out ^. valueTxOutL of MaryValue _ (MultiAsset m) -> Map.null m)
        && ( case out ^. referenceScriptTxOutL of
                SNothing -> True
                SJust _ -> False
           )

{- | The wallet output a transaction is funded and collateralised from: the
one the caller chose, which must be an ada-only output of the wallet, or else
the largest ada-only output. A caller that chose none still gets the output
least likely to leave the change under its minimum.
-}
selectFunding
    :: Maybe TxIn
    -> [(TxIn, TxOut ConwayEra)]
    -> Either String (TxIn, TxOut ConwayEra)
selectFunding chosen utxos = case chosen of
    Nothing -> case sortOn (Down . (^. coinTxOutL) . snd) usable of
        [] -> Left "the payer wallet has no ada-only output"
        (u : _) -> Right u
    Just wanted -> case [u | u@(i, _) <- usable, i == wanted] of
        (u : _) -> Right u
        [] ->
            Left
                "the chosen funding output is not an ada-only output of the payer"
  where
    usable = filter (adaOnlyOut . snd) utxos

{- | The flat fee a publication pays, and the change it must leave strictly
above. One owner (#406): the builder and the whole-run judgement share
these with the pure selection below, never a second copy.
-}
publicationFee :: Integer
publicationFee = 1_000_000

publicationMinChange :: Integer
publicationMinChange = 1_000_000

{- | The reference output a publication creates at the payer's address:
the ledger minimum for the script plus one million lovelace. One owner:
both the selection and the whole-run need share it.
-}
publicationRefCoin
    :: PParams ConwayEra -> Addr -> Script ConwayEra -> Integer
publicationRefCoin pp payerAddr script =
    let probe =
            mkBasicTxOut payerAddr (MaryValue (Coin 0) mempty)
                & referenceScriptTxOutL .~ SJust script
        Coin minCoin = getMinCoinTxOut pp probe
    in  minCoin + 1_000_000

{- | Why one publication cannot be funded: too little in total, or a
covering prefix too large for the protocol maximum transaction size.
-}
data PublicationFundingError
    = PublicationShortfall
        { pfeNeeded :: Integer
        , pfeHeld :: Integer
        , pfeLargest :: Integer
        }
    | PublicationOversize
        { pfeSize :: Integer
        , pfeLimit :: Integer
        }
    deriving stock (Eq, Show)

{- | One owner of the publication arithmetic (#406): the shortest
largest-first prefix of the permitted outputs whose total covers the
reference output plus the fee plus a change strictly above the minimum,
with the inputs, the reference output and the change; or the shortfall
it names (needed total, held total, largest output). A covering prefix
whose transaction would exceed the protocol maximum size is refused up
front, naming size and limit, so a wallet of many dust outputs never
reaches submission.

The permitted outputs are ada-only with no reference script, the seed
withheld before the boot. A covering output spends exactly one input
and it is the largest; otherwise no output that is not needed is spent.
-}
selectPublicationInputs
    :: PParams ConwayEra
    -> Addr
    -> Script ConwayEra
    -> [(k, TxOut ConwayEra)]
    -> Either
        PublicationFundingError
        ([(k, TxOut ConwayEra)], TxOut ConwayEra, Integer)
selectPublicationInputs pp payerAddr script permitted = do
    let ordered = sortOn (Down . (^. coinTxOutL) . snd) permitted
        coins = [c | (_, o) <- ordered, let Coin c = o ^. coinTxOutL]
        held = sum coins
        largest = case coins of
            [] -> 0
            (c : _) -> c
        refCoin = publicationRefCoin pp payerAddr script
        needed = refCoin + publicationFee + publicationMinChange
        refOut =
            mkBasicTxOut payerAddr (MaryValue (Coin refCoin) mempty)
                & referenceScriptTxOutL .~ SJust script
        covering = takeCovering needed ordered 0
    prefix <- case covering of
        Nothing -> Left (PublicationShortfall needed held largest)
        Just chosen -> pure chosen
    let total = sum [c | (_, o) <- prefix, let Coin c = o ^. coinTxOutL]
        change = total - publicationFee - refCoin
        CoinPerByte compactPerByte = pp ^. ppCoinsPerUTxOByteL
        Coin perByte = fromCompact compactPerByte
        limit = fromIntegral (pp ^. ppMaxTxSizeL)
        size =
            if perByte <= 0
                then 0
                else (refCoin `div` perByte) + fromIntegral (length prefix) * 40 + 300
    if limit > 0 && size > limit
        then Left (PublicationOversize size limit)
        else pure (prefix, refOut, change)
  where
    takeCovering _ [] _ = Nothing
    takeCovering need ((k, o) : rest) acc =
        let Coin c = o ^. coinTxOutL
            acc' = acc + c
        in  if acc' > need
                then Just [(k, o)]
                else case takeCovering need rest acc' of
                    Nothing -> Nothing
                    Just chosen -> Just ((k, o) : chosen)

{- | The change output a first publication makes from the whole wallet, and
the seed it becomes (#406 slice 2): the shortest largest-first prefix of
all the ada-only outputs (nothing withheld) funds the state publication,
its change at index 1 is the chained seed. The body is exactly the one
'publishRefScriptTx' builds from the same view (flat fee, no validity
interval), so the transaction id — and the token it derives — is the same
in preview and in create. The arithmetic is 'selectPublicationInputs''s;
this accessor adds only the body and its id.
-}
firstPublicationChange
    :: PParams ConwayEra
    -> Addr
    -> Script ConwayEra
    -> [(TxIn, TxOut ConwayEra)]
    -> Either
        PublicationFundingError
        (TxIn, ConwayTx, TxOut ConwayEra, [(TxIn, TxOut ConwayEra)], Integer)
firstPublicationChange pp payerAddr script wallet = do
    let permitted = [u | u@(_, o) <- wallet, adaOnlyOut o]
    (funds, refOut, changeCoin) <-
        selectPublicationInputs pp payerAddr script permitted
    let changeOut = mkBasicTxOut payerAddr (MaryValue (Coin changeCoin) mempty)
        body =
            mkBasicTxBody
                & inputsTxBodyL .~ Set.fromList (map fst funds)
                & outputsTxBodyL
                    .~ StrictSeq.fromList [refOut, changeOut]
                & feeTxBodyL .~ Coin publicationFee
        tx = mkBasicTx body
        seed = TxIn (txIdTx tx) (TxIx 1)
    pure (seed, tx, refOut, funds, changeCoin)

-- | Publish one script as a reference output at the payer's own address.
publishRefScript
    :: (Cage.Network, Cage.LedgerProvider Cage.NoWitness IO)
    -> SubmitSigned
    -> Addr
    -> Script ConwayEra
    -> IO (TxIn, TxOut ConwayEra)
publishRefScript = publishRefScriptReserving Set.empty

{- | 'publishRefScript', never spending a reserved output (#299): a caller
that has chosen the seed of a later boot keeps it unspent while it
publishes. The largest ada-only output that is not reserved funds it.
-}
publishRefScriptReserving
    :: Set.Set TxIn
    -> (Cage.Network, Cage.LedgerProvider Cage.NoWitness IO)
    -> SubmitSigned
    -> Addr
    -> Script ConwayEra
    -> IO (TxIn, TxOut ConwayEra)
publishRefScriptReserving reserved prov submit payerAddr script = do
    (unsigned, refOut) <-
        Cage.withLatest prov $ \v -> publishRefScriptTx reserved v payerAddr script
    signed <- submit unsigned
    pure (TxIn (txIdTx signed) (TxIx 0), refOut)

{- | The unsigned publication of one reference script, funded by the
shortest largest-first prefix of the ada-only outputs outside the
reservation, and the reference output it creates.
-}
publishRefScriptTx
    :: Set.Set TxIn
    -> Cage.Session Cage.NoWitness IO
    -> Addr
    -> Script ConwayEra
    -> IO (ConwayTx, TxOut ConwayEra)
publishRefScriptTx reserved v payerAddr script = do
    pp <- Cage.parameters v
    utxos <- Cage.outputsAt v payerAddr
    let permitted =
            filter (\(i, o) -> adaOnlyOut o && Set.notMember i reserved) utxos
    (funds, refOut, changeCoin) <- case selectPublicationInputs pp payerAddr script permitted of
        Left (PublicationShortfall needed held largest) ->
            if null permitted
                then error "publishRefScript: the payer wallet has no ada-only output"
                else
                    error
                        ( "publishRefScript: the funding outputs hold "
                            <> show held
                            <> ", which does not cover a reference output of "
                            <> show (needed - publicationFee - publicationMinChange)
                            <> " plus fees; largest holds "
                            <> show largest
                        )
        Left (PublicationOversize size limit) ->
            error
                ( "publishRefScript: the funding transaction would be "
                    <> show size
                    <> " bytes, over the protocol maximum "
                    <> show limit
                )
        Right chosen -> pure chosen
    let body =
            mkBasicTxBody
                & inputsTxBodyL .~ Set.fromList (map fst funds)
                & outputsTxBodyL
                    .~ StrictSeq.fromList
                        [ refOut
                        , mkBasicTxOut payerAddr (MaryValue (Coin changeCoin) mempty)
                        ]
                & feeTxBodyL .~ Coin publicationFee
    pure (mkBasicTx body, refOut)

{- | Publish the state validator as a reference output, once, before any
boot (#177).

A registry boots only by reference: the boot resolves the state
validator through a publication in the payer's wallet and is refused
`StateValidatorNotPublished` without one, because that validator is
fifteen kilobytes against a sixteen-kilobyte transaction cap. A session
calls this before its first boot.

Idempotent by discovery: a wallet that already holds the publication
gets it back rather than a second one, so a harness that boots several
cages publishes once.
-}
publishStateRef
    :: CageConfig
    -> (Cage.Network, Cage.LedgerProvider Cage.NoWitness IO)
    -> SubmitSigned
    -> Addr
    -> IO (TxIn, TxOut ConwayEra)
publishStateRef = publishStateRefReserving Set.empty

{- | 'publishStateRef', never spending a reserved output (#299): an
existing publication is returned as before, and a new one is funded
outside the reservation.
-}
publishStateRefReserving
    :: Set.Set TxIn
    -> CageConfig
    -> (Cage.Network, Cage.LedgerProvider Cage.NoWitness IO)
    -> SubmitSigned
    -> Addr
    -> IO (TxIn, TxOut ConwayEra)
publishStateRefReserving reserved cfg prov submit payerAddr = do
    let script = mkCageScript cfg
    utxos <- Cage.withLatest prov (`Cage.outputsAt` payerAddr)
    case stateRefIn cfg utxos of
        Just u -> pure u
        Nothing -> publishRefScriptReserving reserved prov submit payerAddr script

-- | An output among these that publishes this cage's state validator.
stateRefIn
    :: CageConfig
    -> [(TxIn, TxOut ConwayEra)]
    -> Maybe (TxIn, TxOut ConwayEra)
stateRefIn cfg utxos =
    case [ u
         | u@(_, out) <- utxos
         , SJust s <- [out ^. referenceScriptTxOutL]
         , hashScript s == hashScript (mkCageScript cfg)
         ] of
        (u : _) -> Just u
        [] -> Nothing
