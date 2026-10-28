{- |
Module      : Singular.State.Refusal
Description : Why a builder of the Singular state declines to build a transaction
License     : Apache-2.0

A builder returns a 'Refusal' instead of a transaction it knows the Singular
state validator, the application's validator or the ledger would refuse. Every
refusal names a fact about the chain or the arguments that the caller can act
on. A failed read of the chain is not a refusal: it throws, as the other
builders' reads do.
-}
module Singular.State.Refusal
    ( Refusal (..)
    ) where

import Data.ByteString (ByteString)
import Data.Text (Text)

import Cardano.Ledger.Coin (Coin)
import Cardano.Ledger.Hashes (ScriptHash)
import Cardano.Ledger.TxIn (TxIn)

import Singular.Registry.TrieState (RegistryIdentity, TrieFailure)

-- | Why a builder declined.
data Refusal
    = -- | The payer's address holds no ADA-only output for fee and collateral.
      PayerHasNoFunding
    | -- | The payer's payment credential is a script, which cannot sign.
      PayerIsNotAKey
    | -- | The seed is not an unspent output of the payer.
      SeedNotAtPayer TxIn
    | -- | The reference output named for a script is not on the chain.
      ReferenceScriptMissing TxIn
    | {- | The reference output carries no script, or another one: the hash it
      carries, when it carries a script, and the expected hash.
      -}
      ReferenceScriptMismatch TxIn (Maybe ScriptHash) ScriptHash
    | -- | No output holds the state token of the registry.
      NoRegistryState RegistryIdentity
    | -- | Several outputs hold the state token; the count found.
      AmbiguousRegistryState Int
    | -- | The output that holds the state token is not a state of the registry.
      NotARegistryState TxIn
    | -- | The registry's public history cannot be replayed into its trie.
      TrieRefused TrieFailure
    | -- | There is nothing to fold.
      NothingToFold
    | -- | The same pending registration is named twice.
      DuplicateRequest TxIn
    | -- | Two pending registrations name the same key.
      DuplicateKey ByteString
    | -- | The key is already registered: its leaf is not unknown.
      KeyAlreadyRegistered ByteString
    | -- | A termination can only consume an active key.
      KeyNotActive ByteString
    | -- | The output to fold is not on the chain.
      PendingNotFound TxIn
    | {- | The output is not a pending registration the application decodes and
      authenticates: it holds no approval, or another, than the registration
      it carries commits.
      -}
      NotAPendingRegistration TxIn
    | -- | The pending registration belongs to another registry.
      PendingOfAnotherRegistry TxIn
    | {- | The deposit is below the minimum ADA of the holding it commits, so
      no fold could ever deliver it; the deposit and that minimum.
      -}
      DepositBelowHolding TxIn Coin Coin
    | -- | No validity interval at the tip ends before every processing deadline.
      ProcessingWindowClosed
    | -- | The transaction builder itself failed; its message.
      BuildFailed Text
    deriving stock (Eq, Show)
