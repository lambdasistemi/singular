{-# LANGUAGE RankNTypes #-}

{- |
Module      : Singular.CLI.Failure
Description : How a command stops, and what it runs with
License     : Apache-2.0

The part of a write session every command module reads without the
session itself: why a command stopped, in its outcome class, with the
mark that its refusal was already reported, and the environment the
entry point composes (where it traces, and how it opens the provider for
reads and for writes). It reads no chain and holds no state, so the
session, the submit core and the reconciliation can all stand on it.
-}
module Singular.CLI.Failure
    ( CommandFailure (..)
    , Reported (..)
    , reportedOf
    , markedLike
    , failWith
    , failWithFields
    , Env (..)
    ) where

import Control.Exception
    ( Exception (..)
    , SomeException (..)
    , throwIO
    )
import Control.Tracer (Tracer)
import Data.Aeson (Value)
import Data.Text (Text)
import Data.Typeable (cast)

import Singular.CLI.Receipt (OutcomeClass)
import Singular.CLI.Registry (Release)
import Singular.CLI.Trace (Trace)
import Singular.Registry.Application (Application)
import Singular.Registry.Evidence qualified as Cage
import Singular.Registry.ProviderSettings (ProviderSettings)
import Singular.Registry.Terminal (Capabilities)

{- | Why a command stopped, in its outcome class, with any receipt fields
that name what it left behind.
-}
data CommandFailure = CommandFailure OutcomeClass String [(Text, Value)]
    deriving stock (Show)

-- | A failure is seen through the mark that its refusal was reported ('Reported').
instance Exception CommandFailure where
    fromException (SomeException inner) = case cast inner of
        Just failure -> Just failure
        Nothing -> case cast inner of
            Just (Reported failure) -> fromException failure
            Nothing -> Nothing

{- | A failure whose refusal was already reported where it happened, in the
scopes it happened in: a build that failed, a submission refused or
unanswered. The entry point ('Singular.CLI.Finish') reports a refusal for
any other refusal outcome, so a command's stream carries exactly one. The
failure inside is unchanged, and seen through the mark as itself.
-}
newtype Reported = Reported SomeException

instance Show Reported where
    showsPrec p (Reported e) = showsPrec p e

instance Exception Reported

-- | Whether a failure's refusal was reported, and the failure itself.
reportedOf :: SomeException -> (Bool, SomeException)
reportedOf e = case fromException e of
    Just (Reported inner) -> (True, inner)
    Nothing -> (False, e)

-- | The failure, marked as reported when the original was.
markedLike :: Bool -> SomeException -> SomeException
markedLike reported e
    | reported = toException (Reported e)
    | otherwise = e

failWith :: OutcomeClass -> String -> IO a
failWith c why = throwIO (CommandFailure c why [])

-- | Stop, naming in the receipt what the command left behind.
failWithFields :: OutcomeClass -> String -> [(Text, Value)] -> IO a
failWithFields c why fields = throwIO (CommandFailure c why fields)

{- | What a command runs with, composed by the entry point: where it traces, and
how it opens the provider its caller named, for reads and for writes. The
packaged command opens Koios ('koiosEnv'); a test opens its own.
-}
data Env = Env
    { envTracer :: Tracer IO Trace
    , envSource :: Text
    -- ^ The name the provider's reads report as
    , envLoadRelease
        :: Application -> FilePath -> IO (Either String Release)
    -- ^ Recognition is fixed by the shipping composition; tests supply code fixtures.
    , envReads
        :: forall a
         . ProviderSettings
        -> (Capabilities Cage.NoWitness IO -> IO a)
        -> IO a
    , envWrites
        :: forall a
         . ProviderSettings
        -> (Capabilities Cage.NoWitness IO -> IO a)
        -> IO a
    }
