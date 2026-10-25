{- |
Module      : Singular.Application.OpenDatum.Requests.Fold
Description : What open datum contributes to a fold of pending registrations
License     : Apache-2.0

The fold of a registry belongs to the Singular state: it finds the state,
rebuilds the trie and writes the root. What belongs to open datum is what a
pending registration is, how it is spent and how its approval is burned. This
module hands the fold builder those three things for a request validator, so
anyone with the chain and a wallet can fold what has been booked.
-}
module Singular.Application.OpenDatum.Requests.Fold
    ( openDatumApplication
    ) where

import Control.Monad (forM_)
import Control.Monad.Trans.Except (ExceptT (..), runExceptT)
import Data.Map.Strict qualified as Map
import Lens.Micro ((^.))

import Cardano.Ledger.Address (Addr (..))
import Cardano.Ledger.Api.Tx.Out (addrTxOutL)
import Cardano.Ledger.BaseTypes (Network)
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Credential (Credential (..))
import Cardano.Tx.Build qualified as Tx

import Singular.Application.OpenDatum.Requests.Assemble
    ( inlineDatumOf
    )
import Singular.Application.OpenDatum.Requests.Records
    ( AsData (..)
    , MintAction (..)
    , RegistrationData (..)
    , SpendAction (..)
    , decodeRegistration
    , mintRedeemer
    , spendRedeemer
    )
import Singular.Application.OpenDatum.Requests.Refusal (Refusal)
import Singular.Application.OpenDatum.Requests.Script
    ( RequestScript
    , referenceOutputs
    , requestPolicy
    , requestScriptHash
    , useScript
    )
import Singular.Registry.Evidence (NoWitness)
import Singular.Registry.LedgerProvider (Session)
import Singular.State.Fold
    ( Application (..)
    , Folded (..)
    , Registration (..)
    )

{- | The open-datum application of a fold: the request validator's pending
registrations decoded, spent by a fold and their approvals burned. Refused when
the script's reference output is missing or carries another script.
-}
openDatumApplication
    :: Session NoWitness IO
    -> RequestScript
    -> Network
    -> IO (Either Refusal Application)
openDatumApplication session script net = runExceptT $ do
    references <- ExceptT (referenceOutputs session script)
    pure
        Application
            { appPolicy = requestPolicy script
            , appDecode = decode
            , appReferences = references
            , appFold = \folded -> do
                forM_ folded $ \f ->
                    Tx.spendScript
                        (foldedRequest f)
                        ( AsData
                            ( spendRedeemer
                                (RegistrationFold (toInteger (foldedHolding f)))
                            )
                        )
                Tx.mint
                    (requestPolicy script)
                    (Map.fromList [(foldedApproval f, -1) | f <- folded])
                    (AsData (mintRedeemer [ApprovalBurn]))
                useScript script
            }
  where
    decode output = case output ^. addrTxOutL of
        Addr _ (ScriptHashObj hash) _
            | hash == requestScriptHash script -> do
                registration <- inlineDatumOf output >>= decodeRegistration net
                pure
                    Registration
                        { regRegistry = rdRegistry registration
                        , regKey = rdKey registration
                        , regHolding = rdHoldingAddress registration
                        , regDatum = rdInitialDatum registration
                        , regDeposit = Coin (rdDeposit registration)
                        , regDeadline = rdProcessDeadline registration
                        }
        _ -> Nothing
