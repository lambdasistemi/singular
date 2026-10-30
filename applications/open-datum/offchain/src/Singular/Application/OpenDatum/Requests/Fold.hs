{- |
Module      : Singular.Application.OpenDatum.Requests.Fold
Description : What open datum contributes to a fold of pending registrations
License     : Apache-2.0

The fold of a registry belongs to the Singular state: it finds the state,
rebuilds the trie and writes the root. What belongs to open datum is what a
pending registration is, how it is spent and how its approval is burned. This
module hands the fold builder those three things for a request validator, so
anyone with the chain and a wallet can fold what has been booked. It also says
which output is a registry's configuration: that output holds an approval but
is not a request, so a fold neither takes it nor reports it.
-}
module Singular.Application.OpenDatum.Requests.Fold
    ( openDatumApplication
    ) where

import Control.Monad (forM_)
import Control.Monad.Trans.Except (ExceptT (..), runExceptT)
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust)
import Lens.Micro ((^.))

import Cardano.Ledger.Address (Addr (..))
import Cardano.Ledger.Api.Scripts.Data (Datum (NoDatum))
import Cardano.Ledger.Api.Tx.Out
    ( addrTxOutL
    , datumTxOutL
    , valueTxOutL
    )
import Cardano.Ledger.BaseTypes (Network)
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Credential (Credential (..))
import Cardano.Ledger.Mary.Value (MaryValue (..), MultiAsset (..))
import Cardano.Tx.Build qualified as Tx

import Singular.Application.OpenDatum.Requests.Assemble
    ( inlineDatumOf
    )
import Singular.Application.OpenDatum.Requests.Records
    ( AsData (..)
    , MintAction (..)
    , RegistrationData (..)
    , SpendAction (..)
    , decodeConfiguration
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
    , Request (..)
    )

import Singular.State.Lineage (registryAsset)
import Singular.State.Preimage
    ( activeTokenName
    , approvalName
    , terminationPreimage
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
            , appIsConfiguration = isConfiguration
            , appReferences = references
            , appFold = \folded -> do
                forM_ folded $ \f ->
                    Tx.spendScript
                        (foldedRequest f)
                        ( AsData
                            ( spendRedeemer
                                ( case foldedHolding f of
                                    Just holding -> RegistrationFold (toInteger holding)
                                    Nothing -> TerminationFold (foldedRegistry f) (foldedKey f)
                                )
                            )
                        )
                Tx.mint
                    (requestPolicy script)
                    (Map.fromListWith (+) [(foldedApproval f, -1) | f <- folded])
                    (AsData (mintRedeemer [ApprovalBurn]))
                useScript script
            }
  where
    isConfiguration output = case output ^. addrTxOutL of
        Addr _ (ScriptHashObj hash) _
            | hash == requestScriptHash script ->
                holdsOneToken output
                    && isJust (inlineDatumOf output >>= decodeConfiguration)
        _ -> False
    -- The booking reader also requires the record's own token by name; the name
    -- belongs to a registry that is not known here.
    holdsOneToken output = case output ^. valueTxOutL of
        MaryValue _ (MultiAsset assets) -> case Map.toList assets of
            [(policy, tokens)] ->
                policy == requestPolicy script && Map.elems tokens == [1]
            _ -> False
    decode registry candidates output = case output ^. addrTxOutL of
        Addr _ (ScriptHashObj hash) _
            | hash == requestScriptHash script -> do
                case output ^. datumTxOutL of
                    NoDatum -> do
                        (policy, _) <- registryAsset registry
                        let MaryValue _ actual = output ^. valueTxOutL
                            matches key =
                                actual
                                    == MultiAsset
                                        ( Map.fromListWith
                                            (Map.unionWith (+))
                                            [ (policy, Map.singleton (activeTokenName registry key) 1)
                                            ,
                                                ( requestPolicy script
                                                , Map.singleton (approvalName (terminationPreimage key registry)) 1
                                                )
                                            ]
                                        )
                        case filter matches candidates of
                            [key] -> Just (TerminationRequest registry key)
                            _ -> Nothing
                    _ -> registration output
        _ -> Nothing
    registration output = do
        r <- inlineDatumOf output >>= decodeRegistration net
        pure . RegistrationRequest $
            Registration
                { regRegistry = rdRegistry r
                , regKey = rdKey r
                , regHolding = rdHoldingAddress r
                , regDatum = rdInitialDatum r
                , regDeposit = Coin (rdDeposit r)
                , regDeadline = rdProcessDeadline r
                }
