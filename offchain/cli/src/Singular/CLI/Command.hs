{-# LANGUAGE LambdaCase #-}

{- |
Module      : Singular.CLI.Command
Description : What a @singular@ command line asks for, parsed without effects
License     : Apache-2.0

The registry commands and help, read from the command line alone:
no file, node, key or environment is touched here, so every refusal
below happens before anything is read or submitted.

* @registry create@ boots one registry from a seed the caller chose in
  their own wallet, or previews its identity with @--preview@;
* @registry insert@ books one @insertActive@ at a key and
* @registry terminate@ books one @updateTerminal@ at a key, each leaving
  its request pending for the registry's fold; with @--fold@ either
  also folds it in the same command;
* @registry fold@ folds the one pending request, signed and funded by
  the wallet that runs it;
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
    , EntryMode (..)
    , FoldArgs (..)
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

import Control.Monad (forM_, unless, when)
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.Char (GeneralCategory (Surrogate), generalCategory)
import Data.List (isPrefixOf)
import Data.Maybe (isJust, isNothing)
import Data.Text qualified as T
import Data.Word (Word32)
import Text.Read (readMaybe)

import Cardano.Ledger.TxIn (TxIn)
import Singular.Application.OpenDatum.Build
    ( KeyEncoding (..)
    , KeyRefusal (..)
    , maxKeyBytes
    , readKey
    )
import Singular.CLI.Node (backendSetting, writeTarget)
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
    , createMode :: EntryMode
    {- ^ Submit with the caller's key, or (with @--preview@ only) read for a
    public address
    -}
    , createSeed :: Maybe String
    -- ^ @txid#index@ of the wallet output the boot consumes
    , createPreview :: Bool
    , createReceipt :: Maybe FilePath
    }
    deriving stock (Eq, Show)

{- | What an entry command does with the transactions it builds: sign and
submit them with the caller's key, or prepare them for a public address
and submit nothing. A preview carries no signing key at all.
-}
data EntryMode
    = Submit WriteSettings
    | -- | The node to read, and the caller's enterprise address, bech32
      Preview NodeSettings String
    deriving stock (Eq, Show)

-- | @registry insert@, @registry update@ and @registry terminate@.
data EntryArgs = EntryArgs
    { entryRegistry :: FilePath
    , entryBlueprint :: FilePath
    , entryMode :: EntryMode
    , entryKey :: Key
    , entryDocument :: Maybe FilePath
    {- ^ @insert@: the envelope's detailed-schema JSON (@--envelope@);
    @update@: the new payload's (@--payload@); @terminate@: none
    -}
    , entryFund :: Maybe TxIn
    -- ^ @--fund-input@: the wallet output to fund and collateralise from
    , entryMaxOutlay :: Maybe Integer
    {- ^ @--max-outlay@: lovelace the command may put out; past it nothing is
    submitted
    -}
    , entryReceipt :: Maybe FilePath
    , entryFold :: Bool
    {- ^ @--fold@: after the booking confirms, run the fold the way
    @registry fold@ does. @insert@ and @terminate@ only, never with
    @--preview@
    -}
    }
    deriving stock (Eq, Show)

-- | @registry fold@: the registry's pending request, folded by this wallet.
data FoldArgs = FoldArgs
    { foldRegistry :: FilePath
    , foldBlueprint :: FilePath
    , foldWrite :: WriteSettings
    , foldRequest :: Maybe TxIn
    {- ^ @--request@: the pending request the caller expects to fold; the
    fold is refused when it is not the one pending
    -}
    , foldFund :: Maybe TxIn
    -- ^ @--fund-input@: the wallet output that funds and collateralises the fold
    , foldMaxOutlay :: Maybe Integer
    -- ^ @--max-outlay@: lovelace the fold may put out; past it nothing is signed
    , foldReceipt :: Maybe FilePath
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
    | Fold FoldArgs
    | Inspect InspectArgs
    deriving stock (Eq, Show)

-- | Why a command line was refused before anything ran.
data CLIError
    = UnknownCommand [String]
    | MissingFlag String
    | BadValue String String
    | -- | the key reader's named reason
      KeyRefused KeyRefusal
    | UnsafeSettings String
    | SigningKeyNotAccepted
    | PreviewTakesNoKey
    | {- | A recognised constraint the command does not enforce: refused with
      its name and the command, before any key is read or anything written
      -}
      UnsupportedFlag String String
    deriving stock (Eq, Show)

-- | Parse a command line.
parseCommand :: [String] -> Either CLIError Command
parseCommand args = do
    (words', flags) <- tokens args
    _ <- either (Left . BadValue "--backend") Right (backendSetting args)
    if "--help" `elem` map fst flags || "-h" `elem` map fst flags
        then Right Help
        else case words' of
            [] -> Right Help
            ["registry"] -> Right Help
            ["registry", "create"] ->
                refuseSpendingFlags "create" flags
                    >> refuseRequest flags
                    >> refuseFold flags
                    >> (Create <$> createArgs flags)
            ["registry", "insert"] ->
                refuseRequest flags
                    >> (Insert <$> entryArgs True (Just "--envelope") flags)
            ["registry", "update"] ->
                refuseRequest flags
                    >> (Update <$> entryArgs False (Just "--payload") flags)
            ["registry", "terminate"] ->
                refuseRequest flags >> (Terminate <$> entryArgs True Nothing flags)
            ["registry", "fold"] -> Fold <$> foldArgs flags
            ["registry", "inspect"] ->
                refuseSpendingFlags "inspect" flags
                    >> refuseRequest flags
                    >> refuseFold flags
                    >> (Inspect <$> inspectArgs flags)
            _ -> Left (UnknownCommand words')
  where
    -- The constraints on a write's spending belong to insert, update and
    -- terminate. A command that does not enforce one refuses it by name rather
    -- than discard what the caller stated.
    refuseSpendingFlags command flags =
        forM_ ["--fund-input", "--max-outlay"] $ \flag ->
            when (isJust (lookup flag flags)) $
                Left (UnsupportedFlag flag command)
    -- @--request@ names what @registry fold@ folds; @--fold@ belongs to the
    -- two commands that book. Any other command refuses either by name.
    refuseRequest flags =
        when (isJust (lookup "--request" flags)) $
            Left
                ( BadValue
                    "--request"
                    "names the pending request @registry fold@ folds; this command takes none"
                )
    refuseFold flags =
        when (isJust (lookup "--fold" flags)) $
            Left
                ( BadValue
                    "--fold"
                    "is taken by insert and terminate only: they book, and with it also fold"
                )
    createArgs flags = do
        dir <- required "--registry" flags
        bp <- required "--blueprint" flags
        let preview = isJust (lookup "--preview" flags)
            publicPreview = preview && isJust (lookup "--wallet-address" flags)
        when (not preview && isJust (lookup "--wallet-address" flags)) $
            Left addressNeedsPreview
        mode <-
            if publicPreview
                then previewMode flags
                else Submit <$> writeSettings flags
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
                , createMode = mode
                , createSeed = seed
                , createPreview = preview
                , createReceipt = optional "--receipt" flags
                }
    entryArgs books document flags = do
        dir <- required "--registry" flags
        bp <- required "--blueprint" flags
        key <- keyFrom flags
        unless books (refuseFold flags)
        when
            (isJust (lookup "--fold" flags) && isJust (lookup "--preview" flags))
            $ Left
                ( BadValue
                    "--fold"
                    "is not accepted with --preview: a preview measures the booking and never folds"
                )
        when
            ( isNothing (lookup "--preview" flags)
                && isJust (lookup "--wallet-address" flags)
            )
            $ Left addressNeedsPreview
        mode <-
            if isJust (lookup "--preview" flags)
                then previewMode flags
                else Submit <$> writeSettings flags
        doc <- traverse (`required` flags) document
        fund <- fundFrom flags
        outlay <- outlayFrom flags
        pure
            EntryArgs
                { entryRegistry = dir
                , entryBlueprint = bp
                , entryMode = mode
                , entryKey = key
                , entryDocument = doc
                , entryFund = fund
                , entryMaxOutlay = outlay
                , entryReceipt = optional "--receipt" flags
                , entryFold = isJust (lookup "--fold" flags)
                }
    foldArgs flags = do
        dir <- required "--registry" flags
        bp <- required "--blueprint" flags
        forM_ ["--key", "--envelope", "--payload", "--preview", "--fold"] $ \flag ->
            when (isJust (lookup flag flags)) $
                Left
                    ( BadValue
                        flag
                        "is not accepted by registry fold: it folds the pending request, whose key and edge the request names"
                    )
        when (isJust (lookup "--wallet-address" flags)) $
            Left addressNeedsPreview
        settings <- writeSettings flags
        request <- case optional "--request" flags of
            Nothing -> Right Nothing
            Just s -> case parseOutRef (T.pack s) of
                Right i -> Right (Just i)
                Left err -> Left (BadValue "--request" err)
        fund <- fundFrom flags
        outlay <- outlayFrom flags
        pure
            FoldArgs
                { foldRegistry = dir
                , foldBlueprint = bp
                , foldWrite = settings
                , foldRequest = request
                , foldFund = fund
                , foldMaxOutlay = outlay
                , foldReceipt = optional "--receipt" flags
                }
    fundFrom flags = case optional "--fund-input" flags of
        Nothing -> Right Nothing
        Just s -> case parseOutRef (T.pack s) of
            Right i -> Right (Just i)
            Left err -> Left (BadValue "--fund-input" err)
    outlayFrom flags = case optional "--max-outlay" flags of
        Nothing -> Right Nothing
        Just s -> case readMaybe s of
            Just n | n > 0 -> Right (Just n)
            _ ->
                Left
                    (BadValue "--max-outlay" "is not a positive number of lovelace")
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
    -- A preview reads a node and names a public address; it holds no key,
    -- so a signing key is refused before anything is read.
    addressNeedsPreview =
        BadValue
            "--wallet-address"
            "names a caller for --preview only; a write signs with --wallet-skey"
    previewMode flags = do
        when (isJust (lookup "--wallet-skey" flags)) $
            Left PreviewTakesNoKey
        sock <- required "--node-socket" flags
        magicText <- required "--network-magic" flags
        magic <-
            maybe
                (Left (BadValue "--network-magic" "not a number"))
                Right
                (readMaybe magicText)
        addr <- required "--wallet-address" flags
        pure (Preview (NodeSettings sock magic) addr)
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
    -- --key is the text of the key and --key-hex its base16: one of the two,
    -- read by the library, so no command keeps a decoder of its own.
    keyFrom flags = case (optional "--key" flags, optional "--key-hex" flags) of
        (Just _, Just _) ->
            Left (BadValue "--key-hex" "excludes --key: name the key once")
        (Just argument, Nothing)
            | any isSurrogate argument ->
                Left
                    ( BadValue
                        "--key"
                        "is not text in this locale's encoding: run under a UTF-8 locale, or spell the bytes with --key-hex"
                    )
            | otherwise -> readKeyAs KeyText argument
        (Nothing, Just argument) -> readKeyAs KeyHex argument
        (Nothing, Nothing) -> Left (MissingFlag "--key")
    readKeyAs encoding argument =
        Key <$> first KeyRefused (readKey encoding (T.pack argument))
    isSurrogate c = generalCategory c == Surrogate
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
    switches = ["--help", "-h", "--preview", "--fold"]
    valued =
        [ "--registry"
        , "--blueprint"
        , "--node-socket"
        , "--network-magic"
        , "--wallet-skey"
        , "--seed"
        , "--key"
        , "--key-hex"
        , "--receipt"
        , "--confirm-timeout"
        , "--wallet-address"
        , "--fund-input"
        , "--max-outlay"
        , "--envelope"
        , "--payload"
        , "--request"
        , "--backend"
        ]

-- | One line naming the refusal.
renderCLIError :: CLIError -> String
renderCLIError = \case
    UnknownCommand ws ->
        "not a command singular supports: " <> unwords ws
    MissingFlag name -> "missing " <> name
    BadValue name why -> name <> " " <> why
    KeyRefused KeyEmpty ->
        "--key is empty: a registry key is 1 to "
            <> show maxKeyBytes
            <> " bytes"
    KeyRefused KeyNotHex -> "--key-hex is not base16 bytes"
    KeyRefused (KeyTooLong n) ->
        "--key names "
            <> show n
            <> " bytes; a registry key is at most "
            <> show maxKeyBytes
            <> " bytes"
    UnsafeSettings why -> why
    SigningKeyNotAccepted ->
        "inspect takes no signing key: it reads, and never funds or submits"
    PreviewTakesNoKey ->
        "--preview takes no signing key: name the caller with --wallet-address; a preview reads, and never signs or submits"
    UnsupportedFlag flag command ->
        flag
            <> " is not accepted by `registry "
            <> command
            <> "`: only insert, update, terminate and fold enforce it, and a constraint the command does not enforce is refused, never ignored"

-- | The supported commands.
usage :: String
usage =
    unlines
        [ "usage:"
        , "  singular registry create --registry DIR --blueprint PLUTUS_JSON"
        , "      (--seed TXID#IX | --preview)"
        , "      --node-socket PATH --network-magic N --wallet-skey FILE [--receipt FILE]"
        , "  singular registry create --preview --registry DIR --blueprint PLUTUS_JSON"
        , "      [--seed TXID#IX] --node-socket PATH --network-magic N --wallet-address ADDR"
        , "  singular registry insert --registry DIR --blueprint PLUTUS_JSON (--key KEY | --key-hex HEX)"
        , "      --envelope ENVELOPE_JSON"
        , "      --node-socket PATH --network-magic N --wallet-skey FILE [--receipt FILE]"
        , "      [--fund-input TXID#IX] [--max-outlay LOVELACE] [--fold]"
        , "  singular registry insert --preview --registry DIR --blueprint PLUTUS_JSON"
        , "      (--key KEY | --key-hex HEX) --envelope ENVELOPE_JSON"
        , "      --node-socket PATH --network-magic N --wallet-address ADDR"
        , "      [--fund-input TXID#IX] [--max-outlay LOVELACE]"
        , "  singular registry update --registry DIR --blueprint PLUTUS_JSON (--key KEY | --key-hex HEX)"
        , "      --payload DATUM_JSON"
        , "      --node-socket PATH --network-magic N --wallet-skey FILE [--receipt FILE]"
        , "      [--fund-input TXID#IX] [--max-outlay LOVELACE]"
        , "  singular registry update --preview --registry DIR --blueprint PLUTUS_JSON"
        , "      (--key KEY | --key-hex HEX) --payload DATUM_JSON"
        , "      --node-socket PATH --network-magic N --wallet-address ADDR"
        , "      [--fund-input TXID#IX] [--max-outlay LOVELACE]"
        , "  singular registry terminate --registry DIR --blueprint PLUTUS_JSON (--key KEY | --key-hex HEX)"
        , "      --node-socket PATH --network-magic N --wallet-skey FILE [--receipt FILE]"
        , "      [--fund-input TXID#IX] [--max-outlay LOVELACE] [--fold]"
        , "  singular registry terminate --preview --registry DIR --blueprint PLUTUS_JSON"
        , "      (--key KEY | --key-hex HEX)"
        , "      --node-socket PATH --network-magic N --wallet-address ADDR"
        , "      [--fund-input TXID#IX] [--max-outlay LOVELACE]"
        , "  singular registry fold --registry DIR --blueprint PLUTUS_JSON"
        , "      --node-socket PATH --network-magic N --wallet-skey FILE [--receipt FILE]"
        , "      [--request TXID#IX] [--fund-input TXID#IX] [--max-outlay LOVELACE]"
        , "  singular registry inspect --registry DIR --blueprint PLUTUS_JSON (--key KEY | --key-hex HEX)"
        , "      --node-socket PATH --network-magic N [--receipt FILE]"
        , ""
        , "Write commands also take --confirm-timeout SECONDS (default 600): past it"
        , "the command stops with its submission journalled and never resubmits."
        , "Every command also takes --backend node|indexer (default node): where its"
        , "address reads come from, the node itself or an in-process index that"
        , "follows the node's chain from its origin."
        , "insert and terminate book the request and leave it pending: the registry's"
        , "fold is its own command, registry fold, run by whichever wallet folds, before"
        , "the processing deadline the booking's receipt names. Given the fold switch,"
        , "either also folds, in the same command, once its booking confirms."
        , "insert, update, terminate and fold fund and collateralise from the funding"
        , "input named, and hold to the maximum outlay stated: a booking, an update or a"
        , "fold past it is not signed, and a combined insert or terminate whose fold,"
        , "built after its booking confirms, costs more than the booking left of it stops"
        , "partial, its request pending, with the fold unsigned. create and inspect"
        , "refuse both settings: they enforce neither."
        , "The preview forms name the caller by a public wallet address instead of a"
        , "signing key: they build and measure what they would submit, print it, and"
        , "sign, submit and journal nothing."
        , "A registry key is 1 to 32 bytes: KEY is read as text, its UTF-8 bytes, and HEX as"
        , "base16. A key is named once, by one of the two."
        , "Each command prints one JSON receipt on standard output. inspect reads"
        , "only: it takes no signing key and submits nothing."
        ]
