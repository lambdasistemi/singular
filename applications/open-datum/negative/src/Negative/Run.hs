{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- |
Module      : Negative.Run
Description : The host's entry handlers over the shared session
License     : Apache-2.0

For this slice the holding-spend shapes (controller update,
stranger update, tampered update, release outside a fold), the insertion
and termination bookings and the unevaluated fold run end to end.
Every ordinary spelling is handed to the shared command unchanged.
-}
module Negative.Run
    ( -- * Entry handlers
      runNegativeInsert
    , runNegativeUpdate
    , runNegativeTerminate
    , runNegativeWithdraw
    , runNegativeFold
    ) where

import Control.Exception (SomeException, fromException, try)
import Control.Monad (when)
import Data.Aeson (Value, toJSON, (.=))
import Data.Aeson qualified as Aeson
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T

import PlutusCore.Data qualified as PLC

import Singular.Application.OpenDatum.Build (minimumDeposit)
import Singular.Application.OpenDatum.Command
    ( EntryArgs (..)
    , EntryMode (..)
    , FoldArgs (..)
    , Key (..)
    , OpenDatumCommand (..)
    , ProviderSettings (..)
    , RegistryAccess (..)
    , WriteSettings (..)
    , neededRoles
    )
import Singular.Application.OpenDatum.Envelope
    ( dataFromJson
    , envelopeFromData
    )
import Singular.Application.OpenDatum.Run
    ( readModeFor
    , readModeForFold
    )
import Singular.Application.OpenDatum.Value
    ( applicationIn
    , openDatumApplication
    )
import Singular.CLI.Attached
    ( Attached (..)
    , attached
    , reading
    , savedOf
    )
import Singular.CLI.Live
    ( attachLive
    , liveOutputFor
    , liveOutputs
    , receipt
    , txInText
    )
import Singular.CLI.ManagedState (resolveSignerDir)
import Singular.CLI.Plan (readJson)
import Singular.CLI.Receipt (OutcomeClass (..))
import Singular.CLI.Registry (hexT)
import Singular.CLI.Session
    ( CommandFailure (..)
    , Env
    , Expectation (..)
    , confirmedTx
    , failWith
    , signingWallet
    , submitBuiltIn
    , txIdHex
    )
import Singular.Registry.Application (DecodedHolding (..))
import Singular.Registry.TxBuilder.Internal (bookedKey)

import Negative.Craft
    ( BookingShape (..)
    , FoldPayment (..)
    , FoldSelection (..)
    , HoldingSpend (..)
    , craftBooking
    , craftFold
    , craftHoldingSpend
    , selectFoldRequests
    )
import Negative.Parse (TamperField (..))
import Negative.Read (Around (..), readAround)
import Negative.Submit
    ( FailedScript (..)
    , NodeAnswer (..)
    , TxKind (..)
    , applicationHashOf
    , failedScripts
    , scriptRoleName
    , stateHashOf
    )

{- | Resolve the host's state directory exactly as the shared entry
runners do: the override as it comes (including 'Nothing') goes to
the shared function, which alone decides the default.
-}
negativeStateDir :: EntryArgs -> WriteSettings -> IO FilePath
negativeStateDir args ws =
    resolveSignerDir
        (entryStateDir args)
        (providerMagic (writeProvider ws))
        (accessToken (entryAccess args))
        (writeSigner ws)

{- | Book an insertion for any signer, unevaluated, then fold it. The payer wallet
funds it and is named its owner, with no controller check here: the
controller's own command is the honest booking and a stranger's the
forbidden one; the node tells them apart. A taken or terminated key
still books (a request is only a request); the registry state validator
refuses later, at the fold. The same command then folds that one request
with the host's approved fold, whatever the command line says (issue 486
removes the combined `--fold` switch from the ordinary insert, so no part
relies on it), and the command's verdict is the fold's.
-}
runNegativeInsert :: Env -> EntryArgs -> IO Value
runNegativeInsert env args = case entryMode args of
    Preview _ _ ->
        failWith ClientRefusal "preview takes no key: the host submits"
    Submit ws -> do
        let Key key = entryKey args
        payloadPath <-
            maybe
                (failWith ClientRefusal "insert needs --payload")
                pure
                (entryDocument args)
        payloadValue <- readJson payloadPath
        payload <-
            either
                (failWith ClientRefusal)
                pure
                (dataFromJson payloadValue)
        let deposit = fromMaybe minimumDeposit (entryDeposit args)
        dir <- negativeStateDir args ws
        (mode, modeEnv) <- readModeFor env args
        -- The fold needs every reference role, whatever the command line
        -- says: build the roles host-privately with the fold bit set, so
        -- the command line never carries `--fold` (issue 486 removes it
        -- from the ordinary insert). The coupling (always folding, always
        -- requesting the fold roles) is stated in the ticket's decisions
        -- record as enforced: NONE.
        attached
            (applicationIn mode)
            modeEnv
            dir
            (entryBlueprint args)
            (entryAccess args)
            (neededRoles (OpenInsert (args{entryFold = True})))
            ws
            "insert"
            $ \at -> do
                let s = savedOf at
                    wc = atWrite at
                wallet <- signingWallet wc
                beforeBooking <- readAround at key wallet
                resultBooking <-
                    try
                        ( submitBuiltIn
                            wc
                            "book"
                            ["state", "key outputs"]
                            ( const
                                ( Expectation
                                    (Just key)
                                    "request"
                                    Nothing
                                    Nothing
                                    Nothing
                                )
                            )
                            ( \_building v -> do
                                live <- attachLive v s
                                unsigned <-
                                    craftBooking
                                        v
                                        live
                                        wallet
                                        key
                                        (BookingInsert payload deposit)
                                pure (unsigned, ())
                            )
                        )
                case resultBooking of
                    Left (e :: SomeException) ->
                        case fromException e :: Maybe CommandFailure of
                            Just (CommandFailure LedgerRefusal why _) -> do
                                afterBooking <- readAround at key wallet
                                let registry = atLive at
                                    failed =
                                        failedScripts
                                            registry
                                            TxOther
                                            (AnswerRefused (T.pack why))
                                pure
                                    ( receipt
                                        "insert"
                                        LedgerRefusal
                                        [ ("key", toJSON (hexT key))
                                        , ("reason", toJSON (T.pack why))
                                        ,
                                            ( "failedScripts"
                                            , toJSON
                                                [ Aeson.object
                                                    [ "hash" .= failedHash f
                                                    , "role" .= scriptRoleName (failedRole f)
                                                    ]
                                                | f <- failed
                                                ]
                                            )
                                        , ("before", aroundJson beforeBooking)
                                        , ("after", aroundJson afterBooking)
                                        , ("applicationHash", toJSON (applicationHashOf registry))
                                        , ("stateHash", toJSON (stateHashOf registry))
                                        ]
                                    )
                            _ ->
                                failWith
                                    ClientRefusal
                                    ("insert failed: " <> show e)
                    Right (signedBooking, _) -> do
                        mid <- readAround at key wallet
                        foldPairs <-
                            reading at (\v -> selectFoldRequests v (atLive at) (FoldKey key))
                        resultFold <-
                            try
                                ( submitBuiltIn
                                    wc
                                    "fold"
                                    ["state", "key outputs"]
                                    ( const
                                        ( Expectation
                                            (Just key)
                                            "fold"
                                            Nothing
                                            Nothing
                                            Nothing
                                        )
                                    )
                                    ( \_building v -> do
                                        live <- attachLive v s
                                        (unsigned, chosen) <-
                                            craftFold v live wallet (FoldKey key) PayAsOwed
                                        pure (unsigned, chosen)
                                    )
                                )
                        case resultFold of
                            Right (signedFold, chosen) -> do
                                afterFold <- readAround at key wallet
                                let registry = atLive at
                                pure
                                    ( receipt
                                        "insert"
                                        Success
                                        [ ("key", toJSON (hexT key))
                                        , ("booking", toJSON (txIdHex (confirmedTx signedBooking)))
                                        , ("fold", toJSON (txIdHex (confirmedTx signedFold)))
                                        , ("requests", toJSON [txInText tin | (tin, _) <- chosen])
                                        , ("keys", toJSON [hexT k | (_, k) <- chosen])
                                        , ("before", aroundJson mid)
                                        , ("after", aroundJson afterFold)
                                        , ("applicationHash", toJSON (applicationHashOf registry))
                                        , ("stateHash", toJSON (stateHashOf registry))
                                        ]
                                    )
                            Left (eFold :: SomeException) ->
                                case fromException eFold :: Maybe CommandFailure of
                                    Just (CommandFailure LedgerRefusal whyFold _) -> do
                                        afterFold <- readAround at key wallet
                                        let registry = atLive at
                                            failed =
                                                failedScripts
                                                    registry
                                                    TxFold
                                                    (AnswerRefused (T.pack whyFold))
                                        pure
                                            ( receipt
                                                "insert"
                                                LedgerRefusal
                                                [ ("key", toJSON (hexT key))
                                                , ("booking", toJSON (txIdHex (confirmedTx signedBooking)))
                                                , ("fold", toJSON ("none" :: Text))
                                                , ("requests", toJSON [txInText tin | ((tin, _), _) <- foldPairs])
                                                , ("keys", toJSON [hexT (bookedKey q) | (_, q) <- foldPairs])
                                                , ("reason", toJSON (T.pack whyFold))
                                                ,
                                                    ( "failedScripts"
                                                    , toJSON
                                                        [ Aeson.object
                                                            [ "hash" .= failedHash f
                                                            , "role" .= scriptRoleName (failedRole f)
                                                            ]
                                                        | f <- failed
                                                        ]
                                                    )
                                                , ("before", aroundJson mid)
                                                , ("after", aroundJson afterFold)
                                                , ("applicationHash", toJSON (applicationHashOf registry))
                                                , ("stateHash", toJSON (stateHashOf registry))
                                                ]
                                            )
                                    _ ->
                                        failWith
                                            ClientRefusal
                                            ("insert fold failed: " <> show eFold)

{- | Build the update for any signer, unevaluated. The honest, stranger
and tampered shapes run in this slice.
-}
runNegativeUpdate :: Env -> EntryArgs -> Maybe TamperField -> IO Value
runNegativeUpdate env args tamper = case entryMode args of
    Preview _ _ ->
        failWith ClientRefusal "preview takes no key: the host submits"
    Submit ws -> do
        let Key key = entryKey args
        payloadPath <-
            maybe
                (failWith ClientRefusal "update needs --payload")
                pure
                (entryDocument args)
        payloadValue <- readJson payloadPath
        payload <-
            either
                (failWith ClientRefusal)
                pure
                (dataFromJson payloadValue)
        dir <- negativeStateDir args ws
        (mode, modeEnv) <- readModeFor env args
        attached
            (applicationIn mode)
            modeEnv
            dir
            (entryBlueprint args)
            (entryAccess args)
            (neededRoles (OpenUpdate args))
            ws
            "update"
            $ \at -> do
                let s = savedOf at
                    wc = atWrite at
                wallet <- signingWallet wc
                before <- readAround at key wallet
                result <-
                    try
                        ( submitBuiltIn
                            wc
                            "update"
                            ["state", "key outputs"]
                            ( const
                                ( Expectation
                                    (Just key)
                                    "update"
                                    Nothing
                                    Nothing
                                    Nothing
                                )
                            )
                            ( \_building v -> do
                                live <- attachLive v s
                                outs <- liveOutputs openDatumApplication v s
                                (holding, dh) <-
                                    either
                                        (failWith ClientRefusal)
                                        pure
                                        (liveOutputFor openDatumApplication s key outs)
                                envelope <-
                                    either
                                        (failWith ClientRefusal)
                                        pure
                                        (envelopeFromData (dhDatumData dh))
                                spend <- spendOf tamper payload
                                unsigned <-
                                    craftHoldingSpend
                                        v
                                        live
                                        holding
                                        envelope
                                        wallet
                                        wallet
                                        spend
                                pure (unsigned, envelope)
                            )
                        )
                case result of
                    Right (signed, _) -> do
                        after <- readAround at key wallet
                        let registry = atLive at
                        pure
                            ( receipt
                                "update"
                                Success
                                [ ("key", toJSON (hexT key))
                                , ("update", toJSON (txIdHex (confirmedTx signed)))
                                , ("before", aroundJson before)
                                , ("after", aroundJson after)
                                , ("tamper", toJSON (tamperName tamper))
                                , ("applicationHash", toJSON (applicationHashOf registry))
                                , ("stateHash", toJSON (stateHashOf registry))
                                ]
                            )
                    Left (e :: SomeException) ->
                        case fromException e :: Maybe CommandFailure of
                            Just (CommandFailure LedgerRefusal why _) -> do
                                after <- readAround at key wallet
                                let registry = atLive at
                                    failed =
                                        failedScripts
                                            registry
                                            TxOther
                                            (AnswerRefused (T.pack why))
                                pure
                                    ( receipt
                                        "update"
                                        LedgerRefusal
                                        [ ("key", toJSON (hexT key))
                                        , ("reason", toJSON (T.pack why))
                                        ,
                                            ( "failedScripts"
                                            , toJSON
                                                [ Aeson.object
                                                    [ "hash" .= failedHash f
                                                    , "role" .= scriptRoleName (failedRole f)
                                                    ]
                                                | f <- failed
                                                ]
                                            )
                                        , ("before", aroundJson before)
                                        , ("after", aroundJson after)
                                        , ("tamper", toJSON (tamperName tamper))
                                        , ("applicationHash", toJSON (applicationHashOf registry))
                                        , ("stateHash", toJSON (stateHashOf registry))
                                        ]
                                    )
                            _ ->
                                failWith
                                    ClientRefusal
                                    ("update failed: " <> show e)

{- | Book a termination for any signer, unevaluated. The controller's own
booking is the accepting control; a stranger's is refused by the
application at the booking. No controller check here: the booking names
the signing wallet payer and owner, and the node judges it. With @--fold@
the fold would follow; folds arrive in the third slice.
-}
runNegativeTerminate :: Env -> EntryArgs -> IO Value
runNegativeTerminate env args = case entryMode args of
    Preview _ _ ->
        failWith ClientRefusal "preview takes no key: the host submits"
    Submit ws -> do
        let Key key = entryKey args
        when (entryFold args) $
            failWith
                ClientRefusal
                "not in this slice: folds arrive in the third slice"
        dir <- negativeStateDir args ws
        (mode, modeEnv) <- readModeFor env args
        attached
            (applicationIn mode)
            modeEnv
            dir
            (entryBlueprint args)
            (entryAccess args)
            (neededRoles (OpenTerminate args))
            ws
            "terminate"
            $ \at -> do
                let s = savedOf at
                    wc = atWrite at
                wallet <- signingWallet wc
                before <- readAround at key wallet
                result <-
                    try
                        ( submitBuiltIn
                            wc
                            "book"
                            ["state", "key outputs"]
                            ( const
                                ( Expectation
                                    (Just key)
                                    "request"
                                    Nothing
                                    Nothing
                                    Nothing
                                )
                            )
                            ( \_building v -> do
                                live <- attachLive v s
                                unsigned <-
                                    craftBooking
                                        v
                                        live
                                        wallet
                                        key
                                        BookingTerminate
                                pure (unsigned, ())
                            )
                        )
                case result of
                    Right (signed, _) -> do
                        after <- readAround at key wallet
                        let registry = atLive at
                        pure
                            ( receipt
                                "terminate"
                                Success
                                [ ("key", toJSON (hexT key))
                                , ("booking", toJSON (txIdHex (confirmedTx signed)))
                                , ("before", aroundJson before)
                                , ("after", aroundJson after)
                                , ("applicationHash", toJSON (applicationHashOf registry))
                                , ("stateHash", toJSON (stateHashOf registry))
                                ]
                            )
                    Left (e :: SomeException) ->
                        case fromException e :: Maybe CommandFailure of
                            Just (CommandFailure LedgerRefusal why _) -> do
                                after <- readAround at key wallet
                                let registry = atLive at
                                    failed =
                                        failedScripts
                                            registry
                                            TxOther
                                            (AnswerRefused (T.pack why))
                                pure
                                    ( receipt
                                        "terminate"
                                        LedgerRefusal
                                        [ ("key", toJSON (hexT key))
                                        , ("reason", toJSON (T.pack why))
                                        ,
                                            ( "failedScripts"
                                            , toJSON
                                                [ Aeson.object
                                                    [ "hash" .= failedHash f
                                                    , "role" .= scriptRoleName (failedRole f)
                                                    ]
                                                | f <- failed
                                                ]
                                            )
                                        , ("before", aroundJson before)
                                        , ("after", aroundJson after)
                                        , ("applicationHash", toJSON (applicationHashOf registry))
                                        , ("stateHash", toJSON (stateHashOf registry))
                                        ]
                                    )
                            _ ->
                                failWith
                                    ClientRefusal
                                    ("terminate failed: " <> show e)

-- | Build the release outside any fold. Runs in this slice.
runNegativeWithdraw :: Env -> EntryArgs -> IO Value
runNegativeWithdraw env args = case entryMode args of
    Preview _ _ ->
        failWith ClientRefusal "preview takes no key: the host submits"
    Submit ws -> do
        let Key key = entryKey args
        dir <- negativeStateDir args ws
        (mode, modeEnv) <- readModeFor env args
        attached
            (applicationIn mode)
            modeEnv
            dir
            (entryBlueprint args)
            (entryAccess args)
            (neededRoles (OpenTerminate args))
            ws
            "withdraw"
            $ \at -> do
                let s = savedOf at
                    wc = atWrite at
                wallet <- signingWallet wc
                before <- readAround at key wallet
                result <-
                    try
                        ( submitBuiltIn
                            wc
                            "withdraw"
                            ["state", "key outputs"]
                            ( const
                                ( Expectation
                                    (Just key)
                                    "withdraw"
                                    Nothing
                                    Nothing
                                    Nothing
                                )
                            )
                            ( \_building v -> do
                                live <- attachLive v s
                                outs <- liveOutputs openDatumApplication v s
                                (holding, dhWithdraw) <-
                                    either
                                        (failWith ClientRefusal)
                                        pure
                                        (liveOutputFor openDatumApplication s key outs)
                                envelopeWithdraw <-
                                    either
                                        (failWith ClientRefusal)
                                        pure
                                        (envelopeFromData (dhDatumData dhWithdraw))
                                unsigned <-
                                    craftHoldingSpend
                                        v
                                        live
                                        holding
                                        envelopeWithdraw
                                        wallet
                                        wallet
                                        SpendRelease
                                pure (unsigned, envelopeWithdraw)
                            )
                        )
                case result of
                    Right (signed, _) -> do
                        after <- readAround at key wallet
                        let registry = atLive at
                        pure
                            ( receipt
                                "withdraw"
                                Success
                                [ ("key", toJSON (hexT key))
                                , ("withdraw", toJSON (txIdHex (confirmedTx signed)))
                                , ("before", aroundJson before)
                                , ("after", aroundJson after)
                                , ("applicationHash", toJSON (applicationHashOf registry))
                                , ("stateHash", toJSON (stateHashOf registry))
                                ]
                            )
                    Left (e :: SomeException) ->
                        case fromException e :: Maybe CommandFailure of
                            Just (CommandFailure LedgerRefusal why _) -> do
                                after <- readAround at key wallet
                                let registry = atLive at
                                    failed =
                                        failedScripts
                                            registry
                                            TxOther
                                            (AnswerRefused (T.pack why))
                                pure
                                    ( receipt
                                        "withdraw"
                                        LedgerRefusal
                                        [ ("key", toJSON (hexT key))
                                        , ("reason", toJSON (T.pack why))
                                        ,
                                            ( "failedScripts"
                                            , toJSON
                                                [ Aeson.object
                                                    [ "hash" .= failedHash f
                                                    , "role" .= scriptRoleName (failedRole f)
                                                    ]
                                                | f <- failed
                                                ]
                                            )
                                        , ("before", aroundJson before)
                                        , ("after", aroundJson after)
                                        , ("applicationHash", toJSON (applicationHashOf registry))
                                        , ("stateHash", toJSON (stateHashOf registry))
                                        ]
                                    )
                            _ ->
                                failWith
                                    ClientRefusal
                                    ("withdraw failed: " <> show e)

{- | Fold every pending request, paying short when asked. Permissionless:
signed and funded by the named wallet, built unevaluated with stated
budgets so the node judges it, with no local evaluation and no client
check beyond finding its inputs. Receipt shape follows the other host
handlers. Before and after read the first selected key's holding; with
one request pending that is the request's key.
-}
runNegativeFold :: Env -> FoldArgs -> Maybe Integer -> IO Value
runNegativeFold env args short = do
    let ws = foldWrite args
    dir <-
        resolveSignerDir
            (foldStateDir args)
            (providerMagic (writeProvider ws))
            (accessToken (foldAccess args))
            (writeSigner ws)
    (mode, modeEnv) <- readModeForFold env args
    attached
        (applicationIn mode)
        modeEnv
        dir
        (foldBlueprint args)
        (foldAccess args)
        (neededRoles (OpenFold args))
        ws
        "fold"
        $ \at -> do
            wallet <- signingWallet (atWrite at)
            let payment = maybe PayAsOwed PayShort short
            pairs <- reading at (\v -> selectFoldRequests v (atLive at) FoldEvery)
            firstKey <- case pairs of
                ((_, _), q) : _ -> pure (bookedKey q)
                [] ->
                    failWith ClientRefusal "no request is pending for the fold"
            before <- readAround at firstKey wallet
            result <-
                try
                    ( submitBuiltIn
                        (atWrite at)
                        "fold"
                        ["state", "key outputs"]
                        ( const
                            ( Expectation
                                (Just firstKey)
                                "fold"
                                Nothing
                                Nothing
                                Nothing
                            )
                        )
                        ( \_building v -> do
                            live <- attachLive v (savedOf at)
                            (unsigned, chosen) <- craftFold v live wallet FoldEvery payment
                            pure (unsigned, chosen)
                        )
                    )
            case result of
                Right (signed, chosen) -> do
                    after <- readAround at firstKey wallet
                    let registry = atLive at
                    pure
                        ( receipt
                            "fold"
                            Success
                            [ ("fold", toJSON (txIdHex (confirmedTx signed)))
                            , ("requests", toJSON [txInText tin | (tin, _) <- chosen])
                            , ("keys", toJSON [hexT k | (_, k) <- chosen])
                            , ("before", aroundJson before)
                            , ("after", aroundJson after)
                            , ("payShort", toJSON short)
                            , ("applicationHash", toJSON (applicationHashOf registry))
                            , ("stateHash", toJSON (stateHashOf registry))
                            ]
                        )
                Left (e :: SomeException) ->
                    case fromException e :: Maybe CommandFailure of
                        Just (CommandFailure LedgerRefusal why _) -> do
                            after <- readAround at firstKey wallet
                            let registry = atLive at
                                failed =
                                    failedScripts
                                        registry
                                        TxFold
                                        (AnswerRefused (T.pack why))
                            pure
                                ( receipt
                                    "fold"
                                    LedgerRefusal
                                    [ ("fold", toJSON ("none" :: Text))
                                    , ("requests", toJSON [txInText tin | ((tin, _), _) <- pairs])
                                    , ("keys", toJSON [hexT (bookedKey q) | (_, q) <- pairs])
                                    , ("reason", toJSON (T.pack why))
                                    ,
                                        ( "failedScripts"
                                        , toJSON
                                            [ Aeson.object
                                                [ "hash" .= failedHash f
                                                , "role" .= scriptRoleName (failedRole f)
                                                ]
                                            | f <- failed
                                            ]
                                        )
                                    , ("before", aroundJson before)
                                    , ("after", aroundJson after)
                                    , ("payShort", toJSON short)
                                    , ("applicationHash", toJSON (applicationHashOf registry))
                                    , ("stateHash", toJSON (stateHashOf registry))
                                    ]
                                )
                        _ ->
                            failWith
                                ClientRefusal
                                ("fold failed: " <> show e)

{- | What one update spends: tampered when asked, otherwise the same
continuation for any signer. The node tells the controller from the
stranger; the host does not check.
-}
spendOf :: Maybe TamperField -> PLC.Data -> IO HoldingSpend
spendOf tamper payload = case tamper of
    Just field -> pure (SpendTamperedUpdate field payload)
    Nothing -> pure (SpendStrangerUpdate payload)

-- | The tamper this update ran, if any, as receipt text.
tamperName :: Maybe TamperField -> Text
tamperName = \case
    Nothing -> "none"
    Just TamperController -> "controller"
    Just TamperDeposit -> "deposit"
    Just TamperToken -> "token"
    Just TamperAddress -> "address"
    Just TamperDatum -> "datum"

-- | One comparable read as receipt JSON.
aroundJson :: Around -> Value
aroundJson around =
    Aeson.object
        [ ("state", aroundState around)
        , ("holding", aroundHolding around)
        , ("wallet", aroundWallet around)
        , ("pending", aroundPending around)
        , ("deposit", aroundDeposit around)
        ]
