{-# LANGUAGE GADTs #-}

-- | Live stories carry their registry, wallets and previous results explicitly.
-- The interpreter chooses the concrete handle types; stories never construct
-- transaction results or receipts. The renderer uses names for those handles.
module Conformance.Story.Live (
    LiveI (..), Story, Context (..), theorem, clause, RegistrationRun (..), RetirementRun (..),
    linkedTo,
    registerKey, expectActiveToken, registerFreshKey,
    expectDuplicateRegistrationRefused, compareBatchAllocation,
    retireRegistration, expectRetired, expectAbsentRetirementRefused,
    expectUnknownRetirementRefused, renderLive,
) where

import Control.Monad.Operational (Program, ProgramViewT (Return, (:>>=)), singleton, view)
import Conformance.Lean.Registration (DeliveryCheck)
import Conformance.Story.Binding (Binding, BoundObligation (..))

-- | A story can only use a registry or result returned by its interpreter.
type Story r w a t b f = Program (LiveI r w a t b f)

-- | Resources are established by the caller, outside the reusable story.
data Context r w = Context r w

-- | The shared instruction set for the devnet runner and the book.
data LiveI r w a t b f result where
    LinkedTo :: Binding -> [String] -> LiveI r w a t b f ()
    Theorem :: Binding -> Story r w a t b f result -> LiveI r w a t b f result
    Clause :: String -> DeliveryCheck -> Story r w a t b f a -> LiveI r w a t b f a
    RegisterKey :: r -> String -> w -> LiveI r w a t b f a
    ExpectActiveToken :: a -> w -> Integer -> LiveI r w a t b f ()
    RegisterFreshKey :: r -> String -> w -> LiveI r w a t b f a
    ExpectDuplicateRegistrationRefused :: r -> a -> a -> LiveI r w a t b f f
    CompareBatchAllocation :: r -> w -> String -> String -> LiveI r w a t b f b
    RetireRegistration :: r -> a -> LiveI r w a t b f t
    ExpectRetired :: t -> Integer -> LiveI r w a t b f ()
    ExpectAbsentRetirementRefused :: r -> w -> t -> String -> LiveI r w a t b f f
    ExpectUnknownRetirementRefused :: r -> t -> String -> LiveI r w a t b f f

-- | Results needed to publish registration evidence; supplied by the live run.
data RegistrationRun r a b f = RegistrationRun
    { registrationRegistry :: r
    , registeredKey :: a
    , freshKeyControl :: a
    , batchAllocation :: b
    , duplicateRefusal :: f
    }

-- | Retirement starts from a real registration and keeps both refusal controls.
data RetirementRun a t f = RetirementRun
    { retirementRegistration :: a
    , retiredRegistration :: t
    , absentRefusal :: f
    , unknownControl :: t
    , unknownRefusal :: f
    }

-- | Check the specification identity before running its story.
linkedTo :: Binding -> [String] -> Story r w a t b f ()
linkedTo binding rules = singleton (LinkedTo binding rules)

-- | Bind the enclosed executable clauses to their governing theorem.
theorem :: Binding -> Story r w a t b f result -> Story r w a t b f result
theorem binding body = singleton (Theorem binding body)

-- | Run a registration, check its observations with Lean, then return its handle.
clause :: String -> DeliveryCheck -> Story r w a t b f a -> Story r w a t b f a
clause title check body = singleton (Clause title check body)

-- | Submit an approved request and apply it to the registry.
registerKey :: r -> String -> w -> Story r w a t b f a
registerKey registry key wallet = singleton (RegisterKey registry key wallet)

-- | Query the recipient and inspect the transaction that actually delivered it.
expectActiveToken :: a -> w -> Integer -> Story r w a t b f ()
expectActiveToken registration wallet quantity = singleton (ExpectActiveToken registration wallet quantity)

-- | Accept a fresh key through the same assembly used by the duplicate attempt.
registerFreshKey :: r -> String -> w -> Story r w a t b f a
registerFreshKey registry key wallet = singleton (RegisterFreshKey registry key wallet)

-- | Submit the duplicate and require a state-script rejection on the node.
expectDuplicateRegistrationRefused :: r -> a -> a -> Story r w a t b f f
expectDuplicateRegistrationRefused registry registration control =
    singleton (ExpectDuplicateRegistrationRefused registry registration control)

-- | Submit a balanced but misallocated batch, then apply the correct allocation.
compareBatchAllocation :: r -> w -> String -> String -> Story r w a t b f b
compareBatchAllocation registry recipient first second =
    singleton (CompareBatchAllocation registry recipient first second)

-- | Spend the token delivered by this registration to retire the same key.
retireRegistration :: r -> a -> Story r w a t b f t
retireRegistration registry registration = singleton (RetireRegistration registry registration)

-- | Check the holder's remaining quantity, exact burn, source input and Terminal state.
expectRetired :: t -> Integer -> Story r w a t b f ()
expectRetired retirement quantity = singleton (ExpectRetired retirement quantity)

-- | Establish an Absent key by a real transaction, then attempt to retire it.
expectAbsentRetirementRefused :: r -> w -> t -> String -> Story r w a t b f f
expectAbsentRetirementRefused registry wallet control key =
    singleton (ExpectAbsentRetirementRefused registry wallet control key)

-- | Attempt to retire a never-registered key beside a successful retirement.
expectUnknownRetirementRefused :: r -> t -> String -> Story r w a t b f f
expectUnknownRetirementRefused registry control key =
    singleton (ExpectUnknownRetirementRefused registry control key)

-- | Render the same context and actions the backend executes. No instruction
-- is hidden behind a catch-all; returned handles retain their names and keys.
renderLive :: Story String String String String String String result -> String
renderLive = fst . renderWithResult

renderWithResult :: Story String String String String String String result -> (String, result)
renderWithResult program = case view program of
    Return result -> ("", result)
    LinkedTo binding rules :>>= rest ->
        prepend (formal binding <> "```text\n" <> unlines rules <> "```\n\n") (renderWithResult (rest ()))
    Theorem binding body :>>= rest ->
        let (text, result) = renderWithResult body
        in prepend (formal binding <> text) (renderWithResult (rest result))
    Clause title _check body :>>= rest ->
        let (text, result) = renderWithResult body
        in prepend ("### " <> title <> "\n\n" <> text
            <> "- Compare the observed delivery and queried holdings with the Lean executable's result.\n\n")
            (renderWithResult (rest result))
    RegisterKey registry key wallet :>>= rest ->
        step ("Request registration of **" <> key <> "** in **" <> registry
            <> "**, deliver to the " <> wallet <> ", and apply the request on chain.") (rest key)
    ExpectActiveToken key wallet quantity :>>= rest ->
        step ("Check on chain that the " <> wallet <> " holds exactly **" <> show quantity
            <> " active token(s)** for **" <> key <> "**; check its policy, destination, mint and resulting registry state.") (rest ())
    RegisterFreshKey registry key wallet :>>= rest ->
        step ("Successfully register the fresh key **" <> key <> "** in **" <> registry
            <> "** for the " <> wallet <> ", through the transaction builder used by the duplicate attempt.") (rest key)
    ExpectDuplicateRegistrationRefused registry key control :>>= rest ->
        step ("Try to register **" <> key <> "** again in **" <> registry
            <> "**. Require the state script to reject it; **" <> control <> "** is the successful comparison.") (rest ("duplicate " <> key))
    CompareBatchAllocation registry wallet first second :>>= rest ->
        step ("Request **" <> first <> "** and **" <> second <> "** in **" <> registry
            <> "** for the " <> wallet <> ". Submit a balanced transaction putting both tokens at the first key: require a state-script rejection. Apply the same requests with one token per key: require success and read back the allocation.") (rest (first <> " and " <> second))
    RetireRegistration registry key :>>= rest ->
        step ("Request retirement of the **" <> key <> "** registration just created in **" <> registry
            <> "**. Apply it using the active token held by its recipient.") (rest key)
    ExpectRetired key quantity :>>= rest ->
        step ("Check that **" <> key <> "** now has a Terminal leaf, the holder has **" <> show quantity
            <> " active token(s)** remaining, and exactly its original token was consumed and burned.") (rest ())
    ExpectAbsentRetirementRefused registry wallet control key :>>= rest ->
        step ("In **" <> registry <> "**, establish **" <> key
            <> "** as Absent for the " <> wallet <> " through a real transaction, then try to retire it. Require a script rejection, compared with the successful retirement of **" <> control <> "**.") (rest ("absent " <> key))
    ExpectUnknownRetirementRefused registry control key :>>= rest ->
        step ("Try to retire **" <> key <> "**, which was never registered in **" <> registry
            <> "**. Require a script rejection, compared with the successful retirement of **" <> control <> "** in this same registry.") (rest ("unknown " <> key))
  where
    step sentence rest = prepend ("- " <> sentence <> "\n\n") (renderWithResult rest)
    prepend prefix (text, result) = (prefix <> text, result)
    formal binding = "Formal specification: `" <> boName binding <> "` @ `" <> boRevision binding
        <> "`. Statement digest: `" <> boDigest binding <> "`.\n\n"
