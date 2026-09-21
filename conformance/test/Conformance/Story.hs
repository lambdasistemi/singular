{- |
Module      : Conformance.Story
Description : Theorem-clause DSL: bindings, clauses, executed examples
License     : Apache-2.0

Slice S1 (T194-01, T194-02, T194-03, T194-05). Bindings resolve against
the repository's own statement manifest, read at run time and never
copied. Clauses resolve against the slice's conjunct inventory for the
named obligation: an empty selection, or an anchor outside that
obligation's inventory, is refused, and every quoted anchor is
reconciled against the Lean source on every run. Examples carry a
mandatory executable action; validation runs it, and a mismatched
expectation renders the six mandatory failure fields in reading
order: theorem, clause, example, boundary, expected, actual.
-}
module Conformance.Story (
    BoundObligation (..),
    Clause (..),
    ClauseGroup (..),
    Compat (..),
    Example (..),
    EvidenceBoundary (..),
    Expectation (..),
    FailureReport (..),
    TheoremGroup (..),
    UnexercisedClause (..),
    accepts,
    acceptsBecause,
    anchorsPresent,
    checkExample,
    compatRow,
    groupNames,
    loadManifest,
    loadStatementSource,
    mkBoundObligation,
    mkClause,
    nameViolation,
    receiptClause,
    rejects,
    renderBoundary,
    renderFailure,
    resolveBinding,
    resolveClause,
    runExample,
    runClauseGroup,
    runTheorem,
    theorem,
    unexercised,
    unexercisedChecks,
    validateExample,
) where

import Control.Monad (forM_)
import Data.Aeson (FromJSON (..), eitherDecode, withObject, (.:))
import Data.ByteString.Lazy qualified as BSL
import Data.List (isInfixOf)
import System.Directory (doesFileExist)
import Test.Hspec (Spec, describe, expectationFailure, it, runIO)

-- | A Lean obligation the DSL examples bind to.
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

-- | Read the repository's own statement manifest. The pinned digest in
-- a 'BoundObligation' is reconciled against this file on every run,
-- so it cannot drift silently; the manifest itself is validated
-- against the Lean source by @nix run --quiet .#model-check@.
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
resolveBinding :: [(String, String)] -> BoundObligation -> Bool
resolveBinding manifest obligation =
    lookup (boName obligation) manifest == Just (boDigest obligation)

-- | Read the bound Lean source. Every conjunct anchor the slice quotes
-- is reconciled against this text on every run.
loadStatementSource :: IO (Either String String)
loadStatementSource = do
    found <- firstExisting ["../lean/Singular/Statements.lean", "lean/Singular/Statements.lean"]
    case found of
        Nothing -> pure (Left "statement source not found: want ../lean/Singular/Statements.lean")
        Just path -> Right <$> readFile path

-- | Every anchor quoted anywhere in the inventory appears verbatim in
-- the source. A mistyped anchor, or a conjunct the model no longer
-- states, fails this check instead of drifting silently.
anchorsPresent :: String -> [(String, [String])] -> Bool
anchorsPresent source inventory =
    all (`isInfixOf` source) [anchor | (_, anchors) <- inventory, anchor <- anchors]

-- | A clause alias selecting conjuncts of the bound statement. Each
-- selected string is a verbatim anchor quoted from the statement, and
-- the alias's human reading rides beside them for the report.
data Clause = Clause
    { clauseAlias :: !String
    , clauseConjuncts :: ![String]
    }
    deriving stock (Show, Eq)

-- | Name a clause alias for its selected conjunct anchors.
mkClause :: String -> [String] -> Clause
mkClause = Clause

-- | Whether a clause or example name smuggles in a row ID or ticket
-- number. One predicate, used by every hygiene check and pinned by
-- its own firing control below.
nameViolation :: String -> Bool
nameViolation n = "CG" `isInfixOf` n || '#' `elem` n

-- | A clause resolves exactly when it selects at least one conjunct
-- and every selected anchor belongs to the named obligation's
-- inventory. An alias bound to nothing, to gibberish, or to another
-- theorem's conjunct is refused. Which alias claims which anchors is
-- pinned per clause by the suite and vetted by review against Lean;
-- this check enforces that every claimed anchor is a real conjunct of
-- the named obligation.
resolveClause :: [(String, [String])] -> BoundObligation -> Clause -> Bool
resolveClause inventory obligation clause =
    not (null (clauseConjuncts clause))
        && all (`elem` anchorsFor (boName obligation)) (clauseConjuncts clause)
  where
    anchorsFor name = case lookup name inventory of
        Just anchors -> anchors
        Nothing -> []

-- | Where the example's evidence was observed. Exactly two, carried in
-- the type: a receipt-validation group cannot be spelled as a
-- transaction-execution one.
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

-- | What the example expects the executed action to observe.
data Expectation
    = ExpectAccept
    | ExpectRefuse
    deriving stock (Show, Eq)

-- | One named example. The executable action is mandatory: there is no
-- construction without one, and validation runs it. The reason records
-- why this case distinguishes its defect.
data Example = Example
    { exName :: !String
    , exAction :: !(IO (Either String Int))
    , exExpectation :: !Expectation
    , exReason :: !(Maybe String)
    }

-- | Whether a loader result matches an expectation. Acceptance is
-- exact: one written file loads exactly one receipt, so an accepts
-- over zero or two receipts is refused, not vacuously passed.
matchesExpectation :: Expectation -> Either String Int -> Bool
matchesExpectation ExpectAccept (Right 1) = True
matchesExpectation ExpectRefuse (Left _) = True
matchesExpectation _ _ = False

-- | Validate an example by executing its action and checking the
-- result against its expectation. Validation runs the subject; there
-- is no non-executed path.
validateExample :: Example -> IO Bool
validateExample ex = matchesExpectation (exExpectation ex) <$> exAction ex

-- | The six fields a failure rendering must carry.
data FailureReport = FailureReport
    { frTheorem :: !String
    , frClause :: !String
    , frExample :: !String
    , frBoundary :: !String
    , frExpected :: !String
    , frActual :: !String
    }
    deriving stock (Show, Eq)

-- | Run one example's action and check it: 'Right ()' when the loader
-- did what was expected, 'Left' with the six-field report otherwise.
-- The report is produced by running the subject, never written by hand.
checkExample
    :: BoundObligation -> Clause -> EvidenceBoundary -> Example -> IO (Either FailureReport ())
checkExample obligation clause boundary ex = do
    result <- exAction ex
    pure
        ( if matchesExpectation (exExpectation ex) result
            then Right ()
            else
                Left
                    ( FailureReport
                        { frTheorem = boName obligation <> " @" <> boRevision obligation
                        , frClause = clauseAlias clause
                        , frExample = exName ex
                        , frBoundary = renderBoundary boundary
                        , frExpected = expectedText (exExpectation ex)
                        , frActual = actualText result
                        }
                    )
        )
  where
    expectedText ExpectAccept = "the loader accepts the observation"
    expectedText ExpectRefuse = "the loader refuses the observation"
    actualText (Right n) = "the loader accepted it, returning " <> show n <> " receipt"
    actualText (Left err) = "the loader refused: " <> err

-- | Render the six mandatory failure fields in reading order. Every
-- mismatched expectation exits through this shape, so a report
-- missing any of theorem, clause, example, boundary, expected or
-- actual is a defect in the caller, not a shorter report.
renderFailure :: FailureReport -> String
renderFailure report =
    unlines
        [ "FAILED"
        , "  theorem   " <> frTheorem report
        , "  clause    " <> frClause report
        , "  example   " <> frExample report
        , "  boundary  " <> frBoundary report
        , "  expected  " <> frExpected report
        , "  actual    " <> frActual report
        ]

-- | Run one example as an Hspec case under its theorem and clause.
runExample :: BoundObligation -> Clause -> EvidenceBoundary -> Example -> Spec
runExample obligation clause boundary ex =
    it (exName ex) $ do
        result <- checkExample obligation clause boundary ex
        case result of
            Left report -> expectationFailure (renderFailure report)
            Right _ -> pure ()

-- | A clause the slice does not exercise. Recorded with its alias and
-- what exercising it would need; it contributes no check and earns no
-- coverage, so a theorem pointer alone never reads as evidence.
data UnexercisedClause = UnexercisedClause
    { unAlias :: !String
    , unWhatMissing :: !String
    }
    deriving stock (Show, Eq)

-- | Record an unexercised clause.
unexercised :: String -> String -> UnexercisedClause
unexercised = UnexercisedClause

-- | The executable checks an unexercised clause contributes: none. The
-- type leaves no other option; this pins it.
unexercisedChecks :: UnexercisedClause -> Int
unexercisedChecks _ = 0

-- ---------------------------------------------------------
-- The reading surface: theorem, clause, receipt examples
-- ---------------------------------------------------------

-- | Compatibility metadata: the stable receipt row an example's
-- fixtures run against. Carried beside the example and rendered as
-- its own line, never part of a clause or example name.
newtype Compat = Compat String
    deriving stock (Show, Eq)

-- | Carry a stable row identity beside a clause group.
compatRow :: String -> Compat
compatRow = Compat

-- | Accept the observation: the loader must take it. The reason stays
-- optional; a passing baseline often has nothing non-obvious to say.
accepts :: String -> IO (Either String Int) -> Example
accepts name action = Example name action ExpectAccept Nothing

-- | Accept the observation, recording why the case matters.
acceptsBecause :: String -> IO (Either String Int) -> String -> Example
acceptsBecause name action reason = Example name action ExpectAccept (Just reason)

-- | Refuse the observation. The reason is a required argument: a
-- rejection claims the mutation is caught for a reason, and the type
-- demands it so nobody has to remember it.
rejects :: String -> IO (Either String Int) -> String -> Example
rejects name action reason = Example name action ExpectRefuse (Just reason)

-- | One clause with its receipt-validation examples, its unexercised
-- records, and the row compatibility beside them. The boundary is
-- fixed to receipt validation by construction: this group cannot
-- spell a transaction execution.
data ClauseGroup = ClauseGroup
    { cgClause :: !Clause
    , cgExamples :: ![Example]
    , cgUnexercised :: ![UnexercisedClause]
    , cgCompat :: !Compat
    }

-- | Group a clause's receipt-validation examples.
receiptClause :: Clause -> [Example] -> [UnexercisedClause] -> Compat -> ClauseGroup
receiptClause = ClauseGroup

-- | One bound obligation with the clause groups that read it.
data TheoremGroup = TheoremGroup
    { tgObligation :: !BoundObligation
    , tgClauses :: ![ClauseGroup]
    }

-- | Read an obligation through its clauses.
theorem :: BoundObligation -> [ClauseGroup] -> TheoremGroup
theorem = TheoremGroup

-- | Every clause alias and example name the group declares, read out
-- of the DSL value for the name-hygiene check. Never hand-listed:
-- adding a case extends this list by construction.
groupNames :: TheoremGroup -> [String]
groupNames tg =
    [clauseAlias (cgClause cg) | cg <- tgClauses tg]
        <> [exName ex | cg <- tgClauses tg, ex <- cgExamples cg]

-- | Run a theorem group as Hspec: theorem, clause, then example. The
-- compatibility row renders as its own line under the clause, not as
-- part of any name.
runTheorem :: TheoremGroup -> Spec
runTheorem tg =
    describe (boName (tgObligation tg) <> " @" <> boRevision (tgObligation tg)) $
        forM_ (tgClauses tg) (runClauseGroup (tgObligation tg))

-- | Run one clause group under its obligation: its examples
-- execute, its unexercised records contribute no check. The
-- compatibility row renders as its own line under the clause, not as
-- part of any name.
runClauseGroup :: BoundObligation -> ClauseGroup -> Spec
runClauseGroup obligation cg = describe (clauseAlias (cgClause cg)) $ do
    runIO (putStrLn ("  (compatibility: row " <> row <> ")"))
    forM_ (cgExamples cg) (runExample obligation (cgClause cg) ReceiptValidation)
  where
    row = case cgCompat cg of Compat r -> r

