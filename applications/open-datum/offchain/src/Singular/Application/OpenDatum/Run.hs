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
every later command first resolves its registry through the library's
gate over the open and the closed derivation, follows the mode the
datum's application pin selects, and refuses an update on a closed
registry before anything is built or signed. A registry the gate refuses
is never answered about: not even its mode is read from its datum before
its pinned policies have been compared.
-}
module Singular.Application.OpenDatum.Run
    ( runOpenDatum
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
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Text qualified as T
import System.Exit (ExitCode (..))

import Singular.Application.OpenDatum.Command
    ( BookArgs (..)
    , OpenDatumCommand (..)
    , PendingArgs (..)
    , StateCreateArgs (..)
    , StateFoldArgs (..)
    )
import Singular.Application.OpenDatum.Entry
    ( runInsert
    , runTerminate
    , runUpdate
    )
import Singular.Application.OpenDatum.Registration
    ( openDatumHost
    , runBook
    , runCleanup
    , runReclaim
    )
import Singular.Application.OpenDatum.Requests.Records
    ( RequestParameters (..)
    )
import Singular.Application.OpenDatum.Value
    ( Mode (..)
    , applicationIn
    , closedDatumApplication
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
import Singular.CLI.Create (announceCreated, runCreate)
import Singular.CLI.Finish (finish)
import Singular.CLI.Fold (runFold)
import Singular.CLI.Inspect (runInspect)
import Singular.CLI.Receipt (OutcomeClass (..))
import Singular.CLI.Registry (checkRegistryContracts)
import Singular.CLI.Session
    ( Env (..)
    , failWith
    , openWriteSigner
    , readOnce
    )
import Singular.CLI.SettingsFile (keepStateToken)
import Singular.CLI.State (runStateCreate, runStateFold)
import Singular.Registry.Application (Application (..))
import Singular.Registry.Config.Application ()
import Singular.Registry.LedgerProvider (Asset)
import Singular.Registry.ProviderSettings (ProviderSettings (..))
import Singular.Registry.StateToken
    ( IdentityRefusal (..)
    , Release
    , renderIdentityRefusal
    , renderStateToken
    , resolveRegistryAmong
    )
import Singular.Registry.WaitTypes (WaitFailure)

{- | The mode the registry's application pin selects, decided by the gate.
The registry is resolved once against the open derivation and, when the
blueprint carries it, the closed one; the candidate whose application pin
the datum carries is the one every pin is then compared with. A registry
whose pins differ is refused naming the field, as the command's own
refusal. A registry that cannot be judged for another reason (a release
that does not load, a provider that cannot be read, a token the chain does
not know) is left to the command, whose own resolution refuses it in the
same words before anything is built.
-}
gatedMode
    :: Env
    -> ProviderSettings
    -> FilePath
    -> Asset
    -> IO Mode
gatedMode env settings blueprint token =
    loadRelease Open >>= \case
        Nothing -> pure Open
        Just openRelease ->
            -- A registry made by other contracts than the blueprint's is not
            -- read at all here: no chain read is made for it, and the command
            -- refuses it by name.
            checkRegistryContracts openRelease token >>= \case
                Left _ -> pure Open
                Right () -> gate openRelease
  where
    gate openRelease = do
        closedRelease <- loadRelease Closed
        let candidates =
                (applicationIn Open, openRelease)
                    :| [(applicationIn Closed, closed) | Just closed <- [closedRelease]]
        judged <-
            try
                ( readOnce env settings ["state"] $ \_ view ->
                    resolveRegistryAmong candidates token view
                )
        case judged of
            Left (e :: SomeException)
                | Just (_ :: SomeAsyncException) <- fromException e -> throwIO e
                | Just (_ :: WaitFailure) <- fromException e -> throwIO e
                | otherwise -> pure Open
            Right (Right (_, (selected, _)))
                | appPin selected == appPin closedDatumApplication -> pure Closed
                | otherwise -> pure Open
            Right (Left refusal)
                | pinRefusal refusal ->
                    failWith ClientRefusal (T.unpack (renderIdentityRefusal refusal))
                | otherwise -> pure Open
    loadRelease mode =
        try (envLoadRelease env (applicationIn mode) blueprint) >>= \case
            Left (e :: SomeException)
                | Just (_ :: SomeAsyncException) <- fromException e -> throwIO e
                | Just (_ :: WaitFailure) <- fromException e -> throwIO e
                | otherwise -> pure Nothing
            Right (Left _) -> pure Nothing
            Right (Right release) -> pure (Just (release :: Release))
    pinRefusal = \case
        RegistryPinMismatch _ -> True
        RegistryPinMismatchEvery -> True
        _ -> False

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
            ( keepStateToken "open-datum" (createSaveStateTokenTo a) $
                openCreate a
                    >>= runCreate (applicationIn mode) env
                    >>= announceCreated a
            )
    -- A write that names a vault opens it first, before the registry is
    -- resolved: a refused opening is the command's own refusal.
    OpenInsert a0 -> openedFirst env "insert" (entryReceipt a0) (openEntry a0) $ \a ->
        finish (envTracer env) "insert" (entryReceipt a) $ do
            (_, modeEnv) <- readModeFor env a
            runInsert modeEnv a
    OpenUpdate a0 -> openedFirst env "update" (entryReceipt a0) (openEntry a0) $ \a ->
        finish (envTracer env) "update" (entryReceipt a) $ do
            (mode, modeEnv) <- readModeFor env a
            case mode of
                Closed -> failWithUpdateClosed a
                Open -> runUpdate modeEnv a
    OpenTerminate a0 -> openedFirst env "terminate" (entryReceipt a0) (openEntry a0) $ \a ->
        finish (envTracer env) "terminate" (entryReceipt a) $ do
            (_, modeEnv) <- readModeFor env a
            runTerminate modeEnv a
    OpenFold a0 -> openedFirst env "fold" (foldReceipt a0) (openFold a0) $ \a ->
        finish (envTracer env) "fold" (foldReceipt a) $ do
            (mode, modeEnv) <- readModeForFold env a
            runFold (applicationIn mode) modeEnv a
    OpenStateCreate a parameters ->
        finish
            (envTracer env)
            "state create"
            (stateCreateReceipt a)
            ( openWriteSigner (stateCreateWrite a)
                >>= \ws ->
                    runStateCreate env (openDatumHost parameters) a{stateCreateWrite = ws}
            )
    OpenStateFold a ->
        finish
            (envTracer env)
            "state fold"
            (stateFoldReceipt a)
            ( openWriteSigner (stateFoldWrite a)
                >>= \ws ->
                    runStateFold env (openDatumHost noParameters) a{stateFoldWrite = ws}
            )
    OpenRegistrationBook a ->
        finish
            (envTracer env)
            "registration book"
            (bookArgsReceipt a)
            ( openWriteSigner (bookArgsWrite a)
                >>= \ws -> runBook env a{bookArgsWrite = ws}
            )
    OpenRegistrationReclaim a ->
        finish
            (envTracer env)
            "registration reclaim"
            (pendingArgsReceipt a)
            ( openWriteSigner (pendingArgsWrite a)
                >>= \ws -> runReclaim env a{pendingArgsWrite = ws}
            )
    OpenRegistrationCleanup a ->
        finish
            (envTracer env)
            "registration cleanup"
            (pendingArgsReceipt a)
            ( openWriteSigner (pendingArgsWrite a)
                >>= \ws -> runCleanup env a{pendingArgsWrite = ws}
            )
    OpenInspect a ->
        finish (envTracer env) "inspect" (inspectReceipt a) $ do
            (mode, modeEnv) <- readModeForInspect env a
            runInspect (applicationIn mode) modeEnv a
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
readModeFor env a = followed env =<< gatedMode env settings blueprint token
  where
    settings = case entryMode a of
        Submit ws -> writeProvider ws
        Preview prov _ -> prov
    blueprint = entryBlueprint a
    token = accessToken (entryAccess a)

-- | Read the mode for a fold.
readModeForFold :: Env -> FoldArgs -> IO (Mode, Env)
readModeForFold env a = followed env =<< gatedMode env settings blueprint token
  where
    settings = writeProvider (foldWrite a)
    blueprint = foldBlueprint a
    token = accessToken (foldAccess a)

-- | Read the mode for an inspect.
readModeForInspect :: Env -> InspectArgs -> IO (Mode, Env)
readModeForInspect env a = followed env =<< gatedMode env settings blueprint token
  where
    settings = inspectProvider a
    blueprint = inspectBlueprint a
    token = accessToken (inspectAccess a)

-- | A mode with the environment that follows it.
followed :: Env -> Mode -> IO (Mode, Env)
followed env mode = pure (mode, followingMode mode env)

{- | The parameters of a registry's configuration, none of which a fold reads: the
fold creates nothing.
-}
noParameters :: RequestParameters
noParameters =
    RequestParameters
        { rpRegistrationCost = 0
        , rpMinimumTip = 0
        , rpProcessTime = 0
        , rpRetractTime = 0
        , rpBookingWidth = 0
        }
