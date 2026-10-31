{-# LANGUAGE LambdaCase #-}

{- |
Module      : Singular.Application.OpenDatum.Command
Description : What an @open-datum@ command line asks for, parsed without effects
License     : Apache-2.0

The open-datum commands and help, read from the command line alone:
no file, node, key or environment is touched here, so every refusal
below happens before anything is read or submitted.

The public writers are @create@, @fold@, @insert@,
@reclaim@, @cleanup@, @update@ and
@terminate@.

Write commands name the Koios URL, network and wallet key. Partial settings
and mainnet are refused before file reads or provider effects. Read commands
carry the provider, registry and key without any signing setting. Obsolete backend and
socket settings are refused on every command, including --backend koios.
-}
module Singular.Application.OpenDatum.Command
    ( -- * Commands
      OpenDatumCommand (..)
    , InspectArgs (..)
    , StateCreateArgs (..)
    , StateFoldArgs (..)
    , BookArgs (..)
    , PendingArgs (..)
    , HoldingArgs (..)
    , ProviderSettings (..)
    , Signer (..)
    , WriteSettings (..)
    , RegistryAccess (..)
    , Key (..)

      -- * Parsing
    , CLIError (..)
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

import Cardano.Ledger.TxIn (TxIn)
import Control.Monad (forM_, unless, when)
import Data.Bifunctor (first)
import Data.Char
    ( GeneralCategory (Surrogate)
    , generalCategory
    , isDigit
    )
import Data.List (partition)
import Data.Maybe (isJust)
import Data.Text qualified as T (pack, unpack)
import Data.Version (Version)
import Data.Word (Word32)
import GHC.Generics (Generic)
import Paths_open_datum qualified as Paths (version)
import Singular.Application.OpenDatum.Build
    ( DepositRefusal (..)
    , minimumDeposit
    , readDeposit
    )
import Singular.Application.OpenDatum.Help (openDatumProgram)
import Singular.Application.OpenDatum.Requests.Records
    ( RequestParameters (..)
    )
import Singular.CLI.Command
    ( InspectArgs (..)
    , Key (..)
    , RegistryAccess (..)
    , StateCreateArgs (..)
    , StateFoldArgs (..)
    , WriteSettings (..)
    )
import Singular.CLI.FlagGroup
    ( Signer (..)
    , anyAddress
    , commonFlagGroup
    , commonSwitches
    , parseFlagGroup
    , payloadSchemaFrom
    , traceFlags
    , traceRequestFrom
    )
import Singular.CLI.Inspect (ReaderArgs, readerArgs)
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
import Singular.CLI.Registry (economics)
import Singular.CLI.RegistryReading
    ( RegistryRefusal (..)
    , completeRegistry
    )
import Singular.CLI.Sources
    ( Sources (..)
    , applySources
    , loadSources
    , missingHint
    , noSources
    , sourceConflict
    )
import Singular.CLI.Trace (TraceRequest (..))
import Singular.CLI.Version (releaseVersion)
import Singular.Registry.Config.Application
    ( RegistryEconomics (..)
    )
import Singular.Registry.Deployment (parseOutRef)
import Singular.Registry.PlainJson (PayloadSchema)
import Singular.Registry.ProviderSettings (ProviderSettings (..))
import Singular.Registry.StateToken (parseStateToken)
import Text.Read (readMaybe)

-- | One parsed open-datum command line.
data OpenDatumCommand
    = {- | A help page or the version line, to print as it stands: the command
      line asked for it, so nothing else runs
      -}
      OpenHelp String
    | OpenInspect ReaderArgs
    | OpenStateCreate StateCreateArgs RequestParameters
    | OpenStateFold StateFoldArgs
    | OpenRegistrationBook BookArgs
    | OpenRegistrationReclaim PendingArgs
    | OpenRegistrationCleanup PendingArgs
    | OpenHoldingUpdate HoldingArgs FilePath PayloadSchema
    | OpenHoldingTerminate HoldingArgs
    deriving stock (Eq, Show, Generic)

{- | @insert@: a registration of a key, with its payload and deposit,
booked in a registry of open datum.
-}
data BookArgs = BookArgs
    { bookArgsStateDir :: Maybe FilePath
    , bookArgsAccess :: RegistryAccess
    , bookArgsBlueprint :: FilePath
    , bookArgsWrite :: WriteSettings
    , bookArgsKey :: Key
    , bookArgsPayload :: FilePath
    , bookArgsPayloadSchema :: PayloadSchema
    , bookArgsDeposit :: Integer
    -- ^ What the holding keeps, in lovelace
    , bookArgsTip :: Integer
    -- ^ What the request holds above the deposit for the folder, in lovelace
    , bookArgsRefund :: Maybe String
    -- ^ The address a reclaim or a cleanup returns to; the booker's own when absent
    , bookArgsReceipt :: Maybe FilePath
    }
    deriving stock (Eq, Show)

{- | @reclaim@ and @cleanup@: a pending registration
taken back inside its window, or cleaned up after it.
-}
data PendingArgs = PendingArgs
    { pendingArgsStateDir :: Maybe FilePath
    , pendingArgsAccess :: RegistryAccess
    , pendingArgsBlueprint :: FilePath
    , pendingArgsWrite :: WriteSettings
    , pendingArgsPending :: TxIn
    , pendingArgsReceipt :: Maybe FilePath
    }
    deriving stock (Eq, Show)

-- | A live holding controlled by the signing wallet, in the named registry.
data HoldingArgs = HoldingArgs
    { holdingArgsStateDir :: Maybe FilePath
    , holdingArgsAccess :: RegistryAccess
    , holdingArgsBlueprint :: FilePath
    , holdingArgsWrite :: WriteSettings
    , holdingArgsHolding :: TxIn
    , holdingArgsReceipt :: Maybe FilePath
    }
    deriving stock (Eq, Show)

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
    | -- | the settings the config file or the environment give cannot be used, said in one sentence
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
switches every binary reads. The reading is the
library's; what a flag means, and which command refuses it, is the command's.
-}
readFlags :: [String] -> [String] -> Either CLIError Raw
readFlags group =
    first (refusalAs RemovedSetting BadValue "singular")
        . readLine
            Accepted
                { acceptedValued = group <> ["--config"]
                , acceptedEarly = []
                , acceptedSwitches =
                    commonSwitches <> ["--version", "--json", "--query-work"]
                }

{- | What a command line read flat asks for. The switches are taken out of
the flags, which keep their first occurrence first, as the commands read them.
-}
commandFrom
    :: [(String, String)] -> Raw -> Either CLIError OpenDatumCommand
commandFrom environment (Raw ws allFlags) = do
    let flags =
            [ flag
            | flag@(name, _) <- allFlags
            , name `notElem` ["--version", "--config"]
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
    if "--help" `elem` map fst flags
        then Right askedFor
        else
            if any ((== "--version") . fst) allFlags
                then
                    Right
                        ( OpenHelp
                            (identityLine (openDatumProgram openDatumVersion) environment <> "\n")
                        )
                else case ws of
                    [] -> Right askedFor
                    ["open-datum"] -> Right askedFor
                    ["inspect"] ->
                        OpenInspect
                            <$> readerArgs MissingFlag BadValue KeyRefused environment flags
                    ["create"] ->
                        refuseOutside "create" stateCreateAllowed flags
                            >> (OpenStateCreate <$> stateCreateArgs flags <*> parametersFrom flags)
                    ["fold"] ->
                        refuseOutside "fold" stateFoldAllowed flags
                            >> (OpenStateFold <$> (registryFlags flags >>= stateFoldArgs environment))
                    ["update"] ->
                        refuseOutside
                            "update"
                            (holdingAllowed <> ["--payload", "--payload-schema"])
                            flags
                            >> ( OpenHoldingUpdate
                                    <$> (registryFlags flags >>= holdingArgs environment)
                                    <*> required "--payload" flags
                                    <*> payloadSchemaFrom BadValue flags
                               )
                    ["terminate"] ->
                        refuseOutside "terminate" holdingAllowed flags
                            >> ( OpenHoldingTerminate
                                    <$> (registryFlags flags >>= holdingArgs environment)
                               )
                    ["insert"] ->
                        refuseOutside "insert" bookAllowed flags
                            >> ( OpenRegistrationBook
                                    <$> (registryFlags flags >>= bookArgs environment)
                               )
                    ["reclaim"] ->
                        refuseOutside "reclaim" pendingAllowed flags
                            >> ( OpenRegistrationReclaim
                                    <$> (registryFlags flags >>= pendingArgs environment)
                               )
                    ["cleanup"] ->
                        refuseOutside "cleanup" pendingAllowed flags
                            >> ( OpenRegistrationCleanup
                                    <$> (registryFlags flags >>= pendingArgs environment)
                               )
                    _ -> Left (UnknownCommand ws)
  where
    -- The registry named by its address gives the flags its state token and its
    -- network, so the rest of the reading is the one it always was.
    registryFlags flags =
        first registryRefused (completeRegistry environment flags)
    -- The commands name what they take, and refuse the
    -- rest by name: the builders choose the funding, so there is no funding
    -- choice and no spending limit to give.
    stateWriteFlags =
        [ "--koios-url"
        , "--network-magic"
        , "--koios-token-file"
        , "--network-time"
        , "--vault"
        , "--passphrase-fd"
        , "--wallet-address"
        , "--bundle"
        , "--wallet-skey"
        , "--confirm-timeout"
        , "--trace"
        , "--trace-to"
        , "--trace-format"
        ]
    registryNaming = ["--registry", "--state-token"]
    stateCreateAllowed =
        [ "--state-dir"
        , "--blueprint"
        , "--seed"
        , "--receipt"
        , "--process-time"
        , "--reclaim-time"
        , "--booking-width"
        , "--registration-cost"
        , "--minimum-tip"
        ]
            <> stateWriteFlags
    stateFoldAllowed =
        ["--state-dir", "--blueprint", "--pending", "--limit", "--receipt"]
            <> registryNaming
            <> stateWriteFlags
    bookAllowed =
        [ "--state-dir"
        , "--blueprint"
        , "--receipt"
        , "--key"
        , "--key-hex"
        , "--payload"
        , "--payload-schema"
        , "--deposit"
        , "--tip"
        , "--refund-address"
        ]
            <> registryNaming
            <> stateWriteFlags
    holdingAllowed =
        ["--state-dir", "--blueprint", "--holding", "--receipt"]
            <> registryNaming
            <> stateWriteFlags
    pendingAllowed = filter (/= "--limit") stateFoldAllowed
    refuseOutside command allowed flags =
        forM_ flags $ \(flag, _) ->
            unless (flag `elem` allowed) $
                Left $
                    BadValue flag $
                        "is not accepted by "
                            <> command
                            <> if flag `elem` ["--fund-input", "--max-outlay"]
                                then
                                    ": the builders choose the funding, so there is no funding choice and no spending limit"
                                else ""
    stateCreateArgs flags = do
        let dir = optional "--state-dir" flags
        bp <- required "--blueprint" flags
        settings <-
            parseFlagGroup
                MissingFlag
                BadValue
                UnsafeSettings
                WriteSettings
                flags
        seeded <- case optional "--seed" flags of
            Nothing -> Right Nothing
            Just s -> case parseOutRef (T.pack s) of
                Right i -> Right (Just i)
                Left err -> Left (BadValue "--seed" err)
        pure
            StateCreateArgs
                { stateCreateStateDir = dir
                , stateCreateBlueprint = bp
                , stateCreateWrite = settings
                , stateCreateSeed = seeded
                , stateCreatePolicy = Nothing
                , stateCreateReceipt = optional "--receipt" flags
                }
    -- The five parameters of a registry's configuration, fixed at its creation.
    parametersFrom flags = do
        processing <-
            windowFrom "--process-time" (reProcessTime economics) flags
        reclaiming <-
            windowFrom "--reclaim-time" (reRetractTime economics) flags
        width <- windowFrom "--booking-width" 300_000 flags
        cost <- lovelaceFrom "--registration-cost" 0 flags
        tipped <- lovelaceFrom "--minimum-tip" 0 flags
        pure
            RequestParameters
                { rpRegistrationCost = cost
                , rpMinimumTip = tipped
                , rpProcessTime = processing
                , rpRetractTime = reclaiming
                , rpBookingWidth = width
                }
    lovelaceFrom name fallback flags = case optional name flags of
        Nothing -> Right fallback
        Just value
            | not (null value) && all isDigit value -> Right (read value)
            | otherwise ->
                Left (BadValue name "needs a whole number of lovelace")
    namedRefs flags =
        traverse
            (first (BadValue "--pending") . parseOutRef . T.pack)
            [value | ("--pending", Just value) <- flags]
    pendingRefs flags =
        case [value | ("--pending", Just value) <- flags] of
            [] -> Left (MissingFlag "--pending")
            _ -> namedRefs flags
    discoveryLimit flags = case optional "--limit" flags of
        Nothing -> Right Nothing
        Just value -> case readMaybe value :: Maybe Integer of
            Just count
                | not (null value)
                    && all isDigit value
                    && count <= toInteger (maxBound :: Word32) ->
                    Right (Just (fromInteger count))
            _ ->
                Left (BadValue "--limit" "needs a whole number from 0 to 4294967295")
    stateFoldArgs env flags = do
        let dir = optional "--state-dir" flags
        bp <- required "--blueprint" flags
        settings <-
            parseFlagGroup
                MissingFlag
                BadValue
                UnsafeSettings
                WriteSettings
                flags
        pending <- namedRefs flags
        limit <- discoveryLimit flags
        access <- registryAccess env flags
        pure
            StateFoldArgs
                { stateFoldStateDir = dir
                , stateFoldAccess = access
                , stateFoldBlueprint = bp
                , stateFoldWrite = settings
                , stateFoldPending = pending
                , stateFoldLimit = limit
                , stateFoldReceipt = optional "--receipt" flags
                }
    holdingArgs env flags = do
        bp <- required "--blueprint" flags
        settings <-
            parseFlagGroup MissingFlag BadValue UnsafeSettings WriteSettings flags
        ref <-
            required "--holding" flags
                >>= first (BadValue "--holding") . parseOutRef . T.pack
        access <- registryAccess env flags
        pure
            HoldingArgs
                { holdingArgsStateDir = optional "--state-dir" flags
                , holdingArgsAccess = access
                , holdingArgsBlueprint = bp
                , holdingArgsWrite = settings
                , holdingArgsHolding = ref
                , holdingArgsReceipt = optional "--receipt" flags
                }
    pendingArgs env flags = do
        let dir = optional "--state-dir" flags
        bp <- required "--blueprint" flags
        settings <-
            parseFlagGroup
                MissingFlag
                BadValue
                UnsafeSettings
                WriteSettings
                flags
        pending <- pendingRefs flags
        access <- registryAccess env flags
        case pending of
            [one] ->
                pure
                    PendingArgs
                        { pendingArgsStateDir = dir
                        , pendingArgsAccess = access
                        , pendingArgsBlueprint = bp
                        , pendingArgsWrite = settings
                        , pendingArgsPending = one
                        , pendingArgsReceipt = optional "--receipt" flags
                        }
            _ ->
                Left
                    ( BadValue
                        "--pending"
                        "names one pending registration: give it once"
                    )
    bookArgs env flags = do
        let dir = optional "--state-dir" flags
        bp <- required "--blueprint" flags
        key <- keyFrom flags
        settings <-
            parseFlagGroup
                MissingFlag
                BadValue
                UnsafeSettings
                WriteSettings
                flags
        payload <- required "--payload" flags
        schema <- payloadSchemaFrom BadValue flags
        deposit <-
            first
                DepositRefused
                (readDeposit (T.pack <$> optional "--deposit" flags))
        tipped <- lovelaceFrom "--tip" 0 flags
        refund <- case optional "--refund-address" flags of
            Nothing -> Right Nothing
            Just given ->
                first
                    (BadValue "--refund-address")
                    (Just given <$ anyAddress (T.pack given))
        access <- registryAccess env flags
        pure
            BookArgs
                { bookArgsStateDir = dir
                , bookArgsAccess = access
                , bookArgsBlueprint = bp
                , bookArgsWrite = settings
                , bookArgsKey = key
                , bookArgsPayload = payload
                , bookArgsPayloadSchema = schema
                , bookArgsDeposit = deposit
                , bookArgsTip = tipped
                , bookArgsRefund = refund
                , bookArgsReceipt = optional "--receipt" flags
                }
    windowFrom name fallback flags = case optional name flags of
        Nothing -> Right fallback
        Just value -> case readMaybe value of
            Just n | n > 0 && all isDigit value -> Right n
            _ ->
                Left (BadValue name "needs a positive integer number of milliseconds")

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
        pure RegistryAccess{accessToken = token} -- --key is the text of the key and --key-hex its base16: one of the two,
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
    mapM_
        (Left . ConfigRefused)
        (sourceConflict (openDatumProgram openDatumVersion) sources raw)
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

-- | The valued flags this binary owns beyond the common group: the request commands'.
extraValuedFlags :: [String]
extraValuedFlags =
    [ "--holding"
    , "--pending"
    , "--limit"
    , "--reclaim-time"
    , "--booking-width"
    , "--registration-cost"
    , "--minimum-tip"
    , "--tip"
    , "--refund-address"
    ]

-- | The registry a command line names, refused as the command line refuses.
registryRefused :: RegistryRefusal -> CLIError
registryRefused = \case
    RegistryMissing flag -> MissingFlag flag
    RegistryBad flag why -> BadValue flag why

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
