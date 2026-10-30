{-# LANGUAGE LambdaCase #-}

{- |
Module      : Singular.Registry.ContractTableSpec
Description : From the hash of the state contract to the releases that carry it
License     : Apache-2.0

The table of releases is one committed data file that every release ships.
These cases hold what a refusal says from it, and what keeps it complete:

* a hash the table knows gives the releases that carry it, oldest first, a hash
  it does not know gives no known release, and a row with no release gives
  contracts not released yet;
* the sentence of each case keeps the refusal's name, names the releases and
  the URL of the newest, or says what is not known;
* a table that lists a hash twice, a release out of order or a hash that is not
  28 bytes is refused as a file;
-}
module Singular.Registry.ContractTableSpec (spec) where

import Control.Exception (bracket_)
import Control.Monad (forM_)
import Data.Aeson qualified as Aeson
import Data.ByteString (ByteString)
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as BL
import Data.Either (fromRight, isLeft)
import Data.List (maximumBy, nub)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Maybe (fromMaybe)
import Data.Ord (comparing)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Data.Version (versionBranch)
import System.Environment (lookupEnv, setEnv, unsetEnv)
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec
import Text.Read (readMaybe)

import Paths_singular_registry (version)

import Singular.Registry.ContractTable
    ( ApplicationIdentity (..)
    , ContractTable
    , Contracts (..)
    , applicationOf
    , applicationRows
    , contractsOf
    , loadContractTable
    , parseContractTable
    , releaseUrl
    , renderForeignRelease
    , tableLeftOut
    , tableRows
    )

spec :: Spec
spec = describe "the table of releases" $ do
    applicationLookupRows
    lookupRows
    sentenceRows
    fileRows
    packagedRows
    releaseRows

applicationLookupRows :: Spec
applicationLookupRows = describe "an applied state policy" $ do
    it "names exactly its application, script and the releases of each" $ do
        let rows =
                [ ApplicationIdentity
                    (hashOf 'a')
                    (hashOf 'b')
                    (hashOf 'c')
                    ["v0.17.0"]
                    ["v0.17.0"]
                , ApplicationIdentity (hashOf 'd') (hashOf 'e') (hashOf 'f') [] []
                ]
            bytes =
                BL.toStrict
                    ( Aeson.encode
                        ( Aeson.object
                            ["rows" Aeson..= ([] :: [Aeson.Value]), "applications" Aeson..= rows]
                        )
                    )
        table <- either (fail . T.unpack) pure (parseContractTable bytes)
        applicationRows table `shouldBe` rows
        map (applicationOf table . appliedStatePolicy) rows
            `shouldBe` map Just rows
        applicationOf table (hashOf '0') `shouldBe` Nothing
    it "refuses an invalid hash and releases out of order" $ do
        let row = ApplicationIdentity (hashOf 'a') (hashOf 'b') (hashOf 'c') [] []
            parse rows =
                parseContractTable
                    ( BL.toStrict
                        ( Aeson.encode
                            ( Aeson.object
                                ["rows" Aeson..= ([] :: [Aeson.Value]), "applications" Aeson..= rows]
                            )
                        )
                    )
        parse [row{applicationPolicy = "short"}] `shouldSatisfy` isLeft
        parse [row{singularReleases = ["v0.17.0", "v0.16.0"]}]
            `shouldSatisfy` isLeft
        parse [row{applicationReleases = ["not-a-release"]}]
            `shouldSatisfy` isLeft

-- | A hash of 28 bytes, all this byte.
hashOf :: Char -> ByteString
hashOf c = fromRight mempty (B16.decode (BC.replicate 56 c))

-- | The table text of rows, each a hash in hex and its releases.
tableTextHex :: [(Text, [Text])] -> ByteString
tableTextHex rows =
    BL.toStrict . Aeson.encode $
        Aeson.object
            [
                ( "rows"
                , Aeson.toJSON
                    [ Aeson.object
                        [ ("state-contract", Aeson.toJSON hex)
                        , ("releases", Aeson.toJSON tags)
                        ]
                    | (hex, tags) <- rows
                    ]
                )
            ]

-- | The same for rows each a hash character, repeated, and its releases.
tableText :: [(Char, [Text])] -> ByteString
tableText rows =
    tableTextHex
        [(T.replicate 56 (T.singleton c), tags) | (c, tags) <- rows]

tableOf :: [(Char, [Text])] -> IO ContractTable
tableOf rows =
    either
        (\why -> fail ("the table: " <> T.unpack why))
        pure
        (parseContractTable (tableText rows))

lookupRows :: Spec
lookupRows = describe "a hash" $ do
    it "the table knows is given the releases that carry it, oldest first" $ do
        table <-
            tableOf [('a', ["v0.1.0", "v0.2.0", "v0.10.0"]), ('b', ["v0.11.0"])]
        contractsOf table (hashOf 'a')
            `shouldBe` Released ("v0.1.0" :| ["v0.2.0", "v0.10.0"])
        contractsOf table (hashOf 'b') `shouldBe` Released ("v0.11.0" :| [])
    it "the table does not know is the contracts of no known release" $ do
        table <- tableOf [('a', ["v0.1.0"])]
        contractsOf table (hashOf 'c') `shouldBe` NoKnownRelease
    it "a row has with no release is the contracts not released yet" $ do
        table <- tableOf [('a', ["v0.1.0"]), ('d', [])]
        contractsOf table (hashOf 'd') `shouldBe` NotReleasedYet
        contractsOf table (hashOf 'a') `shouldBe` Released ("v0.1.0" :| [])

sentenceRows :: Spec
sentenceRows = describe "the refusal" $ do
    let lists = Released ("v0.4.1" :| ["v0.5.0", "v0.6.0", "v0.6.1"])
        sentence = T.unpack (renderForeignRelease lists)
    it "keeps its name and names every release of the contracts" $ do
        sentence `shouldSatisfy` isPrefixed "state-token-foreign-release"
        mapM_
            (\tag -> sentence `shouldSatisfy` isIn tag)
            ["v0.4.1", "v0.5.0", "v0.6.0", "v0.6.1"]
    it "gives the page of the newest of them and of no other" $ do
        sentence `shouldSatisfy` isIn (T.unpack (releaseUrl "v0.6.1"))
        mapM_
            (\tag -> sentence `shouldNotSatisfy` isIn (T.unpack (releaseUrl tag)))
            ["v0.4.1", "v0.5.0", "v0.6.0"]
        releaseUrl "v0.6.1"
            `shouldBe` "https://github.com/lambdasistemi/singular/releases/tag/v0.6.1"
    it "names one release in the singular" $
        T.unpack (renderForeignRelease (Released ("v0.7.0" :| [])))
            `shouldSatisfy` isIn "the release v0.7.0"
    it "says no known release when the table has no row" $
        T.unpack (renderForeignRelease NoKnownRelease)
            `shouldSatisfy` isIn "no known release"
    it "says not released yet when the row lists no release" $
        T.unpack (renderForeignRelease NotReleasedYet)
            `shouldSatisfy` isIn "not released yet"
    it "says the table cannot be used, and why, when it cannot be read" $
        T.unpack (renderForeignRelease (TableUnreadable "no such file"))
            `shouldSatisfy` isIn "no such file"
    it "names no release and no page when it knows none" $
        mapM_
            ( \c ->
                T.unpack (renderForeignRelease c)
                    `shouldNotSatisfy` isIn "releases/tag"
            )
            [NoKnownRelease, NotReleasedYet]
  where
    isIn needle hay = T.isInfixOf (T.pack needle) (T.pack hay)
    isPrefixed prefix hay = T.isPrefixOf (T.pack prefix) (T.pack hay)

fileRows :: Spec
fileRows = describe "a table file" $ do
    it "is read, the control of the refusals below" $
        parseContractTable (tableText [('a', ["v0.1.0", "v0.2.0"])])
            `shouldSatisfy` either (const False) (const True)
    it "that lists a hash in two rows is refused" $
        parseContractTable (tableText [('a', ["v0.1.0"]), ('a', ["v0.2.0"])])
            `shouldSatisfy` isLeft
    it "with the releases of a row out of order is refused" $
        parseContractTable (tableText [('a', ["v0.2.0", "v0.1.0"])])
            `shouldSatisfy` isLeft
    it "orders the releases by their numbers, not as text" $
        parseContractTable (tableText [('a', ["v0.9.0", "v0.10.0"])])
            `shouldSatisfy` either (const False) (const True)
    it "with a hash that is not 28 bytes is refused" $
        parseContractTable
            ( BL.toStrict . Aeson.encode $
                Aeson.object
                    [
                        ( "rows"
                        , Aeson.toJSON
                            [ Aeson.object
                                [ ("state-contract", Aeson.toJSON ("abcd" :: Text))
                                , ("releases", Aeson.toJSON ["v0.1.0" :: Text])
                                ]
                            ]
                        )
                    ]
            )
            `shouldSatisfy` isLeft
    it "with a release that is not a tag is refused" $
        parseContractTable (tableText [('a', ["0.1.0"])])
            `shouldSatisfy` isLeft
    it "that is not a table is refused" $
        parseContractTable "[]" `shouldSatisfy` isLeft

packagedRows :: Spec
packagedRows = describe "the packaged table" $ do
    it "refuses duplicate applied state policies in application rows" $ do
        let row =
                Aeson.object
                    [ "state-policy" Aeson..= T.replicate 56 "a"
                    , "application-policy" Aeson..= T.replicate 56 "b"
                    , "application-script" Aeson..= T.replicate 56 "c"
                    , "singular-releases" Aeson..= ([] :: [Text])
                    , "application-releases" Aeson..= ([] :: [Text])
                    ]
        parseContractTable
            ( BL.toStrict
                ( Aeson.encode
                    ( Aeson.object
                        [ "rows" Aeson..= ([] :: [Aeson.Value])
                        , "applications" Aeson..= [row, row]
                        ]
                    )
                )
            )
            `shouldSatisfy` isLeft
    it "is available when no external package data file is installed" $
        withSystemTempDirectory "table-without-data" $ \directory -> do
            previous <- lookupEnv "singular_registry_datadir"
            bracket_
                (setEnv "singular_registry_datadir" directory)
                ( maybe
                    (unsetEnv "singular_registry_datadir")
                    (setEnv "singular_registry_datadir")
                    previous
                )
                ( loadContractTable
                    >>= either
                        (expectationFailure . T.unpack)
                        (\table -> tableRows table `shouldSatisfy` (not . null))
                )
    it "is found from the package's own data and read" $
        loadContractTable >>= \case
            Left why -> expectationFailure (T.unpack why)
            Right table -> tableRows table `shouldSatisfy` (not . null)
    it "lists every release once, under the one hash that carries it" $
        withPackaged $ \table -> do
            let tags = concatMap snd (tableRows table)
            tags `shouldBe` nub tags
    it "names the release it leaves out, with its reason" $
        withPackaged $ \table ->
            lookup "v0.2.0" (tableLeftOut table)
                `shouldSatisfy` maybe False (T.isInfixOf "no on-chain archive")
  where
    withPackaged use =
        loadContractTable >>= either (expectationFailure . T.unpack) use

-- ---------------------------------------------------------
-- Every release older than the package is named once
-- ---------------------------------------------------------

{- | The releases a project's release history names: the headings that carry a
comparison link (the first release has none and was never published).
-}
releasesIn :: Text -> [Text]
releasesIn history =
    [ "v" <> T.takeWhile (/= ']') rest
    | line <- T.lines history
    , Just rest <- [T.stripPrefix "## [" line]
    , T.isInfixOf "](" rest
    ]

-- | The releases of the project's own release history, read at run time.
publishedReleases :: IO [Text]
publishedReleases = do
    path <-
        lookupEnv "SINGULAR_RELEASE_HISTORY"
            >>= maybe (fail "SINGULAR_RELEASE_HISTORY names no release history") pure
    releasesIn <$> TIO.readFile path

-- | Every release the table names, wherever it names it.
listedReleases :: ContractTable -> [Text]
listedReleases table =
    concatMap snd (tableRows table)
        <> concatMap singularReleases (applicationRows table)
        <> map fst (tableLeftOut table)

-- | The release this package is, as its tag.
packageTag :: Text
packageTag = tagOf (take 3 (versionBranch version))

-- | The tag of a release from its numbers.
tagOf :: [Int] -> Text
tagOf numbers = "v" <> T.intercalate "." (map (T.pack . show) numbers)

-- | The numbers of a release tag.
tagNumbers :: Text -> [Int]
tagNumbers = map (fromMaybe 0 . readMaybe . T.unpack) . T.splitOn "." . T.drop 1

{- | The releases older than the package that the table does not name. The
release being cut is not required: the table may lag the package by it, and a
release pull request stays fresh with no row of its own.
-}
staleReleases :: Text -> [Text] -> [Text] -> [Text]
staleReleases package published listed =
    [ release
    | release <- published
    , tagNumbers release < tagNumbers package
    , release `notElem` listed
    ]

releaseRows :: Spec
releaseRows = describe "the release history" $ do
    it "is read from the headings that carry a comparison link" $
        releasesIn
            ( T.unlines
                [ "## [0.18.0](https://example.invalid/compare/v0.17.0...v0.18.0) (2026-10-29)"
                , "* a change"
                , "## [0.17.0](https://example.invalid/compare/v0.16.0...v0.17.0) (2026-10-28)"
                , "## 0.1.0 (2026-09-09)"
                ]
            )
            `shouldBe` ["v0.18.0", "v0.17.0"]
    it "is not empty and holds more than one release" $
        publishedReleases >>= (`shouldSatisfy` ((> 1) . length))
    it
        "is named by the packaged table: every release older than the package, once"
        $ do
            published <- publishedReleases
            withPackaged $ \table -> do
                let listed = listedReleases table
                staleReleases packageTag published listed `shouldBe` []
                [r | r <- listed, length (filter (== r) listed) /= 1] `shouldBe` []
    it "holds every release the packaged table names" $ do
        published <- publishedReleases
        withPackaged $ \table ->
            [r | r <- listedReleases table, r `notElem` published] `shouldBe` []
    it
        "stays fresh for a package one release above the newest the table names"
        $ do
            published <- publishedReleases
            withPackaged $ \table -> do
                let listed = listedReleases table
                    newest = maximumBy (comparing tagNumbers) listed
                    above = case tagNumbers newest of
                        major : minor : _ -> tagOf [major, minor + 1, 0]
                        _ -> newest
                above `shouldNotSatisfy` (`elem` listed)
                staleReleases above (published <> [above]) listed `shouldBe` []
    it
        "is stale for a package when any older release is missing from the table"
        $ do
            published <- publishedReleases
            withPackaged $ \table -> do
                let listed = listedReleases table
                    older = [r | r <- published, tagNumbers r < tagNumbers packageTag]
                    picked =
                        take 1 older
                            <> take 1 (drop (length older `div` 2) older)
                            <> [last older]
                length older `shouldSatisfy` (> 2)
                forM_ picked $ \missing ->
                    staleReleases packageTag published (filter (/= missing) listed)
                        `shouldBe` [missing]
    it "does not require a release newer than the package" $ do
        published <- publishedReleases
        withPackaged $ \table ->
            staleReleases
                packageTag
                (published <> ["v99.0.0"])
                (listedReleases table)
                `shouldBe` []
  where
    withPackaged use =
        loadContractTable >>= either (expectationFailure . T.unpack) use
