{-# LANGUAGE ScopedTypeVariables #-}

{- |
Module      : Singular.Application.OpenDatum.ActorDirectorySpec
Description : Registry resolution does not depend on an actor directory
License     : Apache-2.0

The retained resolver reads registry identity from the supplied chain
fixture. Local registry files do not affect its answer.
-}
module Singular.Application.OpenDatum.ActorDirectorySpec (spec) where

import Cardano.Ledger.Core (Script, hashScript)
import Cardano.Ledger.TxIn (TxIn (..))
import Data.IORef (newIORef)
import Data.Map.Strict qualified as Map (fromList)
import Data.Set qualified as Set (singleton)
import Data.Text qualified as T (pack)
import Singular.Application.OpenDatum.StateTokenFixture
    ( Chain (chainCarriers, chainOutputs)
    , bootCfg
    , bootScripts
    , carrierOf
    , chainSession
    , honestChain
    , refOf
    , release
    , token
    )
import Singular.Application.OpenDatum.Value
    ( openDatumApplication
    )
import Singular.CLI.Command (RegistryAccess (..))
import Singular.CLI.Live (Saved (..), resolveSaved)
import Singular.CLI.Registry (refuseExisting)
import Singular.Registry.Config (CageConfig (..))
import Singular.Registry.Ledger (ConwayEra, TokenId (..))
import Singular.Registry.StateToken (ReferenceRole (..))
import System.Directory (listDirectory)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec
    ( Spec
    , describe
    , it
    , shouldBe
    , shouldReturn
    , shouldSatisfy
    )

spec :: Spec
spec = do
    directories

ours :: RegistryAccess
ours = RegistryAccess{accessToken = token}

directories :: Spec
directories = describe "the actor's directory" $ do
    it
        "may be empty: the registry resolves from the token, and nothing is written"
        $ withSystemTempDirectory "actor"
        $ \dir -> do
            saved <- resolveIn dir
            savedToken saved `shouldBe` tokenId
            pinsOf (savedCfg saved) `shouldBe` pinsOf bootCfg
            map fst (savedRefs saved) `shouldBe` [carrierIn RoleApplication]
            listDirectory dir `shouldReturn` []
    it
        "is never an input: a registry.json from another registry changes nothing"
        $ withSystemTempDirectory "actor"
        $ \dir -> do
            writeFile
                (dir </> "registry.json")
                "{\"confDeployment\":{\"depCageToken\":\"00\"}}"
            saved <- resolveIn dir
            savedToken saved `shouldBe` tokenId
            pinsOf (savedCfg saved) `shouldBe` pinsOf bootCfg
            map fst (savedRefs saved) `shouldBe` [carrierIn RoleApplication]
    it
        "may hold a registry.json and still start a create; a journal or a pending identity refuse it"
        $ withSystemTempDirectory "actor"
        $ \dir -> do
            writeFile (dir </> "registry.json") "{}"
            refuseExisting dir `shouldReturn` Right ()
            writeFile (dir </> "journal.jsonl") ""
            refuseExisting dir
                >>= (`shouldSatisfy` either (const True) (const False))
  where
    tokenId = let (_, name) = token in TokenId name
    pinsOf c =
        [ cfgApplicationPolicy c
        , cfgActivePolicy c
        ]
    resolveIn dir = do
        logRef <- newIORef []
        let chain =
                honestChain
                    { chainOutputs =
                        Map.fromList
                            [(carrierIn role, carrierOf script) | (role, script) <- published]
                            <> chainOutputs honestChain
                    , chainCarriers = \h ->
                        [ (carrierIn role, carrierOf script)
                        | (role, script) <- published
                        , hashScript script == h
                        ]
                    }
        resolveSaved
            openDatumApplication
            dir
            release
            ours
            (Set.singleton RoleApplication)
            Nothing
            (chainSession logRef chain)

-- | The six published scripts by role.
published :: [(ReferenceRole, Script ConwayEra)]
published = zip [minBound .. maxBound] (map snd bootScripts)

carrierIn :: ReferenceRole -> TxIn
carrierIn role = refOf (T.pack (replicate 63 'e' <> show (fromEnum role)) <> "#0")
