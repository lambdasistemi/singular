{- |
Module      : Singular.Application.KeriStub.ScriptRecordSpec
Description : The script record equals the production script constants
License     : Apache-2.0

The committed record @script-record.json@ is the one place the shell
separation check reads the stub's script from: its bytes as hex, its
hash, and the Haskell names of its script constants. Every expected
value here is observed from production at run time, never typed: the
bytes and the hash from the imported script bindings, the names from
the export list of the production @Script@ source itself. The drifted
copies below are the planted drifts: a record with one nibble flipped,
and a record with one name changed, must not equal production, so a
record that drifts from the script fails this suite.
-}
module Singular.Application.KeriStub.ScriptRecordSpec (spec) where

import Cardano.Ledger.Core (hashScript)
import Data.Aeson qualified as Aeson
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Short qualified as SBS
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.IO qualified as TIO
import Test.Hspec

import Paths_keri_stub (getDataFileName)
import Singular.Application.KeriStub.Script
    ( keriStubPolicy
    , keriStubScript
    , keriStubScriptBytes
    )
import Singular.Registry.TxBuilder.Internal (scriptHashBytes)

-- | The committed record, as the shell check reads it.
data ScriptRecord = ScriptRecord
    { recordBytesHex :: Text
    , recordHashHex :: Text
    , recordNames :: [Text]
    }

instance Aeson.FromJSON ScriptRecord where
    parseJSON = Aeson.withObject "ScriptRecord" $ \o ->
        ScriptRecord
            <$> o Aeson..: "scriptBytesHex"
            <*> o Aeson..: "scriptHashHex"
            <*> o Aeson..: "scriptConstantNames"

loadRecord :: IO ScriptRecord
loadRecord = do
    path <- getDataFileName "script-record.json"
    raw <- BS.readFile path
    case Aeson.eitherDecodeStrict raw of
        Right record -> pure record
        Left why ->
            fail ("ScriptRecordSpec: cannot parse script-record.json: " <> why)

expectedBytesHex :: Text
expectedBytesHex =
    TE.decodeUtf8 (B16.encode (SBS.fromShort keriStubScriptBytes))

expectedHashHex :: Text
expectedHashHex =
    TE.decodeUtf8 (B16.encode keriStubPolicy)

{- | The expected constant names, observed from the production source
itself: the export list of the script module, parsed generically
(parentheses, commas and comment markers only). Renaming, adding or
removing a production export changes this list, so the record must
follow it; no name is typed here.
-}
loadExpectedNames :: IO [Text]
loadExpectedNames = do
    path <-
        getDataFileName "src/Singular/Application/KeriStub/Script.hs"
    content <- TIO.readFile path
    let ls = T.lines content
        afterModule = dropWhile (not . T.isInfixOf "module ") ls
        fromParen = dropWhile (not . T.isInfixOf "(") afterModule
        exportLines = takeWhile (not . T.isInfixOf ")") fromParen
        noComments = map (fst . T.breakOn "--") exportLines
        combined = T.intercalate " " noComments
        noParen = T.filter (/= '(') combined
        chunks = T.splitOn "," noParen
    pure (filter (not . T.null) (map T.strip chunks))

-- | Flip the last character, keeping a valid shape for hex and for names.
driftLast :: Text -> Text
driftLast t = case T.unsnoc t of
    Nothing -> t
    Just (prefix, lastChar) ->
        prefix <> T.singleton (if lastChar == '0' then '1' else '0')

spec :: Spec
spec = describe "the script record" $ do
    it "matches the production script constants" $ do
        record <- loadRecord
        expectedNames <- loadExpectedNames
        recordBytesHex record `shouldBe` expectedBytesHex
        recordHashHex record `shouldBe` expectedHashHex
        recordNames record `shouldBe` expectedNames
    it "the script hash is the policy the value pins" $ do
        let fromScript =
                TE.decodeUtf8
                    (B16.encode (scriptHashBytes (hashScript keriStubScript)))
        fromScript `shouldBe` expectedHashHex
    it "refuses a drifted record: one nibble flipped is not the script" $ do
        record <- loadRecord
        let driftedBytes = driftLast (recordBytesHex record)
            driftedHash = driftLast (recordHashHex record)
        driftedBytes `shouldNotBe` expectedBytesHex
        driftedHash `shouldNotBe` expectedHashHex
        recordBytesHex record `shouldBe` expectedBytesHex
    it "refuses a drifted name: one name changed is not the script" $ do
        record <- loadRecord
        expectedNames <- loadExpectedNames
        case recordNames record of
            [] -> expectationFailure "ScriptRecordSpec: record names empty"
            (first : rest) -> do
                let drifted = driftLast first : rest
                drifted `shouldNotBe` expectedNames
                recordNames record `shouldBe` expectedNames
