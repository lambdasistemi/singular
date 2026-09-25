{- |
Module      : Singular.Registry.E2E.ConfigSpec
Description : The real E2E entrypoint refuses unusable configuration
License     : Apache-2.0

Child processes execute the same test binary with only a behavioural
scenario selected, so configuration checks cannot recursively run themselves.
-}
module Singular.Registry.E2E.ConfigSpec (spec) where

import Data.List (isInfixOf)
import System.Environment (getEnvironment, getExecutablePath)
import System.Exit (ExitCode (..))
import System.IO.Temp (withSystemTempDirectory)
import System.Process (CreateProcess (..), proc, readCreateProcessWithExitCode)
import Test.Hspec (Spec, describe, expectationFailure, it)
import Text.Read (readMaybe)

-- | Configuration refusals observed at the executable boundary.
spec :: Spec
spec = describe "Appendix: E2E configuration checks" $ do
    it "refuses a missing REGISTRY_BLUEPRINT before any scenario passes" $
        checkConfiguration "missing" Nothing "not set"
    it "refuses an unreadable REGISTRY_BLUEPRINT before any scenario passes" $
        withSystemTempDirectory "registry-config" $ \dir ->
            checkConfiguration "unreadable" (Just (dir <> "/absent.json")) "cannot read"
    it "refuses an invalid REGISTRY_BLUEPRINT before any scenario passes" $
        withBlueprint "not a blueprint" $ \path ->
            checkConfiguration "invalid" (Just path) "invalid blueprint"
    it "refuses a REGISTRY_BLUEPRINT without required validators before any scenario passes" $
        withBlueprint "{\"validators\":[],\"definitions\":{}}" $ \path ->
            checkConfiguration "unusable" (Just path) "missing compiled validator"

withBlueprint :: String -> (FilePath -> IO ()) -> IO ()
withBlueprint contents action =
    withSystemTempDirectory "registry-config" $ \dir -> do
        let path = dir <> "/plutus.json"
        writeFile path contents
        action path

checkConfiguration :: String -> Maybe FilePath -> String -> IO ()
checkConfiguration configuration blueprint defect = do
    executable <- getExecutablePath
    inherited <- getEnvironment
    let environment =
            maybe [] (\path -> [("REGISTRY_BLUEPRINT", path)]) blueprint
                <> filter ((/= "REGISTRY_BLUEPRINT") . fst) inherited
    (status, output, errors) <-
        readCreateProcessWithExitCode
            (proc executable ["--match", "updateTerminal", "--format=specdoc", "--no-color"])
                { env = Just environment
                }
            ""
    let summaries = [n - failures | line <- lines output, Just (n, failures) <- [exampleSummary line]]
        passed = sum summaries
        diagnostic = output <> errors
        receipt =
            "configuration="
                <> configuration
                <> " child-exit="
                <> show status
                <> " passed-examples="
                <> show passed
                <> "\n"
                <> diagnostic
    putStrLn receipt
    if status /= ExitSuccess
        && "REGISTRY_BLUEPRINT" `isInfixOf` diagnostic
        && defect `isInfixOf` diagnostic
        && passed == 0
        && (not (null summaries) || null output)
        then pure ()
        else expectationFailure receipt

exampleSummary :: String -> Maybe (Int, Int)
exampleSummary line = case words line of
    count : examples : failures : failureWord : _
        | examples `elem` ["example,", "examples,"]
        , failureWord `elem` ["failure", "failures", "failure,", "failures,"] ->
            (,) <$> readMaybe count <*> readMaybe failures
    _ -> Nothing
