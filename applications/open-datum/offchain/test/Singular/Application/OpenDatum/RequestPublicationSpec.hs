{- |
Module      : Singular.Application.OpenDatum.RequestPublicationSpec
Description : The scripts of open datum are published once and reused by the later registries
License     : Apache-2.0

As the creator of the first registry of open datum I publish the state script
and the request script as reference scripts, in two transactions. As the creator
of a later registry I find the live copies, publish nothing, and create my
registry from them: no script travels in the transaction, and both compiled
validators accept it.
-}
module Singular.Application.OpenDatum.RequestPublicationSpec
    ( spec
    ) where

import Data.List (sort)
import Data.Map.Strict qualified as Map
import Lens.Micro ((^.))
import Test.Hspec

import Cardano.Ledger.Api.PParams (ppMaxTxSizeL)
import Cardano.Ledger.Api.Tx (sizeTxF, txIdTx, witsTxL)
import Cardano.Ledger.Api.Tx.Wits (scriptTxWitsL)
import Cardano.Ledger.BaseTypes (TxIx (..))
import Cardano.Ledger.Core (hashScript)
import Cardano.Ledger.TxIn (TxIn (..))

import Singular.Application.OpenDatum.CreationWorld
import Singular.Application.OpenDatum.Requests.Script
    ( RequestScript (..)
    , ScriptSource (..)
    )
import Singular.Registry.SessionIO qualified as SessionIO
import Singular.State.Publication
    ( Publication (..)
    , References (..)
    , planNextReference
    )
import Singular.State.Script (StateScript (..))
import Singular.State.Script qualified as State

spec :: Spec
spec = do
    describe "the first registry of open datum" $ do
        it
            "publishes the state script, then the request script, each in a transaction that fits the ledger"
            $ do
                world <- newCreation
                limit <-
                    withSession world (fmap (^. ppMaxTxSizeL) . SessionIO.parameters)
                References{referencesLive = live, referencesPublication = publication} <-
                    planned world
                live `shouldBe` []
                Publication stateTx stateLocated <- expectPublication publication
                map fst stateLocated
                    `shouldBe` [hashScript (ssScript (crState world))]
                soundnessProblems world stateTx `shouldReturn` []
                stateTx ^. sizeTxF `shouldSatisfy` (<= fromIntegral limit)
                applyTx world stateTx
                References{referencesLive = liveState, referencesPublication = next} <-
                    planned world
                map fst liveState `shouldBe` [hashScript (ssScript (crState world))]
                Publication requestTx requestLocated <- expectPublication next
                map fst requestLocated
                    `shouldBe` [hashScript (rsScript (crRequest world))]
                soundnessProblems world requestTx `shouldReturn` []
                requestTx ^. sizeTxF `shouldSatisfy` (<= fromIntegral limit)
                txIdTx requestTx `shouldNotBe` txIdTx stateTx
                -- These are computed from the actual transactions, not fixtures' sizes.
                putStrLn
                    ( "publication bytes: state="
                        <> show (stateTx ^. sizeTxF)
                        <> ", request="
                        <> show (requestTx ^. sizeTxF)
                    )
                applyTx world requestTx
                References{referencesLive = both, referencesPublication = done} <-
                    planned world
                fmap publicationTx done `shouldBe` Nothing
                sort (map fst both) `shouldBe` sort (wanted world)
                sort [ref | (_, (ref, _)) <- both]
                    `shouldBe` sort (map snd (stateLocated <> requestLocated))

    describe "a later registry of open datum" $ do
        it
            "creates its registry from the live copies, with no script in the transaction"
            $ do
                world <- newCreation
                References{referencesLive = _, referencesPublication = first} <-
                    planned world
                Publication stateTx _ <- expectPublication first
                applyTx world stateTx
                References{referencesLive = _, referencesPublication = second} <-
                    planned world
                Publication published located <- expectPublication second
                applyTx world published
                References{referencesLive = live, referencesPublication = later} <-
                    planned world
                fmap publicationTx later `shouldBe` Nothing
                sort (map fst live) `shouldBe` sort (wanted world)
                -- the creator's change of the publication is the seed of the new registry
                let seed = TxIn (txIdTx published) (TxIx (fromIntegral (length located)))
                    reference hash = maybe (fail "no live copy") (pure . fst) (lookup hash live)
                stateAt <- reference (hashScript (ssScript (crState world)))
                requestAt <- reference (hashScript (rsScript (crRequest world)))
                let referencing =
                        world
                            { crSeed = seed
                            , crState = (crState world){ssSource = State.Referenced stateAt}
                            , crRequest = (crRequest world){rsSource = Referenced requestAt}
                            }
                (tx, _) <- createRegistry referencing >>= either (fail . show) pure
                Map.null (tx ^. witsTxL . scriptTxWitsL) `shouldBe` True
                judged <- judge referencing tx
                everyScriptAccepts judged `shouldBe` True
                purposesRun judged `shouldBe` [(Mint, 2)]
  where
    planned world =
        withSession world $ \session ->
            planNextReference
                []
                session
                (crBooker world)
                [ssScript (crState world), rsScript (crRequest world)]
                >>= either (fail . show) pure
    wanted world =
        [ hashScript (ssScript (crState world))
        , hashScript (rsScript (crRequest world))
        ]

expectPublication :: Maybe Publication -> IO Publication
expectPublication = maybe (fail "nothing is published") pure
