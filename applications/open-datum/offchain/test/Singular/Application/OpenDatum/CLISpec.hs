module Singular.Application.OpenDatum.CLISpec (spec) where

import Control.Monad (forM_)
import Singular.Application.OpenDatum.Command
    ( CLIError (UnknownCommand)
    , parseOpenDatumCommand
    )
import Test.Hspec (Spec, describe, it, shouldBe)

spec :: Spec
spec = describe "unsupported public routes" $
    forM_ ["create", "insert", "update", "terminate", "fold", "inspect"] $ \verb ->
        forM_ ([[verb] | verb == "inspect"] <> [["open-datum", verb]]) $ \line ->
            it ("refuses " <> unwords line <> " without an alias") $
                parseOpenDatumCommand line `shouldBe` Left (UnknownCommand line)
