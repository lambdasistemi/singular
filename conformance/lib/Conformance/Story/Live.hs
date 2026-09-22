{-# LANGUAGE GADTs #-}

-- | Programs over the seven model edges. Handles remain opaque to stories.
module Conformance.Story.Live (
    Edge (..), edgeName, EdgeRequest (..), Tamper (..), tamperName,
    LiveI (..), Story, Context (..), submit, tamper, observe,
    compareWithModel, renderLive,
    RetirementRun (..), registerKey, expectActiveToken, retireRegistration,
    expectRetired, expectAbsentRetirementRefused, expectUnknownRetirementRefused,
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

data Tamper = RedirectDelivery
    deriving stock (Eq, Show, Enum, Bounded)

tamperName :: Tamper -> String
tamperName RedirectDelivery = "redirect-delivery"

type Story reg wal step obs cmp ins ret bat ref = Specification.Story (LiveI reg wal step obs cmp ins ret bat ref)

data Context reg wal = Context reg wal

data LiveI reg wal step obs cmp ins ret bat ref result where
    Submit :: reg -> EdgeRequest wal -> LiveI reg wal step obs cmp ins ret bat ref step
    Tamper :: Tamper -> reg -> EdgeRequest wal -> LiveI reg wal step obs cmp ins ret bat ref step
    Observe :: step -> LiveI reg wal step obs cmp ins ret bat ref obs
    Compare :: step -> obs -> LiveI reg wal step obs cmp ins ret bat ref cmp
    -- The retirement chapter is migrated in the next bisect-safe slice.
    CheckRetirementEffect :: ret -> LiveI reg wal step obs cmp ins ret bat ref ()
    CheckRegistrationDelivery :: ins -> LiveI reg wal step obs cmp ins ret bat ref ()
    RegisterKey :: reg -> String -> wal -> LiveI reg wal step obs cmp ins ret bat ref ins
    ExpectActiveToken :: ins -> wal -> Integer -> LiveI reg wal step obs cmp ins ret bat ref ()
    RetireRegistration :: reg -> ins -> LiveI reg wal step obs cmp ins ret bat ref ret
    ExpectRetired :: ret -> Integer -> LiveI reg wal step obs cmp ins ret bat ref ()
    ExpectAbsentRetirementRefused :: reg -> wal -> ret -> String -> LiveI reg wal step obs cmp ins ret bat ref ref
    ExpectUnknownRetirementRefused :: reg -> ret -> String -> LiveI reg wal step obs cmp ins ret bat ref ref

data RetirementRun step obs ref = RetirementRun
    { retirementRegistration :: step
    , retiredRegistration :: obs
    , absentRefusal :: ref
    , unknownControl :: obs
    , unknownRefusal :: ref
    }

submit :: reg -> EdgeRequest wal -> Story reg wal step obs cmp ins ret bat ref step
submit registry request = action (Submit registry request)

tamper :: Tamper -> reg -> EdgeRequest wal -> Story reg wal step obs cmp ins ret bat ref step
tamper alteration registry request = action (Tamper alteration registry request)

observe :: step -> Story reg wal step obs cmp ins ret bat ref obs
observe = action . Observe

compareWithModel :: step -> obs -> Story reg wal step obs cmp ins ret bat ref cmp
compareWithModel step observation = action (Compare step observation)

registerKey :: reg -> String -> wal -> Story reg wal step obs cmp ins ret bat ref ins
registerKey registry key wallet = action (RegisterKey registry key wallet)

expectActiveToken :: ins -> wal -> Integer -> Story reg wal step obs cmp ins ret bat ref ()
expectActiveToken step wallet quantity = action (ExpectActiveToken step wallet quantity)

retireRegistration :: reg -> ins -> Story reg wal step obs cmp ins ret bat ref ret
retireRegistration registry step = action (RetireRegistration registry step)

expectRetired :: ret -> Integer -> Story reg wal step obs cmp ins ret bat ref ()
expectRetired result quantity = action (ExpectRetired result quantity)

expectAbsentRetirementRefused :: reg -> wal -> ret -> String -> Story reg wal step obs cmp ins ret bat ref ref
expectAbsentRetirementRefused registry wallet control key = action (ExpectAbsentRetirementRefused registry wallet control key)

expectUnknownRetirementRefused :: reg -> ret -> String -> Story reg wal step obs cmp ins ret bat ref ref
expectUnknownRetirementRefused registry control key = action (ExpectUnknownRetirementRefused registry control key)

renderLive :: Story String String String String String String String String String res -> String
renderLive = fst . renderWithResult

renderWithResult :: Story String String String String String String String String String res -> (String, res)
renderWithResult program = case view program of
    Return result -> ("", result)
    Action instruction :>>= rest -> renderAction instruction rest
    Theorem binding body :>>= rest ->
        let (text, result) = renderClauses body
         in prepend (formal (theoremBinding binding) <> text) (renderWithResult (rest result))

renderClauses :: TheoremStory thm (LiveI String String String String String String String String String) res -> (String, res)
renderClauses = renderClauseProgram . clauses

renderClauseProgram :: Program (Clause thm (LiveI String String String String String String String String String)) res -> (String, res)
renderClauseProgram program = case view program of
    Return result -> ("", result)
    Clause title check body :>>= rest ->
        let (text, result) = renderWithResult body
            (checked, ()) = renderWithResult (checkAction check result)
         in prepend ("### " <> title <> "\n\n" <> text <> checked)
                (renderClauseProgram (rest result))

renderAction :: LiveI String String String String String String String String String obs -> (obs -> Story String String String String String String String String String res) -> (String, res)
renderAction instruction rest = case instruction of
    Submit registry request ->
        step ("Submit **" <> edgeName (requestEdge request) <> "** for **" <> requestKey request
            <> "** in **" <> registry <> "**, using the " <> requestWallet request <> ".")
            (rest (requestKey request))
    Tamper RedirectDelivery registry request ->
        step ("Submit **" <> edgeName (requestEdge request) <> "** for **" <> requestKey request
            <> "** in **" <> registry <> "** with redirect delivery. The same request without redirection is the untampered control.")
            (rest (requestKey request))
    Observe handle ->
        step ("Observe the complete registry, token, leaf and transaction boundary after **" <> handle <> "**.")
            (rest ("observations for " <> handle))
    Compare handle _ ->
        step ("Compare **" <> handle <> "** and its observation with the executable registry model.")
            (rest ("comparison for " <> handle))
    CheckRetirementEffect _ ->
        step "Compare the burn, spent witness, remaining holdings and committed leaf with the Lean retirement result." (rest ())
    CheckRegistrationDelivery _ ->
        step "Compare the observed delivery and queried holdings with the Lean executable's result." (rest ())
    RegisterKey registry key wallet ->
        step ("Request registration of **" <> key <> "** in **" <> registry
            <> "**, deliver to the " <> wallet <> ", and apply the request on chain.") (rest key)
    ExpectActiveToken key wallet quantity ->
        step ("Check on chain that the " <> wallet <> " holds exactly **" <> show quantity
            <> " active token(s)** for **" <> key <> "**; check its policy, destination, mint and resulting registry state.") (rest ())
    RetireRegistration registry key ->
        step ("Request retirement of the **" <> key <> "** registration just created in **" <> registry
            <> "**. Apply it using the active token held by its recipient.") (rest key)
    ExpectRetired key quantity ->
        step ("Check that **" <> key <> "** now has a Terminal leaf, the holder has **" <> show quantity
            <> " active token(s)** remaining, and exactly its original token was consumed and burned.") (rest ())
    ExpectAbsentRetirementRefused registry wallet control key ->
        step ("In **" <> registry <> "**, establish **" <> key
            <> "** as Absent for the " <> wallet <> " through a real transaction, then try to retire it. Require a script rejection, compared with the successful retirement of **" <> control <> "**.") (rest ("absent " <> key))
    ExpectUnknownRetirementRefused registry control key ->
        step ("Try to retire **" <> key <> "**, which was never registered in **" <> registry
            <> "**. Require a script rejection, compared with the successful retirement of **" <> control <> "** in this same registry.") (rest ("unknown " <> key))
  where
    step sentence next = prepend ("- " <> sentence <> "\n\n") (renderWithResult next)

prepend :: String -> (String, res) -> (String, res)
prepend prefix (text, result) = (prefix <> text, result)

formal :: Binding -> String
formal binding = "Formal specification: `" <> boName binding <> "` @ `" <> boRevision binding
    <> "`. Statement digest: `" <> boDigest binding <> "`.\n\n"
