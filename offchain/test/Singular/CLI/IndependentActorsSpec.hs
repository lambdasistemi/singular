{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

{- |
Module      : Singular.CLI.IndependentActorsSpec
Description : Independent public replay and cross-actor command decisions
License     : Apache-2.0

Component fixtures contain CBOR transactions and resolved ledger outputs, not
joined directories or copied registry identities. Each actor acquires its own
public-history session. Roots and proofs come from the existing MPF producer.
These rows exercise replay, speculative termination proofs, controller and
request-window decisions; they do not claim a signed fold, refund or CLI join.
The packaged two-terminal journey retains those integrations as pending #437.
-}
module Singular.CLI.IndependentActorsSpec (spec) where

import Cardano.Ledger.Alonzo.Scripts (AsIx (..))
import Cardano.Ledger.Alonzo.TxWits (Redeemers (..))
import Cardano.Ledger.Api.Scripts.Data (Data (..))
import Cardano.Ledger.Api.Tx (bodyTxL, mkBasicTx, txIdTx, witsTxL)
import Cardano.Ledger.Api.Tx.Body
    ( inputsTxBodyL
    , mintTxBodyL
    , mkBasicTxBody
    , outputsTxBodyL
    )
import Cardano.Ledger.Api.Tx.Out (TxOut, datumTxOutL, mkBasicTxOut)
import Cardano.Ledger.Api.Tx.Wits (rdmrsTxWitsL)
import Cardano.Ledger.BaseTypes (Network (Testnet), TxIx (..))
import Cardano.Ledger.Binary (serialize)
import Cardano.Ledger.Conway.Scripts (ConwayPlutusPurpose (..))
import Cardano.Ledger.Core (eraProtVerHigh)
import Cardano.Ledger.Mary.Value (MaryValue (..), MultiAsset (..))
import Cardano.Ledger.Plutus.ExUnits (ExUnits (..))
import Cardano.Ledger.TxIn (TxIn (..))
import Cardano.Tx.Ledger (ConwayTx)
import Control.Exception (try)
import Control.Monad (foldM, forM_)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BL
import Data.ByteString.Short qualified as SBS
import Data.Foldable (toList)
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.List (elemIndex, isInfixOf)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Sequence.Strict qualified as StrictSeq
import Data.Set qualified as Set
import Data.Text qualified as T
import Lens.Micro ((&), (.~), (^.))
import PlutusCore.Data qualified as PLC
import Singular.Application.OpenDatum.Envelope (Envelope (..))
import Singular.CLI.FoldRules (FoldKind (FoldTermination), foldKind)
import Singular.CLI.InsertEnvelope (insertEnvelope)
import Singular.CLI.Live (failTrie)
import Singular.CLI.Plan (controllerCheck)
import Singular.CLI.Receipt (OutcomeClass (..), exitCodeOf)
import Singular.CLI.ReclaimRules qualified as Reclaim
import Singular.CLI.RejectRules qualified as Reject
import Singular.CLI.RequestWindow (Bounds (..), windowOf)
import Singular.CLI.Session (CommandFailure (..))
import Singular.Registry.AssetName (deriveAssetName)
import Singular.Registry.Config (CageConfig (..), bootStateFromCfg)
import Singular.Registry.Deployment (parseOutRef)
import Singular.Registry.Evidence (NoWitness)
import Singular.Registry.Ledger
    ( AssetName (..)
    , Coin (..)
    , ConwayEra
    , Root (..)
    , TokenId (..)
    )
import Singular.Registry.LedgerProvider qualified as LP
import Singular.Registry.StubSession (stubSession)
import Singular.Registry.TrieState hiding (StaleState)
import Singular.Registry.TrieState.Lineage (lineageTrieState)
import Singular.Registry.TrieStateSpec (produced)
import Singular.Registry.TxBuilder.BookingFixture qualified as Booking
import Singular.Registry.TxBuilder.Internal
    ( addrFromKeyHashBytes
    , cageAddrFromCfg
    , cagePolicyIdFromCfg
    , mkInlineDatum
    , mkRequestDatumWith
    , scriptHashBytes
    , toPlcData
    , txInToRef
    )
import Singular.Registry.Types
    ( CageDatum (..)
    , MintRedeemer (..)
    , OnChainRoot (..)
    , RequestAction (..)
    , UpdateRedeemer (..)
    , edgeInsertAbsent
    , edgeInsertActive
    , edgeUpdateTerminal
    )
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..))
import Test.Hspec
    ( Spec
    , describe
    , expectationFailure
    , it
    , shouldBe
    , shouldReturn
    , shouldSatisfy
    )

spec :: Spec
spec = describe
    "Two actors use public component facts without a joining fixture"
    $ do
        it "both independently reconstruct every fold's state root" $ do
            rows <- history
            forM_ (zip [0 :: Int ..] rows) $ \(index, (root, record)) -> do
                let material = map snd (take (index + 1) rows)
                control <- lookupEnv "SINGULAR_TWO_ACTOR_UNIT_CONTROL"
                let supplied =
                        if control == Just "withhold-fold" && index > 1
                            then take 1 material <> drop 2 material
                            else material
                forM_ [Alice, Bob] $ \actor -> do
                    calls <- newIORef (0 :: Int)
                    let session = actorSession actor supplied
                        provider =
                            session
                                { LP.history = \asset range -> do
                                    modifyIORef' calls (+ 1)
                                    LP.history session asset range
                                }
                        selected = selection provider root record
                    answer <- withTrieState (lineageTrieState provider) selected $ \snapshot -> do
                        trieRoot snapshot `shouldBe` root
                        coverageTransitions (trieCoverage snapshot) `shouldBe` index
                    answer `shouldBe` Right ()
                    readIORef calls `shouldReturn` 1
        forM_ [(Alice, Bob, 2), (Bob, Alice, 3)] $ \(folder, controller, index) ->
            it
                ( show folder
                    <> " prepares "
                    <> show controller
                    <> "'s termination from its own replay"
                )
                $ do
                    rows <- history
                    let (before, record) = rows !! index
                        (after, _) = rows !! (index + 1)
                        provider = actorSession folder (map snd (take (index + 1) rows))
                    foldKind edgeUpdateTerminal `shouldBe` Right FoldTermination
                    targetKey <- faulted "fold-own-key" (key controller) (key folder)
                    answer <- withTrieState
                        (lineageTrieState provider)
                        (selection provider before record)
                        $ \snapshot -> do
                            leafAt snapshot targetKey `shouldReturn` Right Active
                            proof <- membership snapshot targetKey Active
                            proof
                                `shouldSatisfy` either (const False) (not . BS.null . membershipBytes)
                            walk <-
                                speculateEdges snapshot ((targetKey, edgeUpdateTerminal) :| [])
                            fmap walkRoot walk `shouldBe` Right after
                            -- Preparing the other actor's fold never commits private proof state.
                            trieRoot snapshot `shouldBe` before
                            leafAt snapshot (key controller) `shouldReturn` Right Active
                    answer `shouldBe` Right ()
        it
            "withholding a consumed fold refuses HistoryIncomplete before yielding a trie"
            $ do
                rows <- history
                let (root, record) = last rows
                    material = map snd (take 1 rows <> drop 2 rows)
                checkRefusal
                    (actorSession Bob material)
                    root
                    record
                    "HistoryIncomplete"
        it
            "altering a consumed request edge refuses RootDoesNotChain before yielding a trie"
            $ do
                rows <- history
                let (root, record) = last rows
                    change i (_, r) =
                        if i == (1 :: Int)
                            then r{LP.spentOutputs = map alter (LP.spentOutputs r)}
                            else r
                    alter (ref, out)
                        | ref == requestAt Bob edgeInsertActive =
                            (ref, requestOutput Bob edgeInsertAbsent)
                        | otherwise = (ref, out)
                checkRefusal
                    (actorSession Alice (zipWith change [0 ..] rows))
                    root
                    record
                    "RootDoesNotChain"
        forM_ [Alice, Bob] $ \controller -> do
            it
                ( "the shared update/termination check refuses "
                    <> show (other controller)
                    <> " for "
                    <> show controller
                    <> "'s key"
                )
                $ do
                    let envelope =
                            insertEnvelope
                                Booking.cfg
                                token
                                (key controller)
                                (owner controller)
                                2000000
                                (PLC.I 1)
                    signer <-
                        faulted
                            "foreign-controller"
                            (owner controller)
                            (owner (other controller))
                    controllerCheck signer (envControl envelope)
                    refused <-
                        try @CommandFailure
                            (controllerCheck (owner (other controller)) (envControl envelope))
                    case refused of
                        Left (CommandFailure cls why _) -> do
                            cls `shouldBe` ClientRefusal
                            exitCodeOf cls `shouldBe` ExitFailure 10
                            why `shouldSatisfy` isInfixOf "controller"
                        Right () -> expectationFailure "a foreign controller was accepted"
            it
                ( show controller
                    <> " reclaims its request; the other actor is refused by owner"
                )
                $ do
                    let bounds = requestBounds
                        opens = processingEnds bounds
                        closes = retractEnds bounds
                        pending =
                            Just
                                (owner controller, edgeInsertActive, bounds, Just opens, Just closes)
                    signer <-
                        faulted
                            "foreign-reclaim-owner"
                            (owner controller)
                            (owner (other controller))
                    Reclaim.reclaimGate signer pending opens
                        `shouldBe` Right bounds
                    Reclaim.reclaimGate (owner (other controller)) pending opens
                        `shouldBe` Left Reclaim.NotOwner
                    Reclaim.renderReclaimRefusal Reclaim.NotOwner
                        `shouldBe` "retract-owner: this wallet is not the request's owner"
            it
                ( show (other controller)
                    <> " can reject "
                    <> show controller
                    <> "'s expired request and must refund its owner"
                )
                $ do
                    let bounds = requestBounds
                        pending = [(requestRef controller, bounds, Just (retractEnds bounds))]
                        paid = requestValue - tipValue
                    Reject.rejectGate (retractEnds bounds - 1) pending
                        `shouldSatisfy` either (const True) (const False)
                    Reject.rejectGate (retractEnds bounds) pending
                        `shouldBe` Right [(requestRef controller, bounds)]
                    recipient <-
                        faulted
                            "refund-to-folder"
                            (owner controller)
                            (owner (other controller))
                    Reject.refundShape
                        [(owner controller, paid)]
                        [(recipient, paid)]
                        `shouldBe` Right [paid]
                    Reject.refundShape
                        [(owner controller, paid)]
                        [(owner (other controller), paid)]
                        `shouldBe` Left (Reject.WrongRecipient 0)

-- Every byte here is fixture input or output of the existing producer. There
-- is no registry directory, identity file, private envelope store or join call.
faulted :: String -> a -> a -> IO a
faulted name original mutant = do
    control <- lookupEnv "SINGULAR_TWO_ACTOR_UNIT_CONTROL"
    pure (if control == Just name then mutant else original)

data Actor = Alice | Bob deriving stock (Eq, Show)

other :: Actor -> Actor
other Alice = Bob
other Bob = Alice

owner :: Actor -> ByteString
owner Alice = BS.replicate 28 0x11
owner Bob = BS.replicate 28 0x22

key :: Actor -> ByteString
key Alice = "alice-key"
key Bob = "bob-key"

seed :: TxIn
seed = either error id (parseOutRef (T.replicate 64 "1" <> "#0"))

requestRef :: Actor -> TxIn
requestRef actor = either error id (parseOutRef (T.replicate 64 digit <> "#0"))
  where
    digit = if actor == Alice then "a" else "b"

requestAt :: Actor -> Integer -> TxIn
requestAt actor edge = case requestRef actor of
    TxIn tid _ -> TxIn tid (TxIx (fromIntegral edge))

token :: TokenId
token =
    TokenId (AssetName (SBS.toShort (deriveAssetName (txInToRef seed))))

identity :: RegistryIdentity
identity =
    RegistryIdentity
        (StatePolicyId (scriptHashBytes (cfgScriptHash Booking.cfg)))
        (unTokenId token)

requestValue, tipValue :: Integer
requestValue = 3000000
tipValue = let Coin value = defaultTip Booking.cfg in value

requestBounds :: Bounds
requestBounds =
    windowOf
        1000
        (defaultProcessTime Booking.cfg)
        (defaultRetractTime Booking.cfg)

requestOutput :: Actor -> Integer -> TxOut ConwayEra
requestOutput actor edge =
    mkBasicTxOut
        (addrFromKeyHashBytes Testnet (owner actor))
        (MaryValue (Coin requestValue) mempty)
        & datumTxOutL
            .~ mkInlineDatum
                ( mkRequestDatumWith
                    token
                    (addrFromKeyHashBytes Testnet (owner actor))
                    (key actor)
                    edge
                    2000000
                    1000
                    ("", "")
                )

stateOutput :: Root -> TxOut ConwayEra
stateOutput (Root root) =
    mkBasicTxOut
        (cageAddrFromCfg Booking.cfg Testnet)
        ( MaryValue
            (Coin 2000000)
            ( MultiAsset
                ( Map.singleton
                    (cagePolicyIdFromCfg Booking.cfg)
                    (Map.singleton (unTokenId token) 1)
                )
            )
        )
        & datumTxOutL
            .~ mkInlineDatum
                ( toPlcData
                    (StateDatum (bootStateFromCfg Booking.cfg (OnChainRoot root)))
                )

create :: Root -> ConwayTx
create root =
    mkBasicTx
        ( mkBasicTxBody
            & inputsTxBodyL .~ Set.singleton seed
            & mintTxBodyL
                .~ MultiAsset
                    ( Map.singleton
                        (cagePolicyIdFromCfg Booking.cfg)
                        (Map.singleton (unTokenId token) 1)
                    )
            & outputsTxBodyL .~ StrictSeq.singleton (stateOutput root)
        )
        & witsTxL . rdmrsTxWitsL
            .~ Redeemers
                ( Map.singleton
                    (ConwayMinting (AsIx 0))
                    (Data (toPlcData (Minting (txInToRef seed))), ExUnits 0 0)
                )

foldTx :: ConwayTx -> Actor -> Integer -> Root -> ConwayTx
foldTx previous actor edge root =
    mkBasicTx
        ( mkBasicTxBody
            & inputsTxBodyL .~ inputs
            & outputsTxBodyL .~ StrictSeq.singleton (stateOutput root)
        )
        & witsTxL . rdmrsTxWitsL
            .~ Redeemers
                ( Map.singleton
                    (ConwaySpending (AsIx position))
                    (Data (toPlcData (Modify [Update []])), ExUnits 0 0)
                )
  where
    stateIn = TxIn (txIdTx previous) (TxIx 0)
    inputs = Set.fromList [stateIn, requestAt actor edge]
    position =
        maybe
            (error "fixture lost its state input")
            fromIntegral
            (elemIndex stateIn (Set.toAscList inputs))

recordOf :: LP.Outputs -> ConwayTx -> LP.HistoricalTransaction
recordOf spent tx =
    LP.HistoricalTransaction
        (txIdTx tx)
        (BL.toStrict (serialize (eraProtVerHigh @ConwayEra) tx))
        tx
        spent
        []
        [ (TxIn (txIdTx tx) (TxIx index), out)
        | (index, out) <- zip [0 ..] (toList (tx ^. bodyTxL . outputsTxBodyL))
        ]
        True

history :: IO [(Root, LP.HistoricalTransaction)]
history = do
    (_, empty, _) <- produced token []
    let initial = create empty
    (_, rows) <-
        foldM
            next
            ([], [(empty, recordOf [] initial)])
            [ (Bob, edgeInsertActive)
            , (Alice, edgeInsertActive)
            , (Bob, edgeUpdateTerminal)
            , (Alice, edgeUpdateTerminal)
            ]
    pure rows
  where
    next (moves, rows) (actor, edge) = do
        let moves' = moves <> [(key actor, edge)]
            (_, previous) = last rows
        (_, root, _) <- produced token moves'
        let tx = foldTx (LP.historicalTx previous) actor edge root
            spent =
                [
                    ( TxIn (LP.historicalId previous) (TxIx 0)
                    , stateOutput (fst (last rows))
                    )
                , (requestAt actor edge, requestOutput actor edge)
                ]
        pure (moves', rows <> [(root, recordOf spent tx)])

actorSession
    :: Actor -> [LP.HistoricalTransaction] -> LP.Session NoWitness IO
actorSession actor records =
    stubSession
        { LP.sessionId = SessionId (T.pack (show actor))
        , LP.history = \_ _ -> pure (Right (stream (zip [1 ..] records)))
        }
  where
    stream [] = LP.HistoryStream (pure (Right Nothing))
    stream ((height, record) : rest) =
        LP.HistoryStream
            ( pure
                (Right (Just (LP.HistoryBlock height (record :| []), stream rest)))
            )

selection
    :: LP.Session w IO -> Root -> LP.HistoricalTransaction -> TrieSelection
selection session root record =
    TrieSelection
        identity
        ( StatePoint
            (LP.sessionId session)
            (LP.sessionBinding session)
            (TxIn (LP.historicalId record) (TxIx 0))
        )
        root

checkRefusal
    :: LP.Session w IO -> Root -> LP.HistoricalTransaction -> T.Text -> IO ()
checkRefusal session root record name = do
    yielded <- newIORef False
    answer <-
        withTrieState
            (lineageTrieState session)
            (selection session root record)
            (\_ -> modifyIORef' yielded (const True))
    readIORef yielded `shouldReturn` False
    case answer of
        Left refusal -> do
            trieFailureName refusal `shouldBe` name
            received <- try @CommandFailure (failTrie refusal :: IO ())
            case received of
                Left (CommandFailure cls why _) -> do
                    cls `shouldBe` StaleState
                    exitCodeOf cls `shouldBe` ExitFailure 14
                    why `shouldBe` "TrieState " <> T.unpack name
                Right () ->
                    expectationFailure "trie refusal was accepted by the command boundary"
        Right _ ->
            expectationFailure
                "incomplete or altered public history yielded a trie"
