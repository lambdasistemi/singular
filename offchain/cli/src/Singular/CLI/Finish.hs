{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- |
Module      : Singular.CLI.Finish
Description : Print a command's receipt and name its exit status
License     : Apache-2.0

Every command ends here: its receipt is printed as JSON on standard output
(and to @--receipt FILE@ when given), and the exit status is that of its
outcome class ("Singular.CLI.Receipt"). A command that stops early is its
own receipt, naming its outcome class and why.

Asynchronous cancellation and infrastructure wait failures propagate unchanged
after the action's cleanup and journal preservation. They supply no command
verdict and must not become client or ledger refusals here.
-}
module Singular.CLI.Finish
    ( finish
    ) where

import Control.Exception
    ( SomeAsyncException
    , SomeException
    , fromException
    , tryJust
    )
import Control.Monad (forM_, unless)
import Control.Tracer (Tracer, traceWith)
import Data.Aeson (Value (..), toJSON)
import Data.Aeson.Encode.Pretty (encodePretty)
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy.Char8 qualified as BLC
import Data.Text qualified as T
import System.Exit (ExitCode (..))

import Singular.CLI.Failure (CommandFailure (..), reportedOf)
import Singular.CLI.Live (receipt)
import Singular.CLI.Receipt
    ( OutcomeClass (..)
    , exitCodeOf
    , outcomeName
    )
import Singular.CLI.Trace
    ( Event (..)
    , RefusalKind (..)
    , Trace (..)
    , What (..)
    )
import Singular.Registry.Trace (startTimer)
import Singular.Registry.WaitTypes (WaitFailure)

{- | Print the receipt, write it where asked, and exit with the class of
its outcome. A failure is its own receipt. The command's stream opens with
its start and closes with its outcome class and elapsed time, before the
receipt is printed. A refusal outcome whose refusal was not reported where it
happened (a refusal before any transaction is built) is reported here, so
every refusal receipt has exactly one refusal event.
-}
finish
    :: Tracer IO Trace -> T.Text -> Maybe FilePath -> IO Value -> IO ExitCode
finish tracer command target action = do
    traceWith tracer (Trace [] (What (CommandStarted command)))
    elapsed <- startTimer
    result <- tryJust receiptFailure action
    let (value, outcome, reported) = case result of
            Right v -> (v, outcomeOf v, False)
            Left (e :: SomeException) -> case reportedOf e of
                (marked, failure) -> case fromException failure of
                    Just (CommandFailure c why fields) ->
                        ( receipt command c (("reason", toJSON (T.pack why)) : fields)
                        , c
                        , marked
                        )
                    Nothing ->
                        ( receipt
                            command
                            ClientRefusal
                            [("reason", toJSON (T.pack (show failure)))]
                        , ClientRefusal
                        , marked
                        )
        rendered = encodePretty value
    ms <- elapsed
    -- a refusal not reported where it happened is reported here, once
    unless reported $
        forM_ (refusalOf outcome) $ \kind ->
            traceWith tracer (Trace [] (What (Refused kind Nothing)))
    traceWith
        tracer
        (Trace [] (What (CommandEnded command (outcomeName outcome) ms)))
    BLC.putStrLn rendered
    maybe (pure ()) (\p -> BLC.writeFile p (rendered <> "\n")) target
    pure (exitCodeOf outcome)
  where
    receiptFailure failure
        | Just (_ :: SomeAsyncException) <- fromException failure = Nothing
        | Just (_ :: WaitFailure) <- fromException failure = Nothing
        | otherwise = Just failure

-- | The outcome class a receipt names.
outcomeOf :: Value -> OutcomeClass
outcomeOf = \case
    Object o
        | Just (String name) <- KeyMap.lookup "outcome" o
        , (c : _) <- [c | c <- [minBound .. maxBound], outcomeName c == name] ->
            c
    _ -> ClientRefusal

-- | The refusal an outcome class stands for, when it is one.
refusalOf :: OutcomeClass -> Maybe RefusalKind
refusalOf = \case
    ClientRefusal -> Just ClientRefused
    LedgerRefusal -> Just LedgerRejected
    _ -> Nothing
