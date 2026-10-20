{- |
Module      : Singular.Registry.FoldSelection
Description : Pure fold selection over pending requests (#518)
License     : Apache-2.0

Pull request 1 of #518 judges every pending request alone and settles one
per fold. This module is the pure selection: it takes the pending requests,
the live facts, the clock and a capacity bound as arguments and returns, for
every pending request, exactly one of settled or excluded-with-reason. It
reads no file, no clock and no provider, and imports no command-line module
and no application module, so both the command line and the conformance suite
can use it.

The seven checks run in the spec's order; the first one a request fails
names its reason:

1. it decodes as a request, otherwise @undecodable@
2. its edge is one the model admits, otherwise @edge-inadmissible@
3. its processing window admits the probe bound under the registry's
   processing time, otherwise @not-phase1@
4. the model's approval check accepts it, otherwise @no-approval@ or
   @approval-mismatch@
5. the model's leaf check accepts it from the live state, otherwise
   @key-exists@, @token-missing@, @key-unknown@, @not-booked@ or
   @terminal-immutable@
6. the application step's verdict carried on the request is ready, otherwise
   @application-datum-unreadable@ or @application-required@
7. no earlier included request names the same key, otherwise @key-in-batch@

Requests that pass all seven keep ledger input order; the first ones up to
the capacity bound are settled and each remaining one is named @capacity@.
The window rule is the model's admission at the probe bound the folder
would build under, the clock plus the fold margin: a bound past the
request's deadline is refused @not-phase1@ with the deadline and the
probe bound, and a bound equal to the deadline admits. The approval and
leaf checks follow the model's refusal order: excluded edges first, then
admission, then approval, then the leaf from the live state.
-}
module Singular.Registry.FoldSelection
    ( EdgeKind (..)
    , Leaf (..)
    , ApprovalCheck (..)
    , AppVerdict (..)
    , PendingRequest (..)
    , SelectedRequest (..)
    , Reason (..)
    , Exclusion (..)
    , Selection (..)
    , LiveFacts
    , selectFold
    , MemberKind (..)
    , TaggedRequest (..)
    , TaggedSelection (..)
    , selectTaggedFold
    , judgeAlone
    , foldCapacity
    , foldCapacityProvenance
    , exclusionName
    , exclusionSource
    ) where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T

import Singular.Registry.FoldAdmission
    ( foldAdmission
    , refusalBound
    , refusalDeadline
    )

{- | The edge a pending request names. Only the two edges the model admits
settle; any other edge is refused @edge-inadmissible@.
-}
data EdgeKind
    = EdgeInsertActive
    | EdgeUpdateTerminal
    | EdgeOther Text
    deriving stock (Eq, Show)

-- | The live leaf for a key, read from the registry state before the decision.
data Leaf
    = LeafUnknown
    | LeafAbsent
    | LeafActive
    | LeafTerminal
    deriving stock (Eq, Show)

{- | The model's approval check, decided by the caller from the live state:
a missing approval, an approval under another policy (both @no-approval@),
an approval whose tuple does not match (@approval-mismatch@), or a match.
-}
data ApprovalCheck
    = ApprovalMissing
    | ApprovalPolicyMismatch
    | ApprovalTupleMismatch
    | ApprovalOk
    deriving stock (Eq, Show)

{- | The application step's verdict, asked through the application value and
carried on the pending request: the settlement inputs are ready, the
carried datum does not read, or the value carries no holding rules for a
termination, naming the application's executable.
-}
data AppVerdict
    = AppReady
    | AppDatumUnreadable
    | AppRequired Text
    deriving stock (Eq, Show)

{- | One pending request with everything the seven checks need. The
application verdict arrives as a field, like the decode verdict does: the
selection never calls the application value.
-}
data PendingRequest = PendingRequest
    { prRef :: Int
    , prKey :: Int
    , prOwner :: Text
    , prEdge :: EdgeKind
    , prDeadline :: Integer
    , prSubmittedAt :: Integer
    , prDecodeOk :: Bool
    , prApproval :: ApprovalCheck
    , prApp :: AppVerdict
    }
    deriving stock (Eq, Show)

-- | A request that passed all seven checks.
data SelectedRequest = SelectedRequest
    { selRef :: Int
    , selKey :: Int
    , selOwner :: Text
    , selEdge :: EdgeKind
    , selDeadline :: Integer
    }
    deriving stock (Eq, Show)

{- | Every exclusion reason: nine model refusals in the model's own words,
five selection-policy reasons of the processor.
-}
data Reason
    = ReasonEdgeInadmissible
    | ReasonNoApproval
    | ReasonApprovalMismatch
    | ReasonKeyExists
    | ReasonTokenMissing
    | ReasonKeyUnknown
    | ReasonNotBooked
    | ReasonTerminalImmutable
    | ReasonUndecodable
    | ReasonNotPhase1
    | ReasonAppDatumUnreadable
    | ReasonAppRequired
    | ReasonKeyInBatch
    | ReasonCapacity
    deriving stock (Eq, Show, Enum, Bounded)

{- | Why a pending request is left out: its reason and a detail text. The
detail of @application-required@ names the application's executable.
-}
data Exclusion = Exclusion
    { excReason :: Reason
    , excDetail :: Text
    }
    deriving stock (Eq, Show)

{- | The selection: the settled requests and the excluded requests, each in
ledger input order, with the capacity bound used and its provenance.
-}
data Selection = Selection
    { selectionSettled :: [SelectedRequest]
    , selectionExcluded :: [(PendingRequest, Exclusion)]
    , selectionBound :: Int
    , selectionProvenance :: Text
    }
    deriving stock (Eq, Show)

{- | The live facts: per key, the leaf and whether a live output holds the
key's one active token.
-}
type LiveFacts = Map Int (Leaf, Bool)

{- | The capacity bound of a fold: nine requests per fold, an estimate
under preprod's execution budget of 14 million memory units, bound by
trie-proof verification. The number is not measured under preprod parameters.
-}
foldCapacity :: Int
foldCapacity = 9

-- | an estimate, not a measurement: about nine requests fit in a fold under preprod's execution budget of 14 million memory units, bound by trie-proof verification
foldCapacityProvenance :: Text
foldCapacityProvenance =
    "an estimate, not a measurement: about nine requests fit in a fold under preprod's execution budget of 14 million memory units, bound by trie-proof verification"

-- | The reason's name in the receipt's vocabulary.
exclusionName :: Exclusion -> Text
exclusionName exc = case excReason exc of
    ReasonEdgeInadmissible -> "edge-inadmissible"
    ReasonNoApproval -> "no-approval"
    ReasonApprovalMismatch -> "approval-mismatch"
    ReasonKeyExists -> "key-exists"
    ReasonTokenMissing -> "token-missing"
    ReasonKeyUnknown -> "key-unknown"
    ReasonNotBooked -> "not-booked"
    ReasonTerminalImmutable -> "terminal-immutable"
    ReasonUndecodable -> "undecodable"
    ReasonNotPhase1 -> "not-phase1"
    ReasonAppDatumUnreadable -> "application-datum-unreadable"
    ReasonAppRequired -> "application-required"
    ReasonKeyInBatch -> "key-in-batch"
    ReasonCapacity -> "capacity"

{- | Which vocabulary the reason belongs to: a refusal of the model or the
processor's own selection policy.
-}
exclusionSource :: Exclusion -> Text
exclusionSource exc = case excReason exc of
    ReasonEdgeInadmissible -> "model-refusal"
    ReasonNoApproval -> "model-refusal"
    ReasonApprovalMismatch -> "model-refusal"
    ReasonKeyExists -> "model-refusal"
    ReasonTokenMissing -> "model-refusal"
    ReasonKeyUnknown -> "model-refusal"
    ReasonNotBooked -> "model-refusal"
    ReasonTerminalImmutable -> "model-refusal"
    ReasonUndecodable -> "selection-policy"
    ReasonNotPhase1 -> "model-refusal"
    ReasonAppDatumUnreadable -> "selection-policy"
    ReasonAppRequired -> "selection-policy"
    ReasonKeyInBatch -> "selection-policy"
    ReasonCapacity -> "selection-policy"

-- | Whether the edge is one the model admits.
isAdmittedEdge :: EdgeKind -> Bool
isAdmittedEdge EdgeInsertActive = True
isAdmittedEdge EdgeUpdateTerminal = True
isAdmittedEdge (EdgeOther _) = False

{- | Judge one request alone against the live facts: the six per-request
checks in the spec's order. No argument names any other pending request, so
a request's verdict never depends on requests on other keys. The seventh
check, 'ReasonKeyInBatch', needs the earlier verdicts and runs in
'selectFold'. The window check is the library's 'foldAdmission' at the
probe bound the folder would build under (the clock plus the fold margin)
with the registry's processing time: a bound past the request's deadline
is refused 'not-phase1' with the deadline and the probe bound, and a bound
equal to the deadline admits, as the model and the chain admit it.
-}
judgeAlone
    :: Integer
    -> Integer
    -> Integer
    -> LiveFacts
    -> PendingRequest
    -> Either Exclusion SelectedRequest
judgeAlone now margin process facts req
    | not (prDecodeOk req) =
        Left
            (Exclusion ReasonUndecodable "the output does not decode as a request")
    | not (isAdmittedEdge (prEdge req)) =
        Left
            ( Exclusion
                ReasonEdgeInadmissible
                "the edge is not one the model admits"
            )
    | otherwise = case foldAdmission
        process
        (now + margin)
        [(prRef req, prSubmittedAt req)] of
        Just refusal ->
            Left
                ( Exclusion
                    ReasonNotPhase1
                    ( T.pack
                        ( "the request's processing deadline, "
                            <> show (refusalDeadline refusal)
                            <> " ms, is before the probe bound "
                            <> show (refusalBound refusal)
                            <> " ms the fold would build under: no fold is built"
                        )
                    )
                )
        Nothing -> case prApproval req of
            ApprovalMissing ->
                Left (Exclusion ReasonNoApproval "the request carries no approval")
            ApprovalPolicyMismatch ->
                Left
                    (Exclusion ReasonNoApproval "the approval is under another policy")
            ApprovalTupleMismatch ->
                Left
                    ( Exclusion
                        ReasonApprovalMismatch
                        "the approval does not match the request"
                    )
            ApprovalOk ->
                judgeLeaf
                    (Map.findWithDefault (LeafUnknown, False) (prKey req) facts)
                    req

{- | The model's leaf check from the live facts. A key the facts never
mention reads unknown, like a fresh key. The admitted edge is already
established, so the remaining 'EdgeOther' arm cannot fire.
-}
judgeLeaf
    :: (Leaf, Bool) -> PendingRequest -> Either Exclusion SelectedRequest
judgeLeaf (leaf, tokenPresent) req = case prEdge req of
    EdgeInsertActive
        | leaf == LeafUnknown -> judgeApp req
        | otherwise ->
            Left (Exclusion ReasonKeyExists "the key is already booked")
    EdgeUpdateTerminal -> case leaf of
        LeafUnknown -> Left (Exclusion ReasonKeyUnknown "the key is unknown")
        LeafAbsent -> Left (Exclusion ReasonNotBooked "the key is not booked")
        LeafTerminal -> Left (Exclusion ReasonTerminalImmutable "the key is terminal")
        LeafActive
            | tokenPresent -> judgeApp req
            | otherwise ->
                Left
                    ( Exclusion
                        ReasonTokenMissing
                        "no live output holds the key's active token"
                    )
    EdgeOther _ ->
        Left
            ( Exclusion
                ReasonEdgeInadmissible
                "the edge is not one the model admits"
            )

{- | The sixth check: place the application step's verdict, which arrives as
a field of the pending request, after the model's leaf check.
-}
judgeApp :: PendingRequest -> Either Exclusion SelectedRequest
judgeApp req = case prApp req of
    AppDatumUnreadable ->
        Left
            (Exclusion ReasonAppDatumUnreadable "the carried datum does not read")
    AppRequired exe ->
        Left
            ( Exclusion
                ReasonAppRequired
                ("the value carries no holding rules; settle with " <> exe)
            )
    AppReady ->
        Right
            ( SelectedRequest
                (prRef req)
                (prKey req)
                (prOwner req)
                (prEdge req)
                (prDeadline req)
            )

{- | Judge every pending request alone, keep ledger input order, and settle
the first included requests up to the capacity bound. The only cross-request
rule is the seventh check, which reads earlier included requests of the same
key; the capacity cut runs after every request has its own verdict. Both
lists keep ledger input order.
-}
selectFold
    :: Int
    -> Integer
    -> Integer
    -> Integer
    -> LiveFacts
    -> [PendingRequest]
    -> Selection
selectFold bound now margin process facts reqs =
    Selection settled excluded bound foldCapacityProvenance
  where
    judged :: [(PendingRequest, Either Exclusion SelectedRequest)]
    judged = [(req, judgeAlone now margin process facts req) | req <- reqs]

    deduped :: [(PendingRequest, Either Exclusion SelectedRequest)]
    deduped = go Set.empty judged
      where
        go _ [] = []
        go seen ((req, verdict) : rest) = case verdict of
            Left exc -> (req, Left exc) : go seen rest
            Right sel
                | selKey sel `Set.member` seen ->
                    ( req
                    , Left
                        ( Exclusion
                            ReasonKeyInBatch
                            "an earlier included request names the same key"
                        )
                    )
                        : go seen rest
                | otherwise ->
                    (req, Right sel) : go (Set.insert (selKey sel) seen) rest

    settledRefs :: Set.Set Int
    settledRefs =
        Set.fromList
            (take (max 0 bound) [selRef sel | (_, Right sel) <- deduped])

    settled :: [SelectedRequest]
    settled =
        [sel | (_, Right sel) <- deduped, selRef sel `Set.member` settledRefs]

    excluded :: [(PendingRequest, Exclusion)]
    excluded =
        [ (req, exc)
        | (req, verdict) <- deduped
        , Just exc <- [toExclusion verdict]
        ]
      where
        toExclusion (Left exc) = Just exc
        toExclusion (Right sel)
            | selRef sel `Set.member` settledRefs = Nothing
            | otherwise =
                Just
                    ( Exclusion
                        ReasonCapacity
                        "the fold is at its capacity bound; the next fold takes this request"
                    )

-- ---------------------------------------------------------
-- Tagged members (the checkpoint's boundary)
-- ---------------------------------------------------------

{- | What a tagged pending request is: a registration, which folds only inside
its processing window, or a termination, which has no window.
-}
data MemberKind
    = MemberRegistration
    | MemberTermination
    deriving stock (Eq, Show)

{- | One tagged pending request with what the selection needs: its position in
ledger input order, its key, its kind, a registration's booked time and the
verdict on a registration's delivered datum. Authenticity is not here: only
requests the consumer has authenticated reach the selection.
-}
data TaggedRequest = TaggedRequest
    { tgRef :: Int
    , tgKey :: Int
    , tgKind :: MemberKind
    , tgSubmittedAt :: Integer
    -- ^ The booked time of a registration; a termination has none to read
    , tgCarried :: AppVerdict
    -- ^ Whether a registration's delivered datum reads; a termination delivers none
    }
    deriving stock (Eq, Show)

-- | The tagged selection: settled and excluded requests, each in ledger input order.
data TaggedSelection = TaggedSelection
    { taggedSettled :: [TaggedRequest]
    , taggedExcluded :: [(TaggedRequest, Exclusion)]
    , taggedBound :: Int
    }
    deriving stock (Eq, Show)

{- | Judge every tagged pending request and settle the first included ones up
to the capacity bound. A registration is judged against its processing window
at the probe bound (the clock plus the fold margin), then the leaf of its key
(a key the registry knows is refused @key-exists@), then its carried datum; a
termination has no window and is judged against the leaf alone (@key-unknown@,
@not-booked@, @terminal-immutable@), needing no live holder and no datum. A
request whose key an earlier included request already names is refused
@key-in-batch@, and the requests beyond the bound @capacity@. Both lists keep
ledger input order. Only the reasons of the model's two kinds are named: no
approval, edge or live token is judged.
-}
selectTaggedFold
    :: Int
    -> Integer
    -> Integer
    -> Integer
    -> LiveFacts
    -> [TaggedRequest]
    -> TaggedSelection
selectTaggedFold bound now margin process facts reqs =
    TaggedSelection settled excluded bound
  where
    judged = [(req, judgeTagged now margin process facts req) | req <- reqs]

    deduped :: [(TaggedRequest, Either Exclusion TaggedRequest)]
    deduped = go Set.empty judged
      where
        go _ [] = []
        go seen ((req, verdict) : rest) = case verdict of
            Left exc -> (req, Left exc) : go seen rest
            Right ok
                | tgKey ok `Set.member` seen ->
                    ( req
                    , Left
                        ( Exclusion
                            ReasonKeyInBatch
                            "an earlier included request names the same key"
                        )
                    )
                        : go seen rest
                | otherwise ->
                    (req, Right ok) : go (Set.insert (tgKey ok) seen) rest

    settledRefs =
        Set.fromList
            (take (max 0 bound) [tgRef ok | (_, Right ok) <- deduped])

    settled = [ok | (_, Right ok) <- deduped, tgRef ok `Set.member` settledRefs]

    excluded =
        [ (req, exc)
        | (req, verdict) <- deduped
        , Just exc <- [toExclusion verdict]
        ]
      where
        toExclusion (Left exc) = Just exc
        toExclusion (Right ok)
            | tgRef ok `Set.member` settledRefs = Nothing
            | otherwise =
                Just
                    ( Exclusion
                        ReasonCapacity
                        "the fold is at its capacity bound; the next fold takes this request"
                    )

judgeTagged
    :: Integer
    -> Integer
    -> Integer
    -> LiveFacts
    -> TaggedRequest
    -> Either Exclusion TaggedRequest
judgeTagged now margin process facts req = case tgKind req of
    MemberRegistration -> case foldAdmission
        process
        (now + margin)
        [(tgRef req, tgSubmittedAt req)] of
        Just refusal ->
            Left
                ( Exclusion
                    ReasonNotPhase1
                    ( T.pack
                        ( "the request's processing deadline, "
                            <> show (refusalDeadline refusal)
                            <> " ms, is before the probe bound "
                            <> show (refusalBound refusal)
                            <> " ms the fold would build under: no fold is built"
                        )
                    )
                )
        Nothing
            | leaf /= LeafUnknown ->
                Left (Exclusion ReasonKeyExists "the key is already booked")
            | otherwise -> case tgCarried req of
                AppReady -> Right req
                AppDatumUnreadable ->
                    Left
                        ( Exclusion
                            ReasonAppDatumUnreadable
                            "the carried datum does not read"
                        )
                AppRequired exe ->
                    Left
                        ( Exclusion
                            ReasonAppRequired
                            ("the value carries no holding rules; settle with " <> exe)
                        )
    MemberTermination -> case leaf of
        LeafUnknown -> Left (Exclusion ReasonKeyUnknown "the key is unknown")
        LeafAbsent -> Left (Exclusion ReasonNotBooked "the key is not booked")
        LeafTerminal -> Left (Exclusion ReasonTerminalImmutable "the key is terminal")
        LeafActive -> Right req
  where
    (leaf, _) = Map.findWithDefault (LeafUnknown, False) (tgKey req) facts
