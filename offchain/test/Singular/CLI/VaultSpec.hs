{- |
Module      : Singular.CLI.VaultSpec
Description : The wallet vault: keys, sealing, exclusive creation, passphrase
License     : Apache-2.0

The proofs of the encrypted wallet vault, one row per promise the vault
makes to whoever keeps their signing key in it:

* a signing key file parses to its key whichever of the three spellings
  it carries, and the address of a key is the address the wallet loader
  already derives — pinned by a fixed test key's independently derived
  constant;
* a sealed vault round-trips its key, refuses every wrong passphrase,
  corrupted or foreign file with the one opening refusal, and bounds the
  work factor in both directions;
* the vault file is created readable by its owner only, an existing path
  or symbolic link is refused with its bytes untouched, and a write that
  fails removes the file the call made;
* the passphrase intake refuses the empty passphrase, confirms a typed
  pair purely, and reads a descriptor exactly once.

The terminal prompt is not executed here: the descriptor path shares the
parser, and the plan records a manual transcript for the human path.
-}
module Singular.CLI.VaultSpec (spec) where

import Control.Exception (SomeException, try)
import Control.Exception qualified
import Control.Monad (forM_)
import Data.Bits (xor, (.&.))
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Char8 qualified as BC
import Data.List (isInfixOf)
import Data.Maybe (fromMaybe)
import Data.Word (Word32, Word8)
import System.IO
    ( BufferMode (NoBuffering)
    , Handle
    , hClose
    , hSetBuffering
    )
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Files
    ( createSymbolicLink
    , fileMode
    , getFileStatus
    , getSymbolicLinkStatus
    , isSymbolicLink
    )
import System.Posix.IO
    ( OpenMode (ReadOnly)
    , closeFd
    , defaultFileFlags
    , fdToHandle
    , openFd
    )
import System.Posix.Terminal
    ( TerminalMode (EnableEcho)
    , TerminalState (Immediately)
    , getTerminalAttributes
    , openPseudoTerminal
    , setTerminalAttributes
    , terminalMode
    , withMode
    )
import System.Posix.Types (Fd (..))
import Test.Hspec

import Cardano.Crypto.DSIGN
    ( Ed25519DSIGN
    , SignKeyDSIGN
    , rawDeserialiseSignKeyDSIGN
    , rawSerialiseSignKeyDSIGN
    )
import Crypto.Age.Scrypt (WorkFactor, mkWorkFactor)

import Singular.CLI.Command
    ( CLIError (..)
    , Command (..)
    , FoldArgs (..)
    , WalletArgs (..)
    , WriteSettings (..)
    , parseCommand
    )
import Singular.CLI.FlagGroup (Signer (..))
import Singular.CLI.Passphrase
import Singular.CLI.Vault
import Singular.Registry.Wallet
    ( Wallet (..)
    , bech32Address
    , loadWallet
    , parseSignKey
    , walletFromSignKey
    )

spec :: Spec
spec = describe "wallet vault" $ do
    signingKeyFiles
    addressOfAKey
    sealAndOpen
    theEnvelope
    aFreshKey
    exclusiveCreation
    passphraseIntake
    promptOrdering
    walletVerbs

-- * Producers: every expected value is obtained, never typed beside the code

-- | The RFC 8032 Ed25519 test vector 1 seed, the fixed test key.
rfc8032Seed :: ByteString
rfc8032Seed =
    either (error "VaultSpec: the fixed test key is not hex") id $
        B16.decode
            "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60"

{- | The enterprise addresses of the fixed test key, derived once through
the production path — @loadWallet@ on a file holding the key's text
envelope — and committed as constants. The derivation is
@serialiseAddr\ (Addr\ net\ (KeyHashObj\ (hashKey\ (VKey\ (deriveVerKeyDSIGN\ sk))))\ StakeRefNull)@
bech32-encoded with the CIP-5 prefixes, where @sk@ is the seed above;
@net@ is Testnet for every magic but the mainnet one.
-}
rfc8032TestnetAddress :: String
rfc8032TestnetAddress =
    "addr_test1vq6aahffs2sreuu70h8q8jpen98lmmpwc6cy788j6s8xrgc64xuck"

rfc8032MainnetAddress :: String
rfc8032MainnetAddress =
    "addr1vy6aahffs2sreuu70h8q8jpen98lmmpwc6cy788j6s8xrgcpajqhn"

fixedKey :: SignKeyDSIGN Ed25519DSIGN
fixedKey =
    fromMaybe (error "VaultSpec: the fixed test key is not a signing key") $
        rawDeserialiseSignKeyDSIGN rfc8032Seed

-- | A key made at run time from a byte pattern, as a seed and as a key.
runtimeKey :: Word8 -> (ByteString, SignKeyDSIGN Ed25519DSIGN)
runtimeKey first = (seed, key)
  where
    seed = BS.pack (first : replicate 31 0x2a)
    key =
        fromMaybe (error "VaultSpec: the seed is not a signing key") $
            rawDeserialiseSignKeyDSIGN seed

-- | The key's cardano-cli text envelope, built here as the loader's input.
envelopeOf :: ByteString -> ByteString
envelopeOf seed =
    "{\"type\":\"PaymentSigningKeyShelley_ed25519\",\"description\":\"VaultSpec\"\
    \,\"cborHex\":\"5820"
        <> B16.encode seed
        <> "\"}"

{- | A scrypt work factor for the proofs; the shipped factor runs in its
own proof.
-}
factor :: Word8 -> WorkFactor
factor n =
    fromMaybe
        (error "VaultSpec: scrypt rejected the factor")
        (mkWorkFactor n)

{- | The passphrase of the round-trip proofs, and a wrong one, each
already unwrapped: the fixtures fail the proof loudly if the
passphrase constructor itself refuses them.
-}
thePassphrase :: Passphrase
thePassphrase =
    either (error "VaultSpec: the passphrase fixture refused") id $
        mkPassphrase "correct horse battery staple"

anotherPassphrase :: Passphrase
anotherPassphrase =
    either (error "VaultSpec: the wrong passphrase fixture refused") id $
        mkPassphrase "a deliberately wrong passphrase"

{- | The seal a proof uses, unwrapped: sealing refusing is the proof's
own failure, named.
-}
sealed
    :: Word8 -> Passphrase -> SignKeyDSIGN Ed25519DSIGN -> IO ByteString
sealed n pass key =
    either (error . ("the seal refused: " <>) . show) id
        <$> sealVault (factor n) pass key

-- * Key files

signingKeyFiles :: Spec
signingKeyFiles = describe "a signing key file" $ do
    let (seed, key) = runtimeKey 0x11
        rawSerialised = rawSerialiseSignKeyDSIGN key
        parsesToTheKey bytes =
            parseSignKey bytes
                `shouldSatisfy` either
                    (const False)
                    ((== rawSerialised) . rawSerialiseSignKeyDSIGN)
    it "parses the cardano-cli text envelope to the key" $
        parsesToTheKey (envelopeOf seed)
    it "parses the bare cborHex hex spelling to the same key" $
        parsesToTheKey (B16.encode (BS.pack [0x58, 0x20] <> seed))
    it "parses the 32 raw key bytes to the same key" $
        parsesToTheKey seed
    it "parses a spelling with surrounding whitespace" $
        parsesToTheKey (BC.pack ("  \n" <> BC.unpack seed <> "\t "))
    it
        "refuses a file that is none of the three spellings, in the loader's words"
        $ parseSignKey "zzz"
            `shouldBe` Left
                "not a text envelope with a cborHex field, not hex, and not 32 raw bytes"
    it "refuses hex that does not hold 32 key bytes, naming the count" $
        parseSignKey (B16.encode (BS.pack [0x58, 0x20] <> BS.take 31 seed))
            `shouldBe` Left "expected 32 key bytes, found 33"

-- * Addresses

addressOfAKey :: Spec
addressOfAKey = describe "the address of a key" $ do
    it
        "equals the address the wallet loader derives, on more than one key"
        $ withSystemTempDirectory "vault-address"
        $ \dir -> do
            let magic = 1 :: Word32
            forM_ [0x21, 0x22] $ \n -> do
                let (seed, key) = runtimeKey n
                    path = dir <> "/key-" <> show n <> ".skey"
                BS.writeFile path (envelopeOf seed)
                loaded <- loadWallet magic path
                bech32Address (walletAddr loaded)
                    `shouldBe` bech32Address (walletAddr (walletFromSignKey magic key))
    it "is the fixed test key's committed constant on a test network" $
        bech32Address (walletAddr (walletFromSignKey 1 fixedKey))
            `shouldBe` rfc8032TestnetAddress
    it "selects mainnet only at the mainnet magic" $ do
        bech32Address (walletAddr (walletFromSignKey 764824073 fixedKey))
            `shouldBe` rfc8032MainnetAddress
        bech32Address (walletAddr (walletFromSignKey 42 fixedKey))
            `shouldBe` rfc8032TestnetAddress

-- * Sealing and opening

sealAndOpen :: Spec
sealAndOpen = describe "a vault sealed and opened" $ do
    it "round-trips the key at a cheap work factor" $ do
        let (seed, key) = runtimeKey 0x31
        bytes <- sealed 10 thePassphrase key
        openVault thePassphrase bytes
            `shouldSatisfy` either
                (const False)
                ((== seed) . rawSerialiseSignKeyDSIGN)
    it "round-trips the key at the shipped work factor 18" $ do
        let (seed, key) = runtimeKey 0x32
        bytes <-
            either (error . ("the seal refused: " <>) . show) id
                <$> sealVault vaultWorkFactor thePassphrase key
        openVault thePassphrase bytes
            `shouldSatisfy` either
                (const False)
                ((== seed) . rawSerialiseSignKeyDSIGN)
    it "refuses a wrong passphrase with the one opening refusal" $ do
        let (_, key) = runtimeKey 0x33
        bytes <- sealed 10 thePassphrase key
        openVault anotherPassphrase bytes `shouldBe` Left VaultNotOpened
    it
        "refuses a corrupted vault with the one opening refusal, while the intact vault opens"
        $ do
            let (_, key) = runtimeKey 0x34
            bytes <- sealed 10 thePassphrase key
            let truncated = BS.init bytes
                bodyFlipped =
                    BS.concat
                        [ BS.take 40 bytes
                        , BS.singleton (BS.index bytes 40 `xor` 1)
                        , BS.drop 41 bytes
                        ]
            openVault thePassphrase truncated `shouldBe` Left VaultNotOpened
            openVault thePassphrase bodyFlipped `shouldBe` Left VaultNotOpened
            openVault thePassphrase bytes
                `shouldSatisfy` either (const False) (const True)
    it "refuses a file that is not a vault with the one opening refusal" $
        openVault thePassphrase "this is not a vault at all"
            `shouldBe` Left VaultNotOpened
    it "refuses a vault sealed at a work factor above the shipped one" $ do
        let (_, key) = runtimeKey 0x35
        bytes <- sealed 19 thePassphrase key
        openVault thePassphrase bytes `shouldBe` Left VaultNotOpened
    it "carries no key byte, key spelling or key envelope in the clear" $ do
        let (seed, key) = runtimeKey 0x36
        bytes <- sealed 10 thePassphrase key
        bytes `shouldSatisfy` BS.isPrefixOf "age-encryption.org/v1"
        bytes `shouldSatisfy` not . BS.isInfixOf seed
        bytes `shouldSatisfy` not . BS.isInfixOf (B16.encode seed)
        bytes `shouldSatisfy` not . BS.isInfixOf (envelopeOf seed)
    it
        "never seals an empty passphrase: the empty passphrase is refused at birth"
        $ mkPassphrase "" `shouldBe` Left PassphraseEmpty

-- * The envelope

theEnvelope :: Spec
theEnvelope = describe "the key's text envelope" $ do
    let (seed, key) = runtimeKey 0x41
        rawSerialised = rawSerialiseSignKeyDSIGN key
    it "is the bytes the wallet loader already reads" $
        withSystemTempDirectory "vault-envelope" $ \dir -> do
            let path = dir <> "/payment.skey"
            BS.writeFile path (signKeyEnvelope key)
            loaded <- loadWallet 1 path
            bech32Address (walletAddr loaded)
                `shouldBe` bech32Address (walletAddr (walletFromSignKey 1 key))
    it "parses back to the same key through the key-file parser" $
        parseSignKey (signKeyEnvelope key)
            `shouldSatisfy` either
                (const False)
                ((== rawSerialised) . rawSerialiseSignKeyDSIGN)
    it
        "names the shelley payment key type and the cborHex spelling of the key"
        $ do
            let envelope = signKeyEnvelope key
            envelope
                `shouldSatisfy` BS.isInfixOf "PaymentSigningKeyShelley_ed25519"
            envelope `shouldSatisfy` BS.isInfixOf ("5820" <> B16.encode seed)

-- * Fresh keys

aFreshKey :: Spec
aFreshKey = describe "a fresh key" $ do
    it "draws a different key every time" $ do
        first <- freshSignKey
        second <- freshSignKey
        rawSerialiseSignKeyDSIGN first
            `shouldNotBe` rawSerialiseSignKeyDSIGN second
    it "is not the fixed test key" $ do
        key <- freshSignKey
        rawSerialiseSignKeyDSIGN key `shouldNotBe` rfc8032Seed
    it "round-trips through its envelope" $ do
        key <- freshSignKey
        parseSignKey (signKeyEnvelope key)
            `shouldSatisfy` either
                (const False)
                ((== rawSerialiseSignKeyDSIGN key) . rawSerialiseSignKeyDSIGN)

-- * Exclusive creation

exclusiveCreation :: Spec
exclusiveCreation = describe "the vault file created exclusively" $ do
    let vaultBytes = BC.pack "the sealed vault bytes"
    it "creates the file readable by its owner only, holding the bytes" $
        withSystemTempDirectory "vault-create" $ \dir -> do
            let path = dir <> "/alice.vault"
            createVaultFile path vaultBytes >>= (`shouldBe` Right ())
            BS.readFile path `shouldReturn` vaultBytes
            mode <- fileMode <$> getFileStatus path
            (mode .&. 0o777) `shouldBe` 0o600
    it "refuses an existing path and leaves its bytes unchanged" $
        withSystemTempDirectory "vault-exists" $ \dir -> do
            let path = dir <> "/alice.vault"
                original = BC.pack "the wallet that lives here already"
            BS.writeFile path original
            createVaultFile path vaultBytes
                `shouldReturn` Left (VaultPathExists path)
            BS.readFile path `shouldReturn` original
    it "refuses a symbolic link and leaves its target untouched" $
        withSystemTempDirectory "vault-symlink" $ \dir -> do
            let target = dir <> "/real.vault"
                link = dir <> "/alice.vault"
                original = BC.pack "the symlinked wallet"
            BS.writeFile target original
            createSymbolicLink "real.vault" link
            createVaultFile link vaultBytes
                `shouldReturn` Left (VaultPathExists link)
            BS.readFile target `shouldReturn` original
            isSymbolicLink <$> getSymbolicLinkStatus link `shouldReturn` True
    it "removes the file it made when the write fails" $
        withSystemTempDirectory "vault-failed-write" $ \dir -> do
            let path = dir <> "/alice.vault"
            withVaultFile
                path
                (\_ -> ioError (userError "the write fails") :: IO ())
                `shouldReturn` Left (VaultNotWritten path)
            getFileStatus path `shouldThrow` anyIOException
    it "keeps the file when the write succeeds" $
        withSystemTempDirectory "vault-written" $ \dir -> do
            let path = dir <> "/alice.vault"
            withVaultFile path (`BS.hPut` vaultBytes)
                `shouldReturn` Right ()
            BS.readFile path `shouldReturn` vaultBytes

-- * Passphrase intake

passphraseIntake :: Spec
passphraseIntake = describe "the passphrase intake" $ do
    it "refuses the empty passphrase" $
        mkPassphrase "" `shouldBe` Left PassphraseEmpty
    it "keeps a passphrase with no rendering that shows it" $ do
        let passphrase =
                either (error "mkPassphrase refused") id (mkPassphrase "top-secret")
        show passphrase `shouldBe` "<passphrase>"
        show passphrase `shouldNotSatisfy` ("top-secret" `isInfixOf`)
    it "confirms two agreeing lines to the passphrase" $
        confirmPassphrase "shared secret" "shared secret"
            `shouldBe` mkPassphrase "shared secret"
    it "refuses two differing lines as the confirmation mismatch" $
        confirmPassphrase "shared secret" "shared secret "
            `shouldBe` Left PassphraseConfirmationDiffers
    it "refuses an agreeing empty pair as the empty passphrase" $
        confirmPassphrase "" "" `shouldBe` Left PassphraseEmpty
    it "names the mismatch before emptiness when both apply" $
        confirmPassphrase "" "x" `shouldBe` Left PassphraseConfirmationDiffers
    it "reads a descriptor as one line, whatever confirmation is asked" $
        withSystemTempDirectory "vault-fd" $ \dir -> do
            let path = dir <> "/passphrase"
            forM_ [AskOnce, AskTwice] $ \confirmation -> do
                BS.writeFile path "correct horse\n"
                Fd fdn <- openFd path ReadOnly defaultFileFlags
                readPassphrase confirmation (PassphraseDescriptor (fromIntegral fdn))
                    `shouldReturn` mkPassphrase "correct horse"
    it "refuses an empty line on a descriptor" $
        withSystemTempDirectory "vault-fd-empty" $ \dir -> do
            let path = dir <> "/passphrase"
            BS.writeFile path "\n"
            Fd fdn <- openFd path ReadOnly defaultFileFlags
            readPassphrase AskOnce (PassphraseDescriptor (fromIntegral fdn))
                `shouldReturn` Left PassphraseEmpty
    it "names the descriptor it could not read" $ do
        Fd fdn <- openFd "/dev/null" ReadOnly defaultFileFlags
        closeFd (Fd fdn)
        readPassphrase AskOnce (PassphraseDescriptor (fromIntegral fdn))
            `shouldReturn` Left
                (PassphraseDescriptorUnreadable (fromIntegral fdn))

-- * The hidden terminal bracket

{- | The hidden-prompt proofs, against the bracketed core with the
effects injected: the echo is off inside the bracket before any
bracketed write, and it is restored on every exit, the bracketed read
throwing included. The interactive terminal path itself — a human
typing at a prompt — is the plan's declared limit: no hosted run
executes it, and the manual transcript in the pull request body is
its evidence.
-}
promptOrdering :: Spec
promptOrdering = describe "the hidden terminal bracket" $ do
    it "holds the echo off inside the bracket, before any bracketed write" $
        withPseudoTerminal $ \_master _slave slaveFd -> do
            setEchoOn slaveFd
            observed <- withHiddenEcho slaveFd (echoIsOn slaveFd)
            observed `shouldBe` False
            restored <- echoIsOn slaveFd
            restored `shouldBe` True
    it "restores the echo when the read inside the bracket fails" $
        withPseudoTerminal $ \_master _slave slaveFd -> do
            setEchoOn slaveFd
            outcome <-
                try (withHiddenEcho slaveFd (ioError (userError "the read fails")))
            case outcome of
                Left (_ :: SomeException) -> pure ()
                Right _ -> fail "the failing read should have propagated"
            restored <- echoIsOn slaveFd
            restored `shouldBe` True

-- | One pseudo-terminal, echo on, both ends unbuffered, closed after.
withPseudoTerminal :: (Handle -> Handle -> Fd -> IO a) -> IO a
withPseudoTerminal action = do
    (masterFd, slaveFd) <- openPseudoTerminal
    master <- fdToHandle masterFd
    slave <- fdToHandle slaveFd
    hSetBuffering master NoBuffering
    hSetBuffering slave NoBuffering
    result <- action master slave slaveFd
    hClose slave `catchAny` pure
    hClose master `catchAny` pure
    pure result
  where
    catchAny act handler =
        Control.Exception.catch act (\(_ :: SomeException) -> handler ())

-- | Turn the terminal's echo explicitly on.
setEchoOn :: Fd -> IO ()
setEchoOn slaveFd = do
    attributes <- getTerminalAttributes slaveFd
    setTerminalAttributes
        slaveFd
        (withMode attributes EnableEcho)
        Immediately

-- | Whether the terminal's echo is on.
echoIsOn :: Fd -> IO Bool
echoIsOn slaveFd = do
    attributes <- getTerminalAttributes slaveFd
    pure (terminalMode EnableEcho attributes)

-- * The wallet verbs

walletVerbs :: Spec
walletVerbs = describe "the wallet verbs on the command line" $ do
    let created vault magic fd =
            WalletCreate
                WalletArgs
                    { walletVaultPath = vault
                    , walletNetworkMagic = magic
                    , walletPassphraseFd = fd
                    }
        addressed vault magic fd =
            WalletAddress
                WalletArgs
                    { walletVaultPath = vault
                    , walletNetworkMagic = magic
                    , walletPassphraseFd = fd
                    }
    it "parses wallet create with its vault, network magic and descriptor" $
        parseCommand
            [ "wallet"
            , "create"
            , "--vault"
            , "alice.vault"
            , "--network-magic"
            , "1"
            , "--passphrase-fd"
            , "9"
            ]
            `shouldBe` Right (created "alice.vault" 1 (Just 9))
    it "parses wallet create with the terminal as the passphrase source" $
        parseCommand
            [ "wallet"
            , "create"
            , "--vault"
            , "alice.vault"
            , "--network-magic"
            , "42"
            ]
            `shouldBe` Right (created "alice.vault" 42 Nothing)
    it "parses wallet address with the same flags, mainnet included" $
        parseCommand
            [ "wallet"
            , "address"
            , "--vault"
            , "alice.vault"
            , "--network-magic"
            , "764824073"
            ]
            `shouldBe` Right (addressed "alice.vault" 764824073 Nothing)
    it "refuses wallet create without a vault path" $
        parseCommand ["wallet", "create", "--network-magic", "1"]
            `shouldBe` Left (MissingFlag "--vault")
    it "refuses wallet create without a network magic" $
        parseCommand ["wallet", "create", "--vault", "alice.vault"]
            `shouldBe` Left (MissingFlag "--network-magic")
    it "refuses a network magic that is not a number" $
        parseCommand
            ["wallet", "create", "--vault", "v", "--network-magic", "preprod"]
            `shouldBe` Left (BadValue "--network-magic" "not a number")
    it "refuses a passphrase descriptor that is not a number" $
        parseCommand
            [ "wallet"
            , "create"
            , "--vault"
            , "v"
            , "--network-magic"
            , "1"
            , "--passphrase-fd"
            , "x"
            ]
            `shouldBe` Left (BadValue "--passphrase-fd" "not a descriptor number")
    it "refuses a registry flag on a wallet command, by name" $
        parseCommand
            [ "wallet"
            , "create"
            , "--vault"
            , "v"
            , "--network-magic"
            , "1"
            , "--blueprint"
            , "plutus.json"
            ]
            `shouldBe` Left
                ( BadValue
                    "--blueprint"
                    "is not accepted by wallet create: a wallet command takes only its vault, network magic and passphrase descriptor"
                )
    it
        "takes the vault and its passphrase descriptor on a registry write, as its signer"
        $ case parseCommand
            (registryFoldLine <> ["--vault", "x", "--passphrase-fd", "3"]) of
            Right (Fold a) ->
                writeSigner (foldWrite a) `shouldBe` SignerVault "x" (Just 3)
            other -> expectationFailure ("the vault was not taken: " <> show other)
    it "takes a bare wallet word as help" $
        case parseCommand ["wallet"] of
            Right (Help page) ->
                page `shouldSatisfy` isInfixOf "Usage: singular wallet COMMAND"
            other -> expectationFailure ("not help: " <> show other)

-- | A registry fold line complete but for its signer.
registryFoldLine :: [String]
registryFoldLine =
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
