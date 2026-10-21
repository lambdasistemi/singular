{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.CLI.Describe
Description : @singular registry describe@: the registry page from the chain alone
License     : Apache-2.0

Describe takes the state token, the blueprint of the packaged release, a
provider and a network, and nothing else: no wallet, no signing key, no
state directory and no file of any actor. It selects the registry from
its token and the release, runs the same public replay @inspect@ reads,
reads the live request outputs, and prints the page @Singular.Registry.Page@
renders from those facts: indented JSON, with or without @--json@.

Every write setting is refused by the parser before anything is read. The
version label comes from @version.txt@ beside the blueprint and is refused
by name when missing, unreadable or malformed, before any provider read.
A success prints the page alone on standard output and writes no file;
every refusal prints the usual one JSON receipt and exits non-zero, with
the trace events a command keeps.
-}
module Singular.CLI.Describe
    ( runDescribe
    , runDescribeCommand
    , readVersionLabel
    ) where

import Control.Exception
    ( IOException
    , SomeAsyncException
    , SomeException
    , fromException
    , try
    , tryJust
    )
import Control.Monad (forM_, unless)
import Control.Tracer (Tracer, traceWith)
import Data.Aeson (Value, toJSON)
import Data.Aeson qualified as Aeson
import Data.Aeson.Encode.Pretty (encodePretty)
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy.Char8 qualified as BLC
import Data.ByteString.Short qualified as SBS
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import System.Directory (doesFileExist)
import System.Exit (ExitCode (..))
import System.FilePath (takeDirectory, (</>))

import Cardano.Crypto.Hash.Class (hashToBytes)
import Cardano.Ledger.BaseTypes (Network (Testnet))
import Cardano.Ledger.Hashes (extractHash)
import Cardano.Ledger.TxIn (TxId (..))

import Singular.CLI.Command
    ( DescribeArgs (..)
    , ProviderSettings (..)
    , RegistryAccess (..)
    )
import Singular.CLI.Inspect (pendingJson)
import Singular.CLI.Key (maxKeyBytes)
import Singular.CLI.Live
    ( attachLive
    , failTrie
    , liveState
    , receipt
    , requireTrieSelection
    , resolveSaved
    , savedCfg
    , savedToken
    , txInText
    , withTrie
    )
import Singular.CLI.ManagedState (resolveStateRoot, statelessDir)
import Singular.CLI.Receipt
    ( OutcomeClass (..)
    , exitCodeOf
    , outcomeName
    )
import Singular.CLI.Registry (hexT)
import Singular.CLI.Session
    ( CommandFailure (..)
    , Env (..)
    , failWith
    , loadReleaseFor
    , readOnce
    , reportedOf
    )
import Singular.CLI.Trace
    ( Event (..)
    , RefusalKind (..)
    , Trace (..)
    , What (..)
    )
import Singular.Registry.Address
    ( registryFingerprint
    , renderRegistryAddress
    )
import Singular.Registry.Application (Application)
import Singular.Registry.Config (CageConfig (..))
import Singular.Registry.Page
    ( Page
    , PageInputs (..)
    , PageRefusal (..)
    , ReleaseInfo (..)
    , blueprintSha
    , describeRegistry
    , parseVersionLabel
    , renderPageJson
    , renderPageRefusal
    )
import Singular.Registry.SessionIO qualified as Cage
import Singular.Registry.StateToken (renderStateToken)
import Singular.Registry.Trace (startTimer)
import Singular.Registry.TrieState (Leaf (..))
import Singular.Registry.TrieState qualified as TS
import Singular.Registry.TxBuilder.Internal
    ( extractCageDatum
    , findRequestUtxos
    , requestAddrFromCfg
    , scriptHashBytes
    )
import Singular.Registry.Types
    ( CageDatum (..)
    , OnChainRoot (..)
    , OnChainTokenState (..)
    )
import Singular.Registry.WaitTypes (WaitFailure)

-- | The version label beside a blueprint, or why no label is printed.
readVersionLabel :: FilePath -> IO (Either PageRefusal Text)
readVersionLabel blueprint = do
    let versionFile = takeDirectory blueprint </> "version.txt"
    present <- doesFileExist versionFile
    if not present
        then pure (Left VersionMissing)
        else do
            content <-
                try (TIO.readFile versionFile) :: IO (Either IOException Text)
            pure $ case content of
                Left why -> Left (VersionUnreadable (T.pack (show why)))
                Right raw -> parseVersionLabel raw

-- | The blueprint preamble title, or why the blueprint names none.
blueprintTitle :: BS.ByteString -> Either String Text
blueprintTitle bytes = case Aeson.eitherDecodeStrict bytes of
    Left why -> Left ("the blueprint does not parse: " <> why)
    Right (Aeson.Object o) -> case KeyMap.lookup "preamble" o of
        Just (Aeson.Object p) -> case KeyMap.lookup "title" p of
            Just (Aeson.String t) -> Right t
            _ -> Left "the blueprint carries no preamble title"
        _ -> Left "the blueprint carries no preamble title"
    Right _ -> Left "the blueprint does not parse: not an object"

-- | A transaction identifier as hex.
txHex :: TxId -> Text
txHex (TxId h) = hexT (hashToBytes (extractHash h))

{- | The registry page from the chain alone. Refusals throw the usual
command failure: the version before any provider read, then the
release, the registry selection and the public replay.
-}
runDescribe :: Application -> Env -> DescribeArgs -> IO Page
runDescribe app env a = do
    version <-
        readVersionLabel (describeBlueprint a)
            >>= either (failWith ClientRefusal . T.unpack . renderPageRefusal) pure
    release <-
        loadReleaseFor
            env
            app
            (describeBlueprint a)
            (accessToken (describeAccess a))
    blueprintBytes <- do
        content <-
            try (BS.readFile (describeBlueprint a))
                :: IO (Either IOException BS.ByteString)
        either
            (failWith ClientRefusal . ("the blueprint cannot be read: " <>) . show)
            pure
            content
    title <-
        either (failWith ClientRefusal) pure (blueprintTitle blueprintBytes)
    root <- resolveStateRoot Nothing
    let settings = describeProvider a
        requested = accessToken (describeAccess a)
        magic = providerMagic settings
        stateless = statelessDir root magic requested
    readOnce env settings ["state", "requests"] $ \_caps v -> do
        saved <-
            resolveSaved
                app
                stateless
                release
                (describeAccess a)
                Set.empty
                Nothing
                v
        live <- attachLive v saved
        state <- case extractCageDatum (snd (liveState live)) of
            Just (StateDatum found) -> pure found
            _ ->
                failWith Partial "the registry's state output carries no state datum"
        selected <- requireTrieSelection saved live
        (lineage, actives, terminals) <- withTrie selected $ \snap -> do
            lin <-
                maybe
                    (failWith StaleState "the replay reported no lineage")
                    pure
                    (TS.trieLineage snap)
            leaves <- mapM (readLeaf snap) (TS.lineageKeys lin)
            pure
                ( lin
                , length [() | Active <- leaves]
                , length [() | Terminal <- leaves]
                )
        requests <-
            Cage.outputsAt
                v
                (requestAddrFromCfg (savedCfg saved) (savedToken saved) Testnet)
        let cfg = savedCfg saved
            -- This registry's requests, as inspect lists them; the page
            -- renders them in one fixed order.
            pending = map pendingJson (findRequestUtxos (savedToken saved) requests)
        pure $
            describeRegistry
                PageInputs
                    { pageStateToken = renderStateToken requested
                    , pageAddress = renderRegistryAddress magic requested
                    , pageFingerprint = registryFingerprint requested
                    , pageStateOutput = txInText (fst (liveState live))
                    , pageStateScript = hexT (scriptHashBytes (cfgScriptHash cfg))
                    , pageApplicationScript =
                        hexT (SBS.fromShort (cfgApplicationPolicy cfg))
                    , pageActiveScript = hexT (SBS.fromShort (cfgActivePolicy cfg))
                    , pageAbsentScript = hexT (SBS.fromShort (cfgAbsentPolicy cfg))
                    , pageTerminalScript = hexT (SBS.fromShort (cfgTerminalPolicy cfg))
                    , pageRelease =
                        ReleaseInfo
                            { releaseVersion = version
                            , releaseBlueprintTitle = title
                            , releaseBlueprintSha = blueprintSha blueprintBytes
                            , releaseApplicationHash =
                                hexT (SBS.fromShort (cfgApplicationPolicy cfg))
                            }
                    , pageProcessTime = stateProcessTime state
                    , pageRetractTime = stateRetractTime state
                    , pageTip = stateMaxFee state
                    , pageMaxKeyBytes = maxKeyBytes
                    , pageRoot = hexT (unOnChainRoot (stateRoot state))
                    , pageActiveKeys = actives
                    , pageTerminalKeys = terminals
                    , pageFoldsSinceCreate = length (TS.lineageFolds lineage)
                    , pageCreateTransaction = txHex (TS.lineageCreate lineage)
                    , pageLastFold = txHex <$> lastMay (TS.lineageFolds lineage)
                    , pagePendingRequests = pending
                    }

-- | One named key's leaf from the replayed trie, refusing what has no proof.
readLeaf :: TS.TrieSnapshot IO -> ByteString -> IO Leaf
readLeaf snap key = TS.leafAt snap key >>= either failTrie pure

-- | The last element, or nothing when there is none.
lastMay :: [a] -> Maybe a
lastMay [] = Nothing
lastMay xs = Just (last xs)

{- | Run describe as the entry point does: the trace events around the
run, the page alone on standard output, and the usual receipt and exit
status on refusal. The failure branch mirrors @Singular.CLI.Finish@,
which this command cannot reuse: a success prints the page, not a
receipt, and the finish module is held by another lane.
-}
runDescribeCommand
    :: Application -> Env -> DescribeArgs -> IO ExitCode
runDescribeCommand app env a = do
    let tracer = envTracer env
    traceWith tracer (Trace [] (What (CommandStarted "describe")))
    elapsed <- startTimer
    result <- tryJust refusalFailure (runDescribe app env a)
    ms <- elapsed
    case result of
        Right page -> do
            traceWith
                tracer
                (Trace [] (What (CommandEnded "describe" (outcomeName Success) ms)))
            printPage page
            pure ExitSuccess
        Left e -> case reportedOf e of
            (marked, failure) -> case fromException failure of
                Just (CommandFailure c why fields) ->
                    finishRefusal tracer marked ms c why fields
                Nothing ->
                    finishRefusal
                        tracer
                        marked
                        ms
                        ClientRefusal
                        (show failure)
                        []

-- | One refusal receipt on standard output with its outcome exit status.
finishRefusal
    :: Tracer IO Trace
    -> Bool
    -> Double
    -> OutcomeClass
    -> String
    -> [(Text, Value)]
    -> IO ExitCode
finishRefusal tracer marked ms outcome why fields = do
    let value =
            receipt "describe" outcome (("reason", toJSON (T.pack why)) : fields)
    unless marked $
        forM_ (refusalOf outcome) $ \kind ->
            traceWith tracer (Trace [] (What (Refused kind Nothing)))
    traceWith
        tracer
        (Trace [] (What (CommandEnded "describe" (outcomeName outcome) ms)))
    BLC.putStrLn (encodePretty value)
    pure (exitCodeOf outcome)

-- | Print the page alone, as indented JSON. No file is written.
printPage :: Page -> IO ()
printPage = BLC.putStrLn . encodePretty . renderPageJson

-- | Asynchronous cancellation and infrastructure waits propagate, as in finish.
refusalFailure :: SomeException -> Maybe SomeException
refusalFailure failure
    | Just (_ :: SomeAsyncException) <- fromException failure = Nothing
    | Just (_ :: WaitFailure) <- fromException failure = Nothing
    | otherwise = pure failure

-- | The refusal an outcome class stands for, as in finish.
refusalOf :: OutcomeClass -> Maybe RefusalKind
refusalOf = \case
    ClientRefusal -> Just ClientRefused
    LedgerRefusal -> Just LedgerRejected
    _ -> Nothing
