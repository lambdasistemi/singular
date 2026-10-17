{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.CLI.Sign
Description : @wallet sign@: witness a bundle of unsigned transactions from the vault
License     : Apache-2.0

The offline signing command: read the bundle, ask the passphrase once,
open the vault, check the bundle offline, and write one witness file
per transaction, each named by its transaction's identity and created
exclusively. The witness paths go to standard output, one per line; a
short summary of what was signed — each transaction's identity,
deadline and the effects its writer claims — goes to standard error.

The command is offline by construction: it takes no provider or
registry option, opens no connection, and reads nothing but the bundle
file, the vault file and the passphrase. The network a bundle is built
for comes from the bundle itself; the vault's address is derived for
that network and must be among the bundle's signers, or nothing is
written. No output, refusal or file carries the passphrase or any key
byte: a witness carries the public key and the signature only.
-}
module Singular.CLI.Sign
    ( SignRefusal (..)
    , renderSignRefusal
    , PlannedWitness (..)
    , witnessPlan
    , bundleWitnesses
    , signBundle
    ) where

import Control.Exception (IOException, bracket, try)
import Control.Monad (forM, forM_, unless)
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Either (lefts)
import Data.List.NonEmpty (toList)
import Data.Maybe (fromMaybe)
import Data.Text qualified as Text
import Data.Word (Word32)
import System.Directory (createDirectoryIfMissing)
import System.Exit (ExitCode (..))
import System.FilePath (takeDirectory, (</>))
import System.IO (hClose, hPutStrLn, stderr)
import System.Posix.Files
    ( getSymbolicLinkStatus
    , groupReadMode
    , otherReadMode
    , ownerReadMode
    , ownerWriteMode
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
    , SignedDSIGN (..)
    , rawSerialiseSigDSIGN
    , rawSerialiseVerKeyDSIGN
    )
import Cardano.Ledger.Keys
    ( KeyRole (Witness)
    , VKey (..)
    , WitVKey (..)
    )

import Singular.CLI.Passphrase
    ( Confirmation (AskOnce)
    , PassphraseRefusal
    , PassphraseSource
    , readPassphrase
    , renderPassphraseRefusal
    )
import Singular.CLI.Vault (openVault)
import Singular.Registry.Bundle
import Singular.Registry.Signing (detachedWitness)
import Singular.Registry.Wallet
    ( bech32Address
    , walletAddr
    , walletFromSignKey
    )

-- | Why signing a bundle was refused. None names the passphrase or the key.
data SignRefusal
    = -- | the bundle itself was refused, naming its own cause
      SignBundle BundleRefusal
    | -- | the bundle file could not be read, naming its path
      SignBundleUnreadable FilePath
    | -- | the passphrase could not be read, naming its own cause
      SignPassphrase PassphraseRefusal
    | {- | the vault could not be opened, naming its path; a wrong
      passphrase, a corrupt file and a foreign file all answer alike
      -}
      SignVaultNotOpened FilePath
    | {- | the vault's address is not among the bundle's signers,
      naming the address; nothing is written
      -}
      SignVaultNotAmongSigners String
    | {- | a witness file already exists, naming its path; its bytes
      are untouched
      -}
      SignOutputExists FilePath
    | {- | a witness file or the output directory could not be written,
      naming the path
      -}
      SignNotWritten FilePath
    deriving stock (Eq, Show)

-- | One line naming the refusal, carrying what it concerns and no secret.
renderSignRefusal :: SignRefusal -> String
renderSignRefusal = \case
    SignBundle refusal -> renderBundleRefusal refusal
    SignBundleUnreadable path -> "cannot read the bundle file: " <> path
    SignPassphrase refusal -> renderPassphraseRefusal refusal
    SignVaultNotOpened path ->
        "cannot open vault "
            <> path
            <> ": wrong passphrase, corrupt file, or not a singular vault"
    SignVaultNotAmongSigners address ->
        "the vault's address "
            <> address
            <> " is not among the bundle's signers"
    SignOutputExists path -> "the witness file already exists: " <> path
    SignNotWritten path -> "cannot write the witness file: " <> path

{- | One witness to write: its file name, its envelope bytes and the
summary lines it adds to standard error.
-}
data PlannedWitness = PlannedWitness
    { plannedPath :: FilePath
    {- ^ the file name, the transaction's identity in hex with
    @.witness@ appended
    -}
    , plannedBytes :: ByteString
    -- ^ the witness envelope's JSON bytes
    , plannedSummary :: [String]
    -- ^ what standard error says about this transaction
    }
    deriving stock (Eq, Show)

{- | The pure core of the verb: the bundle's bytes and the opened
vault's key become the witnesses to write, or the first named refusal.
The bundle is decoded and checked, the vault's address is derived for
the bundle's network and must be among the signers, and each body's
witness is signed over its own hash. Pure.
-}
witnessPlan
    :: ByteString
    -> SignKeyDSIGN Ed25519DSIGN
    -> Either SignRefusal [PlannedWitness]
witnessPlan bytes key = do
    bundle <- first SignBundle (decodeBundle bytes)
    witnesses <- bundleWitnesses bundle key
    pure
        [ PlannedWitness
            { plannedPath = hexText (bundleTxIdentity tx) <> ".witness"
            , plannedBytes = encodeTextEnvelope (witnessEnvelope witness)
            , plannedSummary = summaryOf bundle tx
            }
        | (tx, witness) <- zip (toList (bundleTransactions bundle)) witnesses
        ]

{- | The detached witness of every transaction of a checked, in-memory
bundle for the vault's key, in the bundle's order, or the first named
refusal: the bundle is checked, the vault's address is derived for the
bundle's network and must be among the signers, and each body's witness
is signed over its own hash. The witnesses @wallet sign@ writes, and the
ones the vault mode sends without a file. Pure.
-}
bundleWitnesses
    :: Bundle
    -> SignKeyDSIGN Ed25519DSIGN
    -> Either SignRefusal [DetachedWitness]
bundleWitnesses bundle key = do
    first SignBundle (checkBundle bundle)
    let address = vaultAddress (bundleNetworkMagic bundle) key
    unless
        (address `elem` map Text.unpack (toList (bundleSigners bundle)))
        $ Left (SignVaultNotAmongSigners address)
    forM (toList (bundleTransactions bundle)) $ \tx ->
        case decodeTransactionEnvelope (bundleTxEnvelope tx) of
            Left _ ->
                Left
                    ( SignBundle
                        (BundleEnvelopeUndecodable (hexText (bundleTxIdentity tx)))
                    )
            Right transaction -> pure (witnessData (detachedWitness key transaction))

-- | The witness as the envelope's data: the key and signature bytes.
witnessData :: WitVKey Witness -> DetachedWitness
witnessData (WitVKey (VKey verKey) (SignedDSIGN sig)) =
    DetachedWitness
        { detachedKeyBytes = rawSerialiseVerKeyDSIGN verKey
        , detachedSignatureBytes = rawSerialiseSigDSIGN sig
        }

-- | The vault's enterprise address for the network the bundle names.
vaultAddress :: Word32 -> SignKeyDSIGN Ed25519DSIGN -> String
vaultAddress magic key = bech32Address (walletAddr (walletFromSignKey magic key))

{- | What standard error says about one transaction: its identity, its
deadline, the signers and the writer's claimed effects.
-}
summaryOf :: Bundle -> BundleTransaction -> [String]
summaryOf bundle tx =
    ( "signed "
        <> hexText (bundleTxIdentity tx)
        <> ", deadline "
        <> maybe "none" show (bundleTxDeadline tx)
        <> ", among "
        <> show (length (toList (bundleSigners bundle)))
        <> " signer addresses"
        <> maybe
            ""
            (\token -> ", registry " <> Text.unpack token)
            (bundleStateToken bundle)
    )
        : map (("  effect: " <>) . Text.unpack) (bundleTxEffects tx)

{- | @wallet sign@: read the bundle, ask the passphrase once, open the
vault, plan the witnesses and write them exclusively into the output
directory — the bundle's own directory when none is named. The witness
paths print on standard output, one per line, and the summary on
standard error; a refusal prints one line on standard error, nothing
on standard output, and exits 1.
-}
signBundle
    :: FilePath
    -- ^ the bundle file
    -> FilePath
    -- ^ the vault file
    -> PassphraseSource
    -- ^ where the passphrase is read from
    -> Maybe FilePath
    -- ^ the output directory; the bundle's directory when nothing
    -> IO ExitCode
signBundle bundlePath vaultPath source outputDirectory = do
    asked <- readPassphrase AskOnce source
    case asked of
        Left refusal -> refused (SignPassphrase refusal)
        Right passphrase -> runWith passphrase
  where
    runWith passphrase = do
        bundle <- try (BS.readFile bundlePath)
        case bundle of
            Left (_ :: IOException) ->
                refused (SignBundleUnreadable bundlePath)
            Right bytes -> do
                sealed <- try (BS.readFile vaultPath)
                case sealed of
                    Left (_ :: IOException) ->
                        refused (SignVaultNotOpened vaultPath)
                    Right vaultBytes -> case openVault passphrase vaultBytes of
                        Left _ -> refused (SignVaultNotOpened vaultPath)
                        Right key -> case witnessPlan bytes key of
                            Left refusal -> refused refusal
                            Right plan -> writePlan bundlePath outputDirectory plan

{- | Write the planned witnesses exclusively, print each path on
standard output and its summary on standard error, and succeed.
-}
writePlan
    :: FilePath -> Maybe FilePath -> [PlannedWitness] -> IO ExitCode
writePlan bundlePath outputDirectory plan = do
    let directory = fromMaybe (takeDirectory bundlePath) outputDirectory
    made <- try (createDirectoryIfMissing True directory)
    case made of
        Left (_ :: IOException) -> refused (SignNotWritten directory)
        Right () -> do
            outcomes <- forM plan $ \planned -> do
                let path = directory </> plannedPath planned
                outcome <- writeExclusively path (plannedBytes planned)
                case outcome of
                    Left refusal -> pure (Left refusal)
                    Right () -> do
                        putStrLn path
                        forM_ (plannedSummary planned) (hPutStrLn stderr)
                        pure (Right ())
            case lefts outcomes of
                (refusal : _) -> refused refusal
                [] -> pure ExitSuccess

{- | The mode a witness is born with: readable by all, writable by its
owner only — a witness is public data.
-}
witnessFileMode :: FileMode
witnessFileMode =
    ownerReadMode
        `unionFileModes` ownerWriteMode
        `unionFileModes` groupReadMode
        `unionFileModes` otherReadMode

{- | Create the witness file exclusively and write the bytes; the file
this call made is removed if the write fails; an existing path of any
kind — a regular file or a symbolic link — is refused untouched.
-}
writeExclusively
    :: FilePath -> ByteString -> IO (Either SignRefusal ())
writeExclusively path bytes = do
    opened <-
        try
            ( openFd
                path
                WriteOnly
                defaultFileFlags
                    { exclusive = True
                    , creat = Just witnessFileMode
                    , nofollow = True
                    }
            )
    case opened of
        Right fd -> writeBracketed fd
        Left (_ :: IOException) -> do
            present <- try (getSymbolicLinkStatus path)
            case present of
                Right _ -> pure (Left (SignOutputExists path))
                Left (_ :: IOException) -> pure (Left (SignNotWritten path))
  where
    writeBracketed fd =
        bracket (fdToHandle fd) hClose $ \handle -> do
            written <- try (BS.hPut handle bytes)
            case written of
                Left (_ :: IOException) -> pure (Left (SignNotWritten path))
                Right () -> pure (Right ())

{- | One line on standard error naming the cause, nothing on standard
output, exit 1. No refusal names the passphrase or the key.
-}
refused :: SignRefusal -> IO ExitCode
refused refusal = do
    hPutStrLn stderr ("singular: " <> renderSignRefusal refusal)
    pure (ExitFailure 1)
