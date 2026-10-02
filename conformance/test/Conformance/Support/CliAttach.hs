{-# LANGUAGE TypeApplications #-}

{- | What a take on an existing registry decides before it acts: the bound on
a refused transaction's collateral, the outcomes it may go on from, and the
one request it may retract.
-}
module Conformance.Support.CliAttach (spec) where

import Conformance.Cli.Admission
    ( admit
    , blake2b256Hex
    , sha256Hex
    , txIdHexOf
    )
import Conformance.Cli.Attach
    ( LiveRequest (..)
    , continues
    , fundingProblem
    , reclaimTarget
    , submissionProblem
    )
import Conformance.Cli.Controls
    ( Account (..)
    , Observation (..)
    , Receipt (..)
    , Requirement (IndexerAgrees)
    , check
    , emptyReceipt
    )
import Data.Aeson (Key, Value (..), encode, object, toJSON, (.=))
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Lazy qualified as BL
import Data.Either (isLeft)
import Data.List (isInfixOf)
import Data.Maybe (fromMaybe, isJust, isNothing)
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Lens.Micro ((&), (.~))
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)
import Text.Printf (printf)

import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.Api.Tx (mkBasicTx, txIdTx)
import Cardano.Ledger.Api.Tx.Body
    ( collateralInputsTxBodyL
    , collateralReturnTxBodyL
    , feeTxBodyL
    , inputsTxBodyL
    , mkBasicTxBody
    , totalCollateralTxBodyL
    )
import Cardano.Ledger.Api.Tx.Out (mkBasicTxOut)
import Cardano.Ledger.BaseTypes
    ( Network (Testnet)
    , StrictMaybe (..)
    , TxIx (..)
    )
import Cardano.Ledger.Binary (serialize')
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Core (eraProtVerHigh)
import Cardano.Ledger.Mary.Value (MaryValue (..))
import Cardano.Ledger.TxIn (TxIn (..))
import Cardano.Tx.Ledger (ConwayTx)
import Singular.Registry.Deployment (renderOutRef)
import Singular.Registry.Ledger (ConwayEra)
import Singular.Registry.TxBuilder.Internal (addrFromKeyHashBytes)

-- | A distinct output reference, named by the ledger's own transaction id.
reference :: Integer -> TxIn
reference n =
    TxIn
        (txIdTx (mkBasicTx (mkBasicTxBody & feeTxBodyL .~ Coin n) :: ConwayTx))
        (TxIx 0)

wallet :: Addr
wallet = addrFromKeyHashBytes Testnet (BS.replicate 28 7)

-- | A transaction that puts collateral at risk, as given.
withCollateral :: Maybe Integer -> Maybe Integer -> ConwayTx
withCollateral total returned =
    mkBasicTx
        ( mkBasicTxBody
            & collateralInputsTxBodyL .~ Set.singleton (reference 1)
            & totalCollateralTxBodyL
                .~ maybe SNothing (SJust . Coin) total
            & collateralReturnTxBodyL
                .~ maybe
                    SNothing
                    (\c -> SJust (mkBasicTxOut wallet (MaryValue (Coin c) mempty)))
                    returned
        )

spec :: Spec
spec = do
    describe
        "A take's refused transaction is sent only under an explicit bound"
        $ do
            let allowed = Just 5_000_000
                problem = submissionProblem True
            it
                "sends one that states its collateral within the bound and returns the rest"
                $ problem allowed (withCollateral (Just 300_000) (Just 9_000_000))
                    `shouldBe` Nothing
            it
                "refuses to sign anything when the run set no allowance, whatever the body states"
                $ do
                    problem Nothing (withCollateral (Just 300_000) (Just 9_000_000))
                        `shouldSatisfy` isJust
                    problem Nothing (mkBasicTx mkBasicTxBody) `shouldSatisfy` isJust
            it "refuses a total over the bound, no total, and no return" $ do
                problem allowed (withCollateral (Just 9_000_000) (Just 9_000_000))
                    `shouldSatisfy` isJust
                problem allowed (withCollateral Nothing (Just 9_000_000))
                    `shouldSatisfy` isJust
                problem allowed (withCollateral (Just 300_000) Nothing)
                    `shouldSatisfy` isJust
            it
                "leaves a development run, which sets no allowance and requires none, as it was"
                $ do
                    submissionProblem False Nothing (withCollateral Nothing Nothing)
                        `shouldBe` Nothing
            it "names a transaction that puts no collateral at risk as bounded" $
                problem allowed (mkBasicTx mkBasicTxBody) `shouldBe` Nothing

    describe "A take goes on only from an outcome its story can judge" $ do
        it "goes on from the outcomes a requirement judges" $
            mapM_
                (\o -> (o, continues o) `shouldBe` (o, True))
                ["success", "partial", "accepted", "ledger-refused", "observed"]
        it
            "stops at uncertainty and at setup, client, budget and stale outcomes"
            $ mapM_
                (\o -> (o, continues o) `shouldBe` (o, False))
                [ "client-error"
                , "submit-unknown"
                , "unconfirmed"
                , "timeout"
                , "node-unavailable"
                , "concurrent-writer"
                , "stale-state"
                , "client-refusal"
                , "ledger-refusal"
                , "provider-mismatch"
                , "provider-unavailable"
                , ""
                ]

    describe
        "A retraction spends the one request its own insertion left pending"
        $ do
            let key = "demo1-take"
                keyBytes = "demo1-take" :: BS.ByteString
                owner = BS.replicate 28 7
                stranger = BS.replicate 28 9
                partial =
                    (emptyReceipt 4 "run insert" "permanent" key)
                        { rcOutcome = "partial"
                        , rcPendingRequest = Just "r0#0"
                        }
                seen =
                    (emptyReceipt 6 "observe" "permanent" key)
                        { rcOutcome = "observed"
                        , rcObservation =
                            Just
                                Observation
                                    { obRoot = "aa"
                                    , obHolding = Just "h#1"
                                    , obHoldingLovelace = Just 4_000_000
                                    , obPending = ["r0#0"]
                                    , obPendingLovelace = 3_000_000
                                    , obWalletLovelace = 100
                                    , obLeaf = Just "active"
                                    }
                        }
                mine ref = LiveRequest ref keyBytes owner
                target = reclaimTarget keyBytes owner
                honest = target partial seen "aa" ["r0#0"] [mine "r0#0"]
            it
                "names the request the insertion named, in the state the readback saw"
                $ honest `shouldBe` Right "r0#0"
            it
                "refuses when that request is gone, though another of this key and owner is there"
                $ do
                    -- the substitution the take must never make
                    target partial seen "aa" ["r1#0"] [mine "r1#0"] `shouldSatisfy` isLeft
            it "refuses when another request has appeared beside it" $
                target partial seen "aa" ["r0#0", "r1#0"] [mine "r0#0", mine "r1#0"]
                    `shouldSatisfy` isLeft
            it "refuses when it is another key's or another owner's request" $ do
                target partial seen "aa" ["r0#0"] [LiveRequest "r0#0" "other" owner]
                    `shouldSatisfy` isLeft
                target
                    partial
                    seen
                    "aa"
                    ["r0#0"]
                    [LiveRequest "r0#0" keyBytes stranger]
                    `shouldSatisfy` isLeft
            it "refuses when the registry's root moved since the readback" $
                target partial seen "bb" ["r0#0"] [mine "r0#0"] `shouldSatisfy` isLeft
            it
                "refuses an output at the request address that does not read as a request"
                $ target partial seen "aa" ["r0#0"] [] `shouldSatisfy` isLeft
            it
                "refuses when the insertion's receipt names no request or did not stop partial"
                $ do
                    target
                        partial{rcPendingRequest = Nothing}
                        seen
                        "aa"
                        ["r0#0"]
                        [mine "r0#0"]
                        `shouldSatisfy` isLeft
                    target partial{rcOutcome = "success"} seen "aa" ["r0#0"] [mine "r0#0"]
                        `shouldSatisfy` isLeft
            it
                "refuses when the readback did not see it pending, or is of another key"
                $ do
                    target
                        partial{rcPendingRequest = Just "r9#0"}
                        seen
                        "aa"
                        ["r0#0"]
                        [mine "r0#0"]
                        `shouldSatisfy` isLeft
                    target partial seen{rcKey = "other"} "aa" ["r0#0"] [mine "r0#0"]
                        `shouldSatisfy` isLeft
                    target
                        partial
                        seen{rcObservation = Nothing}
                        "aa"
                        ["r0#0"]
                        [mine "r0#0"]
                        `shouldSatisfy` isLeft

    describe "A retraction's retained body names what it spends" $
        it "reads the spent outputs from the body, not from the receipt" $
            withSystemTempDirectory "attach" $ \work -> do
                createDirectoryIfMissing True (work </> "evidence")
                let spent = reference 3
                    tx =
                        mkBasicTx
                            (mkBasicTxBody & inputsTxBodyL .~ Set.singleton spent)
                            :: ConwayTx
                    body = B16.encode (serialize' (eraProtVerHigh @ConwayEra) tx)
                BS.writeFile (work </> "evidence/body.cbor.hex") body
                let r =
                        (emptyReceipt 7 "reclaim" "permanent" "k")
                            { rcOutcome = "accepted"
                            , rcTxId = Just (txIdHexOf tx)
                            , rcBodyFile = Just "evidence/body.cbor.hex"
                            , rcBodySha256 = Just (sha256Hex body)
                            , rcPendingRequest = Just (T.pack "not-the-spent-one#0")
                            }
                a <- admit work r
                fmap acSpends (rcAccount a) `shouldBe` Just [renderOutRef spent]
                fmap (isNothing . acCollateralTotal) (rcAccount a)
                    `shouldBe` Just True

    describe
        "A take is refused before it writes unless the wallet can fund every action"
        $ do
            let floorSize = 30_000_000
                big = (True, 5_000_000_000)
            it
                "accepts a wallet with one ada-only output of the floor for each returning action and one more"
                $ fundingProblem 7 floorSize (replicate 8 big) `shouldBe` Nothing
            it "refuses one output short, and says how many it found" $
                fundingProblem 7 floorSize (replicate 7 big) `shouldSatisfy` isJust
            it
                "does not count an output that holds an asset or a reference script"
                $ fundingProblem
                    7
                    floorSize
                    (replicate 7 big <> replicate 5 (False, 5_000_000_000))
                    `shouldSatisfy` isJust
            it "does not count an ada-only output under the floor" $
                fundingProblem
                    7
                    floorSize
                    (replicate 7 big <> replicate 5 (True, floorSize - 1))
                    `shouldSatisfy` isJust
            it "counts an output exactly at the floor" $
                fundingProblem 1 floorSize [(True, floorSize), (True, floorSize)]
                    `shouldBe` Nothing

    describe
        "An indexer's record is judged on the facts it keeps, not on what it says of them"
        $ do
            let label = "demo1-take"
                key =
                    T.pack
                        ( concatMap (printf "%02x") (BS.unpack (TE.encodeUtf8 (T.pack label)))
                            :: String
                        )
                policy = T.replicate 28 "cc"
                cbor = "d8799f4164ff"
                other = "d8799f4165ff"
                hashOf c = fromMaybe "" (blake2b256Hex c)
                out = T.replicate 32 "ab" <> "#1"
                inspect =
                    (emptyReceipt 9 "run inspect" "permanent" (T.pack label))
                        { rcOutcome = "success"
                        , rcAdmission = Just []
                        , rcCommand =
                            Just
                                ( object
                                    [ "outcome" .= ("success" :: T.Text)
                                    , "leaf" .= ("active" :: T.Text)
                                    , "key" .= key
                                    , "chainPoint" .= ("1000.aa" :: T.Text)
                                    , "applicationOutput"
                                        .= object
                                            [ "output" .= out
                                            , "datumCbor" .= cbor
                                            , "datumHash" .= hashOf cbor
                                            , "envelope"
                                                .= object
                                                    [ "fields"
                                                        .= [ object
                                                                [ "fields"
                                                                    .= [ object ["int" .= (1 :: Int)]
                                                                       , object ["fields" .= ([] :: [Value])]
                                                                       , object ["bytes" .= policy]
                                                                       ]
                                                                ]
                                                           ]
                                                    ]
                                            ]
                                    ]
                                )
                        }
                -- What tools/demo1_readback.sh writes for koios: the requests and their
                -- answers, what the indexer reported and what the node read, the lag,
                -- the stated comparisons and verdict, here always stated true. The
                -- answer's tip and each holder's index and quantities of the token are
                -- kept as given, raw; trailing fields replace the record's own.
                rawRecord
                    :: T.Text
                    -> T.Text
                    -> Value
                    -> Integer
                    -> [(T.Text, Value, [Value])]
                    -> [(Key, Value)]
                    -> Value
                rawRecord datum recomputed answerTip tip holders replaced =
                    object $
                        [ "provider" .= ("koios" :: T.Text)
                        , "policy" .= policy
                        , "assetName" .= key
                        , "baseUrl" .= ("http://indexer" :: T.Text)
                        , "requests"
                            .= [ object
                                    [ "method" .= ("GET" :: T.Text)
                                    , "url" .= ("http://indexer/tip" :: T.Text)
                                    , "status" .= (200 :: Int)
                                    , "response" .= [object ["abs_slot" .= answerTip]]
                                    ]
                               , object
                                    [ "method" .= ("POST" :: T.Text)
                                    , "url" .= ("http://indexer/asset_utxos" :: T.Text)
                                    , "status" .= (200 :: Int)
                                    , "response"
                                        .= [ object
                                                [ "tx_hash" .= T.takeWhile (/= '#') ref
                                                , "tx_index" .= index
                                                , "datum_hash" .= recomputed
                                                , "inline_datum" .= object ["bytes" .= datum]
                                                , "asset_list"
                                                    .= [ object
                                                            [ "policy_id" .= policy
                                                            , "asset_name" .= key
                                                            , "quantity" .= q
                                                            ]
                                                       | q <- quantities
                                                       ]
                                                ]
                                           | (ref, index, quantities) <- holders
                                           ]
                                    ]
                               ]
                        , "indexer"
                            .= object
                                [ "output" .= out
                                , "datumCbor" .= datum
                                , "datumHashRecomputed" .= recomputed
                                , "tipSlot" .= T.pack (show tip)
                                ]
                        , "node"
                            .= object
                                [ "output" .= out
                                , "datumCbor" .= cbor
                                , "datumHash" .= hashOf cbor
                                , "chainPoint" .= ("1000.aa" :: T.Text)
                                ]
                        , "lagSlots" .= (0 :: Int)
                        , "maxLagSlots" .= (600 :: Int)
                        , "comparisons"
                            .= object
                                [ "sameOutput" .= True
                                , "sameDatumBytes" .= True
                                , "sameDatumHash" .= True
                                , "withinLag" .= True
                                ]
                        , "holds" .= True
                        ]
                            <> [k .= x | (k, x) <- replaced]
                record :: T.Text -> T.Text -> Integer -> [(T.Text, Integer)] -> Value
                record datum recomputed tip holders =
                    rawRecord
                        datum
                        recomputed
                        (toJSON tip)
                        tip
                        [ (ref, toJSON (1 :: Int), [toJSON (T.pack (show q))])
                        | (ref, q) <- holders
                        ]
                        []
                -- The honest record with the one holder's index and quantities as given.
                holding :: Value -> [Value] -> Value
                holding index quantities =
                    rawRecord
                        cbor
                        (hashOf cbor)
                        (toJSON (1000 :: Int))
                        1000
                        [(out, index, quantities)]
                        []
                honest = record cbor (hashOf cbor) 1000 [(out, 1 :: Integer)]
                -- Keep the record, digest it into its receipt, admit it and judge the
                -- read against the inspect, as render and the take's own check do.
                judged value = withSystemTempDirectory "readback" $ \work -> do
                    createDirectoryIfMissing True (work </> "evidence")
                    let bytes = BL.toStrict (encode value)
                    BS.writeFile (work </> "evidence/readback.json") bytes
                    let r =
                            (emptyReceipt 10 "read-indexer koios" "permanent" (T.pack label))
                                { rcOutcome = "success"
                                , rcMaxLag = Just 600
                                , rcReadbackFile = Just "evidence/readback.json"
                                , rcReadbackSha256 = Just (sha256Hex bytes)
                                }
                    a <- admit work r
                    pure (rcAdmission a, check IndexerAgrees [inspect, a])
            it "holds an honest record" $
                judged honest >>= (`shouldBe` (Just [], []))
            it
                "does not hold different datum bytes with their own hash, every stated comparison still true"
                $ do
                    (admission, problems) <-
                        judged (record other (hashOf other) 1000 [(out, 1)])
                    admission `shouldBe` Just []
                    problems
                        `shouldSatisfy` any (isInfixOf "datum bytes are not the node's")
                    problems
                        `shouldSatisfy` any (isInfixOf "is not the node's datum hash")
                    problems
                        `shouldSatisfy` any (isInfixOf "states sameDatumBytes True, but its facts say False")
            it
                "does not hold a tip beyond the configured lag, the stated lag and comparison still true"
                $ do
                    (admission, problems) <-
                        judged (record cbor (hashOf cbor) 100 [(out, 1)])
                    admission `shouldBe` Just []
                    problems
                        `shouldSatisfy` any (isInfixOf "900 slots behind the node, beyond the 600 allowed")
                    problems `shouldSatisfy` any (isInfixOf "states a lag of 0 slots")
            it
                "does not hold an answer counting two holders or two of the token, the stated verdict still true"
                $ do
                    (_, twoHolders) <-
                        judged
                            ( record
                                cbor
                                (hashOf cbor)
                                1000
                                [(out, 1), (T.replicate 32 "cd" <> "#1", 1)]
                            )
                    twoHolders
                        `shouldSatisfy` any (isInfixOf "counts 2 outputs holding the token")
                    (_, twoOfIt) <- judged (record cbor (hashOf cbor) 1000 [(out, 2)])
                    twoOfIt `shouldSatisfy` any (isInfixOf "holds 2 of the token")
            it
                "does not hold a recorded hash that is not the hash of the recorded bytes"
                $ do
                    (_, problems) <- judged (record cbor (hashOf other) 1000 [(out, 1)])
                    problems
                        `shouldSatisfy` any (isInfixOf "not the hash of its own datum bytes")
            it
                "holds an honest record whose whole numbers are JSON numbers or their digits"
                $ do
                    judged (holding (Number 1) [Number 1]) >>= (`shouldBe` (Just [], []))
                    judged
                        ( rawRecord
                            cbor
                            (hashOf cbor)
                            (String "1000")
                            1000
                            [(out, Number 1, [String "1"])]
                            [("lagSlots", String "0"), ("maxLagSlots", String "600")]
                        )
                        >>= (`shouldBe` (Just [], []))
            it
                "does not hold a fractional quantity of the token, the stated verdict still true and the digest renewed"
                $ do
                    (admission, problems) <- judged (holding (Number 1) [Number 1.4])
                    admission `shouldBe` Just []
                    problems
                        `shouldSatisfy` any
                            ( isInfixOf
                                ( "the record keeps a malformed fact: the koios answer's quantity of the token at "
                                    <> T.unpack out
                                    <> " is 1.4, not an exact whole number"
                                )
                            )
                    problems
                        `shouldSatisfy` any (isInfixOf "states holds True, but its facts say False")
            it
                "does not hold a fractional output index, the stated verdict still true and the digest renewed"
                $ do
                    (admission, problems) <- judged (holding (Number 1.4) [String "1"])
                    admission `shouldBe` Just []
                    problems
                        `shouldSatisfy` any
                            ( isInfixOf
                                ( "the koios answer's output index of "
                                    <> T.unpack (T.takeWhile (/= '#') out)
                                    <> " is 1.4, not an exact output index"
                                )
                            )
            it
                "does not hold a malformed quantity of the token beside an honest one in the same holder"
                $ do
                    (admission, problems) <-
                        judged (holding (Number 1) [String "1", String "0.5"])
                    admission `shouldBe` Just []
                    problems
                        `shouldSatisfy` any
                            ( isInfixOf
                                ( "the koios answer's quantity of the token at "
                                    <> T.unpack out
                                    <> " is \"0.5\", not an exact whole number"
                                )
                            )
            it
                "does not hold a fractional tip, maximum lag or stated lag"
                $ do
                    (_, tipOff) <-
                        judged
                            ( rawRecord
                                cbor
                                (hashOf cbor)
                                (Number 1000.4)
                                1000
                                [(out, Number 1, [String "1"])]
                                []
                            )
                    tipOff
                        `shouldSatisfy` any
                            ( isInfixOf
                                "the koios answer's tip slot is 1000.4, not an exact whole number"
                            )
                    (_, lagOff) <-
                        judged
                            ( rawRecord
                                cbor
                                (hashOf cbor)
                                (Number 1000)
                                1000
                                [(out, Number 1, [String "1"])]
                                [("maxLagSlots", Number 600.4), ("lagSlots", Number 0.4)]
                            )
                    lagOff
                        `shouldSatisfy` any
                            ( isInfixOf
                                "the record's maximum lag is 600.4, not an exact whole number"
                            )
                    lagOff
                        `shouldSatisfy` any
                            (isInfixOf "the record's stated lag is 0.4, not an exact whole number")
