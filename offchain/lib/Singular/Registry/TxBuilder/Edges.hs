{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.Registry.TxBuilder.Edges
Description : Booking and folding one registry-mode tree edge
License     : Apache-2.0

Registry mode admits seven edges and nothing else (#157 seven-admitted-edges), and every
processed edge but a read rides on an approval the naming application's
mint arm certified (#157 tree-edge-admission-by-approval, approval-asset-binding). A caller that wants a fold to
land therefore needs three things this module supplies: the four policy
pins derived from the naming partition's own compiled code, a booking
transaction that carries each edge's certification — which edges get
an approval, what it is, and nothing at all for a read — and the duties
context the fold discharges its obligations from.

The state validator alone is fifteen kilobytes, so a fold that attaches
it, the request validator and a token policy does not fit in a
transaction. 'publishCageRefs' publishes them once as reference outputs
and every purpose resolves through those instead.

Every consumer of the application — the conformance rows, the devnet end-to-end
and the bounded journey — derives its pins and books its edges the same
way, so all three move together.
-}
module Singular.Registry.TxBuilder.Edges
    ( -- * Submission
      SubmitSigned

      -- * Derived identity
    , registryIdOf
    , witnessScriptOf
    , namingPins

      -- * Reference outputs
    , publishRefScript
    , publishRefScriptReserving
    , publishRefScriptTx
    , publishReferencesTx
    , publishStateRef
    , publishStateRefReserving
    , stateRefIn
    , publishCageRefs
    , adaOnlyOut
    , selectFunding

      -- * Booking one edge
    , BookingApproval (..)
    , bookingApproval
    , certifyBooking
    , bookEdge
    , bookEdgeTo
    , bookEdgeWith
    , bookEdgeTx
    , bookEdgeMeasured
    , edgeDeposit
    , edgeDestinationOf
    , edgeRecordDatum

      -- * Folding
    , registryContextFor
    ) where

import Control.Monad (unless, when)
import Data.ByteString (ByteString)
import Data.ByteString.Short qualified as SBS
import Data.Foldable (toList)
import Data.List (sortOn)
import Data.Map.Strict qualified as Map
import Data.Maybe (mapMaybe)
import Data.Ord (Down (..))
import Data.Sequence.Strict qualified as StrictSeq
import Data.Set qualified as Set
import Lens.Micro ((&), (.~), (^.))

import Cardano.Ledger.Address (Addr (..), serialiseAddr)
import Cardano.Ledger.Alonzo.Scripts (AsIx (..))
import Cardano.Ledger.Api.Tx
    ( bodyTxL
    , estimateMinFeeTx
    , mkBasicTx
    , txIdTx
    , witsTxL
    )
import Cardano.Ledger.Api.Tx.Body
    ( collateralInputsTxBodyL
    , collateralReturnTxBodyL
    , feeTxBodyL
    , inputsTxBodyL
    , mintTxBodyL
    , mkBasicTxBody
    , outputsTxBodyL
    , referenceInputsTxBodyL
    , reqSignerHashesTxBodyL
    , scriptIntegrityHashTxBodyL
    )
import Cardano.Ledger.Api.Tx.Out
    ( TxOut
    , coinTxOutL
    , datumTxOutL
    , getMinCoinTxOut
    , mkBasicTxOut
    , referenceScriptTxOutL
    , valueTxOutL
    )
import Cardano.Ledger.Api.Tx.Wits
    ( Redeemers (..)
    , rdmrsTxWitsL
    , scriptTxWitsL
    )
import Cardano.Ledger.BaseTypes (StrictMaybe (..), TxIx (..))
import Cardano.Ledger.Conway.Scripts (ConwayPlutusPurpose (..))
import Cardano.Ledger.Core (PParams, Script, hashScript)
import Cardano.Ledger.Credential
    ( Credential (..)
    , StakeReference (..)
    )
import Cardano.Ledger.Mary.Value
    ( AssetName (..)
    , MaryValue (..)
    , MultiAsset (..)
    , PolicyID (..)
    )
import Cardano.Ledger.TxIn (TxIn (..))
import Cardano.Tx.Ledger (ConwayTx)
import PlutusCore.Data qualified as PLC

import Control.Tracer (Tracer)
import Singular.Registry.AssetName (deriveAssetName)
import Singular.Registry.Blueprint.Load (NamingCodes (..))
import Singular.Registry.Blueprint.Params
    ( applyBytesParam
    , applyDataParam
    )
import Singular.Registry.Config (CageConfig (..))
import Singular.Registry.Surface
    ( BodyBuild (..)
    , BodyEnd (..)
    , Coin (..)
    , ConwayEra
    , NoWitness
    , ReadEvent (..)
    , Session
    , TokenId
    , WalletOutputs
    , fundableOutputsAt
    , fundingOutputs
    , parameters
    , readOutputsAt
    , timedTrace
    )
import Singular.Registry.TxBuilder.ConnectedFold
    ( RawRedeemer (..)
    , generousUnits
    )
import Singular.Registry.TxBuilder.Internal.Edges
    ( approvalDestination
    , approvalName
    )
import Singular.Registry.TxBuilder.Internal.Identity
    ( addrKeyHashBytes
    , addrWitnessKeyHash
    , cageAddrFromCfg
    , computeScriptHash
    , mkCageScript
    , mkInlineDatum
    , mkRequestDatumWith
    , mkRequestScript
    , requestAddrFromCfg
    , scriptFromBytes
    , scriptHashBytes
    , toLedgerData
    )
import Singular.Registry.TxBuilder.Internal.Lookup
    ( computeScriptIntegrity
    , currentPosixMs
    , evaluateAndBalanceReferencing
    )
import Singular.Registry.TxBuilder.Update
    ( RegistryContext (..)
    , emptyRegistryContext
    )
import Singular.Registry.Types
    ( Edge
    , edgeInsertAbsent
    , edgeInsertActive
    , edgeUpdateActive
    , edgeWitnessTerminal
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
    :: CageConfig -> NamingCodes -> Integer -> Script ConwayEra
witnessScriptOf cfg codes kind =
    scriptFromBytes
        ("witness-" <> show kind)
        ( applyBytesParam
            (registryIdOf cfg)
            (applyDataParam (PLC.I kind) (ncWitness codes))
        )

{- | The four pins a registry identity carries (#157 genesis-policy-pins), derived
from the naming partition's own compiled code: the application validator
for the approval, and @witness(kind, registry)@ at kinds 0, 1 and 2.

The registry id the witness policies are parameterized by depends on the
state script hash and the boot seed, so this takes them directly rather
than a configuration that does not exist yet.
-}
namingPins
    :: NamingCodes
    -> ByteString
    -- ^ The registry id: state script hash then boot token name
    -> ( SBS.ShortByteString
       , SBS.ShortByteString
       , SBS.ShortByteString
       , SBS.ShortByteString
       )
    -- ^ Application, absent, active, terminal
namingPins codes registryId =
    ( pinOf (ncApplication codes)
    , witnessPin 0
    , witnessPin 1
    , witnessPin 2
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

-- | Publish one script as a reference output at the payer's own address.
publishRefScript
    :: Session NoWitness IO
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
    -> Session NoWitness IO
    -> SubmitSigned
    -> Addr
    -> Script ConwayEra
    -> IO (TxIn, TxOut ConwayEra)
publishRefScriptReserving reserved v submit payerAddr script = do
    (unsigned, refOut) <- publishRefScriptTx reserved v payerAddr script
    signed <- submit unsigned
    pure (TxIn (txIdTx signed) (TxIx 0), refOut)

{- | The unsigned publication of one reference script, funded by the
largest ada-only output outside the reservation, and the reference
output it creates.
-}
publishRefScriptTx
    :: Set.Set TxIn
    -> Session NoWitness IO
    -> Addr
    -> Script ConwayEra
    -> IO (ConwayTx, TxOut ConwayEra)
publishRefScriptTx reserved v payerAddr script = do
    pp <- parameters v
    utxos <- fundableOutputsAt v payerAddr
    fund <-
        case sortOn
            (Down . (^. coinTxOutL) . snd)
            (filter (\(i, o) -> adaOnlyOut o && Set.notMember i reserved) utxos) of
            [] -> error "publishRefScript: the payer wallet has no ada-only output"
            (u : _) -> pure u
    let probe =
            mkBasicTxOut payerAddr (MaryValue (Coin 0) mempty)
                & referenceScriptTxOutL .~ SJust script
        Coin minCoin = getMinCoinTxOut pp probe
        refCoin = minCoin + 1_000_000
        refOut =
            mkBasicTxOut payerAddr (MaryValue (Coin refCoin) mempty)
                & referenceScriptTxOutL .~ SJust script
        fee = 1_000_000
        Coin inCoin = snd fund ^. coinTxOutL
        changeCoin = inCoin - fee - refCoin
    unless (changeCoin > 1_000_000) $
        error
            ( "publishRefScript: the funding output holds "
                <> show inCoin
                <> ", which does not cover a reference output of "
                <> show refCoin
                <> " plus fees"
            )
    let body =
            mkBasicTxBody
                & inputsTxBodyL .~ Set.singleton (fst fund)
                & outputsTxBodyL
                    .~ StrictSeq.fromList
                        [ refOut
                        , mkBasicTxOut payerAddr (MaryValue (Coin changeCoin) mempty)
                        ]
                & feeTxBodyL .~ Coin fee
    pure (mkBasicTx body, refOut)

{- | Publish every checked script as a minimum-ADA reference output at the
payer's address, in one transaction funded from permitted outputs only.
The first largest-first prefix that settles at the ledger's exact fee
funds it; carriers and token holdings never do. Insufficient permitted
funds fail closed with a stable message (the command gates sufficiency
by name before building).
-}
publishReferencesTx
    :: Session NoWitness IO
    -> Addr
    -> WalletOutputs
    -> [Script ConwayEra]
    -> IO (ConwayTx, [TxOut ConwayEra])
publishReferencesTx session payerAddr wallet scripts = do
    when (null scripts) $
        error "publishReferencesTx: no scripts to publish"
    pp <- parameters session
    let funds = fundingOutputs wallet
        published =
            [ atMinimum
                pp
                ( mkBasicTxOut payerAddr (MaryValue (Coin 0) mempty)
                    & referenceScriptTxOutL
                        .~ SJust script
                )
            | script <- scripts
            ]
    case mapMaybe
        (\n -> settleTo pp payerAddr (take n funds) published)
        [1 .. length funds] of
        tx : _ -> pure (tx, published)
        [] ->
            error
                "publishReferencesTx: permitted outputs cannot cover the reference outputs and the fee"

atMinimum :: PParams ConwayEra -> TxOut ConwayEra -> TxOut ConwayEra
atMinimum pp out
    | out ^. coinTxOutL == Coin wanted = out
    | otherwise = out & coinTxOutL .~ Coin wanted
  where
    Coin base = getMinCoinTxOut pp (out & coinTxOutL .~ Coin 0)
    wanted = base + 1_000_000

{- | Settle inputs and minimum outputs at the ledger's exact fee: try the
fee, charge it, and repeat until the fee stops moving (at most eight
rounds) or the inputs cannot cover outputs, fee and a minimum-ada
change. Nothing means they cannot.
-}
settleTo
    :: PParams ConwayEra
    -> Addr
    -> [(TxIn, TxOut ConwayEra)]
    -> [TxOut ConwayEra]
    -> Maybe ConwayTx
settleTo pp payerAddr inputs outs = go (0 :: Int) (Coin 0)
  where
    MaryValue (Coin held) _ = foldMap ((^. valueTxOutL) . snd) inputs
    Coin paid = foldMap (^. coinTxOutL) outs
    build fee@(Coin f) =
        let rest = mkBasicTxOut payerAddr (MaryValue (Coin (held - paid - f)) mempty)
        in  ( rest
            , mkBasicTx $
                mkBasicTxBody
                    & inputsTxBodyL .~ Set.fromList (map fst inputs)
                    & outputsTxBodyL .~ StrictSeq.fromList (outs <> [rest])
                    & feeTxBodyL .~ fee
            )
    go rounds fee@(Coin f)
        | rounds > 8 || held - paid - f < 0 = Nothing
        | needed > fee = go (rounds + 1) needed
        | rest ^. coinTxOutL < getMinCoinTxOut pp rest = Nothing
        | otherwise = Just tx
      where
        (rest, tx) = build fee
        needed = estimateMinFeeTx pp tx 1 0 0

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
    -> Session NoWitness IO
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
    -> Session NoWitness IO
    -> SubmitSigned
    -> Addr
    -> IO (TxIn, TxOut ConwayEra)
publishStateRefReserving reserved cfg v submit payerAddr = do
    let script = mkCageScript cfg
    utxos <- readOutputsAt v payerAddr
    case stateRefIn cfg utxos of
        Just u -> pure u
        Nothing -> publishRefScriptReserving reserved v submit payerAddr script

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

{- | Publish this cage's scripts as reference outputs: the cage, the
request validator and the three token policies.
-}
publishCageRefs
    :: CageConfig
    -> NamingCodes
    -> Session NoWitness IO
    -> SubmitSigned
    -> Addr
    -> TokenId
    -> IO [(TxIn, TxOut ConwayEra)]
publishCageRefs cfg codes v submit payerAddr tokenId =
    mapM
        (publishRefScript v submit payerAddr)
        ( [ mkCageScript cfg
          , mkRequestScript cfg tokenId
          ]
            <> map (witnessScriptOf cfg codes) [0, 1, 2]
        )

{- | The record datum a booking's destination carries. The cage checks only
that the receiving output carries the datum the request carries — naming's
own validators do not run at fold time — so one datum is enough.
-}
edgeRecordDatum :: PLC.Data
edgeRecordDatum = PLC.B "singular-record"

{- | Where an edge delivers (#157 request-destination-binding). An absence names the address
its deposit comes back to and no datum; an activation names the naming
application's own address and carries the record datum the delivered
output will hold.
-}
edgeDestinationOf
    :: CageConfig
    -> NamingCodes
    -> Addr
    -> Edge
    -> (ByteString, Maybe PLC.Data)
edgeDestinationOf cfg codes payerAddr edge =
    let appHash = computeScriptHash (ncApplication codes)
        appAddr = Addr (network cfg) (ScriptHashObj appHash) StakeRefNull
    in  if edge == edgeInsertActive || edge == edgeUpdateActive
            then (serialiseAddr appAddr, Just edgeRecordDatum)
            else (serialiseAddr payerAddr, Nothing)

{- | The deposit a booking rides with, over and above the tip. The fold
returns it to the destination the request named, or locks it in the
custody an absence creates — it is never the folder's.
-}
edgeDeposit :: Integer
edgeDeposit = 3_000_000

{- | What a tree-edge booking carries so the naming application
certifies it (DM-1): the asset it mints, the @Approve@ redeemer the
mint arm reads, and the application script that witnesses the mint.
The asset name hashes the same @(edge, key, owner, destination)@ the
redeemer carries, so one value binds both (DM-1-BIND).
-}
data BookingApproval = BookingApproval
    { baAsset :: MultiAsset
    -- ^ Exactly one asset, quantity 1, under the application policy.
    , baRedeemer :: PLC.Data
    {- ^ The @Approve@ constructor over @[edge, key, owner,
    [destinationAddress, destinationDatumHash]]@.
    -}
    , baScript :: Script ConwayEra
    -- ^ The application script, the mint's witness.
    , baScriptReference :: Maybe TxIn
    {- ^ An output carrying the application script as a reference
    script: the booking reads the script from it instead of carrying it
    as a witness. Nothing for the naming and open applications.
    -}
    , baReferenceInputs :: Set.Set TxIn
    {- ^ Outputs the application reads without spending: the registry
    state, and for a termination the live output it releases. Empty for
    the naming and open applications.
    -}
    }

{- | The booking certification decision, in one place (#240): which
edges carry an approval and what it is. A tree edge (0–5) carries the
approval 'approvalName' binds; @edgeWitnessTerminal@ carries none,
because @open.ak@ refuses to certify a read and the cage never looks
for one — a booking that minted anyway is a transaction the node can
only reject. Admissibility of @edge@ stays the caller's check.
-}
bookingApproval
    :: NamingCodes
    -> Edge
    -- ^ Admissible edge, 0..6
    -> ByteString
    -- ^ Registry key
    -> ByteString
    -- ^ Booker's key hash bytes
    -> (ByteString, ByteString)
    -- ^ Destination: address bytes, datum hash
    -> Maybe BookingApproval
bookingApproval codes edge key owner dest
    | edge == edgeWitnessTerminal = Nothing
    | otherwise =
        Just
            BookingApproval
                { baAsset =
                    MultiAsset
                        ( Map.singleton
                            appPolicy
                            (Map.singleton (AssetName (SBS.toShort name)) 1)
                        )
                , baRedeemer =
                    PLC.Constr
                        0
                        [ PLC.I edge
                        , PLC.B key
                        , PLC.B owner
                        , PLC.List [PLC.B destAddr, PLC.B destHash]
                        ]
                , baScript = appScript
                , baScriptReference = Nothing
                , baReferenceInputs = Set.empty
                }
  where
    name = approvalName edge key owner dest
    appScript = scriptFromBytes "naming-application" (ncApplication codes)
    appPolicy = PolicyID (hashScript appScript)
    (destAddr, destHash) = dest

{- | Put a booking's certification into the transaction (DM-1b): with
an approval, the mint, its redeemer, the script witness, the collateral
and the script-integrity hash; without one, the booking unchanged — no
redeemers, no witness, no collateral, and so no script-integrity hash,
which the ledger computes for any transaction that could run a script.
-}
certifyBooking
    :: PParams ConwayEra
    -- ^ Protocol parameters, for the script-integrity hash
    -> TxIn
    -- ^ Ada-only input, collateral when an approval is present
    -> Maybe BookingApproval
    -> ConwayTx
    -- ^ The booking with inputs, outputs, fee and signers set
    -> ConwayTx
certifyBooking pp collateral mApproval unsigned =
    case mApproval of
        Nothing -> unsigned
        Just approval ->
            let redeemers =
                    Redeemers
                        ( Map.singleton
                            (ConwayMinting (AsIx 0))
                            ( toLedgerData (RawRedeemer (baRedeemer approval))
                            , generousUnits
                            )
                        )
            in  unsigned
                    & bodyTxL . mintTxBodyL .~ baAsset approval
                    & bodyTxL . collateralInputsTxBodyL .~ Set.singleton collateral
                    & bodyTxL . referenceInputsTxBodyL
                        .~ ( baReferenceInputs approval
                                <> maybe Set.empty Set.singleton (baScriptReference approval)
                           )
                    & bodyTxL
                        . scriptIntegrityHashTxBodyL
                        .~ computeScriptIntegrity pp redeemers
                    & witsTxL . rdmrsTxWitsL .~ redeemers
                    & witsTxL . scriptTxWitsL
                        .~ case baScriptReference approval of
                            Just _ -> Map.empty
                            Nothing ->
                                Map.singleton
                                    (hashScript (baScript approval))
                                    (baScript approval)

{- | Book an edge, routing its minted token to the destination
`edgeDestinationOf` chooses for it.
-}
bookEdge
    :: CageConfig
    -> NamingCodes
    -> Session NoWitness IO
    -> SubmitSigned
    -> Addr
    -> TokenId
    -> ByteString
    -> Edge
    -> IO TxIn
bookEdge cfg codes v submit payerAddr tokenId key edge =
    bookEdgeTo
        cfg
        codes
        v
        submit
        payerAddr
        tokenId
        key
        edge
        (edgeDestinationOf cfg codes payerAddr edge)

{- | Book an edge, naming the destination explicitly (#173 I4, I5).

`edgeDestinationOf` sends an `insertActive` to the APPLICATION's own
script address, because the naming application is what creates the
record the active token witnesses. The OPEN registry has no such
application: `open.ak` is a minting policy with no spending arm at all,
so a token routed there would be locked forever.

The open story therefore names a WALLET, and the request carries that
choice. Nothing on chain changes: the cage already checks the
destination the request declares, and this is the off-chain builder
learning to say something it could not say before.

Which edges carry an approval, what it is, and how the transaction
carries it is decided once, in 'bookingApproval' and 'certifyBooking':
a tree edge mints and certifies, and a read books nothing at all.
-}
bookEdgeTo
    :: CageConfig
    -> NamingCodes
    -> Session NoWitness IO
    -> SubmitSigned
    -> Addr
    -> TokenId
    -> ByteString
    -> Edge
    -> (ByteString, Maybe PLC.Data)
    -> IO TxIn
bookEdgeTo cfg codes v submit payerAddr tokenId key edge dest = do
    signed <-
        bookEdgeWith
            cfg
            v
            submit
            payerAddr
            tokenId
            key
            edge
            dest
            edgeDeposit
            ( bookingApproval
                codes
                edge
                key
                (addrKeyHashBytes payerAddr)
                (approvalDestination dest)
            )
    pure (TxIn (txIdTx signed) (TxIx 0))

{- | Book an edge with the certification and deposit the caller's
application decides (#299): the approval it mints, with any outputs it
reads by reference, and the deposit the request rides with over the tip.
The booker's own key is the request's owner and its required signer.
Returns the signed booking as the submission callback handed it back;
the request is its first output.
-}
bookEdgeWith
    :: CageConfig
    -> Session NoWitness IO
    -> SubmitSigned
    -> Addr
    -> TokenId
    -> ByteString
    -> Edge
    -> (ByteString, Maybe PLC.Data)
    -> Integer
    -- ^ The deposit, over and above the tip
    -> Maybe BookingApproval
    -> IO ConwayTx
bookEdgeWith cfg v submit payerAddr tokenId key edge dest deposit approval =
    bookEdgeTx cfg v payerAddr tokenId key edge dest deposit approval
        >>= submit

{- | The unsigned booking of one edge, built from one view: the payer's
largest ada-only output pays the bond, the fee and the change.
-}
bookEdgeTx
    :: CageConfig
    -> Session NoWitness IO
    -> Addr
    -> TokenId
    -> ByteString
    -> Edge
    -> (ByteString, Maybe PLC.Data)
    -> Integer
    -- ^ The deposit, over and above the tip
    -> Maybe BookingApproval
    -> IO ConwayTx
bookEdgeTx cfg v payerAddr tokenId key edge dest deposit approval = do
    requireAdmissible key edge
    pp <- parameters v
    utxos <- fundableOutputsAt v payerAddr
    (feeIn, feeOut) <-
        case sortOn
            (Down . (^. coinTxOutL) . snd)
            (filter (adaOnlyOut . snd) utxos) of
            [] -> error "bookEdge: the payer wallet has no ada-only output"
            (u : _) -> pure u
    now <- currentPosixMs
    let MaryValue (Coin feeBal) carried = feeOut ^. valueTxOutL
        (reqOut, bond) =
            requestOutput
                cfg
                pp
                tokenId
                payerAddr
                key
                edge
                dest
                deposit
                approval
                now
        fee = 2_000_000
        change = feeBal - bond - fee
        owner = addrKeyHashBytes payerAddr
    unless (change > 0) $
        error
            ("bookEdge: the payer wallet is too small (" <> show feeBal <> ")")
    let body =
            mkBasicTxBody
                & inputsTxBodyL .~ Set.singleton feeIn
                & outputsTxBodyL
                    .~ StrictSeq.fromList
                        [ reqOut
                        , mkBasicTxOut payerAddr (MaryValue (Coin change) carried)
                        ]
                & feeTxBodyL .~ Coin fee
                & reqSignerHashesTxBodyL
                    .~ Set.singleton (addrWitnessKeyHash owner)
    pure (certifyBooking pp feeIn approval (mkBasicTx body))

{- | A booking's edge must be one of the seven the registry admits (#183):
the tag IS the edge. A booking states its own seven-admitted-edges row, and a row outside the
table is one only an adversarial caller wants, so it is refused here rather
than carried to a fold that would refuse it @edge-inadmissible@ anyway.
-}
requireAdmissible :: ByteString -> Edge -> IO ()
requireAdmissible key edge =
    when (edge < edgeInsertAbsent || edge > edgeWitnessTerminal) $
        error
            ( "bookEdge: edge "
                <> show edge
                <> " on key "
                <> show key
                <> " is not one of the seven admissible edges"
            )

{- | The request output a booking locks, and the bond it holds.

Issue 183: the datum binds the DEPOSIT, not the tip. The output holds @bond@ =
tip + deposit, and the fold checks @deposit == held - tip@, so the two are
the same number written once each. The min-ADA check is what keeps them
equal: a bond raised to meet min-ADA would break the equality silently, so
the booking refuses instead.
-}
requestOutput
    :: CageConfig
    -> PParams ConwayEra
    -> TokenId
    -> Addr
    -> ByteString
    -> Edge
    -> (ByteString, Maybe PLC.Data)
    -> Integer
    -> Maybe BookingApproval
    -> Integer
    -> (TxOut ConwayEra, Integer)
requestOutput cfg pp tokenId payerAddr key edge dest deposit approval now =
    let Coin tipVal = defaultTip cfg
        bond = tipVal + deposit
        datum = mkRequestDatumWith tokenId payerAddr key edge deposit now dest
        reqOut =
            mkBasicTxOut
                (requestAddrFromCfg cfg tokenId (network cfg))
                (MaryValue (Coin bond) (maybe mempty baAsset approval))
                & datumTxOutL .~ mkInlineDatum datum
        Coin minAda = getMinCoinTxOut pp reqOut
    in  if bond >= minAda
            then (reqOut, bond)
            else error ("bookEdge: the bond is under min-ADA: " <> show bond)

{- | 'bookEdgeWith' with its fee, units and collateral measured rather
than declared (#300).

The node's evaluator measures the booking's one purpose, the redeemer
declares exactly those units, and the balancer charges the ledger's fee for
the final body, reference scripts included — the resolved outputs the
booking reads its script from are handed to it. The funding output, the
wallet's largest ada-only output unless the caller chose one, is the
collateral input, and the transaction states its total collateral at the
protocol's percentage of the fee, rounded up, and a return carrying the rest
of the output back. Everything is read from the one view the caller holds,
and the booking is returned unsigned: the caller submits it after the view is
released, and a caller that only prepares submits nothing.
-}
bookEdgeMeasured
    :: CageConfig
    -> Session NoWitness IO
    {- ^ The one acquired view the booking is built, measured and certified
    from: its protocol parameters are the ones the caller reports and judges
    its outlay under, and nothing is submitted while it is held
    -}
    -> Tracer IO ReadEvent
    {- ^ Where the build reports its timing: the caller's scope, passed
    explicitly because the session record stays closed.
    -}
    -> Addr
    -> TokenId
    -> ByteString
    -> Edge
    -> (ByteString, Maybe PLC.Data)
    -> Integer
    -- ^ The deposit, over and above the tip
    -> BookingApproval
    -> [(TxIn, TxOut ConwayEra)]
    -- ^ The resolved outputs the booking reads its scripts from
    -> Maybe TxIn
    -- ^ The wallet output the caller chose to fund and collateralise
    -> IO ConwayTx
bookEdgeMeasured cfg v tracer payerAddr tokenId key edge dest deposit approval refs chosen =
    timedTrace
        tracer
        ( \ms end ->
            BodyBuilt
                BodyBuild
                    { bodyBuilder = "bookEdgeMeasured"
                    , bodyElapsed = ms
                    , bodyEnd = either BodyFailed (const BodyReady) end
                    }
        )
        ( measuredBody
            cfg
            v
            payerAddr
            tokenId
            key
            edge
            dest
            deposit
            approval
            refs
            chosen
        )

-- | The measured booking, unlogged: the builder 'bookEdgeMeasured' times.
measuredBody
    :: CageConfig
    -> Session NoWitness IO
    -> Addr
    -> TokenId
    -> ByteString
    -> Edge
    -> (ByteString, Maybe PLC.Data)
    -> Integer
    -> BookingApproval
    -> [(TxIn, TxOut ConwayEra)]
    -> Maybe TxIn
    -> IO ConwayTx
measuredBody cfg v payerAddr tokenId key edge dest deposit approval refs chosen = do
    requireAdmissible key edge
    pp <- parameters v
    utxos <- fundableOutputsAt v payerAddr
    funding <-
        either (error . ("bookEdge: " <>)) pure (selectFunding chosen utxos)
    now <- currentPosixMs
    let (reqOut, _) =
            requestOutput
                cfg
                pp
                tokenId
                payerAddr
                key
                edge
                dest
                deposit
                (Just approval)
                now
        body =
            mkBasicTxBody
                & inputsTxBodyL .~ Set.singleton (fst funding)
                & outputsTxBodyL .~ StrictSeq.singleton reqOut
                & reqSignerHashesTxBodyL
                    .~ Set.singleton (addrWitnessKeyHash (addrKeyHashBytes payerAddr))
        unsigned = certifyBooking pp (fst funding) (Just approval) (mkBasicTx body)
    balanced <-
        evaluateAndBalanceReferencing
            v
            pp
            [funding]
            refs
            payerAddr
            unsigned
    requireCarriesMinimums pp balanced
    pure balanced

{- | The balancer appends a change output and a collateral return whatever
they hold. A funding output too small to leave either its minimum ada would
make a transaction the ledger refuses, so the booking refuses it first.
-}
requireCarriesMinimums :: PParams ConwayEra -> ConwayTx -> IO ()
requireCarriesMinimums pp tx = do
    unless (all carries outs) $
        error
            "bookEdge: the funding output is too small to carry the booking, its fee, its collateral and their change"
    -- The balancer collateralises the whole input, stating no return, when
    -- what remains after the required total is under the minimum output.
    -- A booking never puts a whole funding output at risk.
    case body ^. collateralReturnTxBodyL of
        SNothing ->
            error
                "bookEdge: the funding output cannot leave a collateral return of its minimum, so its whole value would be collateral"
        SJust _ -> pure ()
  where
    body = tx ^. bodyTxL
    outs =
        toList (body ^. outputsTxBodyL)
            <> [r | SJust r <- [body ^. collateralReturnTxBodyL]]
    carries o = o ^. coinTxOutL >= getMinCoinTxOut pp o

{- | What a fold of tree edges needs in hand: the three token policies
this registry pins, the cage script custody spends run, the cage's own
UTxOs, the one destination datum a booking binds, and the reference
outputs the fold's scripts resolve through.
-}
registryContextFor
    :: CageConfig
    -> NamingCodes
    -> Session NoWitness IO
    -> [(TxIn, TxOut ConwayEra)]
    -> IO RegistryContext
registryContextFor cfg codes v refs = do
    utxos <- readOutputsAt v (cageAddrFromCfg cfg (network cfg))
    pure
        emptyRegistryContext
            { rcWitnessScripts =
                Map.fromList [(k, witnessScriptOf cfg codes k) | k <- [0, 1, 2]]
            , rcCageScript = Just (mkCageScript cfg)
            , rcCageUtxos = utxos
            , rcRefUtxos = refs
            }
