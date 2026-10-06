{-# LANGUAGE LambdaCase #-}

{- |
Module      : Singular.Provider.Koios.ReferenceScriptsSpec
Description : The existence query and the mint record, over recorded preprod answers
License     : Apache-2.0

Answers recorded read-only from @https://preprod.koios.rest/api/v1@ for
the preprod registry whose state token is
@7c58a200….1ffd2d0d…@: the outputs carrying its request and state
scripts, a script no output carries, whether those outputs are spent,
the asset's minting transaction and supply, and an asset Koios does not
know. Every expected value is read from a recorded answer, or decoded by
the ledger from a recorded transaction, never typed.

Two races cannot be recorded on demand, so two answers are derived from
the recordings and marked as such: Koios reporting a listed carrier as
spent, and Koios naming a hash for an output that carries another script.
-}
module Singular.Provider.Koios.ReferenceScriptsSpec (spec) where

import Data.Aeson
    ( Object
    , Value (..)
    , eitherDecodeStrict'
    , encode
    , toJSON
    )
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Lazy qualified as BSL
import Data.ByteString.Short qualified as SBS
import Data.Foldable (toList)
import Data.List (sortOn)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Maybe (fromMaybe, isNothing)
import Data.Scientific (toBoundedInteger)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Lens.Micro ((^.))
import Test.Hspec

import Cardano.Crypto.Hash.Class (hashFromTextAsHex, hashToTextAsHex)
import Cardano.Ledger.Api.Tx (bodyTxL)
import Cardano.Ledger.Api.Tx.Body (outputsTxBodyL)
import Cardano.Ledger.Api.Tx.Out (TxOut)
import Cardano.Ledger.BaseTypes (TxIx (..))
import Cardano.Ledger.Hashes (ScriptHash (..))
import Cardano.Ledger.Mary.Value (AssetName (..), PolicyID (..))
import Cardano.Ledger.TxIn (TxId, TxIn (..))
import Singular.Registry.Ledger (ConwayEra)

import Singular.Provider.Koios.Client qualified as Client
import Singular.Provider.Koios.Provider (koiosProvider)
import Singular.Provider.Koios.Recorded
    ( Fixture (..)
    , FixtureRequest (..)
    , FixtureSet (..)
    , fixtureRequestOf
    , loadFixtureSet
    , recordedTransport
    )
import Singular.Provider.Koios.Runtime (newIORuntime)
import Singular.Provider.Koios.Wire qualified as Wire
import Singular.Registry.AssetName (deriveAssetName)
import Singular.Registry.Deployment (parseOutRef)
import Singular.Registry.Evidence
    ( Evidenced (..)
    , NoWitness
    , SessionBinding (..)
    )
import Singular.Registry.LedgerProvider
import Singular.Registry.NetworkTimeSpec (loadNetworkFixture)
import Singular.Registry.PhaseLog (noPhaseLog)
import Singular.Registry.StateToken (carriesReference)
import Singular.Registry.TimeSource (TimeSource (..))
import Singular.Registry.TxBuilder.Internal (txInToRef)

spec :: Spec
spec = do
    describe "the Koios reference-script and asset calls" $ do
        it
            "lists each output Koios records as carrying a script, with the hash it names"
            $ do
                set <- fixtures
                for2 [requestHash, stateHash] $ \hash -> do
                    rows <- recordedRows set Wire.CallReferenceScriptUtxos (hashText hash)
                    expected <- traverse carrierRow rows
                    length expected `shouldSatisfy` (> 0)
                    Client.referenceScriptUtxos (client set) (hash :| [])
                        >>= (`shouldBe` Right expected)
        it
            "answers a script no output carries with an empty list, not a failure"
            $ do
                set <- fixtures
                rows <-
                    recordedRows set Wire.CallReferenceScriptUtxos (hashText absentHash)
                rows `shouldBe` []
                Client.referenceScriptUtxos (client set) (absentHash :| [])
                    >>= (`shouldBe` Right [])
        it "reads whether each named output is spent" $ do
            set <- fixtures
            for2 [requestCarrier, stateCarrier] $ \reference -> do
                rows <- recordedRows set Wire.CallUtxoInfo (referenceText reference)
                expected <- traverse spentRow rows
                length expected `shouldBe` 1
                Client.utxoInfo (client set) (reference :| [])
                    >>= (`shouldBe` Right expected)
        it "reads an asset's minting transaction and supply" $ do
            set <- fixtures
            rows <-
                recordedRows set Wire.CallAssetInfo (assetNameText registryToken)
            expected <- case rows of
                [row] -> assetRow row
                other -> fail ("one asset_info row expected, got " <> show (length other))
            Client.assetInfo (client set) registryToken
                >>= (`shouldBe` Right (Just expected))
        it "has no row for an asset Koios does not know" $ do
            set <- fixtures
            rows <-
                recordedRows set Wire.CallAssetInfo (assetNameText unknownToken)
            rows `shouldBe` []
            Client.assetInfo (client set) unknownToken
                >>= (`shouldBe` Right Nothing)

    describe "the Koios session's existence query" $ do
        it
            "answers each carrier with its exact output, read from its producing transaction, unverified and unbound"
            $ do
                set <- fixtures
                produced <- producedOutput set requestCarrier
                withSession (recordedTransport set) $ \session -> do
                    sessionBinding session `shouldBe` Unbound
                    answer <- outputs session (CarryingReferenceScript requestHash)
                    fmap (isNothing . witness) answer `shouldBe` Right True
                    fmap value answer `shouldBe` Right [(requestCarrier, produced)]
        it "composes with the other output queries" $ do
            set <- fixtures
            requestOut <- producedOutput set requestCarrier
            stateOut <- producedOutput set stateCarrier
            withSession (recordedTransport set) $ \session -> do
                answer <-
                    outputs
                        session
                        ( AnyOf
                            ( CarryingReferenceScript requestHash
                                :| [CarryingReferenceScript stateHash]
                            )
                        )
                fmap value answer
                    `shouldBe` Right
                        ( sortOn
                            fst
                            [(requestCarrier, requestOut), (stateCarrier, stateOut)]
                        )
        it
            "answers a script no output carries with no outputs: not found by this provider"
            $ do
                set <- fixtures
                withSession (recordedTransport set) $ \session -> do
                    answer <- outputs session (CarryingReferenceScript absentHash)
                    fmap value answer `shouldBe` Right []
        it
            "drops a listed carrier that Koios reports spent (answer derived from the recording)"
            $ do
                set <- fixtures
                withSession (spentOverlay set) $ \session -> do
                    answer <- outputs session (CarryingReferenceScript requestHash)
                    fmap value answer `shouldBe` Right []
        it
            "returns an output as produced when Koios names another hash for it, so the hash computed from its script decides (answer derived from the recording)"
            $ do
                set <- fixtures
                produced <- producedOutput set stateCarrier
                carriesReference stateHash produced `shouldBe` True
                carriesReference requestHash produced `shouldBe` False
                withSession (misnamedOverlay set) $ \session -> do
                    answer <- outputs session (CarryingReferenceScript requestHash)
                    fmap value answer `shouldBe` Right [(stateCarrier, produced)]
                    fmap (map (carriesReference requestHash . snd) . value) answer
                        `shouldBe` Right [False]

    describe "the Koios session's mint record" $ do
        it
            "names the minting transaction, every input it spent and the supply"
            $ do
                set <- fixtures
                rows <-
                    recordedRows set Wire.CallAssetInfo (assetNameText registryToken)
                (minting, supply) <- case rows of
                    [row] ->
                        (,)
                            <$> textField "minting_tx_hash" row
                            <*> textField "total_supply" row
                    _ -> fail "one asset_info row expected"
                spent <- spentInputs set minting
                let AssetName name = snd registryToken
                -- The seed is among the inputs: its derived name is the token's.
                filter ((== SBS.fromShort name) . deriveAssetName . txInToRef) spent
                    `shouldSatisfy` ((== 1) . length)
                withSession (recordedTransport set) $ \session -> do
                    answer <- mintRecord session registryToken
                    fmap (isNothing . witness) answer `shouldBe` Right True
                    fmap value answer
                        `shouldBe` Right
                            ( Just
                                MintRecord
                                    { mintTransaction = txIdOf minting
                                    , mintSpentInputs = spent
                                    , mintSupply = read (T.unpack supply)
                                    }
                            )
        it "has no mint record for an asset Koios does not know" $ do
            set <- fixtures
            withSession (recordedTransport set) $ \session -> do
                answer <- mintRecord session unknownToken
                fmap value answer `shouldBe` Right Nothing
  where
    for2 xs f = mapM_ f xs

-- ---------------------------------------------------------------------------
-- The recorded registry
-- ---------------------------------------------------------------------------

requestHash, stateHash, absentHash :: ScriptHash
requestHash = hashOf "4d31c0bffb84f13bc885c4ccd55e70eab8cdb0e9a36a64115eafd0e3"
stateHash = hashOf "7c58a200ab88798562d98e3223dff44d27e2be29b18387c1b1bd450c"
absentHash = hashOf (T.replicate 56 "0")

requestCarrier, stateCarrier :: TxIn
requestCarrier =
    refOf
        "e8f6921d3f3ed0d8b1f4a1f1b171fb181b5373665eae2af9412f041e97f7a2ff#0"
stateCarrier =
    refOf
        "9c823210f66bafdacb067e974324d582d1f95fadf7ce72bd53ef9365ee287635#0"

registryToken, unknownToken :: Asset
registryToken =
    ( PolicyID stateHash
    , assetOf
        "1ffd2d0deb7896e08eda018f071f4fe15e542d3c603a430e974730358a1de516"
    )
unknownToken = (PolicyID stateHash, assetOf (T.replicate 64 "0"))

fixtures :: IO FixtureSet
fixtures =
    loadFixtureSet "test/fixtures/koios/preprod-references"
        >>= either (fail . show) pure

client :: FixtureSet -> Client.Koios IO
client = Client.Koios recordedConfig . recordedTransport

recordedConfig :: Client.ClientConfig
recordedConfig = Client.ClientConfig{Client.pageSize = 20, Client.pageCeiling = 10}

withSession
    :: Client.Transport IO -> (Session NoWitness IO -> IO a) -> IO a
withSession transport use = do
    (manifest, genesis, historyBytes, _) <- loadNetworkFixture "preprod"
    runtime <- newIORuntime noPhaseLog (const (pure ()))
    let provider =
            koiosProvider
                runtime
                (Network 1)
                (pure (Right (TimeSource manifest genesis historyBytes)))
                (Client.Koios recordedConfig transport)
    acquire provider (Latest (Network 1)) use
        >>= either (fail . show) pure

-- ---------------------------------------------------------------------------
-- Answers derived from the recording
-- ---------------------------------------------------------------------------

{- | The recording, except that @utxo_info@ reports the request carrier
spent: the race between Koios's listing and its spent flag.
-}
spentOverlay :: FixtureSet -> Client.Transport IO
spentOverlay set = Client.Transport $ \raw -> do
    recorded <- Client.exchange (recordedTransport set) raw
    pure $
        if fixtureCall (fixtureRequestOf raw) == Wire.CallUtxoInfo
            then rewriteRows (KM.insert "is_spent" (Bool True)) recorded
            else recorded

{- | The recording, except that Koios lists the state script's carrier
under the request script's hash.
-}
misnamedOverlay :: FixtureSet -> Client.Transport IO
misnamedOverlay set = Client.Transport $ \raw -> do
    let key = fixtureRequestOf raw
        asks hash = hashText hash `T.isInfixOf` bodyText (fixtureBody key)
    if fixtureCall key == Wire.CallReferenceScriptUtxos && asks requestHash
        then do
            -- Ask the recording for the state script, then rename its row.
            stateAnswer <-
                Client.exchange
                    (recordedTransport set)
                    raw{Client.rawBody = renameBody (Client.rawBody raw)}
            pure
                ( rewriteRows
                    (KM.insert "script_hash" (String (hashText requestHash)))
                    stateAnswer
                )
        else Client.exchange (recordedTransport set) raw
  where
    renameBody = \case
        Wire.JsonBody v ->
            Wire.JsonBody
                ( textReplace
                    (hashText requestHash)
                    (hashText stateHash)
                    v
                )
        other -> other
    textReplace from to v =
        fromMaybe v (decodeValue (T.replace from to (valueText v)))

rewriteRows
    :: (Object -> Object) -> Client.Exchange -> Client.Exchange
rewriteRows f ex = case Client.exchangeResult ex of
    Right answer
        | Right (Array rows) <- eitherDecodeStrict' (Client.answerBody answer) ->
            ex
                { Client.exchangeResult =
                    Right
                        answer
                            { Client.answerBody =
                                BSL.toStrict
                                    ( encode
                                        [ case row of
                                            Object o -> Object (f o)
                                            other -> other
                                        | row <- toList rows
                                        ]
                                    )
                            }
                }
    _ -> ex

-- ---------------------------------------------------------------------------
-- Reading the recorded answers
-- ---------------------------------------------------------------------------

-- | The rows of the one recorded answer of a call whose request names the text.
recordedRows :: FixtureSet -> Wire.Call -> Text -> IO [Object]
recordedRows set call needle =
    case [ f
         | f <- setFixtures set
         , fixtureCall (fixtureRequest f) == call
         , needle `T.isInfixOf` bodyText (fixtureBody (fixtureRequest f))
         ] of
        [f] -> case eitherDecodeStrict' (Client.answerBody (fixtureAnswer f)) of
            Right (Array rows) -> pure [o | Object o <- toList rows]
            other -> fail ("not an array of rows: " <> show other)
        found ->
            fail ("one recorded answer expected, found " <> show (length found))

-- | The producing transaction's output, decoded by the ledger from its bytes.
producedOutput :: FixtureSet -> TxIn -> IO (TxOut ConwayEra)
producedOutput set reference@(TxIn txId (TxIx ix)) = do
    rows <- recordedRows set Wire.CallTxCbor (Wire.txIdHex txId)
    decoded <-
        either
            (fail . show)
            pure
            (Wire.decodeTxCbors (toJSON (map Object rows)))
    case decoded of
        [tx] -> case drop
            (fromIntegral ix)
            (toList (Wire.txCborTx tx ^. bodyTxL . outputsTxBodyL)) of
            out : _ -> pure out
            [] -> fail ("no output " <> show reference)
        _ -> fail "one transaction expected"

-- | The inputs the recorded @tx_info@ of the transaction names.
spentInputs :: FixtureSet -> Text -> IO [TxIn]
spentInputs set txId = do
    rows <- recordedRows set Wire.CallTxInfo txId
    decoded <-
        either
            (fail . show)
            pure
            (Wire.decodeTxInfos (toJSON (map Object rows)))
    case decoded of
        [info] -> pure (map fst (Wire.txInfoInputs info))
        _ -> fail "one transaction expected"

carrierRow :: Object -> IO (ScriptHash, TxIn)
carrierRow o = do
    hash <- textField "script_hash" o
    txHash <- textField "tx_hash" o
    ix <- intField "tx_index" o
    pure (hashOf hash, refOf (txHash <> "#" <> T.pack (show ix)))

spentRow :: Object -> IO Wire.UtxoInfo
spentRow o = do
    txHash <- textField "tx_hash" o
    ix <- intField "tx_index" o
    spent <- case KM.lookup "is_spent" o of
        Just (Bool b) -> pure b
        other -> fail ("is_spent: " <> show other)
    pure
        Wire.UtxoInfo
            { Wire.utxoInfoReference = refOf (txHash <> "#" <> T.pack (show ix))
            , Wire.utxoInfoSpent = spent
            }

assetRow :: Object -> IO Wire.AssetInfo
assetRow o = do
    minting <- textField "minting_tx_hash" o
    supply <- textField "total_supply" o
    pure
        Wire.AssetInfo
            { Wire.assetInfoMintingTx = txIdOf minting
            , Wire.assetInfoSupply = read (T.unpack supply)
            }

textField :: Text -> Object -> IO Text
textField key o = case KM.lookup (Key.fromText key) o of
    Just (String t) -> pure t
    other -> fail (T.unpack key <> ": " <> show other)

intField :: Text -> Object -> IO Int
intField key o = case KM.lookup (Key.fromText key) o of
    Just (Number n) | Just i <- toBoundedInteger n -> pure i
    other -> fail (T.unpack key <> ": " <> show other)

bodyText :: Wire.Body -> Text
bodyText = \case
    Wire.JsonBody v -> valueText v
    _ -> ""

valueText :: Value -> Text
valueText = TE.decodeUtf8 . BSL.toStrict . encode

decodeValue :: Text -> Maybe Value
decodeValue = either (const Nothing) Just . eitherDecodeStrict' . TE.encodeUtf8

hashOf :: Text -> ScriptHash
hashOf t = maybe (error ("hash " <> show t)) ScriptHash (hashFromTextAsHex t)

hashText :: ScriptHash -> Text
hashText (ScriptHash h) = hashToTextAsHex h

assetOf :: Text -> AssetName
assetOf t =
    either error (AssetName . SBS.toShort) (B16.decode (TE.encodeUtf8 t))

assetNameText :: Asset -> Text
assetNameText (_, AssetName n) = TE.decodeUtf8 (B16.encode (SBS.fromShort n))

referenceText :: TxIn -> Text
referenceText (TxIn txId (TxIx ix)) = Wire.txIdHex txId <> "#" <> T.pack (show ix)

refOf :: Text -> TxIn
refOf = either error id . parseOutRef

txIdOf :: Text -> TxId
txIdOf t = let TxIn i _ = refOf (t <> "#0") in i
