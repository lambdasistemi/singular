{-# LANGUAGE RankNTypes #-}

{- | Raw builder inputs. Evaluation and time conversion always use the
production common services; this fixture supplies no derived answers.
-}
module Singular.Registry.StubSession
    ( stubSession
    , servingSession
    , withParameters
    , withTime
    , withAddressOutputs
    , withResolvedOutputs
    , withTip
    ) where

import Cardano.Ledger.Api.PParams (emptyPParams)
import Cardano.Ledger.TxIn (TxIn)
import Cardano.Slotting.Slot (SlotNo (..))
import Control.Exception (finally)
import Control.Tracer (nullTracer)
import Data.Bifunctor qualified
import Data.ByteString qualified as BS
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.Unique (hashUnique, newUnique)
import Singular.Registry.Evidence
    ( Evidenced (..)
    , NoWitness
    , SessionBinding (..)
    , SessionId (..)
    )
import Singular.Registry.Ledger (Addr, ConwayEra, PParams)
import Singular.Registry.LedgerProvider
import Singular.Registry.NetworkTime (NetworkTime)

stubSession :: Session NoWitness IO
stubSession =
    Session
        { sessionNetwork = Network 42
        , sessionId = SessionId "raw-builder-fixture"
        , sessionBinding = Unbound
        , sessionTracer = nullTracer
        , outputs =
            const (pure (Left (BackendReadFailure "fixture supplies no outputs")))
        , protocolParameters = pure (Right (Evidenced emptyPParams Nothing))
        , tipObservation =
            pure
                ( Right
                    (Evidenced (TipObservation (SlotNo 1) (BS.replicate 32 0) 1 0) Nothing)
                )
        , networkTime =
            pure (Left (BackendReadFailure "fixture supplies no time context"))
        , scriptRegistered =
            const
                (pure (Left (BackendReadFailure "fixture supplies no registration")))
        , history = \_ _ ->
            pure
                ( Left
                    (HistoryReadFailure (BackendReadFailure "fixture supplies no history"))
                )
        }

withParameters
    :: PParams ConwayEra -> Session NoWitness IO -> Session NoWitness IO
withParameters supplied session =
    session
        { protocolParameters = pure (Right (Evidenced supplied Nothing))
        }

withTime
    :: IO NetworkTime -> Session NoWitness IO -> Session NoWitness IO
withTime supplied session =
    session{networkTime = fmap (Right . (`Evidenced` Nothing)) supplied}

withTip
    :: TipObservation -> Session NoWitness IO -> Session NoWitness IO
withTip supplied session = session{tipObservation = pure (Right (Evidenced supplied Nothing))}

withAddressOutputs
    :: (Addr -> IO Outputs) -> Session NoWitness IO -> Session NoWitness IO
withAddressOutputs supplied session = session{outputs = query}
  where
    query (AtAddress address) = fmap (Right . (`Evidenced` Nothing)) (supplied address)
    query (AnyOf queries) = joinQueries False query queries
    query (AllOf queries) = joinQueries True query queries
    query requested = outputs session requested

withResolvedOutputs
    :: (Set.Set TxIn -> IO Outputs)
    -> Session NoWitness IO
    -> Session NoWitness IO
withResolvedOutputs supplied session = session{outputs = query}
  where
    query requested | Just wanted <- references requested = do
        found <- supplied wanted
        pure $ case Set.toAscList (wanted Set.\\ Set.fromList (map fst found)) of
            missing : _ -> Left (MissingOutput missing)
            [] -> Right (Evidenced found Nothing)
    query requested = outputs session requested
    references (AtTxIn reference) = Just (Set.singleton reference)
    references (AnyOf queries) = Set.unions <$> traverse references (NE.toList queries)
    references _ = Nothing

joinQueries
    :: Bool
    -> (OutputQuery -> IO (Either ReadFailure (Evidenced NoWitness Outputs)))
    -> NE.NonEmpty OutputQuery
    -> IO (Either ReadFailure (Evidenced NoWitness Outputs))
joinQueries intersect query queries = do
    results <- traverse query (NE.toList queries)
    pure $ do
        found <- traverse (fmap value) results
        combined <- foldMapOutputs (concat found)
        pure $
            Evidenced
                [ pair
                | pair@(reference, _) <- Map.toAscList combined
                , not intersect || all (elem reference . map fst) found
                ]
                Nothing
  where
    foldMapOutputs = go Map.empty
    go kept [] = Right kept
    go kept ((reference, output) : rest) = case Map.lookup reference kept of
        Just previous | previous /= output -> Left (ConflictingOutput reference)
        _ -> go (Map.insert reference output kept) rest

-- | Fresh, guarded identity for each fixture acquisition; no production View.
servingSession
    :: Session NoWitness IO -> (Network, LedgerProvider NoWitness IO)
servingSession supplied = (configured, provider)
  where
    configured = sessionNetwork supplied
    provider =
        LedgerProvider
            { acquire = \request action -> case request of
                Latest wanted
                    | wanted /= configured -> pure (Left (WrongNetwork configured wanted))
                AtPoint wanted _
                    | wanted /= configured -> pure (Left (WrongNetwork configured wanted))
                AtPoint _ point -> pure (Left (PointNotSupported point))
                Latest _ -> do
                    unique <- hashUnique <$> newUnique
                    open <- newIORef True
                    let identity = SessionId ("raw-fixture-" <> Text.pack (show unique))
                        guarded readFact =
                            readIORef open >>= \alive ->
                                if alive then readFact else pure (Left (ReleasedSession identity))
                        guardedHistory readBlocks =
                            readIORef open >>= \alive ->
                                if alive
                                    then readBlocks
                                    else pure (Left (HistoryReadFailure (ReleasedSession identity)))
                        guardedStream stream = HistoryStream $ guardedHistory $ do
                            result <- nextBlock stream
                            pure
                                ( fmap
                                    (fmap (\pair -> pair `seq` Data.Bifunctor.second guardedStream pair))
                                    result
                                )
                        acquired =
                            supplied
                                { sessionId = identity
                                , outputs = guarded . outputs supplied
                                , protocolParameters = guarded (protocolParameters supplied)
                                , tipObservation = guarded (tipObservation supplied)
                                , networkTime = guarded (networkTime supplied)
                                , scriptRegistered = guarded . scriptRegistered supplied
                                , history = \asset range ->
                                    guardedHistory $
                                        fmap (fmap guardedStream) (history supplied asset range)
                                }
                    (Right <$> action acquired) `finally` writeIORef open False
            , submitTx = \wanted _ ->
                pure $
                    if wanted /= configured
                        then SubmitWrongNetwork configured wanted
                        else SubmitFailed "raw builder fixture has no submitter"
            }
