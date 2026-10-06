{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.CLI.FoldManySpec
Description : One fold takes every request it can fold, and accounts for each
License     : Apache-2.0

Alice and Bob each book from their own wallet; one @registry fold@, run by
either of them or by anyone, settles both. These rows fix what that fold
decides before it builds anything — which pending requests it takes, in the
ledger's input order, and why it leaves each other one — and what it binds to
its transaction afterwards: the journal line listing every transition, the
reconciliation that proves every included key, the rollback that returns
every included request to pending. Every row runs with two or three requests
and two owners, because with one request a count of requests, of keys and of
owners coincide.

The refusal reasons a request may be left for are the model's own words,
those @Singular.refusal@ returns for the two edges this command folds
(@lean/Singular/Model.lean@).
-}
module Singular.CLI.FoldManySpec (spec) where

import Control.Monad (forM_)
import Data.Aeson qualified as Aeson
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as BL
import Data.Either (isLeft, isRight)
import Data.List (isInfixOf, nub, sort, sortOn)
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Lens.Micro ((&), (.~))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec
import Test.QuickCheck
    ( Gen
    , chooseInt
    , chooseInteger
    , conjoin
    , counterexample
    , elements
    , forAll
    , property
    , sublistOf
    , vectorOf
    , (===)
    )

import Cardano.Ledger.Api.Tx.Out (datumTxOutL, mkBasicTxOut)
import Cardano.Ledger.BaseTypes (Network (..))
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Mary.Value (MaryValue (..))
import Cardano.Ledger.TxIn (TxIn)
import Cardano.Slotting.Slot (SlotNo (..))
import PlutusCore.Data qualified as PLC
import PlutusTx.Builtins (toBuiltin)

import Singular.Application.OpenDatum.Envelope
    ( Control (..)
    , Envelope (..)
    , StateAsset (..)
    , envelopeHash
    , envelopeVersion
    )
import Singular.CLI.FoldRules
import Singular.CLI.Receipt
    ( FoldTransition (..)
    , JournalEntry (..)
    , appendJournal
    , chainTransitions
    , foldTransitions
    , readJournal
    )
import Singular.CLI.Reconcile
    ( Recovery (..)
    , observe
    , rolledBackLine
    )
import Singular.Registry.Deployment (parseOutRef, renderOutRef)
import Singular.Registry.LedgerProvider (TipObservation (..))
import Singular.Registry.TrieState (Leaf (..))
import Singular.Registry.TxBuilder.Internal
    ( addrFromKeyHashBytes
    , approvalName
    , mkInlineDatum
    , toPlcData
    )
import Singular.Registry.Types
    ( CageDatum (..)
    , Edge
    , OnChainRequest (..)
    , OnChainRoot (..)
    , OnChainTokenId (..)
    , OnChainTokenState (..)
    , edgeDeleteAbsent
    , edgeInsertAbsent
    , edgeInsertActive
    , edgeUpdateActive
    , edgeUpdateTerminal
    , edgeWitnessTerminal
    )

spec :: Spec
spec = describe "a fold of every pending request" $ do
    selection
    approvals
    law
    refusals
    bound
    spending
    payouts
    journalLines
    reconciliation

-- ---------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------

outRef :: Char -> Int -> TxIn
outRef c i =
    either
        error
        id
        (parseOutRef (T.pack (replicate 64 c <> "#" <> show i)))

alice, bob :: ByteString
alice = BS.replicate 28 0xa1
bob = BS.replicate 28 0xb0

processTime :: Integer
processTime = 90_000

now :: Integer
now = 1_000_000_000

margin :: Integer
margin = foldMarginMs

-- | A request of @owner@ moving @key@ by @edge@, submitted at @submitted@.
requestOf
    :: ByteString -> ByteString -> Edge -> Integer -> OnChainRequest
requestOf owner key edge submitted =
    OnChainRequest
        { requestToken = OnChainTokenId (toBuiltin ("registry" :: ByteString))
        , requestOwner = toBuiltin owner
        , requestKey = key
        , requestEdge = edge
        , requestDeposit = 2_000_000
        , requestSubmittedAt = submitted
        , requestDestination = ("", Nothing)
        }

-- | The request pending with its deadline, as the command reads it.
pendingOf :: OnChainRequest -> PendingRequest
pendingOf r =
    PendingDecoded r (requestDeadline (requestSubmittedAt r) processTime)

-- | Submitted so that @left@ milliseconds remain before the deadline, now.
leaving :: Integer -> Integer
leaving left = now + left - processTime

-- | Open: a full processing window ahead.
open :: Integer
open = leaving processTime

-- | The law over a tree where @active@ keys are Active with a live holding.
lawWith :: [ByteString] -> [(ByteString, Edge)] -> Either Text ()
lawWith active =
    leafLaw
        (Map.fromList [(k, Active) | k <- active])
        (Set.fromList active)

included :: FoldSelection -> [TxIn]
included = map srInput . selIncluded

-- ---------------------------------------------------------
-- Which requests a fold takes
-- ---------------------------------------------------------

selection :: Spec
selection = describe "which pending requests it takes" $ do
    it
        "takes two owners' insertions together, in the ledger's input order"
        $ do
            let a =
                    ( outRef 'b' 0
                    , pendingOf (requestOf alice "keyA" edgeInsertActive open)
                    )
                b =
                    (outRef 'a' 1, pendingOf (requestOf bob "keyB" edgeInsertActive open))
                s = selectFold now margin (lawWith []) [a, b]
            included s `shouldBe` [outRef 'a' 1, outRef 'b' 0]
            selExcluded s `shouldBe` []
            map (requestOwner . srRequest) (selIncluded s)
                `shouldBe` [toBuiltin bob, toBuiltin alice]
    it
        "takes three requests of two owners, an insertion and two terminations"
        $ do
            let rs =
                    [
                        ( outRef 'c' 0
                        , pendingOf (requestOf alice "keyA" edgeUpdateTerminal open)
                        )
                    , (outRef 'c' 1, pendingOf (requestOf bob "keyB" edgeInsertActive open))
                    ,
                        ( outRef 'c' 2
                        , pendingOf (requestOf bob "keyC" edgeUpdateTerminal open)
                        )
                    ]
                s = selectFold now margin (lawWith ["keyA", "keyC"]) rs
            included s `shouldBe` map fst rs
            map srKind (selIncluded s)
                `shouldBe` [FoldTermination, FoldInsertion, FoldTermination]
            map srDeadlineMs (selIncluded s)
                `shouldBe` replicate 3 (open + processTime)
    it
        "leaves a request whose window has closed, naming how far past it is"
        $ do
            let expired =
                    ( outRef 'd' 0
                    , pendingOf (requestOf alice "keyA" edgeInsertActive (leaving (-5_000)))
                    )
                near =
                    ( outRef 'd' 1
                    , pendingOf (requestOf bob "keyB" edgeInsertActive (leaving margin))
                    )
                fresh =
                    (outRef 'd' 2, pendingOf (requestOf bob "keyC" edgeInsertActive open))
                s = selectFold now margin (lawWith []) [expired, near, fresh]
            included s `shouldBe` [outRef 'd' 2]
            selExcluded s
                `shouldBe` [ (outRef 'd' 0, WindowClosed (-5_000))
                           , (outRef 'd' 1, WindowClosed margin)
                           ]
    it "leaves an edge it does not fold and a datum it cannot read" $ do
        let other =
                ( outRef 'e' 0
                , pendingOf (requestOf alice "keyA" edgeInsertAbsent open)
                )
            broken = (outRef 'e' 1, PendingUndecodable "no request datum")
            fresh =
                (outRef 'e' 2, pendingOf (requestOf bob "keyB" edgeInsertActive open))
            s = selectFold now margin (lawWith []) [other, broken, fresh]
        included s `shouldBe` [outRef 'e' 2]
        selExcluded s
            `shouldBe` [ (outRef 'e' 0, EdgeUnsupported edgeInsertAbsent)
                       , (outRef 'e' 1, Undecodable "no request datum")
                       ]
    it "folds the first of two insertions of one key and names the second" $ do
        let first =
                ( outRef 'f' 0
                , pendingOf (requestOf alice "keyA" edgeInsertActive open)
                )
            second =
                (outRef 'f' 1, pendingOf (requestOf bob "keyA" edgeInsertActive open))
            fresh =
                (outRef 'f' 2, pendingOf (requestOf bob "keyB" edgeInsertActive open))
            s = selectFold now margin (lawWith []) [second, fresh, first]
        included s `shouldBe` [outRef 'f' 0, outRef 'f' 2]
        selExcluded s `shouldBe` [(outRef 'f' 1, RefusedByLaw "key-exists")]
    it "names each exclusion by its reason" $ do
        renderExclusion (WindowClosed (-1)) `shouldBe` "window-closed"
        renderExclusion (WindowClosed 10) `shouldBe` "window-closed"
        renderExclusion (EdgeUnsupported edgeDeleteAbsent)
            `shouldBe` "edge-unsupported"
        renderExclusion (Undecodable "x") `shouldBe` "undecodable"
        renderExclusion (RefusedByLaw "key-exists")
            `shouldBe` "refused-by-law key-exists"
    it
        "puts every pending request in exactly one list, taking each one the rules admit after those before it"
        $ property
        $ forAll genPending
        $ \(active, waiting) ->
            let lawF = lawWith active
                s = selectFold now margin lawF waiting
                ordered = sortOn fst waiting
                expected = expectSelection lawF ordered
                everything = sort (included s <> map fst (selExcluded s))
            in  counterexample (show s) $
                    conjoin
                        [ everything === sort (map fst waiting)
                        , length (nub everything) === length waiting
                        , included s === sort (included s)
                        , map fst (selExcluded s) === sort (map fst (selExcluded s))
                        , (included s, selExcluded s) === expected
                        ]

{- | The rule, stated once over a list in input order: a request is taken
exactly when it decodes, names an edge this command folds, has its window
open beyond the margin, and the law accepts it after the requests taken
before it; otherwise it is left for the first of those it fails.
-}
expectSelection
    :: ([(ByteString, Edge)] -> Either Text ())
    -> [(TxIn, PendingRequest)]
    -> ([TxIn], [(TxIn, Exclusion)])
expectSelection lawF = go [] [] []
  where
    go taken _ left [] = (reverse taken, reverse left)
    go taken moves left ((i, p) : rest) = case p of
        PendingUndecodable why -> go taken moves ((i, Undecodable why) : left) rest
        PendingUnapproved r d why
            | requestEdge r `notElem` [edgeInsertActive, edgeUpdateTerminal] ->
                go taken moves ((i, EdgeUnsupported (requestEdge r)) : left) rest
            | d - now <= margin ->
                go taken moves ((i, WindowClosed (d - now)) : left) rest
            | otherwise -> go taken moves ((i, RefusedByLaw why) : left) rest
        PendingDecoded r d
            | requestEdge r `notElem` [edgeInsertActive, edgeUpdateTerminal] ->
                go taken moves ((i, EdgeUnsupported (requestEdge r)) : left) rest
            | d - now <= margin ->
                go taken moves ((i, WindowClosed (d - now)) : left) rest
            | otherwise ->
                let move = (requestKey r, requestEdge r)
                in  case lawF (moves <> [move]) of
                        Left why -> go taken moves ((i, RefusedByLaw why) : left) rest
                        Right () -> go (i : taken) (moves <> [move]) left rest

-- | Two to four pending requests over three keys, with every exclusion reachable.
genPending :: Gen ([ByteString], [(TxIn, PendingRequest)])
genPending = do
    n <- chooseInt (2, 4)
    active <- sublistOf keys
    entries <- vectorOf n entry
    ins <- vectorOf n (elements "0123456789abcdef")
    let refs = nub [outRef c i | (c, i) <- zip ins [0 ..]]
    pure (active, zip refs entries)
  where
    keys = ["keyA", "keyB", "keyC"]
    entry = do
        owner <- elements [alice, bob]
        key <- elements keys
        edge <-
            elements
                [ edgeInsertActive
                , edgeInsertActive
                , edgeUpdateTerminal
                , edgeUpdateTerminal
                , edgeUpdateActive
                , edgeWitnessTerminal
                ]
        left <-
            elements [processTime, processTime, margin, margin + 1, 0, -60_000]
        decoding <-
            elements [Right True, Right True, Right True, Right False, Left ()]
        let r = requestOf owner key edge (leaving left)
        pure $ case decoding of
            Right True -> pendingOf r
            Right False -> PendingUnapproved r (leaving left + processTime) "no-approval"
            Left () -> PendingUndecodable "not a request"

-- ---------------------------------------------------------
-- The approval a request carries
-- ---------------------------------------------------------

approvals :: Spec
approvals = describe "the approval each request carries" $ do
    let r = requestOf alice "keyA" edgeInsertActive open
        owned = approvalName edgeInsertActive "keyA" alice ("", "")
        other = approvalName edgeInsertActive "keyA" bob ("", "")
    it
        "admits exactly one approval, at quantity one, named for this request"
        $ approvalVerdict r [(owned, 1)] `shouldBe` Nothing
    it
        "refuses no approval, more than one, or one at another quantity: no-approval"
        $ do
            approvalVerdict r [] `shouldBe` Just "no-approval"
            approvalVerdict r [(owned, 2)] `shouldBe` Just "no-approval"
            approvalVerdict r [(owned, 1), (other, 1)]
                `shouldBe` Just "no-approval"
    it "refuses an approval named for another owner: approval-mismatch" $
        approvalVerdict r [(other, 1)] `shouldBe` Just "approval-mismatch"
    it
        "leaves an unapproved request out by the model's reason and folds the other owner's"
        $ do
            let bad =
                    (outRef 'a' 0, PendingUnapproved r (open + processTime) "no-approval")
                good =
                    (outRef 'b' 0, pendingOf (requestOf bob "keyA" edgeInsertActive open))
                s = selectFold now margin (lawWith []) [bad, good]
            included s `shouldBe` [outRef 'b' 0]
            selExcluded s `shouldBe` [(outRef 'a' 0, RefusedByLaw "no-approval")]
    it
        "names a closed window before a missing approval, as admission comes first"
        $ do
            let late =
                    ( outRef 'a' 0
                    , PendingUnapproved r (leaving (-1) + processTime) "no-approval"
                    )
                s = selectFold now margin (lawWith []) [late]
            selExcluded s `shouldBe` [(outRef 'a' 0, WindowClosed (-1))]

-- ---------------------------------------------------------
-- The law over the batch
-- ---------------------------------------------------------

law :: Spec
law = describe "the model's verdict on each step of the batch" $ do
    let leaves l = Map.fromList [("k", l)]
    it "inserts a key the tree does not hold, and refuses one it holds" $ do
        leafLaw Map.empty Set.empty [("k", edgeInsertActive)]
            `shouldBe` Right ()
        forM_ [Absent, Active, Terminal] $ \l ->
            leafLaw (leaves l) (Set.fromList ["k"]) [("k", edgeInsertActive)]
                `shouldBe` Left "key-exists"
    it
        "terminates an active key whose holding is live, naming every other case"
        $ do
            leafLaw
                (leaves Active)
                (Set.fromList ["k"])
                [("k", edgeUpdateTerminal)]
                `shouldBe` Right ()
            leafLaw (leaves Active) Set.empty [("k", edgeUpdateTerminal)]
                `shouldBe` Left "token-missing"
            leafLaw Map.empty Set.empty [("k", edgeUpdateTerminal)]
                `shouldBe` Left "key-unknown"
            leafLaw (leaves Absent) Set.empty [("k", edgeUpdateTerminal)]
                `shouldBe` Left "not-booked"
            leafLaw (leaves Terminal) Set.empty [("k", edgeUpdateTerminal)]
                `shouldBe` Left "terminal-immutable"
    it "judges each step from the state the steps before it leave" $ do
        leafLaw
            Map.empty
            Set.empty
            [("k", edgeInsertActive), ("k", edgeInsertActive)]
            `shouldBe` Left "key-exists"
        leafLaw
            (leaves Active)
            (Set.fromList ["k"])
            [("k", edgeUpdateTerminal), ("k", edgeUpdateTerminal)]
            `shouldBe` Left "terminal-immutable"
        leafLaw
            (Map.fromList [("k", Active)])
            (Set.fromList ["k"])
            [ ("j", edgeInsertActive)
            , ("k", edgeUpdateTerminal)
            , ("i", edgeInsertActive)
            ]
            `shouldBe` Right ()
    it
        "cannot terminate in the batch a key the batch inserts: its holding is not yet live"
        $ leafLaw
            Map.empty
            Set.empty
            [("k", edgeInsertActive), ("k", edgeUpdateTerminal)]
            `shouldBe` Left "token-missing"

-- ---------------------------------------------------------
-- Refusals
-- ---------------------------------------------------------

refusals :: Spec
refusals = describe "the fold it refuses" $ do
    let a = outRef 'a' 0
        b = outRef 'b' 0
        c = outRef 'c' 0
        taken i owner key =
            SelectedRequest
                i
                (requestOf owner key edgeInsertActive open)
                FoldInsertion
                (open + processTime)
        two =
            FoldSelection
                [taken a alice "keyA", taken c bob "keyC"]
                [(b, WindowClosed (-3_000))]
    it "builds over every included request, in order" $ do
        foldRequests Nothing two
            `shouldBe` Right (taken a alice "keyA" :| [taken c bob "keyC"])
        foldRequests (Just c) two
            `shouldBe` Right (taken a alice "keyA" :| [taken c bob "keyC"])
    it
        "refuses a named request it leaves, naming why, and one not pending"
        $ do
            foldRequests (Just b) two
                `shouldBe` Left (NamedNotIncluded b (Just (WindowClosed (-3_000))))
            let d = outRef 'd' 0
            foldRequests (Just d) two `shouldBe` Left (NamedNotIncluded d Nothing)
    it "refuses nothing-to-fold, naming every request it leaves" $ do
        foldRequests Nothing (FoldSelection [] [])
            `shouldBe` Left (NothingToFold [])
        let left = [(a, WindowClosed (-1)), (b, RefusedByLaw "key-exists")]
        foldRequests Nothing (FoldSelection [] left)
            `shouldBe` Left (NothingToFold left)
        foldRequests (Just a) (FoldSelection [] left)
            `shouldBe` Left (NothingToFold left)
    it "words each refusal with what it names" $ do
        let txt = T.unpack . renderOutRef
        renderFoldRefusal (NothingToFold [])
            `shouldSatisfy` isInfixOf "nothing-to-fold"
        renderFoldRefusal (NothingToFold [])
            `shouldSatisfy` isInfixOf "nothing is pending"
        let named =
                renderFoldRefusal
                    (NothingToFold [(a, WindowClosed (-1)), (b, RefusedByLaw "key-exists")])
        named `shouldSatisfy` isInfixOf "nothing-to-fold"
        forM_ [txt a, txt b, "window-closed", "refused-by-law key-exists"] $ \w ->
            named `shouldSatisfy` isInfixOf w
        let passed =
                renderFoldRefusal (NamedNotIncluded b (Just (WindowClosed (-3_000))))
        forM_ [txt b, "processing deadline", "has passed", "no fold is built"] $ \w ->
            passed `shouldSatisfy` isInfixOf w
        let nearly = renderFoldRefusal (NamedNotIncluded b (Just (WindowClosed 20_000)))
        forM_ [txt b, "within the", "no fold is built"] $ \w ->
            nearly `shouldSatisfy` isInfixOf w
        renderFoldRefusal (NamedNotIncluded c Nothing)
            `shouldSatisfy` (\s -> "not pending" `isInfixOf` s && txt c `isInfixOf` s)

-- ---------------------------------------------------------
-- The bound
-- ---------------------------------------------------------

bound :: Spec
bound = describe "the deadline that bounds the fold" $ do
    it
        "is the earliest deadline among the included requests, whatever their order"
        $ property
        $ forAll (vectorOf 3 (chooseInteger (margin + 1, 10 * processTime)))
        $ \lefts ->
            let rs =
                    [ (outRef 'a' i, pendingOf (requestOf o k edgeInsertActive (leaving l)))
                    | (i, o, k, l) <-
                        zip4 [0 ..] [alice, bob, alice] ["keyA", "keyB", "keyC"] lefts
                    ]
                s = selectFold now margin (lawWith []) rs
            in  case NE.nonEmpty (selIncluded s) of
                    Nothing -> counterexample "nothing included" False
                    Just taken ->
                        selectionDeadline taken === now + minimum lefts
    it "is never set by a request the fold leaves" $ do
        let earliest =
                ( outRef 'b' 0
                , pendingOf
                    (requestOf bob "keyA" edgeInsertActive (leaving (margin + 1_000)))
                )
            first =
                ( outRef 'a' 0
                , pendingOf (requestOf alice "keyA" edgeInsertActive (leaving 80_000))
                )
            other =
                ( outRef 'c' 0
                , pendingOf (requestOf bob "keyB" edgeInsertActive (leaving 60_000))
                )
            s = selectFold now margin (lawWith []) [earliest, first, other]
        selExcluded s `shouldBe` [(outRef 'b' 0, RefusedByLaw "key-exists")]
        fmap selectionDeadline (NE.nonEmpty (selIncluded s))
            `shouldBe` Just (now + 60_000)
  where
    zip4 (a : as) (b : bs) (c : cs) (d : ds) = (a, b, c, d) : zip4 as bs cs ds
    zip4 _ _ _ _ = []

-- ---------------------------------------------------------
-- What the built fold spends
-- ---------------------------------------------------------

spending :: Spec
spending = describe "what the built fold spends" $ do
    let state = outRef '5' 0
        fee = outRef '7' 0
        booked = [outRef 'a' 0, outRef 'b' 0, outRef 'c' 0]
    it
        "admits the state and exactly the included requests, beside the wallet's own inputs"
        $ spendsSelection
            state
            [outRef 'a' 0, outRef 'c' 0]
            booked
            [fee, outRef 'c' 0, state, outRef 'a' 0]
            `shouldBe` Right ()
    it
        "refuses a fold that leaves out the state, an included request, or spends one it left"
        $ do
            spendsSelection
                state
                [outRef 'a' 0, outRef 'c' 0]
                booked
                [fee, outRef 'a' 0, outRef 'c' 0]
                `shouldSatisfy` isLeft
            spendsSelection
                state
                [outRef 'a' 0, outRef 'c' 0]
                booked
                [fee, state, outRef 'a' 0]
                `shouldSatisfy` isLeft
            spendsSelection
                state
                [outRef 'a' 0, outRef 'c' 0]
                booked
                (state : booked)
                `shouldSatisfy` isLeft
    it
        "admits a spent set exactly when it is the state, the selection and no other pending request"
        $ property
        $ forAll (sublistOf booked)
        $ \chosen ->
            forAll (sublistOf (state : fee : booked)) $ \spent ->
                let exact =
                        state `elem` spent
                            && sort [i | i <- spent, i `elem` booked] == sort chosen
                in  isRight (spendsSelection state chosen booked spent) === exact

-- ---------------------------------------------------------
-- Payouts
-- ---------------------------------------------------------

payouts :: Spec
payouts = describe "each payout reaches its own owner" $ do
    it "finds nothing short when each owner is paid what is owed to them" $
        unpaidOwners
            [(alice, 2_000_000), (bob, 3_000_000)]
            [(bob, 3_000_000), (alice, 2_500_000)]
            `shouldBe` []
    it "names an owner paid another owner's amount" $
        unpaidOwners
            [(alice, 2_000_000), (bob, 3_000_000)]
            [(alice, 3_000_000), (bob, 2_000_000)]
            `shouldBe` [(bob, 3_000_000, 2_000_000)]
    it
        "sums what two requests owe one owner, and names a payment short of the sum"
        $ do
            unpaidOwners
                [(alice, 2_000_000), (alice, 2_000_000), (bob, 1)]
                [(alice, 2_000_000), (bob, 1)]
                `shouldBe` [(alice, 4_000_000, 2_000_000)]
            unpaidOwners
                [(alice, 2_000_000), (alice, 2_000_000)]
                [(alice, 1_000_000), (alice, 3_000_000)]
                `shouldBe` []
    it "names an owner nothing is paid to" $
        unpaidOwners [(alice, 1), (bob, 1)] [(alice, 1)]
            `shouldBe` [(bob, 1, 0)]

-- ---------------------------------------------------------
-- The journal line
-- ---------------------------------------------------------

journalLines :: Spec
journalLines = describe "the journal binds every transition to the fold" $ do
    it
        "chains the transitions from the state's root before to its root after"
        $ do
            let ts =
                    chainTransitions
                        "r0"
                        [ ("aa#0", "6b31", edgeInsertActive, "active:01", "r1")
                        , ("bb#1", "6b32", edgeUpdateTerminal, "terminal", "r2")
                        , ("cc#2", "6b33", edgeInsertActive, "active:03", "r3")
                        ]
            map transitionRootBefore ts `shouldBe` ["r0", "r1", "r2"]
            map transitionRootAfter ts `shouldBe` ["r1", "r2", "r3"]
            map transitionRequest ts `shouldBe` map Just ["aa#0", "bb#1", "cc#2"]
            map transitionKey ts `shouldBe` ["6b31", "6b32", "6b33"]
            map transitionEdge ts
                `shouldBe` [edgeInsertActive, edgeUpdateTerminal, edgeInsertActive]
            map transitionExpect ts
                `shouldBe` ["active:01", "terminal", "active:03"]
    it "reads back the transitions a prepared line was written with" $
        withSystemTempDirectory "fold-journal" $ \dir -> do
            let ts =
                    chainTransitions
                        "r0"
                        [ ("aa#0", "6b31", edgeInsertActive, "active:01", "r1")
                        , ("bb#1", "6b32", edgeInsertActive, "active:02", "r2")
                        ]
            appendJournal dir (prepared "t1" ts)
            [line] <- readJournal dir
            foldTransitions line `shouldBe` ts
            length (foldTransitions line) `shouldBe` 2
    it "reads a line written before batches as a batch of one" $ do
        let old =
                "{\"journalCommand\":\"fold\",\"journalStep\":\"fold\",\"journalTxId\":\"t0\","
                    <> "\"journalEvent\":\"prepared\",\"journalDetail\":null,\"journalInputs\":[],"
                    <> "\"journalBody\":null,\"journalBodyHash\":null,\"journalChainPoint\":null,"
                    <> "\"journalKey\":\"6b31\",\"journalExpect\":\"active:01\",\"journalEdge\":1,"
                    <> "\"journalRootBefore\":\"r0\",\"journalRootAfter\":\"r1\"}"
        case Aeson.eitherDecode (BL.fromStrict (BC.pack old)) of
            Left why -> expectationFailure why
            Right line ->
                foldTransitions line
                    `shouldBe` [FoldTransition Nothing "6b31" 1 "active:01" "r0" "r1"]
    it "binds no transition to a line that folds nothing" $
        foldTransitions
            (blank "t2" "prepared")
                { journalKey = Just "6b31"
                , journalExpect = Just "request"
                }
            `shouldBe` []

blank :: Text -> Text -> JournalEntry
blank tx event =
    JournalEntry
        { journalCommand = "fold"
        , journalStep = "fold"
        , journalTxId = tx
        , journalEvent = event
        , journalDetail = Nothing
        , journalInputs = Nothing
        , journalBody = Nothing
        , journalBodyHash = Nothing
        , journalNetwork = Nothing
        , journalEra = Nothing
        , journalChainPoint = Nothing
        , journalSession = Nothing
        , journalObservedTip = Nothing
        , journalKey = Nothing
        , journalExpect = Nothing
        , journalEdge = Nothing
        , journalRootBefore = Nothing
        , journalRootAfter = Nothing
        , journalTime = Nothing
        , journalTransitions = Nothing
        }

-- | A fold's prepared line over these transitions, with the transaction's root pair.
prepared :: Text -> [FoldTransition] -> JournalEntry
prepared tx ts =
    (blank tx "prepared")
        { journalExpect = Just "fold"
        , journalRootBefore = transitionRootBefore <$> headOf ts
        , journalRootAfter = transitionRootAfter <$> headOf (reverse ts)
        , journalTransitions = Just ts
        }
  where
    headOf (x : _) = Just x
    headOf [] = Nothing

-- ---------------------------------------------------------
-- Reconciliation and rollback
-- ---------------------------------------------------------

envelopeOf :: ByteString -> ByteString -> Envelope
envelopeOf owner key =
    Envelope
        { envControl =
            Control
                { ctlVersion = envelopeVersion
                , ctlRegistry = StateAsset (BS.replicate 28 0x11) "registry"
                , ctlActivePolicy = BS.replicate 28 0x22
                , ctlKey = key
                , ctlController = owner
                , ctlDeposit = 2_000_000
                }
        , envPayload = PLC.I 0
        }

hex :: ByteString -> Text
hex = T.pack . BC.unpack . B16.encode

reconciliation :: Spec
reconciliation = describe "reconciliation covers every included request" $ do
    let keyA = "keyA"
        keyB = "keyB"
        envA = envelopeOf alice keyA
        envB = envelopeOf bob keyB
        root n = hex (BS.replicate 32 n)
        holding =
            ( outRef '9' 0
            , mkBasicTxOut
                (addrFromKeyHashBytes Testnet alice)
                (MaryValue (Coin 1) mempty)
            )
        -- The fold's first output: the registry's state, at this root.
        stateAt r =
            snd holding
                & datumTxOutL
                    .~ mkInlineDatum
                        ( toPlcData
                            ( StateDatum
                                OnChainTokenState
                                    { stateRoot = OnChainRoot (BS.replicate 32 r)
                                    , stateMaxFee = 1_000_000
                                    , stateProcessTime = processTime
                                    , stateRetractTime = 30_000
                                    , stateAppPolicy = toBuiltin (BS.replicate 28 1)
                                    , stateActivePolicy = toBuiltin (BS.replicate 28 2)
                                    , stateAbsentPolicy = toBuiltin (BS.replicate 28 3)
                                    , stateTerminalPolicy = toBuiltin (BS.replicate 28 4)
                                    }
                            )
                        )
        ts =
            chainTransitions
                (root 0)
                [
                    ( "aa#0"
                    , hex keyA
                    , edgeInsertActive
                    , "active:" <> hex (envelopeHash envA)
                    , root 1
                    )
                , ("bb#0", hex keyB, edgeUpdateTerminal, "terminal", root 2)
                ]
        recovery out0 p =
            Recovery
                { recTx = journalTxId p
                , recStep = "fold"
                , recIncluded = True
                , recExcluded = False
                , recNote = ""
                , recPrepared = Just p
                , recFirstOutput = Just out0
                , recBody = Nothing
                , recLast = blank (journalTxId p) "confirmed"
                }
        reader settled key
            | key == keyA = pure (Right Active, Right (holding, envA))
            | key == keyB && settled = pure (Right Terminal, Left "no holding")
            | otherwise = pure (Right Active, Right (holding, envB))
        observedLines dir = filter ((== "observed") . journalEvent) <$> readJournal dir
    it "observes a two-request fold once its root and every key read back" $
        withSystemTempDirectory "fold-observe" $ \dir -> do
            verdicts <-
                observe
                    "update"
                    dir
                    (Just (reader True))
                    [recovery (stateAt 2) (prepared "t1" ts)]
            map fst verdicts `shouldBe` ["t1"]
            map (map isRight . snd) verdicts `shouldBe` [[True, True, True]]
            seen <- observedLines dir
            map journalTxId seen `shouldBe` ["t1"]
            forM_ [hex keyA, hex keyB, root 2] $ \w ->
                fmap (T.isInfixOf w) (journalDetail =<< headOrNothing seen)
                    `shouldBe` Just True
    it
        "does not observe it while one included key has not reached its after-state" $
        withSystemTempDirectory "fold-observe" $ \dir -> do
            verdicts <-
                observe
                    "update"
                    dir
                    (Just (reader False))
                    [recovery (stateAt 2) (prepared "t1" ts)]
            map (map isRight . snd) verdicts `shouldBe` [[True, True, False]]
            observedLines dir >>= (`shouldBe` [])
    it "does not observe it while the state output carries another root" $
        withSystemTempDirectory "fold-observe" $ \dir -> do
            verdicts <-
                observe
                    "update"
                    dir
                    (Just (reader True))
                    [recovery (stateAt 1) (prepared "t1" ts)]
            map (map isRight . snd) verdicts `shouldBe` [[False, True, True]]
            observedLines dir >>= (`shouldBe` [])
    it
        "reads a key the batch moves twice against its last transition only" $
        withSystemTempDirectory "fold-observe" $ \dir -> do
            let twice =
                    chainTransitions
                        (root 0)
                        [
                            ( "aa#0"
                            , hex keyB
                            , edgeInsertActive
                            , "active:" <> hex (envelopeHash envB)
                            , root 1
                            )
                        ,
                            ( "bb#0"
                            , hex keyA
                            , edgeInsertActive
                            , "active:" <> hex (envelopeHash envA)
                            , root 2
                            )
                        , ("cc#0", hex keyB, edgeUpdateTerminal, "terminal", root 3)
                        ]
            verdicts <-
                observe
                    "update"
                    dir
                    (Just (reader True))
                    [recovery (stateAt 3) (prepared "t3" twice)]
            map (map isRight . snd) verdicts `shouldBe` [[True, True, True]]
            map journalTxId <$> observedLines dir >>= (`shouldBe` ["t3"])
            stale <-
                observe
                    "update"
                    dir
                    (Just (reader False))
                    [recovery (stateAt 3) (prepared "t4" twice)]
            map (map isRight . snd) stale `shouldBe` [[True, False, True]]
    it
        "still observes a fold journalled before batches, as a batch of one" $
        withSystemTempDirectory "fold-observe" $ \dir -> do
            let old =
                    (blank "t0" "prepared")
                        { journalKey = Just (hex keyA)
                        , journalEdge = Just edgeInsertActive
                        , journalExpect = Just ("active:" <> hex (envelopeHash envA))
                        , journalRootBefore = Just (root 0)
                        , journalRootAfter = Just (root 1)
                        }
            verdicts <-
                observe "update" dir (Just (reader True)) [recovery (stateAt 1) old]
            map (map isRight . snd) verdicts `shouldBe` [[True, True]]
            map journalTxId <$> observedLines dir >>= (`shouldBe` ["t0"])
    it
        "returns every included request to pending and restores the root before" $ do
        let p = prepared "t1" ts
            tip = TipObservation (SlotNo 7) (BS.replicate 32 0) 1 0
            line =
                rolledBackLine
                    "update"
                    (blank "t1" "observed")
                    (Just p)
                    [outRef 'a' 0, outRef 'b' 0, outRef '5' 0]
                    tip
        journalEvent line `shouldBe` "rolled-back"
        journalTransitions line `shouldBe` Just ts
        map transitionRequest (foldTransitions line)
            `shouldBe` map Just ["aa#0", "bb#0"]
        journalRootBefore line `shouldBe` Just (root 0)
  where
    headOrNothing (x : _) = Just x
    headOrNothing [] = Nothing
