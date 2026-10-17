{-# LANGUAGE ScopedTypeVariables #-}

{- |
Module      : Singular.CLI.SignSpec
Description : @wallet sign@: the verb's pure core and its file effects
License     : Apache-2.0

The proofs of the offline signing verb, one row per promise it makes
to the operator who runs it on an air-gapped machine:

* the command line takes its vault, its passphrase descriptor, its
output directory and the bundle, and refuses every provider and
registry setting by name — the network comes from the bundle;
* the pure core turns a checked bundle and an opened key into one
witness per transaction, each signing its own body's hash and carrying
no secret;
* the file effects write each witness exclusively, named by its
transaction's identity, next to the bundle or under the directory
named, print the paths on standard output and a short summary on
standard error, and refuse — writing nothing — when the vault's
address is not among the bundle's signers;
* an existing witness file is refused with its bytes untouched, a
vault that will not open names nothing about why, and no output names
the passphrase.

The terminal prompt is not executed here: the descriptor path shares
the reader, and the packaged controls drive the real binary with one.
-}
module Singular.CLI.SignSpec (spec) where

import Control.Exception (SomeException, throwIO, try)
import Control.Monad (forM_)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.Char (toLower, toUpper)
import Data.List (isInfixOf, sort)
import Data.List.NonEmpty (NonEmpty ((:|)), toList)
import Data.Text qualified as Text
import GHC.IO.Handle (hDuplicate, hDuplicateTo)
import System.Directory (doesFileExist, listDirectory)
import System.Exit (ExitCode (..))
import System.IO
    ( Handle
    , IOMode (WriteMode)
    , hClose
    , hFlush
    , stderr
    , stdout
    , withFile
    )
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Files (createSymbolicLink)
import System.Posix.IO
    ( OpenMode (ReadOnly)
    , defaultFileFlags
    , openFd
    )
import System.Posix.Types (Fd (..))
import Test.Hspec

import Cardano.Crypto.DSIGN
    ( Ed25519DSIGN
    , SigDSIGN
    , SignKeyDSIGN
    , VerKeyDSIGN
    , deriveVerKeyDSIGN
    , rawDeserialiseSigDSIGN
    , rawDeserialiseVerKeyDSIGN
    , rawSerialiseSignKeyDSIGN
    , rawSerialiseVerKeyDSIGN
    , verifyDSIGN
    )

import Cardano.Ledger.Api.Tx (mkBasicTx)
import Cardano.Tx.Ledger (ConwayTx)
import Singular.CLI.Command
    ( CLIError (..)
    , Command (..)
    , FoldArgs (..)
    , SignArgs (..)
    , WriteSettings (..)
    , parseCommand
    )
import Singular.CLI.FlagGroup (Signer (..), commonFlagGroup)
import Singular.CLI.Passphrase
    ( PassphraseSource (..)
    , mkPassphrase
    )
import Singular.CLI.Sign
import Singular.CLI.Vault
    ( createVaultFile
    , freshSignKey
    , sealVault
    , vaultWorkFactor
    )
import Singular.Registry.Bundle
import Singular.Registry.BundleSpec
    ( bundleTxOf
    , fixedSigner
    , syntheticBody
    )
import Singular.Registry.Ledger (ConwayTxBody)
import Singular.Registry.Wallet
    ( bech32Address
    , walletAddr
    , walletFromSignKey
    )

spec :: Spec
spec = describe "signing a bundle from the vault" $ do
    theCommandLine
    thePureCore
    theFileEffects
    theRefusals

-- | A bundle whose signers are the given addresses.
bundleWithSigners :: [Text.Text] -> Bundle
bundleWithSigners signers =
    Bundle
        { bundleCommand = "singular registry fold"
        , bundleNetworkMagic = 1
        , bundleStateToken = Nothing
        , bundleSigners = case signers of
            s : rest -> s :| rest
            [] -> fixedSigner :| []
        , bundleTransactions =
            bundleTxOf
                (syntheticBody 1000)
                ["returns the request's deposit to its owner"]
                :| [ bundleTxOf
                        (syntheticBody 1001)
                        ["pays the request's owner 2000000 lovelace"]
                   ]
        }

-- | The vault's address for the bundle's network, derived at run time.
vaultAddressOf :: SignKeyDSIGN Ed25519DSIGN -> String
vaultAddressOf key = bech32Address (walletAddr (walletFromSignKey 1 key))

-- * The command line

theCommandLine :: Spec
theCommandLine = describe "the command line" $ do
    it "takes its vault, the bundle and the output settings" $
        parseCommand
            ["wallet", "sign", "--vault", "bob.vault", "bundle.json"]
            `shouldBe` Right
                ( WalletSign
                    SignArgs
                        { signVaultPath = "bob.vault"
                        , signBundlePath = "bundle.json"
                        , signPassphraseFd = Nothing
                        , signOutputDir = Nothing
                        }
                )
    it "takes the passphrase descriptor and the output directory" $
        parseCommand
            [ "wallet"
            , "sign"
            , "--vault"
            , "bob.vault"
            , "--passphrase-fd"
            , "9"
            , "--out"
            , "witnesses"
            , "bundle.json"
            ]
            `shouldBe` Right
                ( WalletSign
                    SignArgs
                        { signVaultPath = "bob.vault"
                        , signBundlePath = "bundle.json"
                        , signPassphraseFd = Just 9
                        , signOutputDir = Just "witnesses"
                        }
                )
    it "refuses every provider and registry setting by name" $
        forM_ refusedSettings $ \spelling ->
            case parseCommand
                ["wallet", "sign", "--vault", "v", spelling, "x", "bundle.json"] of
                Left (BadValue named _) -> named `shouldBe` spelling
                other ->
                    expectationFailure (spelling <> " was taken: " <> show other)
    it "refuses the network magic: the network comes from the bundle" $
        case parseCommand
            [ "wallet"
            , "sign"
            , "--vault"
            , "v"
            , "--network-magic"
            , "1"
            , "bundle.json"
            ] of
            Left (BadValue "--network-magic" _) -> pure ()
            other -> expectationFailure ("--network-magic was taken: " <> show other)
    it "takes the wallet vault flag on a registry write, as its signer" $
        case parseCommand (vaultFoldLine ["--vault", "x"]) of
            Right (Fold a) -> writeSigner (foldWrite a) `shouldBe` SignerVault "x" Nothing
            other -> expectationFailure ("--vault was not taken: " <> show other)
    it "refuses the output directory outside wallet sign" $
        case parseCommand ["wallet", "create", "--out", "d", "--vault", "v"] of
            Left (BadValue flag why) -> do
                flag `shouldBe` "--out"
                why `shouldSatisfy` ("wallet create" `isInfixOf`)
            other -> expectationFailure ("--out was taken: " <> show other)
    it "refuses the bundle's absence" $
        case parseCommand ["wallet", "sign", "--vault", "v"] of
            Left (MissingFlag "BUNDLE") -> pure ()
            other -> expectationFailure ("taken: " <> show other)

-- | Every valued setting the shared group names, minus wallet sign's own.
refusedSettings :: [String]
refusedSettings =
    filter (`notElem` ["--vault", "--passphrase-fd"]) commonFlagGroup

-- * The pure core

thePureCore :: Spec
thePureCore = describe "the pure core" $ do
    it "plans one witness per transaction, named by its identity" $ do
        key <- freshSignKey
        let bundle = bundleWithSigners [Text.pack (vaultAddressOf key)]
            plan = thePlan bundle key
        mapM plannedPath plan
            `shouldBe` mapM
                (\tx -> hexText (bundleTxIdentity tx) <> ".witness")
                (toList (bundleTransactions bundle))
    it "signs each body's own hash with the vault's key, verifiably" $ do
        key <- freshSignKey
        let bundle = bundleWithSigners [Text.pack (vaultAddressOf key)]
            plan = thePlan bundle key
        forM_ (zip (toList (bundleTransactions bundle)) plan) $
            \(tx, planned) ->
                witnessIsSound
                    (decodedWitness (plannedBytes planned))
                    key
                    (bodyIdentity (envelopeBody tx))
                    `shouldBe` True
    it
        "gives an in-memory bundle the witnesses wallet sign writes, in order"
        $ do
            key <- freshSignKey
            let bundle = bundleWithSigners [Text.pack (vaultAddressOf key)]
            bundleWitnesses bundle key
                `shouldBe` Right (map (decodedWitness . plannedBytes) (thePlan bundle key))
    it "refuses an in-memory bundle the vault's key is not a signer of" $ do
        key <- freshSignKey
        other <- freshSignKey
        let bundle = bundleWithSigners [Text.pack (vaultAddressOf other)]
        bundleWitnesses bundle key
            `shouldBe` Left (SignVaultNotAmongSigners (vaultAddressOf key))
    it "summarises identity, deadline, signers and effects" $ do
        key <- freshSignKey
        let bundle = bundleWithSigners [Text.pack (vaultAddressOf key)]
            plan = thePlan bundle key
        forM_ (zip (toList (bundleTransactions bundle)) plan) $
            \(tx, planned) -> do
                map toLower (concat (plannedSummary planned))
                    `shouldSatisfy` (map toLower (hexText (bundleTxIdentity tx)) `isInfixOf`)
                forM_ (bundleTxEffects tx) $ \effect ->
                    unwords (plannedSummary planned)
                        `shouldSatisfy` (Text.unpack effect `isInfixOf`)
    it
        "carries no key byte and no passphrase, in any spelling it can leave"
        $ do
            key <- freshSignKey
            let bundle = bundleWithSigners [Text.pack (vaultAddressOf key)]
                plan = thePlan bundle key
            forM_ plan $ \planned -> do
                forM_ (secretSpellings key) $ \secret -> do
                    plannedBytes planned `shouldNotSatisfy` (secret `BS.isInfixOf`)
                    forM_ (plannedSummary planned) $ \line ->
                        line `shouldNotSatisfy` (BC.unpack secret `isInfixOf`)
                concat (plannedSummary planned)
                    `shouldNotSatisfy` (passphraseSpelling `isInfixOf`)
    it "refuses a bundle whose signers do not include the vault" $ do
        key <- freshSignKey
        let bundle = bundleWithSigners [fixedSigner]
        witnessPlan (encodeBundle bundle) key
            `shouldBe` Left (SignVaultNotAmongSigners (vaultAddressOf key))

-- * The file effects

theFileEffects :: Spec
theFileEffects = describe "the file effects" $ do
    it
        "writes one exclusive witness per transaction, paths on standard output, summary on standard error"
        $ withSystemTempDirectory "sign-effects"
        $ \dir -> do
            key <- freshSignKey
            vault <- makeVault dir key
            let bundle = bundleWithSigners [Text.pack (vaultAddressOf key)]
                bundlePath = dir </> "bundle.json"
                outDir = dir </> "witnesses"
            BS.writeFile bundlePath (encodeBundle bundle)
            (exit, out, err) <-
                withCapture dir . withPassphraseSource dir $ \source ->
                    signBundle bundlePath vault source (Just outDir)
            exit `shouldBe` ExitSuccess
            let expectedPaths =
                    map
                        (\tx -> outDir </> (hexText (bundleTxIdentity tx) <> ".witness"))
                        (toList (bundleTransactions bundle))
            sort (lines out) `shouldBe` sort expectedPaths
            err
                `shouldSatisfy` (hexText (bundleTxIdentity (firstTx bundle)) `isInfixOf`)
            forM_ (zip expectedPaths (toList (bundleTransactions bundle))) $
                \(path, tx) -> do
                    present <- doesFileExist path
                    present `shouldBe` True
                    bytes <- BS.readFile path
                    witnessIsSound
                        (decodedWitness bytes)
                        key
                        (bodyIdentity (envelopeBody tx))
                        `shouldBe` True
            forM_ (secretSpellings key) $ \secret -> do
                err `shouldNotSatisfy` (BC.unpack secret `isInfixOf`)
                out `shouldNotSatisfy` (BC.unpack secret `isInfixOf`)
                forM_ expectedPaths $ \path -> do
                    bytes <- BS.readFile path
                    bytes `shouldNotSatisfy` (secret `BS.isInfixOf`)
    it "writes next to the bundle when no directory is named" $
        withSystemTempDirectory "sign-beside" $ \dir -> do
            key <- freshSignKey
            vault <- makeVault dir key
            let bundlePath = dir </> "bundle.json"
            BS.writeFile
                bundlePath
                (encodeBundle (bundleWithSigners [Text.pack (vaultAddressOf key)]))
            (exit, out, _) <-
                withCapture dir . withPassphraseSource dir $ \source ->
                    signBundle bundlePath vault source Nothing
            exit `shouldBe` ExitSuccess
            forM_ (lines out) $ \path -> do
                present <- doesFileExist path
                present `shouldBe` True

-- * The refusals

theRefusals :: Spec
theRefusals = describe "the refusals" $ do
    it "refuses a second run over existing witness files, bytes unchanged" $
        withSystemTempDirectory "sign-twice" $ \dir -> do
            key <- freshSignKey
            vault <- makeVault dir key
            let bundlePath = dir </> "bundle.json"
            BS.writeFile
                bundlePath
                (encodeBundle (bundleWithSigners [Text.pack (vaultAddressOf key)]))
            (first, out1, _) <-
                withCapture dir . withPassphraseSource dir $ \source ->
                    signBundle bundlePath vault source Nothing
            first `shouldBe` ExitSuccess
            earlier <- mapM BS.readFile (lines out1)
            (second, out, err) <-
                withCapture dir . withPassphraseSource dir $ \source ->
                    signBundle bundlePath vault source Nothing
            second `shouldNotBe` ExitSuccess
            out `shouldBe` ""
            err `shouldSatisfy` ("already exists" `isInfixOf`)
            again <- mapM BS.readFile (lines out1)
            again `shouldBe` earlier
    it "refuses a symbolic link standing where a witness would go" $
        withSystemTempDirectory "sign-link" $ \dir -> do
            key <- freshSignKey
            vault <- makeVault dir key
            let bundle = bundleWithSigners [Text.pack (vaultAddressOf key)]
                bundlePath = dir </> "bundle.json"
                identity = hexText (bundleTxIdentity (firstTx bundle))
            BS.writeFile bundlePath (encodeBundle bundle)
            BS.writeFile (dir </> "elsewhere") "untouched"
            createSymbolicLink
                (dir </> "elsewhere")
                (dir </> (identity <> ".witness"))
            (exit, _, err) <-
                withCapture dir . withPassphraseSource dir $ \source ->
                    signBundle bundlePath vault source Nothing
            exit `shouldNotBe` ExitSuccess
            err `shouldSatisfy` ("already exists" `isInfixOf`)
            linked <- BS.readFile (dir </> "elsewhere")
            linked `shouldBe` "untouched"
    it "refuses a vault that will not open, naming nothing about why" $
        withSystemTempDirectory "sign-wrong" $ \dir -> do
            key <- freshSignKey
            vault <- makeVault dir key
            let bundlePath = dir </> "bundle.json"
            BS.writeFile
                bundlePath
                (encodeBundle (bundleWithSigners [Text.pack (vaultAddressOf key)]))
            BS.writeFile (dir </> "wrong") "not the passphrase\n"
            Fd fdn <- openFd (dir </> "wrong") ReadOnly defaultFileFlags
            (exit, out, err) <-
                withCapture dir $
                    signBundle
                        bundlePath
                        vault
                        (PassphraseDescriptor (fromIntegral fdn))
                        Nothing
            exit `shouldNotBe` ExitSuccess
            out `shouldBe` ""
            err `shouldSatisfy` ("cannot open vault" `isInfixOf`)
            err `shouldNotSatisfy` ("not the passphrase" `isInfixOf`)
    it "refuses an unreadable bundle file by name" $
        withSystemTempDirectory "sign-missing" $ \dir -> do
            key <- freshSignKey
            vault <- makeVault dir key
            (exit, out, err) <-
                withCapture dir . withPassphraseSource dir $ \source ->
                    signBundle (dir </> "absent.json") vault source Nothing
            exit `shouldNotBe` ExitSuccess
            out `shouldBe` ""
            err `shouldSatisfy` ("cannot read the bundle file" `isInfixOf`)
    it "refuses a tampered bundle, writing nothing" $
        withSystemTempDirectory "sign-tampered" $ \dir -> do
            key <- freshSignKey
            vault <- makeVault dir key
            let bundlePath = dir </> "bundle.json"
            BS.writeFile
                bundlePath
                ( tamperFirstCborHex
                    (encodeBundle (bundleWithSigners [Text.pack (vaultAddressOf key)]))
                )
            (exit, out, err) <-
                withCapture dir . withPassphraseSource dir $ \source ->
                    signBundle bundlePath vault source Nothing
            exit `shouldNotBe` ExitSuccess
            out `shouldBe` ""
            err `shouldSatisfy` ("is not the hash of its body" `isInfixOf`)
            witnesses <- filter (".witness" `isInfixOf`) <$> listDirectory dir
            witnesses `shouldBe` []

-- * Helpers

-- | The plan of a bundle for a key, failing loudly when refused.
thePlan :: Bundle -> SignKeyDSIGN Ed25519DSIGN -> [PlannedWitness]
thePlan bundle key = case witnessPlan (encodeBundle bundle) key of
    Right plan -> plan
    Left refusal -> error ("witnessPlan refused: " <> renderSignRefusal refusal)

-- | A decoded witness, failing loudly when refused.
decodedWitness :: ByteString -> DetachedWitness
decodedWitness bytes = case decodeWitnessEnvelope bytes of
    Right witness -> witness
    Left refusal ->
        error ("witness envelope refused: " <> renderBundleRefusal refusal)

-- | The passphrase every vault here is sealed with.
passphraseSpelling :: String
passphraseSpelling = "correct horse battery staple"

-- | Make a sealed vault for a key, returning its path.
makeVault :: FilePath -> SignKeyDSIGN Ed25519DSIGN -> IO FilePath
makeVault dir key = do
    sealed <- sealVault vaultWorkFactor thePassphrase key
    bytes <- case sealed of
        Right sealedBytes -> pure sealedBytes
        Left refusal -> error ("sealing refused: " <> show refusal)
    let path = dir </> "bob.vault"
    created <- createVaultFile path bytes
    case created of
        Left refusal -> error ("vault refused: " <> show refusal)
        Right () -> pure path
  where
    thePassphrase =
        either
            (error "SignSpec: the passphrase is empty")
            id
            (mkPassphrase "correct horse battery staple")

{- | Write the passphrase file once and hand its descriptor's source to
the action. The passphrase reader owns the descriptor's lifetime: it
opens, reads and closes the one line itself, so this wrapper closes
nothing and double-closes no descriptor.
-}
withPassphraseSource :: FilePath -> (PassphraseSource -> IO a) -> IO a
withPassphraseSource dir action = do
    let path = dir </> "passphrase"
    BC.writeFile path (BC.pack (passphraseSpelling <> "\n"))
    Fd fdn <- openFd path ReadOnly defaultFileFlags
    action (PassphraseDescriptor (fromIntegral fdn))

{- | Run an action with its standard output and standard error captured
to files under the directory, returning its result with both texts.
The originals are restored even when the action throws.
-}
withCapture
    :: FilePath -> IO ExitCode -> IO (ExitCode, String, String)
withCapture dir action = do
    result <-
        withOutputTo stdout (dir </> "capture.out") $
            withOutputTo stderr (dir </> "capture.err") action
    out <- readStrictly (dir </> "capture.out")
    err <- readStrictly (dir </> "capture.err")
    pure (result, out, err)
  where
    -- Strict, so the files are closed before the next capture opens them.
    readStrictly path = BC.unpack <$> BS.readFile path

{- | Run an action with one stream duplicated to a file, restoring the
original even when the action throws.
-}
withOutputTo :: Handle -> FilePath -> IO ExitCode -> IO ExitCode
withOutputTo sink path action =
    withFile path WriteMode $ \file -> do
        saved <- hDuplicate sink
        _ <- try (hDuplicateTo file sink) :: IO (Either SomeException ())
        run <- try action :: IO (Either SomeException ExitCode)
        _ <- try (hFlush sink) :: IO (Either SomeException ())
        hDuplicateTo saved sink
        hClose saved
        either throwIO pure run

-- | The first transaction of a bundle.
firstTx :: Bundle -> BundleTransaction
firstTx bundle = case bundleTransactions bundle of
    t :| _ -> t

-- | The body a transaction's envelope carries.
envelopeBody :: BundleTransaction -> ConwayTx
envelopeBody tx = case decodeTransactionEnvelope (bundleTxEnvelope tx) of
    Right body -> body
    Left refusal -> error ("envelope refused: " <> show refusal)

{- | Whether a decoded witness's key and signature verify over the
bytes given.
-}
witnessVerifies :: DetachedWitness -> ByteString -> Bool
witnessVerifies (DetachedWitness keyBytes sigBytes) message =
    case (rawDeserialiseVerKeyDSIGN keyBytes, rawDeserialiseSigDSIGN sigBytes) of
        (Just verKey, Just sig) -> verifyOver verKey sig message
        _ -> False
  where
    verifyOver
        :: VerKeyDSIGN Ed25519DSIGN
        -> SigDSIGN Ed25519DSIGN
        -> ByteString
        -> Bool
    verifyOver verKey sig message' =
        either (const False) (const True) (verifyDSIGN () verKey message' sig)

{- | Whether a witness is sound for a key and a body: it carries that
key's own public key — obtained from the producer, not from the
witness — and its signature verifies over that body's hash.
-}
witnessIsSound
    :: DetachedWitness
    -> SignKeyDSIGN Ed25519DSIGN
    -> ByteString
    -> Bool
witnessIsSound witness key bodyHash =
    detachedKeyBytes witness
        == rawSerialiseVerKeyDSIGN (deriveVerKeyDSIGN key)
        && witnessVerifies witness bodyHash

{- | Flip the last hex digit of the first cborHex in the bytes: a
bundle whose recorded identity can no longer be its body's hash.
-}

{- | Swap the first transaction's body for a different, well-formed
one built by the same producer: a bundle whose recorded identity can
no longer be its body's hash, refused for identity rather than for
decodability.
-}
tamperFirstCborHex :: ByteString -> ByteString
tamperFirstCborHex = spliceFirstString "cborHex" otherBody
  where
    otherBody =
        envelopeCborHex (transactionEnvelope (txOfBody (syntheticBody 999)))

-- | The transaction that carries a body, as the producer builds it.
txOfBody :: ConwayTxBody -> ConwayTx
txOfBody = mkBasicTx

{- | Replace the value of the first @"FIELD\":\"value\"@ string field
in the bytes given, a byte-level splice over the codec's own
encoding.
-}
spliceFirstString
    :: Text.Text -> Text.Text -> ByteString -> ByteString
spliceFirstString field replacement bytes =
    case BS.breakSubstring needle bytes of
        (prefix, rest)
            | BS.null rest -> bytes
            | otherwise ->
                let valueStart = BS.drop (BS.length needle) rest
                    (_, remainder) = BC.break (== '"') valueStart
                in  prefix
                        <> needle
                        <> BC.pack (Text.unpack replacement)
                        <> remainder
  where
    needle = BC.pack (show field) <> ":\""

-- | Path join kept out of the rows.
(</>) :: FilePath -> FilePath -> FilePath
(</>) a b = a ++ "/" ++ b

{- | The secret spellings a signing key can leave behind: its raw bytes
and its hex, in both cases, obtained from the producer at run time.
-}
secretSpellings :: SignKeyDSIGN Ed25519DSIGN -> [ByteString]
secretSpellings key =
    [ raw
    , BC.pack (hexText raw)
    , BC.pack (map toUpper (hexText raw))
    ]
  where
    raw = rawSerialiseSignKeyDSIGN key

-- | A registry fold line complete but for its signer, which the probe names.
vaultFoldLine :: [String] -> [String]
vaultFoldLine signer =
    [ "registry"
    , "fold"
    , "--blueprint"
    , "blueprint.json"
    , "--state-token"
    , replicate 56 'a' <> "." <> replicate 64 'b'
    , "--koios-url"
    , "https://koios.example"
    , "--network-magic"
    , "1"
    ]
        <> signer
