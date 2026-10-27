{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

{- |
Module      : Singular.CLI.ParserCorpusSpec
Description : Every command line in use gives the same parse result as before
License     : Apache-2.0

The corpus is the command lines the Demo 1 journeys, the Demo 1 guide and the
documentation use, then every flag the shared group owns appended to each
command's valid line, each required flag removed in turn, bad values, every
mixture of signer flags, and the structural cases (unknown flag, missing
value, extra words, repeated flags, flags in front of the command words,
removed settings). Each line carries the parse result recorded from the
parser that read command lines by hand; the parser reading them now must give
the same result. A line whose result is allowed to differ carries the new
result in an @after@ field, and the difference is listed in the pull
request.

A result is the parse outcome as the user meets it: the command or the
refusal, with the refusal's own text. Help is one outcome whichever command's
help it is, because the help text itself is pinned by the help snapshots.

Set @CLI_CORPUS_RECORD=FILE@ to write the corpus with freshly parsed results
to FILE instead of comparing.
-}
module Singular.CLI.ParserCorpusSpec (spec) where

import Data.Aeson (Value (..), object, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy.Char8 qualified as LBC
import Data.Foldable (toList)
import Data.List (nub, sort)
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Text qualified as T
import System.Environment (lookupEnv)
import Test.Hspec

import Crypto.Hash (Digest, SHA256, hash)

import Cardano.Crypto.Hash.Class (hashFromBytes)
import Cardano.Ledger.Address (Addr (..))
import Cardano.Ledger.BaseTypes (Network (Testnet))
import Cardano.Ledger.Credential
    ( Credential (..)
    , StakeReference (..)
    )
import Cardano.Ledger.Hashes (ScriptHash (..))

import Singular.CLI.Command
    ( CLIError
    , Command (..)
    , parseInvocation
    , renderCLIError
    )
import Singular.CLI.Trace (TraceRequest)
import Singular.Registry.TxBuilder.Internal (addrFromKeyHashBytes)
import Singular.Registry.Wallet (bech32Address)

-- | Where the committed corpus lives, relative to the package.
corpusFile :: FilePath
corpusFile = "test/fixtures/cli-corpus/singular.json"

spec :: Spec
spec = describe "the command lines in use" $ do
    it "keep the parse results recorded before the parser changed" $ do
        recording <- lookupEnv "CLI_CORPUS_RECORD"
        entries <- readCorpus corpusFile
        case recording of
            Just out -> do
                BS.writeFile out $
                    "[\n"
                        <> BC.intercalate
                            ",\n"
                            [ BC.pack
                                ( LBC.unpack
                                    ( Aeson.encode
                                        (withResult (fst (outcome entry)) entry)
                                    )
                                )
                            | entry <- entries
                            ]
                        <> "\n]\n"
                pendingWith
                    ("recorded " <> show (length entries) <> " lines to " <> out)
            Nothing -> do
                let mismatches =
                        [ (entry, expected, got, detail)
                        | entry <- entries
                        , let expected = expectedResult entry
                        , let (got, detail) = outcome entry
                        , expected /= got
                        ]
                case mismatches of
                    [] -> pure ()
                    _ ->
                        expectationFailure . unlines $
                            [ show (length mismatches)
                                <> " of "
                                <> show (length entries)
                                <> " command lines changed their result; the first:"
                            ]
                                <> concat
                                    [ [ "  " <> show (entryArgs e)
                                      , "    was: " <> expected
                                      , "    now: " <> got
                                      , "    in full: " <> detail
                                      ]
                                    | (e, expected, got, detail) <- take 8 mismatches
                                    ]
    it "reach every command, accepted and refused" $ do
        entries <- readCorpus corpusFile
        let accepted = nub (sort (mapMaybe acceptedKind entries))
        accepted
            `shouldBe` sort
                [ "Create"
                , "Fold"
                , "Help"
                , "Inspect"
                , "Reclaim"
                , "Reject"
                , "StateCreate"
                , "SubmitBundle"
                , "WalletAddress"
                , "WalletCreate"
                , "WalletSign"
                ]
        length entries `shouldSatisfy` (> 1500)
        length [() | e <- entries, "refused" `isPrefix` expectedResult e]
            `shouldSatisfy` (> 500)
  where
    isPrefix p s = take (length p) s == p
    acceptedKind entry = case parseEntry entry of
        Right (Help{}, _) -> Just "Help"
        Right (command, _) -> Just (takeWhile (/= ' ') (show command))
        Left _ -> Nothing

-- | One recorded command line.
data Entry = Entry
    { entryEnv :: [(String, String)]
    , entryArgs :: [String]
    , entryRecorded :: Maybe String
    , entryAfter :: Maybe String
    }

withResult :: String -> Entry -> Value
withResult result Entry{..} =
    object $
        [ "args" .= entryArgs
        , "result" .= result
        ]
            <> [ "env" .= object [Key.fromString k .= v | (k, v) <- entryEnv]
               | not (null entryEnv)
               ]
            <> maybe [] (\a -> ["after" .= a]) entryAfter

expectedResult :: Entry -> String
expectedResult entry = case entryAfter entry of
    Just changed -> changed
    Nothing -> fromMaybe "" (entryRecorded entry)

{- | What a line gives, as pinned: a refusal in full, help as one outcome, an
accepted command by its name and the digest of everything it carries. The
second component is the full account, printed when a pinned result changes.
-}
outcome :: Entry -> (String, String)
outcome entry = case parseEntry entry of
    Left err ->
        let line = "refused: " <> show err <> " | " <> renderCLIError err
        in  (line, line)
    Right (Help{}, _) -> ("help", "help")
    Right (command, request) ->
        let full = show command <> " " <> show request
            digest = hash (BC.pack full) :: Digest SHA256
        in  ( "accepted "
                <> takeWhile (/= ' ') (show command)
                <> " sha256:"
                <> take 32 (show digest)
            , "accepted: " <> full
            )

parseEntry :: Entry -> Either CLIError (Command, TraceRequest)
parseEntry entry = parseInvocation (entryEnv entry) (entryArgs entry)

-- | Read a corpus file, putting the run-time spellings in place of the placeholders.
readCorpus :: FilePath -> IO [Entry]
readCorpus path = do
    contents <- BS.readFile path
    case Aeson.decodeStrict contents of
        Just values -> pure [entry | v <- values, Just entry <- [decodeEntry v]]
        Nothing -> fail ("not a JSON array of command lines: " <> path)
  where
    decodeEntry value = do
        Object o <- Just value
        args <- strings =<< KeyMap.lookup "args" o
        let env = case KeyMap.lookup "env" o of
                Just (Object e) ->
                    [ (Key.toString k, T.unpack t)
                    | (k, String t) <- KeyMap.toList e
                    ]
                _ -> []
            text key = case KeyMap.lookup key o of
                Just (String t) -> Just (T.unpack t)
                _ -> Nothing
        Just
            Entry
                { entryEnv = [(k, spell v) | (k, v) <- env]
                , entryArgs = map spell args
                , entryRecorded = text "result"
                , entryAfter = text "after"
                }
    strings = \case
        Array vs ->
            traverse
                (\case String t -> Just (T.unpack t); _ -> Nothing)
                (toList vs)
        _ -> Nothing
    spell s
        | s == "@ADDRESS@" = anAddress
        | s == "@SCRIPT_ADDRESS@" = aScriptAddress
        | otherwise = s

-- | A bech32 payment-key address, produced from a key hash, never typed.
anAddress :: String
anAddress = bech32Address (addrFromKeyHashBytes Testnet (BS.replicate 28 0x5a))

-- | A bech32 address whose payment part is a script, derived at run time.
aScriptAddress :: String
aScriptAddress =
    bech32Address (Addr Testnet (ScriptHashObj scriptHash) StakeRefNull)
  where
    scriptHash = case hashFromBytes (BS.replicate 28 3) of
        Just h -> ScriptHash h
        Nothing -> error "a script hash is 28 bytes"
