{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Conformance.Operational
Description : Conformance cases as operational programs, run and rendered
License     : Apache-2.0

Slice S2. Every case body is a @do@ block of edit instructions; every
collection is its own instruction program; a verb needing more than one
argument takes each as a @do@ block via @BlockArguments@ ('clause' is
the only such verb). Argument positions store programs, never resolved
values (NOTE-001); scalars stay scalars. The interpreter says once what
@accepts@ and @rejects@ mean; no case mentions the loader, @Left@,
@Right@, a receipt count, or an Hspec combinator.

One program, two interpreter families calling the next layer down.
'runStory' executes against 'Conformance.Receipt.loadReceipts';
'renderStory' renders the theorem-clause-example story from the same
instructions, including the @edit@ line. Both families are total over
their instruction sets with no catch-all arms, so a new instruction
breaks both at compile time.
-}
module Conformance.Operational (
    AssetsI (..),
    Binding,
    BoundObligation (..),
    CaseI (..),
    ClauseI (..),
    Compat (..),
    ConfigI (..),
    EditI (..),
    EvidenceBoundary (..),
    FailureReport (..),
    HashesI (..),
    KeysI (..),
    LegI (..),
    LegName (..),
    MintI (..),
    Reason,
    RefundsI (..),
    SelectI (..),
    SequenceI (..),
    SignersI (..),
    StoryI (..),
    UnexercisedClause (..),
    accepts,
    acceptsBecause,
    acceptsMeaning,
    activeToken,
    anchorsPresent,
    approvalRecomputed,
    checkCase,
    clause,
    claimedMint,
    collectAssets,
    compatRow,
    configAfter,
    configBefore,
    conjunct,
    conjunctInventory,
    controlMint,
    deliver,
    distinguisher,
    dropLeg,
    duplicate,
    entailedMint,
    executeEdit,
    groupNames,
    hash,
    hashes,
    insertActiveRow,
    key,
    keyedMint,
    keyedMintFold,
    keys,
    landedFolds,
    literalControl,
    loadManifest,
    loadStatementSource,
    lovelace,
    maxFee,
    mint,
    minted,
    mkBoundObligation,
    nameViolation,
    noHashes,
    noMints,
    noPins,
    noRefunds,
    noSigners,
    noSteps,
    nothing,
    observedAddress,
    omitTrace,
    onLeg,
    openParameters,
    renderBoundary,
    renderEdit,
    renderFailure,
    renderStory,
    requestLovelace,
    resolveBinding,
    resolveClause,
    restUnchanged,
    runStory,
    signer,
    signers,
    step,
    theorem,
    token,
    controlTxid,
    txid,
    unexercised,
    unexercisedChecks,
    unchanged,
    validateCase,
    validateCollection,
    validateEdit,
    validateLeg,
    refunds,
    rejects,
) where

import Control.Monad.Operational (Program, ProgramViewT (Return, (:>>=)), singleton, view)
import Data.Aeson (FromJSON (..), Value, eitherDecode, toJSON, withObject, (.:), (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Lazy qualified as BSL
import Data.Foldable (toList)
import Data.List (isInfixOf)
import Data.Text (Text)
import Data.Text qualified as T
import System.Directory (doesFileExist)
import Test.Hspec (Spec, describe, expectationFailure, it, runIO)

import Conformance.EdgeFixtures (activeHex, completeReceipt, configPins, loadOne)

-- ---------------------------------------------------------
-- Bindings: the slice's Lean pins (single home; StoryBindings
-- is deleted at s2-move, values byte-identical)
-- ---------------------------------------------------------

-- | A Lean obligation the programs bind to.
data BoundObligation = BoundObligation
    { boName :: !String
    , boDigest :: !String
    , boRevision :: !String
    }
    deriving stock (Show, Eq)

-- | Name a bound obligation by qualified declaration, digest, revision.
mkBoundObligation :: String -> String -> String -> BoundObligation
mkBoundObligation name digest revision =
    BoundObligation name digest revision

-- | A binding is a bound obligation.
type Binding = BoundObligation

-- | The active-registration obligation.
insertActiveRow :: Binding
insertActiveRow =
    mkBoundObligation
        "Singular.Statements.insert_active_transaction_row"
        "bfb4e3174839b649a883244b97053ea52985cb3eeea1d3eb4475bb273e841737"
        "265c595"

-- | The batch-allocation obligation.
keyedMintFold :: Binding
keyedMintFold =
    mkBoundObligation
        "Singular.Statements.fold_batch_claimed_mint_by_kind_key"
        "9c01e278443498d3488e6671cc1799393f565a2a1c0055c1926a8d3e559da988"
        "265c595"

-- | The conjunct anchors the slice's clauses may select, keyed by the
-- obligation that states them. Quoted verbatim; every one must appear
-- in the Lean source or the suite fails.
conjunctInventory :: [(String, [String])]
conjunctInventory =
    [ ( boName insertActiveRow
      ,
          [ "address := some r.output"
          , "assets := [((.active, r.key), 1)]"
          , "kindCount t.state .active r.key = 1"
          , "mint := [((.active, r.key), 1)]"
          , "openPolicyParameters = []"
          , "refunds := []"
          , "signers := []"
          , "lovelaceCoversTip s.config lovelace = true"
          , "destinationDatumBinds r = true"
          , "onlyRootChanged s.config t.state.config = true"
          , "txOf t.state r₂ lovelace = .error \"key-exists\""
          ]
      )
    , ( boName keyedMintFold
      ,
          [ "assetKindTotal (claimedMint [b₁, b₂]) k"
          , "assetSame (claimedMint [b₁, b₂]) (actualMint [b₁, b₂]) = false"
          , "foldBatch s [b₁, b₂] = .error \"net-mint-mismatch\""
          ]
      )
    ]

-- | One row of the repository's statement manifest.
data ManifestEntry = ManifestEntry
    { meName :: !String
    , meDigest :: !String
    }

instance FromJSON ManifestEntry where
    parseJSON = withObject "ManifestEntry" $ \o ->
        ManifestEntry <$> o .: "name" <*> o .: "statementSha256"

-- | First of the candidate paths that exists on disk.
firstExisting :: [FilePath] -> IO (Maybe FilePath)
firstExisting [] = pure Nothing
firstExisting (p : ps) = do
    exists <- doesFileExist p
    if exists then pure (Just p) else firstExisting ps

-- | Read the repository's own statement manifest.
loadManifest :: IO (Either String [(String, String)])
loadManifest = do
    found <- firstExisting ["../lean/theorem-debt.json", "lean/theorem-debt.json"]
    case found of
        Nothing -> pure (Left "statement manifest not found: want ../lean/theorem-debt.json")
        Just path -> do
            content <- BSL.readFile path
            case eitherDecode content :: Either String [ManifestEntry] of
                Left err -> pure (Left ("statement manifest does not parse: " <> err))
                Right entries -> pure (Right [(meName e, meDigest e) | e <- entries])

-- | A binding resolves exactly when the manifest carries the named
-- declaration under the pinned digest.
resolveBinding :: [(String, String)] -> Binding -> Bool
resolveBinding manifest obligation =
    lookup (boName obligation) manifest == Just (boDigest obligation)

-- | Read the bound Lean source.
loadStatementSource :: IO (Either String String)
loadStatementSource = do
    found <- firstExisting ["../lean/Singular/Statements.lean", "lean/Singular/Statements.lean"]
    case found of
        Nothing -> pure (Left "statement source not found: want ../lean/Singular/Statements.lean")
        Just path -> Right <$> readFile path

-- | Every anchor quoted anywhere in the inventory appears verbatim in
-- the source.
anchorsPresent :: String -> [(String, [String])] -> Bool
anchorsPresent source inventory =
    all (`isInfixOf` source) [anchor | (_, anchors) <- inventory, anchor <- anchors]

-- | Whether a clause or example name smuggles in a row ID or ticket
-- number. One predicate, used by every hygiene check.
nameViolation :: String -> Bool
nameViolation n = "CG" `isInfixOf` n || '#' `elem` n

-- | A clause resolves exactly when every selected anchor belongs to
-- the named obligation's inventory.
resolveClause :: [(String, [String])] -> Binding -> [Text] -> Bool
resolveClause inventory obligation anchors =
    not (null anchors)
        && all (`elem` map T.pack (anchorsFor (boName obligation))) anchors
  where
    anchorsFor name = case lookup name inventory of
        Just listed -> listed
        Nothing -> []

-- ---------------------------------------------------------
-- Instruction sets: programs in argument positions (NOTE-001)
-- ---------------------------------------------------------

-- | A rejection reason. Required by 'rejects'.
type Reason = Text

-- | Refusal legs under observation.
data LegName = Duplicate | KeyedMint
    deriving stock (Show, Eq)

-- | The duplicate leg.
duplicate :: LegName
duplicate = Duplicate

-- | The keyed-mint leg.
keyedMint :: LegName
keyedMint = KeyedMint

-- | Render a leg name as the fixture spells it.
renderLeg :: LegName -> String
renderLeg Duplicate = "duplicate"
renderLeg KeyedMint = "keyedMint"

-- | Asset collections as programs. 'LitAssets' is the negative control
-- instrument: a collection built as a literal rather than a program.
-- Validators refuse it and 'runStory' will not execute it.
data AssetsI a where
    ActiveToken :: Value -> Integer -> AssetsI ()
    Token :: Value -> Value -> Integer -> AssetsI ()
    NoAssets :: AssetsI ()
    LitAssets :: [Value] -> AssetsI ()

-- | Key collections as programs.
data KeysI a where
    Key :: Value -> KeysI ()

-- | Mint collections as programs.
data MintI a where
    Mint :: Value -> Value -> Integer -> MintI ()
    NoMints :: MintI ()

-- | Refund collections as programs.
data RefundsI a where
    Lovelace :: Integer -> RefundsI ()
    NoRefunds :: RefundsI ()

-- | Signer collections as programs.
data SignersI a where
    Signer :: Value -> SignersI ()
    NoSigners :: SignersI ()

-- | Configuration pins as programs.
data ConfigI a where
    MaxFee :: Integer -> ConfigI ()
    RestUnchanged :: ConfigI ()
    NoPins :: ConfigI ()

-- | Landed-fold sequences as programs.
data SequenceI a where
    Step :: Value -> Value -> Value -> Value -> SequenceI ()
    NoSteps :: SequenceI ()

-- | Failing-script hashes as programs.
data HashesI a where
    Hash :: Value -> HashesI ()
    NoHashes :: HashesI ()

-- | Leg edits as programs. 'OmitTrace' names the ledger reality that a
-- script-execution failure carries an empty log list, so absence of the
-- field is the normal case.
data LegI a where
    LegKeys :: Program KeysI () -> LegI ()
    LegClaimed :: Program MintI () -> LegI ()
    LegEntailed :: Program MintI () -> LegI ()
    LegControl :: Program MintI () -> LegI ()
    LegDistinguisher :: Text -> LegI ()
    LegTxid :: Value -> LegI ()
    LegControlTxid :: Value -> LegI ()
    LegHashes :: Program HashesI () -> LegI ()
    OmitTrace :: LegI ()

-- | Receipt edits as programs.
data EditI a where
    Deliver :: Program AssetsI () -> EditI ()
    Minted :: Program AssetsI () -> EditI ()
    ObservedAddress :: Value -> EditI ()
    OpenParameters :: Integer -> EditI ()
    RequestLovelace :: Integer -> EditI ()
    ApprovalRecomputed :: Value -> EditI ()
    Refunds :: Program RefundsI () -> EditI ()
    Signers :: Program SignersI () -> EditI ()
    ConfigAfter :: Program ConfigI () -> EditI ()
    ConfigBefore :: Program ConfigI () -> EditI ()
    LandedFolds :: Program SequenceI () -> EditI ()
    OnLeg :: LegName -> Program LegI () -> EditI ()
    DropLeg :: LegName -> EditI ()
    Unchanged :: EditI ()

-- | Cases as programs. The outcome is named here; what it means lives
-- in the interpreters.
data CaseI a where
    Accepts :: Text -> Program EditI () -> CaseI ()
    AcceptsBecause :: Text -> Program EditI () -> Reason -> CaseI ()
    Rejects :: Text -> Reason -> Program EditI () -> CaseI ()

-- | Clause selections as programs: conjunct anchors quoted verbatim
-- from the bound statement.
data SelectI a where
    Conjunct :: Text -> SelectI ()

-- | Clauses as programs. The compatibility row rides beside the clause
-- it was observed under, never in a name.
data ClauseI a where
    Clause :: Text -> Program SelectI () -> Program CaseI () -> Compat -> ClauseI ()
    Unexercised :: Text -> Text -> ClauseI ()

-- | Stories as programs: one bound obligation read through clauses.
data StoryI a where
    Theorem :: Binding -> Program ClauseI () -> StoryI ()

-- | Compatibility metadata: the stable receipt row an example's
-- fixtures run against.
newtype Compat = Compat String
    deriving stock (Show, Eq)

-- | Carry a stable row identity beside a clause.
compatRow :: String -> Compat
compatRow = Compat

-- | Where the example's evidence was observed.
data EvidenceBoundary
    = ReceiptValidation
    | TransactionExecution
    deriving stock (Show, Eq)

-- | Render the boundary as the failure report names it.
renderBoundary :: EvidenceBoundary -> String
renderBoundary ReceiptValidation =
    "receipt evidence \183 subject: Conformance.Receipt.loadReceipts"
renderBoundary TransactionExecution =
    "transaction execution \183 subject: Singular.Registry.Driver"

-- ---------------------------------------------------------
-- Smart constructors: one instruction is already a program
-- ---------------------------------------------------------

-- | One active token holding: under the active policy the asset name
-- IS the key.
activeToken :: Value -> Integer -> Program AssetsI ()
activeToken k qty = singleton (ActiveToken k qty)

-- | One token holding under any policy.
token :: Value -> Value -> Integer -> Program AssetsI ()
token policy name qty = singleton (Token policy name qty)

-- | Negative control: a literal-built collection inside a program
-- world. Validators refuse it; it is never used in a case.
literalControl :: [Value] -> Program AssetsI ()
literalControl vs = singleton (LitAssets vs)

-- | The empty asset collection, said out loud.
nothing :: Program AssetsI ()
nothing = singleton NoAssets

-- | One key of a batch.
key :: Value -> Program KeysI ()
key k = singleton (Key k)

-- | One mint entry: policy, name, quantity.
mint :: Value -> Value -> Integer -> Program MintI ()
mint policy name qty = singleton (Mint policy name qty)

-- | The empty mint collection.
noMints :: Program MintI ()
noMints = singleton NoMints

-- | A lovelace refund of the given size.
lovelace :: Integer -> Program RefundsI ()
lovelace n = singleton (Lovelace n)

-- | No refund.
noRefunds :: Program RefundsI ()
noRefunds = singleton NoRefunds

-- | One required signer.
signer :: Value -> Program SignersI ()
signer addr = singleton (Signer addr)

-- | No signer.
noSigners :: Program SignersI ()
noSigners = singleton NoSigners

-- | Override the first configuration pin (the max fee).
maxFee :: Integer -> Program ConfigI ()
maxFee n = singleton (MaxFee n)

-- | Every other pin stays as the fixture carries it.
restUnchanged :: Program ConfigI ()
restUnchanged = singleton RestUnchanged

-- | No pins at all: an unobserved configuration.
noPins :: Program ConfigI ()
noPins = singleton NoPins

-- | One landed fold: transaction, root before and after, committed root.
step :: Value -> Value -> Value -> Value -> Program SequenceI ()
step tx before after committed = singleton (Step tx before after committed)

-- | No landed folds.
noSteps :: Program SequenceI ()
noSteps = singleton NoSteps

-- | One failing-script hash.
hash :: Value -> Program HashesI ()
hash h = singleton (Hash h)

-- | No failing script named.
noHashes :: Program HashesI ()
noHashes = singleton NoHashes

-- | Deliver a collection program.
deliver :: Program AssetsI () -> Program EditI ()
deliver p = singleton (Deliver p)

-- | Mint a collection program.
minted :: Program AssetsI () -> Program EditI ()
minted p = singleton (Minted p)

-- | Observe the token at another address.
observedAddress :: Value -> Program EditI ()
observedAddress addr = singleton (ObservedAddress addr)

-- | Declare open parameters.
openParameters :: Integer -> Program EditI ()
openParameters n = singleton (OpenParameters n)

-- | Carry request lovelace.
requestLovelace :: Integer -> Program EditI ()
requestLovelace n = singleton (RequestLovelace n)

-- | Recompute the approval to another name.
approvalRecomputed :: Value -> Program EditI ()
approvalRecomputed v = singleton (ApprovalRecomputed v)

-- | Pay a refund collection program.
refunds :: Program RefundsI () -> Program EditI ()
refunds p = singleton (Refunds p)

-- | Require a signer collection program.
signers :: Program SignersI () -> Program EditI ()
signers p = singleton (Signers p)

-- | Replace the output configuration pins.
configAfter :: Program ConfigI () -> Program EditI ()
configAfter p = singleton (ConfigAfter p)

-- | Replace the input configuration pins.
configBefore :: Program ConfigI () -> Program EditI ()
configBefore p = singleton (ConfigBefore p)

-- | Replace the landed-fold sequence.
landedFolds :: Program SequenceI () -> Program EditI ()
landedFolds p = singleton (LandedFolds p)

-- | Scope an edit program to one refusal leg.
onLeg :: LegName -> Program LegI () -> Program EditI ()
onLeg leg p = singleton (OnLeg leg p)

-- | Drop a refusal leg entirely: an incomplete row.
dropLeg :: LegName -> Program EditI ()
dropLeg leg = singleton (DropLeg leg)

-- | No change.
unchanged :: Program EditI ()
unchanged = singleton Unchanged

-- | Name the keys a leg carries.
keys :: Program KeysI () -> Program LegI ()
keys p = singleton (LegKeys p)

-- | Name what the leg's transaction claimed to mint.
claimedMint :: Program MintI () -> Program LegI ()
claimedMint p = singleton (LegClaimed p)

-- | Name what the leg's edges actually entail.
entailedMint :: Program MintI () -> Program LegI ()
entailedMint p = singleton (LegEntailed p)

-- | Name what the leg's accepting control minted.
controlMint :: Program MintI () -> Program LegI ()
controlMint p = singleton (LegControl p)

-- | State the one thing distinguishing the refused pair.
distinguisher :: Text -> Program LegI ()
distinguisher t = singleton (LegDistinguisher t)

-- | Name the refused transaction.
txid :: Value -> Program LegI ()
txid v = singleton (LegTxid v)

-- | Name the accepting control transaction.
controlTxid :: Value -> Program LegI ()
controlTxid v = singleton (LegControlTxid v)

-- | Name the failing scripts.
hashes :: Program HashesI () -> Program LegI ()
hashes p = singleton (LegHashes p)

-- | Record that the ledger surfaced no trace: a script-execution
-- failure carries an empty log list, so absence is the normal case.
omitTrace :: Program LegI ()
omitTrace = singleton OmitTrace

-- | Accept the observation: the loader must take it.
accepts :: Text -> Program EditI () -> Program CaseI ()
accepts name prog = singleton (Accepts name prog)

-- | Accept the observation, recording why the case matters.
acceptsBecause :: Text -> Program EditI () -> Reason -> Program CaseI ()
acceptsBecause name prog reason = singleton (AcceptsBecause name prog reason)

-- | Refuse the observation. The reason is a required argument: a
-- rejection claims the mutation is caught for a reason, and the type
-- demands it so nobody has to remember it.
rejects :: Text -> Reason -> Program EditI () -> Program CaseI ()
rejects name reason prog = singleton (Rejects name reason prog)

-- | Quote one conjunct anchor verbatim from the bound statement.
conjunct :: Text -> Program SelectI ()
conjunct t = singleton (Conjunct t)

-- | Read a clause through its selected conjuncts and its cases. The
-- only verb taking two block arguments: selects, then cases.
clause :: Text -> Program SelectI () -> Program CaseI () -> Compat -> Program ClauseI ()
clause alias selects cases compat = singleton (Clause alias selects cases compat)

-- | Read a bound obligation through its clauses.
theorem :: Binding -> Program ClauseI () -> Program StoryI ()
theorem binding clauses = singleton (Theorem binding clauses)

-- | A clause the slice does not exercise. Recorded with its alias and
-- what exercising it would need; it contributes no check and earns no
-- coverage, so a theorem pointer alone never reads as evidence.
data UnexercisedClause = UnexercisedClause
    { unAlias :: !String
    , unWhatMissing :: !String
    }
    deriving stock (Show, Eq)

-- | Record an unexercised clause as data.
unexercised :: Text -> Text -> Program ClauseI ()
unexercised alias missing = singleton (Unexercised alias missing)

-- | The executable checks an unexercised clause contributes: none. The
-- type leaves no other option; this pins it.
unexercisedChecks :: UnexercisedClause -> Int
unexercisedChecks _ = 0

-- ---------------------------------------------------------
-- Folds: interpreters call interpreters (NOTE-001)
-- ---------------------------------------------------------

-- | One asset entry.
assetOf :: Value -> Value -> Integer -> Value
assetOf policy name qty =
    Aeson.object
        [ "policy" .= policy
        , "name" .= name
        , "quantity" .= qty
        ]

-- | Fold an asset program to its JSON values.
collectAssets :: Program AssetsI () -> [Value]
collectAssets prog = case view prog of
    Return () -> []
    ActiveToken k qty :>>= k2 -> assetOf activeHex k qty : collectAssets (k2 ())
    Token policy name qty :>>= k -> assetOf policy name qty : collectAssets (k ())
    NoAssets :>>= k -> collectAssets (k ())
    LitAssets vs :>>= k -> vs <> collectAssets (k ())

-- | Fold a key program to its JSON values.
collectKeys :: Program KeysI () -> [Value]
collectKeys prog = case view prog of
    Return () -> []
    Key k :>>= rest -> k : collectKeys (rest ())

-- | Fold a mint program to its JSON values.
collectMints :: Program MintI () -> [Value]
collectMints prog = case view prog of
    Return () -> []
    Mint policy name qty :>>= rest -> assetOf policy name qty : collectMints (rest ())
    NoMints :>>= rest -> collectMints (rest ())

-- | Fold a refund program to its JSON values.
collectRefunds :: Program RefundsI () -> [Value]
collectRefunds prog = case view prog of
    Return () -> []
    Lovelace n :>>= rest -> Aeson.Number (fromInteger n) : collectRefunds (rest ())
    NoRefunds :>>= rest -> collectRefunds (rest ())

-- | Fold a signer program to its JSON values.
collectSigners :: Program SignersI () -> [Value]
collectSigners prog = case view prog of
    Return () -> []
    Signer addr :>>= rest -> addr : collectSigners (rest ())
    NoSigners :>>= rest -> collectSigners (rest ())

-- | The complete configuration pins the fixture carries.
completePins :: [Value]
completePins = case configPins of
    Aeson.Array arr -> toList arr
    _ -> []

-- | Fold a config program to its pins.
collectConfig :: Program ConfigI () -> [Value]
collectConfig prog = go prog completePins
  where
    go :: Program ConfigI () -> [Value] -> [Value]
    go p pins = case view p of
        Return () -> pins
        MaxFee n :>>= rest -> go (rest ()) (Aeson.Number (fromInteger n) : drop 1 pins)
        RestUnchanged :>>= rest -> go (rest ()) pins
        NoPins :>>= _ -> []

-- | Fold a sequence program to its JSON values.
collectSequence :: Program SequenceI () -> [Value]
collectSequence prog = case view prog of
    Return () -> []
    Step tx before after committed :>>= rest ->
        Aeson.object
            [ "txid" .= tx
            , "rootBefore" .= before
            , "rootAfter" .= after
            , "committed" .= committed
            ]
            : collectSequence (rest ())
    NoSteps :>>= rest -> collectSequence (rest ())

-- | Fold a hash program to its JSON values.
collectHashes :: Program HashesI () -> [Value]
collectHashes prog = case view prog of
    Return () -> []
    Hash h :>>= rest -> h : collectHashes (rest ())
    NoHashes :>>= rest -> collectHashes (rest ())

-- | Set one field of the receipt's edge observation.
setEdgeField :: String -> Value -> Value -> Value
setEdgeField k v receipt = case receipt of
    Aeson.Object o -> case KM.lookup "edge" o of
        Just (Aeson.Object e) ->
            Aeson.Object (KM.insert "edge" (Aeson.Object (KM.insert (Key.fromString k) v e)) o)
        _ -> receipt
    _ -> receipt

-- | Set one field of one refusal leg.
setLegField :: LegName -> String -> Value -> Value -> Value
setLegField leg k v receipt = case receipt of
    Aeson.Object o -> case KM.lookup "edge" o of
        Just (Aeson.Object e) -> case KM.lookup (Key.fromString (renderLeg leg)) e of
            Just (Aeson.Object l) ->
                let e2 = KM.insert (Key.fromString (renderLeg leg)) (Aeson.Object (KM.insert (Key.fromString k) v l)) e
                 in Aeson.Object (KM.insert "edge" (Aeson.Object e2) o)
            _ -> receipt
        _ -> receipt
    _ -> receipt

-- | Delete one field of one refusal leg.
dropLegField :: LegName -> String -> Value -> Value
dropLegField leg k receipt = case receipt of
    Aeson.Object o -> case KM.lookup "edge" o of
        Just (Aeson.Object e) -> case KM.lookup (Key.fromString (renderLeg leg)) e of
            Just (Aeson.Object l) ->
                let e2 = KM.insert (Key.fromString (renderLeg leg)) (Aeson.Object (KM.delete (Key.fromString k) l)) e
                 in Aeson.Object (KM.insert "edge" (Aeson.Object e2) o)
            _ -> receipt
        _ -> receipt
    _ -> receipt

-- | Fold a leg program to a receipt transformer, scoped to the leg.
foldLeg :: LegName -> Program LegI () -> Value -> Value
foldLeg leg prog = case view prog of
    Return () -> id
    LegKeys p :>>= rest ->
        \v -> foldLeg leg (rest ()) (setLegField leg "keys" (toJSON (collectKeys p)) v)
    LegClaimed p :>>= rest ->
        \v -> foldLeg leg (rest ()) (setLegField leg "claimedMint" (toJSON (collectMints p)) v)
    LegEntailed p :>>= rest ->
        \v -> foldLeg leg (rest ()) (setLegField leg "entailedMint" (toJSON (collectMints p)) v)
    LegControl p :>>= rest ->
        \v -> foldLeg leg (rest ()) (setLegField leg "controlMint" (toJSON (collectMints p)) v)
    LegDistinguisher t :>>= rest ->
        \v -> foldLeg leg (rest ()) (setLegField leg "distinguisher" (Aeson.String t) v)
    LegTxid tx :>>= rest ->
        \v -> foldLeg leg (rest ()) (setLegField leg "txid" tx v)
    LegControlTxid tx :>>= rest ->
        \v -> foldLeg leg (rest ()) (setLegField leg "controlTxid" tx v)
    LegHashes p :>>= rest ->
        \v -> foldLeg leg (rest ()) (setLegField leg "hashes" (toJSON (collectHashes p)) v)
    OmitTrace :>>= rest ->
        \v -> foldLeg leg (rest ()) (dropLegField leg "trace" v)

-- | Fold an edit program to a receipt transformer.
foldEdit :: Program EditI () -> Value -> Value
foldEdit prog = case view prog of
    Return () -> id
    Deliver p :>>= rest ->
        \v -> foldEdit (rest ()) (setEdgeField "delivered" (toJSON (collectAssets p)) v)
    Minted p :>>= rest ->
        \v -> foldEdit (rest ()) (setEdgeField "minted" (toJSON (collectAssets p)) v)
    ObservedAddress addr :>>= rest ->
        \v -> foldEdit (rest ()) (setEdgeField "observedAddress" addr v)
    OpenParameters n :>>= rest ->
        \v -> foldEdit (rest ()) (setEdgeField "openParameters" (Aeson.Number (fromInteger n)) v)
    RequestLovelace n :>>= rest ->
        \v -> foldEdit (rest ()) (setEdgeField "requestLovelace" (Aeson.Number (fromInteger n)) v)
    ApprovalRecomputed newVal :>>= rest ->
        \r -> foldEdit (rest ()) (setEdgeField "approvalRecomputed" newVal r)
    Refunds p :>>= rest ->
        \v -> foldEdit (rest ()) (setEdgeField "refunds" (toJSON (collectRefunds p)) v)
    Signers p :>>= rest ->
        \v -> foldEdit (rest ()) (setEdgeField "signers" (toJSON (collectSigners p)) v)
    ConfigAfter p :>>= rest ->
        \v -> foldEdit (rest ()) (setEdgeField "configAfter" (toJSON (collectConfig p)) v)
    ConfigBefore p :>>= rest ->
        \v -> foldEdit (rest ()) (setEdgeField "configBefore" (toJSON (collectConfig p)) v)
    LandedFolds p :>>= rest ->
        \v -> foldEdit (rest ()) (setEdgeField "sequence" (toJSON (collectSequence p)) v)
    OnLeg leg p :>>= rest ->
        \v -> foldEdit (rest ()) (foldLeg leg p v)
    DropLeg leg :>>= rest ->
        \v -> foldEdit (rest ()) (setEdgeField (renderLeg leg) Aeson.Null v)
    Unchanged :>>= rest -> foldEdit (rest ())

-- ---------------------------------------------------------
-- The one place saying what accepted means
-- ---------------------------------------------------------

-- | Accepted means the loader returned exactly the fixture's receipt
-- count: one written file loads exactly one receipt. An accepts over
-- zero or two receipts is refused, not vacuously passed.
acceptsMeaning :: Either String Int -> Bool
acceptsMeaning (Right 1) = True
acceptsMeaning _ = False

-- | A case is well-formed when every rejection carries a non-empty
-- reason. Presence is enforced by the type; this refuses emptiness.
validateCase :: Program CaseI () -> Bool
validateCase prog = case view prog of
    Return () -> True
    Accepts _ _ :>>= rest -> validateCase (rest ())
    AcceptsBecause _ _ reason :>>= rest -> not (T.null reason) && validateCase (rest ())
    Rejects _ reason _ :>>= rest -> not (T.null reason) && validateCase (rest ())

-- | A collection is well-formed when no literal instrument built it.
validateCollection :: Program AssetsI () -> Bool
validateCollection prog = case view prog of
    Return () -> True
    ActiveToken _ _ :>>= rest -> validateCollection (rest ())
    Token _ _ _ :>>= rest -> validateCollection (rest ())
    NoAssets :>>= rest -> validateCollection (rest ())
    LitAssets _ :>>= _ -> False

-- | A leg program is well-formed. Leg collections have no literal
-- instrument, so this folds total and true.
validateLeg :: Program LegI () -> Bool
validateLeg prog = case view prog of
    Return () -> True
    LegKeys _ :>>= rest -> validateLeg (rest ())
    LegClaimed _ :>>= rest -> validateLeg (rest ())
    LegEntailed _ :>>= rest -> validateLeg (rest ())
    LegControl _ :>>= rest -> validateLeg (rest ())
    LegDistinguisher _ :>>= rest -> validateLeg (rest ())
    LegTxid _ :>>= rest -> validateLeg (rest ())
    LegControlTxid _ :>>= rest -> validateLeg (rest ())
    LegHashes _ :>>= rest -> validateLeg (rest ())
    OmitTrace :>>= rest -> validateLeg (rest ())

-- | An edit program is well-formed when every nested collection is.
validateEdit :: Program EditI () -> Bool
validateEdit prog = case view prog of
    Return () -> True
    Deliver p :>>= rest -> validateCollection p && validateEdit (rest ())
    Minted p :>>= rest -> validateCollection p && validateEdit (rest ())
    ObservedAddress _ :>>= rest -> validateEdit (rest ())
    OpenParameters _ :>>= rest -> validateEdit (rest ())
    RequestLovelace _ :>>= rest -> validateEdit (rest ())
    ApprovalRecomputed _ :>>= rest -> validateEdit (rest ())
    Refunds _ :>>= rest -> validateEdit (rest ())
    Signers _ :>>= rest -> validateEdit (rest ())
    ConfigAfter _ :>>= rest -> validateEdit (rest ())
    ConfigBefore _ :>>= rest -> validateEdit (rest ())
    LandedFolds _ :>>= rest -> validateEdit (rest ())
    OnLeg _ p :>>= rest -> validateLeg p && validateEdit (rest ())
    DropLeg _ :>>= rest -> validateEdit (rest ())
    Unchanged :>>= rest -> validateEdit (rest ())

-- ---------------------------------------------------------
-- Rendering: the same instructions, read as a story
-- ---------------------------------------------------------

-- | Render a JSON scalar compactly; long hashes read as a prefix so
-- the edit line stays one line.
valueText :: Value -> String
valueText v = case v of
    Aeson.String t ->
        if T.length t > 8
            then T.unpack (T.take 8 t) <> "\8230"
            else T.unpack t
    Aeson.Number n -> show n
    Aeson.Bool b -> show b
    Aeson.Null -> "null"
    Aeson.Array _ -> "[…]"
    Aeson.Object _ -> "{…}"

-- | Render an asset program.
renderAssets :: Program AssetsI () -> String
renderAssets prog = case view prog of
    Return () -> ""
    ActiveToken k qty :>>= rest ->
        "activeToken " <> valueText k <> " " <> show qty <> then_ (renderAssets (rest ()))
    Token policy name qty :>>= rest ->
        "token " <> valueText policy <> " " <> valueText name <> " " <> show qty <> then_ (renderAssets (rest ()))
    NoAssets :>>= rest -> "nothing" <> then_ (renderAssets (rest ()))
    LitAssets _ :>>= rest -> "literal" <> then_ (renderAssets (rest ()))
  where
    then_ "" = ""
    then_ s = "; " <> s

-- | Render the edit line from the instructions that ran.
renderEdit :: Program EditI () -> String
renderEdit prog = case view prog of
    Return () -> "unchanged"
    Deliver p :>>= rest -> "deliver: " <> renderAssets p <> then_ (renderEdit (rest ()))
    Minted p :>>= rest -> "minted: " <> renderAssets p <> then_ (renderEdit (rest ()))
    ObservedAddress addr :>>= rest ->
        "observedAddress " <> valueText addr <> then_ (renderEdit (rest ()))
    OpenParameters n :>>= rest -> "openParameters " <> show n <> then_ (renderEdit (rest ()))
    RequestLovelace n :>>= rest -> "requestLovelace " <> show n <> then_ (renderEdit (rest ()))
    ApprovalRecomputed v :>>= rest ->
        "approvalRecomputed " <> valueText v <> then_ (renderEdit (rest ()))
    Refunds _ :>>= rest -> "refunds" <> then_ (renderEdit (rest ()))
    Signers _ :>>= rest -> "signers" <> then_ (renderEdit (rest ()))
    ConfigAfter _ :>>= rest -> "configAfter" <> then_ (renderEdit (rest ()))
    ConfigBefore _ :>>= rest -> "configBefore" <> then_ (renderEdit (rest ()))
    LandedFolds _ :>>= rest -> "landedFolds" <> then_ (renderEdit (rest ()))
    OnLeg leg p :>>= rest ->
        "onLeg " <> renderLeg leg <> ": " <> renderLegProg p <> then_ (renderEdit (rest ()))
    DropLeg leg :>>= rest -> "without " <> renderLeg leg <> then_ (renderEdit (rest ()))
    Unchanged :>>= rest -> case view (rest ()) of
        Return () -> "unchanged"
        _ -> renderEdit (rest ())
  where
    then_ "unchanged" = ""
    then_ "" = ""
    then_ s = "; " <> s

-- | Render a leg program.
renderLegProg :: Program LegI () -> String
renderLegProg prog = case view prog of
    Return () -> ""
    LegKeys _ :>>= rest -> "keys" <> then_ (renderLegProg (rest ()))
    LegClaimed _ :>>= rest -> "claimedMint" <> then_ (renderLegProg (rest ()))
    LegEntailed _ :>>= rest -> "entailedMint" <> then_ (renderLegProg (rest ()))
    LegControl _ :>>= rest -> "controlMint" <> then_ (renderLegProg (rest ()))
    LegDistinguisher _ :>>= rest -> "distinguisher" <> then_ (renderLegProg (rest ()))
    LegTxid _ :>>= rest -> "txid" <> then_ (renderLegProg (rest ()))
    LegControlTxid _ :>>= rest -> "controlTxid" <> then_ (renderLegProg (rest ()))
    LegHashes _ :>>= rest -> "hashes" <> then_ (renderLegProg (rest ()))
    OmitTrace :>>= rest -> "without trace" <> then_ (renderLegProg (rest ()))
  where
    then_ "" = ""
    then_ s = "; " <> s

-- | Execute an edit program against the real loader.
executeEdit :: Program EditI () -> IO (Either String Int)
executeEdit prog = loadOne (foldEdit prog completeReceipt)

-- | The failure report: the six S1 fields in order, then the reason
-- distinguishing the defect and the edit line rendered from the
-- instructions that ran.
data FailureReport = FailureReport
    { frTheorem :: !String
    , frClause :: !String
    , frExample :: !String
    , frBoundary :: !String
    , frExpected :: !String
    , frActual :: !String
    , frBecause :: !(Maybe String)
    , frEdit :: !String
    }
    deriving stock (Show, Eq)

-- | Render the failure report in reading order.
renderFailure :: FailureReport -> String
renderFailure report =
    unlines
        [ "FAILED"
        , "  theorem   " <> frTheorem report
        , "  clause    " <> frClause report
        , "  example   " <> frExample report
        , "  because   " <> maybe "(accepted without a stated reason)" id (frBecause report)
        , "  boundary  " <> frBoundary report
        , "  edit      " <> frEdit report
        , "  expected  " <> frExpected report
        , "  actual    " <> frActual report
        ]

-- | Check one case: well-formedness first, then the loader's answer
-- against the named outcome. A missing reason ('Nothing', plain
-- 'accepts') is well-formed; an empty one is refused.
checkOne
    :: BoundObligation -> Text -> EvidenceBoundary -> Text -> Maybe Reason -> Program EditI () -> Bool -> IO (Either FailureReport ())
checkOne obligation clauseName boundary name mreason prog expectAccept = do
    result <- executeEdit prog
    let reasonOk = maybe True (not . T.null) mreason
        wellFormed = reasonOk && validateEdit prog
        accepted = acceptsMeaning result
        good = wellFormed && (accepted == expectAccept)
    pure
        ( if good
            then Right ()
            else
                Left
                    ( FailureReport
                        { frTheorem = boName obligation <> " @" <> boRevision obligation
                        , frClause = T.unpack clauseName
                        , frExample = T.unpack name
                        , frBoundary = renderBoundary boundary
                        , frExpected =
                            if expectAccept
                                then "the loader accepts the observation"
                                else "the loader refuses the observation"
                        , frActual = case result of
                            Right n -> "the loader accepted it, returning " <> show n <> " receipt"
                            Left err -> "the loader refused: " <> err
                        , frBecause = fmap T.unpack mreason
                        , frEdit = renderEdit prog
                        }
                    )
        )

-- | Check a case program with its clause context.
checkCase :: Binding -> Text -> EvidenceBoundary -> Program CaseI () -> IO (Either FailureReport ())
checkCase obligation clauseName boundary prog = go prog
  where
    go :: Program CaseI () -> IO (Either FailureReport ())
    go p = case view p of
        Return () -> pure (Right ())
        Accepts name edit :>>= rest -> do
            r <- checkOne obligation clauseName boundary name Nothing edit True
            case r of
                Left report -> pure (Left report)
                Right _ -> go (rest ())
        AcceptsBecause name edit reason :>>= rest -> do
            r <- checkOne obligation clauseName boundary name (Just reason) edit True
            case r of
                Left report -> pure (Left report)
                Right _ -> go (rest ())
        Rejects name reason edit :>>= rest -> do
            r <- checkOne obligation clauseName boundary name (Just reason) edit False
            case r of
                Left report -> pure (Left report)
                Right _ -> go (rest ())

-- | Every clause alias and example name the story declares, read out
-- of the program for the name-hygiene check. Never hand-listed.
groupNames :: Program StoryI () -> [String]
groupNames prog = case view prog of
    Return () -> []
    Theorem _ clauses :>>= rest -> clauseNames clauses <> groupNames (rest ())
  where
    clauseNames :: Program ClauseI () -> [String]
    clauseNames p = case view p of
        Return () -> []
        Clause alias _ cases _ :>>= rest -> T.unpack alias : caseNames cases <> clauseNames (rest ())
        Unexercised alias _ :>>= rest -> T.unpack alias : clauseNames (rest ())
    caseNames :: Program CaseI () -> [String]
    caseNames p = case view p of
        Return () -> []
        Accepts name _ :>>= rest -> T.unpack name : caseNames (rest ())
        AcceptsBecause name _ _ :>>= rest -> T.unpack name : caseNames (rest ())
        Rejects name _ _ :>>= rest -> T.unpack name : caseNames (rest ())

-- | Render one story as the readable theorem-clause-example text.
renderStory :: Program StoryI () -> String
renderStory prog = case view prog of
    Return () -> ""
    Theorem binding clauses :>>= rest ->
        unlines
            [ boName binding <> " @" <> boRevision binding <> " " <> take 8 (boDigest binding) <> "\8230"
            ]
            <> renderClauses clauses
            <> renderStory (rest ())
  where
    renderClauses :: Program ClauseI () -> String
    renderClauses p = case view p of
        Return () -> ""
        Clause alias selects cases (Compat row) :>>= rest ->
            "  " <> T.unpack alias <> "\n"
                <> renderSelects selects
                <> renderCases cases
                <> "    (compatibility: row " <> row <> ")\n"
                <> renderClauses (rest ())
        Unexercised alias missing :>>= rest ->
            "    \8251 unexercised: " <> T.unpack alias <> "\n"
                <> "        " <> T.unpack missing <> "\n"
                <> renderClauses (rest ())
    renderSelects :: Program SelectI () -> String
    renderSelects p = case view p of
        Return () -> ""
        Conjunct t :>>= rest ->
            "      \183 " <> T.unpack t <> "\n" <> renderSelects (rest ())
    renderCases :: Program CaseI () -> String
    renderCases p = case view p of
        Return () -> ""
        Accepts name edit :>>= rest ->
            "      - " <> T.unpack name <> "\n"
                <> "          edit " <> renderEdit edit <> "\n"
                <> renderCases (rest ())
        AcceptsBecause name edit reason :>>= rest ->
            "      - " <> T.unpack name <> "\n"
                <> "          because " <> T.unpack reason <> "\n"
                <> "          edit " <> renderEdit edit <> "\n"
                <> renderCases (rest ())
        Rejects name reason edit :>>= rest ->
            "      - " <> T.unpack name <> "\n"
                <> "          because " <> T.unpack reason <> "\n"
                <> "          edit " <> renderEdit edit <> "\n"
                <> renderCases (rest ())

-- | Run one story as Hspec: theorem, clause, then example. Every
-- example executes the loader; the compatibility row renders as its
-- own line under the clause, not as part of any name.
runStory :: Program StoryI () -> Spec
runStory prog = case view prog of
    Return () -> pure ()
    Theorem binding clauses :>>= rest -> do
        describe (boName binding <> " @" <> boRevision binding) (runClauses binding clauses)
        runStory (rest ())
  where
    runClauses :: Binding -> Program ClauseI () -> Spec
    runClauses binding p = case view p of
        Return () -> pure ()
        Clause alias _ cases (Compat row) :>>= rest -> do
            describe (T.unpack alias) $ do
                runIO (putStrLn ("  (compatibility: row " <> row <> ")"))
                runCases binding alias cases
            runClauses binding (rest ())
        Unexercised _ _ :>>= rest -> runClauses binding (rest ())
    runCases :: Binding -> Text -> Program CaseI () -> Spec
    runCases binding clauseName p = case view p of
        Return () -> pure ()
        Accepts name edit :>>= rest -> do
            it (T.unpack name) $ do
                result <- checkOne binding clauseName ReceiptValidation name Nothing edit True
                case result of
                    Left report -> expectationFailure (renderFailure report)
                    Right _ -> pure ()
            runCases binding clauseName (rest ())
        AcceptsBecause name edit reason :>>= rest -> do
            it (T.unpack name) $ do
                result <- checkOne binding clauseName ReceiptValidation name (Just reason) edit True
                case result of
                    Left report -> expectationFailure (renderFailure report)
                    Right _ -> pure ()
            runCases binding clauseName (rest ())
        Rejects name reason edit :>>= rest -> do
            it (T.unpack name) $ do
                result <- checkOne binding clauseName ReceiptValidation name (Just reason) edit False
                case result of
                    Left report -> expectationFailure (renderFailure report)
                    Right _ -> pure ()
            runCases binding clauseName (rest ())
