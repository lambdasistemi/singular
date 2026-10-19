{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- |
Module      : Singular.Application.OpenDatum.Run
Description : Run one parsed @open-datum@ command
License     : Apache-2.0

'runOpenDatum' dispatches the open-datum commands and help. Each
command prints one receipt as JSON on standard output (and to
@--receipt FILE@ when given) and ends with the exit status of its
outcome class ("Singular.CLI.Finish"). Create uses the mode's value;
every later command reads the mode from the chain and follows it, refusing
an update on a closed registry before anything is built or signed.
-}
module Singular.Application.OpenDatum.Run
    ( runOpenDatum
    , ModeRefusal (..)
    , modeOfRecordedPolicy
    , registryMode
    , followingMode
    , closedUpdateRefusal
    , readModeFor
    , readModeForFold
    ) where

import Control.Exception
    ( SomeAsyncException
    , SomeException
    , fromException
    , throwIO
    , try
    )
import Data.ByteString (ByteString)
import Data.ByteString.Short qualified as SBS
import Data.Text (Text)
import Data.Text qualified as T
import System.Exit (ExitCode (..))

import Singular.Application.OpenDatum.Command
    ( OpenDatumCommand (..)
    )
import Singular.Application.OpenDatum.Entry
    ( runInsert
    , runTerminate
    , runUpdate
    )
import Singular.Application.OpenDatum.Value
    ( Mode (..)
    , applicationIn
    , closedDatumApplication
    , modeTitle
    )
import Singular.CLI.Command
    ( CreateArgs (..)
    , EntryArgs (..)
    , EntryMode (..)
    , FoldArgs (..)
    , InspectArgs (..)
    , RegistryAccess (..)
    , WriteSettings (..)
    )
import Singular.CLI.Create (runCreate)
import Singular.CLI.Finish (finish)
import Singular.CLI.Fold (runFold)
import Singular.CLI.Inspect (runInspect)
import Singular.CLI.Receipt (OutcomeClass (..))
import Singular.CLI.Session
    ( Env (..)
    , failWith
    , openWriteSigner
    , readOnce
    )
import Singular.Registry.Application (ApplicationPin (..), applyPin)
import Singular.Registry.Config.Application ()
import Singular.Registry.Ledger (AssetName (..))
import Singular.Registry.LedgerProvider (Asset)
import Singular.Registry.ProviderSettings (ProviderSettings (..))
import Singular.Registry.StateToken
    ( Release (..)
    , findStateOutput
    , renderIdentityRefusal
    , renderStateToken
    )
import Singular.Registry.TxBuilder.Internal
    ( computeScriptHash
    , scriptHashBytes
    )
import Singular.Registry.Types (stateAppPolicyBytes)
import Singular.Registry.WaitTypes (WaitFailure)

-- | Why a mode was not read.
data ModeRefusal
    = ReleaseUnreadable String
    | StateUnreadable String
    | UnrecognisedPolicy ByteString
    deriving stock (Eq, Show)

-- | The mode for a recorded policy: total, never choosing an absent or unequal derivation.
modeOfRecordedPolicy
    :: ByteString
    -> ByteString
    -> Maybe ByteString
    -> Either ModeRefusal Mode
modeOfRecordedPolicy recorded openDerived closedDerived
    | recorded == openDerived = Right Open
    | Just closed <- closedDerived
    , recorded == closed =
        Right Closed
    | otherwise = Left (UnrecognisedPolicy recorded)

-- | Read the registry's mode from the chain through the state token.
registryMode
    :: Env
    -> ProviderSettings
    -> FilePath
    -> Asset
    -> IO (Either ModeRefusal Mode)
registryMode env settings blueprint token = do
    openTried <-
        try (envLoadRelease env (applicationIn Open) blueprint)
            :: IO (Either SomeException (Either String Release))
    openRelease <- case openTried of
        Left (e :: SomeException)
            | Just (_ :: SomeAsyncException) <- fromException e -> throwIO e
            | Just (_ :: WaitFailure) <- fromException e -> throwIO e
            | otherwise -> pure (Left (ReleaseUnreadable (show e)))
        Right (Left err) -> pure (Left (ReleaseUnreadable err))
        Right (Right rel) -> pure (Right rel)
    case openRelease of
        Left refusal -> pure (Left refusal)
        Right openRel -> do
            closedTried <-
                try (envLoadRelease env (applicationIn Closed) blueprint)
                    :: IO (Either SomeException (Either String Release))
            closedRel <- case closedTried of
                Left (e :: SomeException)
                    | Just (_ :: SomeAsyncException) <- fromException e -> throwIO e
                    | Just (_ :: WaitFailure) <- fromException e -> throwIO e
                    | otherwise -> pure Nothing
                Right (Left _) -> pure Nothing
                Right (Right rel) -> pure (Just rel)
            found <-
                try
                    (readOnce env settings ["state"] (\_ v -> findStateOutput token v))
            case found of
                Left (e :: SomeException)
                    | Just (_ :: SomeAsyncException) <- fromException e -> throwIO e
                    | Just (_ :: WaitFailure) <- fromException e -> throwIO e
                    | otherwise -> pure (Left (StateUnreadable (show e)))
                Right stated -> case stated of
                    Left refusal ->
                        pure
                            (Left (StateUnreadable (T.unpack (renderIdentityRefusal refusal))))
                    Right (_, _, datum) -> do
                        let recorded = stateAppPolicyBytes datum
                            (_, AssetName name) = token
                            tokenName = SBS.fromShort name
                            openId =
                                scriptHashBytes (computeScriptHash (releaseState openRel))
                                    <> tokenName
                            (openPolicy, _) =
                                applyPin
                                    (PinByScript (modeTitle Open))
                                    openId
                                    (releaseCodes openRel)
                            closedPolicy = case closedRel of
                                Nothing -> Nothing
                                Just closedR ->
                                    let closedId =
                                            scriptHashBytes (computeScriptHash (releaseState closedR))
                                                <> tokenName
                                        (pol, _) =
                                            applyPin
                                                (PinByScript (modeTitle Closed))
                                                closedId
                                                (releaseCodes closedR)
                                    in  Just (SBS.fromShort pol)
                            openBytes = SBS.fromShort openPolicy
                        pure (modeOfRecordedPolicy recorded openBytes closedPolicy)

-- | The environment that follows a mode: open returns what it was given.
followingMode :: Mode -> Env -> Env
followingMode Open env = env
followingMode Closed env =
    env
        { envLoadRelease = \_app blueprint ->
            envLoadRelease env closedDatumApplication blueprint
        }

-- | The plain message an update on a closed registry stops with.
closedUpdateRefusal :: Asset -> String
closedUpdateRefusal token =
    "the registry "
        <> T.unpack (renderStateToken token)
        <> " is closed: a payload is written once, and an update is refused"

-- | Run one open-datum command in the environment the entry point composed.
runOpenDatum :: Env -> OpenDatumCommand -> IO ExitCode
runOpenDatum env = \case
    OpenHelp text -> putStr text >> pure ExitSuccess
    OpenCreate mode a ->
        finish
            (envTracer env)
            "create"
            (createReceipt a)
            (openCreate a >>= runCreate (applicationIn mode) env)
    -- A write that names a vault opens it first, before the registry's mode is
    -- read from the chain: a refused opening is the command's own refusal.
    OpenInsert a0 -> openedFirst env "insert" (entryReceipt a0) (openEntry a0) $ \a -> do
        (_, modeEnv) <- readModeFor env a
        finish
            (envTracer modeEnv)
            "insert"
            (entryReceipt a)
            (runInsert modeEnv a)
    OpenUpdate a0 -> openedFirst env "update" (entryReceipt a0) (openEntry a0) $ \a -> do
        (mode, modeEnv) <- readModeFor env a
        case mode of
            Closed ->
                finish
                    (envTracer env)
                    "update"
                    (entryReceipt a)
                    (failWithUpdateClosed a)
            Open ->
                finish
                    (envTracer modeEnv)
                    "update"
                    (entryReceipt a)
                    (runUpdate modeEnv a)
    OpenTerminate a0 -> openedFirst env "terminate" (entryReceipt a0) (openEntry a0) $ \a -> do
        (_, modeEnv) <- readModeFor env a
        finish
            (envTracer modeEnv)
            "terminate"
            (entryReceipt a)
            (runTerminate modeEnv a)
    OpenFold a0 -> openedFirst env "fold" (foldReceipt a0) (openFold a0) $ \a -> do
        (mode, modeEnv) <- readModeForFold env a
        finish
            (envTracer modeEnv)
            "fold"
            (foldReceipt a)
            (runFold (applicationIn mode) modeEnv a)
    OpenInspect a -> do
        (mode, modeEnv) <- readModeForInspect env a
        finish
            (envTracer modeEnv)
            "inspect"
            (inspectReceipt a)
            (runInspect (applicationIn mode) modeEnv a)
  where
    failWithUpdateClosed :: EntryArgs -> IO a
    failWithUpdateClosed args =
        failWith
            ClientRefusal
            (closedUpdateRefusal (accessToken (entryAccess args)))

{- | Run the rest of a command over the arguments its vault opened into, or end
it as the command's own refusal receipt when the opening is refused. A
vault is opened once, at dispatch, before the blueprint, the chain or the
state directory is touched; any other signer opens to itself.
-}
openedFirst
    :: Env
    -> Text
    -> Maybe FilePath
    -> IO a
    -> (a -> IO ExitCode)
    -> IO ExitCode
openedFirst env command receipt open rest =
    try open >>= \case
        Right opened -> rest opened
        Left (refused :: SomeException)
            | Just (_ :: SomeAsyncException) <- fromException refused ->
                throwIO refused
            | otherwise ->
                finish (envTracer env) command receipt (throwIO refused)

-- | A create's arguments with the vault its write names opened.
openCreate :: CreateArgs -> IO CreateArgs
openCreate a = case createMode a of
    Submit ws -> (\opened -> a{createMode = Submit opened}) <$> openWriteSigner ws
    Preview{} -> pure a

-- | An entry write's arguments with the vault it names opened.
openEntry :: EntryArgs -> IO EntryArgs
openEntry a = case entryMode a of
    Submit ws -> (\opened -> a{entryMode = Submit opened}) <$> openWriteSigner ws
    Preview{} -> pure a

-- | A fold's arguments with the vault it names opened.
openFold :: FoldArgs -> IO FoldArgs
openFold a =
    (\opened -> a{foldWrite = opened}) <$> openWriteSigner (foldWrite a)

-- | Read the mode for an entry command (insert, update, terminate).
readModeFor :: Env -> EntryArgs -> IO (Mode, Env)
readModeFor env a = do
    let settings = case entryMode a of
            Submit ws -> writeProvider ws
            Preview prov _ -> prov
        blueprint = entryBlueprint a
        token = accessToken (entryAccess a)
    modeOrRefusal <- registryMode env settings blueprint token
    case modeOrRefusal of
        Right mode -> pure (mode, followingMode mode env)
        Left _ -> pure (Open, env)

-- | Read the mode for a fold.
readModeForFold :: Env -> FoldArgs -> IO (Mode, Env)
readModeForFold env a = do
    let settings = writeProvider (foldWrite a)
        blueprint = foldBlueprint a
        token = accessToken (foldAccess a)
    modeOrRefusal <- registryMode env settings blueprint token
    case modeOrRefusal of
        Right mode -> pure (mode, followingMode mode env)
        Left _ -> pure (Open, env)

-- | Read the mode for an inspect.
readModeForInspect :: Env -> InspectArgs -> IO (Mode, Env)
readModeForInspect env a = do
    let settings = inspectProvider a
        blueprint = inspectBlueprint a
        token = accessToken (inspectAccess a)
    modeOrRefusal <- registryMode env settings blueprint token
    case modeOrRefusal of
        Right mode -> pure (mode, followingMode mode env)
        Left _ -> pure (Open, env)
