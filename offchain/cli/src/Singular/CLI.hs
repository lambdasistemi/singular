{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- |
Module      : Singular.CLI
Description : Run one parsed @singular@ command
License     : Apache-2.0

'runCommand' dispatches the five registry commands and help. Each
command prints one receipt as JSON on standard output (and to
@--receipt FILE@ when given) and ends with the exit status of its
outcome class ("Singular.CLI.Receipt"). A command that stops early
prints a receipt naming its outcome class and why; no secret is ever
printed.
-}
module Singular.CLI
    ( runCommand
    ) where

import Control.Exception (SomeException, fromException, try)
import Data.Aeson (Value (..), toJSON)
import Data.Aeson.Encode.Pretty (encodePretty)
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy.Char8 qualified as BLC
import Data.Text qualified as T
import System.Exit (ExitCode (..))

import Singular.CLI.Command
    ( Command (..)
    , CreateArgs (..)
    , EntryArgs (..)
    , InspectArgs (..)
    , usage
    )
import Singular.CLI.Create (runCreate)
import Singular.CLI.Entry (runInsert, runTerminate, runUpdate)
import Singular.CLI.Inspect (runInspect)
import Singular.CLI.Live (receipt)
import Singular.CLI.Receipt
    ( OutcomeClass (..)
    , exitCodeOf
    , outcomeName
    )
import Singular.CLI.Session (CommandFailure (..))

-- | Run one command; the exit status names its outcome class.
runCommand :: Command -> IO ExitCode
runCommand = \case
    Help -> putStr usage >> pure ExitSuccess
    Create a -> finish "create" (createReceipt a) (runCreate a)
    Insert a -> finish "insert" (entryReceipt a) (runInsert a)
    Update a -> finish "update" (entryReceipt a) (runUpdate a)
    Terminate a -> finish "terminate" (entryReceipt a) (runTerminate a)
    Inspect a -> finish "inspect" (inspectReceipt a) (runInspect a)

{- | Print the receipt, write it where asked, and exit with the class of
its outcome. A failure is its own receipt.
-}
finish :: T.Text -> Maybe FilePath -> IO Value -> IO ExitCode
finish command target action = do
    result <- try action
    let (value, outcome) = case result of
            Right v -> (v, outcomeOf v)
            Left (e :: SomeException) -> case fromException e of
                Just (CommandFailure c why fields) ->
                    (receipt command c (("reason", toJSON (T.pack why)) : fields), c)
                Nothing ->
                    ( receipt command ClientRefusal [("reason", toJSON (T.pack (show e)))]
                    , ClientRefusal
                    )
        rendered = encodePretty value
    BLC.putStrLn rendered
    maybe (pure ()) (\p -> BLC.writeFile p (rendered <> "\n")) target
    pure (exitCodeOf outcome)

-- | The outcome class a receipt names.
outcomeOf :: Value -> OutcomeClass
outcomeOf = \case
    Object o
        | Just (String name) <- KeyMap.lookup "outcome" o
        , (c : _) <- [c | c <- [minBound .. maxBound], outcomeName c == name] ->
            c
    _ -> ClientRefusal
