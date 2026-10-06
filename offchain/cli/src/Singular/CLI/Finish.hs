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
-}
module Singular.CLI.Finish
    ( finish
    ) where

import Control.Exception (SomeException, fromException, try)
import Control.Tracer (Tracer)
import Data.Aeson (Value (..), toJSON)
import Data.Aeson.Encode.Pretty (encodePretty)
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy.Char8 qualified as BLC
import Data.Text qualified as T
import System.Exit (ExitCode (..))

import Singular.CLI.Live (receipt)
import Singular.CLI.Receipt
    ( OutcomeClass (..)
    , exitCodeOf
    , outcomeName
    )
import Singular.CLI.Session (CommandFailure (..))
import Singular.CLI.Trace (Trace)

{- | Print the receipt, write it where asked, and exit with the class of
its outcome. A failure is its own receipt.
-}
finish
    :: Tracer IO Trace -> T.Text -> Maybe FilePath -> IO Value -> IO ExitCode
finish _ command target action = do
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
