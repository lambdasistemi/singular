module Singular.Registry.MirrorSpec (spec) where

import Data.Bits ((.&.))
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BL
import Data.ByteString.Short qualified as SBS
import Data.Map.Strict qualified as Map
import MPF.Backend.Pure (emptyMPFInMemoryDB)
import Paths_singular_registry (getDataFileName)
import Singular.Registry.Deployment (loadMirror, loadReplayCheckpoint, mirrorPathFor, saveMirror)
import Singular.Registry.Ledger (AssetName (..), TokenId (..))
import Singular.Registry.Trie.Pure (getRootFromDb)
import System.Directory (copyFile)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Files (fileMode, getFileStatus, setFileMode)
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)

spec :: Spec
spec = describe "proof mirror compatibility" $ do
    it "loads the pre-checkpoint format with the key absent" $
        withSystemTempDirectory "legacy-mirror" $ \dir -> do
            fixture <- getDataFileName "test/fixtures/mirror-before-checkpoints.json"
            let manifest = dir </> "deployment.json"
            bytes <- BL.readFile fixture
            -- An absent key is materially different from a null field.
            bytes `shouldSatisfy` (not . BS.isInfixOf "mirrorCheckpoint" . BL.toStrict)
            copyFile fixture (mirrorPathFor manifest)
            mirrors <- loadMirror manifest
            let expectedToken = TokenId (AssetName (SBS.toShort (BS.replicate 32 0)))
            Map.keys mirrors `shouldBe` [expectedToken]
            expectedRoot <- getRootFromDb emptyMPFInMemoryDB
            getRootFromDb (mirrors Map.! expectedToken) >>= (`shouldBe` expectedRoot)
            loadReplayCheckpoint manifest >>= (`shouldBe` Nothing)
    it "creates and replaces mirrors with deliberate owner-only mode 0600" $
        withSystemTempDirectory "mirror-mode" $ \dir -> do
            let manifest = dir </> "deployment.json"
                mode = (.&. 0o7777) . fileMode <$> getFileStatus (mirrorPathFor manifest)
            saveMirror manifest Map.empty
            mode >>= (`shouldBe` 0o600)
            setFileMode (mirrorPathFor manifest) 0o644
            saveMirror manifest Map.empty
            mode >>= (`shouldBe` 0o600)
