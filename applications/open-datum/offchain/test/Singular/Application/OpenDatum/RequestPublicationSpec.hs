{- |
Module      : Singular.Application.OpenDatum.RequestPublicationSpec
Description : The scripts of open datum are published once and reused by the later registries
License     : Apache-2.0

As the creator of the first registry of open datum I publish the state script
and the request script as reference scripts, in one transaction. As the creator
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

import Cardano.Ledger.Api.Tx (txIdTx, witsTxL)
import Cardano.Ledger.Api.Tx.Wits (scriptTxWitsL)
import Cardano.Ledger.BaseTypes (TxIx (..))
import Cardano.Ledger.Core (hashScript)
import Cardano.Ledger.TxIn (TxIn (..))

import Singular.Application.OpenDatum.CreationWorld
import Singular.Application.OpenDatum.Requests.Script
    ( RequestScript (..)
    , ScriptSource (..)
    )
import Singular.State.Publication
    ( Publication (..)
    , References (..)
    , planReferences
    )
import Singular.State.Script (StateScript (..))
import Singular.State.Script qualified as State

spec :: Spec
spec = do
    describe "the first registry of open datum" $ do
        it
            "publishes the state script and the request script in one transaction that fits the ledger"
            $ do
                world <- newCreation
                References live publication <- planned world
                live `shouldBe` []
                case publication of
                    Nothing -> expectationFailure "nothing is published"
                    Just (Publication tx located) -> do
                        sort (map fst located) `shouldBe` sort (wanted world)
                        soundnessProblems world tx `shouldReturn` []

    describe "a later registry of open datum" $ do
        it
            "creates its registry from the live copies, with no script in the transaction"
            $ do
                world <- newCreation
                References _ first <- planned world
                Publication published located <-
                    maybe (fail "nothing is published") pure first
                applyTx world published
                References live later <- planned world
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
            planReferences
                session
                (crBooker world)
                [ssScript (crState world), rsScript (crRequest world)]
                >>= either (fail . show) pure
    wanted world =
        [ hashScript (ssScript (crState world))
        , hashScript (rsScript (crRequest world))
        ]
