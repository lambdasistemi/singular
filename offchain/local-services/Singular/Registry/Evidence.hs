{-# LANGUAGE EmptyDataDecls #-}
{-# LANGUAGE RankNTypes #-}

{- |
Module      : Singular.Registry.Evidence
Description : Acquisition identity and abstract evidence policy
License     : Apache-2.0

A session identity records one acquisition; it does not assert a snapshot.
Facts may carry an abstract witness. Demo 1 has no inhabitant of NoWitness or
Endorsement and configures only the honest unverified verdict.
-}
module Singular.Registry.Evidence
    ( SessionId (..)
    , SessionBinding (..)
    , Evidenced (..)
    , NoWitness
    , Endorsement
    , Reason (..)
    , Verdict (..)
    , Verifier (..)
    , unverifiedVerifier
    ) where

import Data.ByteString (ByteString)
import Data.Text (Text)

-- | Identifies one acquisition, including all facts consumed within it.
newtype SessionId = SessionId Text deriving stock (Eq, Ord, Show)

-- | Snapshot binding, independent of the latest observed tip.
data SessionBinding = Unbound | Bound Integer ByteString
    deriving stock (Eq, Show)

-- | A raw fact and its optional abstract witness.
data Evidenced w a = Evidenced
    { value :: a
    , witness :: Maybe w
    }

-- | Demo 1 has no concrete witness representation.
data NoWitness

-- | No endorsement implementation or concrete decoder ships in Demo 1.
data Endorsement

-- | Why a fact remains unverified.
data Reason = NoVerifierConfigured deriving stock (Eq, Show)

-- | A verdict retains the exact fact it describes.
data Verdict a = Verified a Endorsement | Unverified a Reason

-- | An abstract, effect-polymorphic fact verifier.
newtype Verifier w m = Verifier
    { verifyFact :: forall a. Evidenced w a -> m (Verdict a)
    }

-- | The sole configured Demo 1 policy; never upgrades a raw fact.
unverifiedVerifier :: (Applicative m) => Verifier NoWitness m
unverifiedVerifier =
    Verifier
        (\fact -> pure (Unverified (value fact) NoVerifierConfigured))
