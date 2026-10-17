{-# LANGUAGE LambdaCase #-}

{- |
Module      : Main
Description : A test-harness tool: seal a devnet key file into a wallet vault
License     : Apache-2.0

A tool for the packaged controls, never evidence of anything: the
devnet funds key files, and a control that signs from a vault needs that
same key sealed. It reads a key file (the hex or text-envelope spelling
the signing commands read) and a passphrase from standard input, one line,
and creates the vault exactly as @singular wallet create@ does: the
production sealing at the house work factor, the file created exclusively
with mode 0600. It prints nothing on success; a refusal is one line on
standard error, naming no secret, and exit 1.

usage: vault-seal KEY_FILE VAULT_FILE < passphrase
-}
module Main (main) where

import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import System.Environment (getArgs)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

import Singular.CLI.Passphrase (mkPassphrase, renderPassphraseRefusal)
import Singular.CLI.Vault
    ( createVaultFile
    , renderVaultRefusal
    , sealVault
    , vaultWorkFactor
    )
import Singular.Registry.Wallet (parseSignKey)

main :: IO ()
main =
    getArgs >>= \case
        [keyPath, vaultPath] -> do
            raw <- BS.readFile keyPath
            key <-
                either
                    (const (refuse ("the key file " <> keyPath <> " is not a signing key")))
                    pure
                    (parseSignKey raw)
            line <- BC.takeWhile (/= '\n') <$> BS.getContents
            passphrase <-
                either (refuse . renderPassphraseRefusal) pure (mkPassphrase line)
            sealed <-
                sealVault vaultWorkFactor passphrase key
                    >>= either (refuse . renderVaultRefusal) pure
            createVaultFile vaultPath sealed
                >>= either (refuse . renderVaultRefusal) pure
        _ -> refuse "usage: vault-seal KEY_FILE VAULT_FILE < passphrase"
  where
    refuse why = hPutStrLn stderr ("vault-seal: " <> why) >> exitFailure
