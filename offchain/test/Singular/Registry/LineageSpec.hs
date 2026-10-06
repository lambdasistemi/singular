{-# LANGUAGE OverloadedStrings #-}

{- | The history adapter's refusals execute the acquired session's history
capability. These are component controls, without ledger acceptance claims.
-}
module Singular.Registry.LineageSpec (spec) where

import Cardano.Ledger.TxIn (TxId, TxIn (..))
import Control.Exception (try)
import Control.Monad (forM_)
import Data.Aeson (Value (..), toJSON)
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString qualified as BS
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.List.NonEmpty (NonEmpty (..))
import MPF.Backend.Pure (emptyMPFInMemoryDB)
import Singular.CLI.Live (failTrie)
import Singular.CLI.Receipt (OutcomeClass (..), exitCodeOf)
import Singular.CLI.Session (CommandFailure (..))
import Singular.Registry.Deployment (parseOutRef)
import Singular.Registry.Ledger (AssetName (..))
import Singular.Registry.LedgerProvider qualified as LP
import Singular.Registry.StubSession (stubSession)
import Singular.Registry.Trie.Pure (rootFromDb)
import Singular.Registry.TrieState
import Singular.Registry.TrieState.Lineage (lineageTrieState)
import System.Exit (ExitCode (..))
import Test.Hspec

spec :: Spec
spec = describe "An acquired session supplies the registry trie" $ do
    forM_ failures $ \failure ->
        it
            ("retains every datum of " <> show failure <> " in HistoryIncomplete") $ do
            calls <- newIORef []
            let session =
                    stubSession
                        { LP.history = \asset range -> do
                            modifyIORef' calls (<> [(asset, range)])
                            pure (Left failure)
                        }
                capability = lineageTrieState session
                selected = selection (LP.sessionId session)
            withTrieState capability selected (const (pure ()))
                `shouldReturn` Left
                    ( HistoryIncomplete
                        identity
                        (transactionOf failure)
                        (ProviderHistoryFailure failure)
                    )
            queried <- readIORef calls
            length queried `shouldBe` 1
            map snd queried `shouldBe` [LP.HistoryRange Nothing Nothing]
    forM_ failures $ \failure ->
        it
            ( "prints the retained provider failure and its existing outcome: "
                <> show failure
            ) $ do
            let refused =
                    HistoryIncomplete
                        identity
                        (transactionOf failure)
                        (ProviderHistoryFailure failure)
                (wanted, status) = case failure of
                    LP.HistoryReadFailure{} -> (ClientRefusal, ExitFailure 10)
                    _ -> (StaleState, ExitFailure 14)
            caught <- try (failTrie refused :: IO ())
            case caught of
                Left (CommandFailure cls why fields) -> do
                    cls `shouldBe` wanted
                    exitCodeOf cls `shouldBe` status
                    why `shouldBe` "TrieState HistoryIncomplete"
                    case lookup "trieRefusal" fields of
                        Just (Object payload) ->
                            KM.lookup "providerFailure" payload
                                `shouldBe` Just (toJSON (show failure))
                        other -> expectationFailure ("missing provider payload: " <> show other)
                Right () -> expectationFailure "a provider failure was accepted"
    it "refuses another session before requesting history" $ do
        calls <- newIORef (0 :: Int)
        let session =
                stubSession
                    { LP.history = \_ _ -> do
                        modifyIORef' calls (+ 1)
                        pure (Left (head failures))
                    }
        answer <-
            withTrieState
                (lineageTrieState session)
                (selection (SessionId "another-session"))
                (const (pure ()))
        case answer of
            Left StaleState{} -> pure ()
            _ ->
                expectationFailure ("another session was admitted: " <> show answer)
        readIORef calls `shouldReturn` 0
    it "refuses an empty history rather than serving an empty trie" $ do
        let session =
                stubSession
                    { LP.history = \_ _ -> pure (Right (LP.HistoryStream (pure (Right Nothing))))
                    }
        answer <-
            withTrieState
                (lineageTrieState session)
                (selection (LP.sessionId session))
                (const (pure ()))
        answer
            `shouldBe` Left (HistoryIncomplete identity (Just firstId) MissingTransaction)
    it
        "acceptObservedFold stores nothing and never substitutes for history" $ do
        calls <- newIORef (0 :: Int)
        let failure = head failures
            session =
                stubSession
                    { LP.history = \_ _ -> do
                        modifyIORef' calls (+ 1)
                        pure (Left failure)
                    }
            capability = lineageTrieState session
            chosen = selection (LP.sessionId session)
        acceptObservedFold
            capability
            (ObservedFold chosen chosen (("key", 1) :| []))
            `shouldReturn` Right ()
        forM_ [1 :: Int, 2] $ \_ ->
            withTrieState capability chosen (const (pure ()))
                `shouldReturn` Left
                    (HistoryIncomplete identity Nothing (ProviderHistoryFailure failure))
        readIORef calls `shouldReturn` 2

identity :: RegistryIdentity
identity =
    RegistryIdentity
        (StatePolicyId (BS.replicate 28 1))
        (AssetName "component-registry")

selection :: SessionId -> TrieSelection
selection sid =
    TrieSelection
        identity
        (StatePoint sid Unbound firstOutput)
        (rootFromDb emptyMPFInMemoryDB)

firstOutput :: TxIn
firstOutput =
    either
        error
        id
        ( parseOutRef
            "1111111111111111111111111111111111111111111111111111111111111111#0"
        )

firstId :: TxId
firstId = case firstOutput of TxIn tid _ -> tid

secondId :: TxId
secondId = case either
    error
    id
    ( parseOutRef
        "2222222222222222222222222222222222222222222222222222222222222222#0"
    ) of
    TxIn tid _ -> tid

failures :: [LP.HistoryFailure]
failures =
    [ LP.HistoryReadFailure
        (LP.BackendReadFailure "provider withheld block 42")
    , LP.HistoryReadFailure (LP.ReleasedSession (SessionId "released"))
    , LP.HistoryReadFailure (LP.MissingOutput firstOutput)
    , LP.HistoryReadFailure (LP.ConflictingOutput firstOutput)
    , LP.HistoryDependencyCycle (firstId :| [secondId])
    , LP.MissingInBlockParent firstId secondId
    , LP.DuplicateSpend firstOutput
    , LP.HistoryMaterialMismatch firstId "resolved output differs"
    , LP.HistoryOrderMismatch 43 42
    ]

transactionOf :: LP.HistoryFailure -> Maybe TxId
transactionOf (LP.HistoryDependencyCycle (tid :| _)) = Just tid
transactionOf (LP.MissingInBlockParent tid _) = Just tid
transactionOf (LP.HistoryMaterialMismatch tid _) = Just tid
transactionOf (LP.DuplicateSpend (TxIn tid _)) = Just tid
transactionOf (LP.HistoryReadFailure (LP.MissingOutput (TxIn tid _))) = Just tid
transactionOf (LP.HistoryReadFailure (LP.ConflictingOutput (TxIn tid _))) = Just tid
transactionOf _ = Nothing
