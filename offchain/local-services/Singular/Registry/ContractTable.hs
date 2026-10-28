{-# LANGUAGE LambdaCase #-}

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
package, packaged and found like the preprod network-time data, from the
program's own release. Its rows are filled from the published release assets
by @tools/fill_contract_table.sh@; the file names every release it leaves out.

A hash that appears in no row is a registry made by contracts of no known
release; a row with no release is a registry made by contracts that are not
released yet.
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

      -- * The refusal
    , renderForeignRelease
    , releaseUrl
    ) where

import Control.Applicative ((<|>))
import Control.Exception (IOException, try)
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
import Data.List (sort)
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Paths_singular_registry (getDataFileName)
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
    | -- | The table could not be read, and why
      TableUnreadable Text
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

-- | The table of this program's own release, read from its packaged data.
loadContractTable :: IO (Either Text ContractTable)
loadContractTable = do
    path <- getDataFileName tableFile
    read' <- try (BS.readFile path) :: IO (Either IOException ByteString)
    pure $ case read' of
        Left why ->
            Left
                ( "the table of releases at "
                    <> T.pack path
                    <> " cannot be read: "
                    <> T.pack (show why)
                )
        Right bytes -> parseContractTable bytes

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

-- | The page of a release.
releaseUrl :: Text -> Text
releaseUrl tag = "https://github.com/lambdasistemi/singular/releases/tag/" <> tag

{- | The sentence of the refusal of a registry whose policy is not the state
contract of the blueprint the command was given. It keeps the refusal's name,
says which contracts made the registry and, when a release carries them, where
to get the newest of those.
-}
renderForeignRelease :: Contracts -> Text
renderForeignRelease = \case
    Released tags ->
        "state-token-foreign-release: the registry was made by the contracts of the "
            <> (if NE.length tags == 1 then "release " else "releases ")
            <> listed (NE.toList tags)
            <> ", not by the contracts of this blueprint; the newest of them is at "
            <> releaseUrl (NE.last tags)
    NotReleasedYet ->
        refusal
            <> "made by contracts that are not released yet, not by the contracts of this blueprint"
    NoKnownRelease ->
        refusal
            <> "made by contracts of no known release, not by the contracts of this blueprint"
    TableUnreadable why ->
        refusal
            <> "made by other contracts than this blueprint's, and the table of releases that names them cannot be used: "
            <> why
  where
    refusal = "state-token-foreign-release: the registry was "
    listed = \case
        [] -> ""
        [one] -> one
        several ->
            T.intercalate ", " (init several) <> " and " <> last several
