{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Revision-bound Lean identities and statement anchors.
module Conformance.Story.Binding (
    BoundObligation (..),
    Binding,
    ManifestEntry (..),
    mkBoundObligation,
    firstExisting,
    loadManifest,
    resolveBinding,
    loadStatementSource,
    anchorsPresent,
    nameViolation,
    resolveClause
) where

import Data.Aeson (FromJSON (..), eitherDecode, withObject, (.:))
import Data.ByteString.Lazy qualified as BSL
import Data.List (isInfixOf)
import Data.Text (Text)
import Data.Text qualified as T
import System.Directory (doesFileExist)

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

