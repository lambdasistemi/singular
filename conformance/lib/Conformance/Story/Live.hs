{-# LANGUAGE GADTs #-}

-- | Live stories carry their registry, wallets and previous results explicitly.
-- The interpreter chooses the concrete handle types; stories never construct
-- transaction results or receipts. The renderer uses names for those handles.
module Conformance.Story.Live (
    LiveI (..), Story, Context (..), RegistrationRun (..), RetirementRun (..),
    linkedTo,
    registerKey, expectActiveToken, registerFreshKey,
    expectDuplicateRegistrationRefused, compareBatchAllocation,
    retireRegistration, expectRetired, expectAbsentRetirementRefused,
    expectUnknownRetirementRefused, renderLive,
) where

import Control.Monad.Operational (Program, ProgramViewT (Return, (:>>=)), view)
import Conformance.Story.Specification (Step (..), Clause (..), TheoremStory, action, checkAction, clauses, theoremBinding)
import Conformance.Story.Specification qualified as Specification
import Conformance.Story.Binding (Binding, BoundObligation (..))

-- | A story can only use a registry or result returned by its interpreter.
type Story reg wal ins ret bat ref = Specification.Story (LiveI reg wal ins ret bat ref)

-- | Resources are established by the caller, outside the reusable story.
data Context reg wal = Context reg wal

-- | The shared instruction set for the devnet runner and the book.
data LiveI reg wal ins ret bat ref res where
    LinkedTo :: Binding -> [String] -> LiveI reg wal ins ret bat ref ()
    CheckRetirementEffect :: ret -> LiveI reg wal ins ret bat ref ()
    CheckRegistrationDelivery :: ins -> LiveI reg wal ins ret bat ref ()
    RegisterKey :: reg -> String -> wal -> LiveI reg wal ins ret bat ref ins
    ExpectActiveToken :: ins -> wal -> Integer -> LiveI reg wal ins ret bat ref ()
    RegisterFreshKey :: reg -> String -> wal -> LiveI reg wal ins ret bat ref ins
    ExpectDuplicateRegistrationRefused :: reg -> ins -> ins -> LiveI reg wal ins ret bat ref ref
    CompareBatchAllocation :: reg -> wal -> String -> String -> LiveI reg wal ins ret bat ref bat
    RetireRegistration :: reg -> ins -> LiveI reg wal ins ret bat ref ret
    ExpectRetired :: ret -> Integer -> LiveI reg wal ins ret bat ref ()
    ExpectAbsentRetirementRefused :: reg -> wal -> ret -> String -> LiveI reg wal ins ret bat ref ref
    ExpectUnknownRetirementRefused :: reg -> ret -> String -> LiveI reg wal ins ret bat ref ref

-- | Results needed to publish registration evidence; supplied by the live run.
data RegistrationRun reg ins bat ref = RegistrationRun
    { registrationRegistry :: reg
    , registeredKey :: ins
    , freshKeyControl :: ins
    , batchAllocation :: bat
    , duplicateRefusal :: ref
    }

-- | Retirement starts from a real registration and keeps both refusal controls.
data RetirementRun ins ret ref = RetirementRun
    { retirementRegistration :: ins
    , retiredRegistration :: ret
    , absentRefusal :: ref
    , unknownControl :: ret
    , unknownRefusal :: ref
    }

-- | Check the specification identity before running its story.
linkedTo :: Binding -> [String] -> Story reg wal ins ret bat ref ()
linkedTo binding rules = action (LinkedTo binding rules)

-- | Submit an approved request and apply it to the registry.
registerKey :: reg -> String -> wal -> Story reg wal ins ret bat ref ins
registerKey registry key wallet = action (RegisterKey registry key wallet)

-- | Query the recipient and inspect the transaction that actually delivered it.
expectActiveToken :: ins -> wal -> Integer -> Story reg wal ins ret bat ref ()
expectActiveToken registration wallet quantity = action (ExpectActiveToken registration wallet quantity)

-- | Accept a fresh key through the same assembly used by the duplicate attempt.
registerFreshKey :: reg -> String -> wal -> Story reg wal ins ret bat ref ins
registerFreshKey registry key wallet = action (RegisterFreshKey registry key wallet)

-- | Submit the duplicate and require a state-script rejection on the node.
expectDuplicateRegistrationRefused :: reg -> ins -> ins -> Story reg wal ins ret bat ref ref
expectDuplicateRegistrationRefused registry registration control =
    action (ExpectDuplicateRegistrationRefused registry registration control)

-- | Submit a balanced but misallocated batch, then apply the correct allocation.
compareBatchAllocation :: reg -> wal -> String -> String -> Story reg wal ins ret bat ref bat
compareBatchAllocation registry recipient first second =
    action (CompareBatchAllocation registry recipient first second)

-- | Spend the token delivered by this registration to retire the same key.
retireRegistration :: reg -> ins -> Story reg wal ins ret bat ref ret
retireRegistration registry registration = action (RetireRegistration registry registration)

-- | Check the holder's remaining quantity, exact burn, source input and Terminal state.
expectRetired :: ret -> Integer -> Story reg wal ins ret bat ref ()
expectRetired retirement quantity = action (ExpectRetired retirement quantity)

-- | Establish an Absent key by a real transaction, then attempt to retire it.
expectAbsentRetirementRefused :: reg -> wal -> ret -> String -> Story reg wal ins ret bat ref ref
expectAbsentRetirementRefused registry wallet control key =
    action (ExpectAbsentRetirementRefused registry wallet control key)

-- | Attempt to retire a never-registered key beside a successful retirement.
expectUnknownRetirementRefused :: reg -> ret -> String -> Story reg wal ins ret bat ref ref
expectUnknownRetirementRefused registry control key =
    action (ExpectUnknownRetirementRefused registry control key)

-- | Render the same context and actions the backend executes. No instruction
-- is hidden behind a catch-all; returned handles retain their names and keys.
renderLive :: Story String String String String String String res -> String
renderLive = fst . renderWithResult

renderWithResult :: Story String String String String String String res -> (String, res)
renderWithResult program = case view program of
    Return result -> ("", result)
    Action instruction :>>= rest -> renderAction instruction rest
    Theorem binding body :>>= rest ->
        let (text, result) = renderClauses body
        in prepend (formal (theoremBinding binding) <> text) (renderWithResult (rest result))

renderClauses :: TheoremStory thm (LiveI String String String String String String) res -> (String, res)
renderClauses = renderClauseProgram . clauses

renderClauseProgram :: Program (Clause thm (LiveI String String String String String String)) res -> (String, res)
renderClauseProgram program = case view program of
    Return result -> ("", result)
    Clause title check body :>>= rest ->
        let (text, result) = renderWithResult body
            (checked, ()) = renderWithResult (action (checkAction check result))
        in prepend ("### " <> title <> "\n\n" <> text <> checked)
            (renderClauseProgram (rest result))

renderAction :: LiveI String String String String String String obs -> (obs -> Story String String String String String String res) -> (String, res)
renderAction instruction rest = case instruction of
    CheckRetirementEffect _retirement ->
        step "Compare the burn, spent witness, remaining holdings and committed leaf with the Lean retirement result." (rest ())
    CheckRegistrationDelivery _registration ->
        step "Compare the observed delivery and queried holdings with the Lean executable's result." (rest ())
    LinkedTo binding rules ->
        prepend (formal binding <> "```text\n" <> unlines rules <> "```\n\n") (renderWithResult (rest ()))
    RegisterKey registry key wallet ->
        step ("Request registration of **" <> key <> "** in **" <> registry
            <> "**, deliver to the " <> wallet <> ", and apply the request on chain.") (rest key)
    ExpectActiveToken key wallet quantity ->
        step ("Check on chain that the " <> wallet <> " holds exactly **" <> show quantity
            <> " active token(s)** for **" <> key <> "**; check its policy, destination, mint and resulting registry state.") (rest ())
    RegisterFreshKey registry key wallet ->
        step ("Successfully register the fresh key **" <> key <> "** in **" <> registry
            <> "** for the " <> wallet <> ", through the transaction builder used by the duplicate attempt.") (rest key)
    ExpectDuplicateRegistrationRefused registry key control ->
        step ("Try to register **" <> key <> "** again in **" <> registry
            <> "**. Require the state script to reject it; **" <> control <> "** is the successful comparison.") (rest ("duplicate " <> key))
    CompareBatchAllocation registry wallet first second ->
        step ("Request **" <> first <> "** and **" <> second <> "** in **" <> registry
            <> "** for the " <> wallet <> ". Submit a balanced transaction putting both tokens at the first key: require a state-script rejection. Apply the same requests with one token per key: require success and read back the allocation.") (rest (first <> " and " <> second))
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
