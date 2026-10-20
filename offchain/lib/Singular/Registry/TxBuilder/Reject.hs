{- |
Module      : Singular.Registry.TxBuilder.Reject
Description : The retired state-spending rejection
License     : Apache-2.0

The state is never spent to reject a request. The fold of the registry has no
such action: a state spent with a rejection is refused @rejected-retired@ by
the validator for every request, and a request that is not a genuine booked
request is not a member of any fold. So no transaction is built here, for a
tagged request or for a legacy one; the two entry points keep their shape for
their callers and answer with that refusal.
-}
module Singular.Registry.TxBuilder.Reject
    ( rejectRequestsImpl
    , rejectRequestsWithRefs
    ) where

import Cardano.Ledger.Address (Addr)
import Cardano.Tx.Ledger (ConwayTx)

import Cardano.Ledger.Api.Tx.Out (TxOut)
import Singular.Registry.Config (CageConfig)
import Singular.Registry.Evidence (NoWitness)
import Singular.Registry.Ledger (ConwayEra, TokenId, TxIn)
import Singular.Registry.LedgerProvider (Session)

{- | Refuses: the state is never spent to reject a request
(@rejected-retired@).
-}
rejectRequestsImpl
    :: CageConfig
    -> Session NoWitness IO
    -> TokenId
    -> Addr
    -> IO ConwayTx
rejectRequestsImpl cfg view tid addr =
    rejectRequestsWithRefs cfg view tid addr []

{- | Refuses, whatever outputs carry the scripts: the state is never spent to
reject a request (@rejected-retired@).
-}
rejectRequestsWithRefs
    :: CageConfig
    -> Session NoWitness IO
    -> TokenId
    -> Addr
    -> [(TxIn, TxOut ConwayEra)]
    -- ^ Outputs carrying the scripts of the retired reject as reference scripts
    -> IO ConwayTx
rejectRequestsWithRefs _ _ _ _ _ =
    ioError
        ( userError
            "reject: rejected-retired: the state is never spent to reject a request"
        )
