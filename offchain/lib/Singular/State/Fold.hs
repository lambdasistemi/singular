{-# LANGUAGE LambdaCase #-}

{- |
Module      : Singular.State.Fold
Description : Discover foldable requests and build a registry batch from public data
License     : Apache-2.0

Anyone may fold the acceptable pending requests of a registry. The folder reads
its public state and trie history, skips individually unfoldable requests and
keeps the first foldable request per key in take order. A registration proves
its key absent and mints its token into the committed holding; a termination
proves its key active and burns its token. The batch consumes the requests and
their approvals, continues the state and writes the new root. The booker
contributes only the public request: no file, key or local record.

What a pending request is, how it is spent and how its approval is burned
belong to the application. The application hands the builder those three
things; the builder owns everything the state validator decides.
-}
module Singular.State.Fold
    ( Registration (..)
    , Request (..)
    , requestKey
    , Folded (..)
    , Application (..)
    , PendingRequest (..)
    , SkippedHolder (..)
    , SkipReason (..)
    , discoverPending
    , FoldResult (..)
    , FoldFailure (..)
    , pendingTake
    , buildFold
    , attemptFold
    , buildRegistrationFold
    , foldedRequests
    ) where

import Control.Exception (throwIO)
import Control.Monad (forM, forM_, unless, when)
import Control.Monad.Except
    ( ExceptT (..)
    , runExceptT
    , throwError
    , withExceptT
    )
import Control.Monad.IO.Class (liftIO)
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Either (partitionEithers)
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map
import Data.Maybe (mapMaybe)
import Data.Set qualified as Set
import Data.Word (Word32)
import Lens.Micro ((&), (.~), (^.))
import PlutusCore.Data qualified as PLC
import PlutusLedgerApi.V3 qualified as PV3
import PlutusTx.Builtins.Internal (BuiltinData (..))

import Cardano.Ledger.Address (Addr (..))
import Cardano.Ledger.Alonzo.TxWits (Redeemers (..))
import Cardano.Ledger.Api.Scripts.Data (getPlutusData)
import Cardano.Ledger.Api.Tx (witsTxL)
import Cardano.Ledger.Api.Tx.Out
    ( addrTxOutL
    , coinTxOutL
    , datumTxOutL
    , getMinCoinTxOut
    , mkBasicTxOut
    , valueTxOutL
    )
import Cardano.Ledger.Api.Tx.Wits (rdmrsTxWitsL)
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
import Cardano.Slotting.Slot (SlotNo)
import Cardano.Tx.Build qualified as Tx
import Cardano.Tx.Ledger (ConwayTx)

import Singular.Registry.Evidence (NoWitness)
import Singular.Registry.Ledger (ConwayEra, PParams, Root (..), TxOut)
import Singular.Registry.LedgerProvider
    ( OutputQuery (..)
    , ReadFailure (..)
    , Session (..)
    )
import Singular.Registry.SessionIO (floorSlot, parameters, slotStart)
import Singular.Registry.TrieState
    ( Leaf (..)
    , RegistryIdentity (..)
    , SpeculativeWalk (..)
    , StatePoint (..)
    , TrieSelection (..)
    , TrieSnapshot
    , leafAt
    , speculateEdges
    )
import Singular.Registry.TrieState.Core (snapshotObserved)
import Singular.Registry.TrieState.Types (CompleteFromCreate (..))
import Singular.Registry.TxBuilder.Internal (mkInlineDatum)
import Singular.Registry.Types (edgeInsertActive, edgeUpdateTerminal)
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
import Singular.State.Batch
    ( BatchSelection (..)
    , largestFittingPrefix
    , orderByTake
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
    , terminationPreimage
    )
import Singular.State.Records
    ( Change (..)
    , decodeFoldRedeemer
    , decodeStateDatum
    , foldRedeemer
    , foldedRedeemer
    , stateDatum
    )
import Singular.State.Refusal (CapacityLimit, Refusal (..))
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

-- | An application request, decoded from public data.
data Request
    = RegistrationRequest Registration
    | TerminationRequest RegistryIdentity ByteString
    deriving stock (Eq, Show)

requestKey :: Request -> ByteString
requestKey (RegistrationRequest r) = regKey r
requestKey (TerminationRequest _ key) = key

requestRegistry :: Request -> RegistryIdentity
requestRegistry (RegistrationRequest r) = regRegistry r
requestRegistry (TerminationRequest registry _) = registry

-- | A request being folded, with a holding output only for registration.
data Folded = Folded
    { foldedRequest :: TxIn
    , foldedApproval :: AssetName
    , foldedRegistry :: RegistryIdentity
    , foldedKey :: ByteString
    , foldedHolding :: Maybe Word32
    }
    deriving stock (Eq, Show)

-- | What the application contributes to a fold.
data Application = Application
    { appPolicy :: PolicyID
    -- ^ The policy of the approvals
    , appDecode
        :: RegistryIdentity -> [ByteString] -> TxOut ConwayEra -> Maybe Request
    -- ^ The public decoding of a pending request at the application's script
    , appIsConfiguration :: TxOut ConwayEra -> Bool
    {- ^ Whether an output is the configuration of a registry the application
    holds, not a request. Discovery neither folds nor reports such an output.
    -}
    , appReferences :: [(TxIn, TxOut ConwayEra)]
    -- ^ The outputs that carry its code, already checked, when it is referenced
    , appFold :: [Folded] -> Program ()
    {- ^ Spend the pending registrations into their holdings, burn their
    approvals and make the application's code available to the transaction
    -}
    }

-- | A request and its exact output, authenticated from public chain data.
data PendingRequest = PendingRequest
    { pendingRef :: TxIn
    -- ^ The output the fold must spend, once.
    , pendingOutput :: TxOut ConwayEra
    -- ^ Its complete value and datum as served by the provider.
    , pendingRequest :: Request
    -- ^ Its decoded registry, key, kind and registration holding requirements.
    , pendingApproval :: AssetName
    -- ^ The authenticated approval held by that same output.
    }
    deriving stock (Eq, Show)

-- | Why an approval holder is omitted from an automatic fold.
data SkipReason
    = HeldAtKeyAddress
    | DecodedForAnotherRegistry
    | NotAcceptedByApplication
    | UnfoldableRequest Refusal
    deriving stock (Eq, Show)

-- | A holder omitted from an automatic fold, with its public reference and reason.
data SkippedHolder = SkippedHolder
    { skippedRef :: TxIn
    -- ^ The holder that remains unspent by this discovery result.
    , skippedReason :: SkipReason
    -- ^ The reason it was not selected as this registry's request.
    }
    deriving stock (Eq, Show)

{- | Find requests using one complete policy query. The caller supplies keys
from the registry's public replay; neither a wallet nor a local booking record
participates. An output the application names as its configuration is in
neither list. A failed read is thrown with its provider evidence intact.
-}
discoverPending
    :: Session NoWitness IO
    -> Application
    -> RegistryIdentity
    -> [ByteString]
    -> IO ([PendingRequest], [SkippedHolder])
discoverPending session application registry candidates = do
    holders <-
        readOutputs session (HoldingPolicy (appPolicy application))
            >>= either throwIO pure
    let (skipped, pending) = partitionEithers (mapMaybe classify holders)
    pure (pending, skipped)
  where
    classify (ref, output)
        | Addr _ KeyHashObj{} _ <- output ^. addrTxOutL =
            Just (Left (SkippedHolder ref HeldAtKeyAddress))
        | appIsConfiguration application output = Nothing
        | otherwise =
            Just $ case pendingFromOutput application registry candidates ref output of
                Right pending -> Right pending
                Left PendingOfAnotherRegistry{} -> Left (SkippedHolder ref DecodedForAnotherRegistry)
                Left _ -> Left (SkippedHolder ref NotAcceptedByApplication)

{- | Fold named requests, or discover them from approvals when none is named.
The payer funds the transaction and keeps what each registration holds above
its deposit and what each termination holds in full.
-}
buildRegistrationFold
    :: Session NoWitness IO
    -> StateScript
    -> Application
    -> RegistryIdentity
    -> [TxIn]
    -> Addr
    -> IO (Either Refusal ConwayTx)
buildRegistrationFold session script application registry requests payerAddress =
    fmap foldTransaction
        <$> buildFold
            session
            script
            application
            registry
            requests
            payerAddress
            Nothing

-- | The actual built batch and the complete discovery accounting.
data FoldResult = FoldResult
    { foldTransaction :: ConwayTx
    -- ^ The successful probe's transaction.
    , foldSelected :: [PendingRequest]
    -- ^ The folded requests, in their transaction order.
    , foldSkipped :: [SkippedHolder]
    -- ^ All unaccepted or individually unfoldable holders, named with reasons.
    , foldLeft :: Int
    -- ^ Every foldable request beyond the chosen prefix, including the cap.
    , foldBoundary :: Maybe CapacityLimit
    -- ^ The next prefix's actual capacity refusal, when a boundary was probed.
    }
    deriving stock (Eq, Show)

-- | The folder's take from the observed request, matching natural subtraction.
pendingTake :: PendingRequest -> Coin
pendingTake pending = case pendingRequest pending of
    RegistrationRequest registration ->
        let Coin deposit = regDeposit registration
        in  Coin (max 0 (held - deposit))
    TerminationRequest{} -> Coin held
  where
    Coin held = pendingOutput pending ^. coinTxOutL

{- | Discover and build the greatest fitting prefix, optionally capped. A
nonempty named batch is built as named, without a cap or trimming. Automatic
selection first skips individually unfoldable requests, then later foldable
requests for an already selected key. Capacity alone permits a shorter prefix;
other construction and public-read failures retain their own identity.
-}
buildFold
    :: Session NoWitness IO
    -> StateScript
    -> Application
    -> RegistryIdentity
    -> [TxIn]
    -> Addr
    -> Maybe Word32
    -> IO (Either Refusal FoldResult)
buildFold session script application registry requests payerAddress cap =
    first foldFailureReason
        <$> attemptFold
            session
            script
            application
            registry
            requests
            payerAddress
            cap

-- | A refusal, retaining complete discovery accounting when it was observed.
data FoldFailure = FoldFailure
    { foldFailureReason :: Refusal
    , foldFailureObserved :: Maybe ([SkippedHolder], Int)
    {- ^ All skipped holders and the unconsumed candidate count after automatic
    filtering. Nothing means classification was incomplete, so no empty set may
    be claimed.
    -}
    }
    deriving stock (Eq, Show)

{- | Build with the same rules as 'buildFold', retaining observed holders even
when nothing is eligible or a later build refuses. Failed reads still throw.
-}
attemptFold
    :: Session NoWitness IO
    -> StateScript
    -> Application
    -> RegistryIdentity
    -> [TxIn]
    -> Addr
    -> Maybe Word32
    -> IO (Either FoldFailure FoldResult)
attemptFold session script application registry requests payerAddress cap = runExceptT $ do
    (payer, observed, pendings, skipped) <- withExceptT (`FoldFailure` Nothing) $ do
        forM_ (duplicates requests) (throwError . DuplicateRequest)
        payer <- ExceptT (resolvePayer session payerAddress)
        observed@(PublicRegistry _ _ replayed _) <-
            readPublicRegistry session script registry
        (pendings, skipped) <-
            if null requests
                then
                    liftIO
                        (discoverPending session application registry (replayedKeys replayed))
                else do
                    named <-
                        forM
                            requests
                            ( ExceptT
                                . readPending session application registry (replayedKeys replayed)
                            )
                    pure (named, [])
        pure (payer, observed, pendings, skipped)
    (foldable, omitted, observation) <-
        if null requests
            then withExceptT (`FoldFailure` Nothing) $ do
                protocol <- liftIO (parameters session)
                now <- liftIO (tipSlot session)
                let current = FoldObservation protocol now
                (accepted, refused) <-
                    selectFoldable
                        session
                        registry
                        observed
                        current
                        (orderByTake pendingTake pendingRef pendings)
                pure (accepted, skipped <> refused, Just current)
            else pure (pendings, skipped, Nothing)
    let build =
            buildPendingFold
                session
                script
                application
                registry
                observed
                observation
                payer
                payerAddress
    selected <-
        withExceptT
            (\reason -> FoldFailure reason (Just (omitted, length foldable)))
            $ if null requests
                then
                    ExceptT
                        ( largestFittingPrefix
                            (runExceptT . build)
                            cap
                            foldable
                        )
                else do
                    tx <- build foldable
                    pure (BatchSelection foldable 0 tx Nothing)
    pure
        FoldResult
            { foldTransaction = selectedBuild selected
            , foldSelected = selectedRequests selected
            , foldSkipped = omitted
            , foldLeft = requestsLeft selected
            , foldBoundary = nextCapacity selected
            }

-- | Captured public state and replay, shared by all probes of one fold.
data PublicRegistry
    = PublicRegistry TxIn (TxOut ConwayEra) Replayed (TrieSnapshot IO)

-- | One protocol and clock observation shared by eligibility and capacity probes.
data FoldObservation = FoldObservation (PParams ConwayEra) SlotNo

selectFoldable
    :: Session NoWitness IO
    -> RegistryIdentity
    -> PublicRegistry
    -> FoldObservation
    -> [PendingRequest]
    -> ExceptT Refusal IO ([PendingRequest], [SkippedHolder])
selectFoldable session registry (PublicRegistry _ _ _ snapshot) (FoldObservation protocol now) =
    go Set.empty [] []
  where
    go _ accepted omitted [] = pure (reverse accepted, reverse omitted)
    go keys accepted omitted (pending : rest) = do
        eligible <- liftIO . runExceptT $ do
            checkDeposit protocol registry pending
            checkLeaf snapshot pending
            case pendingRequest pending of
                RegistrationRequest registration -> do
                    _ <- processingWindow session now [registration]
                    pure ()
                TerminationRequest{} -> pure ()
        let key = requestKey (pendingRequest pending)
            skip reason =
                go
                    keys
                    accepted
                    ( SkippedHolder (pendingRef pending) (UnfoldableRequest reason)
                        : omitted
                    )
                    rest
        case eligible of
            Left reason | individualRefusal reason -> skip reason
            Left failure -> throwError failure
            Right ()
                | Set.member key keys -> skip (DuplicateKey key)
                | otherwise ->
                    go (Set.insert key keys) (pending : accepted) omitted rest
    individualRefusal = \case
        DepositBelowHolding{} -> True
        KeyAlreadyRegistered{} -> True
        KeyNotActive{} -> True
        ProcessingWindowClosed -> True
        _ -> False

checkDeposit
    :: PParams ConwayEra
    -> RegistryIdentity
    -> PendingRequest
    -> ExceptT Refusal IO ()
checkDeposit protocol registry pending = case pendingRequest pending of
    RegistrationRequest registration -> do
        let smallest = getMinCoinTxOut protocol (holdingFor registry registration)
            deposit = regDeposit registration
        when (deposit < smallest) $
            throwError (DepositBelowHolding (pendingRef pending) deposit smallest)
    TerminationRequest{} -> pure ()

checkLeaf
    :: TrieSnapshot IO -> PendingRequest -> ExceptT Refusal IO ()
checkLeaf snapshot pending = do
    let request = pendingRequest pending
        key = requestKey request
    leaf <-
        ExceptT (either (Left . TrieRefused) Right <$> leafAt snapshot key)
    case request of
        RegistrationRequest{} -> unless (leaf == Unknown) (throwError (KeyAlreadyRegistered key))
        TerminationRequest{} -> unless (leaf == Active) (throwError (KeyNotActive key))

processingWindow
    :: Session NoWitness IO
    -> SlotNo
    -> [Registration]
    -> ExceptT Refusal IO SlotNo
processingWindow session now registrations = do
    fallback <- (+ 3600000) <$> liftIO (slotStart session now)
    deadline <-
        liftIO
            (floorSlot session (minimum (fallback : map regDeadline registrations)))
    liftIO (validityFromTip session now deadline)
        >>= maybe (throwError ProcessingWindowClosed) pure

readPublicRegistry
    :: Session NoWitness IO
    -> StateScript
    -> RegistryIdentity
    -> ExceptT Refusal IO PublicRegistry
readPublicRegistry session script registry = do
    (stateIn, stateOut, root) <-
        ExceptT (findState session script registry)
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
    pure (PublicRegistry stateIn stateOut replayed snapshot)

buildPendingFold
    :: Session NoWitness IO
    -> StateScript
    -> Application
    -> RegistryIdentity
    -> PublicRegistry
    -> Maybe FoldObservation
    -> Payer
    -> Addr
    -> [PendingRequest]
    -> ExceptT Refusal IO ConwayTx
buildPendingFold session script application registry (PublicRegistry stateIn stateOut replayed snapshot) observation payer payerAddress pendings = do
    when (null pendings) $ throwError NothingToFold
    let keys = map (requestKey . pendingRequest) pendings
    forM_ (duplicates keys) (throwError . DuplicateKey)
    protocol <- case observation of
        Just (FoldObservation observedProtocol _) -> pure observedProtocol
        Nothing -> liftIO (parameters session)
    forM_ pendings (checkDeposit protocol registry)
    forM_ pendings (checkLeaf snapshot)
    walked <-
        ExceptT
            ( either (Left . TrieRefused) Right
                <$> speculateEdges
                    snapshot
                    ( NE.fromList
                        [ (requestKey request, toInteger (edgeFor request))
                        | pending <- pendings
                        , let request = pendingRequest pending
                        ]
                    )
            )
    now <- case observation of
        Just (FoldObservation _ observedSlot) -> pure observedSlot
        Nothing -> liftIO (tipSlot session)
    upper <-
        processingWindow
            session
            now
            [ registration
            | pending <- pendings
            , RegistrationRequest registration <- [pendingRequest pending]
            ]
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
                changed <- forM (zip pendings (walkProofs walked)) $ \(pending, proof) -> do
                    let request = pendingRequest pending
                        folded =
                            Folded
                                (pendingRef pending)
                                (pendingApproval pending)
                                registry
                                (requestKey request)
                    case request of
                        RegistrationRequest registration -> do
                            holding <- Tx.output (holdingFor registry registration)
                            let Coin deposit = regDeposit registration
                            pure
                                ( Register
                                    (pendingRef pending)
                                    (regKey registration)
                                    (toInteger holding)
                                    deposit
                                    proof
                                , folded (Just holding)
                                )
                        TerminationRequest _ key ->
                            pure (Terminate (pendingRef pending) key proof, folded Nothing)
                let changes = map fst changed
                _ <-
                    Tx.spendScript
                        stateIn
                        (BuiltinData (foldRedeemer (replayedSeed replayed) changes))
                Tx.mint
                    policy
                    ( Map.fromListWith
                        (+)
                        [ ( activeTokenName registry (requestKey request)
                          , case request of RegistrationRequest{} -> 1; TerminationRequest{} -> -1
                          )
                        | p <- pendings
                        , let request = pendingRequest p
                        ]
                    )
                    (BuiltinData foldedRedeemer)
                useScript (ssScript script) (ssSource script)
                appFold application (map snd changed)
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
holdingFor :: RegistryIdentity -> Registration -> TxOut ConwayEra
holdingFor registry registration =
    mkBasicTxOut regHolding (MaryValue regDeposit tokens)
        & datumTxOutL .~ mkInlineDatum regDatum
  where
    Registration{regKey, regHolding, regDatum, regDeposit} = registration
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
    -> [ByteString]
    -> TxIn
    -> IO (Either Refusal PendingRequest)
readPending session application registry candidates ref =
    readOutputs session (AtTxIn ref) >>= \case
        Left (MissingOutput _) -> pure (Left (PendingNotFound ref))
        Left failure -> throwIO failure
        Right [(_, output)] ->
            pure (pendingFromOutput application registry candidates ref output)
        Right _ -> pure (Left (PendingNotFound ref))

-- | The same request authentication for discovered and explicitly named outputs.
pendingFromOutput
    :: Application
    -> RegistryIdentity
    -> [ByteString]
    -> TxIn
    -> TxOut ConwayEra
    -> Either Refusal PendingRequest
pendingFromOutput application registry candidates ref output = do
    request <-
        maybe
            declined
            Right
            (appDecode application registry candidates output)
    when (requestRegistry request /= registry) $
        Left (PendingOfAnotherRegistry ref)
    approval <- maybe declined Right (approvalOf request)
    case request of
        RegistrationRequest registration -> do
            unless (holdsOnly (appPolicy application) approval output) declined
            unless (regDeposit registration <= output ^. coinTxOutL) declined
        TerminationRequest _ key -> do
            (policy, _) <- maybe declined Right (registryAsset registry)
            let expected =
                    MultiAsset
                        ( Map.fromListWith
                            (Map.unionWith (+))
                            [ (policy, Map.singleton (activeTokenName registry key) 1)
                            , (appPolicy application, Map.singleton approval 1)
                            ]
                        )
                MaryValue _ actual = output ^. valueTxOutL
            unless (actual == expected) declined
    pure (PendingRequest ref output request approval)
  where
    declined = Left (NotAPendingRegistration ref)

edgeFor :: Request -> Int
edgeFor RegistrationRequest{} = fromIntegral edgeInsertActive
edgeFor TerminationRequest{} = fromIntegral edgeUpdateTerminal

-- | The name of the approval a registration commits to.
approvalOf :: Request -> Maybe AssetName
approvalOf (TerminationRequest registry key) = Just (approvalName (terminationPreimage key registry))
approvalOf (RegistrationRequest registration) = do
    holding <- transAddr (regHolding registration)
    let Coin deposit = regDeposit registration
    pure . approvalName $
        registrationPreimage
            (regKey registration)
            (regRegistry registration)
            holding
            (initialDatumHash (regDatum registration))
            (PV3.Lovelace deposit)

-- | Requests named by the fold redeemer of a built transaction.
foldedRequests :: ConwayTx -> [(TxIn, ByteString)]
foldedRequests tx =
    [ (changeRequest change, changeKey change)
    | (_, changes) <- decoded
    , change <- changes
    ]
  where
    Redeemers redeemers = tx ^. witsTxL . rdmrsTxWitsL
    decoded =
        mapMaybe
            (decodeFoldRedeemer . getPlutusData . fst)
            (Map.elems redeemers)
