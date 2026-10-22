{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.CLI.Reject
Description : @singular registry reject@: retired, refused as an attempt
License     : Apache-2.0

The state script no longer admits a spend of the registry with the
@Rejected@ action: a booked request leaves the registry by the permissionless
fold, and a registration's booker takes it back by retraction, never by a
rejection. The command is kept so that the attempt is refused by name and
before anything is read, signed or submitted: the receipt is a client
refusal, it carries no transaction and the registry is not touched.
-}
module Singular.CLI.Reject
    ( runReject
    , retiredRejectReason
    ) where

import Data.Aeson (Value)

import Singular.CLI.Command (RejectArgs)
import Singular.CLI.Receipt (OutcomeClass (..))
import Singular.CLI.Session (Env, failWith)

-- | Why the command refuses, in the words the receipt states.
retiredRejectReason :: String
retiredRejectReason =
    "registry reject is retired: the registry's state script refuses a spend "
        <> "with the Rejected action, so no such transaction is built; a booked "
        <> "request leaves the registry through the fold (registry fold), and "
        <> "nothing was read, signed or submitted"

{- | @singular registry reject@: refuse, before anything is read or signed.
The caller's arguments are not consulted: no state directory is resolved and no
journal is opened.
-}
runReject :: Env -> RejectArgs -> IO Value
runReject _ _ = failWith ClientRefusal retiredRejectReason
