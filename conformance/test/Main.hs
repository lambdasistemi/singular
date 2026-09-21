-- | Read the promises first; machinery checks are the appendix.
module Main (main) where

import Test.Hspec (Spec, describe, hspec)
import System.Environment (getArgs, withArgs)
import Conformance.Story.Book (renderBook)
import Conformance.Edge.Register qualified as InsertActive
import Conformance.Fold.KeyedMint qualified as KeyedMint
import Conformance.Story.BindingControl qualified as BindingControl
import Conformance.Story.Control qualified as Control
import Conformance.Story.Usage qualified as Usage
import Conformance.Support.Observation qualified as Observation
import Conformance.Support.Receipt qualified as Receipt
import Conformance.Support.Refusal qualified as Refusal
import Conformance.Support.Rows qualified as Rows

main :: IO ()
main = do
    args <- getArgs
    case args of
        ["--book", path] -> withArgs [] $ do
            hspec suite
            renderBook >>= writeFile path
        _ -> hspec suite

suite :: Spec
suite = do
    describe "Registry promises — receipt evidence" $ do
        InsertActive.spec
        KeyedMint.spec
    describe "Appendix — evidence machinery" $ do
        Observation.spec
        Receipt.spec
        Refusal.spec
        Rows.spec
        Control.spec
        BindingControl.spec
        Usage.spec
