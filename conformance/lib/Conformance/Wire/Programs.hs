{- |
Module      : Conformance.Wire.Programs
Description : The serialization rows as programs over the wire round-trip vocabulary
License     : Apache-2.0

A consumer builds the registry's datums and redeemers in its own code. What it
needs to know is that a value encoded in Haskell is the value the compiled
scripts declare, execute and leave on the chain. The model has no byte
representation, no blueprint, no redeemer and no proof, so these requirements
are outside its vocabulary; they are said instead in the vocabulary of this
module, the wire round trip: encode a value and check it against the compiled
blueprint, derive a script's applied identity, submit a registry operation and
read its bytes back, and read the constructors a submitted transaction carries.

Each serialization row is one program: a list of instructions. The live runner
executes the same list the book renders, so neither holds a second description
of a row.
-}
module Conformance.Wire.Programs
    ( Variation (..)
    , Registry (..)
    , Transaction (..)
    , Purpose (..)
    , Constructor (..)
    , ReadBackDatum (..)
    , Sample (..)
    , Encoding (..)
    , Validator (..)
    , Parameters (..)
    , Requirement (..)
    , Instruction (..)
    , Residual (..)
    , ResidualKind (..)
    , Standing (..)
    , Program (..)
    , programs
    , programFor
    , outsideReason
    , outsideReasons
    , needsDevnet
    , instructionReading
    , renderProgram
    , armedBy
    , controls
    , InstructionKind (..)
    , instructionKind
    , validateProgram
    ) where

import Conformance.Story.Live (Edge (..), edgeName)
import Control.Monad (foldM)
import Data.Char (toUpper)
import Data.List (find, intercalate)

-- | How a registry a program boots differs from the standard one.
data Variation
    = Standard
    | {- | the active policy pinned in the state set to another value, so a
      read back can tell the two registries apart on that field alone
      -}
      ActivePolicyVaried
    | -- | one second of processing and thirty of retraction: a retraction is soon possible
      FastRetraction
    | -- | one second of processing and one of retraction: a rejection is soon possible
      FastRejection
    deriving stock (Eq, Show, Enum, Bounded)

-- | A registry a program boots, by the name the program uses for it.
data Registry = Registry
    { registryName :: String
    , registryVariation :: Variation
    }
    deriving stock (Eq, Show)

-- | A transaction a program submits, named by what it does.
data Transaction
    = BootOf String
    | RequestFor String String
    | FoldOf String String
    | RetractionOf String String
    | RejectionIn String
    deriving stock (Eq, Show)

-- | Which redeemers of a transaction a constructor is read from.
data Purpose
    = -- | the redeemers of the inputs the transaction spends
      SpentInputs
    | -- | the redeemers of the policies it mints or burns under
      MintedPolicies
    | -- | the actions inside the state script's modify redeemer
      ModifyActions
    deriving stock (Eq, Show, Enum, Bounded)

-- | A constructor of an on-chain type, by name and wire index.
data Constructor = Constructor
    { constructorName :: String
    , constructorIndex :: Integer
    }
    deriving stock (Eq, Show)

-- | A datum a program reads back from the chain.
data ReadBackDatum
    = -- | the state datum the registry's boot wrote
      StateDatumOf String
    | -- | the request datum a request for this key wrote
      RequestDatumOf String String
    deriving stock (Eq, Show)

-- | A sample value whose encoding is checked against the compiled blueprint.
data Sample
    = TokenIdentifier
    | OutputReference
    | TrieRoot
    | RequestSample
    | -- | the sample request with its edge set to this tag
      RequestOnEdge Integer
    | StateSample
    | StateWithActivePolicyVaried
    | RequestDatumSample
    | StateDatumSample
    | AbsentCustodySample
    | MintingSample
    | MigratingSample
    | BurningSample
    | MigrationSample
    | UpdateSample
    | RejectedSample
    | EndSample
    | ContributeSample
    | ModifySample
    | RetractSample
    | SweepSample
    | BranchSample
    | ForkSample
    | LeafSample
    | NeighborSample
    deriving stock (Eq, Show)

-- | The shape an encoding must have on top of its schema.
data Encoding
    = -- | a constructor at this index
      ConstructorAt Integer
    | -- | plain bytes, no constructor
      PlainBytes
    | -- | only the schema is checked
      SchemaOnly
    deriving stock (Eq, Show)

-- | A validator of the compiled blueprint, by its title prefix.
newtype Validator = Validator {validatorTitle :: String}
    deriving stock (Eq, Show)

-- | What a validator's blueprint entry declares about its parameters.
data Parameters
    = -- | no parameter field at all
      NoParameterField
    | -- | no parameter field, or an empty list
      NoParameters
    | -- | exactly these parameters, in this order: title and schema reference
      ExactParameters [(String, String)]
    deriving stock (Eq, Show)

-- | Whether a validator must be present in the blueprint.
data Requirement = Required | IfPresent
    deriving stock (Eq, Show)

-- | One step of a wire round-trip program.
data Instruction
    = -- | boot a registry from the wallet's largest output
      BootRegistry Registry
    | -- | submit a request for a key on an edge, outside any fold
      SubmitRequest String String Edge
    | {- | book a key on an edge through the registry's published references,
      then fold it; the folded key is walked in the committed trie
      -}
      BookAndFold String String Edge
    | {- | book a key and build its fold, then retarget the modify redeemer to
      an index the validator does not name, keeping its fields; the ledger
      must refuse it in phase two
      -}
      BookAndTamperFold String String Edge Integer
    | -- | after the retraction window opens, the owner retracts the request for a key
      RetractRequest String String
    | -- | after both windows close, a folder rejects the registry's pending requests
      RejectPending String
    | -- | the datum written by the submitting transaction is read back from the chain identical
      DatumReadBack ReadBackDatum
    | -- | the registry's state read back from the chain equals its boot's, field by field
      StateFieldsReadBack String
    | -- | the registry's state datum encodes this many fields
      StateFieldCount String Int
    | {- | the field the second registry's variation names differs between
      the two registries, and the application policy does not
      -}
      VariedFieldDiffers String String
    | {- | the four policies the registry's state pins are derived: none is a
      placeholder of zero bytes, and the three token policies are distinct
      -}
      PoliciesDerived String
    | -- | a submitted transaction carries this constructor for this purpose
      ConstructorWitnessed Transaction Purpose Constructor
    | {- | a fold's proof steps are exactly these constructors, every fork's
      neighbour is well formed, and the chain's root equals the committed trie
      -}
      ProofShape Transaction [Integer]
    | -- | across the row's folds, every one of these proof step constructors appears
      ProofStepsWitnessed [Constructor]
    | {- | the ledger refused the tampered fold in phase two, and the refusal
      names the state script whose redeemer was tampered
      -}
      RefusedByStateScript String String
    | -- | a sample's encoding validates against a blueprint definition and has this shape
      EncodingConforms Sample String Encoding
    | -- | the request sample's field at this position is the named integer
      RequestFieldAt Int String
    | -- | a blueprint definition's constructor lists its fields in this order
      FieldOrder String String [String]
    | -- | a constructor index the definition does not name fails its schema
      UnnamedConstructorRefused String Integer
    | -- | a list longer than the definition's fixed tuple fails its schema
      FixedTupleArity String Int
    | -- | a validator's blueprint entry declares these parameters
      ParametersDeclared Validator Parameters
    | -- | the hash of a validator's unapplied code equals the blueprint's pin
      UnappliedHashPinned Validator Requirement
    | -- | one extra parameter application changes a validator's hash
      ExtraApplicationChangesHash Validator
    | {- | applying the request validator's parameters changes its hash, and
      swapping them gives yet another
      -}
      RequestApplicationDiscriminates
    deriving stock (Eq, Show)

-- | Whether a constructor left unexercised is a named residual or a gap.
data ResidualKind = NamedResidual | ExplicitGap
    deriving stock (Eq, Show)

-- | A constructor a row does not exercise, with why.
data Residual = Residual
    { residualConstructor :: Constructor
    , residualKind :: ResidualKind
    , residualReason :: String
    }
    deriving stock (Eq, Show)

-- | How a row stands once its program has run.
data Standing
    = -- | every instruction held; the model constrains nothing here
      Holds
    | -- | the instructions held, and these constructors stay unexercised
      PartialCoverage [Residual]
    | -- | the chain refused as required, and the requirement is kept unmet by this ruling
      KeptUnmetByRuling String
    deriving stock (Eq, Show)

-- | One serialization row.
data Program = Program
    { programRow :: String
    , programCites :: [Transaction]
    -- ^ the transactions the receipt cites and measures
    , programInstructions :: [Instruction]
    , programStanding :: Standing
    }
    deriving stock (Eq, Show)

-- | Every serialization row, in inventory order.
programs :: [Program]
programs =
    [ blueprintEncoding
    , submittedDatum
    , updateRedeemerWitnesses
    , wrongRedeemerIndex
    , requestAndMintWitnesses
    , scriptParameters
    , proofSteps
    , stateFields
    ]

programFor :: String -> Maybe Program
programFor row = find ((== row) . programRow) programs

-- | Whether any instruction of a program needs a devnet.
needsDevnet :: Program -> Bool
needsDevnet = any onDevnet . programInstructions
  where
    onDevnet i = case i of
        EncodingConforms{} -> False
        RequestFieldAt{} -> False
        FieldOrder{} -> False
        UnnamedConstructorRefused{} -> False
        FixedTupleArity{} -> False
        ParametersDeclared{} -> False
        UnappliedHashPinned{} -> False
        ExtraApplicationChangesHash{} -> False
        RequestApplicationDiscriminates -> False
        _ -> True

-- ---------------------------------------------------------
-- The programs
-- ---------------------------------------------------------

con :: String -> Integer -> Constructor
con = Constructor

blueprintEncoding :: Program
blueprintEncoding =
    Program
        "blueprint-encoding-round-trip"
        []
        ( [ EncodingConforms TokenIdentifier "types/TokenId" (ConstructorAt 0)
          , EncodingConforms
                OutputReference
                "cardano/transaction/OutputReference"
                (ConstructorAt 0)
          , EncodingConforms TrieRoot "ByteArray" PlainBytes
          , RequestFieldAt 3 "edge"
          , RequestFieldAt 4 "deposit"
          ]
            <> [ EncodingConforms (RequestOnEdge edge) "types/Request" SchemaOnly
               | edge <- [0 .. 7]
               ]
            <> [ EncodingConforms RequestSample "types/Request" (ConstructorAt 0)
               , EncodingConforms StateSample "types/State" (ConstructorAt 0)
               , EncodingConforms StateWithActivePolicyVaried "types/State" SchemaOnly
               , EncodingConforms
                    RequestDatumSample
                    "types/CageDatum"
                    (ConstructorAt 0)
               , EncodingConforms StateDatumSample "types/CageDatum" (ConstructorAt 1)
               , EncodingConforms
                    AbsentCustodySample
                    "types/CageDatum"
                    (ConstructorAt 2)
               , EncodingConforms MintingSample "types/MintRedeemer" (ConstructorAt 0)
               , EncodingConforms
                    MigratingSample
                    "types/MintRedeemer"
                    (ConstructorAt 1)
               , EncodingConforms BurningSample "types/MintRedeemer" (ConstructorAt 2)
               , EncodingConforms MigrationSample "types/Migration" (ConstructorAt 0)
               , EncodingConforms UpdateSample "types/RequestAction" (ConstructorAt 0)
               , EncodingConforms
                    RejectedSample
                    "types/RequestAction"
                    (ConstructorAt 1)
               , EncodingConforms EndSample "types/UpdateRedeemer" (ConstructorAt 0)
               , EncodingConforms
                    ContributeSample
                    "types/UpdateRedeemer"
                    (ConstructorAt 1)
               , EncodingConforms ModifySample "types/UpdateRedeemer" (ConstructorAt 2)
               , EncodingConforms
                    RetractSample
                    "types/UpdateRedeemer"
                    (ConstructorAt 3)
               , EncodingConforms SweepSample "types/UpdateRedeemer" (ConstructorAt 4)
               , UnnamedConstructorRefused "types/UpdateRedeemer" 99
               , EncodingConforms BranchSample proofStep (ConstructorAt 0)
               , EncodingConforms ForkSample proofStep (ConstructorAt 1)
               , EncodingConforms LeafSample proofStep (ConstructorAt 2)
               , EncodingConforms
                    NeighborSample
                    "aiken/merkle_patricia_forestry/Neighbor"
                    (ConstructorAt 0)
               , FixedTupleArity "Tuple<<ByteArray,ByteArray>>" 2
               , FieldOrder
                    "types/State"
                    "State"
                    [ "root"
                    , "tip"
                    , "process_time"
                    , "retract_time"
                    , "application_policy"
                    , "active_policy"
                    , "absent_policy"
                    , "terminal_policy"
                    ]
               , FieldOrder
                    "types/Request"
                    "Request"
                    [ "requestToken"
                    , "requestOwner"
                    , "requestKey"
                    , "edge"
                    , "deposit"
                    , "submitted_at"
                    , "destination"
                    ]
               , FieldOrder "types/Migration" "Migration" ["oldPolicy", "tokenId"]
               , FieldOrder "types/TokenId" "TokenId" ["assetName"]
               , FieldOrder
                    "cardano/transaction/OutputReference"
                    "OutputReference"
                    ["transaction_id", "output_index"]
               , FieldOrder
                    "aiken/merkle_patricia_forestry/Neighbor"
                    "Neighbor"
                    ["nibble", "prefix", "root"]
               , FieldOrder proofStep "Branch" ["skip", "neighbors"]
               , FieldOrder proofStep "Fork" ["skip", "neighbor"]
               , FieldOrder proofStep "Leaf" ["skip", "key", "value"]
               ]
        )
        Holds
  where
    proofStep = "aiken/merkle_patricia_forestry/ProofStep"

submittedDatum :: Program
submittedDatum =
    Program
        "submitted-datum-byte-round-trip"
        [BootOf "datum", RequestFor "datum" key]
        [ BootRegistry (Registry "datum" Standard)
        , SubmitRequest "datum" key InsertActive
        , DatumReadBack (StateDatumOf "datum")
        , DatumReadBack (RequestDatumOf "datum" key)
        ]
        Holds
  where
    key = "datum-read-back-key"

updateRedeemerWitnesses :: Program
updateRedeemerWitnesses =
    Program
        "update-redeemer-constructor-witnesses"
        [FoldOf "modify" modifyKey, RetractionOf "retraction" retractKey]
        [ BootRegistry (Registry "modify" Standard)
        , BookAndFold "modify" modifyKey InsertActive
        , ConstructorWitnessed
            (FoldOf "modify" modifyKey)
            SpentInputs
            (con "Modify" 2)
        , ConstructorWitnessed
            (FoldOf "modify" modifyKey)
            SpentInputs
            (con "Contribute" 1)
        , BootRegistry (Registry "retraction" FastRetraction)
        , SubmitRequest "retraction" retractKey InsertActive
        , RetractRequest "retraction" retractKey
        , ConstructorWitnessed
            (RetractionOf "retraction" retractKey)
            SpentInputs
            (con "Retract" 3)
        ]
        ( PartialCoverage
            [ Residual
                (con "End" 0)
                NamedResidual
                "the state script refuses End for every party under the ownerless-registry ruling (commit f3a68b1b removed its builder); no accepting path exists"
            , Residual
                (con "Sweep" 4)
                NamedResidual
                "the request script refuses Sweep for every party under the ownerless-registry ruling (commit f3a68b1b removed its builder); no accepting path exists"
            ]
        )
  where
    modifyKey = "modify-witness-key"
    retractKey = "retract-witness-key"

wrongRedeemerIndex :: Program
wrongRedeemerIndex =
    Program
        "wrong-redeemer-constructor-index"
        []
        [ BootRegistry (Registry "tampered" Standard)
        , BookAndTamperFold "tampered" tamperedKey InsertActive 5
        , RefusedByStateScript "tampered" tamperedKey
        , BootRegistry (Registry "control" Standard)
        , BookAndFold "control" controlKey InsertActive
        ]
        ( KeptUnmetByRuling
            "kept unmet by operator ruling 2026-10-02 (narrowed #287; model follow-up lambdasistemi/singular#347); Singular's Lean has no vocabulary for decoding a redeemer, so it gives no reason to compare with the chain's"
        )
  where
    tamperedKey = "wrong-index-key"
    controlKey = "wrong-index-control-key"

requestAndMintWitnesses :: Program
requestAndMintWitnesses =
    Program
        "request-and-mint-constructor-witnesses"
        [BootOf "update", FoldOf "update" updateKey, RejectionIn "rejection"]
        [ BootRegistry (Registry "update" Standard)
        , ConstructorWitnessed
            (BootOf "update")
            MintedPolicies
            (con "Minting" 0)
        , BookAndFold "update" updateKey InsertActive
        , ConstructorWitnessed
            (FoldOf "update" updateKey)
            ModifyActions
            (con "Update" 0)
        , BootRegistry (Registry "rejection" FastRejection)
        , SubmitRequest "rejection" rejectKey InsertActive
        , RejectPending "rejection"
        , ConstructorWitnessed
            (RejectionIn "rejection")
            ModifyActions
            (con "Rejected" 1)
        ]
        ( PartialCoverage
            [ Residual
                (con "Burning" 2)
                NamedResidual
                "no accepting path: End, which burned the state token, was removed with the owner role (commit f3a68b1b)"
            , Residual
                (con "Migrating" 1)
                ExplicitGap
                "refused unconditionally under the ownerless-registry ruling, with no attributed witness and no discriminator; the wire constructor stays at index 1"
            ]
        )
  where
    updateKey = "update-witness-key"
    rejectKey = "reject-witness-key"

scriptParameters :: Program
scriptParameters =
    Program
        "script-parameter-application"
        []
        [ ParametersDeclared state NoParameters
        , ParametersDeclared
            request
            ( ExactParameters
                [ ("statePolicyId", "#/definitions/cardano~1assets~1PolicyId")
                , ("cageTokenName", "#/definitions/cardano~1assets~1AssetName")
                ]
            )
        , ParametersDeclared staking NoParameterField
        , UnappliedHashPinned state Required
        , UnappliedHashPinned request Required
        , UnappliedHashPinned staking IfPresent
        , ExtraApplicationChangesHash state
        , RequestApplicationDiscriminates
        ]
        Holds
  where
    state = Validator "state.state"
    request = Validator "request.request"
    staking = Validator "staking.staking"

proofSteps :: Program
proofSteps =
    Program
        "proof-step-constructor-witnesses"
        (BootOf "proof" : [FoldOf "proof" key | (key, _) <- folds])
        ( BootRegistry (Registry "proof" Standard)
            : concat
                [ [ BookAndFold "proof" key InsertAbsent
                  , ProofShape (FoldOf "proof" key) steps
                  ]
                | (key, steps) <- folds
                ]
                <> [ ProofStepsWitnessed
                        [con "Branch" 0, con "Fork" 1, con "Leaf" 2]
                   ]
        )
        Holds
  where
    -- The keys' bytes fix the trie's shape, so they are kept as they were
    -- first chosen: the third fold is the historical absence of a key whose
    -- path forks between the first two, and the last two widen the trie until
    -- a branch appears.
    folds =
        [ ("cs07-fork-A", [])
        , ("cs07-fork-B1294", [2])
        , ("cs07-fork-C11", [1])
        , ("cs07-fork-D127", [2, 1])
        , ("cs07-fork-E400", [2, 0])
        ]

stateFields :: Program
stateFields =
    Program
        "state-fields-chain-round-trip"
        [BootOf "base", BootOf "varied"]
        [ BootRegistry (Registry "base" Standard)
        , BootRegistry (Registry "varied" ActivePolicyVaried)
        , StateFieldsReadBack "base"
        , StateFieldsReadBack "varied"
        , StateFieldCount "base" 8
        , VariedFieldDiffers "base" "varied"
        , PoliciesDerived "base"
        ]
        Holds

-- ---------------------------------------------------------
-- Why each row is outside the model
-- ---------------------------------------------------------

-- | Why a serialization row is outside the model's vocabulary.
outsideReason :: String -> Maybe String
outsideReason row = lookup row outsideReasons

-- | Every serialization row the model cannot express, with its reason.
outsideReasons :: [(String, String)]
outsideReasons = reasons
  where
    noBytes = "the model has no byte representation"
    reasons =
        [
            ( "blueprint-encoding-round-trip"
            , noBytes
                <> " and no blueprint; the encodings are checked off chain against the compiled blueprint."
            )
        ,
            ( "submitted-datum-byte-round-trip"
            , noBytes
                <> ": its transaction observation states whether an output's datum is inline or absent, and the reported form is written, not read, so datum bytes are below it."
            )
        ,
            ( "update-redeemer-constructor-witnesses"
            , "the model has no redeemer (lambdasistemi/singular#347): its operations here are a fold and a retraction, but the claim is the constructor each transaction carries on the wire."
            )
        ,
            ( "wrong-redeemer-constructor-index"
            , "a fold whose redeemer is retargeted to an index the validator does not name; the model has no vocabulary for decoding a redeemer, so it gives no reason to compare with the chain's refusal (lambdasistemi/singular#347)."
            )
        ,
            ( "request-and-mint-constructor-witnesses"
            , "the model has no redeemer (lambdasistemi/singular#347): its operations here are a boot, a fold and a rejection, but the claim is the constructor each transaction carries on the wire."
            )
        ,
            ( "script-parameter-application"
            , noBytes
                <> ": parameters and script hashes are below it; the application is checked off chain against the compiled blueprint."
            )
        ,
            ( "proof-step-constructor-witnesses"
            , "the model takes no proof and no authenticated root (lambdasistemi/singular#346)."
            )
        ,
            ( "state-fields-chain-round-trip"
            , "the model states the eight state fields abstractly as its configuration observation, compared on every step of the registry programs; the byte round trip of the encoded state with one policy varied is below it."
            )
        ]

-- ---------------------------------------------------------
-- Reading
-- ---------------------------------------------------------

variationReading :: Variation -> String
variationReading v = case v of
    Standard -> ""
    ActivePolicyVaried -> ", its active policy set to another value"
    FastRetraction -> ", with one second of processing and thirty of retraction"
    FastRejection -> ", with one second of processing and one of retraction"

transactionReading :: Transaction -> String
transactionReading t = case t of
    BootOf r -> "the boot of **" <> r <> "**"
    RequestFor r k -> "the request for **" <> k <> "** in **" <> r <> "**"
    FoldOf r k -> "the fold of **" <> k <> "** in **" <> r <> "**"
    RetractionOf r k -> "the retraction of **" <> k <> "** in **" <> r <> "**"
    RejectionIn r -> "the rejection in **" <> r <> "**"

purposeReading :: Purpose -> String
purposeReading p = case p of
    SpentInputs -> "among the redeemers of the inputs it spends"
    MintedPolicies -> "among the redeemers of the policies it mints under"
    ModifyActions -> "among the request actions of its modify redeemer"

constructorReading :: Constructor -> String
constructorReading c = constructorName c <> " (index " <> show (constructorIndex c) <> ")"

datumReading :: ReadBackDatum -> String
datumReading d = case d of
    StateDatumOf r -> "the state datum **" <> r <> "**'s boot wrote"
    RequestDatumOf r k -> "the request datum written for **" <> k <> "** in **" <> r <> "**"

sampleReading :: Sample -> String
sampleReading s = case s of
    TokenIdentifier -> "a token identifier"
    OutputReference -> "an output reference"
    TrieRoot -> "a trie root"
    RequestSample -> "a request"
    RequestOnEdge e
        | e <= 6 -> "a request on edge " <> show e
        | otherwise ->
            "a request on edge " <> show e <> ", which the registry refuses"
    StateSample -> "a state"
    StateWithActivePolicyVaried -> "a state with its active policy varied"
    RequestDatumSample -> "a request datum"
    StateDatumSample -> "a state datum"
    AbsentCustodySample -> "an absent-key custody datum"
    MintingSample -> "the Minting redeemer"
    MigratingSample -> "the Migrating redeemer"
    BurningSample -> "the Burning redeemer"
    MigrationSample -> "a migration record"
    UpdateSample -> "the Update action"
    RejectedSample -> "the Rejected action"
    EndSample -> "the End redeemer"
    ContributeSample -> "the Contribute redeemer"
    ModifySample -> "the Modify redeemer"
    RetractSample -> "the Retract redeemer"
    SweepSample -> "the Sweep redeemer"
    BranchSample -> "a Branch proof step"
    ForkSample -> "a Fork proof step"
    LeafSample -> "a Leaf proof step"
    NeighborSample -> "a fork neighbour"

parametersReading :: Parameters -> String
parametersReading p = case p of
    NoParameterField -> "no parameter field"
    NoParameters -> "no parameters"
    ExactParameters ps ->
        "exactly the parameters "
            <> intercalate
                ", "
                [name <> " (" <> schema <> ")" | (name, schema) <- ps]
            <> ", in that order"

-- | One instruction as a sentence of the book.
instructionReading :: Instruction -> String
instructionReading instruction = case instruction of
    BootRegistry (Registry r v) ->
        "Boot the registry **" <> r <> "**" <> variationReading v <> "."
    SubmitRequest r k e ->
        "Submit a request for **"
            <> k
            <> "** on "
            <> edgeName e
            <> " in **"
            <> r
            <> "**."
    BookAndFold r k e ->
        "Book **"
            <> k
            <> "** on "
            <> edgeName e
            <> " in **"
            <> r
            <> "** and fold it."
    BookAndTamperFold r k e index ->
        "Book **"
            <> k
            <> "** on "
            <> edgeName e
            <> " in **"
            <> r
            <> "**, build its fold and retarget the modify redeemer to index "
            <> show index
            <> ", which the validator does not name, keeping its fields; the ledger must refuse it in phase two."
    RetractRequest r k ->
        "Once the retraction window opens, the owner retracts the request for **"
            <> k
            <> "** in **"
            <> r
            <> "**."
    RejectPending r ->
        "Once both windows close, a folder rejects the pending request in **"
            <> r
            <> "**."
    DatumReadBack d ->
        "Read "
            <> datumReading d
            <> " back from the chain: the bytes are the ones submitted."
    StateFieldsReadBack r ->
        "Read **"
            <> r
            <> "**'s state back from the chain: each field equals the one its boot submitted."
    StateFieldCount r n ->
        "**"
            <> r
            <> "**'s state datum on the chain encodes "
            <> show n
            <> " fields."
    VariedFieldDiffers a b ->
        "The field **"
            <> b
            <> "**'s variation names differs from **"
            <> a
            <> "**'s, and the application policy does not."
    PoliciesDerived r ->
        "The four policies **"
            <> r
            <> "**'s state pins are derived: none is a placeholder, and the three token policies are distinct."
    ConstructorWitnessed t p c ->
        "The ledger accepted "
            <> transactionReading t
            <> ", which carries "
            <> constructorReading c
            <> " "
            <> purposeReading p
            <> "."
    ProofShape t steps ->
        capitalise (transactionReading t)
            <> " proves with "
            <> ( if null steps
                    then "no proof step"
                    else "the proof steps " <> intercalate ", " (map show steps)
               )
            <> ", every fork's neighbour is well formed, and the chain's root equals the committed trie's."
    ProofStepsWitnessed cs ->
        "Across the folds, every proof step constructor appears: "
            <> intercalate ", " (map constructorReading cs)
            <> "."
    RefusedByStateScript r k ->
        "The ledger refuses the tampered fold of **"
            <> k
            <> "** in **"
            <> r
            <> "** in phase two, and the refusal names the state script."
    EncodingConforms s definition encoding ->
        "The Haskell encoding of "
            <> sampleReading s
            <> " decodes back to itself and validates against the blueprint's "
            <> definition
            <> case encoding of
                ConstructorAt n -> ", as constructor index " <> show n <> "."
                PlainBytes -> ", as plain bytes."
                SchemaOnly -> "."
    RequestFieldAt n name ->
        "A request's field at position "
            <> show n
            <> " is its "
            <> name
            <> "."
    FieldOrder definition constructor fields ->
        "The blueprint's "
            <> definition
            <> " lists the fields of "
            <> constructor
            <> " as "
            <> intercalate ", " fields
            <> ", the Haskell record's order."
    UnnamedConstructorRefused definition index ->
        "A constructor at index "
            <> show index
            <> " fails the blueprint's "
            <> definition
            <> "."
    FixedTupleArity definition n ->
        "A list of "
            <> show (n + 1)
            <> " elements fails the blueprint's "
            <> definition
            <> ", a fixed tuple of "
            <> show n
            <> "."
    ParametersDeclared (Validator v) p ->
        "The blueprint's " <> v <> " declares " <> parametersReading p <> "."
    UnappliedHashPinned (Validator v) requirement ->
        "The hash of "
            <> v
            <> "'s unapplied code equals the blueprint's pin"
            <> ( if requirement == IfPresent
                    then ", when the blueprint carries it."
                    else "."
               )
    ExtraApplicationChangesHash (Validator v) ->
        "One extra parameter application changes " <> v <> "'s hash."
    RequestApplicationDiscriminates ->
        "Applying the request validator's parameters changes its hash, and swapping the two parameters gives another."

capitalise :: String -> String
capitalise (c : cs) = toUpper c : cs
capitalise [] = []

-- | A program as the book prints it.
renderProgram :: Program -> String
renderProgram p =
    concatMap
        (\i -> "- " <> instructionReading i <> "\n")
        (programInstructions p)
        <> "\n"
        <> standingReading (programStanding p)
  where
    standingReading s = case s of
        Holds -> ""
        PartialCoverage residuals ->
            "Coverage stays partial: "
                <> intercalate
                    "; "
                    [ constructorReading (residualConstructor r)
                        <> ( case residualKind r of
                                NamedResidual -> " is a named residual: "
                                ExplicitGap -> " is an explicit gap: "
                           )
                        <> residualReason r
                    | r <- residuals
                    ]
                <> ".\n\n"
        KeptUnmetByRuling ruling -> "The requirement is " <> ruling <> ".\n\n"

{- | The controls of this vocabulary. Each demands the opposite of the checks
it arms, and a run under it must fail.
-}
controls :: [String]
controls =
    [ "wrong-index"
    , "blueprint-wrong-arity"
    , "wrong-params"
    , "false-datum"
    , "missing-witness"
    , "legacy-six-field"
    , "wrong-reason"
    ]

-- | Whether a control arms an instruction.
armedBy :: String -> Instruction -> Bool
armedBy control instruction = case (control, instruction) of
    ("wrong-index", EncodingConforms EndSample _ _) -> True
    ("blueprint-wrong-arity", FixedTupleArity{}) -> True
    ("wrong-params", ParametersDeclared (Validator "state.state") _) -> True
    ("false-datum", DatumReadBack _) -> True
    ("false-datum", VariedFieldDiffers{}) -> True
    ("missing-witness", ConstructorWitnessed{}) -> True
    ("missing-witness", ProofStepsWitnessed _) -> True
    ("legacy-six-field", StateFieldCount{}) -> True
    ("wrong-reason", RefusedByStateScript{}) -> True
    _ -> False

-- | The kinds of instruction this vocabulary has, for its extent controls.
data InstructionKind
    = Booting
    | Requesting
    | Folding
    | TamperingFold
    | Retracting
    | Rejecting
    | ReadingDatumBack
    | ReadingStateBack
    | CountingStateFields
    | ComparingVariedField
    | CheckingPoliciesDerived
    | WitnessingConstructor
    | CheckingProofShape
    | WitnessingProofSteps
    | AttributingRefusal
    | CheckingEncoding
    | CheckingRequestField
    | CheckingFieldOrder
    | RefusingUnnamedConstructor
    | CheckingTupleArity
    | CheckingParameters
    | CheckingUnappliedHash
    | CheckingExtraApplication
    | CheckingRequestApplication
    deriving stock (Eq, Ord, Show, Enum, Bounded)

instructionKind :: Instruction -> InstructionKind
instructionKind instruction = case instruction of
    BootRegistry _ -> Booting
    SubmitRequest{} -> Requesting
    BookAndFold{} -> Folding
    BookAndTamperFold{} -> TamperingFold
    RetractRequest{} -> Retracting
    RejectPending _ -> Rejecting
    DatumReadBack _ -> ReadingDatumBack
    StateFieldsReadBack _ -> ReadingStateBack
    StateFieldCount{} -> CountingStateFields
    VariedFieldDiffers{} -> ComparingVariedField
    PoliciesDerived _ -> CheckingPoliciesDerived
    ConstructorWitnessed{} -> WitnessingConstructor
    ProofShape{} -> CheckingProofShape
    ProofStepsWitnessed _ -> WitnessingProofSteps
    RefusedByStateScript{} -> AttributingRefusal
    EncodingConforms{} -> CheckingEncoding
    RequestFieldAt{} -> CheckingRequestField
    FieldOrder{} -> CheckingFieldOrder
    UnnamedConstructorRefused{} -> RefusingUnnamedConstructor
    FixedTupleArity{} -> CheckingTupleArity
    ParametersDeclared{} -> CheckingParameters
    UnappliedHashPinned{} -> CheckingUnappliedHash
    ExtraApplicationChangesHash _ -> CheckingExtraApplication
    RequestApplicationDiscriminates -> CheckingRequestApplication

{- | A program uses every registry, request and transaction only after the
instruction that makes it: a registry boots before anything acts on it, a
retraction follows its request, an observation follows the transaction it
reads, and every cited transaction has been submitted. A program whose
standing is unmet by ruling refuses a tampered fold.
-}
validateProgram :: Program -> Either String ()
validateProgram p = do
    (_, transactions, tampered) <-
        foldM step ([], [], []) (programInstructions p)
    mapM_ (produced transactions) (programCites p)
    case programStanding p of
        KeptUnmetByRuling _
            | null tampered ->
                Left (row <> " is unmet by ruling but refuses nothing")
        _ -> Right ()
  where
    row = programRow p
    step known@(registries, transactions, tampered) instruction = case instruction of
        BootRegistry registry@(Registry name _)
            | name `elem` map registryName registries ->
                Left (row <> " boots " <> name <> " twice")
            | otherwise ->
                Right (registry : registries, BootOf name : transactions, tampered)
        SubmitRequest r k _ ->
            (registries, RequestFor r k : transactions, tampered)
                <$ booted known r
        BookAndFold r k _ ->
            (registries, FoldOf r k : transactions, tampered) <$ booted known r
        BookAndTamperFold r k _ _ -> (registries, transactions, (r, k) : tampered) <$ booted known r
        RetractRequest r k -> do
            produced transactions (RequestFor r k)
            Right (registries, RetractionOf r k : transactions, tampered)
        RejectPending r
            | any (requestIn r) transactions ->
                Right (registries, RejectionIn r : transactions, tampered)
            | otherwise ->
                Left (row <> " rejects in " <> r <> " with no request pending")
        DatumReadBack (StateDatumOf r) -> known <$ produced transactions (BootOf r)
        DatumReadBack (RequestDatumOf r k) -> known <$ produced transactions (RequestFor r k)
        StateFieldsReadBack r -> known <$ booted known r
        StateFieldCount r _ -> known <$ booted known r
        VariedFieldDiffers a b -> do
            booted known a
            booted known b
            case [v | Registry name v <- registries, name == b] of
                [Standard] -> Left (row <> " compares " <> b <> ", which varies nothing")
                _ -> Right known
        PoliciesDerived r -> known <$ booted known r
        ConstructorWitnessed t _ _ -> known <$ produced transactions t
        ProofShape t _ -> known <$ produced transactions t
        ProofStepsWitnessed _
            | any isFold transactions -> Right known
            | otherwise -> Left (row <> " witnesses proof steps with no fold")
        RefusedByStateScript r k
            | (r, k) `elem` tampered -> Right known
            | otherwise ->
                Left (row <> " attributes a refusal of " <> k <> " it never tampered")
        _ -> Right known
    booted (registries, _, _) r
        | r `elem` map registryName registries = Right ()
        | otherwise = Left (row <> " acts on " <> r <> " before it boots")
    produced transactions t
        | t `elem` transactions = Right ()
        | otherwise =
            Left (row <> " reads " <> show t <> " before it is submitted")
    requestIn r (RequestFor r' _) = r == r'
    requestIn _ _ = False
    isFold FoldOf{} = True
    isFold _ = False
