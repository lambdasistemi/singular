-- | A committed live receipt in an independently owned temporary directory.
module Conformance.Fixture.Receipt (
    fixtureReceipt,
    loadOne,
    withScopedReceiptDir,
) where

import Conformance.Receipt (loadReceipts)
import Data.ByteString.Lazy qualified as BSL
import Paths_conformance (getDataFileName)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)

fixtureReceipt :: IO BSL.ByteString
fixtureReceipt = do
    path <- getDataFileName "test/fixtures/receipts/receipt-CG02.json"
    BSL.readFile path

withScopedReceiptDir :: (FilePath -> IO a) -> IO a
withScopedReceiptDir = withSystemTempDirectory "conformance-receipt-spec"

loadOne :: IO (Either String Int)
loadOne = withScopedReceiptDir $ \dir -> do
    receipt <- fixtureReceipt
    BSL.writeFile (dir </> "receipt-CG02.json") receipt
    fmap length <$> loadReceipts dir
