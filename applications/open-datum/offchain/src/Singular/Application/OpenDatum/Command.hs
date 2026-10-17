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
    , openDatumVersion
    , openDatumHint
    , openDatumRefusalHint
    , parseOpenDatumCommand
    , parseOpenDatumCommandWithEnvironment
    , parseOpenDatumInvocation
    , parseOpenDatumInvocationFrom
    , loadOpenDatumSources
    , parseOpenDatumWithGroup
    , renderCLIError
    , openDatumUsage
    , openDatumHelp
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
import Data.List (partition)
import Data.Maybe (isJust)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Version (Version)
import GHC.Generics (Generic)
import Text.Read (readMaybe)

import Paths_open_datum qualified as Paths
import Singular.Application.OpenDatum.Build
    ( DepositRefusal (..)
    , minimumDeposit
    , readDeposit
    )
import Singular.Application.OpenDatum.Help (openDatumProgram)
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
    , commonSwitches
    , parseFlagGroup
    , readProviderSettings
    , traceFlags
    , traceRequestFrom
    )
import Singular.CLI.Key
    ( KeyEncoding (..)
    , KeyRefusal (..)
    , keyFlags
    , maxKeyBytes
    , readKey
    )
import Singular.CLI.Options
    ( Accepted (..)
    , Raw (..)
    , helpText
    , hintLines
    , identityLine
    , readLine
    , refusalAs
    , resolvePath
    )
import Singular.CLI.Registry (shippedProcessTime, shippedRetractTime)
import Singular.CLI.Sources
    ( Sources (..)
    , applySources
    , loadSources
    , missingHint
    , noSources
    )
import Singular.CLI.Trace (TraceRequest (..))
import Singular.CLI.Version (releaseVersion)
import Singular.Registry.Deployment (parseOutRef)
import Singular.Registry.ProviderSettings (ProviderSettings (..))
import Singular.Registry.StateToken
    ( ReferenceRole (..)
    , parseStateToken
    )

-- | One parsed open-datum command line.
data OpenDatumCommand
    = {- | A help page or the version line, to print as it stands: the command
      line asked for it, so nothing else runs
      -}
      OpenHelp String
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
    | -- | the config file cannot be used, said in one sentence
      ConfigRefused String
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

{- | Parse a command line with its environment over an explicit flag group:
the tokenizer reads exactly these valued flags. The exported parser applies
this to the common group (this binary owns no valued flag beyond it).
-}
parseOpenDatumWithGroup
    :: [String]
    -> [(String, String)]
    -> [String]
    -> Either CLIError OpenDatumCommand
parseOpenDatumWithGroup group environment args =
    readFlags group args
        >>= commandFrom environment
            . applySources
                (openDatumProgram openDatumVersion)
                (noSources environment)

{- | Read a command line over the valued flags this binary owns, with the
switches every binary reads and the closed switch. The reading is the
library's; what a flag means, and which command refuses it, is the command's.
-}
readFlags :: [String] -> [String] -> Either CLIError Raw
readFlags group =
    first (refusalAs RemovedSetting BadValue "singular")
        . readLine
            Accepted
                { acceptedValued = group <> ["--config"]
                , acceptedEarly = []
                , acceptedSwitches = commonSwitches <> [closedSwitch, "--version"]
                }

{- | What a command line read flat asks for. The switches are taken out of
the flags, which keep their first occurrence first, as the commands read them.
-}
commandFrom
    :: [(String, String)] -> Raw -> Either CLIError OpenDatumCommand
commandFrom environment (Raw ws allFlags) = do
    let hasClosed = any ((== closedSwitch) . fst) allFlags
        flags =
            [ flag
            | flag@(name, _) <- allFlags
            , name `notElem` [closedSwitch, "--version", "--config"]
            ]
        askedFor =
            OpenHelp
                ( helpText
                    (openDatumProgram openDatumVersion)
                    environment
                    ( fst
                        ( resolvePath
                            (openDatumProgram openDatumVersion)
                            (dropWhile (== "open-datum") ws)
                        )
                    )
                )
    -- #528 slice 4: the packaged `open-datum` binary is invoked as
    -- `open-datum create|insert|...` (program plus a bare verb, as its
    -- usage, DEMO1.md and the journey all spell it). Accept that bare
    -- spelling alongside the namespaced `open-datum create|...` form the
    -- shared parser also recognises, normalising before every check so
    -- the create-only windows and the inspect-only `--outputs-at` keep
    -- their exact scope on both spellings.
    let words'' = case ws of
            ["create"] -> ["open-datum", "create"]
            ["insert"] -> ["open-datum", "insert"]
            ["update"] -> ["open-datum", "update"]
            ["terminate"] -> ["open-datum", "terminate"]
            ["fold"] -> ["open-datum", "fold"]
            ["inspect"] -> ["open-datum", "inspect"]
            _ -> ws
    if "--help" `elem` map fst flags
        then Right askedFor
        else
            if any ((== "--version") . fst) allFlags
                then
                    Right
                        ( OpenHelp
                            (identityLine (openDatumProgram openDatumVersion) environment <> "\n")
                        )
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
                                [] -> Right askedFor
                                ["open-datum"] -> Right askedFor
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
                                _ -> Left (UnknownCommand ws)
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
parseOpenDatumCommandWithEnvironment environment args =
    refuseObsoleteEnvironment environment
        >> parseOpenDatumWith environment args

refuseObsoleteEnvironment :: [(String, String)] -> Either CLIError ()
refuseObsoleteEnvironment environment =
    when (isJust (lookup "SINGULAR_NODE_SOCKET" environment)) $
        Left (RemovedSetting "SINGULAR_NODE_SOCKET")

{- | A whole command line: the command, and the tracing it asks for with
@--trace@, @--trace-to@ and @--trace-format@. Every command takes the three.
-}
parseOpenDatumInvocation
    :: [(String, String)]
    -> [String]
    -> Either CLIError (OpenDatumCommand, TraceRequest)
parseOpenDatumInvocation = parseOpenDatumInvocationFrom . noSources

{- | The same over the settings the environment and the config file give: a
setting the command line leaves out is read from the environment, then from
the file. A file that cannot be used is refused for a command that runs, and
ignored for a request for help.
-}
parseOpenDatumInvocationFrom
    :: Sources
    -> [String]
    -> Either CLIError (OpenDatumCommand, TraceRequest)
parseOpenDatumInvocationFrom sources args = do
    raw <- readFlags invocationFlags args
    let environment = sourceEnvironment sources
        filled = applySources (openDatumProgram openDatumVersion) sources raw
        (tracing, rest) =
            partition ((`elem` traceFlags) . fst) (rawFlags filled)
    request <-
        traceRequestFrom BadValue [(name, v) | (name, Just v) <- tracing]
    refuseObsoleteEnvironment environment
    command <- case ( commandFrom environment filled{rawFlags = rest}
                    , sourceConfig sources
                    ) of
        (Right help@(OpenHelp _), _) -> Right help
        (_, Left why) -> Left (ConfigRefused why)
        (result, Right _) -> result
    pure (command, request)

-- | The settings the environment and the config file give for a command line.
loadOpenDatumSources :: [(String, String)] -> [String] -> IO Sources
loadOpenDatumSources environment args =
    case readFlags invocationFlags args of
        Right raw -> loadSources (openDatumProgram openDatumVersion) environment raw
        Left _ -> pure (noSources environment)

-- | The valued flags a whole command line carries.
invocationFlags :: [String]
invocationFlags = commonFlagGroup <> extraValuedFlags <> traceFlags

-- | The valued flags this binary owns beyond the common group: none.
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
    ConfigRefused why -> why
    UnsupportedFlag flag command ->
        flag
            <> " is not accepted by `open-datum "
            <> command
            <> "`: only insert, update, terminate and fold enforce it, and a constraint the command does not enforce is refused, never ignored"

-- | The overview of the supported commands: the page `open-datum --help` prints.
openDatumUsage :: String
openDatumUsage = helpText (openDatumProgram openDatumVersion) [] []

-- | The help page of a command, for no environment: the overview for no path.
openDatumHelp :: [String] -> String
openDatumHelp = helpText (openDatumProgram openDatumVersion) []

-- | The version the program was built as.
openDatumVersion :: Version
openDatumVersion = releaseVersion Paths.version

{- | What a refused command line adds below the refusal: the nearest command
when a word was mistyped, the usage of the command it was heading for and
where its help is.
-}
openDatumHint :: [String] -> [String]
openDatumHint line =
    hintLines
        (openDatumProgram openDatumVersion)
        (either (const line) rawWords (readFlags invocationFlags line))

{- | What a refusal says below its line: for a missing standing setting, the
three ways to give it.
-}
openDatumRefusalHint :: CLIError -> [String]
openDatumRefusalHint = \case
    MissingFlag name -> missingHint (openDatumProgram openDatumVersion) name
    _ -> []

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
    OpenHelp _ -> Set.empty
  where
    everything = Set.fromList [minBound .. maxBound]
