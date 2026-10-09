{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- |
Module      : Negative.Run
Description : The host's entry handlers over the shared session
License     : Apache-2.0

For this slice the holding-spend shapes (controller update,
stranger update, tampered update, release outside a fold) and the
termination booking run end to end; every other host command stops at
a clear client refusal naming its slice. Every ordinary spelling is
handed to the shared command unchanged.
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
import Data.Text (Text)
import Data.Text qualified as T

import PlutusCore.Data qualified as PLC

import Singular.Application.OpenDatum.Envelope (dataFromJson)
import Singular.CLI.Attached (Attached (..), attached, savedOf)
import Singular.CLI.Command
    ( Command (..)
    , EntryArgs (..)
    , EntryMode (..)
    , FoldArgs (..)
    , Key (..)
    , ProviderSettings (..)
    , RegistryAccess (..)
    , WriteSettings (..)
    , neededRoles
    )
import Singular.CLI.Live
    ( attachLive
    , liveOutputFor
    , liveOutputs
    , receipt
    )
import Singular.CLI.ManagedState (resolveWalletDir)
import Singular.CLI.Plan (readJson)
import Singular.CLI.Receipt (OutcomeClass (..))
import Singular.CLI.Registry (hexT)
import Singular.CLI.Session
    ( CommandFailure (..)
    , Env
    , Expectation (..)
    , WriteContext (..)
    , failWith
    , submitBuiltIn
    , txIdHex
    )

import Negative.Craft
    ( BookingShape (..)
    , HoldingSpend (..)
    , craftBooking
    , craftHoldingSpend
    )
import Negative.Parse (TamperField (..))
import Negative.Read (Around (..), readAround)
import Negative.Submit
    ( FailedScript (..)
    , NodeAnswer (..)
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
    resolveWalletDir
        (entryStateDir args)
        (providerMagic (writeProvider ws))
        (accessToken (entryAccess args))
        (writeWalletKey ws)

{- | Book an insertion through the library builder and submit
unevaluated. Insert bookings and their pairs arrive in the third slice.
-}
runNegativeInsert :: Env -> EntryArgs -> IO Value
runNegativeInsert _ _ =
    failWith
        ClientRefusal
        "not in this slice: insert bookings arrive in the third slice"

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
        attached
            env
            dir
            (entryBlueprint args)
            (entryAccess args)
            (neededRoles (Update args))
            ws
            "update"
            $ \at -> do
                let s = savedOf at
                    wc = atWrite at
                    wallet = wcWallet wc
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
                                outs <- liveOutputs v s
                                (holding, envelope) <-
                                    either
                                        (failWith ClientRefusal)
                                        pure
                                        (liveOutputFor s key outs)
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
                                , ("update", toJSON (txIdHex signed))
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
        attached
            env
            dir
            (entryBlueprint args)
            (entryAccess args)
            (neededRoles (Terminate args))
            ws
            "terminate"
            $ \at -> do
                let s = savedOf at
                    wc = atWrite at
                    wallet = wcWallet wc
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
                                , ("booking", toJSON (txIdHex signed))
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
        attached
            env
            dir
            (entryBlueprint args)
            (entryAccess args)
            (neededRoles (Terminate args))
            ws
            "withdraw"
            $ \at -> do
                let s = savedOf at
                    wc = atWrite at
                    wallet = wcWallet wc
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
                                outs <- liveOutputs v s
                                (holding, envelope) <-
                                    either
                                        (failWith ClientRefusal)
                                        pure
                                        (liveOutputFor s key outs)
                                unsigned <-
                                    craftHoldingSpend
                                        v
                                        live
                                        holding
                                        envelope
                                        wallet
                                        wallet
                                        SpendRelease
                                pure (unsigned, envelope)
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
                                , ("withdraw", toJSON (txIdHex signed))
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

{- | Fold the pending requests, paying short when asked. Not in this
slice.
-}
runNegativeFold :: Env -> FoldArgs -> Maybe Integer -> IO Value
runNegativeFold _ _ _ =
    failWith
        ClientRefusal
        "not in this slice: folds arrive in the third slice"

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
        ]
