{-# LANGUAGE ScopedTypeVariables #-}

{- |
Module      : Singular.CLI.FailureSentenceSpec
Description : A failure no command reported is one sentence, never the runtime's report
License     : Apache-2.0

An exception that escapes a command used to end the process with the
runtime's own report, @Uncaught exception ghc-internal:...@. The program now
says what failed on one line and ends with status 1, and lets an interrupt and
an exit through.
-}
module Singular.CLI.FailureSentenceSpec (spec) where

import Control.Exception
    ( AsyncException (UserInterrupt)
    , throwIO
    , toException
    )
import System.Exit (ExitCode (..), exitWith)
import System.IO.Error
    ( doesNotExistErrorType
    , mkIOError
    , permissionErrorType
    )
import Test.Hspec

import Singular.CLI.Root (containFailure, failureSentence)

spec :: Spec
spec = describe "a failure no command reported" $ do
    it "names the file and why it is not there" $
        failureSentence
            ( toException
                ( mkIOError
                    doesNotExistErrorType
                    "withBinaryFile"
                    Nothing
                    (Just "/x.vault")
                )
            )
            `shouldBe` "/x.vault: it does not exist"
    it "names the file and says permission is denied" $
        failureSentence
            ( toException
                (mkIOError permissionErrorType "openFile" Nothing (Just "/x.vault"))
            )
            `shouldBe` "/x.vault: permission denied"
    it "says the first line of anything else, in one line" $
        failureSentence
            (toException (userError "it broke\nthe rest of the story"))
            `shouldBe` "it broke"
    it "ends a failing command with status 1" $
        containFailure "singular" (ioError (userError "it broke"))
            `shouldReturn` ExitFailure 1
    it "lets an exit through with its own status" $
        containFailure "singular" (exitWith (ExitFailure 7))
            `shouldReturn` ExitFailure 7
    it "lets an interrupt through" $
        containFailure "singular" (throwIO UserInterrupt)
            `shouldThrow` (== UserInterrupt)
    it "passes a command's own status along" $
        containFailure "singular" (pure (ExitFailure 10))
            `shouldReturn` ExitFailure 10
