{- |
Module      : Singular.Registry.TxBuilder.Update.Context
Description : Fold context preparation — queries, proofs, state and slot
License     : Apache-2.0

Everything a fold must know or decide before it can be built: the registry
context a caller hands in (and its empty value), the queries that find the
fold's inputs (the state output, the pending requests by their request-policy
tag, the funding output), the selection of the pending requests the fold
settles and the remainder it leaves pending, and the guard on the built
fold's window. Pending requests are discovered by the request policy alone,
through the acquired session: nothing is discovered by reading the request
address, and an output at that address that does not hold its own tag is no
request.

This module owns no duty decisions and no transaction assembly; see
"Singular.Registry.TxBuilder.Update.Duties" and
"Singular.Registry.TxBuilder.Update.Build". The public surface stays
"Singular.Registry.TxBuilder.Update", which re-exports the context
types unchanged (#267).
-}
module Singular.Registry.TxBuilder.Update.Context
    ( RegistryContext (..)
    , HolderRelease (..)
    , emptyRegistryContext
    , queryContext
    , FoldLeaf
    , FoldPlan (..)
    , checkPending
    , planFold
    , computeUpperSlot
    , guardBuiltWindow
    ) where

import Control.Monad (when)
import Data.ByteString (ByteString)
import Data.List (intercalate, sortOn)
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map
import Data.Ord (Down (..))
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Time.Clock (getCurrentTime)
import Data.Time.Clock.POSIX
    ( utcTimeToPOSIXSeconds
    )
import Lens.Micro ((^.))
import PlutusCore.Data qualified as PLC

import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.Allegra.Scripts
    ( ValidityInterval (..)
    )
import Cardano.Ledger.Api.Tx (bodyTxL)
import Cardano.Ledger.Api.Tx.Body
    ( vldtTxBodyL
    )
import Cardano.Ledger.Api.Tx.Out
    ( TxOut
    , coinTxOutL
    , referenceScriptTxOutL
    , valueTxOutL
    )
import Cardano.Ledger.BaseTypes (StrictMaybe (..))
import Cardano.Ledger.Core (Script)
import Cardano.Ledger.Mary.Value
    ( MaryValue (..)
    , MultiAsset (..)
    )
import Cardano.Slotting.Slot (SlotNo (..))
import Cardano.Tx.Ledger (ConwayTx)

import Singular.Registry.Config
    ( CageConfig (..)
    )
import Singular.Registry.Evidence (NoWitness)
import Singular.Registry.FoldAdmission
    ( AdmissionRefusal (..)
    , admissionReason
    , admissionSource
    , foldAdmission
    )
import Singular.Registry.FoldSelection
    ( AppVerdict (..)
    , Exclusion (..)
    , Leaf (..)
    , MemberKind (..)
    , TaggedRequest (..)
    , TaggedSelection (..)
    , exclusionName
    , foldCapacity
    , selectTaggedFold
    )
import Singular.Registry.Ledger
    ( ConwayEra
    , TokenId
    , TxIn
    )
import Singular.Registry.LedgerProvider (Session, TipObservation (..))
import Singular.Registry.SessionIO (outputsAt)
import Singular.Registry.SessionIO qualified as Services
import Singular.Registry.TxBuilder.Internal.Identity
import Singular.Registry.TxBuilder.Internal.Lookup
import Singular.Registry.Types
    ( CageDatum (..)
    , OnChainRegistrationRequest (..)
    , OnChainRequest (..)
    , OnChainTokenState (..)
    )

{- | What a fold needs in hand to discharge the obligations. The fold of booked
requests reads 'rcWitnessScripts' and 'rcRefUtxos' only: it finds the script of
each policy the registry pins among the witness scripts (any key) and the
scripts the reference outputs carry. The other fields serve the pure
'Singular.Registry.TxBuilder.Update.Duties.registryDuties' calculator of legacy
edge-only requests, which no fold entry point calls: the cage script (custody
spends run it), the UTxOs sitting at the cage address (custody lives among them)
and the holders a burn may be sourced from. A delivered output's datum is the
one its request carries (#419), so nothing beyond the chain is in hand.
-}
data RegistryContext = RegistryContext
    { rcWitnessScripts :: Map.Map Integer (Script ConwayEra)
    , rcCageScript :: Maybe (Script ConwayEra)
    , rcCageUtxos :: [(TxIn, TxOut ConwayEra)]
    , rcAllowInadmissible :: Bool
    {- ^ Build a fold even when a request takes no admissible edge, so a
    row that exists to watch the chain REFUSE one can produce the
    transaction it submits. An honest builder leaves this off and
    fails early, naming the request.
    -}
    , rcHolderUtxos :: [(TxIn, TxOut ConwayEra)]
    {- ^ #177 I177-BUILDER: the candidate inputs a burn may be sourced
    from — the outputs that actually HOLD registry witnesses. A
    retirement or an active deletion destroys an asset it does not
    create, so the fold has to consume the holder's own UTxO; with
    nothing in this
    inventory the builder fails naming the key rather than emitting a
    mint the cage refuses `token-missing`. Left empty, the builder
    queries the fold's own wallet address.
    -}
    , rcHolderReleases :: Map.Map TxIn HolderRelease
    {- ^ #299: holders that sit at an application script rather than a
    key. A burn sourced from one of them spends it with the application's
    own witness instead of as a plain input, and the application's
    release is owed to its recipient together with every other
    obligation of the fold to that key. Empty for key-held witnesses.
    -}
    , rcRefUtxos :: [(TxIn, TxOut ConwayEra)]
    {- ^ Outputs carrying the fold's scripts as reference scripts. The
    state validator alone is fifteen kilobytes, so a fold that
    attaches it, the request script and a token policy does not fit
    in a transaction; with references every purpose resolves through
    them instead.
    -}
    }

{- | How an application-held burn source is spent, and what its spend
releases (#299): the redeemer and script that witness the spend, and the
lovelace owed to the recipient's key because the holder is released.
-}
data HolderRelease = HolderRelease
    { hrRedeemer :: PLC.Data
    , hrScript :: Script ConwayEra
    , hrRecipient :: ByteString
    -- ^ The payment key hash the release is owed to
    , hrReleased :: Integer
    -- ^ Lovelace owed to it, over every other obligation to that key
    }
    deriving stock (Eq, Show)

{- | The context a fold needs beyond the registry's own configuration: the
scripts of the token policies it pins. A delivered output's datum is the one its
request carries.

`emptyRegistryContext` carries none of it, which refuses loudly, naming the
missing policy, for a caller that folds a registration or a termination
without it.
-}
emptyRegistryContext :: RegistryContext
emptyRegistryContext =
    RegistryContext
        { rcWitnessScripts = Map.empty
        , rcCageScript = Nothing
        , rcCageUtxos = []
        , rcAllowInadmissible = False
        , rcHolderUtxos = []
        , rcHolderReleases = Map.empty
        , rcRefUtxos = []
        }

{- | Query the cage UTxOs for the state, the request policy for the pending
requests, and the wallet for the fee-paying output. A pending request is an
output the request policy vouches for ('pendingByTag'): the discovery reads no
address of the requests, so untagged outputs there are never seen, and a
listing that fails or comes back incomplete is the failure itself, never an
empty fold.
-}
queryContext
    :: CageConfig
    -> Session NoWitness IO
    -> TokenId
    -> Addr
    -> IO
        ( (TxIn, TxOut ConwayEra)
        , [(TxIn, TxOut ConwayEra)]
        , (TxIn, TxOut ConwayEra)
        )
queryContext cfg view tid addr = do
    stateUtxos <- outputsAt view (cageAddrFromCfg cfg (network cfg))
    stateUtxo <- case findStateUtxo (cagePolicyIdFromCfg cfg) tid stateUtxos of
        Nothing ->
            error
                "updateToken: state UTxO \
                \not found"
        Just x -> pure x
    pending <- pendingByTag cfg view tid
    walletUtxos <- outputsAt view addr
    -- #157: an approval is not burned at the fold, so it returns to the
    -- funder and rides in the wallet from then on. The fee input doubles
    -- as collateral, and collateral must be ada-only.
    feeUtxo <- case sortOn
        (Down . (^. coinTxOutL) . snd)
        (filter (adaOnlyOutput . snd) walletUtxos) of
        [] -> error "updateToken: no ada-only UTxO to fund the fold"
        (u : _) -> pure u
    pure (stateUtxo, pending, feeUtxo)

-- | What a key's leaf in the registry's trie says, as the selection reads it.
type FoldLeaf = Leaf

{- | The pending requests a fold settles, in the ledger's input order, and the
ones it leaves pending with the reason each is left.
-}
data FoldPlan = FoldPlan
    { planSettled :: [(TxIn, TxOut ConwayEra)]
    , planRemainder :: [((TxIn, TxOut ConwayEra), Exclusion)]
    }

{- | The refusals that need no trie: folding every pending request refuses an
empty pending set, and folding a chosen set names every chosen reference that
is not among the pending requests, at every live pending-set size including zero.
-}
checkPending
    :: Maybe (NE.NonEmpty TxIn) -> [(TxIn, TxOut ConwayEra)] -> IO ()
checkPending selected pending = case selected of
    Nothing -> when (null pending) $ error "updateToken: no pending requests"
    Just chosen ->
        case filter (`notElem` map fst pending) (NE.toList chosen) of
            [] -> pure ()
            missing ->
                error
                    ( "updateToken: selected requests not pending: "
                        <> show missing
                    )

{- | Choose what a fold settles among the pending requests. With no chosen
set, the library's tagged selection judges every pending request (its window,
the leaf of its key, one request per key) and settles the first ones up to the
capacity bound, leaving the others pending. With a chosen set, the chosen
requests are folded and no other: each must be pending, naming every one that
is not, and each must be foldable, naming every one that is not and why.
The judgement reads the processing window from the observed tip and the keys'
leaves from the trie the proofs come from.
-}
planFold
    :: CageConfig
    -> TokenId
    -> Session NoWitness IO
    -> TipObservation
    -- ^ The one observation of the tip this build is judged against
    -> Integer
    -- ^ The registry's processing time
    -> ([ByteString] -> IO (Map.Map ByteString FoldLeaf))
    -- ^ The leaf of each key, from the trie the proofs come from
    -> Maybe (NE.NonEmpty TxIn)
    -- ^ The pending requests to fold; every settleable one when absent
    -> [(TxIn, TxOut ConwayEra)]
    -- ^ The pending requests, in the ledger's input order
    -> IO FoldPlan
planFold cfg tid view observed process readLeaves selected pending = do
    checkPending selected pending
    let judged =
            [ (ref, out, booked)
            | (ref, out) <- pending
            , maybe True ((ref `elem`) . NE.toList) selected
            , Just booked <- [bookedRequestOf cfg tid out]
            ]
        keys = Set.toAscList (Set.fromList [bookedKey b | (_, _, b) <- judged])
        keyIndex = Map.fromList (zip keys [0 :: Int ..])
    leaves <- readLeaves keys
    now <- Services.slotStart view (observedSlot observed)
    let facts =
            Map.fromList
                [ (ix, (Map.findWithDefault LeafUnknown key leaves, False))
                | (key, ix) <- Map.toList keyIndex
                ]
        requests =
            [ TaggedRequest
                { tgRef = ix
                , tgKey = keyIndex Map.! bookedKey booked
                , tgKind = case booked of
                    BookedRegistration _ -> MemberRegistration
                    BookedTermination _ -> MemberTermination
                , tgSubmittedAt = case booked of
                    BookedRegistration r -> regSubmittedAt r
                    BookedTermination _ -> 0
                , tgCarried = AppReady
                }
            | (ix, (_, _, booked)) <- zip [0 ..] judged
            ]
        bound = maybe foldCapacity (const (length judged)) selected
        selection = selectTaggedFold bound now 0 process facts requests
        outputAt ix = case drop (tgRef ix) judged of
            (ref, out, _) : _ -> (ref, out)
            [] ->
                error "updateToken: the selection names a request it was not given"
        settled = map outputAt (taggedSettled selection)
        left = [(outputAt q, exc) | (q, exc) <- taggedExcluded selection]
        describe ((ref, _), exc) =
            show ref
                <> ": "
                <> T.unpack (exclusionName exc)
                <> " ("
                <> T.unpack (excDetail exc)
                <> ")"
    case selected of
        Just _
            | not (null left) ->
                error
                    ( "updateToken: selected requests cannot be folded: "
                        <> intercalate "; " (map describe left)
                    )
        Nothing
            | null settled ->
                error
                    ( "updateToken: no pending request can be folded: "
                        <> intercalate "; " (map describe left)
                    )
        _ -> pure (FoldPlan settled left)

-- | Compute the validity upper slot.
computeUpperSlot
    :: Session NoWitness IO
    -> OnChainTokenState
    -> [(TxIn, TxOut ConwayEra)]
    -> IO SlotNo
computeUpperSlot view oldState reqUtxos = do
    let extractSubmittedAt (_, rOut) =
            case extractCageDatum rOut of
                Just (RequestDatum r) ->
                    requestSubmittedAt r
                _ -> 0
        earliestDeadline =
            minimum $
                map
                    ( \u ->
                        extractSubmittedAt u
                            + stateProcessTime
                                oldState
                    )
                    reqUtxos
    mUpperSlot <- trySync (Services.floorSlot view earliestDeadline)
    candidate <- case mUpperSlot of
        Right s -> pure s
        Left _ -> do
            nowUtc <- getCurrentTime
            let posixSec =
                    utcTimeToPOSIXSeconds nowUtc
            tryUpperSlots view $
                map
                    ( \d ->
                        round
                            ((posixSec + d) * 1000)
                    )
                    [30, 5, 2]
    observed <- Services.tip view
    Services.validityUpper
        view
        (observedSlot observed)
        Nothing
        candidate

{- | Judge the built body's bound through the view by the library's
'foldAdmission', over the registrations the fold settles (each with the time
it was booked); a termination has no window. A missing or unconvertible bound
fails closed with client-policy wording, never a model refusal. Returns the
transaction it was given; the caller signs only after this passes.
-}
guardBuiltWindow
    :: String
    -> Session NoWitness IO
    -> Integer
    -> [(TxIn, Integer)]
    -> ConwayTx
    -> IO ConwayTx
guardBuiltWindow who view processTime windowed tx = do
    upperSlot <- case tx ^. bodyTxL . vldtTxBodyL of
        ValidityInterval _ (SJust u) -> pure u
        _ ->
            error
                ( who
                    <> ": the built fold carries no validity upper bound, \
                       \so nothing is signed"
                )
    boundStart <- trySync (Services.slotStart view upperSlot)
    boundMs <- case boundStart of
        Right ms -> pure ms
        Left _ ->
            error
                ( who
                    <> ": the built fold's upper bound, slot "
                    <> show (unSlotNo upperSlot)
                    <> ", converts to no time in this view, so nothing is signed"
                )
    case foldAdmission processTime boundMs windowed of
        Nothing -> pure ()
        Just refusal ->
            error
                ( who
                    <> ": the built fold is not signed: "
                    <> admissionReason
                    <> " ("
                    <> admissionSource
                    <> "): request "
                    <> show (refusalRef refusal)
                    <> " has processing deadline "
                    <> show (refusalDeadline refusal)
                    <> " ms, which the built bound "
                    <> show (refusalBound refusal)
                    <> " ms passes"
                )
    pure tx

{- | Can this output fund a fold? It must hold ada and nothing else,
because it doubles as collateral, and it must not be one of the published
reference outputs, because a transaction may not both spend an output and
reference it.
-}
adaOnlyOutput :: TxOut ConwayEra -> Bool
adaOnlyOutput out =
    (case out ^. valueTxOutL of MaryValue _ (MultiAsset m) -> Map.null m)
        && ( case out ^. referenceScriptTxOutL of
                SNothing -> True
                SJust _ -> False
           )
