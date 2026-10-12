{-# LANGUAGE LambdaCase #-}

{- |
Module      : Singular.Application.KeriStub.Command
Description : What a @keri-stub@ command line asks for, parsed without effects
License     : Apache-2.0

The keri-stub commands and help, read from the command line alone:
no file, node, key or environment is touched here, so every refusal
below happens before anything is read or submitted.

* @keri-stub create@ boots one registry from a seed the caller chose in
  their own wallet, or previews its identity with @--preview@;
* @keri-stub register@ books one @insertActive@ at a key under the stub's
  own always-succeeding policy, leaving its request pending for the
  registry's fold; with @--fold@ it also folds it in the same command;
* @keri-stub convict@ books one @updateTerminal@ at a key, carrying the
  evidence hash its @--evidence@ names, leaving its request pending for
  the registry's fold; with @--fold@ it also folds it in the same
  command, releasing the holding to its controller;
* @keri-stub fold@ folds the one pending request, signed and funded by
  the wallet that runs it;
* @keri-stub status@ reads the registry and one key back, and accepts
  no signing key at all.

Write commands name the Koios URL, network and wallet key. Partial
settings and mainnet are refused before file reads or provider
effects. Read commands carry a public wallet address instead of a
signing key. Register and convict take no preview — they book and
submit.

The tokenizing, tracing and settings readers live in the shared flag
group ("Singular.CLI.FlagGroup"), called with the extras this binary
owns; this parser keeps none of its own.
-}
module Singular.Application.KeriStub.Command
    ( -- * Commands
      KeriStubCommand (..)
    , ConvictArgs (..)
    , neededRoles

      -- * Parsing
    , CLIError (..)
    , parseKeriStubCommand
    , parseKeriStubCommandWithEnvironment
    , parseKeriStubInvocation
    , parseKeriStubWithGroup
    , renderCLIError
    , keriStubUsage
    ) where

import Control.Monad (forM_, unless, when)
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Char8 qualified as BC
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
    ( commonFlagGroup
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
import Singular.CLI.Registry (economics)
import Singular.CLI.Trace (TraceRequest (..))
import Singular.Registry.Config.Application (RegistryEconomics (..))
import Singular.Registry.Deployment (parseOutRef)
import Singular.Registry.StateToken
    ( ReferenceRole (..)
    , parseStateToken
    )
import Singular.Registry.TxBuilder.Edges (edgeDeposit)

-- | One parsed keri-stub command line.
data KeriStubCommand
    = KeriHelp
    | KeriCreate CreateArgs
    | KeriRegister EntryArgs
    | KeriConvict ConvictArgs
    | KeriFold FoldArgs
    | KeriStatus InspectArgs
    deriving stock (Eq, Show, Generic)

{- | One parsed @keri-stub convict@: the termination it books and the
evidence hash the booking carries. The entry part is the shared
entry command; the evidence flag belongs to convict alone and stays
in the stub.
-}
data ConvictArgs = ConvictArgs
    { convictEntry :: EntryArgs
    , convictEvidence :: ByteString
    }
    deriving stock (Eq, Show, Generic)

-- | Why a keri-stub command line was refused before anything ran.
data CLIError
    = UnknownCommand [String]
    | RemovedSetting String
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
parseKeriStubCommand :: [String] -> Either CLIError KeriStubCommand
parseKeriStubCommand = parseKeriStubWith []

-- | Parse a command line with its environment.
parseKeriStubWith
    :: [(String, String)] -> [String] -> Either CLIError KeriStubCommand
parseKeriStubWith = parseKeriStubWithGroup (commonFlagGroup <> extraValuedFlags)

{- | Parse a command line with its environment over an explicit flag
group: the tokenizer reads exactly these valued flags. The exported
parser applies this to the common group plus the extras this binary
owns.
-}
parseKeriStubWithGroup
    :: [String]
    -> [(String, String)]
    -> [String]
    -> Either CLIError KeriStubCommand
parseKeriStubWithGroup group environment args = do
    (words', flags) <- tokenizeWith RemovedSetting BadValue group args
    let words'' = case words' of
            ["create"] -> ["keri-stub", "create"]
            ["register"] -> ["keri-stub", "register"]
            ["convict"] -> ["keri-stub", "convict"]
            ["fold"] -> ["keri-stub", "fold"]
            ["status"] -> ["keri-stub", "status"]
            _ -> words'
    if "--help" `elem` map fst flags || "-h" `elem` map fst flags
        then Right KeriHelp
        else
            refuseWindows words'' flags >> refuseOutputsAt words'' flags >> case words'' of
                [] -> Right KeriHelp
                ["keri-stub"] -> Right KeriHelp
                ["keri-stub", "create"] ->
                    refuseSpendingFlags "create" flags
                        >> refuseRequest flags
                        >> refuseFold flags
                        >> refuseEntry flags
                        >> (KeriCreate <$> createArgs flags)
                ["keri-stub", "register"] ->
                    refuseRequest flags
                        >> (KeriRegister <$> registerArgs environment flags)
                ["keri-stub", "convict"] ->
                    refuseRequest flags
                        >> refuseEntry flags
                        >> (KeriConvict <$> convictArgs environment flags)
                ["keri-stub", "fold"] ->
                    refuseEntry flags >> (KeriFold <$> foldArgs environment flags)
                ["keri-stub", "status"] ->
                    refuseSpendingFlags "status" flags
                        >> refuseRequest flags
                        >> refuseFold flags
                        >> refuseEntry flags
                        >> (KeriStatus <$> statusArgs environment flags)
                _ -> Left (UnknownCommand words')
  where
    refuseWindows words' flags =
        unless (words' == ["keri-stub", "create"]) $
            forM_ ["--process-time", "--retract-time"] $ \flag ->
                when (isJust (lookup flag flags)) $
                    Left
                        ( BadValue
                            flag
                            "is a keri-stub create flag: windows are fixed for the life of a registry"
                        )
    refuseSpendingFlags command flags =
        forM_ ["--fund-input", "--max-outlay"] $ \flag ->
            when (isJust (lookup flag flags)) $
                Left (UnsupportedFlag flag command)
    refuseOutputsAt words' flags =
        when
            ( isJust (lookup "--outputs-at" flags)
                && words' /= ["keri-stub", "status"]
            )
            $ Left
                ( BadValue
                    "--outputs-at"
                    "is a keri-stub status flag: only status reads another address's outputs"
                )
    refuseRequest flags =
        when (isJust (lookup "--request" flags)) $
            Left
                ( BadValue
                    "--request"
                    "names the pending request @keri-stub fold@ folds; this command takes none"
                )
    refuseFold flags =
        when (isJust (lookup "--fold" flags)) $
            Left
                ( BadValue
                    "--fold"
                    "is taken by register only, which books: this command books nothing, so there is nothing to fold in the same command"
                )
    refuseEntry flags =
        forM_ ["--deposit", "--payload"] $ \flag ->
            when (isJust (lookup flag flags)) $
                Left
                    ( BadValue
                        flag
                        "is taken by register only, which books an insertion carrying a holding"
                    )
    registerArgs env flags = do
        let dir = optional "--state-dir" flags
        bp <- required "--blueprint" flags
        key <- keyFrom flags
        when (isJust (lookup "--preview" flags)) $
            Left
                ( BadValue
                    "--preview"
                    "is not accepted by register: it books and submits, and the stub offers no booking preview"
                )
        when (isJust (lookup "--wallet-address" flags)) $
            Left addressNeedsPreview
        settings <-
            parseFlagGroup
                MissingFlag
                BadValue
                UnsafeSettings
                WriteSettings
                flags
        deposit <- depositFrom flags
        fund <- fundFrom flags
        outlay <- outlayFrom flags
        access <- registryAccess env flags
        pure
            EntryArgs
                { entryStateDir = dir
                , entryAccess = access
                , entryBlueprint = bp
                , entryMode = Submit settings
                , entryKey = key
                , entryDocument = optional "--payload" flags
                , entryDeposit = deposit
                , entryFund = fund
                , entryMaxOutlay = outlay
                , entryReceipt = optional "--receipt" flags
                , entryFold = isJust (lookup "--fold" flags)
                }
    depositFrom flags = case optional "--deposit" flags of
        Nothing -> Right Nothing
        Just value -> case readMaybe value of
            Just n
                | n < leastDeposit ->
                    Left
                        ( BadValue
                            "--deposit"
                            ( "is below the least deposit an insertion rides with: "
                                <> show leastDeposit
                                <> " lovelace"
                            )
                        )
                | otherwise -> Right (Just n)
            Nothing ->
                Left (BadValue "--deposit" "is not a number of lovelace")
    leastDeposit = edgeDeposit
    convictArgs env flags = do
        let dir = optional "--state-dir" flags
        bp <- required "--blueprint" flags
        key <- keyFrom flags
        when (isJust (lookup "--preview" flags)) $
            Left
                ( BadValue
                    "--preview"
                    "is not accepted by convict: it books and submits, and the stub offers no booking preview"
                )
        when (isJust (lookup "--wallet-address" flags)) $
            Left addressNeedsPreview
        settings <-
            parseFlagGroup
                MissingFlag
                BadValue
                UnsafeSettings
                WriteSettings
                flags
        evidence <- evidenceFrom flags
        fund <- fundFrom flags
        outlay <- outlayFrom flags
        access <- registryAccess env flags
        pure
            ConvictArgs
                { convictEntry =
                    EntryArgs
                        { entryStateDir = dir
                        , entryAccess = access
                        , entryBlueprint = bp
                        , entryMode = Submit settings
                        , entryKey = key
                        , entryDocument = Nothing
                        , entryDeposit = Nothing
                        , entryFund = fund
                        , entryMaxOutlay = outlay
                        , entryReceipt = optional "--receipt" flags
                        , entryFold = isJust (lookup "--fold" flags)
                        }
                , convictEvidence = evidence
                }
    evidenceFrom flags = case optional "--evidence" flags of
        Nothing -> Left (MissingFlag "--evidence")
        Just value
            | null value ->
                Left
                    ( BadValue
                        "--evidence"
                        "is empty: name the evidence hash in hex"
                    )
            | otherwise -> case B16.decode (BC.pack value) of
                Right bytes
                    | not (BS.null bytes) -> Right bytes
                _ ->
                    Left
                        ( BadValue
                            "--evidence"
                            "is not base16 bytes: name the evidence hash in hex"
                        )
    createArgs flags = do
        when (isJust (lookup "--state-token" flags)) $
            Left
                ( BadValue
                    "--state-token"
                    "is refused by keri-stub create, which makes one"
                )
        processing <-
            windowFrom "--process-time" (reProcessTime economics) flags
        retracting <-
            windowFrom "--retract-time" (reRetractTime economics) flags
        let dir = optional "--state-dir" flags
        bp <- required "--blueprint" flags
        let preview = isJust (lookup "--preview" flags)
            publicPreview = preview && isJust (lookup "--wallet-address" flags)
        when (not preview && isJust (lookup "--wallet-address" flags)) $
            Left addressNeedsPreview
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
        seed <- case lookup "--seed" flags of
            Just (Just s) -> case parseOutRef (T.pack s) of
                Right _ -> Right (Just s)
                Left err -> Left (BadValue "--seed" err)
            _
                | preview -> Right Nothing
                | otherwise -> Left (MissingFlag "--seed")
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
                }
    windowFrom name fallback flags = case optional name flags of
        Nothing -> Right fallback
        Just value -> case readMaybe value of
            Just n | n > 0 && all isDigit value -> Right n
            _ ->
                Left (BadValue name "needs a positive integer number of milliseconds")
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
                            "is not accepted by keri-stub fold: it folds the pending request, whose key and edge the request names"
                        )
        when (isJust (lookup "--wallet-address" flags)) $
            Left addressNeedsPreview
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
    statusArgs env flags = do
        when (isJust (lookup "--wallet-skey" flags)) $
            Left SigningKeyNotAccepted
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
    addressNeedsPreview =
        BadValue
            "--wallet-address"
            "names a caller for --preview and keri-stub status only; a write signs with --wallet-skey"
    previewMode flags = do
        when (isJust (lookup "--wallet-skey" flags)) $
            Left PreviewTakesNoKey
        settings <- readProviderSettings MissingFlag BadValue flags
        addr <- required "--wallet-address" flags
        pure (Preview settings addr)
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
parseKeriStubCommandWithEnvironment
    :: [(String, String)] -> [String] -> Either CLIError KeriStubCommand
parseKeriStubCommandWithEnvironment environment args = do
    when (isJust (lookup "SINGULAR_NODE_SOCKET" environment)) $
        Left (RemovedSetting "SINGULAR_NODE_SOCKET")
    parseKeriStubWith environment args

{- | A whole command line: the command, and the tracing it asks for with
@--trace@, @--trace-to@ and @--trace-format@. Every command takes the three.
-}
parseKeriStubInvocation
    :: [(String, String)]
    -> [String]
    -> Either CLIError (KeriStubCommand, TraceRequest)
parseKeriStubInvocation environment args = do
    (rest, request) <- splitTracingFor BadValue extraValuedFlags args
    command <- parseKeriStubCommandWithEnvironment environment rest
    pure (command, request)

{- | The extra valued flags this binary owns beyond the common group:
@--evidence@, the hash a convict carries, belongs to convict alone and
stays in the stub; every other command-specific spelling is refused by
name above.
-}
extraValuedFlags :: [String]
extraValuedFlags = ["--evidence"]

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
    UnsafeSettings why -> why
    SigningKeyNotAccepted ->
        "status takes no signing key: it reads, and never funds or submits"
    PreviewTakesNoKey ->
        "--preview takes no signing key: name the caller with --wallet-address; a preview reads, and never signs or submits"
    UnsupportedFlag flag command ->
        flag
            <> " is not accepted by `keri-stub "
            <> command
            <> "`: only fold enforces it, and a constraint the command does not enforce is refused, never ignored"

-- | The supported commands.
keriStubUsage :: String
keriStubUsage =
    unlines
        [ "usage:"
        , "  keri-stub create [--state-dir ROOT] --blueprint PLUTUS_JSON"
        , "      (--seed TXID#IX | --preview) [--process-time MS] [--retract-time MS]"
        , "      --koios-url URL --network-magic N --wallet-skey FILE [--receipt FILE]"
        , "  keri-stub create --preview [--state-dir ROOT] --blueprint PLUTUS_JSON"
        , "      [--seed TXID#IX] [--process-time MS] [--retract-time MS]"
        , "      --koios-url URL --network-magic N --wallet-address ADDR"
        , "  keri-stub register [--state-dir ROOT] --blueprint PLUTUS_JSON (--key KEY | --key-hex HEX)"
        , "      --state-token POLICY.NAME"
        , "      --koios-url URL --network-magic N --wallet-skey FILE [--receipt FILE]"
        , "      [--deposit LOVELACE] [--payload PLUTUS_JSON] [--fund-input TXID#IX] [--max-outlay LOVELACE]"
        , "      [--fold]"
        , "  keri-stub convict [--state-dir ROOT] --blueprint PLUTUS_JSON (--key KEY | --key-hex HEX)"
        , "      --evidence HEX --state-token POLICY.NAME"
        , "      --koios-url URL --network-magic N --wallet-skey FILE [--receipt FILE]"
        , "      [--fund-input TXID#IX] [--max-outlay LOVELACE]"
        , "      [--fold]"
        , "  keri-stub fold [--state-dir ROOT] --blueprint PLUTUS_JSON"
        , "      --state-token POLICY.NAME"
        , "      --koios-url URL --network-magic N --wallet-skey FILE [--receipt FILE]"
        , "      [--request TXID#IX] [--fund-input TXID#IX] [--max-outlay LOVELACE]"
        , "  keri-stub status [--state-dir ROOT] --blueprint PLUTUS_JSON (--key KEY | --key-hex HEX)"
        , "      --state-token POLICY.NAME"
        , "      --koios-url URL --network-magic N [--receipt FILE] [--outputs-at ADDR]"
        , "      [--wallet-address ADDR]"
        , ""
        , "Every command but create names its registry by the state token POLICY.NAME,"
        , "the policy and the name in hex, which create prints; when the flag is absent"
        , "it is read from SINGULAR_STATE_TOKEN. Nothing else names a registry."
        , "register books an insertion whose request the fold settles; --fold on"
        , "register runs that fold in the same command. convict books a termination"
        , "carrying the evidence hash, whose request the fold settles by releasing"
        , "the holding to its controller; --fold on convict runs that fold in the"
        , "same command."
        ]

{- | The reference roles a command's transactions run, and so the only
references it looks up.
-}
neededRoles :: KeriStubCommand -> Set ReferenceRole
neededRoles = \case
    KeriCreate _ -> Set.singleton RoleState
    KeriRegister a
        | entryFold a -> Set.fromList [minBound .. maxBound]
        -- The stub's pin is a hash: no application reference exists to
        -- find, and the booking reads the registry state alone.
        | otherwise -> Set.singleton RoleState
    KeriConvict c
        | entryFold (convictEntry c) -> Set.fromList [minBound .. maxBound]
        -- As register: the pin is a hash, so the booking reads the
        -- registry state and the key's live holding alone.
        | otherwise -> Set.singleton RoleState
    KeriFold _ -> Set.fromList [minBound .. maxBound]
    KeriStatus _ -> Set.empty
    KeriHelp -> Set.empty
