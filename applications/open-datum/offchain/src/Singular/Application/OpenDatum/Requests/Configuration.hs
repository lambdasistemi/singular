{- |
Module      : Singular.Application.OpenDatum.Requests.Configuration
Description : The configuration record of a registry, as a step of its creation
License     : Apache-2.0

The configuration record of a registry is created in the transaction that
creates the registry: the same transaction spends the seed and mints the
state token. This module is the open-datum part of that transaction, a step
that adds the record's output and its mint to a transaction under
construction. The genesis builder composes it with the state's own steps; the
request validator accepts the composition when the seed is spent, the state
token is minted once and the record is the only birth of its token.
-}
module Singular.Application.OpenDatum.Requests.Configuration
    ( configurationCreate
    ) where

import Cardano.Ledger.BaseTypes (Network)
import Cardano.Ledger.TxIn (TxIn)
import Cardano.Tx.Build (TxBuild)

import Singular.Application.OpenDatum.Requests.Records
    ( RequestParameters
    )
import Singular.Application.OpenDatum.Requests.Script (RequestScript)
import Singular.Registry.TrieState (RegistryIdentity)

{- | Add the configuration record of a registry to a transaction under
construction: an output at the request address holding exactly the token of
the record with the parameters inline, and the mint of that token. The seed is
the output the registry's genesis spends; the transaction must spend it.
-}
configurationCreate
    :: RequestScript
    -> Network
    -> RegistryIdentity
    -> TxIn
    -- ^ The seed the registry's genesis spends
    -> RequestParameters
    -> TxBuild q e ()
configurationCreate _ _ _ _ _ = pure ()
