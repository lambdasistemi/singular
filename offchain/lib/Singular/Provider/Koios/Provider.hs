{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RankNTypes #-}

{- | The shipping generic Koios constructor. The caller supplies scope and
observation effects; the shared client owns every HTTP decoder and page.
-}
module Singular.Provider.Koios.Provider
    ( koiosProvider
    , ProviderRuntime (..)
    , ProviderEvent (..)
    , TimeSource (..)
    ) where

import Cardano.Ledger.Address (AccountAddress (..), AccountId (..))
import Cardano.Ledger.Api.Tx.Out (addrTxOutL)
import Cardano.Ledger.BaseTypes qualified as Ledger
import Cardano.Ledger.Credential (Credential (ScriptHashObj))
import Cardano.Ledger.TxIn (TxIn (..))
import Control.Monad.Except (ExceptT (..), runExceptT, throwError)
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Lens.Micro ((^.))
import Singular.Provider.Koios.Client qualified as Client
import Singular.Provider.Koios.History (assetHistory)
import Singular.Provider.Koios.Wire qualified as Wire
import Singular.Registry.Evidence
import Singular.Registry.LedgerProvider
import Singular.Registry.NetworkTime
    ( NetworkTimeManifest
    , validateNetworkTime
    )

-- | Public source bytes, validated at the same boundary that records them.
data TimeSource = TimeSource NetworkTimeManifest ByteString ByteString

{- | Every exchange and local raw time read carries its acquisition identity.
Authorization headers are removed before an observation leaves this module.
-}
data ProviderEvent
    = SessionOpened SessionId Network
    | SessionClosed SessionId
    | RawExchange SessionId Client.RawRequest Client.Exchange
    | RawTime SessionId TimeSource

{- | Scope effects are explicit. Pure State implementations keep their open
session set and events in State; IO implementations release on exceptions.
-}
data ProviderRuntime m = ProviderRuntime
    { scopedSession
        :: forall a. (SessionId -> m a) -> (SessionId -> m ()) -> m a
    , sessionOpen :: SessionId -> m Bool
    , recordEvent :: ProviderEvent -> m ()
    , measureRead
        :: forall a. SessionId -> Text -> (a -> ProviderEvent) -> m a -> m a
    }

koiosProvider
    :: (Monad m)
    => ProviderRuntime m
    -> Network
    -> TimeSource
    -> Client.Koios m
    -> LedgerProvider NoWitness m
koiosProvider runtime configured timeSource client =
    LedgerProvider
        { acquire = \requested action -> case requested of
            AtPoint network point
                | network /= configured ->
                    pure (Left (WrongNetwork configured network))
                | otherwise -> pure (Left (PointNotSupported point))
            Latest network
                | network /= configured ->
                    pure (Left (WrongNetwork configured network))
                | otherwise ->
                    scopedSession
                        runtime
                        ( \identity -> do
                            recordEvent runtime (SessionOpened identity configured)
                            Right <$> action (session identity)
                        )
                        (recordEvent runtime . SessionClosed)
        , submitTx = \network signed ->
            if network /= configured
                then pure (SubmitWrongNetwork configured network)
                else do
                    -- The shared signed-only raw submitter is the allowlisted
                    -- transport composition. Submission is outside a read scope.
                    result <- Client.submitTx client signed
                    pure $ case result of
                        Left failure -> SubmitFailed (Text.pack (show failure))
                        Right (Client.SubmitAccepted key) -> SubmitAccepted key
                        Right (Client.SubmitRefused reason) -> SubmitRefused reason
        }
  where
    session identity =
        let scopedClient =
                client
                    { Client.koiosTransport = Client.Transport $ \request -> do
                        measureRead
                            runtime
                            identity
                            (Wire.callName (Client.rawCall request))
                            ( RawExchange
                                identity
                                request
                                    { Client.rawHeaders =
                                        filter ((/= "authorization") . fst) (Client.rawHeaders request)
                                    }
                            )
                            (Client.exchange (Client.koiosTransport client) request)
                    }
            readFact action =
                guarded
                    identity
                    ( fmap
                        (first backendFailure . fmap (\value -> Evidenced value Nothing))
                        action
                    )
            localTime =
                let Network magic = configured
                    TimeSource manifest genesis eras = timeSource
                in  measureRead
                        runtime
                        identity
                        "network-time"
                        (const (RawTime identity timeSource))
                        $ pure
                            ( first
                                NetworkTimeRefusal
                                ( fmap
                                    (\value -> Evidenced value Nothing)
                                    (validateNetworkTime magic manifest genesis eras)
                                )
                            )
            readHistory asset range = do
                open <- sessionOpen runtime identity
                if not open
                    then pure (Left (HistoryReadFailure (ReleasedSession identity)))
                    else
                        fmap
                            (fmap (guardStream identity))
                            (assetHistory scopedClient asset range)
        in  Session
                { sessionNetwork = configured
                , sessionId = identity
                , sessionBinding = Unbound
                , outputs = \query ->
                    guarded
                        identity
                        ( fmap
                            (fmap (\value -> Evidenced value Nothing))
                            (runExceptT (queryOutputs scopedClient query))
                        )
                , protocolParameters = readFact (Client.cliProtocolParams scopedClient)
                , tipObservation =
                    readFact (fmap (fmap observation) (Client.tip scopedClient))
                , networkTime = guarded identity localTime
                , scriptRegistered = \script ->
                    readFact
                        ( Client.accountRegistered
                            scopedClient
                            (AccountAddress Ledger.Testnet (AccountId (ScriptHashObj script)))
                        )
                , history = readHistory
                }
    guarded identity action = do
        open <- sessionOpen runtime identity
        if open then action else pure (Left (ReleasedSession identity))
    guardStream identity stream = HistoryStream $ do
        open <- sessionOpen runtime identity
        if open
            then
                fmap
                    (fmap (fmap (\(block, rest) -> (block, guardStream identity rest))))
                    (nextBlock stream)
            else pure (Left (HistoryReadFailure (ReleasedSession identity)))

backendFailure :: Client.ClientFailure -> ReadFailure
backendFailure = BackendReadFailure . Text.pack . show

observation :: Wire.Tip -> TipObservation
observation tip =
    TipObservation
        { observedSlot = Wire.tipSlot tip
        , observedHash = Wire.tipBlockHash tip
        , observedHeight = Wire.tipBlockHeight tip
        , observedBlockTime = Wire.tipBlockTime tip
        }

queryOutputs
    :: (Monad m)
    => Client.Koios m -> OutputQuery -> ExceptT ReadFailure m Outputs
queryOutputs client = \case
    AtAddress address -> fetch (Client.addressUtxos client [address]) >>= mergeOutputs
    HoldingAsset asset -> fetch (Client.assetUtxos client [asset]) >>= mergeOutputs
    AtTxIn reference@(TxIn key _) -> do
        -- tx_info includes spent outputs: current visibility requires the
        -- shared UTxO endpoint at the resolved output's address as well.
        infos <- fetch (Client.txInfo client [key])
        produced <- mergeOutputs (concatMap Wire.txInfoOutputs infos)
        case lookup reference produced of
            Nothing -> throwError (MissingOutput reference)
            Just output -> do
                current <-
                    fetch (Client.addressUtxos client [output ^. addrTxOutL])
                        >>= mergeOutputs
                case lookup reference current of
                    Nothing -> throwError (MissingOutput reference)
                    Just actual | actual /= output -> throwError (ConflictingOutput reference)
                    Just _ -> pure [(reference, output)]
    AnyOf queries ->
        traverse (queryOutputs client) (NE.toList queries)
            >>= mergeOutputs . concat
    AllOf queries -> do
        found <- traverse (queryOutputs client) (NE.toList queries)
        combined <- mergeOutputs (concat found)
        pure
            [ pair
            | pair@(reference, _) <- combined
            , all (elem reference . map fst) found
            ]
  where
    fetch = ExceptT . fmap (first backendFailure)

mergeOutputs :: (Monad m) => Outputs -> ExceptT ReadFailure m Outputs
mergeOutputs = fmap Map.toAscList . foldl step (pure Map.empty)
  where
    step accumulated (reference, output) = do
        known <- accumulated
        case Map.lookup reference known of
            Just other | other /= output -> throwError (ConflictingOutput reference)
            _ -> pure (Map.insert reference output known)
