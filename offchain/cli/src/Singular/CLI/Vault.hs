{-# LANGUAGE LambdaCase #-}

{- |
Module      : Singular.CLI.Vault
Description : The encrypted wallet vault: sealing, opening, exclusive creation
License     : Apache-2.0

A vault is one binary age file whose only recipient is a passphrase
(scrypt, work factor 'vaultWorkFactor' on creation, at most that on
opening). Its plaintext is the key's standard @cardano-cli@ text
envelope — the same bytes "Singular.Registry.Wallet" already reads — so
any age tool opens the file with the passphrase and yields an ordinary
key envelope. No public part of the key is stored: reading the address
means decrypting.

The vault file is owned by the command that creates it, for the length
of that command: it is created exclusively with mode 0600 (an existing
path, including a symbolic link, is refused and left untouched), and a
write that fails after the file was made removes that file.

Calculations are values: 'signKeyEnvelope' and 'openVault' are pure.
'Crypto.Age.Scrypt.WorkFactor' bounds both directions — sealing always
uses the factor it is given, opening refuses a vault whose factor
exceeds 'vaultWorkFactor'.
-}
module Singular.CLI.Vault
    ( VaultRefusal (..)
    , renderVaultRefusal
    , vaultWorkFactor
    , signKeyEnvelope
    , sealVault
    , openVault
    , freshSignKey
    , createVaultFile
    , withVaultFile
    , vaultPathTaken
    , readVaultFile
    , ioReason
    ) where

import Control.Exception (IOException, bracket, try)
import Control.Monad.Trans.Except (runExceptT)
import Crypto.Age.Buffered qualified as Age
import Crypto.Age.Identity (Identity (..), ScryptIdentity (..))
import Crypto.Age.Recipient (Recipients (..), ScryptRecipient (..))
import Crypto.Age.Scrypt
    ( WorkFactor
    , bytesToSalt
    , mkWorkFactor
    )
import Crypto.Age.Scrypt qualified as Scrypt (Passphrase (..))
import Crypto.Random (getRandomBytes)
import Data.ByteArray qualified as BA
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.List.NonEmpty (NonEmpty (..))
import System.IO (Handle, hClose)
import System.IO.Error
    ( ioeGetErrorString
    , isDoesNotExistError
    , isPermissionError
    )
import System.Posix.Files
    ( getSymbolicLinkStatus
    , ownerReadMode
    , ownerWriteMode
    , removeLink
    , unionFileModes
    )
import System.Posix.IO
    ( OpenMode (WriteOnly)
    , creat
    , defaultFileFlags
    , exclusive
    , fdToHandle
    , nofollow
    , openFd
    )
import System.Posix.Types (FileMode)

import Cardano.Crypto.DSIGN
    ( Ed25519DSIGN
    , SignKeyDSIGN
    , rawDeserialiseSignKeyDSIGN
    , rawSerialiseSignKeyDSIGN
    )

import Singular.CLI.Passphrase (Passphrase, passphraseBytes)
import Singular.Registry.Wallet (parseSignKey)

{- | Why a vault operation was refused. None names the passphrase or the
key; the opening refusal is one named cause for every way a vault
fails to open, so nothing distinguishes a wrong passphrase from a
corrupt file.
-}
data VaultRefusal
    = -- | the vault path already exists, naming it; its bytes are untouched
      VaultPathExists FilePath
    | -- | the file could not be created or written, naming the path
      VaultNotWritten FilePath
    | -- | the vault file could not be read, naming the path and why
      VaultNotRead FilePath String
    | {- | the vault could not be opened: wrong passphrase, corrupt file,
      or not a singular vault
      -}
      VaultNotOpened
    deriving stock (Eq, Show)

-- | One line naming the refusal, carrying no secret.
renderVaultRefusal :: VaultRefusal -> String
renderVaultRefusal = \case
    VaultPathExists path -> "vault already exists: " <> path
    VaultNotWritten path -> "cannot write the vault file: " <> path
    VaultNotRead path why -> "cannot read the vault file " <> path <> ": " <> why
    VaultNotOpened ->
        "cannot open vault: wrong passphrase, corrupt file, or not a singular vault"

{- | The work factor every creation seals with and every opening accepts
at most: scrypt work factor 18.
-}
vaultWorkFactor :: WorkFactor
vaultWorkFactor = case mkWorkFactor 18 of
    Just factor -> factor
    Nothing -> error "Singular.CLI.Vault.vaultWorkFactor: 18 is out of range"

{- | The key's text envelope bytes — the @cardano-cli@ spelling of a
payment signing key: a JSON object with @type@
@PaymentSigningKeyShelley_ed25519@, a @description@ and a @cborHex@
holding @5820@ followed by the 32 key bytes in hex. This is the vault's
plaintext, and the same bytes 'Singular.Registry.Wallet.parseSignKey'
reads. Pure.
-}
signKeyEnvelope :: SignKeyDSIGN Ed25519DSIGN -> ByteString
signKeyEnvelope key =
    "{\"type\":\"PaymentSigningKeyShelley_ed25519\",\"description\":\"\
    \Signing key for a singular wallet vault\
    \\",\"cborHex\":\"5820"
        <> B16.encode (rawSerialiseSignKeyDSIGN key)
        <> "\"}"

{- | Seal a key into vault bytes with the given work factor and
passphrase: an age file with exactly one passphrase stanza. Effect:
draws the random salt, the one effect the sealing function declares.
-}
sealVault
    :: WorkFactor
    -> Passphrase
    -> SignKeyDSIGN Ed25519DSIGN
    -> IO (Either VaultRefusal ByteString)
sealVault workFactor pass key = do
    saltBytes <- getRandomBytes 16
    case bytesToSalt saltBytes of
        Nothing ->
            pure (Left (VaultNotWritten "the vault salt could not be made"))
        Just salt -> do
            sealed <-
                runExceptT $
                    Age.encrypt
                        ( RecipientsScrypt
                            ScryptRecipient
                                { srPassphrase =
                                    Scrypt.Passphrase (BA.convert raw)
                                , srSalt = salt
                                , srWorkFactor = workFactor
                                }
                        )
                        (signKeyEnvelope key)
            pure
                (either (const (Left (VaultNotWritten "the seal failed"))) Right sealed)
  where
    raw = passphraseBytes pass

{- | Open a vault with a passphrase: its signing key, or the one opening
refusal. A wrong passphrase, a corrupt file, a file that is not a
singular vault, a vault whose work factor exceeds 'vaultWorkFactor' and
a plaintext that is not a key envelope all answer the same refusal, so
nothing about the cause leaks. Pure.
-}
openVault
    :: Passphrase
    -> ByteString
    -> Either VaultRefusal (SignKeyDSIGN Ed25519DSIGN)
openVault pass bytes = case decrypted of
    Left _ -> Left VaultNotOpened
    Right envelope -> case parseSignKey envelope of
        Left _ -> Left VaultNotOpened
        Right key -> Right key
  where
    raw = passphraseBytes pass
    decrypted = Age.decrypt identities bytes
    identities :: NonEmpty Identity
    identities =
        IdentityScrypt
            ScryptIdentity
                { siPassphrase = Scrypt.Passphrase (BA.convert raw)
                , siMaxWorkFactor = vaultWorkFactor
                }
            :| []

{- | A signing key from 32 bytes of operating-system entropy. Effect:
entropy; every call draws fresh bytes.
-}
freshSignKey :: IO (SignKeyDSIGN Ed25519DSIGN)
freshSignKey = do
    seed <- getRandomBytes 32
    case rawDeserialiseSignKeyDSIGN seed of
        Just key -> pure key
        Nothing ->
            error "Singular.CLI.Vault.freshSignKey: entropy gave no signing key"

{- | Create the vault file exclusively with mode 0600 and write the
bytes; the file this call made is removed if the write fails; an
existing path or symbolic link is refused untouched.
-}
createVaultFile
    :: FilePath -> ByteString -> IO (Either VaultRefusal ())
createVaultFile path bytes =
    withVaultFile path (`BS.hPut` bytes)

{- | The file's ownership bracket: create it exclusively with mode 0600,
hand the writer the handle, and remove the file this bracket made if
the writer fails. This is the mechanism 'createVaultFile' composes with
the real write, and the name a proof holds for the removal rule. The
exclusive create never follows a symbolic link: an existing path of any
kind is refused before anything is written.
-}
withVaultFile
    :: FilePath -> (Handle -> IO a) -> IO (Either VaultRefusal a)
withVaultFile path write = do
    opened <-
        try
            ( openFd
                path
                WriteOnly
                defaultFileFlags
                    { exclusive = True
                    , creat = Just vaultFileMode
                    , nofollow = True
                    }
            )
    case opened of
        Right fd -> writeBracketed fd
        Left (_ :: IOException) -> do
            present <- try (getSymbolicLinkStatus path)
            case present of
                Right _ -> pure (Left (VaultPathExists path))
                Left (_ :: IOException) -> pure (Left (VaultNotWritten path))
  where
    writeBracketed fd = do
        written <- try (bracket (fdToHandle fd) hClose write)
        case written of
            Left (_ :: IOException) -> do
                _ <- try (removeLink path) :: IO (Either IOException ())
                pure (Left (VaultNotWritten path))
            Right result -> pure (Right result)

{- | Read a vault file, or say in a few words why it cannot be read.
Effect: reads the file.
-}
readVaultFile :: FilePath -> IO (Either VaultRefusal ByteString)
readVaultFile path =
    either (Left . VaultNotRead path . ioReason) Right
        <$> try (BS.readFile path)

{- | Why a file operation failed, as a person says it: the cause alone,
never the library's name for it.
-}
ioReason :: IOException -> String
ioReason e
    | isDoesNotExistError e = "it does not exist"
    | isPermissionError e = "permission denied"
    | otherwise = ioeGetErrorString e

{- | Whether anything is at the path, a symbolic link included.  create@
asks this before it asks for a passphrase, so a vault that would be refused is
refused before the passphrase is typed twice; the exclusive create above stays
the judge when the path is taken in between.
-}
vaultPathTaken :: FilePath -> IO Bool
vaultPathTaken path =
    either (\(_ :: IOException) -> False) (const True)
        <$> try (getSymbolicLinkStatus path)

{- | The mode a vault is born with: readable and writable by its owner
only.
-}
vaultFileMode :: FileMode
vaultFileMode = ownerReadMode `unionFileModes` ownerWriteMode
