{-# LANGUAGE GADTs #-}

-- | Programs over the seven model edges. Handles remain opaque to stories.
module Conformance.Story.Live (
    Edge (..), edgeName, EdgeRequest (..), Tamper (..), tamperName,
    LiveI (..), Story, Context (..), submit, tamper, observe,
    compareWithModel, renderLive, validateLive,
) where

import Control.Monad.Operational (Program, ProgramViewT (Return, (:>>=)), view)
import Conformance.Story.Specification (Step (..), Clause (..), TheoremStory, action, checkAction, clauses, theoremBinding)
import Conformance.Story.Specification qualified as Specification
import Conformance.Story.Binding (Binding, BoundObligation (..))

data Edge
    = InsertAbsent | InsertActive | UpdateActive | UpdateTerminal
    | DeleteAbsent | DeleteActive | WitnessTerminal
    deriving stock (Eq, Ord, Show, Enum, Bounded)

edgeName :: Edge -> String
edgeName edge = case edge of
    InsertAbsent -> "insertAbsent"
    InsertActive -> "insertActive"
    UpdateActive -> "updateActive"
    UpdateTerminal -> "updateTerminal"
    DeleteAbsent -> "deleteAbsent"
    DeleteActive -> "deleteActive"
    WitnessTerminal -> "witnessTerminal"

data EdgeRequest wal = EdgeRequest
    { requestEdge :: Edge
    , requestKey :: String
    , requestWallet :: wal
    }
    deriving stock (Eq, Show)

{- | A change to the submitted transaction the model's request does not make.
'OtherAddress' sends the payment the exit owes to another address, and
'ShortByOne' pays it one lovelace short; the ledger must refuse both, and the
model must refuse them for the reason it gives. 'ExtraSigner' adds one
required signer the model does not require; the ledger accepts it, and the
comparison must report the transaction's signers.
-}
data Tamper = OtherAddress | ShortByOne | ExtraSigner
    deriving stock (Eq, Show, Enum, Bounded)

tamperName :: Tamper -> String
tamperName OtherAddress = "other-address"
tamperName ShortByOne = "short-by-one"
tamperName ExtraSigner = "extra-signer"

type Story reg wal step obs cmp = Specification.Story (LiveI reg wal step obs cmp)

data Context reg wal = Context reg wal

data LiveI reg wal step obs cmp result where
    Submit :: reg -> EdgeRequest wal -> LiveI reg wal step obs cmp step
    Tamper :: Tamper -> reg -> EdgeRequest wal -> LiveI reg wal step obs cmp step
    Observe :: step -> LiveI reg wal step obs cmp obs
    Compare :: step -> obs -> LiveI reg wal step obs cmp cmp

submit :: reg -> EdgeRequest wal -> Story reg wal step obs cmp step
submit registry request = action (Submit registry request)

tamper :: Tamper -> reg -> EdgeRequest wal -> Story reg wal step obs cmp step
tamper alteration registry request = action (Tamper alteration registry request)

observe :: step -> Story reg wal step obs cmp obs
observe = action . Observe

compareWithModel :: step -> obs -> Story reg wal step obs cmp cmp
compareWithModel step observation = action (Compare step observation)

-- | Check instruction order over the same program with display-only handles,
-- before a runner can submit a transaction.
validateLive :: Story String String String String String res -> Either String ()
validateLive program = do
    (end, _) <- walk Ready program
    if end == Ready then Right () else Left "live story ended before Observe and Compare"
  where
    walk :: PreflightPhase -> Story String String String String String a -> Either String (PreflightPhase, a)
    walk phase body = case view body of
        Return result -> Right (phase, result)
        Action instruction :>>= rest -> case instruction of
            Submit _ _ -> advance Ready NeedObserve "preflight step"
            Tamper _ _ _ -> advance Ready NeedObserve "preflight step"
            Observe _ -> advance NeedObserve NeedCompare "preflight observation"
            Compare _ _ -> advance NeedCompare Ready "preflight comparison"
          where
            advance expected nextPhase value
                | phase == expected = walk nextPhase (rest value)
                | otherwise = Left "live story must Submit or Tamper, Observe, then Compare"
        Theorem _ body' :>>= rest -> do
            (afterClauses, result) <- walkClauses phase (Specification.clauses body')
            walk afterClauses (rest result)
    walkClauses :: PreflightPhase -> Program (Clause thm (LiveI String String String String String)) a -> Either String (PreflightPhase, a)
    walkClauses phase body = case view body of
        Return result -> Right (phase, result)
        Clause _ check actions :>>= rest -> do
            (afterActions, observation) <- walk phase actions
            (afterCheck, ()) <- walk afterActions (Specification.checkAction check observation)
            walkClauses afterCheck (rest observation)

data PreflightPhase = Ready | NeedObserve | NeedCompare
    deriving stock (Eq)

renderLive :: Story String String String String String res -> String
renderLive = fst . renderWithResult

renderWithResult :: Story String String String String String res -> (String, res)
renderWithResult program = case view program of
    Return result -> ("", result)
    Action instruction :>>= rest -> renderAction instruction rest
    Theorem binding body :>>= rest ->
        let (text, result) = renderClauses body
         in prepend (formal (theoremBinding binding) <> text) (renderWithResult (rest result))

renderClauses :: TheoremStory thm (LiveI String String String String String) res -> (String, res)
renderClauses = renderClauseProgram . clauses

renderClauseProgram :: Program (Clause thm (LiveI String String String String String)) res -> (String, res)
renderClauseProgram program = case view program of
    Return result -> ("", result)
    Clause title check body :>>= rest ->
        let (text, result) = renderWithResult body
            (checked, ()) = renderWithResult (checkAction check result)
         in prepend ("### " <> title <> "\n\n" <> text <> checked)
                (renderClauseProgram (rest result))

renderAction :: LiveI String String String String String obs -> (obs -> Story String String String String String res) -> (String, res)
renderAction instruction rest = case instruction of
    Submit registry request ->
        step ("Submit **" <> edgeName (requestEdge request) <> "** for **" <> requestKey request
            <> "** in **" <> registry <> "**, using the " <> requestWallet request <> ".")
            (rest (requestKey request))
    Tamper OtherAddress registry request ->
        step ("Submit **" <> edgeName (requestEdge request) <> "** for **" <> requestKey request
            <> "** in **" <> registry <> "** with the payment it owes sent to another address. The ledger and the model must both refuse it; the same request untampered is its control.")
            (rest (requestKey request))
    Tamper ShortByOne registry request ->
        step ("Submit **" <> edgeName (requestEdge request) <> "** for **" <> requestKey request
            <> "** in **" <> registry <> "** with the payment it owes one lovelace short. The ledger and the model must both refuse it; the same request untampered is its control.")
            (rest (requestKey request))
    Tamper ExtraSigner registry request ->
        step ("Submit **" <> edgeName (requestEdge request) <> "** for **" <> requestKey request
            <> "** in **" <> registry <> "** with one required signer the model does not require. The ledger accepts it; the comparison must report the difference in the transaction's signers.")
            (rest (requestKey request))
    Observe handle ->
        step ("Observe the complete registry, token, leaf and transaction boundary after **" <> handle <> "**.")
            (rest ("observations for " <> handle))
    Compare handle _ ->
        step ("Compare **" <> handle <> "** and its observation with the executable registry model.")
            (rest ("comparison for " <> handle))
  where
    step sentence next = prepend ("- " <> sentence <> "\n\n") (renderWithResult next)

prepend :: String -> (String, res) -> (String, res)
prepend prefix (text, result) = (prefix <> text, result)

formal :: Binding -> String
formal binding = "Formal specification: `" <> boName binding <> "` @ `" <> boRevision binding
    <> "`. Statement digest: `" <> boDigest binding <> "`.\n\n"
