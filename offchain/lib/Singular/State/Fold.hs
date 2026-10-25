{-# LANGUAGE LambdaCase #-}

{- |
Module      : Singular.State.Fold
Description : Fold pending registrations into a registry from public data alone
License     : Apache-2.0

Anyone may fold the acceptable pending registrations of a registry. The folder
reads the registry's state output, rebuilds its trie from the public history of
the state token, proves each key absent, and builds one transaction that
spends the state and the pending registrations, burns their approvals, mints
the token of each key into the holding its approval commits to, and writes the
new root. The booker contributes nothing but the pending registration on the
chain: no file, no key, no record.

What a pending registration is, how it is spent and how its approval is burned
belong to the application. The application hands the builder those three
things; the builder owns everything the state validator decides.
-}
module Singular.State.Fold
    ( Registration (..)
    , Folded (..)
    , Application (..)
    , buildRegistrationFold
    ) where

import Control.Exception (throwIO)
import Control.Monad (forM, forM_, unless, when)
import Control.Monad.Except (ExceptT (..), runExceptT, throwError)
import Control.Monad.IO.Class (liftIO)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map
import Data.Word (Word32)
import Lens.Micro ((&), (.~), (^.))
import PlutusCore.Data qualified as PLC
import PlutusLedgerApi.V3 qualified as PV3
import PlutusTx.Builtins.Internal (BuiltinData (..))

import Cardano.Ledger.Address (Addr (..))
import Cardano.Ledger.Api.Tx.Out
    ( addrTxOutL
    , coinTxOutL
    , datumTxOutL
    , getMinCoinTxOut
    , mkBasicTxOut
    )
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Credential (Credential (..))
import Cardano.Ledger.Mary.Value
    ( AssetName
    , MaryValue (..)
    , MultiAsset (..)
    , PolicyID (..)
    )
import Cardano.Ledger.Plutus.TxInfo (transAddr)
import Cardano.Ledger.TxIn (TxIn)
import Cardano.Tx.Build qualified as Tx
import Cardano.Tx.Ledger (ConwayTx)

import Singular.Registry.Evidence (NoWitness)
import Singular.Registry.Ledger (ConwayEra, Root (..), TxOut)
import Singular.Registry.LedgerProvider
    ( OutputQuery (..)
    , ReadFailure (..)
    , Session (..)
    )
import Singular.Registry.SessionIO (floorSlot, parameters)
import Singular.Registry.TrieState
    ( Leaf (..)
    , RegistryIdentity (..)
    , SpeculativeWalk (..)
    , StatePoint (..)
    , TrieSelection (..)
    , leafAt
    , speculateEdges
    )
import Singular.Registry.TrieState.Core (snapshotObserved)
import Singular.Registry.TrieState.Types (CompleteFromCreate (..))
import Singular.Registry.TxBuilder.Internal (mkInlineDatum)
import Singular.Registry.Types (edgeInsertActive)
import Singular.State.Assemble
    ( Payer (..)
    , Program
    , assembleTransaction
    , holdsOnly
    , inlineDatumOf
    , readOutputs
    , resolvePayer
    , tipSlot
    , validityFromTip
    )
import Singular.State.Lineage
    ( Replayed (..)
    , registryAsset
    , replayRegistry
    )
import Singular.State.Preimage
    ( activeTokenName
    , approvalName
    , initialDatumHash
    , registrationPreimage
    )
import Singular.State.Records
    ( Change (..)
    , decodeStateDatum
    , foldRedeemer
    , foldedRedeemer
    , stateDatum
    )
import Singular.State.Refusal (Refusal (..))
import Singular.State.Script
    ( StateScript (..)
    , referenceOutputs
    , stateAddress
    , statePolicy
    , stateScriptHash
    , useScript
    )

{- | What the fold needs to know of a pending registration, as the
application publishes it in the registration's datum.
-}
data Registration = Registration
    { regRegistry :: RegistryIdentity
    -- ^ The registry it asks to join
    , regKey :: ByteString
    , regHolding :: Addr
    -- ^ Where the key's token goes
    , regDatum :: PLC.Data
    -- ^ The datum the holding starts with
    , regDeposit :: Coin
    -- ^ What the holding keeps
    , regDeadline :: Integer
    -- ^ The time, in milliseconds, after which only the application's other phases spend it
    }
    deriving stock (Eq, Show)

-- | One pending registration being folded, as the transaction places it.
data Folded = Folded
    { foldedRequest :: TxIn
    , foldedApproval :: AssetName
    -- ^ The approval the pending registration holds
    , foldedHolding :: Word32
    -- ^ The index of the output that is its holding
    }
    deriving stock (Eq, Show)

-- | What the application contributes to a fold.
data Application = Application
    { appPolicy :: PolicyID
    -- ^ The policy of the approvals
    , appDecode :: TxOut ConwayEra -> Maybe Registration
    -- ^ The public decoding of a pending registration
    , appReferences :: [(TxIn, TxOut ConwayEra)]
    -- ^ The outputs that carry its code, already checked, when it is referenced
    , appFold :: [Folded] -> Program ()
    {- ^ Spend the pending registrations into their holdings, burn their
    approvals and make the application's code available to the transaction
    -}
    }

-- | A pending registration read from the chain.
data Pending = Pending
    { pendingRef :: TxIn
    , pendingOutput :: TxOut ConwayEra
    , pendingRegistration :: Registration
    , pendingApproval :: AssetName
    }

{- | Build the fold of these pending registrations into the registry. The
payer funds the transaction and keeps what the pending registrations hold
above their deposits.
-}
buildRegistrationFold
    :: Session NoWitness IO
    -> StateScript
    -> Application
    -> RegistryIdentity
    -> [TxIn]
    -- ^ The pending registrations
    -> Addr
    -- ^ The payer
    -> IO (Either Refusal ConwayTx)
buildRegistrationFold session script application registry requests payerAddress =
    runExceptT $ do
        when (null requests) $ throwError NothingToFold
        forM_ (duplicates requests) (throwError . DuplicateRequest)
        payer <- ExceptT (resolvePayer session payerAddress)
        (stateIn, stateOut, root) <-
            ExceptT (findState session script registry)
        pendings <-
            forM requests (ExceptT . readPending session application registry)
        let keys = map (regKey . pendingRegistration) pendings
        forM_ (duplicates keys) (throwError . DuplicateKey)
        protocol <- liftIO (parameters session)
        forM_ pendings $ \pending -> do
            let smallest = getMinCoinTxOut protocol (holdingFor registry pending)
                deposit = regDeposit (pendingRegistration pending)
            when (deposit < smallest) $
                throwError (DepositBelowHolding (pendingRef pending) deposit smallest)
        let selection =
                TrieSelection
                    { trieSelectionIdentity = registry
                    , trieSelectionPoint =
                        StatePoint (sessionId session) (sessionBinding session) stateIn
                    , trieSelectionRoot = Root root
                    }
        (replayed, nodes) <-
            ExceptT
                (either (Left . TrieRefused) Right <$> replayRegistry session selection)
        let snapshot =
                snapshotObserved
                    (const (pure ()))
                    selection
                    nodes
                    (CompleteFromCreate 0)
                    Nothing
        forM_ keys $ \key ->
            ExceptT (either (Left . TrieRefused) Right <$> leafAt snapshot key)
                >>= \case
                    Unknown -> pure ()
                    _ -> throwError (KeyAlreadyRegistered key)
        walked <-
            ExceptT
                ( either (Left . TrieRefused) Right
                    <$> speculateEdges
                        snapshot
                        (NE.fromList [(key, toInteger edgeInsertActive) | key <- keys])
                )
        now <- liftIO (tipSlot session)
        deadline <-
            liftIO
                ( floorSlot
                    session
                    (minimum (map (regDeadline . pendingRegistration) pendings))
                )
        upper <-
            liftIO (validityFromTip session now deadline)
                >>= maybe (throwError ProcessingWindowClosed) pure
        stateScriptOutputs <-
            ExceptT (referenceOutputs session (ssScript script) (ssSource script))
        let policy = statePolicy script
            RegistryIdentity _ name = registry
            funding = payerFunding payer
            Root newRoot = walkRoot walked
            stateValue =
                MaryValue
                    (stateOut ^. coinTxOutL)
                    (MultiAsset (Map.singleton policy (Map.singleton name 1)))
            spent =
                funding
                    : (stateIn, stateOut)
                    : [(pendingRef p, pendingOutput p) | p <- pendings]
        ExceptT $
            assembleTransaction
                session
                spent
                (stateScriptOutputs <> appReferences application)
                payerAddress
                ( do
                    _ <-
                        Tx.payTo'
                            (stateAddress (payerNetwork payer) script)
                            stateValue
                            (BuiltinData (stateDatum newRoot))
                    holdings <- forM pendings (Tx.output . holdingFor registry)
                    let changes =
                            [ Register
                                { changeRequest = pendingRef pending
                                , changeKey = regKey (pendingRegistration pending)
                                , changeHolding = toInteger holding
                                , changeDeposit =
                                    let Coin d = regDeposit (pendingRegistration pending) in d
                                , changeProof = proof
                                }
                            | (pending, holding, proof) <-
                                zip3 pendings holdings (walkProofs walked)
                            ]
                    _ <-
                        Tx.spendScript
                            stateIn
                            (BuiltinData (foldRedeemer (replayedSeed replayed) changes))
                    Tx.mint
                        policy
                        ( Map.fromList
                            [ (activeTokenName registry (regKey (pendingRegistration p)), 1)
                            | p <- pendings
                            ]
                        )
                        (BuiltinData foldedRedeemer)
                    useScript (ssScript script) (ssSource script)
                    appFold
                        application
                        [ Folded (pendingRef p) (pendingApproval p) holding
                        | (p, holding) <- zip pendings holdings
                        ]
                    Tx.collateral (fst funding)
                    Tx.validFrom now
                    Tx.validTo upper
                )

-- | The first element that appears more than once.
duplicates :: (Eq a) => [a] -> [a]
duplicates xs = take 1 [x | (i, x) <- zip [0 :: Int ..] xs, x `elem` take i xs]

{- | The output that holds the token of a pending registration's key, at the
address the registration commits to, with the datum it commits to and exactly
its deposit.
-}
holdingFor :: RegistryIdentity -> Pending -> TxOut ConwayEra
holdingFor registry@(RegistryIdentity _ _) pending =
    mkBasicTxOut regHolding (MaryValue regDeposit tokens)
        & datumTxOutL .~ mkInlineDatum regDatum
  where
    Registration{regKey, regHolding, regDatum, regDeposit} = pendingRegistration pending
    tokens = case registryAsset registry of
        Just (policy, _) ->
            MultiAsset
                ( Map.singleton
                    policy
                    (Map.singleton (activeTokenName registry regKey) 1)
                )
        Nothing -> mempty

{- | The live state output of the registry: the one output that holds the state
token, at the address of this state script, holding it alone besides ADA, with a
root datum. Anything else that holds the token is no state of the registry.
-}
findState
    :: Session NoWitness IO
    -> StateScript
    -> RegistryIdentity
    -> IO (Either Refusal (TxIn, TxOut ConwayEra, ByteString))
findState session script registry = case registryAsset registry of
    Nothing -> pure (Left (NoRegistryState registry))
    Just (policy, name) -> do
        found <-
            readOutputs session (HoldingAsset (policy, name))
                >>= either throwIO pure
        pure $ case found of
            [] -> Left (NoRegistryState registry)
            [(ref, output)] ->
                maybe
                    (Left (NotARegistryState ref))
                    (Right . (,,) ref output)
                    (recognised policy name output)
            several -> Left (AmbiguousRegistryState (length several))
  where
    recognised policy name output = do
        case output ^. addrTxOutL of
            Addr _ (ScriptHashObj h) _
                | PolicyID h == policy && h == stateScriptHash script -> Just ()
            _ -> Nothing
        unless' (holdsOnly policy name output)
        root <- inlineDatumOf output >>= decodeStateDatum
        unless' (BS.length root == 32)
        pure root
    unless' ok = if ok then Just () else Nothing

{- | A pending registration of the application, read from the chain: decoded,
of this registry, and holding the approval its datum commits to.
-}
readPending
    :: Session NoWitness IO
    -> Application
    -> RegistryIdentity
    -> TxIn
    -> IO (Either Refusal Pending)
readPending session application registry ref =
    readOutputs session (AtTxIn ref) >>= \case
        Left (MissingOutput _) -> pure (Left (PendingNotFound ref))
        Left failure -> throwIO failure
        Right [(_, output)] -> pure (shaped output)
        Right _ -> pure (Left (PendingNotFound ref))
  where
    declined = Left (NotAPendingRegistration ref)
    shaped output = do
        registration <- maybe declined Right (appDecode application output)
        when (regRegistry registration /= registry) $
            Left (PendingOfAnotherRegistry ref)
        approval <- maybe declined Right (approvalOf registration)
        unless (holdsOnly (appPolicy application) approval output) declined
        pure (Pending ref output registration approval)

-- | The name of the approval a registration commits to.
approvalOf :: Registration -> Maybe AssetName
approvalOf registration = do
    holding <- transAddr (regHolding registration)
    let Coin deposit = regDeposit registration
    pure . approvalName $
        registrationPreimage
            (regKey registration)
            (regRegistry registration)
            holding
            (initialDatumHash (regDatum registration))
            (PV3.Lovelace deposit)
