{- |
Module      : Singular.CLI.VersionSpec
Description : A command states the release and commit it was built from
License     : Apache-2.0

Every packaged command states its release number and the commit stamped into
the executable. The release number is the package version with the fourth
component dropped. A stamped commit is the one the identity line reads, and
a person's environment cannot replace it. An executable nobody stamped says
its commit is unknown, or the one the environment names, instead of
inventing one.
-}
module Singular.CLI.VersionSpec (spec) where

import Data.List (isPrefixOf)
import Data.Version (makeVersion, showVersion)
import Test.Hspec

import Singular.CLI.Options (releaseCommitVariable)
import Singular.CLI.Version
    ( commitFromSlot
    , commitSlot
    , releaseVersion
    , stampedEnvironment
    )

stamped :: String -> String
stamped commit =
    "SINGULAR-COMMIT-SLOT-V1:"
        <> commit
        <> replicate (64 - length commit) '#'

spec :: Spec
spec = do
    describe "releaseVersion" $ do
        it "is the release version of a four-component package version" $
            showVersion (releaseVersion (makeVersion [0, 12, 0, 0]))
                `shouldBe` "0.12.0"
        it "keeps a three-component version whole" $
            showVersion (releaseVersion (makeVersion [1, 2, 3]))
                `shouldBe` "1.2.3"
        it "does not invent components" $
            showVersion (releaseVersion (makeVersion [2, 1]))
                `shouldBe` "2.1"
    describe "commitFromSlot" $ do
        it "reads the stamped commit and drops the padding" $
            commitFromSlot
                (stamped "60f59f97b0c1d2e3f4a5b6c7d8e9f00112233445")
                `shouldBe` "60f59f97b0c1d2e3f4a5b6c7d8e9f00112233445"
        it "reads a dirty commit whole" $
            commitFromSlot
                ( stamped
                    "60f59f97b0c1d2e3f4a5b6c7d8e9f00112233445-dirty"
                )
                `shouldBe` "60f59f97b0c1d2e3f4a5b6c7d8e9f00112233445-dirty"
        it "reads the unstamped slot as unknown" $
            commitFromSlot commitSlot `shouldBe` "unknown"
        it "never reads an empty commit" $
            commitFromSlot (stamped "") `shouldBe` "unknown"
    describe "the slot" $
        it "has the fixed width the Nix stamping overwrites" $ do
            length commitSlot `shouldBe` 88
            "SINGULAR-COMMIT-SLOT-V1:unknown#"
                `shouldSatisfy` (`isPrefixOf` commitSlot)
    describe "stampedEnvironment" $ do
        it "puts a stamped commit where the identity line reads it" $
            lookup
                releaseCommitVariable
                (stampedEnvironment "abc123" [("HOME", "/home/a")])
                `shouldBe` Just "abc123"
        it "keeps the rest of the environment" $
            lookup
                "HOME"
                (stampedEnvironment "abc123" [("HOME", "/home/a")])
                `shouldBe` Just "/home/a"
        it "wins over a commit the environment names" $
            stampedEnvironment
                "abc123"
                [(releaseCommitVariable, "other"), ("HOME", "/home/a")]
                `shouldBe` [ (releaseCommitVariable, "abc123")
                           , ("HOME", "/home/a")
                           ]
        it "leaves the environment alone for an unstamped executable" $
            stampedEnvironment
                "unknown"
                [(releaseCommitVariable, "other"), ("HOME", "/home/a")]
                `shouldBe` [ (releaseCommitVariable, "other")
                           , ("HOME", "/home/a")
                           ]
