{- |
Module      : Conformance.Authentication.Programs
Description : The registry-identity rows as programs over the authentication vocabulary
License     : Apache-2.0

A consumer finds the registry it builds on by authentication, not by the
chain refusing impostors: the canonical registry's token name is SHA-256 of
the canonical seed's output reference, a seed can be spent only once, and a
rival booted from another seed is accepted by the ledger but cannot carry that
name. The model has no seed, token name or address, so these requirements are
outside its vocabulary; they are said instead in the vocabulary of this
module — seeds, the registries booted from them, the outputs a consumer finds,
the authenticator it applies and the script identity it derives.

Each registry-identity row is one program: a list of instructions. The live
runner executes the same list the book renders, so neither holds a second
description of a row.
-}
module Conformance.Authentication.Programs
    ( Seed (..)
    , Subject (..)
    , Authenticator (..)
    , Decision (..)
    , Instruction (..)
    , Citation (..)
    , Program (..)
    , sessionPrologue
    , programs
    , programFor
    , outsideReason
    , outsideReasons
    , instructionReading
    , renderProgram
    , armedBy
    , controls
    , InstructionKind (..)
    , instructionKind
    , validateSession
    ) where

import Control.Monad (foldM)
import Data.Char (toUpper)
import Data.List (find)

-- | A seed a registry is booted from.
data Seed = CanonicalSeed | RivalSeed
    deriving stock (Eq, Ord, Show, Enum, Bounded)

-- | An output a consumer authenticates.
data Subject
    = -- | the state output of the registry booted from this seed
      StateOutputOf Seed
    | -- | the tokenless output forged at the canonical registry's address
      ForgedOutput
    deriving stock (Eq, Show)

-- | How a consumer decides an output is the canonical registry.
data Authenticator
    = -- | the canonical policy, the name derived from the canonical seed, quantity one
      DerivedName
    | {- | the canonical policy only (the address is the query itself): the
      control that shows the name is the discriminator
      -}
      PolicyOnly
    deriving stock (Eq, Show, Enum, Bounded)

-- | The decision an authentication must reach.
data Decision
    = Accepts
    | -- | the canonical policy is present, the derived name is not
      RejectsOnName
    | -- | no asset under the canonical policy at all
      RejectsOnMissingPolicy
    deriving stock (Eq, Show, Enum, Bounded)

-- | One step of an authentication program.
data Instruction
    = -- | publish a seed by splitting a wallet output in two
      PublishSeed Seed
    | {- | boot a registry from a published seed; the ledger must accept it,
      and the registry's state output is recorded as it stood after the boot
      -}
      BootFrom Seed
    | {- | the registry's state output, read from the chain, carries exactly
      the SHA-256 of its seed's output reference at quantity one under the
      canonical policy, and the derivation of a fabricated reference to the
      same transaction does not appear
      -}
      NameIsSeedDerivation Seed
    | -- | the two seeds' registries carry different names
      NamesDiffer Seed Seed
    | {- | the registry's state output is the one recorded after its boot:
      same output, value and datum
      -}
      UnchangedSinceBoot Seed
    | {- | pay an output to the canonical registry's address carrying its
      state datum and no token; the transaction carries no script witness, the
      node evaluates no script for it, the ledger accepts it and the output is
      read back live; the same detector finds the script the canonical boot
      carried
      -}
      ForgeTokenlessOutput
    | -- | an authenticator reaches a decision about an output read from the chain
      Authenticate Authenticator Subject Decision
    | {- | the published script manifest pins the state validator's hash to
      this run's blueprint code and declares no parameters
      -}
      StateIdentityPinned
    | {- | the state address derived by the production builder equals the
      address the chain reports for the canonical registry
      -}
      StateAddressDerived
    | {- | the request validator applied to the canonical registry's
      parameters has an address different from the unapplied script's
      -}
      RequestAddressApplied
    | {- | a state script corrupted by one extra parameter application derives
      an address the same checker refuses against the chain
      -}
      CorruptedDerivationRefused
    deriving stock (Eq, Show)

-- | The transaction a row's receipt cites, with its measured units and size.
data Citation
    = CitesBootOf Seed
    | CitesForgery
    deriving stock (Eq, Show)

-- | One registry-identity row.
data Program = Program
    { programRow :: String
    , programCites :: Citation
    , programInstructions :: [Instruction]
    }
    deriving stock (Eq, Show)

{- | What the identity session does before its first row: publish the
canonical seed, the publication a consumer derives the canonical name from.
-}
sessionPrologue :: [Instruction]
sessionPrologue = [PublishSeed CanonicalSeed]

-- | Every registry-identity row, in inventory order.
programs :: [Program]
programs =
    []

programFor :: String -> Maybe Program
programFor row = find ((== row) . programRow) programs

-- | Why a registry-identity row is outside the model's vocabulary.
outsideReason :: String -> Maybe String
outsideReason row = lookup row outsideReasons

-- | Every registry-identity row the model cannot express, with its reason.
outsideReasons :: [(String, String)]
outsideReasons = reasons
  where
    noIdentity =
        "the model has no seed, token name or registry address: the registry's address is a named unobservable and the model has no byte representation. "
    reasons =
        [
            ( "canonical-seed-identity"
            , noIdentity
                <> "The naming profile's consumer binding states a seed binding over abstract numbers, but it is not on the model driver's declared surface, so nothing is compared with the model."
            )
        ,
            ( "rival-seed-authentication"
            , noIdentity
                <> "Booting a registry is not one of the model's exits, and authentication reads a token name the model does not have."
            )
        ,
            ( "policy-address-only-authentication-control"
            , noIdentity
                <> "This row is a control over the authenticator itself; the model has no counterpart."
            )
        ,
            ( "applied-validator-identity"
            , noIdentity
                <> "Script hashes, parameter application and addresses are below the model; the derivation is checked off chain against the address the chain reports."
            )
        ,
            ( "tokenless-output-authentication"
            , noIdentity
                <> "Creating an output is not an operation of the model."
            )
        ]

seedReading :: Seed -> String
seedReading CanonicalSeed = "the canonical seed"
seedReading RivalSeed = "a rival seed"

registryReading :: Seed -> String
registryReading CanonicalSeed = "the canonical registry"
registryReading RivalSeed = "the rival registry"

subjectReading :: Subject -> String
subjectReading (StateOutputOf seed) = registryReading seed <> "'s state output"
subjectReading ForgedOutput = "the forged output"

authenticatorReading :: Authenticator -> String
authenticatorReading DerivedName =
    "the consumer's authentication (canonical policy, the name derived from the canonical seed, quantity one)"
authenticatorReading PolicyOnly =
    "an authentication that checks only the policy and the address"

decisionReading :: Decision -> String
decisionReading Accepts = "accepts"
decisionReading RejectsOnName = "rejects on the name"
decisionReading RejectsOnMissingPolicy = "rejects: no token under the canonical policy"

-- | One instruction as a sentence of the book.
instructionReading :: Instruction -> String
instructionReading instruction = case instruction of
    PublishSeed seed ->
        "Publish "
            <> seedReading seed
            <> " by splitting a wallet output in two."
    BootFrom seed ->
        "Boot "
            <> registryReading seed
            <> " from "
            <> seedReading seed
            <> "; the ledger accepts it."
    NameIsSeedDerivation seed ->
        "Read "
            <> registryReading seed
            <> "'s state output from the chain: its only name under the canonical policy is SHA-256 of "
            <> seedReading seed
            <> "'s output reference, at quantity one, and the derivation of a fabricated reference does not appear."
    NamesDiffer a b ->
        "The names of "
            <> registryReading a
            <> " and "
            <> registryReading b
            <> " differ."
    UnchangedSinceBoot seed ->
        registryReading' seed
            <> "'s state output is the one its boot left: same output, value and datum."
    ForgeTokenlessOutput ->
        "Pay an output to the canonical registry's address carrying its state datum and no token: no script witness, no script evaluated, accepted by the ledger and read back live; the same detector finds the script the canonical boot carried."
    Authenticate authenticator subject decision ->
        capitalise (authenticatorReading authenticator)
            <> " "
            <> decisionReading decision
            <> " "
            <> subjectReading subject
            <> "."
    StateIdentityPinned ->
        "The published script manifest pins the state validator to this run's blueprint code and declares no parameters."
    StateAddressDerived ->
        "The state address the production builder derives equals the address the chain reports for the canonical registry."
    RequestAddressApplied ->
        "The request validator applied to the canonical registry's parameters has an address different from the unapplied script's."
    CorruptedDerivationRefused ->
        "A state script corrupted by one extra parameter application derives an address the same check refuses against the chain."
  where
    registryReading' = capitalise . registryReading

capitalise :: String -> String
capitalise (c : cs) = toUpper c : cs
capitalise [] = []

-- | A program as the book prints it.
renderProgram :: Program -> String
renderProgram p =
    concatMap
        (\i -> "- " <> instructionReading i <> "\n")
        (programInstructions p)
        <> "\nThe receipt cites "
        <> citationReading (programCites p)
        <> ".\n\n"
  where
    citationReading (CitesBootOf seed) = "the boot of " <> registryReading seed
    citationReading CitesForgery = "the forged output's transaction"

{- | The controls of this vocabulary. Each demands the opposite of the checks
it arms, and a run under it must fail.
-}
controls :: [String]
controls = ["false-claim", "naive-authenticator", "unapplied-address"]

-- | Whether a control arms an instruction.
armedBy :: String -> Instruction -> Bool
armedBy control instruction = case (control, instruction) of
    ("false-claim", NameIsSeedDerivation _) -> True
    ("naive-authenticator", Authenticate PolicyOnly _ _) -> True
    ("unapplied-address", CorruptedDerivationRefused) -> True
    _ -> False

-- | The kinds of instruction this vocabulary has, for its extent controls.
data InstructionKind
    = PublishingSeed
    | Booting
    | DerivingName
    | ComparingNames
    | CheckingUnchanged
    | Forging
    | Authenticating
    | PinningStateIdentity
    | DerivingStateAddress
    | ApplyingRequestParameters
    | RefusingCorruptedDerivation
    deriving stock (Eq, Ord, Show, Enum, Bounded)

instructionKind :: Instruction -> InstructionKind
instructionKind instruction = case instruction of
    PublishSeed _ -> PublishingSeed
    BootFrom _ -> Booting
    NameIsSeedDerivation _ -> DerivingName
    NamesDiffer _ _ -> ComparingNames
    UnchangedSinceBoot _ -> CheckingUnchanged
    ForgeTokenlessOutput -> Forging
    Authenticate{} -> Authenticating
    StateIdentityPinned -> PinningStateIdentity
    StateAddressDerived -> DerivingStateAddress
    RequestAddressApplied -> ApplyingRequestParameters
    CorruptedDerivationRefused -> RefusingCorruptedDerivation

{- | The session's prologue and programs, run in inventory order, use every
seed and output only after the instruction that makes it: a seed is
published before its registry boots, a registry boots before it is read, and
the forged output exists before it is authenticated. Each program's citation
names a transaction some instruction has submitted by then.
-}
validateSession :: Either String ()
validateSession =
    go
        ([], [], False)
        (("session prologue", sessionPrologue, Nothing) : rows)
  where
    rows =
        [ (programRow p, programInstructions p, Just (programCites p))
        | p <- programs
        ]
    go _ [] = Right ()
    go known ((row, instructions, cites) : rest) = do
        known' <- foldM (step row) known instructions
        case cites of
            Just (CitesBootOf seed) -> booted row known' seed
            Just CitesForgery -> forged row known'
            Nothing -> Right ()
        go known' rest
    step row known@(published, boots, forgery) instruction = case instruction of
        PublishSeed seed
            | seed `elem` published ->
                Left (row <> " publishes " <> show seed <> " twice")
            | otherwise -> Right (seed : published, boots, forgery)
        BootFrom seed
            | seed `notElem` published ->
                Left (row <> " boots from unpublished " <> show seed)
            | seed `elem` boots ->
                Left (row <> " boots " <> show seed <> " twice")
            | otherwise -> Right (published, seed : boots, forgery)
        NameIsSeedDerivation seed -> known <$ booted row known seed
        NamesDiffer a b -> known <$ (booted row known a >> booted row known b)
        UnchangedSinceBoot seed -> known <$ booted row known seed
        ForgeTokenlessOutput -> (published, boots, True) <$ booted row known CanonicalSeed
        Authenticate _ (StateOutputOf seed) _ -> known <$ booted row known seed
        Authenticate _ ForgedOutput _ -> known <$ forged row known
        _ -> known <$ booted row known CanonicalSeed
    booted row (_, boots, _) seed
        | seed `elem` boots = Right ()
        | otherwise =
            Left (row <> " reads " <> show seed <> "'s registry before it boots")
    forged row (_, _, forgery)
        | forgery = Right ()
        | otherwise =
            Left (row <> " reads the forged output before it exists")
