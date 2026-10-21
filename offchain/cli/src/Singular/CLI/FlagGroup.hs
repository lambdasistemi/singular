{-# LANGUAGE LambdaCase #-}

{- |
Module      : Singular.CLI.FlagGroup
Description : The one flag group every registry binary reads
License     : Apache-2.0

The spellings every binary shares — the valued flags, the switches, the
tokenizer, the tracing strip and the provider and write readers — in one
place, so a change to a flag is made once. Each binary passes the extra
valued flags it owns beyond the common group (its own command flags stay
with its commands). The error constructors are parameters, so each
binary's own refusal type is raised with today's texts and today's
order; the reading itself is shared.

* 'commonFlagGroup' is the valued flags every binary reads;
* 'commonSwitches' is the switches every binary reads;
* 'tokenizeWith' splits a command line over a full valued list;
* 'tokenizeFor' splits one over the common group plus a binary's extras;
* 'splitTracingFor' takes the tracing flags out of a command line;
* 'readProviderSettings' reads the node settings from tokenized flags;
* 'parseFlagGroup' reads the write settings from tokenized flags: the
  single write reader both binaries call;
* 'payloadSchemaFrom' reads the form a payload file is written in.
-}
module Singular.CLI.FlagGroup
    ( commonFlagGroup
    , commonSwitches
    , Signer (..)
    , OpenedVault (..)
    , signerAddress
    , tokenizeWith
    , tokenizeFor
    , splitTracingFor
    , traceFlags
    , traceRequestFrom
    , readProviderSettings
    , parseFlagGroup
    , payloadSchemaFrom
    ) where

import Control.Applicative ((<|>))
import Control.Monad (foldM, forM_, when)
import Data.Bifunctor (first)
import Data.List (isPrefixOf)
import Data.Maybe (fromMaybe, isJust, isNothing)
import Data.Text (Text)
import Data.Text qualified as Text
import Text.Read (readMaybe)

import Cardano.Ledger.Address (Addr (..), decodeAddrEither)
import Cardano.Ledger.Credential (Credential (..))
import Codec.Binary.Bech32 qualified as Bech32

import Singular.CLI.Trace
    ( TraceFormat (..)
    , TraceLevel (..)
    , TraceRequest (..)
    , TraceSink (..)
    , noTraceRequest
    )
import Singular.Registry.PlainJson
    ( PayloadSchema (..)
    , parseSchemaName
    )
import Singular.Registry.ProviderSettings (ProviderSettings (..))
import Singular.Registry.Wallet (Wallet, bech32Address, walletAddr)

{- | How one write signs: a key file, as today; an external signer — an
address spelled in bech32 exactly as the caller gave it together with the
bundle file the run's unsigned transactions are written to; or a vault —
the vault file and the descriptor its passphrase is read from, the
terminal when none is named. Exactly one signer names a run; the write
reader refuses the mixtures. The reader holds no secret: the vault is a
path until the command opens it, once, into 'SignerVaultOpened'.
-}
data Signer
    = SignerKeyFile FilePath
    | SignerExternal Text FilePath
    | SignerVault FilePath (Maybe Int)
    | SignerVaultOpened OpenedVault
    deriving stock (Eq, Show)

{- | A vault opened for one run: the wallet its key derives, held in memory
for the command's lifetime. It shows as its address alone and compares by
it, so no rendering of a signer carries a key byte.
-}
newtype OpenedVault = OpenedVault Wallet

instance Show OpenedVault where
    showsPrec p (OpenedVault wallet) =
        showParen (p > 10) $
            showString "OpenedVault " . shows (bech32Address (walletAddr wallet))

instance Eq OpenedVault where
    OpenedVault a == OpenedVault b = walletAddr a == walletAddr b

{- | The address of an external signer, as the ledger reads it: bech32,
decoded, and refused unless its payment part is a payment key — an address
that pays a script, or a bootstrap address, cannot sign a bundle. Pure.
-}
signerAddress :: Text -> Either String Addr
signerAddress given = do
    (_, dataPart) <- first (const notBech32) (Bech32.decode given)
    bytes <-
        maybe (Left notBech32) Right (Bech32.dataPartToBytes dataPart)
    address <- first (const notBech32) (decodeAddrEither bytes)
    case address of
        Addr _ (KeyHashObj _) _ -> Right address
        Addr _ (ScriptHashObj _) _ -> Left paysScript
        AddrBootstrap _ -> Left bootstrap
  where
    notBech32 =
        Text.unpack given
            <> " is not a bech32 address: name the signer's own address"
    paysScript =
        Text.unpack given
            <> " pays a script, not a payment key: the bundle's signer must be a payment key"
    bootstrap =
        Text.unpack given
            <> " is a bootstrap address: the bundle's signer must be a payment key"

-- | The valued flags every binary reads with today's refusals.
commonFlagGroup :: [String]
commonFlagGroup =
    [ "--state-dir"
    , "--blueprint"
    , "--koios-url"
    , "--koios-token-file"
    , "--network-time"
    , "--network-magic"
    , "--wallet-skey"
    , "--seed"
    , "--process-time"
    , "--retract-time"
    , "--key"
    , "--key-hex"
    , "--receipt"
    , "--confirm-timeout"
    , "--wallet-address"
    , "--bundle"
    , "--vault"
    , "--passphrase-fd"
    , "--outputs-at"
    , "--fund-input"
    , "--max-outlay"
    , "--deposit"
    , "--payload"
    , "--payload-schema"
    , "--request"
    , "--state-token"
    ]

-- | The switches every binary reads: help, preview and fold.
commonSwitches :: [String]
commonSwitches = ["--help", "-h", "--preview", "--fold"]

{- | Split a command line into its words and its flags over a full valued
list, the first occurrence of a flag winning. A value flag takes the
next token or its @=value@ spelling; a switch takes nothing.
-}
tokenizeWith
    :: (String -> e)
    -- ^ the removed-setting refusal
    -> (String -> String -> e)
    -- ^ the bad-value refusal
    -> [String]
    -- ^ the full valued list the caller reads
    -> [String]
    -- ^ the raw command line
    -> Either e ([String], [(String, Maybe String)])
tokenizeWith removed bad full = go [] []
  where
    go ws fs [] = Right (reverse ws, reverse fs)
    go ws fs (a : rest)
        | "--" `isPrefixOf` a || a == "-h" =
            let (name, inline) = break (== '=') a
            in  if name == "--registry"
                    then Left (bad "--registry" "was renamed to --state-dir")
                    else
                        if name `elem` ["--backend", "--node-socket"]
                            then Left (removed name)
                            else
                                if name `elem` commonSwitches
                                    then go ws ((name, Nothing) : fs) rest
                                    else
                                        if name `elem` full
                                            then case (inline, rest) of
                                                ('=' : v, _) -> go ws (keep name v fs) rest
                                                (_, v : rest') -> go ws (keep name v fs) rest'
                                                (_, []) -> Left (bad name "needs a value")
                                            else Left (bad name "is not a flag singular reads")
        | otherwise = go (a : ws) fs rest
    keep name v fs
        | isJust (lookup name fs) = fs
        | otherwise = (name, Just v) : fs

{- | Split a command line over the common group plus the extra valued
flags the calling binary owns beyond it.
-}
tokenizeFor
    :: (String -> e)
    -- ^ the removed-setting refusal
    -> (String -> String -> e)
    -- ^ the bad-value refusal
    -> [String]
    -- ^ the extra valued flags the calling binary owns
    -> [String]
    -- ^ the raw command line
    -> Either e ([String], [(String, Maybe String)])
tokenizeFor removed bad extra = tokenizeWith removed bad (commonFlagGroup <> extra)

{- | Take the tracing flags out of a command line, each value read and
refused at parse: @--trace@ and @--trace-format@ once (the first occurrence
wins, as for every flag), @--trace-to@ once per sink, in order. A value flag
keeps its value, so a value spelled like a tracing flag stays a value.
-}
splitTracingFor
    :: (String -> String -> e)
    -- ^ the bad-value refusal
    -> [String]
    -- ^ the extra valued flags the calling binary owns
    -> [String]
    -- ^ the raw command line
    -> Either e ([String], TraceRequest)
splitTracingFor bad extra = go [] noTraceRequest
  where
    full = commonFlagGroup <> extra
    go kept asked = \case
        [] ->
            Right
                (reverse kept, asked{requestSinks = reverse (requestSinks asked)})
        a : rest
            | name `elem` traceFlags ->
                case (inline, rest) of
                    ('=' : v, _) -> withValue bad name v asked >>= \r -> go kept r rest
                    (_, v : rest') -> withValue bad name v asked >>= \r -> go kept r rest'
                    (_, []) -> Left (bad name "needs a value")
            | name `elem` full
            , null inline
            , v : rest' <- rest ->
                go (v : a : kept) asked rest'
            | otherwise -> go (a : kept) asked rest
          where
            (name, inline) = break (== '=') a

-- | The valued tracing flags.
traceFlags :: [String]
traceFlags = ["--trace", "--trace-to", "--trace-format"]

{- | The tracing a command line asks for, from the tracing flags it carried
in the order given, each value read and refused: the first @--trace@ and
@--trace-format@ win, every @--trace-to@ is a sink.
-}
traceRequestFrom
    :: (String -> String -> e)
    -- ^ the bad-value refusal
    -> [(String, String)]
    -- ^ each tracing flag with its value
    -> Either e TraceRequest
traceRequestFrom bad entries = do
    asked <-
        foldM
            (\request (name, v) -> withValue bad name v request)
            noTraceRequest
            entries
    pure asked{requestSinks = reverse (requestSinks asked)}

-- | Read one tracing flag's value into the request so far.
withValue
    :: (String -> String -> e)
    -> String
    -> String
    -> TraceRequest
    -> Either e TraceRequest
withValue bad name v asked = case name of
    "--trace" -> case v of
        "off" -> level TraceOff
        "what" -> level TraceWhat
        "how" -> level TraceHow
        _ -> Left (bad name "is off, what or how")
    "--trace-to" -> case v of
        "stderr" -> sink ToStderr
        'f' : 'i' : 'l' : 'e' : ':' : path@(_ : _) -> sink (ToFile path)
        _ -> Left (bad name "is stderr or file:PATH")
    _ -> case v of
        "text" -> format TextFormat
        "json" -> format JsonFormat
        _ -> Left (bad name "is text or json")
  where
    level l = Right asked{requestLevel = requestLevel asked <|> Just l}
    sink s = Right asked{requestSinks = s : requestSinks asked}
    format f = Right asked{requestFormat = requestFormat asked <|> Just f}

-- | How reading the node settings can fail, before a binary names it.
data ProviderRead
    = ProviderMissing String
    | ProviderBad String String

-- | Read the node settings from tokenized flags, naming failures privately.
readProvider
    :: [(String, Maybe String)] -> Either ProviderRead ProviderSettings
readProvider flags = do
    url <- case flagValue "--koios-url" flags of
        Just v -> Right v
        Nothing -> Left (ProviderMissing "--koios-url")
    when (null url) (Left (ProviderBad "--koios-url" "is empty"))
    magicText <- case flagValue "--network-magic" flags of
        Just v -> Right v
        Nothing -> Left (ProviderMissing "--network-magic")
    magic <-
        maybe
            (Left (ProviderBad "--network-magic" "not a number"))
            Right
            (readMaybe magicText)
    Right
        ProviderSettings
            { providerUrl = url
            , providerMagic = magic
            , providerTokenFile = flagValue "--koios-token-file" flags
            , providerTimeDirectory = flagValue "--network-time" flags
            }

-- | The value of a tokenized flag, if it took one.
flagValue :: String -> [(String, Maybe String)] -> Maybe String
flagValue name flags = case lookup name flags of
    Just (Just v) -> Just v
    _ -> Nothing

{- | Read the node settings from tokenized flags: the service, the
network magic, the optional token file and time directory.
-}
readProviderSettings
    :: (String -> e)
    -- ^ the missing-flag refusal
    -> (String -> String -> e)
    -- ^ the bad-value refusal
    -> [(String, Maybe String)]
    -- ^ the tokenized flags
    -> Either e ProviderSettings
readProviderSettings missing bad flags = case readProvider flags of
    Left (ProviderMissing name) -> Left (missing name)
    Left (ProviderBad name why) -> Left (bad name why)
    Right settings -> Right settings

{- | Read the write settings from tokenized flags: the caller names the
service, network and exactly one signer — the signing key, or the address
with its bundle file — mainnet is refused, and a non-numeric network magic
is an unsafe configuration rather than a bad value. The single write reader
both binaries call; it hands the signer to the settings constructor in place
of the old key-file path.
-}
parseFlagGroup
    :: (String -> e)
    -- ^ the missing-flag refusal
    -> (String -> String -> e)
    -- ^ the bad-value refusal
    -> (String -> e)
    -- ^ the unsafe-settings refusal
    -> (ProviderSettings -> Signer -> Maybe Int -> w)
    -- ^ the write settings the calling binary keeps
    -> [(String, Maybe String)]
    -- ^ the tokenized flags
    -> Either e w
parseFlagGroup missing bad unsafe mkWrite flags = do
    let keyNamed = flagValue "--wallet-skey" flags
        addressNamed = flagValue "--wallet-address" flags
        bundleNamed = flagValue "--bundle" flags
        vaultNamed = flagValue "--vault" flags
        descriptorNamed = flagValue "--passphrase-fd" flags
    case (keyNamed, addressNamed) of
        (Just _, Just _) ->
            Left
                ( bad
                    "--wallet-address"
                    "cannot be combined with --wallet-skey: a write takes exactly one signer"
                )
        _ -> Right ()
    case (vaultNamed, keyNamed, addressNamed) of
        (Just _, Just _, _) ->
            Left
                ( bad
                    "--vault"
                    "cannot be combined with --wallet-skey: a write takes exactly one signer"
                )
        (Just _, _, Just _) ->
            Left
                ( bad
                    "--vault"
                    "cannot be combined with --wallet-address: a write takes exactly one signer"
                )
        _ -> Right ()
    when (isJust descriptorNamed && isNothing vaultNamed) $
        Left
            ( bad
                "--passphrase-fd"
                "is meaningless without --vault: name the vault too"
            )
    case (addressNamed, bundleNamed) of
        (Just _, Nothing) ->
            Left
                ( bad
                    "--bundle"
                    ( "is required with --wallet-address: the run's transactions are "
                        <> "written to the bundle for signing elsewhere"
                    )
                )
        (Nothing, Just _) ->
            Left
                ( bad
                    "--bundle"
                    "is meaningless without --wallet-address: name the signer too"
                )
        _ -> Right ()
    when (isJust bundleNamed && isJust (lookup "--preview" flags)) $
        Left
            ( bad
                "--bundle"
                "cannot be used with --preview: a preview signs and writes nothing"
            )
    let staged = isJust addressNamed || isJust bundleNamed || isJust vaultNamed
    forM_ ["--koios-url", "--network-magic"] $ \name ->
        when (isNothing (flagValue name flags)) $
            Left
                ( unsafe
                    ( "partially configured write: missing "
                        <> name
                        <> "; "
                        <> writeNeeds
                    )
                )
    when (not staged && isNothing keyNamed) $
        Left
            (unsafe ("partially configured write: no signer; " <> writeNeeds))
    settings <- case readProvider flags of
        Left (ProviderBad "--network-magic" _) ->
            Left
                ( unsafe
                    ( "network magic is not a number: "
                        <> fromMaybe "" (flagValue "--network-magic" flags)
                    )
                )
        Left (ProviderMissing name) -> Left (missing name)
        Left (ProviderBad name why) -> Left (bad name why)
        Right providers -> Right providers
    when (providerMagic settings == 764824073) $
        Left (unsafe "mainnet is not supported")
    signer <- case (keyNamed, addressNamed, bundleNamed, vaultNamed) of
        (Just path, Nothing, Nothing, Nothing) -> Right (SignerKeyFile path)
        (Nothing, Just address, Just bundle, Nothing) -> do
            let given = Text.pack address
            SignerExternal given bundle
                <$ first (bad "--wallet-address") (signerAddress given)
        (Nothing, Nothing, Nothing, Just vault) ->
            SignerVault vault <$> case descriptorNamed of
                Nothing -> Right Nothing
                Just spelling -> case readMaybe spelling of
                    Just n | n >= 0 -> Right (Just n)
                    _ -> Left (bad "--passphrase-fd" "not a descriptor number")
        _ ->
            Left
                (unsafe ("partially configured write: no signer; " <> writeNeeds))
    confirmationTimeout <- case flagValue "--confirm-timeout" flags of
        Nothing -> Right Nothing
        Just value -> case readMaybe value of
            Just n | n >= 0 -> Right (Just n)
            _ ->
                Left (bad "--confirm-timeout" "is not a whole number of seconds")
    pure (mkWrite settings signer confirmationTimeout)

{- | What a write needs, said the same way whichever part is missing: the node
and a signer, the vault first and the key file, which is legacy, last.
-}
writeNeeds :: String
writeNeeds =
    "a write needs --koios-url, --network-magic and a signer: \
    \--vault FILE, or --wallet-address ADDR with --bundle FILE, \
    \or --wallet-skey FILE (legacy)"

{- | The form the payload file of a command is written in: what
@--payload-schema@ names, and plain when it names nothing. A name that is
neither is a refusal of the flag, raised with the binary's own constructor.
-}
payloadSchemaFrom
    :: (String -> String -> e)
    -- ^ the bad-value refusal
    -> [(String, Maybe String)]
    -- ^ the tokenized flags
    -> Either e PayloadSchema
payloadSchemaFrom bad flags = case lookup "--payload-schema" flags of
    Just (Just name) ->
        maybe
            ( Left
                ( bad
                    "--payload-schema"
                    "is not a payload schema: give plain or detailed"
                )
            )
            Right
            (parseSchemaName (Text.pack name))
    _ -> Right PlainSchema
