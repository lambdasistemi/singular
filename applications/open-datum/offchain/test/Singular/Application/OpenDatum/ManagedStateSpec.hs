{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.Application.OpenDatum.ManagedStateSpec
Description : #485 managed state: commands run without a directory argument
License     : Apache-2.0

Bob receives Carl's public state token and runs inspect, booking, fold and
readback with no directory argument and no pre-created per-registry state:
every existing-registry command works without @--state-dir@, which remains
only as an optional state-root override with the same identity partitioning.
A new participant's lack of files is never a refusal.

These rows run the effect-free parser over the real module. Each identity is
spelled inline; the token is a well-formed POLICY.NAME the real token reader
accepts. Resolver identity partitioning (network, complete token, stable
wallet identity) and the connected fresh-Bob proof are the track's next rows,
not these.
-}
module Singular.Application.OpenDatum.ManagedStateSpec (spec) where

import Control.Exception (SomeException, try)
import Control.Monad (forM_)
import Control.Tracer (Tracer (..))
import Data.ByteString qualified as BS
    ( readFile
    , replicate
    , writeFile
    )
import Data.Either (isLeft, isRight)
import Data.List (isInfixOf)
import Data.Text qualified as T (pack, unpack)
import Singular.Application.OpenDatum.Command
    ( CLIError (BadValue)
    , EntryArgs (EntryArgs, entryAccess, entryMode, entryStateDir)
    , EntryMode (Submit)
    , FoldArgs (FoldArgs, foldAccess, foldStateDir, foldWrite)
    , OpenDatumCommand (OpenFold, OpenInsert, OpenTerminate, OpenUpdate)
    , ProviderSettings (providerMagic)
    , RegistryAccess (accessToken)
    , Signer
        ( SignerExternal
        , SignerKeyFile
        , SignerVault
        , SignerVaultOpened
        )
    , WriteSettings (writeProvider, writeSigner)
    , openDatumHelp
    , parseOpenDatumCommand
    )
import Singular.Application.OpenDatum.Entry
    ( runInsert
    , runTerminate
    , runUpdate
    )
import Singular.Application.OpenDatum.StateTokenFixture
    ( release
    , token
    )
import Singular.Application.OpenDatum.Value
    ( openDatumApplication
    )
import Singular.CLI.FlagGroup (signerAddress)
import Singular.CLI.Fold (runFold)
import Singular.CLI.ManagedState
    ( addressPartition
    , managedDir
    , resolveSignerDir
    )
import Singular.CLI.Receipt (OutcomeClass (..))
import Singular.CLI.Session (CommandFailure (..), Env (..))
import Singular.Registry.StateToken (renderStateToken)
import Singular.Registry.Wallet
    ( Wallet (..)
    , bech32Address
    , loadWallet
    )
import System.Directory (doesFileExist)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec
    ( Spec
    , describe
    , it
    , shouldReturn
    , shouldSatisfy
    )

spec :: Spec
spec = describe "managed state command line (#485)" $ do
    directoryOptional
    rootOverride
    noWeakening
    externalWriteRows

{- | The external signer's writes (#642 slice 1, ruled by the ticket
owner: no fixture that serves history): each complete external line is
parsed by the real parser; the shared signer step every write runs first
refuses a bundle path that already exists, its bytes untouched, before
any chain read; and a complete line against a provider that is not
listening stops without writing a bundle file or a journal line. Which
refusal such a run ends with is slice 2's question, not asserted here.
The address is produced from a real key file; the bundle path and the
state root live in one temp directory, so the rows observe everything
the run could have written.
-}
externalWriteRows :: Spec
externalWriteRows =
    describe "an external write stops before anything is written" $ do
        it
            "refuses an existing bundle file on every write, its bytes untouched, before any chain read"
            $ withExternalDir
            $ \root addr bundlePath _env -> do
                payload <- payloadFile root
                BS.writeFile bundlePath sentinelBytes
                forM_
                    [ insertLine root addr bundlePath payload False
                    , insertLine root addr bundlePath payload True
                    , updateLine root addr bundlePath payload
                    , terminateLine root addr bundlePath
                    , foldLine root addr bundlePath
                    ]
                    (>>= refusedOnTheBundle)
                BS.readFile bundlePath `shouldReturn` sentinelBytes
        it
            "a fold onto an existing bundle file stops before the provider is contacted"
            $ withExternalDir
            $ \root addr bundlePath env -> do
                BS.writeFile bundlePath sentinelBytes
                command <- foldLine root addr bundlePath
                stopped <- try (runFold openDatumApplication env (asFold command))
                stopped `shouldSatisfy` \case
                    Left failure -> namesTheTakenBundle bundlePath failure
                    Right _ -> False
                BS.readFile bundlePath `shouldReturn` sentinelBytes
                noJournal root addr
        it
            "a complete insert line against a provider that is not listening writes nothing"
            $ withExternalDir
            $ \root addr bundlePath env -> do
                payload <- payloadFile root
                command <- insertLine root addr bundlePath payload False
                stopped <- try (runInsert env (asInsert command))
                stopped `shouldSatisfy` stoppedWithoutWriting
                wroteNothing root addr bundlePath
        it
            "a complete insert line that also folds writes nothing"
            $ withExternalDir
            $ \root addr bundlePath env -> do
                payload <- payloadFile root
                command <- insertLine root addr bundlePath payload True
                stopped <- try (runInsert env (asInsert command))
                stopped `shouldSatisfy` stoppedWithoutWriting
                wroteNothing root addr bundlePath
        it
            "a complete update line against a provider that is not listening writes nothing"
            $ withExternalDir
            $ \root addr bundlePath env -> do
                payload <- payloadFile root
                command <- updateLine root addr bundlePath payload
                stopped <- try (runUpdate env (asUpdate command))
                stopped `shouldSatisfy` stoppedWithoutWriting
                wroteNothing root addr bundlePath
        it
            "a complete terminate line against a provider that is not listening writes nothing"
            $ withExternalDir
            $ \root addr bundlePath env -> do
                command <- terminateLine root addr bundlePath
                stopped <- try (runTerminate env (asTerminate command))
                stopped `shouldSatisfy` stoppedWithoutWriting
                wroteNothing root addr bundlePath
        it
            "a complete fold line against a provider that is not listening writes nothing"
            $ withExternalDir
            $ \root addr bundlePath env -> do
                command <- foldLine root addr bundlePath
                stopped <- try (runFold openDatumApplication env (asFold command))
                stopped `shouldSatisfy` stoppedWithoutWriting
                wroteNothing root addr bundlePath
  where
    sentinelBytes = "sentinel bytes"
    -- The shared signer step every write runs first: the bundle path is
    -- refused by name, its bytes untouched, before any chain read.
    refusedOnTheBundle args = do
        let ws = writeSettingsOf args
        stopped <-
            try
                ( resolveSignerDir
                    (stateDirOf args)
                    (providerMagic (writeProvider ws))
                    (accessToken (accessOf args))
                    (writeSigner ws)
                )
        stopped `shouldSatisfy` \case
            Left failure -> namesTheTakenBundle (bundleOf args) failure
            Right _ -> False
    -- The shared existing-bundle refusal itself: the whole bundle path
    -- is named in the message, with the refusal's own distinguishing
    -- words. The path is spelled in full, never matched componentwise.
    namesTheTakenBundle bundle = \case
        CommandFailure ClientRefusal why _ ->
            bundle `isInfixOf` why && "already exists" `isInfixOf` why
        _ -> False
    -- A complete external line against a provider that is not listening:
    -- the run stops, however it words the refusal. Slice 2 replaces the
    -- stop itself.
    stoppedWithoutWriting = \case
        Left (_ :: SomeException) -> True
        Right _ -> False
    -- Nothing of the run is written: no bundle file, and no journal line
    -- in the partition it resolved. The lock may be taken before a
    -- refusal inside the session, so the directory itself may exist; the
    -- journal must not.
    wroteNothing root addr bundlePath = do
        doesFileExist bundlePath `shouldReturn` False
        noJournal root addr
    noJournal root addr =
        doesFileExist (partitionOf root addr </> "journal.jsonl")
            `shouldReturn` False
    payloadFile root = do
        let path = root </> "payload.json"
        writeFile path "7"
        pure path
    insertLine root addr bundlePath payload withFold = do
        parsed <-
            requireRight $
                parseOpenDatumCommand
                    ( [ "open-datum"
                      , "insert"
                      , "--key"
                      , "ext"
                      , "--payload"
                      , payload
                      ]
                        <> registryArgs root
                        <> provider
                        <> [ "--wallet-address"
                           , addr
                           , "--bundle"
                           , bundlePath
                           ]
                        <> ["--fold" | withFold]
                    )
        case parsed of
            command@(OpenInsert _) -> pure command
            other -> fail ("not an insert: " <> show other)
    updateLine root addr bundlePath payload = do
        parsed <-
            requireRight $
                parseOpenDatumCommand
                    ( [ "open-datum"
                      , "update"
                      , "--key"
                      , "ext"
                      , "--payload"
                      , payload
                      ]
                        <> registryArgs root
                        <> provider
                        <> ["--wallet-address", addr, "--bundle", bundlePath]
                    )
        case parsed of
            command@(OpenUpdate _) -> pure command
            other -> fail ("not an update: " <> show other)
    terminateLine root addr bundlePath = do
        parsed <-
            requireRight $
                parseOpenDatumCommand
                    ( ["open-datum", "terminate", "--key", "ext"]
                        <> registryArgs root
                        <> provider
                        <> ["--wallet-address", addr, "--bundle", bundlePath]
                    )
        case parsed of
            command@(OpenTerminate _) -> pure command
            other -> fail ("not a terminate: " <> show other)
    foldLine root addr bundlePath = do
        parsed <-
            requireRight $
                parseOpenDatumCommand
                    ( ["open-datum", "fold"]
                        <> registryArgs root
                        <> provider
                        <> ["--wallet-address", addr, "--bundle", bundlePath]
                    )
        case parsed of
            command@(OpenFold _) -> pure command
            other -> fail ("not a fold: " <> show other)
    asInsert = \case
        OpenInsert a -> a
        other -> error ("not an insert: " <> show other)
    asUpdate = \case
        OpenUpdate a -> a
        other -> error ("not an update: " <> show other)
    asTerminate = \case
        OpenTerminate a -> a
        other -> error ("not a terminate: " <> show other)
    asFold = \case
        OpenFold a -> a
        other -> error ("not a fold: " <> show other)
    registryArgs root =
        [ "--state-dir"
        , root
        , "--blueprint"
        , "b.json"
        , "--state-token"
        , fixtureTokenSpelling
        ]
    requireRight parsed = case parsed of
        Right a -> pure a
        Left e -> fail ("the external line did not parse: " <> show e)
    -- The settings, directory override, registry access and bundle path of
    -- one parsed write, whichever write it is.
    writeSettingsOf = \case
        OpenInsert EntryArgs{entryMode = Submit w} -> w
        OpenUpdate EntryArgs{entryMode = Submit w} -> w
        OpenTerminate EntryArgs{entryMode = Submit w} -> w
        OpenFold FoldArgs{foldWrite = w} -> w
        other -> error ("not a write: " <> show other)
    stateDirOf = \case
        OpenInsert EntryArgs{entryStateDir = d} -> d
        OpenUpdate EntryArgs{entryStateDir = d} -> d
        OpenTerminate EntryArgs{entryStateDir = d} -> d
        OpenFold FoldArgs{foldStateDir = d} -> d
        other -> error ("not a write: " <> show other)
    accessOf = \case
        OpenInsert EntryArgs{entryAccess = a} -> a
        OpenUpdate EntryArgs{entryAccess = a} -> a
        OpenTerminate EntryArgs{entryAccess = a} -> a
        OpenFold FoldArgs{foldAccess = a} -> a
        other -> error ("not a write: " <> show other)
    bundleOf = \case
        OpenInsert EntryArgs{entryMode = Submit w} -> signerBundle (writeSigner w)
        OpenUpdate EntryArgs{entryMode = Submit w} -> signerBundle (writeSigner w)
        OpenTerminate EntryArgs{entryMode = Submit w} -> signerBundle (writeSigner w)
        OpenFold FoldArgs{foldWrite = w} -> signerBundle (writeSigner w)
        other -> error ("not a write: " <> show other)
    signerBundle = \case
        SignerExternal _ b -> b
        SignerKeyFile _ -> error "the external line parsed without its bundle file"
        SignerVault _ _ -> error "the external line parsed as a vault"
        SignerVaultOpened _ -> error "the external line parsed as an opened vault"
    -- One temp directory, one real key's address, a provider that is not
    -- listening: every read and write of the chain fails loudly, so a row
    -- observes that the run stopped and wrote nothing.
    withExternalDir use =
        withSystemTempDirectory "external-write" $ \root -> do
            addr <- externalAddress root
            use root addr (root </> "run.bundle") notListening
    notListening =
        Env
            { envTracer = Tracer (\_ -> pure ())
            , envSource = "test"
            , envLoadRelease = \_ _ -> pure (Right release)
            , envReads =
                \_ _ ->
                    fail
                        "the provider is not listening: the run must stop before any chain read"
            , envWrites =
                \_ _ ->
                    fail
                        "the provider is not listening: the run must stop before any chain write"
            }
    -- The partition directory this signer resolves under the root: the
    -- address's own payment identity, never a file the run leaves behind.
    partitionOf root addr =
        managedDir
            root
            42
            token
            ( either
                (error . ("partitionOf: " <>))
                addressPartition
                (signerAddress (T.pack addr))
            )

-- | A bech32 payment-key address of a real key file written here.
externalAddress :: FilePath -> IO String
externalAddress root = do
    let path = root </> "payment.skey"
    BS.writeFile path (BS.replicate 32 0xa5)
    signing <- loadWallet 42 path
    pure (bech32Address (walletAddr signing))

provider :: [String]
provider =
    [ "--koios-url"
    , "http://127.0.0.1:8080/api/v1"
    , "--network-magic"
    , "42"
    ]

wallet :: [String]
wallet = ["--wallet-skey", "/keys/payment.skey"]

-- | A well-formed state token POLICY.NAME: 28 policy bytes, 32 name bytes.
tokenSpelling :: String
tokenSpelling = replicate 56 'a' <> "." <> replicate 64 'b'

tokenArgs :: [String]
tokenArgs = ["--state-token", tokenSpelling]

{- | The booted registry's own token, rendered by the library: the chain
fixture serves this registry, so the external lines name it.
-}
fixtureTokenSpelling :: String
fixtureTokenSpelling = T.unpack (renderStateToken token)

seedText :: String
seedText = replicate 64 'b' <> "#1"

directoryOptional :: Spec
directoryOptional = describe "every command works without --state-dir" $ do
    it "create books from seed, blueprint, provider and wallet alone" $
        parseOpenDatumCommand
            ( [ "open-datum"
              , "create"
              , "--seed"
              , seedText
              , "--blueprint"
              , "/srv/plutus.json"
              ]
                <> provider
                <> wallet
            )
            `shouldSatisfy` isRight
    it "insert books from token, key, payload, provider and wallet alone" $
        parseOpenDatumCommand
            ( [ "open-datum"
              , "insert"
              , "--key"
              , "bob"
              , "--payload"
              , "/srv/doc.json"
              , "--blueprint"
              , "/srv/plutus.json"
              ]
                <> tokenArgs
                <> provider
                <> wallet
            )
            `shouldSatisfy` isRight
    it "fold runs from token, provider and wallet alone" $
        parseOpenDatumCommand
            ( ["open-datum", "fold", "--blueprint", "/srv/plutus.json"]
                <> tokenArgs
                <> provider
                <> wallet
            )
            `shouldSatisfy` isRight
    it
        "inspect reads from token, key, blueprint and provider alone, key-free"
        $ parseOpenDatumCommand
            ( [ "open-datum"
              , "inspect"
              , "--key"
              , "bob"
              , "--blueprint"
              , "/srv/plutus.json"
              ]
                <> tokenArgs
                <> provider
            )
            `shouldSatisfy` isRight
    it "terminate books from token, key, provider and wallet alone" $
        parseOpenDatumCommand
            ( [ "open-datum"
              , "terminate"
              , "--key"
              , "bob"
              , "--blueprint"
              , "/srv/plutus.json"
              ]
                <> tokenArgs
                <> provider
                <> wallet
            )
            `shouldSatisfy` isRight
    it "usage documents the managed default state location" $
        openDatumHelp ["insert"] `shouldSatisfy` isInfixOf "XDG_STATE_HOME"

rootOverride :: Spec
rootOverride = describe "an explicit --state-dir stays a root override" $ do
    it "insert still accepts --state-dir" $
        parseOpenDatumCommand
            ( [ "open-datum"
              , "insert"
              , "--key"
              , "bob"
              , "--payload"
              , "/srv/doc.json"
              , "--blueprint"
              , "/srv/plutus.json"
              , "--state-dir"
              , "/srv/root"
              ]
                <> tokenArgs
                <> provider
                <> wallet
            )
            `shouldSatisfy` isRight
    it "inspect still accepts --state-dir" $
        parseOpenDatumCommand
            ( [ "open-datum"
              , "inspect"
              , "--key"
              , "bob"
              , "--blueprint"
              , "/srv/plutus.json"
              , "--state-dir"
              , "/srv/root"
              ]
                <> tokenArgs
                <> provider
            )
            `shouldSatisfy` isRight

noWeakening :: Spec
noWeakening = describe "no refusal is weakened" $ do
    it "still refuses --registry with its rename" $
        parseOpenDatumCommand
            ( [ "open-datum"
              , "inspect"
              , "--key"
              , "bob"
              , "--blueprint"
              , "b"
              , "--registry"
              , "/srv/reg"
              ]
                <> provider
                <> tokenArgs
            )
            `shouldSatisfy` isLeftWithRename
    it "insert without a key is still refused" $
        parseOpenDatumCommand
            ( [ "open-datum"
              , "insert"
              , "--payload"
              , "/srv/doc.json"
              , "--blueprint"
              , "/srv/plutus.json"
              ]
                <> tokenArgs
                <> provider
                <> wallet
            )
            `shouldSatisfy` isLeft
    it "insert without a state token is still refused" $
        parseOpenDatumCommand
            ( [ "open-datum"
              , "insert"
              , "--key"
              , "bob"
              , "--payload"
              , "/srv/doc.json"
              , "--blueprint"
              , "/srv/plutus.json"
              ]
                <> provider
                <> wallet
            )
            `shouldSatisfy` isLeft
  where
    isLeftWithRename = \case
        Left (BadValue "--registry" _) -> True
        _ -> False
