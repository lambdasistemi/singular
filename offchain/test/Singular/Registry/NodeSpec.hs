{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.Registry.NodeSpec
Description : Which chain a command line and an environment select
License     : Apache-2.0

The mode a runner starts in is decided before anything is spawned or
connected, from the command line and the environment alone. That
decision is pure, so it is checked here without a node: the default is
the factory devnet, all three external settings are required together,
flags beat environment variables, a runner's own arguments are ignored,
and mainnet is refused.
-}
module Singular.Registry.NodeSpec (spec) where

import Data.List (isInfixOf)
import Data.Time.Clock (getCurrentTime)
import Data.Time.Clock.POSIX (utcTimeToPOSIXSeconds)
import Lens.Micro ((&), (.~))
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)

import Cardano.Ledger.Allegra.Scripts (ValidityInterval (..))
import Cardano.Ledger.Api.Era (ConwayEra)
import Cardano.Ledger.Api.Tx (mkBasicTx)
import Cardano.Ledger.Api.Tx.Body (mkBasicTxBody, vldtTxBodyL)
import Cardano.Ledger.Alonzo.Core (TopTx, Tx)
import Cardano.Ledger.BaseTypes (SlotNo (..), StrictMaybe (..))
import Singular.Registry.Node (
    ExternalNode (..),
    NodeMode (..),
    confirmDeadline,
    nodeModeFromArgs,
    txUpperBoundSlot,
 )
import Singular.Registry.Provider qualified as Cage

external :: FilePath -> Word -> FilePath -> NodeMode
external sock magic skey =
    External
        ExternalNode
            { extSocket = sock
            , extMagic = fromIntegral magic
            , extSkeyFile = skey
            }

full :: [String]
full =
    [ "--node-socket"
    , "/run/node.sock"
    , "--network-magic"
    , "1"
    , "--wallet-skey"
    , "joiner.skey"
    ]

fullEnv :: [(String, String)]
fullEnv =
    [ ("SINGULAR_NODE_SOCKET", "/env/node.sock")
    , ("SINGULAR_NETWORK_MAGIC", "2")
    , ("SINGULAR_WALLET_SKEY", "env.skey")
    ]

spec :: Spec
spec = describe "the chain a runner selects" $ do
    it "is the factory devnet when nothing is configured" $
        nodeModeFromArgs [] [] `shouldBe` Right Devnet

    it "ignores a runner's own arguments" $
        nodeModeFromArgs ["run", "CA01", "CG02"] []
            `shouldBe` Right Devnet

    it "is the joiner's node when all three settings are given" $
        nodeModeFromArgs full []
            `shouldBe` Right (external "/run/node.sock" 1 "joiner.skey")

    it "accepts the flag=value spelling" $
        nodeModeFromArgs
            [ "--node-socket=/run/node.sock"
            , "--network-magic=1"
            , "--wallet-skey=joiner.skey"
            ]
            []
            `shouldBe` Right (external "/run/node.sock" 1 "joiner.skey")

    it "reads the environment when no flags are given" $
        nodeModeFromArgs [] fullEnv
            `shouldBe` Right (external "/env/node.sock" 2 "env.skey")

    it "lets a flag override the environment setting it repeats" $
        nodeModeFromArgs full fullEnv
            `shouldBe` Right (external "/run/node.sock" 1 "joiner.skey")

    it "takes a runner's arguments around the flags" $
        nodeModeFromArgs (["run", "CA01"] <> full <> ["--verbose"]) []
            `shouldBe` Right (external "/run/node.sock" 1 "joiner.skey")

    it "refuses a socket without a magic or a key, naming what is missing" $
        case nodeModeFromArgs ["--node-socket", "/run/node.sock"] [] of
            Right mode ->
                fail ("a socket alone selected " <> show mode)
            Left err -> do
                err `shouldSatisfy` isInfixOf "--network-magic"
                err `shouldSatisfy` isInfixOf "partially configured"

    it "refuses a magic and a key without a socket" $
        case nodeModeFromArgs
            ["--network-magic", "1", "--wallet-skey", "j.skey"]
            [] of
            Right mode -> fail ("no socket selected " <> show mode)
            Left err -> err `shouldSatisfy` isInfixOf "--node-socket"

    it "refuses a magic that is not a number" $
        case nodeModeFromArgs
            (["--node-socket", "/s", "--wallet-skey", "j.skey"]
                <> ["--network-magic", "preprod"])
            [] of
            Right mode -> fail ("a non-numeric magic selected " <> show mode)
            Left err -> err `shouldSatisfy` isInfixOf "not a number"

    it "refuses mainnet" $
        case nodeModeFromArgs
            (["--node-socket", "/s", "--wallet-skey", "j.skey"]
                <> ["--network-magic", "764824073"])
            [] of
            Right mode -> fail ("mainnet's magic selected " <> show mode)
            Left err -> err `shouldSatisfy` isInfixOf "mainnet"

    describe "the confirmation deadline" $ do
        it "reads the validity upper bound a transaction pins" $
            txUpperBoundSlot txPinningBound `shouldBe` Just (SlotNo 1000)

        it "sees no bound on a transaction that never expires" $
            txUpperBoundSlot txWithoutBound `shouldBe` Nothing

        it "waits for the bound plus two minutes of the chain's own slots" $ do
            deadline <- confirmDeadline slotProv txPinningBound
            deadline `shouldBe` SlotNo 1120

        it "waits for the fixed window when no bound is pinned" $ do
            deadline <- confirmDeadline slotProv txWithoutBound
            now <- getCurrentTime
            let nowMs = round (utcTimeToPOSIXSeconds now * 1000) :: Integer
            deadline
                `shouldBe` SlotNo (fromIntegral (nowMs `div` 1000 + 300))

-- A provider whose chain numbers one slot per second. Only the
-- time-to-slot conversion is ever called.
slotProv :: Cage.Provider IO
slotProv =
    Cage.Provider
        { Cage.queryUTxOs = \_ -> pure []
        , Cage.queryProtocolParams = pure (error "unused")
        , Cage.evaluateTx = \_ -> pure (error "unused")
        , Cage.posixMsToSlot = pure . SlotNo . fromIntegral . (`div` 1000)
        , Cage.posixMsCeilSlot =
            pure . SlotNo . fromIntegral . (\ms -> (ms + 999) `div` 1000)
        }

txPinningBound :: Tx TopTx ConwayEra
txPinningBound =
    mkBasicTx
        ( mkBasicTxBody
            & vldtTxBodyL
                .~ ValidityInterval SNothing (SJust 1000)
        )

txWithoutBound :: Tx TopTx ConwayEra
txWithoutBound = mkBasicTx mkBasicTxBody
