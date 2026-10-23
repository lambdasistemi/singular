{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.Registry.TxBuilder.Edges
Description : Booking and folding one registry-mode tree edge
License     : Apache-2.0

M1 admits insertActive and updateTerminal (#157 seven-admitted-edges), and every
processed edge rides on an approval the naming application's
mint arm certified (#157 tree-edge-admission-by-approval, approval-asset-binding). A caller that wants a fold to
land therefore needs three things this module supplies: the two policy
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
    , PublicationFundingError (..)
    , selectPublicationInputs
    , firstPublicationChange
    , publicationFee
    , publicationMinChange
    , publicationRefCoin
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
import Data.Ord (Down (..))
import Data.Sequence.Strict qualified as StrictSeq
import Data.Set qualified as Set
import Lens.Micro ((&), (.~), (^.))

import Cardano.Ledger.Address (Addr (..), serialiseAddr)
import Cardano.Ledger.Alonzo.Scripts (AsIx (..))
import Cardano.Ledger.Api.PParams (ppCoinsPerUTxOByteL, ppMaxTxSizeL)
import Cardano.Ledger.Api.Tx (bodyTxL, mkBasicTx, txIdTx, witsTxL)
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
import Cardano.Ledger.Coin (CoinPerByte (..))
import Cardano.Ledger.Compactible (fromCompact)
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

import Singular.Registry.AssetName (deriveAssetName)
import Singular.Registry.Blueprint.Load (NamingCodes (..))
import Singular.Registry.Blueprint.Params
    ( applyBytesParam
    , applyDataParam
    )
import Singular.Registry.Config (CageConfig (..))
import Singular.Registry.Evidence qualified as Cage
import Singular.Registry.Ledger (Coin (..), ConwayEra, TokenId)
import Singular.Registry.LedgerProvider qualified as Cage
import Singular.Registry.SessionIO qualified as Cage
import Singular.Registry.Trace
    ( BodyBuild (..)
    , BodyEnd (..)
    , ReadEvent (..)
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
    , edgeInsertActive
    , edgeUpdateTerminal
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

{- | The two pins a registry identity carries (#157 genesis-policy-pins), derived
from the naming partition's own compiled code: the application validator
for the approval, and @witness(1, registry)@ for the active token.

The registry id the witness policies are parameterized by depends on the
state script hash and the boot seed, so this takes them directly rather
than a configuration that does not exist yet.
-}
namingPins
    :: NamingCodes
    -> ByteString
    -- ^ The registry id: state script hash then boot token name
    -> (SBS.ShortByteString, SBS.ShortByteString)
    -- ^ Application, active
namingPins codes registryId =
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

{- | Publish this cage's scripts as reference outputs: the cage, the
request validator and the active token policy.
-}
publishCageRefs
    :: CageConfig
    -> NamingCodes
    -> (Cage.Network, Cage.LedgerProvider Cage.NoWitness IO)
    -> SubmitSigned
    -> Addr
    -> TokenId
    -> IO [(TxIn, TxOut ConwayEra)]
publishCageRefs cfg codes prov submit payerAddr tokenId =
    mapM
        (publishRefScript prov submit payerAddr)
        ( [ mkCageScript cfg
          , mkRequestScript cfg tokenId
          ]
            <> map (witnessScriptOf cfg codes) [1]
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
    in  if edge == edgeInsertActive
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
    | edge /= edgeInsertActive && edge /= edgeUpdateTerminal = Nothing
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
    -> (Cage.Network, Cage.LedgerProvider Cage.NoWitness IO)
    -> SubmitSigned
    -> Addr
    -> TokenId
    -> ByteString
    -> Edge
    -> IO TxIn
bookEdge cfg codes prov submit payerAddr tokenId key edge =
    bookEdgeTo
        cfg
        codes
        prov
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
    -> (Cage.Network, Cage.LedgerProvider Cage.NoWitness IO)
    -> SubmitSigned
    -> Addr
    -> TokenId
    -> ByteString
    -> Edge
    -> (ByteString, Maybe PLC.Data)
    -> IO TxIn
bookEdgeTo cfg codes prov submit payerAddr tokenId key edge dest = do
    signed <-
        bookEdgeWith
            cfg
            prov
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
    -> (Cage.Network, Cage.LedgerProvider Cage.NoWitness IO)
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
bookEdgeWith cfg prov submit payerAddr tokenId key edge dest deposit approval =
    Cage.withLatest
        prov
        ( \v -> bookEdgeTx cfg v payerAddr tokenId key edge dest deposit approval
        )
        >>= submit

{- | The unsigned booking of one edge, built from one view: the payer's
largest ada-only output pays the bond, the fee and the change.
-}
bookEdgeTx
    :: CageConfig
    -> Cage.Session Cage.NoWitness IO
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
    pp <- Cage.parameters v
    utxos <- Cage.outputsAt v payerAddr
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
    when (edge /= edgeInsertActive && edge /= edgeUpdateTerminal) $
        error
            ( "bookEdge: edge "
                <> show edge
                <> " on key "
                <> show key
                <> " is not supported by M1 (expected insertActive or updateTerminal)"
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
    -> Cage.Session Cage.NoWitness IO
    {- ^ The one acquired view the booking is built, measured and certified
    from: its protocol parameters are the ones the caller reports and judges
    its outlay under, and nothing is submitted while it is held
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
bookEdgeMeasured cfg v payerAddr tokenId key edge dest deposit approval refs chosen =
    timedTrace
        (Cage.sessionTracer v)
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
    -> Cage.Session Cage.NoWitness IO
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
    pp <- Cage.parameters v
    utxos <- Cage.outputsAt v payerAddr
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

{- | What a fold of tree edges needs in hand: the active token policy
this registry pins, the cage script custody spends run, the cage's own
UTxOs, the one destination datum a booking binds, and the reference
outputs the fold's scripts resolve through.
-}
registryContextFor
    :: CageConfig
    -> NamingCodes
    -> Cage.Session Cage.NoWitness IO
    -> [(TxIn, TxOut ConwayEra)]
    -> IO RegistryContext
registryContextFor cfg codes v refs = do
    utxos <- Cage.outputsAt v (cageAddrFromCfg cfg (network cfg))
    pure
        emptyRegistryContext
            { rcWitnessScripts =
                Map.fromList [(k, witnessScriptOf cfg codes k) | k <- [1]]
            , rcCageScript = Just (mkCageScript cfg)
            , rcCageUtxos = utxos
            , rcRefUtxos = refs
            }
