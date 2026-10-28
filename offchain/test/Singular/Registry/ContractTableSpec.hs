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
* the packaged table holds the state-contract hash of the blueprint being
  built, and the same check, run on the table with that row removed, fails.
-}
module Singular.Registry.ContractTableSpec (spec) where

import Data.Aeson qualified as Aeson
import Control.Exception (bracket_)
import Data.ByteString (ByteString)
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as BL
import Data.Either (fromRight, isLeft)
import Data.List (nub)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Text qualified as T
import Test.Hspec
import System.Environment (lookupEnv, setEnv, unsetEnv)
import System.IO.Temp (withSystemTempDirectory)

import Singular.CLI.Permanent (knownScripts)
import Singular.Registry.ContractTable
    ( ContractTable
    , ApplicationIdentity (..)
    , applicationOf
    , applicationRows
    , Contracts (..)
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

applicationLookupRows :: Spec
applicationLookupRows = describe "an applied state policy" $ do
    it "names exactly its application, script and the releases of each" $ do
        let rows =
                [ ApplicationIdentity (hashOf 'a') (hashOf 'b') (hashOf 'c') ["v0.17.0"] ["v0.17.0"]
                , ApplicationIdentity (hashOf 'd') (hashOf 'e') (hashOf 'f') [] []
                ]
            bytes = BL.toStrict (Aeson.encode (Aeson.object ["rows" Aeson..= ([] :: [Aeson.Value]), "applications" Aeson..= rows]))
        table <- either (fail . T.unpack) pure (parseContractTable bytes)
        applicationRows table `shouldBe` rows
        map (applicationOf table . appliedStatePolicy) rows `shouldBe` map Just rows
        applicationOf table (hashOf '0') `shouldBe` Nothing
    it "refuses an invalid hash and releases out of order" $ do
        let row = ApplicationIdentity (hashOf 'a') (hashOf 'b') (hashOf 'c') [] []
            parse rows = parseContractTable (BL.toStrict (Aeson.encode (Aeson.object ["rows" Aeson..= ([] :: [Aeson.Value]), "applications" Aeson..= rows])))
        parse [row{applicationPolicy = "short"}] `shouldSatisfy` isLeft
        parse [row{singularReleases = ["v0.17.0", "v0.16.0"]}] `shouldSatisfy` isLeft
        parse [row{applicationReleases = ["not-a-release"]}] `shouldSatisfy` isLeft

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
        let row = Aeson.object
                [ "state-policy" Aeson..= T.replicate 56 "a"
                , "application-policy" Aeson..= T.replicate 56 "b"
                , "application-script" Aeson..= T.replicate 56 "c"
                , "singular-releases" Aeson..= ([] :: [Text])
                , "application-releases" Aeson..= ([] :: [Text])
                ]
        parseContractTable (BL.toStrict (Aeson.encode (Aeson.object ["rows" Aeson..= ([] :: [Aeson.Value]), "applications" Aeson..= [row, row]])))
            `shouldSatisfy` isLeft
    it "is available when no external package data file is installed" $
        withSystemTempDirectory "table-without-data" $ \directory -> do
            previous <- lookupEnv "singular_registry_datadir"
            bracket_
                (setEnv "singular_registry_datadir" directory)
                (maybe (unsetEnv "singular_registry_datadir") (setEnv "singular_registry_datadir") previous)
                (loadContractTable >>= either (expectationFailure . T.unpack) (\table -> tableRows table `shouldSatisfy` (not . null)))
    it "is found from the package's own data and read" $
        loadContractTable >>= \case
            Left why -> expectationFailure (T.unpack why)
            Right table -> tableRows table `shouldSatisfy` (not . null)
    it "holds the state-contract hash of the blueprint being built" $
        withPackaged $ \table ->
            holdsPinned table `shouldBe` True
    it
        "fails the same check when the row of that hash is removed, the control"
        $ withPackaged
        $ \table ->
            case parseContractTable
                ( tableTextHex
                    [ (hexOf hash, tags)
                    | (hash, tags) <- tableRows table
                    , hash /= pinnedHash
                    ]
                ) of
                Left why -> expectationFailure (T.unpack why)
                Right without -> holdsPinned without `shouldBe` False
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
    hexOf = T.pack . BC.unpack . B16.encode
    holdsPinned table =
        contractsOf table pinnedHash /= NoKnownRelease

-- | The state-contract hash the programs pin: the one the blueprint being built has.
pinnedHex :: Text
pinnedHex = case lookup "state.state" knownScripts of
    Just hex -> hex
    Nothing -> error "ContractTableSpec: the programs pin no state contract"

pinnedHash :: ByteString
pinnedHash =
    fromRight mempty (B16.decode (BC.pack (T.unpack pinnedHex)))
