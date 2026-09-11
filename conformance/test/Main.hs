{- |
Module      : Main
Description : Conformance unit test runner
License     : Apache-2.0
-}
module Main (main) where

import Test.Hspec (hspec)

import Conformance.ReceiptSpec qualified as ReceiptSpec
import Conformance.RefusalSpec qualified as RefusalSpec
import Conformance.RowsSpec qualified as RowsSpec

main :: IO ()
main = hspec $ do
    ReceiptSpec.spec
    RefusalSpec.spec
    RowsSpec.spec
