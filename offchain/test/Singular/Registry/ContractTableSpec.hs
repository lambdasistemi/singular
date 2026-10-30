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
* the serving answer is one function of the table, the installed release pair and
  the registry, and the lines every command prints are one function of that
  answer: they name the releases that serve the registry and the page of the
  newest, or say that none is known;
* every release in the project's release history is named once;
* a table that lists a hash twice, a release out of order or a hash that is not
  28 bytes is refused as a file;
* the compatibility record, from which the published page is rendered, says for
  every release of the packaged table what the serving answer says of the
  contract that release carries, and the contract it reads as this release's is
  the one the library derives from the packaged state program.
-}
module Singular.Registry.ContractTableSpec (spec) where

import Cardano.Crypto.Hash (hashFromBytes)
import Cardano.Ledger.Core (hashScript)
import Cardano.Ledger.Hashes (ScriptHash (..))
import Cardano.Ledger.Mary.Value (PolicyID (..))
import Control.Exception (bracket_)
import Control.Monad (forM_)
import Data.Aeson qualified as Aeson
import Data.Aeson.Types qualified as AesonTypes
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as BL
import Data.Either (fromRight, isLeft)
import Data.List (maximumBy, nub)
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, isNothing)
import Data.Ord (comparing)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.IO qualified as TIO
import Data.Version (versionBranch)
import System.Environment (lookupEnv, setEnv, unsetEnv)
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec
import Test.QuickCheck
    ( Gen
    , counterexample
    , elements
    , forAll
    , sublistOf
    )
import Text.Read (readMaybe)

import Paths_singular_registry (version)

import Singular.Registry.Blueprint (loadBlueprint)
import Singular.Registry.ContractTable
    ( ApplicationIdentity (..)
    , ContractTable
    , Contracts (..)
    , Installed (..)
    , Serving (..)
    , applicationOf
    , applicationRows
    , contractsOf
    , loadContractTable
    , parseContractTable
    , releaseUrl
    , servingLines
    , servingOf
    , tableLeftOut
    , tableRows
    )
import Singular.Registry.TxBuilder.Internal (scriptHashBytes)
import Singular.State.Script (stateScriptFromBlueprint)

spec :: Spec
spec = describe "the table of releases" $ do
    applicationLookupRows
    lookupRows
    fileRows
    packagedRows
    releaseRows
    servingRows
    guidanceRows
    compatibilityRows

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

-- ---------------------------------------------------------
-- Which release serves a registry
-- ---------------------------------------------------------

-- | A table from legacy rows and applied rows, in the packaged file's shape.
parseTable
    :: [(Char, [Text])]
    -> [(Char, [Text], [Text])]
    -> Either Text ContractTable
parseTable legacy applied =
    parseContractTable
        ( BL.toStrict . Aeson.encode $
            Aeson.object
                [
                    ( "rows"
                    , Aeson.toJSON
                        [ Aeson.object
                            [ ("state-contract", Aeson.toJSON (T.replicate 56 (T.singleton c)))
                            , ("releases", Aeson.toJSON tags)
                            ]
                        | (c, tags) <- legacy
                        ]
                    )
                ,
                    ( "applications"
                    , Aeson.toJSON
                        [ Aeson.object
                            [ ("state-policy", Aeson.toJSON (T.replicate 56 (T.singleton c)))
                            , ("application-policy", Aeson.toJSON (T.replicate 56 "0"))
                            , ("application-script", Aeson.toJSON (T.replicate 56 "0"))
                            , ("singular-releases", Aeson.toJSON singular)
                            , ("application-releases", Aeson.toJSON application)
                            ]
                        | (c, singular, application) <- applied
                        ]
                    )
                ]
        )

tableFrom
    :: [(Char, [Text])] -> [(Char, [Text], [Text])] -> IO ContractTable
tableFrom legacy applied =
    either
        (\why -> fail ("the table: " <> T.unpack why))
        pure
        (parseTable legacy applied)

-- | What a table holds under a hash.
data Held
    = HeldLegacy [Text]
    | HeldApplied [Text] [Text]
    deriving stock (Eq, Show)

tableHolds :: ContractTable -> ByteString -> Maybe Held
tableHolds table hash =
    case applicationOf table hash of
        Just identity ->
            Just
                (HeldApplied (singularReleases identity) (applicationReleases identity))
        Nothing -> HeldLegacy <$> lookup hash (tableRows table)

-- | The commands of release v0.5.0 that derive and serve these policies.
serving :: [Char] -> Installed
serving derived = Installed "v0.5.0" (map hashOf derived)

servingRows :: Spec
servingRows = describe "the serving answer" $ do
    it
        "names the releases of every earlier contract of the packaged table"
        $ withPackaged
        $ \table -> do
            let released = [(h, rs) | (h, rs) <- tableRows table, not (null rs)]
            length released `shouldSatisfy` (> 1)
            forM_ released $ \(hash, tags) -> do
                servingOf table (Installed packageTag []) hash
                    `shouldBe` ServedByEarlier (NE.fromList tags)
                servingOf
                    table
                    (Installed packageTag (map appliedStatePolicy (applicationRows table)))
                    hash
                    `shouldBe` ServedByEarlier (NE.fromList tags)
    it
        "serves every applied state policy the table holds when the commands recognise it"
        $ withPackaged
        $ \table -> do
            let recognised = map appliedStatePolicy (applicationRows table)
            recognised `shouldSatisfy` (not . null)
            forM_ recognised $ \policy ->
                servingOf table (Installed packageTag recognised) policy
                    `shouldBe` ServedHere
    it "knows no release for a hash that no row holds" $
        withPackaged $ \table ->
            case [ h
                 | c <- "0123456789abcdef"
                 , let h = hashOf c
                 , isNothing (tableHolds table h)
                 ] of
                absent : _ ->
                    servingOf table (Installed packageTag []) absent
                        `shouldBe` UnknownContract
                [] -> expectationFailure "every probe hash is held by a row"
    it
        "serves the commands' own contracts although the table does not list their release"
        $ do
            table <-
                tableFrom
                    [('a', ["v0.1.0", "v0.2.0"])]
                    [ ('e', ["v0.3.0", "v0.4.0"], ["v0.3.0", "v0.4.0"])
                    , ('f', ["v0.4.0", "v0.5.0"], ["v0.3.0"])
                    , ('0', ["v0.3.0"], ["v0.3.0"])
                    , ('1', [], [])
                    ]
            servingOf table (serving "e") (hashOf 'e') `shouldBe` ServedHere
            servingOf table (serving "") (hashOf 'e')
                `shouldBe` ServedByEarlier ("v0.3.0" :| ["v0.4.0"])
            servingOf table (serving "e") (hashOf 'f')
                `shouldBe` ServedByApplication ("v0.3.0" :| [])
            servingOf table (serving "e") (hashOf '0')
                `shouldBe` ServedByEarlier ("v0.3.0" :| [])
            servingOf table (serving "e") (hashOf 'a')
                `shouldBe` ServedByEarlier ("v0.1.0" :| ["v0.2.0"])
            servingOf table (serving "e") (hashOf '1')
                `shouldBe` UnreleasedContract
            servingOf table (serving "e") (hashOf 'b') `shouldBe` UnknownContract
    it
        "names, for every table and observation, one case from the table alone"
        $ forAll genObservation
        $ \(legacy, applied, installed, hash) -> do
            let table = either (error . T.unpack) id (parseTable legacy applied)
                held = tableHolds table hash
                derived = hash `elem` installedServes installed
                answer = servingOf table installed hash
                counter = counterexample (show (answer, held, installed))
            counter $ case answer of
                ServedHere -> derived
                ServedByEarlier tags ->
                    not derived && case held of
                        Just (HeldLegacy singular) -> NE.toList tags == singular
                        Just (HeldApplied singular application) ->
                            NE.toList tags == singular
                                && not
                                    ( installedSingular installed `elem` singular
                                        && not (null application)
                                    )
                        Nothing -> False
                ServedByApplication tags ->
                    not derived && case held of
                        Just (HeldApplied singular application) ->
                            NE.toList tags == application
                                && installedSingular installed `elem` singular
                        _ -> False
                UnknownContract -> not derived && isNothing held
                UnreleasedContract ->
                    not derived && case held of
                        Just (HeldLegacy singular) -> null singular
                        Just (HeldApplied singular _) -> null singular
                        Nothing -> False
                TableUnusable _ -> False
  where
    withPackaged use =
        loadContractTable >>= either (expectationFailure . T.unpack) use

-- | Release tags oldest first, the pool every generated row draws from.
tagPool :: [Text]
tagPool = ["v0.1.0", "v0.2.0", "v0.3.0", "v0.10.0", "v0.11.0"]

-- | A table, the installed commands and a hash that is in the table or is not.
genObservation
    :: Gen
        ( [(Char, [Text])]
        , [(Char, [Text], [Text])]
        , Installed
        , ByteString
        )
genObservation = do
    legacyChars <- sublistOf "abcd"
    appliedChars <- sublistOf "ef01"
    legacy <- mapM (\c -> (,) c <$> sublistOf tagPool) legacyChars
    applied <-
        mapM
            (\c -> (,,) c <$> sublistOf tagPool <*> sublistOf tagPool)
            appliedChars
    singular <- elements (tagPool <> ["v0.99.0"])
    derived <- sublistOf "abcdef01"
    observed <- elements "abcdef012"
    pure
        ( legacy
        , applied
        , Installed singular (map hashOf derived)
        , hashOf observed
        )

guidanceRows :: Spec
guidanceRows = describe "the guidance a serving answer is worded as" $ do
    let earlier = ServedByEarlier ("v0.4.1" :| ["v0.5.0", "v0.6.0", "v0.6.1"])
        said = T.unlines (servingLines earlier)
    it "says nothing when the installed release serves the registry" $
        servingLines ServedHere `shouldBe` []
    it
        "names every release that serves it and the page of the newest only"
        $ do
            forM_ ["v0.4.1", "v0.5.0", "v0.6.0", "v0.6.1"] $ \tag ->
                said `shouldSatisfy` T.isInfixOf tag
            said `shouldSatisfy` T.isInfixOf (releaseUrl "v0.6.1")
            forM_ ["v0.4.1", "v0.5.0", "v0.6.0"] $ \tag ->
                said `shouldNotSatisfy` T.isInfixOf (releaseUrl tag)
    it "names one release in the singular" $
        T.unlines (servingLines (ServedByEarlier ("v0.7.0" :| [])))
            `shouldSatisfy` T.isInfixOf "the release v0.7.0"
    it "names the application releases that serve it" $ do
        let lines' =
                T.unlines
                    (servingLines (ServedByApplication ("v0.3.0" :| ["v0.4.0"])))
        forM_ ["v0.3.0", "v0.4.0"] $ \tag ->
            lines' `shouldSatisfy` T.isInfixOf tag
    it
        "says no release is known, and names none, for contracts no release carries"
        $ do
            let unknown = T.unlines (servingLines UnknownContract)
            unknown `shouldSatisfy` T.isInfixOf "no release"
            unknown `shouldNotSatisfy` T.isInfixOf "releases/tag"
    it
        "says the contracts are not released yet when the row lists no release"
        $ do
            let unreleased = T.unlines (servingLines UnreleasedContract)
            unreleased `shouldSatisfy` T.isInfixOf "not released yet"
            unreleased `shouldNotSatisfy` T.isInfixOf "releases/tag"
    it "says why the table cannot be used" $
        T.unlines (servingLines (TableUnusable "no such file"))
            `shouldSatisfy` T.isInfixOf "no such file"
    it "words each case differently" $ do
        let answers =
                [ earlier
                , ServedByApplication ("v0.3.0" :| [])
                , UnknownContract
                , UnreleasedContract
                , TableUnusable "why"
                ]
        map servingLines answers
            `shouldBe` nub (map servingLines answers)

-- ---------------------------------------------------------
-- The compatibility record agrees with the library
-- ---------------------------------------------------------

{- | What the compatibility record says of who serves the registries made by a
contract: the three kinds the page has, and the library's other answers, which
the page never says.
-}
data Said
    = SaidThisRelease
    | SaidEarlier Text
    | SaidNone
    | SaidOther Text
    deriving stock (Eq, Show)

-- | One row of the record: what it names, the contract it holds and who serves it.
data RecordRow = RecordRow
    { rowName :: Text
    , rowContract :: Maybe ByteString
    , rowSaid :: Said
    , rowWhy :: Maybe Text
    }
    deriving stock (Eq, Show)

-- | An application row of the record, beside the table's.
data ApplicationRecord = ApplicationRecord
    { applicationRow :: RecordRow
    , recordApplicationOf :: ByteString
    , recordSingular :: [Text]
    , recordApplicationReleases :: [Text]
    }
    deriving stock (Eq, Show)

-- | The record the page is rendered from.
data Record = Record
    { recordOwn :: Maybe ByteString
    , recordPolicy :: ByteString
    , recordReleases :: [RecordRow]
    , recordWithoutRelease :: [RecordRow]
    , recordApplications :: [ApplicationRecord]
    }
    deriving stock (Eq, Show)

hexBytes :: Text -> AesonTypes.Parser ByteString
hexBytes hex =
    either
        (const (fail ("not hex: " <> T.unpack hex)))
        pure
        (B16.decode (TE.encodeUtf8 hex))

hexText :: ByteString -> Text
hexText = TE.decodeUtf8 . B16.encode

parseSaid :: Aeson.Object -> AesonTypes.Parser (Said, Maybe Text)
parseSaid o = do
    served <- o Aeson..: "served-by"
    kind <- served Aeson..: "kind" :: AesonTypes.Parser Text
    case kind of
        "this-release" -> pure (SaidThisRelease, Nothing)
        "earlier-release" -> do
            release <- served Aeson..: "release"
            pure (SaidEarlier release, Nothing)
        "no-release" -> do
            why <- served Aeson..: "why"
            pure (SaidNone, Just why)
        other -> fail ("the record says an unknown kind: " <> T.unpack other)

parseRow
    :: Aeson.Key -> Aeson.Key -> Aeson.Object -> AesonTypes.Parser RecordRow
parseRow nameKey contractKey o = do
    name <- o Aeson..: nameKey
    contract <- o Aeson..:? contractKey >>= traverse hexBytes
    (said, why) <- parseSaid o
    pure (RecordRow name contract said why)

instance Aeson.FromJSON Record where
    parseJSON = Aeson.withObject "the compatibility record" $ \o -> do
        own <- o Aeson..: "this-release-contract" >>= traverse hexBytes
        policy <- o Aeson..: "packaged-application-policy" >>= hexBytes
        releases <-
            o Aeson..: "releases"
                >>= traverse (parseRow "release" "state-contract")
        without <-
            o Aeson..: "contracts-without-release"
                >>= traverse (parseRow "state-contract" "state-contract")
        applications <-
            o Aeson..: "applications" >>= traverse parseApplication
        pure (Record own policy releases without applications)
      where
        parseApplication = Aeson.withObject "an application row" $ \a -> do
            row <- parseRow "state-policy" "state-policy" a
            application <- a Aeson..: "application-policy" >>= hexBytes
            singular <- a Aeson..: "singular-releases"
            released <- a Aeson..: "application-releases"
            pure (ApplicationRecord row application singular released)

{- | The committed compatibility record, read from the file named in
@SINGULAR_COMPATIBILITY_ROWS@. A missing variable fails the case: a run that
cannot reach the record compares nothing.
-}
loadRecord :: IO Record
loadRecord = do
    path <-
        lookupEnv "SINGULAR_COMPATIBILITY_ROWS"
            >>= maybe
                (fail "SINGULAR_COMPATIBILITY_ROWS names no compatibility record")
                pure
    bytes <- BS.readFile path
    either
        (fail . ("the compatibility record: " <>))
        pure
        (Aeson.eitherDecodeStrict' bytes)

-- | What the record would say of a serving answer; the page has no other kinds.
saysOf :: Serving -> Said
saysOf = \case
    ServedHere -> SaidThisRelease
    ServedByEarlier tags -> SaidEarlier (NE.last tags)
    UnknownContract -> SaidNone
    UnreleasedContract -> SaidNone
    ServedByApplication tags ->
        SaidOther
            ("served by the application releases " <> T.unwords (NE.toList tags))
    TableUnusable why -> SaidOther why

{- | Every way the record differs from the library's serving answer for the
commands of this record: the installed release, its own contract, and the table.
An empty list is agreement.
-}
disagreements :: Text -> ContractTable -> Record -> [Text]
disagreements tag table record =
    releaseProblems <> withoutProblems <> applicationProblems
  where
    answer = libraryAnswer tag table record
    carried :: Map Text (Maybe ByteString)
    carried =
        Map.fromList $
            [(r, Just h) | (h, rs) <- tableRows table, r <- rs]
                <> [ (r, Just (appliedStatePolicy a))
                   | a <- applicationRows table
                   , r <- singularReleases a
                   ]
                <> [(r, Nothing) | (r, _) <- tableLeftOut table]
    only what names other = [what <> " " <> n | n <- names, n `notElem` other]
    releaseProblems =
        only
            "the table names the release"
            (Map.keys carried)
            (map rowName (recordReleases record))
            <> only
                "the record names the release"
                (map rowName (recordReleases record))
                (Map.keys carried)
            <> concat
                [ rowProblems row contract
                | row <- recordReleases record
                , Just contract <- [Map.lookup (rowName row) carried]
                ]
    rowProblems row contract =
        [ "the contract of the release " <> rowName row <> " differs"
        | rowContract row /= contract
        ]
            <> case contract of
                Just hash ->
                    [ "the record says "
                        <> T.pack (show (rowSaid row))
                        <> " of the release "
                        <> rowName row
                        <> " and the library says "
                        <> T.pack (show (answer hash))
                    | rowSaid row /= answer hash
                    ]
                Nothing ->
                    [ "the record does not say that no release is known for the release "
                        <> rowName row
                        <> " the table leaves out"
                    | rowSaid row /= SaidNone
                        || rowWhy row /= lookup (rowName row) (tableLeftOut table)
                    ]
    unreleased = [h | (h, []) <- tableRows table]
    withoutProblems =
        only
            "the table holds the contract without a release"
            (map hexText unreleased)
            (map rowName (recordWithoutRelease record))
            <> only
                "the record holds the contract without a release"
                (map rowName (recordWithoutRelease record))
                (map hexText unreleased)
            <> [ "the record says "
                    <> T.pack (show (rowSaid row))
                    <> " of the contract "
                    <> rowName row
                    <> " and the library says "
                    <> T.pack (show (answer hash))
               | row <- recordWithoutRelease record
               , hash <- unreleased
               , hexText hash == rowName row
               , rowSaid row /= answer hash
               ]
    applicationProblems =
        only
            "the table holds the application"
            (map (hexText . appliedStatePolicy) (applicationRows table))
            (map (rowName . applicationRow) (recordApplications record))
            <> only
                "the record holds the application"
                (map (rowName . applicationRow) (recordApplications record))
                (map (hexText . appliedStatePolicy) (applicationRows table))
            <> concat
                [ [ "the record says "
                        <> T.pack (show (rowSaid (applicationRow row)))
                        <> " of the application "
                        <> rowName (applicationRow row)
                        <> " and the library says "
                        <> T.pack (show (answer (appliedStatePolicy identity)))
                  | rowSaid (applicationRow row) /= answer (appliedStatePolicy identity)
                  ]
                    <> [ "the releases of the application "
                            <> rowName (applicationRow row)
                            <> " differ"
                       | recordSingular row /= singularReleases identity
                            || recordApplicationReleases row /= applicationReleases identity
                            || recordApplicationOf row /= applicationPolicy identity
                       ]
                | row <- recordApplications record
                , identity <- applicationRows table
                , hexText (appliedStatePolicy identity) == rowName (applicationRow row)
                ]

-- | What the library says of a contract, for the commands of this record.
libraryAnswer :: Text -> ContractTable -> Record -> ByteString -> Said
libraryAnswer tag table record =
    saysOf
        . servingOf
            table
            (Installed tag (maybe [] pure (recordOwn record)))

-- | One line of evidence for a release: the record's answer beside the library's.
evidenceLine :: ContractTable -> Record -> RecordRow -> String
evidenceLine table record row =
    T.unpack (rowName row)
        <> "  "
        <> maybe "-" (T.unpack . T.take 8 . hexText) (rowContract row)
        <> "  record: "
        <> show (rowSaid row)
        <> "  library: "
        <> maybe
            "no contract to ask for"
            (show . libraryAnswer packageTag table record)
            (rowContract row)

-- | The table with one release removed from wherever it names it.
withoutRelease :: Text -> ContractTable -> Either Text ContractTable
withoutRelease release table =
    parseContractTable . BL.toStrict . Aeson.encode $
        Aeson.object
            [ "rows"
                Aeson..= [ Aeson.object
                            [ "state-contract" Aeson..= hexText hash
                            , "releases" Aeson..= filter (/= release) tags
                            ]
                         | (hash, tags) <- tableRows table
                         ]
            , "applications"
                Aeson..= [ a{singularReleases = filter (/= release) (singularReleases a)}
                         | a <- applicationRows table
                         ]
            , "left-out"
                Aeson..= [ Aeson.object ["release" Aeson..= r, "reason" Aeson..= why]
                         | (r, why) <- tableLeftOut table
                         , r /= release
                         ]
            ]

-- | The state policy the library derives from the packaged state program for an application.
derivedStatePolicy :: ByteString -> IO ByteString
derivedStatePolicy application = do
    path <-
        lookupEnv "SINGULAR_STATE_BLUEPRINT"
            >>= maybe (fail "SINGULAR_STATE_BLUEPRINT names no state blueprint") pure
    blueprint <-
        loadBlueprint path >>= either (fail . ("blueprint: " <>)) pure
    hash <-
        maybe
            (fail "the application policy is not 28 bytes")
            (pure . ScriptHash)
            (hashFromBytes application)
    script <-
        either (fail . ("state script: " <>)) pure $
            stateScriptFromBlueprint blueprint (PolicyID hash)
    pure (scriptHashBytes (hashScript script))

compatibilityRows :: Spec
compatibilityRows = describe "the compatibility record" $ do
    it
        "agrees with the serving answer of the library for every release of the packaged table"
        $ withRecord
        $ \table record -> do
            length (recordReleases record) `shouldSatisfy` (> 1)
            recordOwn record `shouldSatisfy` (/= Nothing)
            putStrLn
                ( "the installed commands are the release "
                    <> T.unpack packageTag
                )
            forM_ (recordReleases record) $
                putStrLn . evidenceLine table record
            disagreements packageTag table record `shouldBe` []
    it "says the same whichever release the installed commands are" $
        withRecord $ \table record -> do
            let listed = listedReleases table
                newest = maximumBy (comparing tagNumbers) listed
                above = case tagNumbers newest of
                    major : minor : _ -> [tagOf [major, minor + 1, 0], tagOf [major + 1, 0, 0]]
                    _ -> []
            forM_ (packageTag : "v99.0.0" : above <> listed) $ \tag ->
                disagreements tag table record `shouldBe` []
    it
        "reads as this release the contract the library derives from the packaged state program"
        $ withRecord
        $ \table record -> do
            own <-
                maybe
                    ( expectationFailure "the record reads no release as this one"
                        >> pure mempty
                    )
                    pure
                    (recordOwn record)
            identity <-
                maybe
                    ( expectationFailure "the table holds no application row for it"
                        >> fail "no row"
                    )
                    pure
                    (applicationOf table own)
            applicationPolicy identity `shouldBe` recordPolicy record
            derivedStatePolicy (applicationPolicy identity) >>= (`shouldBe` own)
    it
        "does not read as this release the contract derived for another application"
        $ withRecord
        $ \_ record -> do
            let other = BS.map (+ 1) (recordPolicy record)
            derived <- derivedStatePolicy other
            Just derived `shouldNotBe` recordOwn record
    it
        "is caught when a row says another thing than the library, for each release"
        $ withRecord
        $ \table record ->
            forM_ (zip [0 ..] (recordReleases record)) $ \(index, row) -> do
                let said = case rowSaid row of
                        SaidNone -> SaidThisRelease
                        SaidThisRelease -> SaidNone
                        SaidEarlier _ -> SaidThisRelease
                        SaidOther _ -> SaidNone
                    edited =
                        record
                            { recordReleases =
                                replaceAt index row{rowSaid = said} (recordReleases record)
                            }
                    problems = disagreements packageTag table edited
                problems `shouldSatisfy` any (T.isInfixOf (rowName row))
    it "is caught when a row names another release serving it" $
        withRecord $ \table record ->
            forM_ (zip [0 ..] (recordReleases record)) $ \(index, row) ->
                case rowSaid row of
                    SaidEarlier _ -> do
                        let edited =
                                record
                                    { recordReleases =
                                        replaceAt
                                            index
                                            row{rowSaid = SaidEarlier "v0.0.1"}
                                            (recordReleases record)
                                    }
                        disagreements packageTag table edited
                            `shouldSatisfy` any (T.isInfixOf (rowName row))
                    _ -> pure ()
    it
        "is caught when a release is removed from the table, for each release"
        $ withRecord
        $ \table record ->
            forM_ (listedReleases table) $ \release -> do
                reduced <-
                    either (fail . T.unpack) pure (withoutRelease release table)
                disagreements packageTag reduced record
                    `shouldSatisfy` any (T.isInfixOf release)
    it "is caught when a release is missing from the record" $
        withRecord $ \table record ->
            forM_ (zip [0 ..] (recordReleases record)) $ \(index, row) ->
                disagreements
                    packageTag
                    table
                    record{recordReleases = dropAt index (recordReleases record)}
                    `shouldSatisfy` any (T.isInfixOf (rowName row))
    it "is caught when the record reads no release as this one" $
        withRecord $ \table record ->
            disagreements packageTag table record{recordOwn = Nothing}
                `shouldSatisfy` (not . null)
  where
    withRecord use = do
        record <- loadRecord
        loadContractTable
            >>= either (expectationFailure . T.unpack) (`use` record)
    replaceAt index new rows = take index rows <> [new] <> drop (index + 1) rows
    dropAt index rows = take index rows <> drop (index + 1) rows
