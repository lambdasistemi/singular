-- | These checks concern the evidence reader, not product conformance.
module Main (main) where

import Conformance.Support.EvidencePage qualified as EvidencePage
import Conformance.Support.Receipt qualified as Receipt
import Conformance.Support.Replay qualified as Replay
import Conformance.Support.Rows qualified as Rows
import Test.Hspec (describe, hspec)
import Test.Tags (Area (..), tagged)

main :: IO ()
main = hspec $ describe "Appendix — how we check the evidence" $ do
    describe (tagged "Conformance.Support.Rows" [Conformance]) Rows.spec
    describe
        (tagged "Conformance.Support.Receipt" [Conformance])
        Receipt.spec
    describe
        (tagged "Conformance.Support.Replay" [Conformance])
        Replay.spec
    describe
        (tagged "Conformance.Support.EvidencePage" [Conformance])
        EvidencePage.spec
