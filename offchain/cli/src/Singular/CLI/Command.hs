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
* @registry fold@ takes the selection and folds every included request, signed and funded by
  the wallet that runs it;
* @registry reclaim@ takes back the wallet's named pending insertion or
  terminal-witness request inside its retract window;
* @registry reject@ rejects every pending request, once each is past both
  its windows, signed and funded by the wallet that runs it;
* @registry inspect@ reads the registry and one key back, and accepts
  no signing key at all;
* @registry describe@ reads the registry page from the chain alone, and
  accepts no wallet, key, state directory or other actor file at all.

Write commands name the Koios URL, network and wallet key. Partial settings
and mainnet are refused before file reads or provider effects. Read commands
carry a public wallet address instead of a signing key. Obsolete backend and
socket settings are refused on every command, including --backend koios.
-}
module Singular.CLI.Command
    ( -- * Commands
      Command (..)
    , CreateArgs (..)
    , DescribeArgs (..)
    , EntryArgs (..)
    , EntryMode (..)
    , FoldArgs (..)
    , InspectArgs (..)
    , ProviderSettings (..)
    , RejectArgs (..)
    , ReclaimArgs (..)
    , WalletArgs (..)
    , WriteSettings (..)
    , RegistryAccess (..)
    , Key (..)
    , ApplicationPolicy (..)
    , neededRoles

      -- * Parsing
    , CLIError (..)
    , parseCommand
    , parseCommandWithEnvironment
    , parseInvocation
    , parseWithGroup
    , renderCLIError
    , usage
    , maxKeyBytes
    , keyFlags

      -- * The wallet verbs
    , walletCreateCommand
    , walletAddressCommand
    ) where

import Control.Monad (forM_, unless, when)
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Short qualified as SBS
import Data.Char
    ( GeneralCategory (Surrogate)
    , generalCategory
    , isDigit
    )
import Data.Maybe (isJust)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Word (Word32)
import GHC.Generics (Generic)
import System.Exit (ExitCode (..))
import System.IO (hPutStrLn, stderr)
import Text.Read (readMaybe)

import Cardano.Crypto.DSIGN (Ed25519DSIGN, SignKeyDSIGN)
import Cardano.Ledger.TxIn (TxIn)
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
import Singular.CLI.Passphrase
    ( Confirmation (..)
    , PassphraseSource (..)
    , readPassphrase
    , renderPassphraseRefusal
    )
import Singular.CLI.Registry (economics)
import Singular.CLI.Trace (TraceRequest (..))
import Singular.CLI.Vault
    ( createVaultFile
    , freshSignKey
    , openVault
    , renderVaultRefusal
    , sealVault
    , vaultWorkFactor
    )
import Singular.Registry.Config.Application (RegistryEconomics (..))
import Singular.Registry.Deployment (parseOutRef)
import Singular.Registry.LedgerProvider (Asset)
import Singular.Registry.ProviderSettings (ProviderSettings (..))
import Singular.Registry.StateToken
    ( ReferenceRole (..)
    , parseStateToken
    )
import Singular.Registry.Wallet
    ( Wallet (..)
    , bech32Address
    , walletFromSignKey
    )

-- | A registry key: the bytes the leaf and the active token are named by.
newtype Key = Key {unKey :: ByteString}
    deriving stock (Eq, Show)

{- | @--application-policy HEX@: the 28-byte policy hash a @registry create@
pins, as parsed bytes. Nothing else carries it: any other command refuses
the flag by name.
-}
newtype ApplicationPolicy = ApplicationPolicy
    { unApplicationPolicy :: SBS.ShortByteString
    }
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

{- | The registry a command acts on: its state token (@--state-token@, or
@SINGULAR_STATE_TOKEN@), the only name a registry has.
-}
newtype RegistryAccess = RegistryAccess
    { accessToken :: Asset
    }
    deriving stock (Eq, Show)

-- | @registry create@.
data CreateArgs = CreateArgs
    { createStateDir :: Maybe FilePath
    -- ^ Optional state root override; absent, the managed default root applies
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

{- | @registry describe@: the token, the blueprint, a provider and a network.

Never a wallet, key, state directory or other actor file: those are
refused with their names before anything is read. With @--json@ the
page prints as JSON, otherwise as text.
-}
data DescribeArgs = DescribeArgs
    { describeBlueprint :: FilePath
    , describeAccess :: RegistryAccess
    {- ^ The registry, by its state token: required, as on every command
    but create.
    -}
    , describeProvider :: ProviderSettings
    , describeJson :: Bool
    -- ^ With @--json@, print the page as JSON
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
    { entryStateDir :: Maybe FilePath
    -- ^ Optional state root override; absent, the managed default root applies
    , entryAccess :: RegistryAccess
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
    { foldStateDir :: Maybe FilePath
    -- ^ Optional state root override; absent, the managed default root applies
    , foldAccess :: RegistryAccess
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
    { rejectStateDir :: Maybe FilePath
    -- ^ Optional state root override; absent, the managed default root applies
    , rejectAccess :: RegistryAccess
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
    { reclaimStateDir :: Maybe FilePath
    -- ^ Optional state root override; absent, the managed default root applies
    , reclaimAccess :: RegistryAccess
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
    { inspectStateDir :: Maybe FilePath
    -- ^ Optional state root override; absent, the managed default root applies
    , inspectAccess :: RegistryAccess
    {- ^ The registry, by its state token: required on every command but
    create.
    -}
    , inspectBlueprint :: FilePath
    , inspectProvider :: ProviderSettings
    , inspectKey :: Key
    , inspectOutputsAt :: Maybe String
    {- ^ @--outputs-at@: a public address whose outputs the receipt also lists, read
    from the node apart from any write
    -}
    , inspectWalletAddress :: Maybe String
    {- ^ @--wallet-address@: the caller's public address, locating the managed
    partition whose journal this inspect reconciles. Absent, the inspect is a
    stateless chain read that reconciles no wallet journal. Never a signing key.
    -}
    , inspectReceipt :: Maybe FilePath
    }
    deriving stock (Eq, Show)

{- | @wallet create@ and @wallet address@: the vault path, the network
the address is built for, and the passphrase source — the terminal,
absent, or the inherited descriptor named. No flag takes the
passphrase itself.
-}
data WalletArgs = WalletArgs
    { walletVaultPath :: FilePath
    -- ^ The encrypted vault file, created by @wallet create@ alone
    , walletNetworkMagic :: Word32
    -- ^ The network the address is built for
    , walletPassphraseFd :: Maybe Int
    -- ^ @--passphrase-fd N@: the inherited descriptor read for the passphrase
    }
    deriving stock (Eq, Show)

-- | One parsed command line.
data Command
    = Help
    | Create CreateArgs (Maybe ApplicationPolicy)
    | Describe DescribeArgs
    | Fold FoldArgs
    | Reject RejectArgs
    | Reclaim ReclaimArgs
    | Inspect InspectArgs
    | WalletCreate WalletArgs
    | WalletAddress WalletArgs
    deriving stock (Eq, Show, Generic)

-- | Why a command line was refused before anything ran.
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
    | {- | A setting @registry describe@ does not take: refused with its
      name, before anything is read. Describe reads the public registry
      and writes nothing; it takes no wallet, key, state directory or
      other actor file.
      -}
      RefusedSetting String
    deriving stock (Eq, Show)

-- | Parse a command line.
parseCommand :: [String] -> Either CLIError Command
parseCommand = parseWith []

-- | Parse a command line with its environment.
parseWith :: [(String, String)] -> [String] -> Either CLIError Command
parseWith = parseWithGroup (commonFlagGroup <> extraValuedFlags)

{- | Parse a command line with its environment over an explicit flag group:
the tokenizer reads exactly these valued flags. The exported parser applies
this to the common group plus this binary's extras.
-}
parseWithGroup
    :: [String] -> [(String, String)] -> [String] -> Either CLIError Command
parseWithGroup group environment args = do
    let (jsonSwitch, plainArgs) = splitJson args
    (words', flags) <-
        tokenizeWith RemovedSetting BadValue group plainArgs
    if "--help" `elem` map fst flags || "-h" `elem` map fst flags
        then Right Help
        else
            refuseWindows words' flags
                >> refuseOutputsAt words' flags
                >> refuseJson words' jsonSwitch
                >> refuseWalletSettings words' flags
                >> case words' of
                    [] -> Right Help
                    ["registry"] -> Right Help
                    ["wallet"] -> Right Help
                    ["wallet", "create"] ->
                        refuseWalletCommandSettings "wallet create" flags
                            >> (WalletCreate <$> walletArgs flags)
                    ["wallet", "address"] ->
                        refuseWalletCommandSettings "wallet address" flags
                            >> (WalletAddress <$> walletArgs flags)
                    ["registry", "create"] ->
                        refuseSpendingFlags "create" flags
                            >> refuseRequest flags
                            >> refuseFold flags
                            >> (Create <$> createArgs flags <*> applicationPolicyFrom flags)
                    ["registry", "fold"] ->
                        refuseApplicationPolicy flags
                            >> (Fold <$> foldArgs environment flags)
                    ["registry", "reject"] ->
                        refuseApplicationPolicy flags
                            >> (Reject <$> rejectArgs environment flags)
                    ["registry", "reclaim"] ->
                        refuseApplicationPolicy flags
                            >> (Reclaim <$> reclaimArgs environment flags)
                    ["registry", "inspect"] ->
                        refuseApplicationPolicy flags
                            >> refuseSpendingFlags "inspect" flags
                            >> refuseRequest flags
                            >> refuseFold flags
                            >> (Inspect <$> inspectArgs environment flags)
                    ["registry", "describe"] ->
                        refuseApplicationPolicy flags
                            >> refuseDescribeSettings flags
                            >> (Describe <$> describeArgs environment flags jsonSwitch)
                    _ -> Left (UnknownCommand words')
  where
    refuseJson words' json =
        when (json && words' /= ["registry", "describe"]) $
            Left
                ( BadValue
                    "--json"
                    "is a registry describe flag: only describe prints the page as JSON"
                )
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
    -- The wallet flags belong to the wallet verbs alone; a registry
    -- command refuses either by name rather than ignore it.
    refuseWalletSettings words' flags =
        unless (take 1 words' == ["wallet"]) $
            forM_ ["--vault", "--passphrase-fd"] $ \flag ->
                when (isJust (lookup flag flags)) $
                    Left
                        ( BadValue
                            flag
                            "is a wallet flag: only singular wallet commands read it"
                        )
    -- A wallet command takes its own three flags and nothing else from
    -- the shared group: every other setting is refused by name rather
    -- than ignored.
    refuseWalletCommandSettings command flags =
        forM_ (commonFlagGroup <> extraValuedFlags) $ \flag ->
            unless (flag `elem` ["--network-magic", "--vault", "--passphrase-fd"]) $
                when (isJust (lookup flag flags)) $
                    Left
                        ( BadValue
                            flag
                            ( "is not accepted by "
                                <> command
                                <> ": a wallet command takes only its vault, network magic and passphrase descriptor"
                            )
                        )
    -- @--application-policy@ pins what @registry create@ boots; any other
    -- command refuses it by name rather than ignore it.
    refuseApplicationPolicy flags =
        when (isJust (lookup "--application-policy" flags)) $
            Left
                ( BadValue
                    "--application-policy"
                    "is a registry create flag: only create pins an application policy"
                )
    -- @registry describe@ reads the public registry and writes nothing:
    -- every setting below names something it neither enforces nor keeps,
    -- so each is refused with its own name.
    refuseDescribeSettings flags =
        forM_ describeRefusedFlags $ \flag ->
            when (isJust (lookup flag flags)) $
                Left (RefusedSetting flag)
    describeRefusedFlags :: [String]
    describeRefusedFlags =
        [ "--wallet-skey"
        , "--state-dir"
        , "--receipt"
        , "--wallet-address"
        , "--seed"
        , "--key"
        , "--key-hex"
        , "--deposit"
        , "--payload"
        , "--fund-input"
        , "--max-outlay"
        , "--confirm-timeout"
        , "--preview"
        , "--request"
        , "--fold"
        ]
    createArgs flags = do
        when (isJust (lookup "--state-token" flags)) $
            Left
                ( BadValue
                    "--state-token"
                    "is refused by registry create, which makes one"
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
                }
    applicationPolicyFrom flags = case optional "--application-policy" flags of
        Nothing -> Right Nothing
        Just spelling -> case parseApplicationPolicy (T.pack spelling) of
            Right pinned -> Right (Just pinned)
            Left why -> Left (BadValue "--application-policy" why)
    parseApplicationPolicy spelling = case B16.decode (TE.encodeUtf8 spelling) of
        Left _ ->
            Left "is not hex: give 56 hex characters (a 28-byte policy hash)"
        Right bytes
            | BS.length bytes == 28 ->
                Right (ApplicationPolicy (SBS.toShort bytes))
            | otherwise ->
                Left
                    ( "is "
                        <> show (BS.length bytes)
                        <> " bytes, not 28: give 56 hex characters (a 28-byte policy hash)"
                    )
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
                            "is not accepted by registry fold: it folds the pending request, whose key and edge the request names"
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
    rejectArgs env flags = do
        let dir = optional "--state-dir" flags
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
        settings <-
            parseFlagGroup
                MissingFlag
                BadValue
                UnsafeSettings
                WriteSettings
                flags
        fund <- fundFrom flags
        outlay <- outlayFrom flags
        access <- registryAccess env flags
        pure
            RejectArgs
                { rejectStateDir = dir
                , rejectAccess = access
                , rejectBlueprint = bp
                , rejectWrite = settings
                , rejectFund = fund
                , rejectMaxOutlay = outlay
                , rejectReceipt = optional "--receipt" flags
                }
    reclaimArgs env flags = do
        let dir = optional "--state-dir" flags
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
        settings <-
            parseFlagGroup
                MissingFlag
                BadValue
                UnsafeSettings
                WriteSettings
                flags
        named <- required "--request" flags
        request <- first (BadValue "--request") (parseOutRef (T.pack named))
        fund <- fundFrom flags
        outlay <- outlayFrom flags
        access <- registryAccess env flags
        pure
            ReclaimArgs
                { reclaimStateDir = dir
                , reclaimAccess = access
                , reclaimBlueprint = bp
                , reclaimWrite = settings
                , reclaimRequest = request
                , reclaimFund = fund
                , reclaimMaxOutlay = outlay
                , reclaimReceipt = optional "--receipt" flags
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
    describeArgs env flags json = do
        bp <- required "--blueprint" flags
        settings <- readProviderSettings MissingFlag BadValue flags
        access <- registryAccess env flags
        pure
            DescribeArgs
                { describeBlueprint = bp
                , describeAccess = access
                , describeProvider = settings
                , describeJson = json
                }
    inspectArgs env flags = do
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
    -- A preview reads a node and names a public address; it holds no key,
    -- so a signing key is refused before anything is read.
    addressNeedsPreview =
        BadValue
            "--wallet-address"
            "names a caller for --preview and registry inspect only; a write signs with --wallet-skey"
    previewMode flags = do
        when (isJust (lookup "--wallet-skey" flags)) $
            Left PreviewTakesNoKey
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
    walletArgs flags = do
        vault <- required "--vault" flags
        magicText <- required "--network-magic" flags
        magic <-
            maybe (Left (BadValue "--network-magic" "not a number")) Right $
                readMaybe magicText
        fd <- case optional "--passphrase-fd" flags of
            Nothing -> Right Nothing
            Just spelling -> case readMaybe spelling of
                Just n | n >= 0 -> Right (Just n)
                _ -> Left (BadValue "--passphrase-fd" "not a descriptor number")
        pure
            WalletArgs
                { walletVaultPath = vault
                , walletNetworkMagic = magic
                , walletPassphraseFd = fd
                }
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
    parseWith environment args

{- | A whole command line: the command, and the tracing it asks for with
@--trace@, @--trace-to@ and @--trace-format@. Every command takes the three.
-}
parseInvocation
    :: [(String, String)]
    -> [String]
    -> Either CLIError (Command, TraceRequest)
parseInvocation environment args = do
    (rest, request) <- splitTracingFor BadValue extraValuedFlags args
    command <- parseCommandWithEnvironment environment rest
    pure (command, request)

{- | The tokenizing, tracing and settings readers live in the shared flag
group, called with the extras below; this parser keeps none of its own.
The one valued flag this binary owns beyond the common group: create
pins an application policy, and no other command reads it.
-}
extraValuedFlags :: [String]
extraValuedFlags = ["--application-policy", "--vault", "--passphrase-fd"]

{- | Split the @--json@ switch off a command line: describe reads it, no
other command takes it. Only the exact switch is taken; anything else
spells a value or is refused by the tokenizer. A @--key@ value spelled
exactly @--json@ is taken as the switch: spell those bytes with
@--key-hex@.
-}
splitJson :: [String] -> (Bool, [String])
splitJson args = ("--json" `elem` args, filter (/= "--json") args)

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
        "inspect takes no signing key: it reads, and never funds or submits"
    PreviewTakesNoKey ->
        "--preview takes no signing key: name the caller with --wallet-address; a preview reads, and never signs or submits"
    UnsupportedFlag flag command ->
        flag
            <> " is not accepted by `registry "
            <> command
            <> "`: only fold, reclaim and reject enforce it, and a constraint the command does not enforce is refused, never ignored"
    RefusedSetting flag ->
        flag
            <> " is not accepted by `registry describe`: describe reads the public registry and writes nothing"

-- | The supported commands.
usage :: String
usage =
    unlines
        [ "usage:"
        , "  singular registry create [--state-dir ROOT] --blueprint PLUTUS_JSON"
        , "      [--seed TXID#IX] [--preview] [--application-policy HEX] [--process-time MS] [--retract-time MS]"
        , "      --koios-url URL --network-magic N --wallet-skey FILE [--receipt FILE]"
        , "  singular registry create --preview [--state-dir ROOT] --blueprint PLUTUS_JSON"
        , "      [--seed TXID#IX] [--application-policy HEX] [--process-time MS] [--retract-time MS]"
        , "      --koios-url URL --network-magic N --wallet-address ADDR"
        , "  singular registry fold [--state-dir ROOT] --blueprint PLUTUS_JSON"
        , "      --state-token POLICY.NAME"
        , "      --koios-url URL --network-magic N --wallet-skey FILE [--receipt FILE]"
        , "      [--request TXID#IX] [--fund-input TXID#IX] [--max-outlay LOVELACE]"
        , "  singular registry reclaim [--state-dir ROOT] --blueprint PLUTUS_JSON --request TXID#IX"
        , "      --state-token POLICY.NAME"
        , "      --koios-url URL --network-magic N --wallet-skey FILE [--receipt FILE]"
        , "      [--fund-input TXID#IX] [--max-outlay LOVELACE]"
        , "  singular registry reject [--state-dir ROOT] --blueprint PLUTUS_JSON"
        , "      --state-token POLICY.NAME"
        , "      --koios-url URL --network-magic N --wallet-skey FILE [--receipt FILE]"
        , "      [--fund-input TXID#IX] [--max-outlay LOVELACE]"
        , "  singular registry inspect [--state-dir ROOT] --blueprint PLUTUS_JSON (--key KEY | --key-hex HEX)"
        , "      --state-token POLICY.NAME"
        , "      --koios-url URL --network-magic N [--receipt FILE] [--outputs-at ADDR]"
        , "      [--wallet-address ADDR]"
        , "  singular registry describe --blueprint PLUTUS_JSON --state-token POLICY.NAME"
        , "      --koios-url URL --network-magic N [--json]"
        , "  singular wallet create --vault FILE --network-magic N [--passphrase-fd FD]"
        , "  singular wallet address --vault FILE --network-magic N [--passphrase-fd FD]"
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
        , "Write commands also take --confirm-timeout SECONDS (default 600): past it"
        , "the command stops with its submission journalled and never resubmits."
        , "Every command uses Koios; former backend selectors and socket settings are refused."
        , "The wallet commands are local: they take no provider, blueprint or registry"
        , "setting, and refuse each by name. A wallet command draws a fresh payment"
        , "signing key from the operating system's entropy, seals it into the vault"
        , "path with the passphrase, and prints the enterprise address of the key for"
        , "the network named; opening the same vault with the same passphrase prints"
        , "the same address. The passphrase is read from the terminal with the echo"
        , "off, twice on a creation, or as one line from an inherited descriptor. It"
        , "is never taken as an argument, and no output, refusal or trace names it."
        , "Every registry command also takes --koios-token-file FILE for a bearer credential;"
        , "the shared HTTP client reads it without exposing a command-line token."
        , "Every registry command also takes --network-time DIR for pinned time-manifest.json,"
        , "shelley-genesis.json and era-history.cbor; preprod uses the package when omitted."
        , "Every command also takes --trace off|what|how, --trace-to stderr|file:PATH and --trace-format text|json:"
        , "it narrates its protocol steps, and at how their mechanics, to each sink named, the"
        , "option repeated per sink, or to standard error. With no level named it narrates what"
        , "on a terminal and nothing otherwise; text goes to standard error and JSON lines to a"
        , "file unless a format is named. Standard output carries the receipt alone."
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
        , "fold, reclaim and reject fund and collateralise from the funding"
        , "input named, and hold to the maximum outlay stated: a reclaim, reject or"
        , "fold past it is not signed. create and inspect"
        , "refuse both settings: they enforce neither."
        , "The preview forms name the caller by a public wallet address instead of a"
        , "signing key: they build and measure what they would submit, print it, and"
        , "sign, submit and journal nothing."
        , "A registry key is 1 to 32 bytes: KEY is read as text, its UTF-8 bytes, and HEX as"
        , "base16. A key is named once, by one of the two."
        , "inspect also lists the registry's pending requests with what each actually locks,"
        , "and the outputs at a public address it is given: reads apart from any write."
        , "describe reads the registry page from the chain alone: which registry this is,"
        , "which release it runs, what its rules are and what it holds now. It takes no"
        , "wallet, key, state directory or other actor file: every such setting is refused"
        , "by name before anything is read. With the json switch it prints the page as JSON,"
        , "otherwise as text; a success prints the page alone and writes no file. The version"
        , "label comes from the version file beside the blueprint and is refused by name when"
        , "missing, unreadable or malformed."
        , "Each command prints one JSON receipt on standard output. inspect reads"
        , "only: it takes no signing key and submits nothing. Given a wallet address"
        , "it reconciles that caller's managed journal, as a write would; without one"
        , "it is a stateless chain read that checks no wallet journal and creates"
        , "no state."
        ]

{- | The reference roles a command's transactions run, and so the only
references it looks up.
-}
neededRoles :: Command -> Set ReferenceRole
neededRoles = \case
    Create _ _ -> Set.singleton RoleState
    Describe _ -> Set.empty
    Fold _ -> everything
    Reject _ -> Set.fromList [RoleState, RoleRequest]
    Reclaim _ -> Set.empty
    Inspect _ -> Set.empty
    WalletCreate _ -> Set.empty
    WalletAddress _ -> Set.empty
    Help -> Set.empty
  where
    everything = Set.fromList [minBound .. maxBound]

-- * The wallet verbs

-- | Where a wallet command's passphrase comes from.
passphraseSource :: Maybe Int -> PassphraseSource
passphraseSource = maybe PassphraseTerminal PassphraseDescriptor

-- | The enterprise address of a key on a network, as one printed line.
addressOf :: Word32 -> SignKeyDSIGN Ed25519DSIGN -> String
addressOf magic key =
    bech32Address (walletAddr (walletFromSignKey magic key))

{- | @wallet create@: draw a fresh signing key, seal it into a new
vault with the passphrase asked twice (echo off on a terminal, one
line from a descriptor), and print the key's enterprise address on one
standard output line. Every refusal names its cause on standard error,
prints nothing on standard output, and removes any file this run made.
-}
walletCreateCommand :: WalletArgs -> IO ExitCode
walletCreateCommand WalletArgs{..} =
    readPassphrase AskTwice (passphraseSource walletPassphraseFd) >>= \case
        Left refusal -> walletRefused (renderPassphraseRefusal refusal)
        Right passphrase -> do
            key <- freshSignKey
            sealed <- sealVault vaultWorkFactor passphrase key
            case sealed of
                Left refusal -> walletRefused (renderVaultRefusal refusal)
                Right bytes ->
                    createVaultFile walletVaultPath bytes >>= \case
                        Left refusal -> walletRefused (renderVaultRefusal refusal)
                        Right () -> do
                            putStrLn (addressOf walletNetworkMagic key)
                            pure ExitSuccess

{- | @wallet address@: open the vault with the passphrase asked once,
and print exactly the address @wallet create@ printed for the same
network.
-}
walletAddressCommand :: WalletArgs -> IO ExitCode
walletAddressCommand WalletArgs{..} =
    readPassphrase AskOnce (passphraseSource walletPassphraseFd) >>= \case
        Left refusal -> walletRefused (renderPassphraseRefusal refusal)
        Right passphrase -> do
            bytes <- BS.readFile walletVaultPath
            case openVault passphrase bytes of
                Left _ ->
                    walletRefused
                        ( "cannot open vault "
                            <> walletVaultPath
                            <> ": wrong passphrase, corrupt file, or not a singular vault"
                        )
                Right key -> do
                    putStrLn (addressOf walletNetworkMagic key)
                    pure ExitSuccess

{- | One line on standard error naming the cause, nothing on standard
output, exit 1. No refusal names the passphrase or the key.
-}
walletRefused :: String -> IO ExitCode
walletRefused line = do
    hPutStrLn stderr ("singular: " <> line)
    pure (ExitFailure 1)
