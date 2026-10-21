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
  accepts no wallet, key, state directory or other actor file at all;
* @submit@ sends a bundle its signers witnessed, taking the witness
  files, the bundle and the node settings, and no wallet key or vault.

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
    , parseInvocationFrom
    , loadInvocationSources
    , parseWithGroup
    , renderCLIError
    , usage
    , singularVersion
    , singularHint
    , refusalHint
    , maxKeyBytes
    , keyFlags

      -- * The wallet verbs
    , walletCreateCommand
    , walletAddressCommand
    , SignArgs (..)
    , walletSignCommand

      -- * Submitting a signed bundle
    , SubmitArgs (..)
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
import Data.List (partition)
import Data.Maybe (fromMaybe, isJust, isNothing)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Version (Version)
import Data.Word (Word32)
import GHC.Generics (Generic)
import System.Exit (ExitCode (..))
import System.IO (hPutStrLn, stderr)
import Text.Read (readMaybe)

import Cardano.Crypto.DSIGN (Ed25519DSIGN, SignKeyDSIGN)
import Cardano.Ledger.TxIn (TxIn)
import Paths_singular_registry qualified as Paths
import Singular.CLI.Declared (saveStateToken)
import Singular.CLI.FlagGroup
    ( Signer (..)
    , commonFlagGroup
    , commonSwitches
    , parseFlagGroup
    , readProviderSettings
    , traceFlags
    , traceRequestFrom
    )
import Singular.CLI.Help (singularHelp, singularProgram)
import Singular.CLI.Key
    ( KeyEncoding (..)
    , KeyRefusal (..)
    , keyFlags
    , maxKeyBytes
    , readKey
    )
import Singular.CLI.Options
    ( Accepted (..)
    , Flag (..)
    , Raw (..)
    , defaultConfigFile
    , hintLines
    , identityLine
    , readLine
    , refusalAs
    , resolvePath
    )
import Singular.CLI.Passphrase
    ( Confirmation (..)
    , namedSource
    , readPassphrase
    , renderPassphraseRefusal
    , sourceFor
    )
import Singular.CLI.Registry (economics)
import Singular.CLI.Sign (signBundle)
import Singular.CLI.Sources
    ( Sources (..)
    , applySources
    , configPath
    , loadSources
    , missingHint
    , noSources
    , sourceConflict
    )
import Singular.CLI.Trace (TraceRequest (..))
import Singular.CLI.Vault
    ( VaultRefusal (..)
    , createVaultFile
    , freshSignKey
    , openVault
    , readVaultFile
    , renderVaultRefusal
    , sealVault
    , vaultPathTaken
    , vaultWorkFactor
    )
import Singular.CLI.Version (releaseVersion)
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

{- | The node and the wallet a write command funds and signs from, or the
external signer it stages for: one signer names the run.
-}
data WriteSettings = WriteSettings
    { writeProvider :: ProviderSettings
    , writeSigner :: Signer
    -- ^ The key file, or the address with its bundle file; read, never printed
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
    , createSaveStateTokenTo :: Maybe FilePath
    {- ^ @--save-state-token@: the settings file that takes the new registry's
    state token when the create succeeds, as the commands read it (@--config@,
    else @SINGULAR_CONFIG@, else @singular.json@ in the working directory)
    -}
    , createProcessTime :: Integer
    -- ^ Positive processing window in milliseconds, fixed at creation
    , createRetractTime :: Integer
    -- ^ Positive retract window in milliseconds, fixed at creation
    }
    deriving stock (Eq, Show)

{- | @registry describe@: the token, the blueprint, a provider and a network.

Never a wallet, key, state directory or other actor file: those are
refused with their names before anything is read. The page prints as
indented JSON; @--json@ is accepted and changes nothing.
-}
data DescribeArgs = DescribeArgs
    { describeBlueprint :: FilePath
    , describeAccess :: RegistryAccess
    {- ^ The registry, by its state token: required, as on every command
    but create.
    -}
    , describeProvider :: ProviderSettings
    , describeJson :: Bool
    -- ^ @--json@ given: accepted for scripts that pass it, the page is JSON either way
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

{- | @wallet sign@: the vault, the bundle file, the passphrase source
and the output directory the witness files go to. The network is not
named here: a bundle carries its own network magic, and the vault's
address is derived for it.
-}
data SignArgs = SignArgs
    { signVaultPath :: FilePath
    -- ^ The encrypted vault file the key is opened from
    , signBundlePath :: FilePath
    -- ^ The bundle of unsigned transactions, the command's one argument
    , signPassphraseFd :: Maybe Int
    -- ^ @--passphrase-fd N@: the inherited descriptor read for the passphrase
    , signOutputDir :: Maybe FilePath
    {- ^ @--out DIR@: where the witness files go; the bundle's directory
    when not named
    -}
    }
    deriving stock (Eq, Show)

{- | @submit@: the witness files, the bundle, the node settings and the
receipt file. A directory among the witness paths stands for the
@.witness@ files it holds. No wallet key and no vault: the witnesses
carry every signature the bundle needs.
-}
data SubmitArgs = SubmitArgs
    { submitBundlePath :: FilePath
    -- ^ The bundle of unsigned transactions, the command's one argument
    , submitWitnessPaths :: [FilePath]
    -- ^ @--witnesses@, repeated: witness files or directories, in order
    , submitProvider :: ProviderSettings
    -- ^ The node settings, read exactly as the registry commands read them
    , submitReceipt :: Maybe FilePath
    -- ^ @--receipt FILE@: also write the receipt here
    }
    deriving stock (Eq, Show)

-- | One parsed command line.
data Command
    = {- | A help page or the version line, to print as it stands: the command
      line asked for it, so nothing else runs
      -}
      Help String
    | Create CreateArgs (Maybe ApplicationPolicy)
    | Describe DescribeArgs
    | Fold FoldArgs
    | Reject RejectArgs
    | Reclaim ReclaimArgs
    | Inspect InspectArgs
    | WalletCreate WalletArgs
    | WalletAddress WalletArgs
    | WalletSign SignArgs
    | SubmitBundle SubmitArgs
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
    | -- | the settings the config file or the environment give cannot be used, said in one sentence
      ConfigRefused String
    deriving stock (Eq, Show)

-- | Parse a command line.
parseCommand :: [String] -> Either CLIError Command
parseCommand = parseWith []

-- | Parse a command line with its environment.
parseWith :: [(String, String)] -> [String] -> Either CLIError Command
parseWith = parseWithGroup (commonFlagGroup <> extraValuedFlags)

{- | Parse a command line with its environment over an explicit flag group:
the command line is read over exactly these valued flags. The exported
parser applies this to the common group plus this binary's extras.
-}
parseWithGroup
    :: [String] -> [(String, String)] -> [String] -> Either CLIError Command
parseWithGroup group environment args =
    readFlags group args
        >>= commandFrom environment
            . applySources
                (singularProgram singularVersion)
                (noSources environment)

{- | Read a command line over the valued flags a binary owns, with the
switches every binary reads. The reading is the library's; what a flag
means, and which command refuses it, is the command's.
-}
readFlags :: [String] -> [String] -> Either CLIError Raw
readFlags group =
    first (refusalAs RemovedSetting BadValue "singular")
        . readLine
            Accepted
                { acceptedValued = group <> ["--witnesses", "--config"]
                , acceptedEarly = ["--json"]
                , acceptedSwitches =
                    commonSwitches <> ["--version", flagName saveStateToken]
                }

{- | What a command line read flat asks for. The switches and the repeated
@--witnesses@ are taken out of the flags, which keep their first occurrence
first, as the commands read them.
-}
commandFrom :: [(String, String)] -> Raw -> Either CLIError Command
commandFrom environment (Raw ws allFlags) = do
    let jsonSwitch = any ((== "--json") . fst) allFlags
        witnesses = [v | ("--witnesses", Just v) <- allFlags]
        flags =
            [ flag
            | flag@(name, _) <- allFlags
            , name `notElem` ["--json", "--witnesses", "--version", "--config"]
            ]
        helpAsked = "--help" `elem` map fst flags
        askedFor =
            Help
                ( singularHelp
                    singularVersion
                    environment
                    (fst (resolvePath (singularProgram singularVersion) ws))
                )
    if helpAsked
        then Right askedFor
        else
            if any ((== "--version") . fst) allFlags
                then
                    Right
                        ( Help
                            (identityLine (singularProgram singularVersion) environment <> "\n")
                        )
                else
                    refuseWindows ws flags
                        >> refuseSaveStateToken ws flags
                        >> refuseOutputsAt ws flags
                        >> refuseJson ws jsonSwitch
                        >> refuseWitnesses ws witnesses
                        >> refuseWalletSettings ws flags
                        >> case ws of
                            [] -> Right askedFor
                            ["registry"] -> Right askedFor
                            ["wallet"] -> Right askedFor
                            ["wallet", "create"] ->
                                refuseWalletCommandSettings "wallet create" flags
                                    >> (WalletCreate <$> walletArgs flags)
                            ["wallet", "address"] ->
                                refuseWalletCommandSettings "wallet address" flags
                                    >> (WalletAddress <$> walletArgs flags)
                            ["wallet", "sign", bundle] ->
                                refuseWalletCommandSettings "wallet sign" flags
                                    >> (WalletSign <$> signArgs bundle flags)
                            ["wallet", "sign"] ->
                                Left (MissingFlag "BUNDLE")
                            ["submit", bundle] ->
                                SubmitBundle <$> submitArgs bundle witnesses flags
                            ["submit"] ->
                                Left (MissingFlag "BUNDLE")
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
                                    >> refuseBundle "registry inspect" flags
                                    >> refuseRequest flags
                                    >> refuseFold flags
                                    >> (Inspect <$> inspectArgs environment flags)
                            ["registry", "describe"] ->
                                refuseApplicationPolicy flags
                                    >> refuseDescribeSettings flags
                                    >> (Describe <$> describeArgs environment flags jsonSwitch)
                            _ -> Left (UnknownCommand ws)
  where
    -- @--witnesses@ names what @submit@ sends; any other command refuses
    -- it by name rather than ignore it.
    refuseWitnesses words' witnesses =
        when (not (null witnesses) && take 1 words' /= ["submit"]) $
            Left
                ( BadValue
                    "--witnesses"
                    "is a submit flag: only submit reads witness files"
                )
    refuseJson words' json =
        when (json && words' /= ["registry", "describe"]) $
            Left
                ( BadValue
                    "--json"
                    "is a registry describe flag: only describe prints the page as JSON"
                )
    -- @--save-state-token@ keeps the name of the registry a create makes; any
    -- other command refuses it by name rather than ignore it.
    refuseSaveStateToken words' flags =
        when
            ( isJust (lookup saveSwitch flags)
                && words' /= ["registry", "create"]
            )
            $ Left
                ( BadValue
                    saveSwitch
                    "is a create flag: only create keeps the registry's name"
                )
    saveSwitch = flagName saveStateToken
    -- It is judged before anything else of the create is: a preview creates
    -- nothing and an external signer's registry does not exist until its bundle
    -- is submitted, so neither has a name to keep. The file is the one the
    -- settings are read from.
    saveTarget flags
        | isNothing (lookup saveSwitch flags) = Right Nothing
        | isJust (lookup "--preview" flags) =
            Left
                ( BadValue
                    saveSwitch
                    "cannot be used with --preview: nothing is created, so there is no name to keep"
                )
        | isJust (lookup "--wallet-address" flags)
            && isJust (lookup "--bundle" flags) =
            Left
                ( BadValue
                    saveSwitch
                    "cannot be used with --wallet-address and --bundle: the registry does not exist until the bundle is submitted, so there is no name to keep yet"
                )
        | otherwise =
            Right
                ( Just
                    ( fromMaybe
                        defaultConfigFile
                        (configPath environment (Raw ws allFlags))
                    )
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
    -- @--bundle@ is where a write's run goes for signing elsewhere; a
    -- command that writes nothing refuses it by name rather than ignore it.
    refuseBundle command flags =
        when (isJust (lookup "--bundle" flags)) $
            Left
                ( BadValue
                    "--bundle"
                    ("is a write flag: " <> command <> " writes nothing")
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
    -- The output directory belongs to the wallet verbs alone, and the
    -- vault and its passphrase descriptor to them and the four registry
    -- writes, which sign from the vault; any other command refuses each by
    -- name rather than ignore it.
    refuseWalletSettings words' flags =
        unless (take 1 words' == ["wallet"]) $ do
            when (isJust (lookup "--out" flags)) $
                Left
                    ( BadValue
                        "--out"
                        "is a wallet flag: only singular wallet commands read it"
                    )
            unless (words' `elem` registryWrites) $
                forM_ ["--vault", "--passphrase-fd"] $ \flag ->
                    when (isJust (lookup flag flags)) $
                        Left
                            ( BadValue
                                flag
                                "is a signer flag: only the wallet commands and the registry writes read it"
                            )
    registryWrites =
        [["registry", w] | w <- ["create", "fold", "reject", "reclaim"]]
    -- A wallet command takes its own flags and nothing else from
    -- the shared group: every other setting is refused by name rather
    -- than ignored.
    refuseWalletCommandSettings command flags =
        forM_ (commonFlagGroup <> extraValuedFlags) $ \flag ->
            unless (flag `elem` allowed) $
                when (isJust (lookup flag flags)) $
                    Left
                        ( BadValue
                            flag
                            ( "is not accepted by "
                                <> command
                                <> ": "
                                <> taken
                            )
                        )
      where
        (allowed, taken)
            | command == "wallet sign" =
                ( ["--vault", "--passphrase-fd", "--out"]
                , "the network comes from the bundle; it takes the vault, the passphrase descriptor, the output directory and the bundle file"
                )
            | otherwise =
                ( ["--network-magic", "--vault", "--passphrase-fd"]
                , "a wallet command takes only its vault, network magic and passphrase descriptor"
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
        , "--bundle"
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
        saveTo <- saveTarget flags
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
                , createSaveStateTokenTo = saveTo
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
    previewMode flags = do
        when (isJust (lookup "--wallet-skey" flags)) $
            Left PreviewTakesNoKey
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
    signArgs bundle flags = do
        vault <- required "--vault" flags
        fd <- case optional "--passphrase-fd" flags of
            Nothing -> Right Nothing
            Just spelling -> case readMaybe spelling of
                Just n | n >= 0 -> Right (Just n)
                _ -> Left (BadValue "--passphrase-fd" "not a descriptor number")
        pure
            SignArgs
                { signVaultPath = vault
                , signBundlePath = bundle
                , signPassphraseFd = fd
                , signOutputDir = optional "--out" flags
                }
    -- @submit@ takes the node settings and a receipt file and nothing
    -- else from the shared group: no wallet key, no registry setting,
    -- each refused by name rather than ignored.
    submitArgs bundle witnesses flags = do
        forM_ (commonFlagGroup <> extraValuedFlags <> ["--preview", "--fold"]) $ \flag ->
            unless (flag `elem` submitTakes) $
                when (isJust (lookup flag flags)) $
                    Left
                        ( BadValue
                            flag
                            ( if flag == "--wallet-skey"
                                then
                                    "is not accepted by submit: it takes no wallet key and no vault, the witnesses carry every signature"
                                else
                                    "is not accepted by submit: it takes the witnesses, the bundle, the node settings and a receipt file"
                            )
                        )
        when (null witnesses) $ Left (MissingFlag "--witnesses")
        settings <- readProviderSettings MissingFlag BadValue flags
        when (providerMagic settings == 764824073) $
            Left (UnsafeSettings "mainnet is not supported")
        pure
            SubmitArgs
                { submitBundlePath = bundle
                , submitWitnessPaths = witnesses
                , submitProvider = settings
                , submitReceipt = optional "--receipt" flags
                }
    submitTakes =
        [ "--koios-url"
        , "--koios-token-file"
        , "--network-time"
        , "--network-magic"
        , "--receipt"
        ]
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
parseCommandWithEnvironment environment args =
    refuseObsoleteEnvironment environment >> parseWith environment args

refuseObsoleteEnvironment :: [(String, String)] -> Either CLIError ()
refuseObsoleteEnvironment environment =
    when (isJust (lookup "SINGULAR_NODE_SOCKET" environment)) $
        Left (RemovedSetting "SINGULAR_NODE_SOCKET")

{- | A whole command line: the command, and the tracing it asks for with
@--trace@, @--trace-to@ and @--trace-format@. Every command takes the three.
-}
parseInvocation
    :: [(String, String)]
    -> [String]
    -> Either CLIError (Command, TraceRequest)
parseInvocation = parseInvocationFrom . noSources

{- | The same over the settings the environment and the config file give: a
setting the command line leaves out is read from the environment, then from
the file. A file that cannot be used is refused for a command that runs, and
ignored for a request for help.
-}
parseInvocationFrom
    :: Sources
    -> [String]
    -> Either CLIError (Command, TraceRequest)
parseInvocationFrom sources args = do
    raw <- readFlags invocationFlags args
    mapM_
        (Left . ConfigRefused)
        (sourceConflict (singularProgram singularVersion) sources raw)
    let environment = sourceEnvironment sources
        filled = applySources (singularProgram singularVersion) sources raw
        (tracing, rest) =
            partition ((`elem` traceFlags) . fst) (rawFlags filled)
    request <-
        traceRequestFrom BadValue [(name, v) | (name, Just v) <- tracing]
    refuseObsoleteEnvironment environment
    command <- case ( commandFrom environment filled{rawFlags = rest}
                    , sourceConfig sources
                    ) of
        (Right help@(Help _), _) -> Right help
        (_, Left why) -> Left (ConfigRefused why)
        (result, Right _) -> result
    pure (command, request)

-- | The settings the environment and the config file give for a command line.
loadInvocationSources :: [(String, String)] -> [String] -> IO Sources
loadInvocationSources environment args =
    case readFlags invocationFlags args of
        Right raw -> loadSources (singularProgram singularVersion) environment raw
        Left _ -> pure (noSources environment)

-- | The valued flags a whole command line carries.
invocationFlags :: [String]
invocationFlags = commonFlagGroup <> extraValuedFlags <> traceFlags

{- | The valued flags this binary owns beyond the common group: create pins
an application policy, and the wallet commands name an output directory.
-}
extraValuedFlags :: [String]
extraValuedFlags = ["--application-policy", "--out"]

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
    ConfigRefused why -> why
    RefusedSetting flag ->
        flag
            <> " is not accepted by `registry describe`: describe reads the public registry and writes nothing"

-- | The overview of the supported commands: the page `singular --help` prints.
usage :: String
usage = singularHelp singularVersion [] []

-- | The version the program was built as.
singularVersion :: Version
singularVersion = releaseVersion Paths.version

{- | What a refused command line adds below the refusal: the nearest command
when a word was mistyped, the usage of the command it was heading for and
where its help is.
-}
singularHint :: [String] -> [String]
singularHint line =
    hintLines
        (singularProgram singularVersion)
        (either (const line) rawWords (readFlags invocationFlags line))

{- | What a refusal says below its line: for a missing standing setting, the
three ways to give it.
-}
refusalHint :: CLIError -> [String]
refusalHint = \case
    MissingFlag name -> missingHint (singularProgram singularVersion) name
    _ -> []

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
    WalletSign _ -> Set.empty
    SubmitBundle _ -> Set.empty
    Help _ -> Set.empty
  where
    everything = Set.fromList [minBound .. maxBound]

-- * The wallet verbs

-- | The enterprise address of a key on a network, as one printed line.
addressOf :: Word32 -> SignKeyDSIGN Ed25519DSIGN -> String
addressOf magic key =
    bech32Address (walletAddr (walletFromSignKey magic key))

{- | @wallet create@: draw a fresh signing key, seal it into a new
vault with the passphrase asked twice (echo off on a terminal, one
line from a descriptor, or the variable on a development network), and
print the key's enterprise address on one standard output line. Every
refusal names its cause on standard error, prints nothing on standard
output, and removes any file this run made.
-}
walletCreateCommand :: WalletArgs -> IO ExitCode
walletCreateCommand WalletArgs{..} =
    vaultPathTaken walletVaultPath >>= \case
        True ->
            walletRefused (renderVaultRefusal (VaultPathExists walletVaultPath))
        False ->
            sourceFor walletNetworkMagic walletPassphraseFd >>= \case
                Left refusal -> walletRefused (renderPassphraseRefusal refusal)
                Right source ->
                    readPassphrase AskTwice source >>= \case
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
    sourceFor walletNetworkMagic walletPassphraseFd >>= \case
        Left refusal -> walletRefused (renderPassphraseRefusal refusal)
        Right source ->
            readVaultFile walletVaultPath >>= \case
                Left refusal -> walletRefused (renderVaultRefusal refusal)
                Right bytes ->
                    readPassphrase AskOnce source >>= \case
                        Left refusal -> walletRefused (renderPassphraseRefusal refusal)
                        Right passphrase -> case openVault passphrase bytes of
                            Left _ ->
                                walletRefused
                                    ( "cannot open vault "
                                        <> walletVaultPath
                                        <> ": wrong passphrase, corrupt file, or not a singular vault"
                                    )
                            Right key -> do
                                putStrLn (addressOf walletNetworkMagic key)
                                pure ExitSuccess

{- | @wallet sign@: witness a bundle of unsigned transactions from the
vault, offline — one witness file per transaction, named by its
identity and created exclusively. See "Singular.CLI.Sign".
-}
walletSignCommand :: SignArgs -> IO ExitCode
walletSignCommand SignArgs{..} = do
    source <- namedSource signPassphraseFd
    signBundle signBundlePath signVaultPath source signOutputDir

{- | One line on standard error naming the cause, nothing on standard
output, exit 1. No refusal names the passphrase or the key.
-}
walletRefused :: String -> IO ExitCode
walletRefused line = do
    hPutStrLn stderr ("singular: " <> line)
    pure (ExitFailure 1)
