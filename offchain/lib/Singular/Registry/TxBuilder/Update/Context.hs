{- |
Module      : Singular.Registry.TxBuilder.Update.Context
Description : Fold context preparation — queries, proofs, state and slot
License     : Apache-2.0

Everything a fold must know or prepare before it can decide anything:
the registry context a caller hands in (and its empty value), the
state/request/fee queries that find the fold's inputs, the ordered
speculative proofs through the trie, the state continuation output and
its script, the validity upper slot, and the completion of a partly
empty context from the provider.

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
    , completeContext
    , queryContext
    , computeProofs
    , prepareState
    , computeUpperSlot
    , guardSupportedEdges
    , guardSupportedEncodableEdges
    , guardBatchPair
    , guardMintMatch
    , guardBuiltWindow
    , guardBuiltFold
    ) where

import Control.Monad (when)
import Data.ByteString (ByteString)
import Data.ByteString.Short qualified as SBS
import Data.List (sortOn)
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map
import Data.Ord (Down (..))
import Data.Time.Clock (getCurrentTime)
import Data.Time.Clock.POSIX
    ( utcTimeToPOSIXSeconds
    )
import Lens.Micro ((&), (.~), (^.))
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
    , datumTxOutL
    , mkBasicTxOut
    , referenceScriptTxOutL
    , valueTxOutL
    )
import Cardano.Ledger.BaseTypes (StrictMaybe (..))
import Cardano.Ledger.Core (Script)
import Cardano.Ledger.Mary.Value
    ( AssetName (..)
    , MaryValue (..)
    , MultiAsset (..)
    , PolicyID
    )
import Cardano.Slotting.Slot (SlotNo (..))
import Cardano.Tx.Ledger (ConwayTx)

import Singular.Registry.Config
    ( CageConfig (..)
    )
import Singular.Registry.Evidence (NoWitness)
import Singular.Registry.FoldAdmission
    ( AdmissionRefusal (..)
    , BatchConsumption (..)
    , BatchEdge (..)
    , admissionReason
    , admissionSource
    , batchConsumesCreated
    , consumptionReason
    , consumptionSource
    , foldAdmission
    , mintReason
    , mintSource
    )
import Singular.Registry.Ledger
    ( ConwayEra
    , PParams
    , Root (..)
    , TokenId
    , TxIn
    )
import Singular.Registry.LedgerProvider (Session, TipObservation (..))
import Singular.Registry.SessionIO (outputsAt, parameters)
import Singular.Registry.SessionIO qualified as Services
import Singular.Registry.Trie
    ( Trie (..)
    , TrieManager (..)
    )
import Singular.Registry.TxBuilder.Internal.Edges
import Singular.Registry.TxBuilder.Internal.Identity
import Singular.Registry.TxBuilder.Internal.Lookup
import Singular.Registry.Types
    ( CageDatum (..)
    , OnChainRequest (..)
    , OnChainRoot (..)
    , OnChainTokenState (..)
    , ProofStep
    , edgeInsertActive
    , edgeUpdateTerminal
    )

{- | What a fold needs in hand to discharge the obligations: the three
token policies' scripts by kind, the cage script (custody spends run it),
and the UTxOs sitting at the cage address (custody lives among them). A
delivered output's datum is the one its request carries (#419), so nothing
beyond the chain is in hand.
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

{- | The context a fold of tree edges needs beyond the registry's own
configuration: the three token policies' scripts and the cage script that
custody spends run. A delivered output's datum is the one its request
carries.

`emptyRegistryContext` carries none of it, which is right for a caller
that folds only rejections — and refuses loudly, naming the missing
script, for one that folds an edge without it.
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

{- | Complete a context the caller left partly empty: the cage's own
UTxOs and the fold's holder inventory are queried from the provider
when the caller did not supply them, and the cage script defaults to
the one this build's own state continuation runs. The caller-supplied
value always wins; only an omission triggers a query (#267: moved
verbatim from the facade's inline completion).
-}
completeContext
    :: CageConfig
    -> Session NoWitness IO
    -> Addr
    -> Script ConwayEra
    -> RegistryContext
    -> IO RegistryContext
completeContext cfg view addr script ctx0 = do
    -- The cage's own UTxOs are where custody sits; the caller need not
    -- have queried them, and the cage script is this build's own.
    cageUtxos <-
        if null (rcCageUtxos ctx0)
            then outputsAt view (cageAddrFromCfg cfg (network cfg))
            else pure (rcCageUtxos ctx0)
    -- #177 I177-BUILDER: the candidate burn sources. A retirement or a
    -- deletion of an active key destroys an asset it does not create,
    -- so the fold has to consume the UTxO that HOLDS it; left unset,
    -- the inventory is the fold's own wallet, which is where
    -- `insertActive` delivered it.
    holderUtxos <-
        if null (rcHolderUtxos ctx0)
            then outputsAt view addr
            else pure (rcHolderUtxos ctx0)
    pure
        ctx0
            { rcCageUtxos = cageUtxos
            , rcHolderUtxos = holderUtxos
            , rcCageScript = case rcCageScript ctx0 of
                Just s -> Just s
                Nothing -> Just script
            }

{- | Query cage UTxOs, find the state and request
UTxOs, pick a fee-paying wallet UTxO.

The pending-request query takes the chosen set: folding every pending
request (absent selection) still refuses an empty pending set with the
long-standing generic error, while folding a chosen set returns whatever
is pending (possibly none) so the caller can name every chosen reference
that is not among them, at every live pending-set size including zero.
-}
queryContext
    :: Maybe (NE.NonEmpty TxIn)
    -> CageConfig
    -> Session NoWitness IO
    -> TokenId
    -> Addr
    -> IO
        ( (TxIn, TxOut ConwayEra)
        , [(TxIn, TxOut ConwayEra)]
        , (TxIn, TxOut ConwayEra)
        , PParams ConwayEra
        )
queryContext selected cfg view tid addr = do
    let stateAddr =
            cageAddrFromCfg cfg (network cfg)
        reqAddr =
            requestAddrFromCfg cfg tid (network cfg)
    stateUtxos <- outputsAt view stateAddr
    requestUtxos <- outputsAt view reqAddr
    let policyId = cagePolicyIdFromCfg cfg
    stateUtxo <- case findStateUtxo
        policyId
        tid
        stateUtxos of
        Nothing ->
            error
                "updateToken: state UTxO \
                \not found"
        Just x -> pure x
    let reqUtxos =
            sortOn fst $
                findRequestUtxos tid requestUtxos
    case selected of
        Nothing ->
            when (null reqUtxos) $
                error "updateToken: no pending requests"
        Just _ -> pure ()
    pp <- parameters view
    walletUtxos <- outputsAt view addr
    -- #157: an approval is not burned at the fold, so it returns to the
    -- funder and rides in the wallet from then on. The fee input doubles
    -- as collateral, and collateral must be ada-only.
    feeUtxo <- case sortOn
        (Down . (^. coinTxOutL) . snd)
        (filter (adaOnlyOutput . snd) walletUtxos) of
        [] -> error "updateToken: no ada-only UTxO to fund the fold"
        (u : _) -> pure u
    pure (stateUtxo, reqUtxos, feeUtxo, pp)

{- | Run speculative trie operations to compute
proofs and the new root hash.
-}
computeProofs
    :: TrieManager IO
    -> TokenId
    -> [(TxIn, TxOut ConwayEra)]
    -> IO ([[ProofStep]], Root)
computeProofs tm tid reqUtxos =
    withSpeculativeTrie tm tid $ \trie -> do
        ps <- mapM (processRequest trie) reqUtxos
        r <- getRoot trie
        pure (ps, r)

{- | Extract old state, build new state output,
cage script, and owner key hash.
-}
prepareState
    :: CageConfig
    -> TxOut ConwayEra
    -> Root
    -> (OnChainTokenState, TxOut ConwayEra, Script ConwayEra)
prepareState cfg stateOut newRoot =
    let scriptAddr =
            cageAddrFromCfg cfg (network cfg)
        oldState =
            case extractCageDatum stateOut of
                Just (StateDatum s) -> s
                _ ->
                    error
                        "updateToken: invalid \
                        \state datum"
        newStateDatum =
            StateDatum
                oldState
                    { stateRoot =
                        OnChainRoot
                            (unRoot newRoot)
                    }
        newStateOut =
            mkBasicTxOut
                scriptAddr
                (stateOut ^. valueTxOutL)
                & datumTxOutL
                    .~ mkInlineDatum
                        (toPlcData newStateDatum)
        script = mkCageScript cfg
    in  (oldState, newStateOut, script)

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

{- | One included request as the model's admission checks read it: the
output reference, the submission time from its datum, the key, and the
edge mapped to what the within-batch check reads (an insertion creates
the key's active holding, a termination burns one, any other edge is
neither). Outputs carrying no request datum never reach the checks: the
proofs refuse them first.
-}
admissionInputs
    :: [(TxIn, TxOut ConwayEra)] -> [(TxIn, Integer, ByteString, BatchEdge)]
admissionInputs reqUtxos =
    [ ( ref
      , requestSubmittedAt req
      , requestKey req
      , toBatchEdge (requestEdge req)
      )
    | (ref, out) <- reqUtxos
    , Just (RequestDatum req) <- [extractCageDatum out]
    ]
  where
    toBatchEdge e
        | e == edgeInsertActive = BatchInsert
        | e == edgeUpdateTerminal = BatchTerminate
        | otherwise = BatchOther

{- | Refuse after the proofs a batch naming an edge outside the
permanent contract (#519): the model's fixed edge set comes first among
model checks, so an excluded edge is refused here, in the duties' words,
before the window, the steps, the keyed mint or the within-batch scan.
The caller runs 'guardSupportedEncodableEdges' before the proofs and this
full guard after, so the snapshot's speculative refusal for an
undecodable edge (for example `EdgeOutOfRange`) keeps its printed name
while an excluded encodable edge still reports here, never as a missing
proof or as the pair.
-}
guardSupportedEdges :: String -> [(TxIn, TxOut ConwayEra)] -> IO ()
guardSupportedEdges who reqUtxos =
    case [ (ref, key, edge)
         | (ref, out) <- reqUtxos
         , Just (RequestDatum req) <- [extractCageDatum out]
         , let key = requestKey req
         , let edge = requestEdge req
         , edge /= edgeInsertActive && edge /= edgeUpdateTerminal
         ] of
        [] -> pure ()
        ((ref, key, edge) : _) ->
            error
                ( who
                    <> ": edge "
                    <> show edge
                    <> " on key "
                    <> show key
                    <> " is not supported by M1 (expected insertActive or updateTerminal): request "
                    <> show ref
                )

{- | Refuse before the proofs a batch naming an encodable edge outside the
permanent contract (#519): an excluded edge in `0..6` except `1` and `3`
is refused here, before the proofs run, so it reports here rather than as
a missing proof or as the pair. An undecodable edge (outside `0..6`)
passes through so the snapshot's speculative refusal keeps its printed
name; the full 'guardSupportedEdges' after the proofs catches it on paths
whose proofs cannot fail it.
-}
guardSupportedEncodableEdges
    :: String -> [(TxIn, TxOut ConwayEra)] -> IO ()
guardSupportedEncodableEdges who reqUtxos =
    case [ (ref, key, edge)
         | (ref, out) <- reqUtxos
         , Just (RequestDatum req) <- [extractCageDatum out]
         , let key = requestKey req
         , let edge = requestEdge req
         , edge >= 0 && edge <= 6
         , edge /= edgeInsertActive && edge /= edgeUpdateTerminal
         ] of
        [] -> pure ()
        ((ref, key, edge) : _) ->
            error
                ( who
                    <> ": edge "
                    <> show edge
                    <> " on key "
                    <> show key
                    <> " is not supported by M1 (expected insertActive or updateTerminal): request "
                    <> show ref
                )

{- | Refuse before any proof or build work a batch that terminates a key
an earlier insertion of the same batch created (#519): the library's
'batchConsumesCreated' over the included requests in input order, naming
the terminating request and the key in the model's words. An honest
caller never assembles such a batch — the selection leaves a second
request on an included key out — so this fires only on a directly
chosen set, before anything is signed.
-}
guardBatchPair :: String -> [(TxIn, TxOut ConwayEra)] -> IO ()
guardBatchPair who reqUtxos =
    case batchConsumesCreated
        [ (ref, key, edge)
        | (ref, _, key, edge) <- admissionInputs reqUtxos
        ] of
        Nothing -> pure ()
        Just consumption ->
            error
                ( who
                    <> ": refusing to sign a batch that consumes what it creates: "
                    <> consumptionReason
                    <> " ("
                    <> consumptionSource
                    <> "): request "
                    <> show (consumptionRef consumption)
                    <> " terminates key "
                    <> show (consumptionKey consumption)
                )

{- | Re-check a built fold against the model's admission reading the bound
from the built body (#519): the body's validity upper slot converted to
its start time through the view, judged with the registry's processing
time by the library's 'foldAdmission' over the included requests in input
order, then the within-batch check again, defensively. A missing or
unconvertible bound fails closed with client-policy wording, never a
model refusal. Returns the transaction it was given; the caller signs
only after this passes.
-}
guardBuiltFold
    :: String
    -> Session NoWitness IO
    -> Integer
    -> [(TxIn, TxOut ConwayEra)]
    -> ConwayTx
    -> IO ConwayTx
guardBuiltFold who view processTime reqUtxos tx = do
    windowed <- guardBuiltWindow who view processTime reqUtxos tx
    guardBatchPair who reqUtxos
    pure windowed

{- | The window half of 'guardBuiltFold': judge the built body's bound
through the view by the library's 'foldAdmission'. A caller that must
judge further model checks between the window and the pair (the
skip-evaluation mode's keyed mint check) calls this, then its checks,
then 'guardBatchPair'.
-}
guardBuiltWindow
    :: String
    -> Session NoWitness IO
    -> Integer
    -> [(TxIn, TxOut ConwayEra)]
    -> ConwayTx
    -> IO ConwayTx
guardBuiltWindow who view processTime reqUtxos tx = do
    let inputs = admissionInputs reqUtxos
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
    case foldAdmission
        processTime
        boundMs
        [(ref, submittedAt) | (ref, submittedAt, _, _) <- inputs] of
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

{- | Refuse ahead of the pair scan a batch whose supplied mints differ from
the keyed delta of its edges (#519, skip-evaluation mode only): every
insertion owes one active token for its key, every termination burns one,
any other edge owes nothing, the edge guard having run first. Compared per
(policy, asset name) with a missing entry equal to zero, as the model's
per-asset mint check, and ranged over the registry's own token policies
only: a mint under any other policy is attached application business and
neither counts toward nor causes a mint refusal, as the chain checks mint
only under its own token policies. So auditor-6's
scenario (a created pair beside a further insertion with no mints
supplied) prints 'net-mint-mismatch' before any pair scan runs.
-}
guardMintMatch
    :: String
    -> CageConfig
    -> [(TxIn, TxOut ConwayEra)]
    -> [(PolicyID, AssetName, Integer)]
    -> IO ()
guardMintMatch who cfg reqUtxos claimed =
    if strip (summed [t | t@(p, _, _) <- claimed, p `elem` registryPids])
        == strip actual
        then pure ()
        else
            error
                ( who
                    <> ": the batch's claimed mint differs from its edges' keyed delta: "
                    <> mintReason
                    <> " ("
                    <> mintSource
                    <> ")"
                )
  where
    pid = policyIdFromPin (cfgActivePolicy cfg)
    registryPids =
        [ policyIdFromPin pin
        | pin <-
            [cfgActivePolicy cfg, cfgAbsentPolicy cfg, cfgTerminalPolicy cfg]
        ]
    strip = Map.filter (/= 0)
    summed triples =
        Map.fromListWith
            (+)
            [((p, a), q) | (p, a, q) <- triples]
    actual =
        summed
            [ (pid, AssetName (SBS.toShort key), delta)
            | (_, out) <- reqUtxos
            , Just (RequestDatum req) <- [extractCageDatum out]
            , let delta = case requestEdge req of
                    e | e == edgeInsertActive -> 1
                    e | e == edgeUpdateTerminal -> -1
                    _ -> 0
            , delta /= 0
            , let key = requestKey req
            ]

-- | Process a single request.
processRequest
    :: (Monad m)
    => Trie m
    -> (TxIn, TxOut ConwayEra)
    -> m [ProofStep]
processRequest trie (_txIn, txOut) =
    walkEdge trie (requestKey req) (requestEdge req)
  where
    req = case extractCageDatum txOut of
        Just (RequestDatum r) -> r
        _ ->
            error
                "processRequest: \
                \invalid request datum"

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
