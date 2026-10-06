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
* @registry reclaim@ takes back the wallet's named pending insertion or
  terminal-witness request inside its retract window;
* @registry reject@ rejects every pending request, once each is past both
  its windows, signed and funded by the wallet that runs it;
* @registry inspect@ reads the registry and one key back, and accepts
  no signing key at all.

Write commands name the Koios URL, network and wallet key. Partial settings
and mainnet are refused before file reads or provider effects. Read commands
carry a public wallet address instead of a signing key. Obsolete backend and
socket settings are refused on every command, including --backend koios.
-}
module Singular.CLI.Command
    ( -- * Commands
      Command (..)
    , CreateArgs (..)
    , EntryArgs (..)
    , EntryMode (..)
    , FoldArgs (..)
    , InspectArgs (..)
    , ProviderSettings (..)
    , RejectArgs (..)
    , ReclaimArgs (..)
    , WriteSettings (..)
    , Key (..)

      -- * Parsing
    , CLIError (..)
    , parseCommand
    , parseCommandWithEnvironment
    , parseInvocation
    , renderCLIError
    , usage
    , maxKeyBytes
    , keyFlags
    ) where

import Control.Applicative ((<|>))
import Control.Monad (forM_, unless, when)
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.Char
    ( GeneralCategory (Surrogate)
    , generalCategory
    , isDigit
    )
import Data.List (isPrefixOf)
import Data.Maybe (isJust, isNothing)
import Data.Maybe qualified
import Data.Text qualified as T
import GHC.Generics (Generic)
import Text.Read (readMaybe)

import Cardano.Ledger.TxIn (TxIn)
import Singular.Application.OpenDatum.Build
    ( DepositRefusal (..)
    , KeyEncoding (..)
    , KeyRefusal (..)
    , maxKeyBytes
    , minimumDeposit
    , readDeposit
    , readKey
    )
import Singular.CLI.Registry (economics)
import Singular.CLI.Trace
    ( TraceFormat (..)
    , TraceLevel (..)
    , TraceRequest (..)
    , TraceSink (..)
    , noTraceRequest
    )
import Singular.Registry.Config.Application (RegistryEconomics (..))
import Singular.Registry.Deployment (parseOutRef)
import Singular.Registry.ProviderSettings (ProviderSettings (..))

-- | A registry key: the bytes the leaf and the active token are named by.
newtype Key = Key {unKey :: ByteString}
    deriving stock (Eq, Show)

-- | The node and the wallet a write command funds and signs from.
data WriteSettings = WriteSettings
    { writeProvider :: ProviderSettings
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
    , createProcessTime :: Integer
    -- ^ Positive processing window in milliseconds, fixed at creation
    , createRetractTime :: Integer
    -- ^ Positive retract window in milliseconds, fixed at creation
    }
    deriving stock (Eq, Show)

{- | What an entry command does with the transactions it builds: sign and
submit them with the caller's key, or prepare them for a public address
and submit nothing. A preview carries no signing key at all.
-}
data EntryMode
    = Submit WriteSettings
    | -- | The node to read, and the caller's enterprise address, bech32
      Preview ProviderSettings String
    deriving stock (Eq, Show)

-- | @registry insert@, @registry update@ and @registry terminate@.
data EntryArgs = EntryArgs
    { entryRegistry :: FilePath
    , entryBlueprint :: FilePath
    , entryMode :: EntryMode
    , entryKey :: Key
    , entryDocument :: Maybe FilePath
    {- ^ @insert@ and @update@: the payload's detailed-schema JSON
    (@--payload@); @terminate@: none
    -}
    , entryDeposit :: Maybe Integer
    {- ^ @insert@: the protected deposit in lovelace (@--deposit@, else the
    minimum); @update@ and @terminate@: none
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

-- | @registry reject@: every pending request, rejected by this wallet.
data RejectArgs = RejectArgs
    { rejectRegistry :: FilePath
    , rejectBlueprint :: FilePath
    , rejectWrite :: WriteSettings
    , rejectFund :: Maybe TxIn
    -- ^ @--fund-input@: the wallet output that funds and collateralises the reject
    , rejectMaxOutlay :: Maybe Integer
    -- ^ @--max-outlay@: lovelace the reject may put out; past it nothing is signed
    , rejectReceipt :: Maybe FilePath
    }
    deriving stock (Eq, Show)

-- | @registry reclaim@: take back this wallet's own pending request.
data ReclaimArgs = ReclaimArgs
    { reclaimRegistry :: FilePath
    , reclaimBlueprint :: FilePath
    , reclaimWrite :: WriteSettings
    , reclaimRequest :: TxIn
    -- ^ The pending request to take back; required, never chosen implicitly
    , reclaimFund :: Maybe TxIn
    -- ^ The wallet output that funds and collateralises the reclaim
    , reclaimMaxOutlay :: Maybe Integer
    -- ^ The maximum fee outlay; the return pays the caller's own wallet
    , reclaimReceipt :: Maybe FilePath
    -- ^ Also retain the printed receipt at this path
    }
    deriving stock (Eq, Show)

-- | @registry inspect@: node settings only, never a wallet.
data InspectArgs = InspectArgs
    { inspectRegistry :: FilePath
    , inspectBlueprint :: FilePath
    , inspectProvider :: ProviderSettings
    , inspectKey :: Key
    , inspectOutputsAt :: Maybe String
    {- ^ @--outputs-at@: a public address whose outputs the receipt also lists, read
    from the node apart from any write
    -}
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
    | Reject RejectArgs
    | Reclaim ReclaimArgs
    | Inspect InspectArgs
    deriving stock (Eq, Show, Generic)

-- | Why a command line was refused before anything ran.
data CLIError
    = UnknownCommand [String]
    | RemovedSetting String
    | MissingFlag String
    | BadValue String String
    | -- | the key reader's named reason
      KeyRefused KeyRefusal
    | -- | the deposit reader's named reason
      DepositRefused DepositRefusal
    | UnsafeSettings String
    | SigningKeyNotAccepted
    | PreviewTakesNoKey
    | {- | A recognised constraint the command does not enforce: refused with
      its name and the command, before any key is read or anything written
      -}
      UnsupportedFlag String String
    deriving stock (Eq, Show)

{- | The flags that spell a registry key, each with how it spells it: the one set
the key reader and every command that refuses a key are derived from.
-}
keyFlags :: [(String, KeyEncoding)]
keyFlags = [("--key", KeyText), ("--key-hex", KeyHex)]

-- | Parse a command line.
parseCommand :: [String] -> Either CLIError Command
parseCommand args = do
    (words', flags) <- tokens args
    if "--help" `elem` map fst flags || "-h" `elem` map fst flags
        then Right Help
        else
            refuseWindows words' flags >> refuseOutputsAt words' flags >> case words' of
                [] -> Right Help
                ["registry"] -> Right Help
                ["registry", "create"] ->
                    refuseSpendingFlags "create" flags
                        >> refuseRequest flags
                        >> refuseFold flags
                        >> (Create <$> createArgs flags)
                ["registry", "insert"] ->
                    refuseRequest flags >> (Insert <$> insertArgs flags)
                ["registry", "update"] ->
                    refuseRequest flags
                        >> refuseDeposit flags
                        >> (Update <$> entryArgs False (Just "--payload") flags)
                ["registry", "terminate"] ->
                    refuseRequest flags
                        >> refuseDeposit flags
                        >> (Terminate <$> entryArgs True Nothing flags)
                ["registry", "fold"] -> Fold <$> foldArgs flags
                ["registry", "reject"] -> Reject <$> rejectArgs flags
                ["registry", "reclaim"] -> Reclaim <$> reclaimArgs flags
                ["registry", "inspect"] ->
                    refuseSpendingFlags "inspect" flags
                        >> refuseRequest flags
                        >> refuseFold flags
                        >> (Inspect <$> inspectArgs flags)
                _ -> Left (UnknownCommand words')
  where
    refuseWindows words' flags =
        unless (words' == ["registry", "create"]) $
            forM_ ["--process-time", "--retract-time"] $ \flag ->
                when (isJust (lookup flag flags)) $
                    Left
                        ( BadValue
                            flag
                            "is a registry create flag: windows are fixed for the life of a registry"
                        )
    -- The constraints on a write's spending belong to insert, update and
    -- terminate. A command that does not enforce one refuses it by name rather
    -- than discard what the caller stated.
    refuseSpendingFlags command flags =
        forM_ ["--fund-input", "--max-outlay"] $ \flag ->
            when (isJust (lookup flag flags)) $
                Left (UnsupportedFlag flag command)
    -- @--outputs-at@ is read by @registry inspect@ alone; any other command
    -- refuses it by name rather than ignore it.
    refuseOutputsAt words' flags =
        when
            ( isJust (lookup "--outputs-at" flags)
                && words' /= ["registry", "inspect"]
            )
            $ Left
                ( BadValue
                    "--outputs-at"
                    "is a registry inspect flag: only inspect reads another address's outputs"
                )
    -- @--request@ names what @registry fold@ folds or reclaim takes back; @--fold@ belongs to the
    -- two commands that book. Any other command refuses either by name.
    refuseRequest flags =
        when (isJust (lookup "--request" flags)) $
            Left
                ( BadValue
                    "--request"
                    "names the pending request @registry fold@ folds or @registry reclaim@ takes back; this command takes none"
                )
    refuseFold flags =
        when (isJust (lookup "--fold" flags)) $
            Left
                ( BadValue
                    "--fold"
                    "is taken by insert and terminate only: they book, and with it also fold"
                )
    createArgs flags = do
        processing <-
            windowFrom "--process-time" (reProcessTime economics) flags
        retracting <-
            windowFrom "--retract-time" (reRetractTime economics) flags
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
                , createProcessTime = processing
                , createRetractTime = retracting
                }
    windowFrom name fallback flags = case optional name flags of
        Nothing -> Right fallback
        Just value -> case readMaybe value of
            Just n | n > 0 && all isDigit value -> Right n
            _ ->
                Left (BadValue name "needs a positive integer number of milliseconds")
    -- An insert is an entry command that also names the deposit its envelope
    -- protects: --deposit LOVELACE, else the minimum, read by the library.
    insertArgs flags = do
        parsed <- entryArgs True (Just "--payload") flags
        deposit <-
            first
                DepositRefused
                (readDeposit (T.pack <$> optional "--deposit" flags))
        pure parsed{entryDeposit = Just deposit}
    refuseDeposit flags =
        when (isJust (lookup "--deposit" flags)) $
            Left
                ( BadValue
                    "--deposit"
                    "is a registry insert flag: only insert sets a deposit"
                )
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
                , entryDeposit = Nothing
                , entryFund = fund
                , entryMaxOutlay = outlay
                , entryReceipt = optional "--receipt" flags
                , entryFold = isJust (lookup "--fold" flags)
                }
    foldArgs flags = do
        dir <- required "--registry" flags
        bp <- required "--blueprint" flags
        forM_
            (map fst keyFlags <> ["--deposit", "--payload", "--preview", "--fold"])
            $ \flag ->
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
    rejectArgs flags = do
        dir <- required "--registry" flags
        bp <- required "--blueprint" flags
        forM_
            ( ["--request"]
                <> map fst keyFlags
                <> ["--deposit", "--payload", "--preview", "--fold"]
            )
            $ \flag ->
                when (isJust (lookup flag flags)) $
                    Left
                        ( BadValue
                            flag
                            "is not accepted by registry reject: it takes every pending request, once each is past both its windows"
                        )
        when (isJust (lookup "--wallet-address" flags)) $
            Left addressNeedsPreview
        settings <- writeSettings flags
        fund <- fundFrom flags
        outlay <- outlayFrom flags
        pure
            RejectArgs
                { rejectRegistry = dir
                , rejectBlueprint = bp
                , rejectWrite = settings
                , rejectFund = fund
                , rejectMaxOutlay = outlay
                , rejectReceipt = optional "--receipt" flags
                }
    reclaimArgs flags = do
        dir <- required "--registry" flags
        bp <- required "--blueprint" flags
        forM_
            (map fst keyFlags <> ["--deposit", "--payload", "--preview", "--fold"])
            $ \flag ->
                when (isJust (lookup flag flags)) $
                    Left
                        ( BadValue
                            flag
                            "is not accepted by registry reclaim: it takes back the named pending request"
                        )
        when (isJust (lookup "--wallet-address" flags)) $
            Left addressNeedsPreview
        settings <- writeSettings flags
        named <- required "--request" flags
        request <- first (BadValue "--request") (parseOutRef (T.pack named))
        fund <- fundFrom flags
        outlay <- outlayFrom flags
        pure
            ReclaimArgs
                { reclaimRegistry = dir
                , reclaimBlueprint = bp
                , reclaimWrite = settings
                , reclaimRequest = request
                , reclaimFund = fund
                , reclaimMaxOutlay = outlay
                , reclaimReceipt = optional "--receipt" flags
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
        settings <- providerSettings flags
        pure
            InspectArgs
                { inspectRegistry = dir
                , inspectBlueprint = bp
                , inspectProvider = settings
                , inspectKey = key
                , inspectOutputsAt = optional "--outputs-at" flags
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
        settings <- providerSettings flags
        addr <- required "--wallet-address" flags
        pure (Preview settings addr)
    providerSettings flags = do
        url <- required "--koios-url" flags
        when (null url) (Left (BadValue "--koios-url" "is empty"))
        magicText <- required "--network-magic" flags
        magic <-
            maybe
                (Left (BadValue "--network-magic" "not a number"))
                Right
                (readMaybe magicText)
        pure
            ProviderSettings
                { providerUrl = url
                , providerMagic = magic
                , providerTokenFile = optional "--koios-token-file" flags
                , providerTimeDirectory = optional "--network-time" flags
                }
    -- The caller names the service, network and signing key together.
    -- Parsing precedes token-file reads, acquisition and key access.
    writeSettings flags = do
        forM_ ["--koios-url", "--network-magic", "--wallet-skey"] $ \name ->
            when (isNothing (optional name flags)) $
                Left
                    ( UnsafeSettings
                        ( "partially configured write: missing "
                            <> name
                            <> "; a write needs --koios-url, --network-magic and --wallet-skey"
                        )
                    )
        settings <- case providerSettings flags of
            Left (BadValue "--network-magic" _) ->
                Left
                    ( UnsafeSettings
                        ( "network magic is not a number: "
                            <> Data.Maybe.fromMaybe "" (optional "--network-magic" flags)
                        )
                    )
            other -> other
        when (providerMagic settings == 764824073) $
            Left (UnsafeSettings "mainnet is not supported")
        skey <- required "--wallet-skey" flags
        confirmationTimeout <- case optional "--confirm-timeout" flags of
            Nothing -> Right Nothing
            Just value -> case readMaybe value of
                Just n | n >= 0 -> Right (Just n)
                _ ->
                    Left (BadValue "--confirm-timeout" "is not a whole number of seconds")
        pure
            WriteSettings
                { writeProvider = settings
                , writeWalletKey = skey
                , writeConfirmTimeout = confirmationTimeout
                }
    -- --key is the text of the key and --key-hex its base16: one of the two,
    -- read by the library, so no command keeps a decoder of its own.
    keyFrom flags = case [ (encoding, argument)
                         | (flag, encoding) <- keyFlags
                         , Just argument <- [optional flag flags]
                         ] of
        [(KeyText, argument)]
            | any isSurrogate argument ->
                Left
                    ( BadValue
                        "--key"
                        "is not text in this locale's encoding: run under a UTF-8 locale, or spell the bytes with --key-hex"
                    )
            | otherwise -> readKeyAs KeyText argument
        [(KeyHex, argument)] -> readKeyAs KeyHex argument
        [] -> Left (MissingFlag "--key")
        _ -> Left (BadValue "--key-hex" "excludes --key: name the key once")
    readKeyAs encoding argument =
        Key <$> first KeyRefused (readKey encoding (T.pack argument))
    isSurrogate c = generalCategory c == Surrogate
    required name flags = case lookup name flags of
        Just (Just v) -> Right v
        _ -> Left (MissingFlag name)
    optional name flags = case lookup name flags of
        Just (Just v) -> Just v
        _ -> Nothing

{- | The packaged entry point also refuses obsolete environment settings
before any token/key file is read or any provider effect is run.
-}
parseCommandWithEnvironment
    :: [(String, String)] -> [String] -> Either CLIError Command
parseCommandWithEnvironment environment args = do
    when (isJust (lookup "SINGULAR_NODE_SOCKET" environment)) $
        Left (RemovedSetting "SINGULAR_NODE_SOCKET")
    parseCommand args

{- | A whole command line: the command, and the tracing it asks for with
@--trace@, @--trace-to@ and @--trace-format@. Every command takes the three.
-}
parseInvocation
    :: [(String, String)]
    -> [String]
    -> Either CLIError (Command, TraceRequest)
parseInvocation environment args = do
    (rest, request) <- tracingFlags args
    command <- parseCommandWithEnvironment environment rest
    pure (command, request)

{- | Take the tracing flags out of a command line, each value read and
refused at parse: @--trace@ and @--trace-format@ once (the first occurrence
wins, as for every flag), @--trace-to@ once per sink, in order. A value flag
keeps its value, so a value spelled like a tracing flag stays a value.
-}
tracingFlags :: [String] -> Either CLIError ([String], TraceRequest)
tracingFlags = go [] noTraceRequest
  where
    go kept asked = \case
        [] ->
            Right
                (reverse kept, asked{requestSinks = reverse (requestSinks asked)})
        a : rest
            | name `elem` ["--trace", "--trace-to", "--trace-format"] ->
                case (inline, rest) of
                    ('=' : v, _) -> withValue name v asked >>= \r -> go kept r rest
                    (_, v : rest') -> withValue name v asked >>= \r -> go kept r rest'
                    (_, []) -> Left (BadValue name "needs a value")
            | name `elem` valuedFlags
            , null inline
            , v : rest' <- rest ->
                go (v : a : kept) asked rest'
            | otherwise -> go (a : kept) asked rest
          where
            (name, inline) = break (== '=') a
    withValue name v asked = case name of
        "--trace" -> case v of
            "off" -> level TraceOff
            "what" -> level TraceWhat
            "how" -> level TraceHow
            _ -> Left (BadValue name "is off, what or how")
        "--trace-to" -> case v of
            "stderr" -> sink ToStderr
            'f' : 'i' : 'l' : 'e' : ':' : path@(_ : _) -> sink (ToFile path)
            _ -> Left (BadValue name "is stderr or file:PATH")
        _ -> case v of
            "text" -> format TextFormat
            "json" -> format JsonFormat
            _ -> Left (BadValue name "is text or json")
      where
        level l = Right asked{requestLevel = requestLevel asked <|> Just l}
        sink s = Right asked{requestSinks = s : requestSinks asked}
        format f = Right asked{requestFormat = requestFormat asked <|> Just f}

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
            in  if name `elem` ["--backend", "--node-socket"]
                    then Left (RemovedSetting name)
                    else
                        if name `elem` switches
                            then go ws ((name, Nothing) : fs) rest
                            else
                                if name `elem` valuedFlags
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

-- | The flags that take a value: the next token, or their @=value@ spelling.
valuedFlags :: [String]
valuedFlags =
    [ "--registry"
    , "--blueprint"
    , "--koios-url"
    , "--koios-token-file"
    , "--network-time"
    , "--network-magic"
    , "--wallet-skey"
    , "--seed"
    , "--process-time"
    , "--retract-time"
    , "--key"
    , "--key-hex"
    , "--receipt"
    , "--confirm-timeout"
    , "--wallet-address"
    , "--outputs-at"
    , "--fund-input"
    , "--max-outlay"
    , "--deposit"
    , "--payload"
    , "--request"
    ]

-- | One line naming the refusal.
renderCLIError :: CLIError -> String
renderCLIError = \case
    RemovedSetting name ->
        name
            <> " was removed: singular uses Koios through --koios-url and optional --koios-token-file"
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
    DepositRefused DepositNotInteger ->
        "--deposit is not a whole number of lovelace"
    DepositRefused (DepositBelowMinimum n) ->
        "--deposit "
            <> show n
            <> " is below the minimum of "
            <> show minimumDeposit
            <> " lovelace"
    UnsafeSettings why -> why
    SigningKeyNotAccepted ->
        "inspect takes no signing key: it reads, and never funds or submits"
    PreviewTakesNoKey ->
        "--preview takes no signing key: name the caller with --wallet-address; a preview reads, and never signs or submits"
    UnsupportedFlag flag command ->
        flag
            <> " is not accepted by `registry "
            <> command
            <> "`: only insert, update, terminate, fold, reclaim and reject enforce it, and a constraint the command does not enforce is refused, never ignored"

-- | The supported commands.
usage :: String
usage =
    unlines
        [ "usage:"
        , "  singular registry create --registry DIR --blueprint PLUTUS_JSON"
        , "      (--seed TXID#IX | --preview) [--process-time MS] [--retract-time MS]"
        , "      --koios-url URL --network-magic N --wallet-skey FILE [--receipt FILE]"
        , "  singular registry create --preview --registry DIR --blueprint PLUTUS_JSON"
        , "      [--seed TXID#IX] [--process-time MS] [--retract-time MS]"
        , "      --koios-url URL --network-magic N --wallet-address ADDR"
        , "  singular registry insert --registry DIR --blueprint PLUTUS_JSON (--key KEY | --key-hex HEX)"
        , "      --payload DATUM_JSON [--deposit LOVELACE]"
        , "      --koios-url URL --network-magic N --wallet-skey FILE [--receipt FILE]"
        , "      [--fund-input TXID#IX] [--max-outlay LOVELACE] [--fold]"
        , "  singular registry insert --preview --registry DIR --blueprint PLUTUS_JSON"
        , "      (--key KEY | --key-hex HEX) --payload DATUM_JSON [--deposit LOVELACE]"
        , "      --koios-url URL --network-magic N --wallet-address ADDR"
        , "      [--fund-input TXID#IX] [--max-outlay LOVELACE]"
        , "  singular registry update --registry DIR --blueprint PLUTUS_JSON (--key KEY | --key-hex HEX)"
        , "      --payload DATUM_JSON"
        , "      --koios-url URL --network-magic N --wallet-skey FILE [--receipt FILE]"
        , "      [--fund-input TXID#IX] [--max-outlay LOVELACE]"
        , "  singular registry update --preview --registry DIR --blueprint PLUTUS_JSON"
        , "      (--key KEY | --key-hex HEX) --payload DATUM_JSON"
        , "      --koios-url URL --network-magic N --wallet-address ADDR"
        , "      [--fund-input TXID#IX] [--max-outlay LOVELACE]"
        , "  singular registry terminate --registry DIR --blueprint PLUTUS_JSON (--key KEY | --key-hex HEX)"
        , "      --koios-url URL --network-magic N --wallet-skey FILE [--receipt FILE]"
        , "      [--fund-input TXID#IX] [--max-outlay LOVELACE] [--fold]"
        , "  singular registry terminate --preview --registry DIR --blueprint PLUTUS_JSON"
        , "      (--key KEY | --key-hex HEX)"
        , "      --koios-url URL --network-magic N --wallet-address ADDR"
        , "      [--fund-input TXID#IX] [--max-outlay LOVELACE]"
        , "  singular registry fold --registry DIR --blueprint PLUTUS_JSON"
        , "      --koios-url URL --network-magic N --wallet-skey FILE [--receipt FILE]"
        , "      [--request TXID#IX] [--fund-input TXID#IX] [--max-outlay LOVELACE]"
        , "  singular registry reclaim --registry DIR --blueprint PLUTUS_JSON --request TXID#IX"
        , "      --koios-url URL --network-magic N --wallet-skey FILE [--receipt FILE]"
        , "      [--fund-input TXID#IX] [--max-outlay LOVELACE]"
        , "  singular registry reject --registry DIR --blueprint PLUTUS_JSON"
        , "      --koios-url URL --network-magic N --wallet-skey FILE [--receipt FILE]"
        , "      [--fund-input TXID#IX] [--max-outlay LOVELACE]"
        , "  singular registry inspect --registry DIR --blueprint PLUTUS_JSON (--key KEY | --key-hex HEX)"
        , "      --koios-url URL --network-magic N [--receipt FILE] [--outputs-at ADDR]"
        , ""
        , "create takes positive integer windows in milliseconds. Its processing window"
        , "defaults to 600000 (ten minutes), its retract window to 300000 (five minutes). Both are fixed"
        , "for the life of the registry; create and inspect report them from the state datum."
        , "Write commands also take --confirm-timeout SECONDS (default 600): past it"
        , "the command stops with its submission journalled and never resubmits."
        , "Every command uses Koios; former backend selectors and socket settings are refused."
        , "Every command also takes --koios-token-file FILE for a bearer credential;"
        , "the shared HTTP client reads it without exposing a command-line token."
        , "Every command also takes --network-time DIR for pinned time-manifest.json,"
        , "shelley-genesis.json and era-history.cbor; preprod uses the package when omitted."
        , "Every command also takes --trace off|what|how, --trace-to stderr|file:PATH and --trace-format text|json:"
        , "it narrates its protocol steps, and at how their mechanics, to each sink named, the"
        , "option repeated per sink, or to standard error. With no level named it narrates what"
        , "on a terminal and nothing otherwise; text goes to standard error and JSON lines to a"
        , "file unless a format is named. Standard output carries the receipt alone."
        , "insert and terminate book the request and leave it pending: the registry's"
        , "fold is its own command, registry fold, run by whichever wallet folds, before"
        , "the processing deadline the booking's receipt names. Given the fold switch,"
        , "either also folds, in the same command, once its booking confirms."
        , "reclaim takes back the owner's pending insertion or terminal-witness request,"
        , "inside its retract window: the view's tip must reach the converted processing"
        , "deadline; a converted retract deadline must still be ahead of the tip. An"
        , "unconverted retract deadline stays open; an unconverted processing deadline"
        , "does not prove opening. No host clock decides the window. The locked lovelace"
        , "returns to the owner in one request-bound output; the root does not move."
        , "An early refusal names when it opens; once closed, registry reject clears it."
        , "reject clears the registry's pending requests, all or none: it is built only"
        , "once every pending request is past both its windows, the processing window and"
        , "the retract window after it, and until then it is refused, naming each request"
        , "and when its retract window closes. Each owner is refunded the request's value"
        , "less the tip in the one output designated for it; the wallet that runs it keeps"
        , "the tip, and the registry's root does not move."
        , "insert, update, terminate, fold, reclaim and reject fund and collateralise from the funding"
        , "input named, and hold to the maximum outlay stated: a booking, update, reclaim, reject or"
        , "fold past it is not signed, and a combined insert or terminate whose fold,"
        , "built after its booking confirms, costs more than the booking left of it stops"
        , "partial, its request pending, with the fold unsigned. create and inspect"
        , "refuse both settings: they enforce neither."
        , "The preview forms name the caller by a public wallet address instead of a"
        , "signing key: they build and measure what they would submit, print it, and"
        , "sign, submit and journal nothing."
        , "A registry key is 1 to 32 bytes: KEY is read as text, its UTF-8 bytes, and HEX as"
        , "base16. A key is named once, by one of the two."
        , "inspect also lists the registry's pending requests with what each actually locks,"
        , "and the outputs at a public address it is given: reads apart from any write."
        , "Each command prints one JSON receipt on standard output. inspect reads"
        , "only: it takes no signing key and submits nothing."
        ]
