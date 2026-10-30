{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TemplateHaskell #-}

{- |
Module      : Singular.Registry.ContractTable
Description : From the hash of Singular's state contract to the releases that carry it
License     : Apache-2.0

A registry is made by one version of the on-chain code, and its policy is the
hash of that version's state contract. A program is given one blueprint, so one
state contract; a registry of another policy was made by other contracts, which
the program cannot run against.

Every release ships a table from each state-contract hash to the releases whose
blueprint carries it, so a refusal can say which contracts the registry was
made by and where to get them. The table is one committed data file of this
package, embedded in the executable from the program's own release. The
applied-policy rows also identify the application's policy and script and their
releases. @tools/fill_contract_table.sh@ derives those rows from compiled
blueprints; the retained legacy rows and exclusions remain separate.

A hash that appears in no row is a registry made by contracts of no known
release; a row with no release is a registry made by contracts that are not
released yet.

Which release serves a registry is one function of this table, the release pair
of the installed commands and the registry's contract ('servingOf'); the lines
every command prints for it are one function of that answer ('servingLines').
The module names no application: an application's identity comes from the
table's rows.
-}
module Singular.Registry.ContractTable
    ( -- * The table
      ContractTable
    , tableRows
    , tableLeftOut
    , parseContractTable
    , loadContractTable
    , tableFile
    , ApplicationIdentity (..)
    , applicationRows
    , applicationOf

      -- * What it says of a hash
    , Contracts (..)
    , contractsOf

      -- * Which release serves a registry
    , Installed (..)
    , Serving (..)
    , servingOf
    , servingLines

      -- * Release pages
    , releaseUrl
    ) where

import Control.Applicative ((<|>))
import Control.Monad (unless, when)
import Data.Aeson
    ( FromJSON (..)
    , ToJSON (..)
    , eitherDecodeStrict'
    , object
    , withObject
    , (.:)
    , (.:?)
    , (.=)
    )
import Data.Aeson.Types (Parser)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.FileEmbed (embedFileRelative)
import Data.List (sort)
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Text.Read (readMaybe)

{- | The table: the releases of each state-contract hash, oldest first, and the
releases the filling left out with the reason each is left out.
-}
data ContractTable = ContractTable
    { rows :: Map ByteString [Text]
    , leftOut :: [(Text, Text)]
    , applications :: Map ByteString ApplicationIdentity
    }
    deriving stock (Eq, Show)

{- | The published identity of an application under one applied state policy.
An empty release list means this build has no known release yet.
-}
data ApplicationIdentity = ApplicationIdentity
    { appliedStatePolicy :: ByteString
    , applicationPolicy :: ByteString
    , applicationScript :: ByteString
    , singularReleases :: [Text]
    , applicationReleases :: [Text]
    }
    deriving stock (Eq, Show)

instance ToJSON ApplicationIdentity where
    toJSON identity =
        object
            [ "state-policy" .= hex (appliedStatePolicy identity)
            , "application-policy" .= hex (applicationPolicy identity)
            , "application-script" .= hex (applicationScript identity)
            , "singular-releases" .= singularReleases identity
            , "application-releases" .= applicationReleases identity
            ]
      where
        hex = TE.decodeUtf8 . B16.encode

-- | All known applied state policies, in hash order.
applicationRows :: ContractTable -> [ApplicationIdentity]
applicationRows = Map.elems . applications

-- | Exact lookup only. An unknown applied state policy identifies no application.
applicationOf
    :: ContractTable -> ByteString -> Maybe ApplicationIdentity
applicationOf table policy = Map.lookup policy (applications table)

-- | The rows: a 28-byte state-contract hash and the tags of the releases that carry it.
tableRows :: ContractTable -> [(ByteString, [Text])]
tableRows = Map.toList . rows

-- | The releases left out of the table, each with its reason.
tableLeftOut :: ContractTable -> [(Text, Text)]
tableLeftOut = leftOut

-- | What the table says of one state-contract hash.
data Contracts
    = -- | Made by the contracts of these releases, oldest first
      Released (NonEmpty Text)
    | -- | A row that lists no release: the contracts are not released yet
      NotReleasedYet
    | -- | No row: the contracts of no known release
      NoKnownRelease
    deriving stock (Eq, Show)

-- | The table's file under the package's data directory.
tableFile :: FilePath
tableFile = "data/contracts/state-contracts.json"

-- | What the table says of a hash of 28 bytes.
contractsOf :: ContractTable -> ByteString -> Contracts
contractsOf table hash = case Map.lookup hash (rows table)
    <|> (singularReleases <$> applicationOf table hash) of
    Nothing -> NoKnownRelease
    Just [] -> NotReleasedYet
    Just (oldest : newer) -> Released (oldest :| newer)

-- | The table embedded in this program's release; no runtime file is read.
loadContractTable :: IO (Either Text ContractTable)
loadContractTable =
    pure
        ( parseContractTable
            $(embedFileRelative "data/contracts/state-contracts.json")
        )

{- | Read the table's text: one object with its rows and the releases left out.
A hash appears in one row and the releases of a row are oldest first.
-}
parseContractTable :: ByteString -> Either Text ContractTable
parseContractTable bytes = do
    file <- either (Left . T.pack) Right (eitherDecodeStrict' bytes)
    listed <- traverse readRow (fileRows file)
    appRows <- traverse readApplication (fileApplications file)
    let applied = [(appliedStatePolicy row, row) | row <- appRows]
    when
        (length applied /= Map.size (Map.fromList applied))
        (Left "an applied state policy appears in two application rows")
    let hashes = map fst listed
    when
        (length hashes /= Map.size (Map.fromList listed))
        (Left "a state-contract hash appears in two rows")
    pure
        ContractTable
            { rows = Map.fromList listed
            , leftOut =
                [(release, reason) | LeftOut release reason <- fileLeftOut file]
            , applications = Map.fromList applied
            }
  where
    readApplication (ApplicationRow state policy script singular app) =
        ApplicationIdentity
            <$> readHash state
            <*> readHash policy
            <*> readHash script
            <*> readTags state singular
            <*> readTags state app
    readRow (Row hex tags) = do
        hash <- readHash hex
        checked <- readTags hex tags
        pure (hash, checked)
    readHash hex = do
        hash <-
            either
                (const (Left ("the hash " <> hex <> " is not hex")))
                Right
                (B16.decode (TE.encodeUtf8 hex))
        unless
            (BS.length hash == 28)
            (Left ("the hash " <> hex <> " is not 28 bytes"))
        pure hash
    readTags hex tags = do
        versions <- traverse tagVersion tags
        unless
            (versions == sort versions)
            (Left ("the releases of the hash " <> hex <> " are not oldest first"))
        pure tags
    tagVersion tag = case T.stripPrefix "v" tag of
        Just rest
            | [Just a, Just b, Just c] <-
                map (readMaybe . T.unpack) (T.splitOn "." rest) ->
                Right (a :: Int, b :: Int, c :: Int)
        _ -> Left ("the release " <> tag <> " is not a tag of the form v1.2.3")

data File = File
    { fileRows :: [Row]
    , fileLeftOut :: [LeftOut]
    , fileApplications :: [ApplicationRow]
    }

data Row = Row Text [Text]

data ApplicationRow = ApplicationRow Text Text Text [Text] [Text]

data LeftOut = LeftOut Text Text

instance FromJSON File where
    parseJSON = withObject "the table of releases" $ \o ->
        File
            <$> o .: "rows"
            <*> (fromMaybe [] <$> o .:? "left-out")
            <*> (fromMaybe [] <$> o .:? "applications")

instance FromJSON ApplicationRow where
    parseJSON = withObject "an application identity" $ \o ->
        ApplicationRow
            <$> o .: "state-policy"
            <*> o .: "application-policy"
            <*> o .: "application-script"
            <*> o .: "singular-releases"
            <*> o .: "application-releases"

instance FromJSON Row where
    parseJSON = withObject "a row of the table" $ \o ->
        Row <$> o .: "state-contract" <*> o .: "releases"

instance FromJSON LeftOut where
    parseJSON = withObject "a release left out" $ \o ->
        LeftOut <$> field o "release" <*> field o "reason"
      where
        field o name = o .: name :: Parser Text

{- | What the commands that read or write a registry are: the release they belong
to, and the state policies they serve by their own derivation (a write derives
the policy of its blueprint, a read serves every applied state policy the table
holds). A release is not asked whether the table lists it: the table may lag
the release being cut.
-}
data Installed = Installed
    { installedSingular :: Text
    -- ^ The tag of the Singular release the commands belong to
    , installedServes :: [ByteString]
    -- ^ The state policies the commands serve by derivation
    }
    deriving stock (Eq, Show)

-- | Which release serves a registry, from the table and nowhere else.
data Serving
    = -- | The installed commands serve it, by their own derivation
      ServedHere
    | -- | These earlier Singular releases serve it, oldest first
      ServedByEarlier (NonEmpty Text)
    | -- | The Singular release is the installed one, the application is not; these application releases serve it
      ServedByApplication (NonEmpty Text)
    | -- | The contracts are in no release the table knows
      UnknownContract
    | -- | The contracts are in the table with no release yet
      UnreleasedContract
    | -- | The table of releases could not be used, and why
      TableUnusable Text
    deriving stock (Eq, Show)

{- | Which release serves a registry whose state policy is this hash. A policy the
installed commands serve by derivation is served here, whatever the table lists.
For any other the table alone answers: an applied state policy whose Singular
release is the installed one is served by the application releases it lists,
one of another Singular release by the Singular releases it lists, a legacy
state contract by the releases of its row, and a hash no row holds by no
release at all.
-}
servingOf :: ContractTable -> Installed -> ByteString -> Serving
servingOf table installed hash
    | hash `elem` installedServes installed = ServedHere
    | otherwise = case applicationOf table hash of
        Just identity ->
            notServed (singularReleases identity) (applicationReleases identity)
        Nothing -> case contractsOf table hash of
            Released tags -> ServedByEarlier tags
            NotReleasedYet -> UnreleasedContract
            NoKnownRelease -> UnknownContract
  where
    notServed [] _ = UnreleasedContract
    notServed singular@(oldest : newer) application = case application of
        first : more
            | installedSingular installed `elem` singular ->
                ServedByApplication (first :| more)
        _ -> ServedByEarlier (oldest :| newer)

{- | The lines every command prints for a serving answer, the same lines for the
same answer. Nothing is said when the installed release serves the registry.
-}
servingLines :: Serving -> [Text]
servingLines = \case
    ServedHere -> []
    ServedByEarlier tags ->
        [ "This release does not serve this registry. It is served by "
            <> releasesText tags
            <> "."
        , "Get " <> NE.last tags <> " at " <> releaseUrl (NE.last tags)
        ]
    ServedByApplication tags ->
        [ "This release serves the contracts of this registry but not its application. The application is served by "
            <> releasesText tags
            <> "."
        ]
    UnknownContract ->
        [ "This release does not serve this registry, and the table of releases knows of no release that does: its contracts are in no published release."
        ]
    UnreleasedContract ->
        [ "This release does not serve this registry, and the table of releases knows of no release that does: its contracts are not released yet."
        ]
    TableUnusable why ->
        [ "The table of releases cannot be used, so no release can be named for this registry: "
            <> why
        ]
  where
    releasesText tags =
        (if NE.length tags == 1 then "the release " else "the releases ")
            <> listed (NE.toList tags)
    listed = \case
        [] -> ""
        [one] -> one
        several ->
            T.intercalate ", " (init several) <> " and " <> last several

-- | The page of a release.
releaseUrl :: Text -> Text
releaseUrl tag = "https://github.com/lambdasistemi/singular/releases/tag/" <> tag
