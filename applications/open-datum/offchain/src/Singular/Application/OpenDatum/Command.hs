{-# LANGUAGE LambdaCase #-}

{- |
Module      : Singular.Application.OpenDatum.Command
Description : What an @open-datum@ command line asks for, parsed without effects
License     : Apache-2.0

The open-datum commands and help, read from the command line alone:
no file, node, key or environment is touched here, so every refusal
below happens before anything is read or submitted.

* @open-datum create@ boots one registry from a seed the caller chose in
  their own wallet, or previews its identity with @--preview@;
* @open-datum insert@ books one @insertActive@ at a key and
* @open-datum terminate@ books one @updateTerminal@ at a key, each leaving
  its request pending for the registry's fold; with @--fold@ either
  also folds it in the same command;
* @open-datum fold@ takes the selection and folds every included request, signed and funded by
  the wallet that runs it;
* @open-datum inspect@ reads the registry and one key back, and accepts
  no signing key at all.

Write commands name the Koios URL, network and wallet key. Partial settings
and mainnet are refused before file reads or provider effects. Read commands
carry a public wallet address instead of a signing key. Obsolete backend and
socket settings are refused on every command, including --backend koios.
-}
module Singular.Application.OpenDatum.Command
    ( -- * Commands
      OpenDatumCommand (..)
    , CreateArgs (..)
    , EntryArgs (..)
    , EntryMode (..)
    , FoldArgs (..)
    , InspectArgs (..)
    , ProviderSettings (..)
    , Signer (..)
    , WriteSettings (..)
    , RegistryAccess (..)
    , Key (..)
    , neededRoles

      -- * Parsing
    , CLIError (..)
    , closedSwitch
    , parseOpenDatumCommand
    , parseOpenDatumCommandWithEnvironment
    , parseOpenDatumInvocation
    , parseOpenDatumWithGroup
    , renderCLIError
    , openDatumUsage
    , maxKeyBytes
    , keyFlags
    ) where

import Control.Monad (forM_, unless, when)
import Data.Bifunctor (first)
import Data.Char
    ( GeneralCategory (Surrogate)
    , generalCategory
    , isDigit
    )
import Data.Maybe (isJust)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text qualified as T
import GHC.Generics (Generic)
import Text.Read (readMaybe)

import Singular.Application.OpenDatum.Build
    ( DepositRefusal (..)
    , minimumDeposit
    , readDeposit
    )
import Singular.Application.OpenDatum.Value (Mode (..))
import Singular.CLI.Command
    ( CreateArgs (..)
    , EntryArgs (..)
    , EntryMode (..)
    , FoldArgs (..)
    , InspectArgs (..)
    , Key (..)
    , RegistryAccess (..)
    , WriteSettings (..)
    )
import Singular.CLI.FlagGroup
    ( Signer (..)
    , commonFlagGroup
    , parseFlagGroup
    , readProviderSettings
    , splitTracingFor
    , tokenizeWith
    )
import Singular.CLI.Key
    ( KeyEncoding (..)
    , KeyRefusal (..)
    , keyFlags
    , maxKeyBytes
    , readKey
    )
import Singular.CLI.Registry (shippedProcessTime, shippedRetractTime)
import Singular.CLI.Trace (TraceRequest (..))
import Singular.Registry.Deployment (parseOutRef)
import Singular.Registry.ProviderSettings (ProviderSettings (..))
import Singular.Registry.StateToken
    ( ReferenceRole (..)
    , parseStateToken
    )

-- | One parsed open-datum command line.
data OpenDatumCommand
    = OpenHelp
    | OpenCreate Mode CreateArgs
    | OpenInsert EntryArgs
    | OpenUpdate EntryArgs
    | OpenTerminate EntryArgs
    | OpenFold FoldArgs
    | OpenInspect InspectArgs
    deriving stock (Eq, Show, Generic)

-- | Why an open-datum command line was refused before anything ran.
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

-- | Parse a command line.
parseOpenDatumCommand :: [String] -> Either CLIError OpenDatumCommand
parseOpenDatumCommand = parseOpenDatumWith []

-- | Parse a command line with its environment.
parseOpenDatumWith
    :: [(String, String)] -> [String] -> Either CLIError OpenDatumCommand
parseOpenDatumWith = parseOpenDatumWithGroup (commonFlagGroup <> extraValuedFlags)

-- | The closed switch: chosen at create, read from the chain after.
closedSwitch :: String
closedSwitch = "--closed"

{- | Split the closed switch out before the shared tokenizer, skipping the
value of a valued flag so a key whose text is the switch stays a key.
-}
splitClosed :: [String] -> [String] -> ([String], Bool)
splitClosed valued = go [] False
  where
    go kept closed [] = (reverse kept, closed)
    go kept closed (a : rest)
        | isValuedNoEquals a = case rest of
            (v : rest') -> go (v : a : kept) closed rest'
            [] -> go (a : kept) closed []
        | name == "--closed" = go kept True rest
        | otherwise = go (a : kept) closed rest
      where
        (name, _) = break (== '=') a
        isValuedNoEquals tok =
            let (n, i) = break (== '=') tok
            in  null i && n `elem` valued

{- | Parse a command line with its environment over an explicit flag group:
the tokenizer reads exactly these valued flags. The exported parser applies
this to the common group (this binary owns no valued flag beyond it).
-}
parseOpenDatumWithGroup
    :: [String]
    -> [(String, String)]
    -> [String]
    -> Either CLIError OpenDatumCommand
parseOpenDatumWithGroup group environment args = do
    let (argsNoClosed, hasClosed) = splitClosed group args
    (words', flags) <-
        tokenizeWith RemovedSetting BadValue group argsNoClosed
    -- #528 slice 4: the packaged `open-datum` binary is invoked as
    -- `open-datum create|insert|...` (program plus a bare verb, as its
    -- usage, DEMO1.md and the journey all spell it). Accept that bare
    -- spelling alongside the namespaced `open-datum create|...` form the
    -- shared parser also recognises, normalising before every check so
    -- the create-only windows and the inspect-only `--outputs-at` keep
    -- their exact scope on both spellings.
    let words'' = case words' of
            ["create"] -> ["open-datum", "create"]
            ["insert"] -> ["open-datum", "insert"]
            ["update"] -> ["open-datum", "update"]
            ["terminate"] -> ["open-datum", "terminate"]
            ["fold"] -> ["open-datum", "fold"]
            ["inspect"] -> ["open-datum", "inspect"]
            _ -> words'
    if "--help" `elem` map fst flags || "-h" `elem` map fst flags
        then Right OpenHelp
        else
            if hasClosed
                then case words'' of
                    ["open-datum", "create"] ->
                        refuseWindows words'' flags
                            >> refuseOutputsAt words'' flags
                            >> refuseSpendingFlags "create" flags
                            >> refuseRequest flags
                            >> refuseFold flags
                            >> (OpenCreate Closed <$> createArgs flags)
                    _ ->
                        Left
                            ( BadValue
                                "--closed"
                                "is an open-datum create flag: a registry's mode is chosen at create and read from the chain by every later command"
                            )
                else
                    refuseWindows words'' flags >> refuseOutputsAt words'' flags >> case words'' of
                        [] -> Right OpenHelp
                        ["open-datum"] -> Right OpenHelp
                        ["open-datum", "create"] ->
                            refuseSpendingFlags "create" flags
                                >> refuseRequest flags
                                >> refuseFold flags
                                >> (OpenCreate Open <$> createArgs flags)
                        ["open-datum", "insert"] ->
                            refuseRequest flags >> (OpenInsert <$> insertArgs environment flags)
                        ["open-datum", "update"] ->
                            refuseRequest flags
                                >> refuseDeposit flags
                                >> (OpenUpdate <$> entryArgs False (Just "--payload") environment flags)
                        ["open-datum", "terminate"] ->
                            refuseRequest flags
                                >> refuseDeposit flags
                                >> (OpenTerminate <$> entryArgs True Nothing environment flags)
                        ["open-datum", "fold"] -> OpenFold <$> foldArgs environment flags
                        ["open-datum", "inspect"] ->
                            refuseSpendingFlags "inspect" flags
                                >> refuseRequest flags
                                >> refuseFold flags
                                >> (OpenInspect <$> inspectArgs environment flags)
                        _ -> Left (UnknownCommand words')
  where
    refuseWindows words' flags =
        unless (words' == ["open-datum", "create"])
            $ forM_
                [ ("--process-time", "windows are fixed for the life of a registry")
                , ("--retract-time", "windows are fixed for the life of a registry")
                ,
                    ( "--registration-cost"
                    , "the registration cost is fixed for the life of a registry"
                    )
                ,
                    ( "--booking-width"
                    , "the widest booking interval is fixed for the life of a registry"
                    )
                ]
            $ \(flag, why) ->
                when (isJust (lookup flag flags)) $
                    Left (BadValue flag ("is an open-datum create flag: " <> why))
    -- The constraints on a write's spending belong to insert, update and
    -- terminate. A command that does not enforce one refuses it by name rather
    -- than discard what the caller stated.
    refuseSpendingFlags command flags =
        forM_ ["--fund-input", "--max-outlay"] $ \flag ->
            when (isJust (lookup flag flags)) $
                Left (UnsupportedFlag flag command)
    -- @--outputs-at@ is read by @open-datum inspect@ alone; any other command
    -- refuses it by name rather than ignore it.
    refuseOutputsAt words' flags =
        when
            ( isJust (lookup "--outputs-at" flags)
                && words' /= ["open-datum", "inspect"]
            )
            $ Left
                ( BadValue
                    "--outputs-at"
                    "is an open-datum inspect flag: only inspect reads another address's outputs"
                )
    -- @--request@ names what @open-datum fold@ folds; @--fold@ belongs to the
    -- two commands that book. Any other command refuses either by name.
    refuseRequest flags =
        when (isJust (lookup "--request" flags)) $
            Left
                ( BadValue
                    "--request"
                    "names the pending request @open-datum fold@ folds; this command takes none"
                )
    refuseFold flags =
        when (isJust (lookup "--fold" flags)) $
            Left
                ( BadValue
                    "--fold"
                    "is taken by insert and terminate only: they book, and with it also fold"
                )
    createArgs flags = do
        when (isJust (lookup "--state-token" flags)) $
            Left
                ( BadValue
                    "--state-token"
                    "is refused by open-datum create, which makes one"
                )
        processing <-
            windowFrom "--process-time" shippedProcessTime flags
        retracting <-
            windowFrom "--retract-time" shippedRetractTime flags
        cost <- registrationCostFrom flags
        width <- bookingWidthFrom flags
        let dir = optional "--state-dir" flags
        bp <- required "--blueprint" flags
        let preview = isJust (lookup "--preview" flags)
            publicPreview = preview && isJust (lookup "--wallet-address" flags)
        mode <-
            if publicPreview
                then previewMode flags
                else
                    Submit
                        <$> parseFlagGroup
                            MissingFlag
                            BadValue
                            UnsafeSettings
                            WriteSettings
                            flags
        -- No `--seed` flag auto-selects (#406 slice 2): the largest ada-only
        -- output with a live carrier, else the first publication's change.
        seed <- case lookup "--seed" flags of
            Just (Just s) -> case parseOutRef (T.pack s) of
                Right _ -> Right (Just s)
                Left err -> Left (BadValue "--seed" err)
            _ -> Right Nothing
        pure
            CreateArgs
                { createStateDir = dir
                , createBlueprint = bp
                , createMode = mode
                , createSeed = seed
                , createPreview = preview
                , createReceipt = optional "--receipt" flags
                , createProcessTime = processing
                , createRetractTime = retracting
                , createRegistrationCost = cost
                , createBookingWidth = width
                }
    registrationCostFrom flags = case optional "--registration-cost" flags of
        Nothing -> Left (MissingFlag "--registration-cost")
        Just value -> case readMaybe value of
            Just n | n >= 0 && all isDigit value -> Right n
            _ ->
                Left
                    ( BadValue
                        "--registration-cost"
                        "needs a non-negative integer number of lovelace"
                    )
    bookingWidthFrom flags = case optional "--booking-width" flags of
        Nothing -> Left (MissingFlag "--booking-width")
        Just value -> case readMaybe value of
            Just n | n > 0 && all isDigit value -> Right n
            _ ->
                Left
                    ( BadValue
                        "--booking-width"
                        "needs a positive integer number of milliseconds"
                    )
    windowFrom name fallback flags = case optional name flags of
        Nothing -> Right fallback
        Just value -> case readMaybe value of
            Just n | n > 0 && all isDigit value -> Right n
            _ ->
                Left (BadValue name "needs a positive integer number of milliseconds")
    -- An insert is an entry command that also names the deposit its envelope
    -- protects: --deposit LOVELACE, else the minimum, read by the library.
    insertArgs env flags = do
        parsed <- entryArgs True (Just "--payload") env flags
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
                    "is an open-datum insert flag: only insert sets a deposit"
                )
    entryArgs books document env flags = do
        let dir = optional "--state-dir" flags
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
        -- The signer is the shared write reader's to judge here: an
        -- address may name an external signer with its bundle file, and
        -- the mixtures are refused by the reader below, before anything
        -- is read.
        mode <-
            if isJust (lookup "--preview" flags)
                then previewMode flags
                else
                    Submit
                        <$> parseFlagGroup
                            MissingFlag
                            BadValue
                            UnsafeSettings
                            WriteSettings
                            flags
        doc <- traverse (`required` flags) document
        fund <- fundFrom flags
        outlay <- outlayFrom flags
        access <- registryAccess env flags
        pure
            EntryArgs
                { entryStateDir = dir
                , entryAccess = access
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
    foldArgs env flags = do
        let dir = optional "--state-dir" flags
        bp <- required "--blueprint" flags
        forM_
            (map fst keyFlags <> ["--deposit", "--payload", "--preview", "--fold"])
            $ \flag ->
                when (isJust (lookup flag flags)) $
                    Left
                        ( BadValue
                            flag
                            "is not accepted by open-datum fold: it folds the pending request, whose key and edge the request names"
                        )
        -- The signer is the shared write reader's to judge, as for the
        -- entry writes: an address with its bundle file names an external
        -- signer, and the mixtures are refused by the reader below.
        settings <-
            parseFlagGroup
                MissingFlag
                BadValue
                UnsafeSettings
                WriteSettings
                flags
        request <- case optional "--request" flags of
            Nothing -> Right Nothing
            Just s -> case parseOutRef (T.pack s) of
                Right i -> Right (Just i)
                Left err -> Left (BadValue "--request" err)
        fund <- fundFrom flags
        outlay <- outlayFrom flags
        access <- registryAccess env flags
        pure
            FoldArgs
                { foldStateDir = dir
                , foldAccess = access
                , foldBlueprint = bp
                , foldWrite = settings
                , foldRequest = request
                , foldFund = fund
                , foldMaxOutlay = outlay
                , foldReceipt = optional "--receipt" flags
                }
    registryAccess env flags = do
        tokenStr <- case optional "--state-token" flags of
            Just s -> Right s
            Nothing -> case lookup "SINGULAR_STATE_TOKEN" env of
                Just s -> Right s
                Nothing -> Left (MissingFlag "--state-token")
        token <-
            first
                (BadValue "--state-token" . T.unpack)
                (parseStateToken (T.pack tokenStr))
        pure RegistryAccess{accessToken = token}
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
    inspectArgs env flags = do
        when (isJust (lookup "--wallet-skey" flags)) $
            Left SigningKeyNotAccepted
        forM_ ["--vault", "--passphrase-fd"] $ \flag ->
            when (isJust (lookup flag flags)) $
                Left
                    ( BadValue
                        flag
                        ( "is not accepted by open-datum inspect: it reads, and takes the "
                            <> "address only to locate a journal"
                        )
                    )
        when (isJust (lookup "--bundle" flags)) $
            Left
                ( BadValue
                    "--bundle"
                    ( "is not accepted by open-datum inspect: it reads, and takes the "
                        <> "address only to locate a journal"
                    )
                )
        let dir = optional "--state-dir" flags
        bp <- required "--blueprint" flags
        key <- keyFrom flags
        settings <- readProviderSettings MissingFlag BadValue flags
        access <- registryAccess env flags
        pure
            InspectArgs
                { inspectStateDir = dir
                , inspectAccess = access
                , inspectBlueprint = bp
                , inspectProvider = settings
                , inspectKey = key
                , inspectOutputsAt = optional "--outputs-at" flags
                , inspectWalletAddress = optional "--wallet-address" flags
                , inspectReceipt = optional "--receipt" flags
                }
    -- A preview reads a node and names a public address; it holds no key,
    -- so a signing key is refused before anything is read, and so is the
    -- bundle file of an external signer: a preview writes nothing.
    previewMode flags = do
        when (isJust (lookup "--wallet-skey" flags)) $
            Left PreviewTakesNoKey
        forM_ ["--vault", "--passphrase-fd"] $ \flag ->
            when (isJust (lookup flag flags)) $
                Left
                    ( BadValue
                        flag
                        "cannot be used with --preview: a preview signs and writes nothing"
                    )
        when (isJust (lookup "--bundle" flags)) $
            Left
                ( BadValue
                    "--bundle"
                    "cannot be used with --preview: a preview signs and writes nothing"
                )
        settings <- readProviderSettings MissingFlag BadValue flags
        addr <- required "--wallet-address" flags
        pure (Preview settings addr)
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
parseOpenDatumCommandWithEnvironment
    :: [(String, String)] -> [String] -> Either CLIError OpenDatumCommand
parseOpenDatumCommandWithEnvironment environment args = do
    when (isJust (lookup "SINGULAR_NODE_SOCKET" environment)) $
        Left (RemovedSetting "SINGULAR_NODE_SOCKET")
    parseOpenDatumWith environment args

{- | A whole command line: the command, and the tracing it asks for with
@--trace@, @--trace-to@ and @--trace-format@. Every command takes the three.
-}
parseOpenDatumInvocation
    :: [(String, String)]
    -> [String]
    -> Either CLIError (OpenDatumCommand, TraceRequest)
parseOpenDatumInvocation environment args = do
    (rest, request) <- splitTracingFor BadValue extraValuedFlags args
    command <- parseOpenDatumCommandWithEnvironment environment rest
    pure (command, request)

{- | The tokenizing, tracing and settings readers live in the shared flag
group, called with the extras below; this parser keeps none of its own.
This binary owns no valued flag beyond the common group.
-}
extraValuedFlags :: [String]
extraValuedFlags = ["--registration-cost", "--booking-width"]

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
            <> " is not accepted by `open-datum "
            <> command
            <> "`: only insert, update, terminate and fold enforce it, and a constraint the command does not enforce is refused, never ignored"

-- | The supported commands.
openDatumUsage :: String
openDatumUsage =
    unlines
        [ "usage:"
        , "  open-datum create [--closed] [--state-dir ROOT] --blueprint PLUTUS_JSON"
        , "      [--seed TXID#IX] [--preview] [--process-time MS] [--retract-time MS]"
        , "      --registration-cost LOVELACE --booking-width MS"
        , "      --koios-url URL --network-magic N --wallet-skey FILE [--receipt FILE]"
        , "  open-datum create [--closed] [--state-dir ROOT] --blueprint PLUTUS_JSON"
        , "      [--seed TXID#IX] [--process-time MS] [--retract-time MS]"
        , "      --registration-cost LOVELACE --booking-width MS"
        , "      --koios-url URL --network-magic N --wallet-address ADDR --bundle FILE"
        , "  open-datum create [--closed] [--state-dir ROOT] --blueprint PLUTUS_JSON"
        , "      [--seed TXID#IX] [--process-time MS] [--retract-time MS]"
        , "      --registration-cost LOVELACE --booking-width MS"
        , "      --koios-url URL --network-magic N --vault FILE [--passphrase-fd FD] [--receipt FILE]"
        , "  open-datum create --preview [--closed] [--state-dir ROOT] --blueprint PLUTUS_JSON"
        , "      [--seed TXID#IX] [--process-time MS] [--retract-time MS]"
        , "      --registration-cost LOVELACE --booking-width MS"
        , "      --koios-url URL --network-magic N --wallet-address ADDR"
        , "  open-datum insert [--state-dir ROOT] --blueprint PLUTUS_JSON (--key KEY | --key-hex HEX)"
        , "      --state-token POLICY.NAME"
        , "      --payload DATUM_JSON [--deposit LOVELACE]"
        , "      --koios-url URL --network-magic N --wallet-skey FILE [--receipt FILE]"
        , "      [--fund-input TXID#IX] [--max-outlay LOVELACE] [--fold]"
        , "  open-datum insert [--state-dir ROOT] --blueprint PLUTUS_JSON (--key KEY | --key-hex HEX)"
        , "      --state-token POLICY.NAME"
        , "      --payload DATUM_JSON [--deposit LOVELACE]"
        , "      --koios-url URL --network-magic N --wallet-address ADDR --bundle FILE"
        , "      [--fund-input TXID#IX] [--max-outlay LOVELACE] [--fold]"
        , "  open-datum insert [--state-dir ROOT] --blueprint PLUTUS_JSON (--key KEY | --key-hex HEX)"
        , "      --state-token POLICY.NAME"
        , "      --payload DATUM_JSON [--deposit LOVELACE]"
        , "      --koios-url URL --network-magic N --vault FILE [--passphrase-fd FD] [--receipt FILE]"
        , "      [--fund-input TXID#IX] [--max-outlay LOVELACE] [--fold]"
        , "  open-datum insert --preview [--state-dir ROOT] --blueprint PLUTUS_JSON"
        , "      --state-token POLICY.NAME"
        , "      (--key KEY | --key-hex HEX) --payload DATUM_JSON [--deposit LOVELACE]"
        , "      --koios-url URL --network-magic N --wallet-address ADDR"
        , "      [--fund-input TXID#IX] [--max-outlay LOVELACE]"
        , "  open-datum update [--state-dir ROOT] --blueprint PLUTUS_JSON (--key KEY | --key-hex HEX)"
        , "      --state-token POLICY.NAME"
        , "      --payload DATUM_JSON"
        , "      --koios-url URL --network-magic N --wallet-skey FILE [--receipt FILE]"
        , "      [--fund-input TXID#IX] [--max-outlay LOVELACE]"
        , "  open-datum update [--state-dir ROOT] --blueprint PLUTUS_JSON (--key KEY | --key-hex HEX)"
        , "      --state-token POLICY.NAME"
        , "      --payload DATUM_JSON"
        , "      --koios-url URL --network-magic N --wallet-address ADDR --bundle FILE"
        , "      [--fund-input TXID#IX] [--max-outlay LOVELACE]"
        , "  open-datum update [--state-dir ROOT] --blueprint PLUTUS_JSON (--key KEY | --key-hex HEX)"
        , "      --state-token POLICY.NAME"
        , "      --payload DATUM_JSON"
        , "      --koios-url URL --network-magic N --vault FILE [--passphrase-fd FD] [--receipt FILE]"
        , "      [--fund-input TXID#IX] [--max-outlay LOVELACE]"
        , "  open-datum update --preview [--state-dir ROOT] --blueprint PLUTUS_JSON"
        , "      --state-token POLICY.NAME"
        , "      (--key KEY | --key-hex HEX) --payload DATUM_JSON"
        , "      --koios-url URL --network-magic N --wallet-address ADDR"
        , "      [--fund-input TXID#IX] [--max-outlay LOVELACE]"
        , "  open-datum terminate [--state-dir ROOT] --blueprint PLUTUS_JSON (--key KEY | --key-hex HEX)"
        , "      --state-token POLICY.NAME"
        , "      --koios-url URL --network-magic N --wallet-skey FILE [--receipt FILE]"
        , "      [--fund-input TXID#IX] [--max-outlay LOVELACE] [--fold]"
        , "  open-datum terminate [--state-dir ROOT] --blueprint PLUTUS_JSON (--key KEY | --key-hex HEX)"
        , "      --state-token POLICY.NAME"
        , "      --koios-url URL --network-magic N --wallet-address ADDR --bundle FILE"
        , "      [--fund-input TXID#IX] [--max-outlay LOVELACE] [--fold]"
        , "  open-datum terminate [--state-dir ROOT] --blueprint PLUTUS_JSON (--key KEY | --key-hex HEX)"
        , "      --state-token POLICY.NAME"
        , "      --koios-url URL --network-magic N --vault FILE [--passphrase-fd FD] [--receipt FILE]"
        , "      [--fund-input TXID#IX] [--max-outlay LOVELACE] [--fold]"
        , "  open-datum terminate --preview [--state-dir ROOT] --blueprint PLUTUS_JSON"
        , "      --state-token POLICY.NAME"
        , "      (--key KEY | --key-hex HEX)"
        , "      --koios-url URL --network-magic N --wallet-address ADDR"
        , "      [--fund-input TXID#IX] [--max-outlay LOVELACE]"
        , "  open-datum fold [--state-dir ROOT] --blueprint PLUTUS_JSON"
        , "      --state-token POLICY.NAME"
        , "      --koios-url URL --network-magic N --wallet-skey FILE [--receipt FILE]"
        , "      [--request TXID#IX] [--fund-input TXID#IX] [--max-outlay LOVELACE]"
        , "  open-datum fold [--state-dir ROOT] --blueprint PLUTUS_JSON"
        , "      --state-token POLICY.NAME"
        , "      --koios-url URL --network-magic N --wallet-address ADDR --bundle FILE"
        , "      [--request TXID#IX] [--fund-input TXID#IX] [--max-outlay LOVELACE]"
        , "  open-datum fold [--state-dir ROOT] --blueprint PLUTUS_JSON"
        , "      --state-token POLICY.NAME"
        , "      --koios-url URL --network-magic N --vault FILE [--passphrase-fd FD] [--receipt FILE]"
        , "      [--request TXID#IX] [--fund-input TXID#IX] [--max-outlay LOVELACE]"
        , "  open-datum inspect [--state-dir ROOT] --blueprint PLUTUS_JSON (--key KEY | --key-hex HEX)"
        , "      --state-token POLICY.NAME"
        , "      --koios-url URL --network-magic N [--receipt FILE] [--outputs-at ADDR]"
        , "      [--wallet-address ADDR]"
        , ""
        , "Every command but create names its registry by the state token POLICY.NAME,"
        , "the policy and the name in hex, which create prints; when the flag is absent"
        , "it is read from SINGULAR_STATE_TOKEN. Nothing else names a registry."
        , "No command takes a per-registry directory. Each command keeps its own"
        , "journal and submissions under a managed state directory it resolves itself:"
        , "the platform per-user state location (XDG_STATE_HOME, falling back to"
        , "$HOME/.local/state, namespace singular), partitioned by network, complete"
        , "state token and the caller's stable wallet payment identity. The same"
        , "identity reuses its journal and lock across invocations and key-file"
        , "relocation; different wallets and tokens never share one. A configured"
        , "root overrides only the default root, with the same partitioning."
        , "A command finds"
        , "the reference scripts its transactions run by hash, from the provider and then"
        , "its own wallet."
        , "create takes positive integer windows in milliseconds. Its processing window"
        , "defaults to 600000 (ten minutes), its retract window to 300000 (five minutes). Both are fixed"
        , "for the life of the registry; create and inspect report them from the state datum."
        , "create requires --registration-cost (lovelace, zero or more) and --booking-width"
        , "(milliseconds, at least one): neither has a default, and both are fixed for the life of the registry."
        , "Create takes the closed switch to boot a closed-datum registry whose payload"
        , "is written once; every later command follows the registry's mode with no"
        , "further flag, and an update on a closed registry stops before anything is"
        , "built or signed."
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
        , "insert and terminate book the request and leave it pending: the application's"
        , "fold is its own command, open-datum fold, run by whichever wallet folds, before"
        , "the processing deadline the booking's receipt names. Given the fold switch,"
        , "either also folds, in the same command, once its booking confirms."
        , "insert, update, terminate and fold fund and collateralise from the funding"
        , "input named, and hold to the maximum outlay stated: a booking, update or"
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
        , "only: it takes no signing key and submits nothing. Given a wallet address"
        , "it reconciles that caller's managed journal, as a write would; without one"
        , "it is a stateless chain read that checks no wallet journal and creates"
        , "no state."
        ]

{- | The reference roles a command's transactions run, and so the only
references it looks up.
-}
neededRoles :: OpenDatumCommand -> Set ReferenceRole
neededRoles = \case
    OpenCreate _ _ -> Set.singleton RoleState
    OpenInsert a
        | entryFold a -> everything
        | otherwise -> Set.singleton RoleApplication
    OpenUpdate _ -> Set.singleton RoleApplication
    OpenTerminate a
        | entryFold a -> everything
        | otherwise -> Set.singleton RoleApplication
    OpenFold _ -> everything
    OpenInspect _ -> Set.empty
    OpenHelp -> Set.empty
  where
    everything = Set.fromList [minBound .. maxBound]
