{-# LANGUAGE LambdaCase #-}

{- |
Module      : Negative.Submit
Description : Unevaluated submission and the node's verdict
License     : Apache-2.0

The host signs with the named key file, submits with fixed execution
budgets and no local evaluation, and reports the node's answer with
the failed script hashes and their roles in the opened registry.
Setup, encoding and client failures are classified as such and never
counted as refusals.
-}
module Negative.Submit
    ( -- * Node answers
      NodeAnswer (..)

      -- * Verdicts
    , FailedScript (..)
    , ScriptRole (..)
    , scriptRoleName
    , failedScripts
    , applicationHashOf
    , stateHashOf
    , refusalScriptHashes
    ) where

import Data.Char (isHexDigit)
import Data.List (nub)
import Data.Text (Text)
import Data.Text qualified as T

import Singular.CLI.Live (Live (..), Saved (..), applied)
import Singular.CLI.Registry (hexT)
import Singular.Registry.Config (CageConfig (..))
import Singular.Registry.TxBuilder.Internal
    ( computeScriptHash
    , scriptHashBytes
    )

{- | What the node said about one submitted transaction: accepted with
its transaction id, or refused with the node's own text.
-}
data NodeAnswer
    = AnswerAccepted Text
    | AnswerRefused Text
    deriving stock (Eq, Show)

{- | One failed script hash with its role in the opened registry, or no
role when it is none of them.
-}
data ScriptRole
    = RoleStateValidator
    | RoleApplicationSpending
    | RoleApplicationAtFold
    | RoleNone
    deriving stock (Eq, Show)

-- | A failed script: its hash and its role.
data FailedScript = FailedScript
    { failedHash :: Text
    , failedRole :: ScriptRole
    }
    deriving stock (Eq, Show)

{- | Each failed script hash with its role in this registry, resolved
from the registry the command opened, never a literal typed into the
check. The applied application script and the state script are the
registry's own pins; anything else carries no role.
-}
failedScripts :: Live -> NodeAnswer -> [FailedScript]
failedScripts live = \case
    AnswerAccepted _ -> []
    AnswerRefused text ->
        [ FailedScript h (roleOf h)
        | h <- map T.pack (refusalScriptHashes (T.unpack text))
        ]
  where
    roleOf h
        | h == applicationHashOf live = RoleApplicationSpending
        | h == stateHashOf live = RoleStateValidator
        | otherwise = RoleNone

{- | The registry's own application pin: the applied script's hash, as
receipt text.
-}
applicationHashOf :: Live -> Text
applicationHashOf live =
    hexT (scriptHashBytes (computeScriptHash (applied (liveSaved live))))

{- | The registry's own state pin: the state script's hash, as receipt
text.
-}
stateHashOf :: Live -> Text
stateHashOf live =
    hexT (scriptHashBytes (cfgScriptHash (savedCfg (liveSaved live))))

-- | A script role as receipt text.
scriptRoleName :: ScriptRole -> Text
scriptRoleName = \case
    RoleStateValidator -> "state-validator"
    RoleApplicationSpending -> "application-spending"
    RoleApplicationAtFold -> "application-at-fold"
    RoleNone -> "none"

{- | Every @ScriptHash \"...\"@ value in the node's text, ledger order,
first occurrence wins. Both node shapes name hashes this way.
-}
refusalScriptHashes :: String -> [String]
refusalScriptHashes text = nub (filter (not . null) (go text))
  where
    go s = case findAfter "ScriptHash " s of
        Nothing -> []
        Just after ->
            let digits = dropWhile isQuoteOrEscape after
                h = takeWhile isHexDigit digits
            in  h : go (drop (length h) digits)
    isQuoteOrEscape c = c == '"' || c == '\\'
    findAfter marker xs = case dropUntil marker xs of
        [] -> Nothing
        rest -> Just (drop (length marker) rest)
    dropUntil _ [] = []
    dropUntil marker xs@(_ : ys)
        | marker `isPrefixOf` xs = xs
        | otherwise = dropUntil marker ys
    isPrefixOf [] _ = True
    isPrefixOf _ [] = False
    isPrefixOf (a : as) (b : bs) = a == b && isPrefixOf as bs
