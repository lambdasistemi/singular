{- |
Module      : Singular.CLI.FoldRulesSpec
Description : The command-line rules for a fold that takes a selection (#518)
License     : Apache-2.0

Pull request 1 settles one request per fold, chosen by the pure selection
and built by the builder entry point. This suite pins the pure
command-line rules around that choice: the named-request guard, the
refusal that names every exclusion, the rule that several pending requests
never refuse on count, and the check that a built fold spends exactly the
selection. Every expected refusal text is rendered from the same exclusion
values the selection produced, never typed.
-}
module Singular.CLI.FoldRulesSpec (spec) where

import Data.List (isInfixOf, nub)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Test.Hspec
import Test.QuickCheck

import Cardano.Ledger.TxIn (TxIn)

import Singular.CLI.FoldRules
    ( FoldRequestsRefusal (..)
    , FoldTargetRefusal (..)
    , SpendsRefusal (..)
    , foldRequests
    , foldTarget
    , renderFoldRequestsRefusal
    , renderSpendsRefusal
    , renderTargetRefusal
    , spendsSelection
    )
import Singular.Registry.Deployment (parseOutRef, renderOutRef)
import Singular.Registry.FoldSelection
    ( AppVerdict (..)
    , ApprovalCheck (..)
    , EdgeKind (..)
    , Exclusion (..)
    , Leaf (..)
    , PendingRequest (..)
    , SelectedRequest (..)
    , Selection (..)
    , exclusionName
    , exclusionSource
    , selectFold
    )

-- ---------------------------------------------------------
-- Clock and request builders
-- ---------------------------------------------------------

nowMs :: Integer
nowMs = 1000000

marginMs :: Integer
marginMs = 30000

farDeadline :: Integer
farDeadline = nowMs + 1000000

nearDeadline :: Integer
nearDeadline = nowMs + 10000

-- | A distinct output reference numbered by its hex tail.
txRef :: Int -> TxIn
txRef n =
    either error id $
        parseOutRef (T.pack (replicate 62 'a' <> hex2 n <> "#0"))
  where
    hex2 k = [digit (k `div` 16), digit (k `mod` 16)]
    digit d = "0123456789abcdef" !! (d `mod` 16)

mkInsert :: Int -> Int -> T.Text -> Integer -> PendingRequest
mkInsert ref key owner deadline =
    PendingRequest
        { prRef = ref
        , prKey = key
        , prOwner = owner
        , prEdge = EdgeInsertActive
        , prDeadline = deadline
        , prDecodeOk = True
        , prApproval = ApprovalOk
        , prApp = AppReady
        }

-- | Look an exclusion up by the selection's own reference.
exclusionFor :: Int -> Selection -> Exclusion
exclusionFor r sel =
    case [exc | (q, exc) <- selectionExcluded sel, prRef q == r] of
        (exc : _) -> exc
        [] -> error ("exclusionFor: no exclusion for " <> show r)

-- | Translate a selection's settled references through the pairing.
settledTxIns :: [(TxIn, Int)] -> Selection -> [TxIn]
settledTxIns pairing sel =
    [ tx
    | s <- selectionSettled sel
    , tx <- [txFor (selRef s)]
    ]
  where
    intToTx = [(r, tx) | (tx, r) <- pairing]
    txFor r = case lookup r intToTx of
        Just tx -> tx
        Nothing -> error ("settledTxIns: no output reference for " <> show r)

-- | Translate a selection's exclusions through the pairing, in order.
excludedTxIns :: [(TxIn, Int)] -> Selection -> [(TxIn, Exclusion)]
excludedTxIns pairing sel =
    [(txFor (prRef q), exc) | (q, exc) <- selectionExcluded sel]
  where
    intToTx = [(r, tx) | (tx, r) <- pairing]
    txFor r = case lookup r intToTx of
        Just tx -> tx
        Nothing -> error ("excludedTxIns: no output reference for " <> show r)

-- ---------------------------------------------------------
-- Fixtures: three pending, one settles
-- ---------------------------------------------------------

t1 :: TxIn
t1 = txRef 1

t2 :: TxIn
t2 = txRef 2

t3 :: TxIn
t3 = txRef 3

p1 :: PendingRequest
p1 = mkInsert 1 50 "Alice" farDeadline

p2 :: PendingRequest
p2 = mkInsert 2 51 "Bob" farDeadline

p3 :: PendingRequest
p3 = mkInsert 3 52 "Carol" nearDeadline

threeFacts :: Map.Map Int (Leaf, Bool)
threeFacts =
    Map.fromList
        [ (50, (LeafUnknown, False))
        , (51, (LeafActive, True))
        , (52, (LeafUnknown, False))
        ]

threePending :: [PendingRequest]
threePending = [p1, p2, p3]

threePairing :: [(TxIn, Int)]
threePairing = [(t1, 1), (t2, 2), (t3, 3)]

threeSelection :: Selection
threeSelection = selectFold 1 nowMs marginMs threeFacts threePending

-- ---------------------------------------------------------
-- Fixtures: three pending, none settleable, three reasons
-- ---------------------------------------------------------

u1 :: TxIn
u1 = txRef 11

u2 :: TxIn
u2 = txRef 12

u3 :: TxIn
u3 = txRef 13

q1 :: PendingRequest
q1 = (mkInsert 11 60 "Quinn" farDeadline){prDecodeOk = False}

q2 :: PendingRequest
q2 = mkInsert 12 61 "Ruth" farDeadline

q3 :: PendingRequest
q3 = mkInsert 13 62 "Sam" nearDeadline

noneFacts :: Map.Map Int (Leaf, Bool)
noneFacts =
    Map.fromList
        [ (60, (LeafUnknown, False))
        , (61, (LeafActive, True))
        , (62, (LeafUnknown, False))
        ]

nonePending :: [PendingRequest]
nonePending = [q1, q2, q3]

nonePairing :: [(TxIn, Int)]
nonePairing = [(u1, 11), (u2, 12), (u3, 13)]

noneSelection :: Selection
noneSelection = selectFold 1 nowMs marginMs noneFacts nonePending

-- ---------------------------------------------------------
-- Fixtures: two settle under a wide bound
-- ---------------------------------------------------------

v1 :: TxIn
v1 = txRef 21

v2 :: TxIn
v2 = txRef 22

v3 :: TxIn
v3 = txRef 23

s1 :: PendingRequest
s1 = mkInsert 21 70 "Tess" farDeadline

s2 :: PendingRequest
s2 = mkInsert 22 71 "Uma" farDeadline

s3 :: PendingRequest
s3 = mkInsert 23 72 "Vera" farDeadline

wideFacts :: Map.Map Int (Leaf, Bool)
wideFacts =
    Map.fromList
        [ (70, (LeafUnknown, False))
        , (71, (LeafUnknown, False))
        , (72, (LeafActive, True))
        ]

widePending :: [PendingRequest]
widePending = [s1, s2, s3]

widePairing :: [(TxIn, Int)]
widePairing = [(v1, 21), (v2, 22), (v3, 23)]

wideSelection :: Selection
wideSelection = selectFold 9 nowMs marginMs wideFacts widePending

-- ---------------------------------------------------------
-- Fixtures: the spend check, three pending
-- ---------------------------------------------------------

stateTx :: TxIn
stateTx = txRef 90

aTx :: TxIn
aTx = txRef 91

bTx :: TxIn
bTx = txRef 92

cTx :: TxIn
cTx = txRef 93

fundTx :: TxIn
fundTx = txRef 94

pendingTxIns :: [TxIn]
pendingTxIns = [aTx, bTx, cTx]

spec :: Spec
spec = describe "registry fold takes the selection" $ do
    namedRequestMustBeSettled
    nothingToFoldNamesEveryExclusion
    severalPendingNeverRefusesOnCount
    builtFoldSpendsExactlyTheSelection
    mismatchedInputsRefuseAsInconsistent
    namedWithNothingSettledStatesCause
    oldRuleUntouched

-- ---------------------------------------------------------
-- A named request must be among the settled
-- ---------------------------------------------------------

namedRequestMustBeSettled :: Spec
namedRequestMustBeSettled = describe "a named request is among the settled" $ do
    it "returns exactly the settled list when the named request settled" $ do
        let got = foldRequests (Just t1) threePairing threeSelection
        got `shouldBe` Right (t1 :| [])
        got `shouldBe` case settledTxIns threePairing threeSelection of
            (x : xs) -> Right (x :| xs)
            [] -> Left FoldNothingPending
    it
        "refuses a named request the model refused, naming reason and source"
        $ do
            let exc = exclusionFor 2 threeSelection
            exclusionSource exc `shouldBe` "model-refusal"
            foldRequests (Just t2) threePairing threeSelection
                `shouldBe` Left (FoldNamedExcluded t2 exc)
            let said = renderFoldRequestsRefusal (FoldNamedExcluded t2 exc)
            T.unpack (renderOutRef t2) `isInfixOf` said `shouldBe` True
            T.unpack (exclusionName exc) `isInfixOf` said `shouldBe` True
            T.unpack (exclusionSource exc) `isInfixOf` said `shouldBe` True
            T.unpack (excDetail exc) `isInfixOf` said `shouldBe` True
    it
        "refuses a named request the policy left out, naming reason and source"
        $ do
            let exc = exclusionFor 3 threeSelection
            exclusionSource exc `shouldBe` "selection-policy"
            foldRequests (Just t3) threePairing threeSelection
                `shouldBe` Left (FoldNamedExcluded t3 exc)
            let said = renderFoldRequestsRefusal (FoldNamedExcluded t3 exc)
            T.unpack (renderOutRef t3) `isInfixOf` said `shouldBe` True
            T.unpack (exclusionName exc) `isInfixOf` said `shouldBe` True
            T.unpack (exclusionSource exc) `isInfixOf` said `shouldBe` True
            T.unpack (excDetail exc) `isInfixOf` said `shouldBe` True
    it
        "refuses a named request that was never pending with the not-pending wording"
        $ do
            let fresh = txRef 9
            foldRequests (Just fresh) threePairing threeSelection
                `shouldBe` Left (FoldNamedNotPending fresh)
            renderFoldRequestsRefusal (FoldNamedNotPending fresh)
                `shouldBe` renderTargetRefusal (NotPending fresh)

-- ---------------------------------------------------------
-- Nothing settleable names every exclusion
-- ---------------------------------------------------------

nothingToFoldNamesEveryExclusion :: Spec
nothingToFoldNamesEveryExclusion = describe "nothing settleable names every exclusion" $ do
    it "lists all three exclusions in ledger input order" $ do
        let expected = excludedTxIns nonePairing noneSelection
        length expected `shouldBe` 3
        length (nub (map (T.unpack . exclusionName . snd) expected))
            `shouldBe` 3
        map fst expected `shouldBe` [u1, u2, u3]
        foldRequests Nothing nonePairing noneSelection
            `shouldBe` Left (FoldNothingToFold expected)
        let said = renderFoldRequestsRefusal (FoldNothingToFold expected)
        mapM_
            ( \(tx, exc) -> do
                T.unpack (renderOutRef tx) `isInfixOf` said `shouldBe` True
                T.unpack (exclusionName exc) `isInfixOf` said `shouldBe` True
                T.unpack (exclusionSource exc) `isInfixOf` said `shouldBe` True
                T.unpack (excDetail exc) `isInfixOf` said `shouldBe` True
            )
            expected
    it "fails a version that names only the first exclusion" $ do
        let expected = excludedTxIns nonePairing noneSelection
            firstOnly = take 1 expected
            actual = foldRequests Nothing nonePairing noneSelection
        actual `shouldBe` Left (FoldNothingToFold expected)
        actual `shouldNotBe` Left (FoldNothingToFold firstOnly)
        renderFoldRequestsRefusal (FoldNothingToFold expected)
            `shouldNotBe` renderFoldRequestsRefusal (FoldNothingToFold firstOnly)
    it "says nothing is pending when nothing is pending" $ do
        let emptySel = selectFold 1 nowMs marginMs Map.empty []
        foldRequests Nothing [] emptySel `shouldBe` Left FoldNothingPending
        renderFoldRequestsRefusal FoldNothingPending
            `shouldBe` renderTargetRefusal NothingPending

-- ---------------------------------------------------------
-- Several pending never refuses on count
-- ---------------------------------------------------------

severalPendingNeverRefusesOnCount :: Spec
severalPendingNeverRefusesOnCount = describe "several pending never refuses on count" $ do
    it "takes the one settled request when two are pending" $ do
        let pending2 = [p1, p2]
            pairing2 = [(t1, 1), (t2, 2)]
            facts2 = Map.delete 52 threeFacts
            sel2 = selectFold 1 nowMs marginMs facts2 pending2
        foldRequests Nothing pairing2 sel2 `shouldBe` Right (t1 :| [])
        foldTarget Nothing [t1, t2]
            `shouldBe` Left (SeveralPending [t1, t2])
    it "takes the one settled request when three are pending" $ do
        foldRequests Nothing threePairing threeSelection
            `shouldBe` Right (t1 :| [])
        foldTarget Nothing [t1, t2, t3]
            `shouldBe` Left (SeveralPending [t1, t2, t3])
    it "returns every settled request under a wide bound" $ do
        let expected = settledTxIns widePairing wideSelection
        expected `shouldBe` [v1, v2]
        foldRequests Nothing widePairing wideSelection
            `shouldBe` Right (v1 :| [v2])

-- ---------------------------------------------------------
-- A built fold spends exactly the selection
-- ---------------------------------------------------------

builtFoldSpendsExactlyTheSelection :: Spec
builtFoldSpendsExactlyTheSelection = describe "a built fold spends exactly the selection" $ do
    it "is ok for the state plus the selected plus unrelated funding" $ do
        spendsSelection stateTx [aTx] pendingTxIns [stateTx, aTx, fundTx]
            `shouldBe` Right ()
        spendsSelection
            stateTx
            [aTx, bTx]
            pendingTxIns
            [stateTx, bTx, aTx, fundTx]
            `shouldBe` Right ()
    it "refuses naming the missing state output" $ do
        let got = spendsSelection stateTx [aTx] pendingTxIns [aTx, fundTx]
        got `shouldBe` Left (SpendsMissingState stateTx)
        case got of
            Left why ->
                T.unpack (renderOutRef stateTx)
                    `isInfixOf` renderSpendsRefusal why
                    `shouldBe` True
            Right _ -> expectationFailure "the missing state output is ok"
    it "refuses naming a missing selected reference" $ do
        let got = spendsSelection stateTx [aTx] pendingTxIns [stateTx, fundTx]
        got `shouldBe` Left (SpendsMissingSelected [aTx])
        case got of
            Left why ->
                T.unpack (renderOutRef aTx)
                    `isInfixOf` renderSpendsRefusal why
                    `shouldBe` True
            Right _ -> expectationFailure "the missing selected reference is ok"
    it "refuses naming another pending reference that is spent" $ do
        let got =
                spendsSelection stateTx [aTx] pendingTxIns [stateTx, aTx, bTx, fundTx]
        got `shouldBe` Left (SpendsExtraPending [bTx])
        case got of
            Left why ->
                T.unpack (renderOutRef bTx)
                    `isInfixOf` renderSpendsRefusal why
                    `shouldBe` True
            Right _ -> expectationFailure "the extra pending spend is ok"
    it
        "refuses when the second of two selected references is not spent, naming it"
        $ do
            let got =
                    spendsSelection stateTx [aTx, bTx] pendingTxIns [stateTx, aTx, fundTx]
            got `shouldBe` Left (SpendsMissingSelected [bTx])
            case got of
                Left why ->
                    T.unpack (renderOutRef bTx)
                        `isInfixOf` renderSpendsRefusal why
                        `shouldBe` True
                Right _ -> expectationFailure "the missing second reference is ok"
    it
        "refuses when the last of three selected references is not spent, naming it"
        $ do
            let got =
                    spendsSelection
                        stateTx
                        [aTx, bTx, cTx]
                        pendingTxIns
                        [stateTx, aTx, bTx, fundTx]
            got `shouldBe` Left (SpendsMissingSelected [cTx])
            case got of
                Left why ->
                    T.unpack (renderOutRef cTx)
                        `isInfixOf` renderSpendsRefusal why
                        `shouldBe` True
                Right _ -> expectationFailure "the missing last reference is ok"
    it
        "refuses when the middle of three selected references is not spent, naming it"
        $ do
            let got =
                    spendsSelection
                        stateTx
                        [aTx, bTx, cTx]
                        pendingTxIns
                        [stateTx, aTx, cTx, fundTx]
            got `shouldBe` Left (SpendsMissingSelected [bTx])
            case got of
                Left why ->
                    T.unpack (renderOutRef bTx)
                        `isInfixOf` renderSpendsRefusal why
                        `shouldBe` True
                Right _ -> expectationFailure "the missing middle reference is ok"
    it
        "fails the new rows for a variant that checks only the first selected reference"
        $ do
            let firstOnly state selected _ spent = case selected of
                    [] -> Right ()
                    (x : _) | x `notElem` spent -> Left (SpendsMissingSelected [x])
                    _ | state `notElem` spent -> Left (SpendsMissingState state)
                    _ -> Right ()
                secondMissing =
                    spendsSelection stateTx [aTx, bTx] pendingTxIns [stateTx, aTx, fundTx]
                lastMissing =
                    spendsSelection
                        stateTx
                        [aTx, bTx, cTx]
                        pendingTxIns
                        [stateTx, aTx, bTx, fundTx]
                middleMissing =
                    spendsSelection
                        stateTx
                        [aTx, bTx, cTx]
                        pendingTxIns
                        [stateTx, aTx, cTx, fundTx]
            firstOnly stateTx [aTx, bTx] pendingTxIns [stateTx, aTx, fundTx]
                `shouldBe` Right ()
            ( firstOnly stateTx [aTx, bTx] pendingTxIns [stateTx, aTx, fundTx]
                    == secondMissing
                )
                `shouldBe` False
            ( firstOnly
                    stateTx
                    [aTx, bTx, cTx]
                    pendingTxIns
                    [stateTx, aTx, bTx, fundTx]
                    == lastMissing
                )
                `shouldBe` False
            ( firstOnly
                    stateTx
                    [aTx, bTx, cTx]
                    pendingTxIns
                    [stateTx, aTx, cTx, fundTx]
                    == middleMissing
                )
                `shouldBe` False
    it "leaves funding and collateral free for any non-pending reference" $
        property $
            forAll (choose (100, 200)) $ \n ->
                let extra = txRef n
                in  extra `notElem` (stateTx : pendingTxIns) ==>
                        spendsSelection
                            stateTx
                            [aTx]
                            pendingTxIns
                            [stateTx, aTx, fundTx, extra]
                            === Right ()

-- ---------------------------------------------------------
-- Mismatched selection and pairing refuse as inconsistent
-- ---------------------------------------------------------

mismatchedInputsRefuseAsInconsistent :: Spec
mismatchedInputsRefuseAsInconsistent =
    describe "mismatched selection and pairing refuse as inconsistent" $ do
        it
            "refuses when a settled reference has no pairing, never shortening the list"
            $ do
                let pairingMissingSettled = [(t2, 2), (t3, 3)]
                    listed =
                        map selRef (selectionSettled threeSelection)
                            ++ map (prRef . fst) (selectionExcluded threeSelection)
                    paired = map snd pairingMissingSettled
                    missing = [r | r <- listed, r `notElem` paired]
                    extraTxs = [tx | (tx, r) <- pairingMissingSettled, r `notElem` listed]
                    got = foldRequests Nothing pairingMissingSettled threeSelection
                missing `shouldNotBe` []
                got `shouldBe` Left (FoldInconsistentInput missing extraTxs)
                got `shouldNotBe` Left FoldNothingPending
                case got of
                    Left why -> do
                        let said = renderFoldRequestsRefusal why
                        mapM_ (\r -> show r `isInfixOf` said `shouldBe` True) missing
                        said `shouldNotBe` renderFoldRequestsRefusal FoldNothingPending
                    Right _ -> expectationFailure "the inconsistent pairing returned a list"
        it
            "refuses when a paired output is listed nowhere, never as not-pending"
            $ do
                let tX = txRef 4
                    pairingWithExtra = threePairing ++ [(tX, 99)]
                    listed =
                        map selRef (selectionSettled threeSelection)
                            ++ map (prRef . fst) (selectionExcluded threeSelection)
                    paired = map snd pairingWithExtra
                    missing = [r | r <- listed, r `notElem` paired]
                    extraTxs = [tx | (tx, r) <- pairingWithExtra, r `notElem` listed]
                    got = foldRequests Nothing pairingWithExtra threeSelection
                    gotNamed = foldRequests (Just tX) pairingWithExtra threeSelection
                extraTxs `shouldBe` [tX]
                got `shouldBe` Left (FoldInconsistentInput missing extraTxs)
                gotNamed `shouldBe` Left (FoldInconsistentInput missing extraTxs)
                gotNamed `shouldNotBe` Left (FoldNamedNotPending tX)
                case gotNamed of
                    Left why ->
                        T.unpack (renderOutRef tX)
                            `isInfixOf` renderFoldRequestsRefusal why
                            `shouldBe` True
                    Right _ -> expectationFailure "the unlisted pairing returned a list"
        it
            "refuses when the pairing is non-empty while both lists are empty, never as nothing pending"
            $ do
                let emptySel = selectFold 1 nowMs marginMs Map.empty []
                    pairingNonEmpty = [(t1, 1)]
                    got = foldRequests Nothing pairingNonEmpty emptySel
                got `shouldBe` Left (FoldInconsistentInput [] [t1])
                got `shouldNotBe` Left FoldNothingPending
                case got of
                    Left why ->
                        T.unpack (renderOutRef t1)
                            `isInfixOf` renderFoldRequestsRefusal why
                            `shouldBe` True
                    Right _ ->
                        expectationFailure "the empty selection with pairing returned a list"
        it
            "refuses when the first selected maps and a later one does not, naming the unpaired"
            $ do
                let pairingFirstMaps = [(v1, 21), (v3, 23)]
                    listed =
                        map selRef (selectionSettled wideSelection)
                            ++ map (prRef . fst) (selectionExcluded wideSelection)
                    paired = map snd pairingFirstMaps
                    missing = [r | r <- listed, r `notElem` paired]
                    extraTxs = [tx | (tx, r) <- pairingFirstMaps, r `notElem` listed]
                    got = foldRequests Nothing pairingFirstMaps wideSelection
                missing `shouldBe` [22]
                extraTxs `shouldBe` []
                got `shouldBe` Left (FoldInconsistentInput missing extraTxs)
                case got of
                    Left why ->
                        show (22 :: Int)
                            `isInfixOf` renderFoldRequestsRefusal why
                            `shouldBe` True
                    Right _ -> expectationFailure "the partial pairing returned a list"
        it
            "refuses when the last selected maps and an earlier one does not, naming the unpaired"
            $ do
                let pairingLastMaps = [(v2, 22), (v3, 23)]
                    listed =
                        map selRef (selectionSettled wideSelection)
                            ++ map (prRef . fst) (selectionExcluded wideSelection)
                    paired = map snd pairingLastMaps
                    missing = [r | r <- listed, r `notElem` paired]
                    extraTxs = [tx | (tx, r) <- pairingLastMaps, r `notElem` listed]
                    got = foldRequests Nothing pairingLastMaps wideSelection
                missing `shouldBe` [21]
                extraTxs `shouldBe` []
                got `shouldBe` Left (FoldInconsistentInput missing extraTxs)
                case got of
                    Left why ->
                        show (21 :: Int)
                            `isInfixOf` renderFoldRequestsRefusal why
                            `shouldBe` True
                    Right _ -> expectationFailure "the partial pairing returned a list"
        it
            "fails partial rows for a shortening translation that returns the shorter list"
            $ do
                let shortenFold pairing sel =
                        let intToTx = [(r, tx) | (tx, r) <- pairing]
                            mapped =
                                [ tx
                                | s <- selectionSettled sel
                                , Just tx <- [lookup (selRef s) intToTx]
                                ]
                        in  case mapped of
                                [] -> Left FoldNothingPending
                                (x : xs) -> Right (x :| xs)
                    shortFirst = shortenFold [(v1, 21), (v3, 23)] wideSelection
                    shortLast = shortenFold [(v2, 22), (v3, 23)] wideSelection
                shortFirst `shouldBe` Right (v1 :| [])
                shortLast `shouldBe` Right (v2 :| [])
                shortFirst
                    `shouldNotBe` Left (FoldInconsistentInput [22] [] :: FoldRequestsRefusal)
                shortLast
                    `shouldNotBe` Left (FoldInconsistentInput [21] [] :: FoldRequestsRefusal)

-- ---------------------------------------------------------
-- A named request with nothing settled states its cause
-- ---------------------------------------------------------

namedWithNothingSettledStatesCause :: Spec
namedWithNothingSettledStatesCause =
    describe "a named request with nothing settled states its cause" $ do
        it "states a not-pending named cause and lists every other exclusion" $ do
            let fresh = txRef 9
                allOthers = excludedTxIns nonePairing noneSelection
                got = foldRequests (Just fresh) nonePairing noneSelection
                expected = FoldNamedNothingSettled fresh Nothing allOthers
            got `shouldBe` Left expected
            got `shouldNotBe` Left (FoldNothingToFold allOthers)
            case got of
                Left why -> do
                    let said = renderFoldRequestsRefusal why
                    renderFoldRequestsRefusal (FoldNamedNotPending fresh)
                        `isInfixOf` said
                        `shouldBe` True
                    renderFoldRequestsRefusal (FoldNothingToFold allOthers)
                        `isInfixOf` said
                        `shouldBe` True
                Right _ -> expectationFailure "the named empty fold returned a list"
        it "states an excluded named cause and lists every other exclusion" $ do
            let exc2 = exclusionFor 12 noneSelection
                allExclusions = excludedTxIns nonePairing noneSelection
                others = [x | x@(tx, _) <- allExclusions, tx /= u2]
                got = foldRequests (Just u2) nonePairing noneSelection
                expected = FoldNamedNothingSettled u2 (Just exc2) others
            map fst others `shouldBe` [u1, u3]
            got `shouldBe` Left expected
            got `shouldNotBe` Left (FoldNamedExcluded u2 exc2)
            got `shouldNotBe` Left (FoldNothingToFold allExclusions)
            case got of
                Left why -> do
                    let said = renderFoldRequestsRefusal why
                    renderFoldRequestsRefusal (FoldNamedExcluded u2 exc2)
                        `isInfixOf` said
                        `shouldBe` True
                    renderFoldRequestsRefusal (FoldNothingToFold others)
                        `isInfixOf` said
                        `shouldBe` True
                Right _ -> expectationFailure "the named empty fold returned a list"
        it
            "states both not-pending and nothing pending when nothing is pending"
            $ do
                let fresh = txRef 9
                    emptySel = selectFold 1 nowMs marginMs Map.empty []
                    got = foldRequests (Just fresh) [] emptySel
                    expected = FoldNamedNothingSettled fresh Nothing []
                got `shouldBe` Left expected
                got `shouldNotBe` Left (FoldNamedNotPending fresh)
                got `shouldNotBe` Left FoldNothingPending
                case got of
                    Left why -> do
                        let said = renderFoldRequestsRefusal why
                        renderFoldRequestsRefusal (FoldNamedNotPending fresh)
                            `isInfixOf` said
                            `shouldBe` True
                        renderFoldRequestsRefusal FoldNothingPending
                            `isInfixOf` said
                            `shouldBe` True
                    Right _ -> expectationFailure "the named empty fold returned a list"

-- ---------------------------------------------------------
-- The old rule stays in place
-- ---------------------------------------------------------

oldRuleUntouched :: Spec
oldRuleUntouched = describe "the old one-pending rule stays in place" $ do
    it "takes the one pending request" $
        foldTarget Nothing [t1] `shouldBe` Right t1
    it "refuses several pending" $
        foldTarget Nothing [t1, t2] `shouldBe` Left (SeveralPending [t1, t2])
    it "keeps its wording for the new refusals to reuse" $ do
        renderFoldRequestsRefusal FoldNothingPending
            `shouldBe` renderTargetRefusal NothingPending
        renderFoldRequestsRefusal (FoldNamedNotPending t1)
            `shouldBe` renderTargetRefusal (NotPending t1)
