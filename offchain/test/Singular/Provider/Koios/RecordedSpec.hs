{-# LANGUAGE LambdaCase #-}

{- |
Module      : Singular.Provider.Koios.RecordedSpec
Description : Recorded public preprod Koios answers through the client
License     : Apache-2.0

The preprod fixture set, recorded read-only from
@https://preprod.koios.rest/api/v1@ by the @koios-http@ recorder,
replayed through the recorded transport and through the live HTTP
transport pointed at a loopback server serving the same answers. Both
must produce the same decoded answers, because both hand the same
client the same raw answers.

Decoded outputs are compared with their producer: every output an
@address_utxos@, @asset_utxos@ or @tx_info@ answer names must equal the
output at the same index of the producing transaction, decoded by the
ledger from its recorded @tx_cbor@. The protocol parameters decoded from
@epoch_params@ must equal the ledger's own reading of the recorded
@cli_protocol_params@.
-}
module Singular.Provider.Koios.RecordedSpec (spec) where

import Control.Monad (forM_, unless, (>=>))
import Data.Aeson (Value (..), decodeStrict')
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as Base16
import Data.ByteString.Lazy qualified as BSL
import Data.Foldable (toList)
import Data.List (isSuffixOf, nub, sort)
import Data.Map.Strict qualified as Map
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Lens.Micro ((^.))
import System.Directory (copyFile, listDirectory)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import Cardano.Crypto.Hash.Class (hashFromBytes)
import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.Api.Tx (bodyTxL)
import Cardano.Ledger.Api.Tx.Body (mintTxBodyL, outputsTxBodyL)
import Cardano.Ledger.Api.Tx.Out
    ( TxOut
    , datumTxOutL
    , referenceScriptTxOutL
    , valueTxOutL
    )
import Cardano.Ledger.BaseTypes (TxIx (..))
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Hashes (ScriptHash (..), unsafeMakeSafeHash)
import Cardano.Ledger.Mary.Value
    ( AssetName (..)
    , MaryValue (..)
    , MultiAsset (..)
    , PolicyID (..)
    )
import Cardano.Ledger.Plutus.Data (Datum (..))
import Cardano.Ledger.TxIn (TxId (..), TxIn (..))
import Cardano.Tx.Ledger (ConwayTx)
import Data.ByteString.Short qualified as SBS
import Data.Maybe.Strict (StrictMaybe (..))

import Singular.Provider.Koios.Client
import Singular.Provider.Koios.FakeServer
    ( replayFixtures
    , withFakeKoios
    )
import Singular.Provider.Koios.Http
    ( HttpConfig (..)
    , defaultHttpConfig
    , newHttpTransport
    )
import Singular.Provider.Koios.Recorded
import Singular.Provider.Koios.Wire

-- | Where the preprod set lives, relative to the off-chain tree.
fixtureDir :: FilePath
fixtureDir = "test/fixtures/koios/preprod"

-- | The page size the set was recorded with.
recordedConfig :: ClientConfig
recordedConfig = ClientConfig{pageSize = 20, pageCeiling = 10}

-- The recorded requests' arguments. They select what was recorded; every
-- expected value below is read from a recorded answer, never typed.

-- | The deployment's reference-script address: many outputs, many pages.
referenceAddress :: Text
referenceAddress = "addr_test1vp9nyjxd4pg6u5me3n379yu5kqy723uu5g5n96edt8m66ugf49x2v"

-- | A script address whose output carries a datum hash and two assets.
datumHashAddress :: Text
datumHashAddress = "addr_test1wzzgcnajyue9szkgn73z5h2emj3c67p09msxx9anyumwcfg9479va"

-- | An address that never held an output.
emptyAddress :: Text
emptyAddress = "addr_test1vrm7e5nmgm9yul7dsl7l6v6ate6lpjjjnq6wqvkz0tpcweghrtrk6"

-- | The preprod registry's state token, held under an inline datum.
cageAsset :: (PolicyID, AssetName)
cageAsset =
    ( PolicyID
        ( scriptHashHex
            "8ac9562f5fb6be9b9b913ae2ad2cc1d9e038f7f7039256f1ac9f7a62"
        )
    , AssetName
        ( SBS.toShort
            ( hexBytes
                "bb41081f54d9c2cad883dbefe690affb0db49cff800e7574822fd1f57d76e778"
            )
        )
    )

-- | A policy nothing ever minted under.
unknownPolicy :: PolicyID
unknownPolicy =
    PolicyID
        ( scriptHashHex
            "a8a5d4ad3c8a3c43c2ab28b5c36ff94a3e0bf3d0b8f2b1fd4a0f1ecb"
        )

-- | A registry fold: inline datums, five reference inputs with scripts.
foldTx :: TxId
foldTx =
    txIdHex
        "c8c5be03023b828cffd1dc623b345c3ef061f73b0d7ddb1b8b4d924d2a1c57a3"

-- | A transaction id no chain holds.
absentTx :: TxId
absentTx = txIdHex (T.replicate 64 "0")

registeredAccount, notRegisteredAccount, absentAccount :: Text
registeredAccount = "stake_test17zy7ujlley7twgsnlqmpkue5338vgkqucz2uky864020czgktxcpl"
notRegisteredAccount = "stake_test17r5ar06gltlpcvvtuv7e7p06x9cn0mqaqsazsllqgwu32jss2sprr"
absentAccount = "stake_test17z9vj430t7mtaxumjyaw9tfvc8v7qw8h7upey4h34j0h5cseedkdf"

spec :: Spec
spec = describe "recorded preprod Koios answers" $ do
    setSpec
    decodeSpec
    seamSpec

-- ---------------------------------------------------------------------------
-- The fixture set
-- ---------------------------------------------------------------------------

loadSet :: IO FixtureSet
loadSet =
    loadFixtureSet fixtureDir >>= \case
        Right set -> pure set
        Left failure -> fail ("fixture set: " <> show failure)

recorded :: IO (Koios IO)
recorded = Koios recordedConfig . recordedTransport <$> loadSet

setSpec :: Spec
setSpec = describe "the fixture set" $ do
    it "loads, every fixture under the set's one schema revision" $ do
        set <- loadSet
        length (setFixtures set) `shouldSatisfy` (> 20)
        nub (map fixtureRevision (setFixtures set))
            `shouldBe` [setRevision set]

    it "records every read call and no submission" $ do
        set <- loadSet
        let calls = nub (map (fixtureCall . fixtureRequest) (setFixtures set))
        sort calls
            `shouldBe` filter (/= CallSubmitTx) [minBound .. maxBound]

    it "refuses a set with a fixture under another schema revision"
        $ withTamperedCopy
            (\f -> f{fixtureRevision = fixtureRevision f <> "-other"})
        $ loadFixtureSet
            >=> \case
                Left (RevisionMismatch revisions) ->
                    length (nub (map snd revisions)) `shouldBe` 2
                other -> expectationFailure (show (fmap setRevision other))

    it "refuses a fixture whose body does not match its hash"
        $ withTamperedCopy
            ( \f ->
                f
                    { fixtureAnswer =
                        (fixtureAnswer f){answerBody = answerBody (fixtureAnswer f) <> " "}
                    }
            )
        $ loadFixtureSet
            >=> \case
                Left (FixtureHashMismatch _) -> pure ()
                other -> expectationFailure (show (fmap setRevision other))

    it "refuses an empty directory" $
        withSystemTempDirectory "koios-empty" $ \dir ->
            loadFixtureSet dir `shouldReturn` Left (NoFixtures dir)

-- | Copy the set, apply the change to one fixture, and use the copy.
withTamperedCopy :: (Fixture -> Fixture) -> (FilePath -> IO a) -> IO a
withTamperedCopy change action =
    withSystemTempDirectory "koios-tampered" $ \dir -> do
        files <- filter (".json" `isSuffixOf`) <$> listDirectory fixtureDir
        forM_ files $ \f -> copyFile (fixtureDir </> f) (dir </> f)
        case files of
            f : _ -> do
                bytes <- BSL.readFile (dir </> f)
                case decodeFixture bytes of
                    Right fixture -> BSL.writeFile (dir </> f) (encodeFixture (change fixture))
                    Left e -> fail (T.unpack e)
            [] -> fail "no fixtures to tamper"
        action dir

-- ---------------------------------------------------------------------------
-- Decoded answers
-- ---------------------------------------------------------------------------

ok :: (Show e) => IO (Either e a) -> IO a
ok act = act >>= either (fail . show) pure

addr :: Text -> Addr
addr t = either (error . T.unpack) id (parseAddress t)

decodeSpec :: Spec
decodeSpec = describe "decoded answers" $ do
    it "decodes outputs exactly as their producing transactions hold them" $ do
        k <- recorded
        many <- ok (addressUtxos k [addr referenceAddress])
        hashed <- ok (addressUtxos k [addr datumHashAddress])
        held <- ok (assetUtxos k [cageAsset])
        let outputs = many <> hashed <> held
        forM_ outputs (matchesProducer k)
        -- the comparison ranges over every shape the decoder handles
        let shapes = map (shapeOf . snd) outputs
        shapes `shouldSatisfy` any inlineDatum
        shapes `shouldSatisfy` any datumHash
        shapes `shouldSatisfy` any referenceScript
        shapes `shouldSatisfy` any multiAsset

    it
        "reads a many-page answer whole: every row the first page's total announced"
        $ do
            k <- recorded
            set <- loadSet
            many <- ok (addressUtxos k [addr referenceAddress])
            let pages =
                    [ f
                    | f <- setFixtures set
                    , fixtureCall (fixtureRequest f) == CallAddressUtxos
                    , fixtureBody (fixtureRequest f) == addressBody referenceAddress
                    ]
                totals = mapMaybe (totalOf . fixtureAnswer) pages
            length pages `shouldSatisfy` (> 1)
            nub totals `shouldBe` [fromIntegral (length many)]

    it
        "decodes tx_info inputs, reference inputs and outputs as their producers hold them"
        $ do
            k <- recorded
            [info] <- ok (txInfo k [foldTx])
            txInfoId info `shouldBe` foldTx
            length (txInfoReferenceInputs info) `shouldSatisfy` (> 0)
            forM_
                (txInfoInputs info <> txInfoReferenceInputs info <> txInfoOutputs info)
                (matchesProducer k)
            map ((\(TxIn i _) -> i) . fst) (txInfoOutputs info)
                `shouldSatisfy` all (== foldTx)

    it
        "names a transaction absent from tx_info and from tx_cbor as unknown"
        $ do
            k <- recorded
            failureReason <$> errorOf (txInfo k [foldTx, absentTx])
                `shouldReturn` UnknownFact (UnknownTransaction absentTx)
            failureReason <$> errorOf (txCbor k [absentTx])
                `shouldReturn` UnknownFact (UnknownTransaction absentTx)

    it
        "lists the transactions that moved an asset, in block order, each one moving it"
        $ do
            k <- recorded
            moves <- ok (uncurry (assetTxs k) cageAsset)
            length moves `shouldSatisfy` (> 1)
            let heights = map assetTxBlockHeight moves
            heights `shouldBe` sort heights
            forM_ moves $ \m -> do
                [c] <- ok (txCbor k [assetTxId m])
                unless (movesAsset cageAsset (txCborTx c)) $
                    expectationFailure ("does not move the asset: " <> show (assetTxId m))

    it
        "answers an address and an asset with no history with empty successes"
        $ do
            k <- recorded
            addressUtxos k [addr emptyAddress] `shouldReturn` Right []
            assetTxs k unknownPolicy (AssetName "") `shouldReturn` Right []

    it
        "decodes epoch_params as the ledger reads the same epoch's parameters"
        $ do
            k <- recorded
            t <- ok (tip k)
            fromKoios <- ok (epochParams k (tipEpoch t))
            fromLedger <- ok (cliProtocolParams k)
            fromKoios `shouldBe` fromLedger

    it
        "reports confirmations of a seen transaction and not yet seen for an absent one"
        $ do
            k <- recorded
            statuses <- ok (txStatus k [foldTx, absentTx])
            map txStatusId statuses `shouldBe` [foldTx, absentTx]
            case map txStatusConfirmations statuses of
                [Just n, Nothing] -> n `shouldSatisfy` (> 0)
                other -> expectationFailure (show other)

    it
        "reads registered and not registered as Koios states them, and no row as unknown"
        $ do
            k <- recorded
            set <- loadSet
            let stated stake =
                    case [ s
                         | f <- setFixtures set
                         , fixtureCall (fixtureRequest f) == CallAccountInfo
                         , s <- statusesIn (fixtureAnswer f)
                         , fst s == stake
                         ] of
                        (_, status) : _ -> Just status
                        [] -> Nothing
            stated registeredAccount `shouldBe` Just "registered"
            stated notRegisteredAccount `shouldBe` Just "not registered"
            stated absentAccount `shouldBe` Nothing
            accountRegistered k (account registeredAccount)
                `shouldReturn` Right True
            accountRegistered k (account notRegisteredAccount)
                `shouldReturn` Right False
            failureReason
                <$> errorOf (accountRegistered k (account absentAccount))
                `shouldReturn` UnknownFact (UnknownRegistration absentAccount Nothing)

    it "names a request with no recording" $ do
        k <- recorded
        unrecorded <-
            failureReason <$> errorOf (txCbor k [txIdHex (T.replicate 64 "1")])
        unrecorded `shouldSatisfy` (\case NotRecorded _ -> True; _ -> False)
  where
    account t = either (error . T.unpack) id (parseRewardAccount t)

errorOf :: IO (Either ClientFailure a) -> IO ClientFailure
errorOf act =
    act >>= \case
        Left f -> pure f
        Right _ -> fail "expected a failure, got an answer"

-- | The output must equal the producing transaction's output at its index.
matchesProducer :: Koios IO -> (TxIn, TxOut ConwayEra) -> Expectation
matchesProducer k (TxIn txId (TxIx ix), out) = do
    [c] <- ok (txCbor k [txId])
    let produced = toList (txCborTx c ^. bodyTxL . outputsTxBodyL)
    case drop (fromIntegral ix) produced of
        expected : _ -> out `shouldBe` expected
        [] -> expectationFailure ("producer has no output " <> show ix)

data Shape = Shape
    { inlineDatum :: Bool
    , datumHash :: Bool
    , referenceScript :: Bool
    , multiAsset :: Bool
    }
    deriving stock (Show)

shapeOf :: TxOut ConwayEra -> Shape
shapeOf out =
    Shape
        { inlineDatum = case out ^. datumTxOutL of Datum _ -> True; _ -> False
        , datumHash = case out ^. datumTxOutL of DatumHash _ -> True; _ -> False
        , referenceScript = case out ^. referenceScriptTxOutL of
            SJust _ -> True
            SNothing -> False
        , multiAsset =
            let MaryValue _ (MultiAsset m) = out ^. valueTxOutL
            in  sum (map Map.size (Map.elems m)) > 1
        }

movesAsset :: (PolicyID, AssetName) -> ConwayTx -> Bool
movesAsset (policy, name) tx =
    let MultiAsset minted = tx ^. bodyTxL . mintTxBodyL
        held out =
            let MaryValue _ (MultiAsset m) = out ^. valueTxOutL
            in  maybe False (Map.member name) (Map.lookup policy m)
    in  maybe False (Map.member name) (Map.lookup policy minted)
            || any held (tx ^. bodyTxL . outputsTxBodyL)

-- | The JSON body of an @address_utxos@ request for one address.
addressBody :: Text -> Body
addressBody a = requestBody (addressUtxosRequest [addr a])

-- | The exact total of a recorded page's range header.
totalOf :: Answer -> Maybe Integer
totalOf a = do
    range <- lookup "content-range" (answerHeaders a)
    let total = T.drop 1 (snd (T.breakOn "/" range))
    case reads (T.unpack total) of
        [(n, "")] -> Just n
        _ -> Nothing

-- | Stake address and status of each row of a recorded account_info body.
statusesIn :: Answer -> [(Text, Text)]
statusesIn a =
    case decodeStrict' (answerBody a) of
        Just (Array rows) ->
            [ (s, st)
            | Object row <- toList rows
            , Just (String s) <- [KM.lookup "stake_address" row]
            , Just (String st) <- [KM.lookup "status" row]
            ]
        _ -> []

-- ---------------------------------------------------------------------------
-- One decoder for recorded and live answers
-- ---------------------------------------------------------------------------

-- | Every recorded request, rendered: the same text whatever the transport.
everyCall :: Koios IO -> IO [String]
everyCall k = do
    t <- tip k
    let epoch = either (const Nothing) (Just . tipEpoch) t
    sequence
        [ pure (show t)
        , show <$> addressUtxos k [addr referenceAddress]
        , show <$> addressUtxos k [addr datumHashAddress]
        , show <$> addressUtxos k [addr emptyAddress]
        , show <$> assetUtxos k [cageAsset]
        , show <$> uncurry (assetTxs k) cageAsset
        , show <$> assetTxs k unknownPolicy (AssetName "")
        , show <$> txInfo k [foldTx]
        , show <$> txCbor k [foldTx]
        , maybe (pure "no epoch") (fmap show . epochParams k) epoch
        , show <$> cliProtocolParams k
        , show <$> txStatus k [foldTx, absentTx]
        , show <$> accountRegistered k (account registeredAccount)
        , show <$> accountRegistered k (account notRegisteredAccount)
        ]
  where
    account t = either (error . T.unpack) id (parseRewardAccount t)

seamSpec :: Spec
seamSpec = describe "one decoder for recorded and live answers"
    $ it
        "the HTTP transport serving the recorded answers decodes exactly as the recorded transport"
    $ do
        set <- loadSet
        fromRecorded <-
            everyCall (Koios recordedConfig (recordedTransport set))
        fromHttp <-
            withFakeKoios (replayFixtures set) $ \base _ -> do
                transport <-
                    newHttpTransport (defaultHttpConfig base){httpAttempts = 1} >>= \case
                        Right t -> pure t
                        Left r -> fail (show r)
                everyCall (Koios recordedConfig transport)
        length fromRecorded `shouldBe` 14
        fromHttp `shouldBe` fromRecorded

-- ---------------------------------------------------------------------------
-- Hex helpers
-- ---------------------------------------------------------------------------

hexBytes :: Text -> BS.ByteString
hexBytes t = either error id (Base16.decode (TE.encodeUtf8 t))

scriptHashHex :: Text -> ScriptHash
scriptHashHex t = maybe (error "script hash") ScriptHash (hashFromBytes (hexBytes t))

txIdHex :: Text -> TxId
txIdHex t =
    maybe
        (error "tx id")
        (TxId . unsafeMakeSafeHash)
        (hashFromBytes (hexBytes t))
