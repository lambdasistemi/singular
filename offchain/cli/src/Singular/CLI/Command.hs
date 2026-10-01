{-# LANGUAGE LambdaCase #-}

{- |
Module      : Singular.CLI.Command
Description : What a @singular@ command line asks for, parsed without effects
License     : Apache-2.0

The four registry commands and help, read from the command line alone:
no file, node, key or environment is touched here, so every refusal
below happens before anything is read or submitted.

* @registry create@ boots one registry from a seed the caller chose in
  their own wallet, or previews its identity with @--preview@;
* @registry insert@ books and folds one @insertActive@ at a key;
* @registry terminate@ books and folds one @updateTerminal@ at a key;
* @registry inspect@ reads the registry and one key back, and accepts
  no signing key at all.

Write commands take their node and wallet from three settings
(@--node-socket@, @--network-magic@, @--wallet-skey@), read by
'writeTarget' in "Singular.CLI.Node", so a partial set and mainnet are
refused with the node module's own diagnostics.
The CLI never spawns a node of its own: a registry that died with the
process could not be attached to by the next one.
-}
module Singular.CLI.Command
    ( -- * Commands
      Command (..)
    , CreateArgs (..)
    , EntryArgs (..)
    , InspectArgs (..)
    , NodeSettings (..)
    , WriteSettings (..)
    , Key (..)

      -- * Parsing
    , CLIError (..)
    , parseCommand
    , renderCLIError
    , usage
    , maxKeyBytes
    ) where

import Control.Monad (when)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Char8 qualified as BC
import Data.List (isPrefixOf)
import Data.Maybe (isJust)
import Data.Text qualified as T
import Data.Word (Word32)
import Text.Read (readMaybe)

import Singular.CLI.Node (writeTarget)
import Singular.Registry.Deployment (parseOutRef)

-- | A registry key: the bytes the leaf and the active token are named by.
newtype Key = Key {unKey :: ByteString}
    deriving stock (Eq, Show)

-- | The node a command reads from.
data NodeSettings = NodeSettings
    { nodeSocket :: FilePath
    , nodeMagic :: Word32
    }
    deriving stock (Eq, Show)

-- | The node and the wallet a write command funds and signs from.
data WriteSettings = WriteSettings
    { writeNode :: NodeSettings
    , writeWalletKey :: FilePath
    -- ^ Path of the caller's payment signing key; read, never printed
    , writeConfirmTimeout :: Maybe Int
    {- ^ Seconds to wait for each submission to confirm; unset, ten minutes.
    The bound holds even when the node is lost after accepting the
    submission. On expiry the command stops with the submission
    journalled, never resubmitting.
    -}
    }
    deriving stock (Eq, Show)

-- | @registry create@.
data CreateArgs = CreateArgs
    { createRegistry :: FilePath
    , createBlueprint :: FilePath
    , createWrite :: WriteSettings
    , createSeed :: Maybe String
    -- ^ @txid#index@ of the wallet output the boot consumes
    , createPreview :: Bool
    , createReceipt :: Maybe FilePath
    }
    deriving stock (Eq, Show)

-- | @registry insert@ and @registry terminate@.
data EntryArgs = EntryArgs
    { entryRegistry :: FilePath
    , entryBlueprint :: FilePath
    , entryWrite :: WriteSettings
    , entryKey :: Key
    , entryDocument :: Maybe FilePath
    {- ^ @insert@: the envelope's detailed-schema JSON (@--envelope@);
    @update@: the new payload's (@--payload@); @terminate@: none
    -}
    , entryReceipt :: Maybe FilePath
    }
    deriving stock (Eq, Show)

-- | @registry inspect@: node settings only, never a wallet.
data InspectArgs = InspectArgs
    { inspectRegistry :: FilePath
    , inspectBlueprint :: FilePath
    , inspectNode :: NodeSettings
    , inspectKey :: Key
    , inspectReceipt :: Maybe FilePath
    }
    deriving stock (Eq, Show)

-- | One parsed command line.
data Command
    = Help
    | Create CreateArgs
    | Insert EntryArgs
    | Update EntryArgs
    | Terminate EntryArgs
    | Inspect InspectArgs
    deriving stock (Eq, Show)

-- | Why a command line was refused before anything ran.
data CLIError
    = UnknownCommand [String]
    | MissingFlag String
    | BadValue String String
    | KeyMalformed String
    | KeyOversized Int
    | UnsafeSettings String
    | SigningKeyNotAccepted
    deriving stock (Eq, Show)

-- | The longest key a registry can name: a ledger asset name.
maxKeyBytes :: Int
maxKeyBytes = 32

-- | Parse a command line.
parseCommand :: [String] -> Either CLIError Command
parseCommand args = do
    (words', flags) <- tokens args
    if "--help" `elem` map fst flags || "-h" `elem` map fst flags
        then Right Help
        else case words' of
            [] -> Right Help
            ["registry"] -> Right Help
            ["registry", "create"] -> Create <$> createArgs flags
            ["registry", "insert"] -> Insert <$> entryArgs (Just "--envelope") flags
            ["registry", "update"] -> Update <$> entryArgs (Just "--payload") flags
            ["registry", "terminate"] -> Terminate <$> entryArgs Nothing flags
            ["registry", "inspect"] -> Inspect <$> inspectArgs flags
            _ -> Left (UnknownCommand words')
  where
    createArgs flags = do
        dir <- required "--registry" flags
        bp <- required "--blueprint" flags
        write <- writeSettings flags
        let preview = isJust (lookup "--preview" flags)
        seed <- case lookup "--seed" flags of
            Just (Just s) -> case parseOutRef (T.pack s) of
                Right _ -> Right (Just s)
                Left err -> Left (BadValue "--seed" err)
            _
                | preview -> Right Nothing
                | otherwise -> Left (MissingFlag "--seed")
        pure
            CreateArgs
                { createRegistry = dir
                , createBlueprint = bp
                , createWrite = write
                , createSeed = seed
                , createPreview = preview
                , createReceipt = optional "--receipt" flags
                }
    entryArgs document flags = do
        dir <- required "--registry" flags
        bp <- required "--blueprint" flags
        key <- keyFrom flags
        write <- writeSettings flags
        doc <- traverse (`required` flags) document
        pure
            EntryArgs
                { entryRegistry = dir
                , entryBlueprint = bp
                , entryWrite = write
                , entryKey = key
                , entryDocument = doc
                , entryReceipt = optional "--receipt" flags
                }
    inspectArgs flags = do
        when (isJust (lookup "--wallet-skey" flags)) $
            Left SigningKeyNotAccepted
        dir <- required "--registry" flags
        bp <- required "--blueprint" flags
        key <- keyFrom flags
        sock <- required "--node-socket" flags
        magicText <- required "--network-magic" flags
        magic <-
            maybe
                (Left (BadValue "--network-magic" "not a number"))
                Right
                (readMaybe magicText)
        pure
            InspectArgs
                { inspectRegistry = dir
                , inspectBlueprint = bp
                , inspectNode = NodeSettings sock magic
                , inspectKey = key
                , inspectReceipt = optional "--receipt" flags
                }
    -- The three write settings go through the node module's own reader,
    -- so its partial-setting and mainnet refusals are this command's.
    writeSettings flags = case writeTarget args of
        Left err -> Left (UnsafeSettings err)
        Right Nothing ->
            Left
                ( UnsafeSettings
                    "a write needs --node-socket, --network-magic and \
                    \--wallet-skey: singular never starts a node of its own, \
                    \because a registry booted on a chain that dies with the \
                    \process could not be attached to again"
                )
        Right (Just (sock, magic, skey)) -> do
            timeout <- case optional "--confirm-timeout" flags of
                Nothing -> Right Nothing
                Just s -> case readMaybe s of
                    Just n | n >= 0 -> Right (Just n)
                    _ ->
                        Left (BadValue "--confirm-timeout" "is not a whole number of seconds")
            Right
                WriteSettings
                    { writeNode = NodeSettings sock magic
                    , writeWalletKey = skey
                    , writeConfirmTimeout = timeout
                    }
    keyFrom flags = do
        text <- required "--key" flags
        bytes <- case B16.decode (BC.pack text) of
            Right b -> Right b
            Left _ -> Left (KeyMalformed text)
        when (BS.length bytes > maxKeyBytes) $
            Left (KeyOversized (BS.length bytes))
        pure (Key bytes)
    required name flags = case lookup name flags of
        Just (Just v) -> Right v
        _ -> Left (MissingFlag name)
    optional name flags = case lookup name flags of
        Just (Just v) -> Just v
        _ -> Nothing

{- | Split a command line into its words and its flags, the first
occurrence of a flag winning. A value flag takes the next token or its
@=value@ spelling; a switch takes nothing.
-}
tokens
    :: [String] -> Either CLIError ([String], [(String, Maybe String)])
tokens = go [] []
  where
    go ws fs [] = Right (reverse ws, reverse fs)
    go ws fs (a : rest)
        | "--" `isPrefixOf` a || a == "-h" =
            let (name, inline) = break (== '=') a
            in  if name `elem` switches
                    then go ws ((name, Nothing) : fs) rest
                    else
                        if name `elem` valued
                            then case (inline, rest) of
                                ('=' : v, _) -> go ws (keep name v fs) rest
                                (_, v : rest') -> go ws (keep name v fs) rest'
                                (_, []) -> Left (BadValue name "needs a value")
                            else Left (BadValue name "is not a flag singular reads")
        | otherwise = go (a : ws) fs rest
    keep name v fs
        | isJust (lookup name fs) = fs
        | otherwise = (name, Just v) : fs
    switches = ["--help", "-h", "--preview"]
    valued =
        [ "--registry"
        , "--blueprint"
        , "--node-socket"
        , "--network-magic"
        , "--wallet-skey"
        , "--seed"
        , "--key"
        , "--receipt"
        , "--confirm-timeout"
        , "--envelope"
        , "--payload"
        ]

-- | One line naming the refusal.
renderCLIError :: CLIError -> String
renderCLIError = \case
    UnknownCommand ws ->
        "not a command singular supports: " <> unwords ws
    MissingFlag name -> "missing " <> name
    BadValue name why -> name <> " " <> why
    KeyMalformed text -> "--key is not hex bytes: " <> text
    KeyOversized n ->
        "--key names "
            <> show n
            <> " bytes; a registry key is at most "
            <> show maxKeyBytes
    UnsafeSettings why -> why
    SigningKeyNotAccepted ->
        "inspect takes no signing key: it reads, and never funds or submits"

-- | The supported commands.
usage :: String
usage =
    unlines
        [ "usage:"
        , "  singular registry create --registry DIR --blueprint PLUTUS_JSON"
        , "      (--seed TXID#IX | --preview)"
        , "      --node-socket PATH --network-magic N --wallet-skey FILE [--receipt FILE]"
        , "  singular registry insert --registry DIR --blueprint PLUTUS_JSON --key HEX"
        , "      --envelope ENVELOPE_JSON"
        , "      --node-socket PATH --network-magic N --wallet-skey FILE [--receipt FILE]"
        , "  singular registry update --registry DIR --blueprint PLUTUS_JSON --key HEX"
        , "      --payload DATUM_JSON"
        , "      --node-socket PATH --network-magic N --wallet-skey FILE [--receipt FILE]"
        , "  singular registry terminate --registry DIR --blueprint PLUTUS_JSON --key HEX"
        , "      --node-socket PATH --network-magic N --wallet-skey FILE [--receipt FILE]"
        , "  singular registry inspect --registry DIR --blueprint PLUTUS_JSON --key HEX"
        , "      --node-socket PATH --network-magic N [--receipt FILE]"
        , ""
        , "Write commands also take --confirm-timeout SECONDS (default 600): past it"
        , "the command stops with its submission journalled and never resubmits."
        , "Each command prints one JSON receipt on standard output. inspect reads"
        , "only: it takes no signing key and submits nothing."
        ]
