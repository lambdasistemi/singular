{- |
Module      : Negative.Parse
Description : The host's command line, parsed without effects
License     : Apache-2.0

The three negative-only forms beside the shared spelling: @registry
withdraw@, @registry update ... --tamper FIELD@ and @registry fold ...
--pay-short N@. Every ordinary spelling is translated to the open-datum
spelling and handed to the shared parser; an unknown spelling is refused
exactly as the shared parser refuses it. No file, node or key is touched here.
-}
module Negative.Parse
    ( -- * Negative command surface
      TamperField (..)
    , NegativeInvocation (..)
    , parseTamperField

      -- * Parsing
    , parseNegativeInvocation
    ) where

import Data.List (isPrefixOf)

import Singular.Application.OpenDatum.Command
    ( CLIError (..)
    , EntryArgs (..)
    , FoldArgs (..)
    , OpenDatumCommand (..)
    , parseOpenDatumCommandWithEnvironment
    )
import Singular.CLI.FlagGroup (commonFlagGroup)

{- | One protected field a tampered update rewrites. The five names are
the closed set the host accepts; anything else is refused as a bad
value, never built.
-}
data TamperField
    = TamperController
    | TamperDeposit
    | TamperToken
    | TamperAddress
    | TamperDatum
    deriving stock (Eq, Show)

{- | What one host invocation asks for: the shared parser's command for
every ordinary spelling, or one of the three negative forms carrying
the shared-parsed arguments. A fold without @--pay-short@ and an update
without @--tamper@ are ordinary for later slices; @withdraw@ has no
ordinary spelling.
-}
data NegativeInvocation
    = Ordinary OpenDatumCommand
    | NegativeWithdraw EntryArgs
    | NegativeUpdate EntryArgs (Maybe TamperField)
    | NegativeFold FoldArgs (Maybe Integer)
    deriving stock (Eq, Show)

{- | Read one tamper name. Accepts exactly the five protected fields;
refuses anything else as a bad value, never built.
-}
parseTamperField :: String -> Either CLIError TamperField
parseTamperField s = case s of
    "controller" -> Right TamperController
    "deposit" -> Right TamperDeposit
    "token" -> Right TamperToken
    "address" -> Right TamperAddress
    "datum" -> Right TamperDatum
    _ ->
        Left
            ( BadValue
                "--tamper"
                "needs one of controller|deposit|token|address|datum"
            )

{- | Parse one host invocation without effects. Ordinary spellings go to
the shared parser translated to the open-datum spelling; the three negative
forms are recognised by
their word or flag and their negative-only flag stripped before the
shared parse of the rest, so the shared flag group cannot drift.
-}
parseNegativeInvocation
    :: [(String, String)]
    -> [String]
    -> Either CLIError NegativeInvocation
parseNegativeInvocation env args =
    case wordsOf args of
        ["registry", "withdraw"] -> do
            cmd <-
                parseOpenDatumCommandWithEnvironment
                    env
                    (toOpenDatum (replaceWord args))
            case cmd of
                OpenTerminate entry -> Right (NegativeWithdraw entry)
                _ -> Left (UnknownCommand ["registry", "withdraw"])
        ["registry", "update"] ->
            case lookupFlag "--tamper" args of
                Just tamper -> do
                    field <- parseTamperField tamper
                    cmd <-
                        parseOpenDatumCommandWithEnvironment
                            env
                            (toOpenDatum (stripFlag "--tamper" args))
                    case cmd of
                        OpenUpdate entry ->
                            Right (NegativeUpdate entry (Just field))
                        _ -> Left (UnknownCommand ["registry", "update"])
                Nothing
                    | hasFlag "--tamper" args ->
                        Left (MissingFlag "--tamper needs a value")
                    | otherwise -> do
                        cmd <- parseOpenDatumCommandWithEnvironment env (toOpenDatum args)
                        case cmd of
                            OpenUpdate entry ->
                                Right (NegativeUpdate entry Nothing)
                            _ -> pure (Ordinary cmd)
        ["registry", "fold"] ->
            case lookupFlag "--pay-short" args of
                Just short ->
                    case reads short of
                        [(n, "")]
                            | n > 0 -> do
                                cmd <-
                                    parseOpenDatumCommandWithEnvironment
                                        env
                                        (toOpenDatum (stripFlag "--pay-short" args))
                                case cmd of
                                    OpenFold foldArgs ->
                                        Right
                                            ( NegativeFold
                                                foldArgs
                                                (Just n)
                                            )
                                    _ ->
                                        Left
                                            ( UnknownCommand
                                                ["registry", "fold"]
                                            )
                        _ ->
                            Left
                                ( BadValue
                                    "--pay-short"
                                    "needs a positive integer number of lovelace"
                                )
                Nothing
                    | hasFlag "--pay-short" args ->
                        Left (MissingFlag "--pay-short needs a value")
                    | otherwise -> do
                        cmd <- parseOpenDatumCommandWithEnvironment env (toOpenDatum args)
                        case cmd of
                            OpenFold foldArgs ->
                                Right (NegativeFold foldArgs Nothing)
                            _ -> pure (Ordinary cmd)
        _ ->
            Ordinary
                <$> parseOpenDatumCommandWithEnvironment env (toOpenDatum args)
  where
    -- Indices of the command words among the argument tokens, following
    -- the shared parser's own separation (`tokens`): flag tokens
    -- (`--name`, with an inline `=value` kept atomic, and `-h`) and the
    -- separate value of a valued flag are not words; every other token
    -- is, in order. Unknown `--` tokens count as flag tokens without a
    -- value: the shared parser refuses them either way.
    wordIndices :: [String] -> [Int]
    wordIndices = go 0
      where
        go _ [] = []
        go i (tok : toks)
            | "--" `isPrefixOf` tok || tok == "-h" =
                let (flagName, inline) = break (== '=') tok
                in  case inline of
                        '=' : _ -> go (i + 1) toks
                        _
                            | flagName `elem` commonFlagGroup -> case toks of
                                [] -> []
                                _ : more -> go (i + 2) more
                            | otherwise -> go (i + 1) toks
            | otherwise = i : go (i + 1) toks
    -- Translate only the command-namespace token: the first command
    -- word, when it names the registry namespace. Every flag token and
    -- every value stays where it is, in every ordering, so @--key
    -- registry@ keeps its value exactly like @--key=registry@, including
    -- before the command or between its words.
    toOpenDatum argv = case wordIndices argv of
        i : _ -> case splitAt i argv of
            (before, w : after)
                | w == "registry" -> before ++ ["open-datum"] ++ after
                | otherwise -> argv
            _ -> argv
        _ -> argv
    -- Rewrite only the command verb: the second command word, from
    -- @withdraw@ to @terminate@. A value such as @--key withdraw@ is
    -- caller data and is never rewritten.
    replaceWord argv = case wordIndices argv of
        _ : j : _ -> case splitAt j argv of
            (before, w : after)
                | w == "withdraw" -> before ++ ["terminate"] ++ after
                | otherwise -> argv
            _ -> argv
        _ -> argv
    stripFlag flag = go
      where
        go [] = []
        go (a : rest)
            | a == flag = case rest of
                (_ : more) -> go more
                [] -> []
            | (flag <> "=") `isPrefixOf` a = go rest
            | otherwise = a : go rest

{- | The command words of an invocation: leading flags dropped, the first
two words that do not start with @-@.
-}
wordsOf :: [String] -> [String]
wordsOf args =
    take 2 [w | w <- args, not ("-" `isPrefixOf` w)]

{- | Whether a flag appears in any of its spellings (@--flag@,
@--flag=value@, @--flag value@).
-}
hasFlag :: String -> [String] -> Bool
hasFlag flag =
    any
        (\a -> a == flag || (flag <> "=") `isPrefixOf` a)

-- | The value of a flag in any of its spellings, if present.
lookupFlag :: String -> [String] -> Maybe String
lookupFlag flag = go
  where
    go [] = Nothing
    go (a : rest)
        | a == flag = case rest of
            (v : _) | not ("-" `isPrefixOf` v) -> Just v
            _ -> Nothing
        | (flag <> "=") `isPrefixOf` a =
            Just (drop (length flag + 1) a)
        | otherwise = go rest
