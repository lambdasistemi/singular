{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- |
Module      : Singular.CLI.Sources
Description : Settings from the environment and from one JSON file
License     : Apache-2.0

A standing setting declared with "Singular.CLI.Options" has three forms: its
flag, an environment variable and a key of one JSON file. The command line is
read first and a flag that is there is the setting. For a setting the command
line leaves out, the environment gives it, and then the file; what none of the
three gives is left to the command's own default. This module fills the
command line a person typed with what the other two give, for the settings
the command takes and for no others, so the command sees one line and decides
what it means exactly as before.

The file is named by @--config@ or by the variable @SINGULAR_CONFIG@, and
when neither does, it is @singular.json@ in the working directory if there is
one. A path inside it means what the same path on a command line means:
relative to where the command runs.

A signer is one of a choice, so a setting that sits in one is never joined to
the others: a vault from the environment or the file with a key file or an
external signer on the line is refused, naming both, and a preview, which
signs nothing, takes none from either.

A passphrase is not a setting of either: the vault's stays on a descriptor or
a prompt, and a file that names one is refused.
-}
module Singular.CLI.Sources
    ( Sources (..)
    , Config
    , noSources
    , applySources
    , configPath
    , sourceConflict
    , loadSources
    , loadSourcesAt
    , configFromValue
    , missingHint
    ) where

import Control.Exception (IOException, try)
import Data.Aeson (Value (..), eitherDecode, encode)
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy qualified as BL
import Data.ByteString.Lazy.Char8 qualified as LC
import Data.List
    ( intercalate
    , isInfixOf
    , nub
    , partition
    , sort
    , stripPrefix
    )
import Data.Maybe (fromMaybe, isNothing, listToMaybe)
import Data.Text qualified as T
import System.Directory (doesFileExist)
import System.IO.Error
    ( ioeGetErrorString
    , isDoesNotExistError
    , isPermissionError
    )

import Singular.CLI.Options
    ( Flag (..)
    , Program
    , Raw (..)
    , Shape (..)
    , configFlag
    , defaultConfigFile
    , leafAt
    , leafShape
    , nearestCommand
    , programLeaves
    , resolvePath
    , shapeFlags
    )

{- | What a file gives: each key with its value, as the text a command line
would carry.
-}
type Config = [(String, String)]

-- | Where settings come from besides the command line.
data Sources = Sources
    { sourceEnvironment :: [(String, String)]
    , sourceConfig :: Either String Config
    {- ^ The file, read; or why it cannot be used, which a command that runs
    reports and a request for help does not
    -}
    }
    deriving stock (Eq, Show)

-- | The environment alone, no file.
noSources :: [(String, String)] -> Sources
noSources environment = Sources environment (Right [])

{- | The command line, with the standing settings the command takes and the
line leaves out added from the environment and the file, as if typed after
the rest. A line that asks for help or the version is left alone, and so is a
preview: it signs nothing, so it takes no signer from either.
-}
applySources :: Program -> Sources -> Raw -> Raw
applySources program sources@(Sources environment _) raw@(Raw ws flags)
    | any (`elem` present) ["--help", "--version"] = raw
    | otherwise = case leafAt program (fst (resolvePath program ws)) of
        Nothing -> raw
        Just leaf ->
            raw
                { rawFlags =
                    flags
                        <> [ (flagName f, Just value)
                           | f <- nub (shapeFlags (leafShape leaf))
                           , flagName f `notElem` present
                           , not (previewing && not (null (rivals (leafShape leaf) f)))
                           , Just (value, _) <- [sourced sources file f]
                           ]
                }
  where
    present = map fst flags
    previewing = "--preview" `elem` present
    file = fromMaybe defaultConfigFile (configPath environment raw)

{- | A setting a source gives: its value, where it comes from said as a
person reads it, and how to take it away.
-}
type Sourced = (String, (String, String))

{- | What the environment, then the file, gives for a standing setting; an
empty value is no value.
-}
sourced :: Sources -> FilePath -> Flag -> Maybe Sourced
sourced (Sources environment config) file f =
    case filter (not . null . fst) (environmentValue <> fileValue) of
        found : _ -> Just found
        [] -> Nothing
  where
    environmentValue =
        [ (value, ("the variable " <> variable, "unset the variable"))
        | Just variable <- [flagEnvironment f]
        , Just value <- [lookup variable environment]
        ]
    fileValue =
        [ ( value
          , ("the " <> show key <> " key of " <> file, "remove the key")
          )
        | Just key <- [flagConfig f]
        , Right pairs <- [config]
        , (name, value) <- pairs
        , name == key
        ]

{- | The flags a setting excludes, by the group the command declares it in:
those of the other branches of the innermost exclusive choice that holds it.
The vault of a write is excluded by the external signer's address and bundle
and by the key file; a setting outside any choice excludes nothing.
-}
rivals :: Shape -> Flag -> [String]
rivals shape f = case shape of
    OneOf branches -> case partition (elem f . shapeFlags) branches of
        ([], _) -> []
        (mine, others) -> case concatMap (`rivals` f) mine of
            [] -> nub (map flagName (concatMap shapeFlags others))
            deeper -> deeper
    Each parts -> concatMap (`rivals` f) parts
    _ -> []

{- | A setting the environment or the file would give, while the line names a
flag it cannot be used with: the refusal, naming where the setting comes from
and the flag on the line. Only one signer is ever taken, so a vault from the
environment is never joined to a key file or an external signer typed on the
line, and neither is one silently dropped.
-}
sourceConflict :: Program -> Sources -> Raw -> Maybe String
sourceConflict program sources@(Sources environment _) raw@(Raw ws flags)
    | any (`elem` present) ["--help", "--version", "--preview"] = Nothing
    | otherwise = do
        leaf <- leafAt program (fst (resolvePath program ws))
        listToMaybe
            [ flagName f
                <> " comes from "
                <> from
                <> " and "
                <> rival
                <> " is on the command line, and only one of the two can be used: "
                <> undo
                <> ", or leave "
                <> rival
                <> " out"
            | f <- nub (shapeFlags (leafShape leaf))
            , flagName f `notElem` present
            , Just (_, (from, undo)) <- [sourced sources file f]
            , rival <- rivals (leafShape leaf) f
            , rival `elem` present
            ]
  where
    present = map fst flags
    file = fromMaybe defaultConfigFile (configPath environment raw)

-- | The file the command names: @--config@, else the variable.
configPath :: [(String, String)] -> Raw -> Maybe FilePath
configPath environment (Raw _ flags) =
    case [path | ("--config", Just path) <- flags] of
        path : _ -> Just path
        [] -> case flagEnvironment configFlag >>= (`lookup` environment) of
            Just path | not (null path) -> Just path
            _ -> Nothing

{- | The settings a file gives for a command line: the file it names, or
@singular.json@ in the working directory when it names none and there is one.
A file that is named and cannot be used is a refusal, and so is a present
default one; an absent default is no file.
-}
loadSources :: Program -> [(String, String)] -> Raw -> IO Sources
loadSources = loadSourcesAt defaultConfigFile

-- | The same with the file read when none is named given, for a test.
loadSourcesAt
    :: FilePath -> Program -> [(String, String)] -> Raw -> IO Sources
loadSourcesAt fallback program environment raw =
    Sources environment <$> case configPath environment raw of
        Just path -> readConfig program path
        Nothing -> do
            present <- doesFileExist fallback
            if present then readConfig program fallback else pure (Right [])

-- | Read a file, or say in a sentence why it cannot be used.
readConfig :: Program -> FilePath -> IO (Either String Config)
readConfig program path = do
    bytes <- try (BL.readFile path)
    pure $ case bytes of
        Left (e :: IOException)
            | isDoesNotExistError e ->
                Left ("the config file " <> path <> " does not exist")
            | isPermissionError e ->
                Left
                    ("the config file " <> path <> " cannot be read: permission denied")
            | otherwise ->
                Left
                    ( "the config file "
                        <> path
                        <> " cannot be read: "
                        <> ioeGetErrorString e
                    )
        Right content -> case eitherDecode content of
            Left why -> Left ("the config file " <> path <> " is not JSON: " <> clean why)
            Right value -> configFromValue program path value
  where
    clean why = fromMaybe why (stripPrefix "Error in $: " why)

{- | A file's settings: one JSON object whose keys are setting names without
their dashes and whose values are text or numbers. A key the file may not
give is refused, so a misspelling is never silently ignored and a passphrase
is never read.
-}
configFromValue
    :: Program -> FilePath -> Value -> Either String Config
configFromValue program path = \case
    Object o -> traverse entry (KeyMap.toList o)
    _ -> Left (here "must hold one JSON object of settings")
  where
    here why = "the config file " <> path <> " " <> why
    everyFlag = nub (concatMap (shapeFlags . leafShape) (programLeaves program))
    keys = sort (nub [k | f <- everyFlag, Just k <- [flagConfig f]])
    others =
        sort
            ( nub
                ( "config"
                    : [drop 2 (flagName f) | f <- everyFlag, isNothing (flagConfig f)]
                )
            )
    entry (key, value) = case Key.toString key of
        name
            | name `elem` keys -> (,) name <$> text name value
            | name `elem` others ->
                Left
                    ( here
                        ( show name
                            <> " cannot come from a file; only "
                            <> intercalate ", " keys
                            <> " can: give --"
                            <> name
                            <> " on the command line"
                        )
                    )
            | otherwise -> Left (here (unknown name))
    text name = \case
        String t -> Right (T.unpack t)
        Number n -> Right (LC.unpack (encode (Number n)))
        Null -> Right ""
        _ -> Left (here (show name <> " must be text or a number"))
    unknown name =
        "has no setting "
            <> show name
            <> case nearestCommand keys name of
                Just near -> "; did you mean " <> show near <> "?"
                Nothing
                    | any (`isInfixOf` name) ["pass", "secret"] ->
                        "; a passphrase is never read from a file"
                    | otherwise -> "; the settings are " <> intercalate ", " keys

{- | What a refusal for a missing flag adds when the flag is a standing
setting: the three ways to give it. Nothing for any other flag.
-}
missingHint :: Program -> String -> [String]
missingHint program name =
    case [ f
         | f <- nub (concatMap (shapeFlags . leafShape) (programLeaves program))
         , flagName f == name
         ] of
        f : _
            | Just variable <- flagEnvironment f
            , Just key <- flagConfig f ->
                [ "Give it as "
                    <> name
                    <> ", or set the variable "
                    <> variable
                    <> ", or put the key \""
                    <> key
                    <> "\" in the config file ("
                    <> defaultConfigFile
                    <> " in the working directory, or the file named by --config or "
                    <> fromMaybe "SINGULAR_CONFIG" (flagEnvironment configFlag)
                    <> ")."
                ]
        _ -> []
