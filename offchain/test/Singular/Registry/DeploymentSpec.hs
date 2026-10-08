{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.Registry.DeploymentSpec
Description : Focused deployment manifest, mirror and attachment rows
License     : Apache-2.0

The deployment record travels as files a person copies between
machines, so its shapes are contracts: the manifest's JSON keys and
pretty bytes, the mirror's hex maps beside it, the @txid#index@
spelling, and the checks a run makes against a node before it uses a
recorded registry. These rows run the public deployment surface itself
over files and a provider stub that records every address it is asked
for: the successful attachment row reads that record back, so the
resolution order is asserted, not assumed, and the refusal rows observe
the real named diagnostics rather than a source reading.

Every identity the rows compare against — script hashes, the token a
seed determines, the addresses a run queries — is computed at run time
from the same producers the manifest and the code under test use; none
is typed into this file. The provider serves finite UTxOs at recorded
addresses; this is the library attachment path over a fixture, not a
public journey, and no mirror-root comparison happens here (the
retained journey callers own that check after attaching).
-}
module Singular.Registry.DeploymentSpec (spec) where

import Control.Exception (ErrorCall (..))
import Control.Monad (forM_)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as BL
import Data.ByteString.Short qualified as SBS
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.List (isInfixOf)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Word (Word8)
import Lens.Micro ((&), (.~), (^.))
import Test.Hspec

import Data.Aeson qualified as Aeson
import Data.Aeson.Encode.Pretty (encodePretty)

import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.Api.Tx.Out
    ( TxOut
    , datumTxOutL
    , mkBasicTxOut
    , referenceScriptTxOutL
    )
import Cardano.Ledger.BaseTypes (Network (Testnet), StrictMaybe (..))
import Cardano.Ledger.Core (hashScript)
import Cardano.Ledger.Mary.Value
    ( MaryValue (..)
    , MultiAsset (..)
    )
import Cardano.Ledger.TxIn (TxIn)
import PlutusCore.Version (plcVersion110)
import PlutusLedgerApi.V3 (serialiseUPLC)
import PlutusTx.Builtins.Internal (BuiltinByteString (..))
import UntypedPlutusCore qualified as UPLC

import MPF.Backend.Pure (MPFInMemoryDB (..))

import Singular.Registry.AssetName (deriveAssetName)
import Singular.Registry.Config (CageConfig (..))
import Singular.Registry.Deployment
import Singular.Registry.Evidence (Evidenced (..), NoWitness)
import Singular.Registry.Ledger
    ( AssetName (..)
    , Coin (..)
    , ConwayEra
    , TokenId (..)
    )
import Singular.Registry.LedgerProvider qualified as Cage
import Singular.Registry.StubSession
import Singular.Registry.TxBuilder.Internal
    ( addrFromKeyHashBytes
    , cageAddrFromCfg
    , cagePolicyIdFromCfg
    , computeScriptHash
    , mkInlineDatum
    , scriptFromBytes
    , scriptHashBytes
    , toPlcData
    , txInToRef
    )
import Singular.Registry.Types
    ( CageDatum (..)
    , OnChainRoot (..)
    , OnChainTokenState (..)
    , OnChainTxOutRef (..)
    )

import System.Directory (doesFileExist)
import System.Environment (setEnv, unsetEnv)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)

spec :: Spec
spec = do
    describe "the manifest file" $ do
        it
            "round-trips every field through its recorded keys and pretty bytes"
            $ withTempDir
            $ \dir -> do
                let path = dir </> "deployment.json"
                writeDeployment path manifest
                readBack <- readDeployment path
                readBack `shouldBe` manifest
                raw <- BL.readFile path
                case BL.unsnoc raw of
                    Just (_, b) -> b `shouldBe` newlineByte
                    Nothing -> expectationFailure "the manifest file is empty"
                Aeson.decode raw `shouldBe` Just expectedManifestValue
                raw `shouldBe` (encodePretty expectedManifestValue <> "\n")

        it "refuses an unreadable manifest naming the file" $ withTempDir $ \dir -> do
            let path = dir </> "broken.json"
            BL.writeFile path "{not json"
            readDeployment path
                `shouldThrow` refusalContaining ("deployment manifest " <> path)

        it "parses every --deployment spelling and leaves other flags alone" $ do
            deploymentPathFromArgs ["--deployment", "/a/dep.json"]
                `shouldBe` Just "/a/dep.json"
            deploymentPathFromArgs ["--other", "--deployment=/b/dep.json", "-x"]
                `shouldBe` Just "/b/dep.json"
            deploymentPathFromArgs ["--deployments=/c/dep.json"]
                `shouldBe` Nothing
            deploymentPathFromArgs ["--deployment"]
                `shouldBe` Nothing
            deploymentPathFromArgs []
                `shouldBe` Nothing

        it "falls back to SINGULAR_DEPLOYMENT when no flag names one" $ do
            unsetEnv "SINGULAR_DEPLOYMENT"
            deploymentPathFromEnvironment `shouldReturn` Nothing
            setEnv "SINGULAR_DEPLOYMENT" "/d/dep.json"
            deploymentPathFromEnvironment `shouldReturn` Just "/d/dep.json"
            unsetEnv "SINGULAR_DEPLOYMENT"

    describe "output references" $ do
        it "renders and re-parses a txid#index exactly" $
            forM_
                [seedIn, stateIn, highIxIn]
                (\txIn -> parseOutRef (renderOutRef txIn) `shouldBe` Right txIn)

        it "names what was wrong with a bad reference" $ do
            let bad = parseOutRef :: Text -> Either String TxIn
            leftOf (bad "zz#0")
                `shouldSatisfy` isInfixOf "transaction id is not hex"
            leftOf (bad "aa#0")
                `shouldSatisfy` isInfixOf "transaction id is not 32 bytes"
            leftOf (bad "carries-no-hash")
                `shouldSatisfy` isInfixOf "not a txid#index output reference"
            leftOf (bad (T.pack (replicate 64 'a' <> "#two")))
                `shouldSatisfy` isInfixOf "output index is not a number"

    describe "the proof mirror" $ do
        it
            "writes the mirror beside the manifest and reads it back with hex maps"
            $ withTempDir
            $ \dir -> do
                let manifestPath = dir </> "deployment.json"
                    mirrorPath' = mirrorPathFor manifestPath
                mirrorPath' `shouldBe` (dir </> "deployment.mirror.json")
                saveMirror manifestPath mirrorFixture
                there <- doesFileExist mirrorPath'
                there `shouldBe` True
                loaded <- loadMirror manifestPath
                loaded `shouldBe` mirrorFixture
                raw <- BL.readFile mirrorPath'
                case BL.unsnoc raw of
                    Just (_, b) -> b `shouldBe` newlineByte
                    Nothing -> expectationFailure "the mirror file is empty"
                Aeson.decode raw `shouldBe` Just expectedMirrorValue
                raw `shouldBe` (encodePretty expectedMirrorValue <> "\n")

        it "treats a missing mirror as empty rather than an error" $ withTempDir $ \dir -> do
            loaded <- loadMirror (dir </> "never-written.json")
            loaded `shouldBe` Map.empty

        it "replaces what was there on write" $ withTempDir $ \dir -> do
            let path = dir </> "deployment.json"
                replacement = case Map.toList mirrorFixture of
                    ((t, _) : _) -> Map.delete t mirrorFixture
                    [] -> mirrorFixture
            saveMirror path mirrorFixture
            saveMirror path replacement
            loaded <- loadMirror path
            loaded `shouldBe` replacement

        it "refuses a mirror whose token is not hex" $ withTempDir $ \dir -> do
            let manifestPath = dir </> "deployment.json"
            BL.writeFile
                (mirrorPathFor manifestPath)
                "{\"mirrorTries\":[{\"mtToken\":\"zz\",\"mtMpf\":[],\"mtKv\":[],\"mtJournal\":[],\"mtMetrics\":[]}]}"
            loadMirror manifestPath
                `shouldThrow` refusalContaining "proof mirror: not hex"

    describe "attaching a run" $ do
        it
            "finds each recorded role's reference by its hash, wherever it now sits, and the state by its token"
            $ do
                -- The recorded outputs are gone; other carriers of the same
                -- scripts are live at other addresses.
                let serves =
                        Map.fromList
                            [ (refAddr2, [movedState])
                            , (refAddr1, [movedRequest])
                            , (stateAddr, [decoyUtxo, stateUtxo])
                            ]
                (logRef, prov) <- providerServing serves
                attached <- attach prov manifest parts
                reverse <$> readIORef logRef `shouldReturn` [stateAddr]
                attRefUtxos attached `shouldBe` [movedState, movedRequest]
                attStateUtxo attached `shouldBe` stateUtxo
                attToken attached `shouldBe` recordedToken
                cfgOf (attCfg attached) `shouldBe` cfgOf fixtureCfg

        it "takes the lowest output reference among a role's carriers" $ do
            let serves =
                    Map.insert
                        refAddr2
                        [lowerState, refUtxo2]
                        (Map.insert refAddr1 [refUtxo1, movedRequest] agreeingServes)
                -- Below the recorded state carrier; above the recorded request one.
                lowerState = (outRefOf '3' 1, publishedAt refAddr2 stateProgram 9_000_000)
            (_, prov) <- providerServing serves
            attached <- attach prov manifest parts
            attRefUtxos attached `shouldBe` [lowerState, refUtxo2]

        it "never takes an output that carries another script than its role's" $ do
            let serves =
                    Map.insert
                        refAddr1
                        [(refIn1, publishedAt refAddr1 otherProgram 5_000_000)]
                        agreeingServes
            (_, prov) <- providerServing serves
            attach prov manifest parts
                `shouldThrow` refusalContaining "reference-missing state"

        it "refuses a role whose script no live output carries, naming it" $ do
            let serves = Map.delete refAddr2 agreeingServes
            (_, prov) <- providerServing serves
            attach prov manifest parts
                `shouldThrow` refusalContaining "reference-missing request"

        it
            "attaches the deployment's own manifest: the registry roles it records beside the custody script"
            $ do
                let serves =
                        Map.insert
                            refAddr3
                            [witnessActiveUtxo, applicationUtxo, custodyUtxo]
                            agreeingServes
                (_, prov) <- providerServing serves
                attached <- attach prov deploymentManifest parts
                attRefUtxos attached
                    `shouldBe` [ refUtxo1
                               , refUtxo2
                               , witnessActiveUtxo
                               , applicationUtxo
                               , custodyUtxo
                               ]

        it "refuses a manifest that records a role nobody knows, by name" $ do
            (_, prov) <- providerServing agreeingServes
            attach
                prov
                manifest
                    { depReferenceScripts =
                        [refScriptOf "registry" refAddr1 refIn1 stateProgram]
                    }
                parts
                `shouldThrow` refusalContaining
                    "the deployment records an unknown reference role registry"

        it "refuses a seed whose derived token contradicts the manifest" $ do
            (_, prov) <- providerServing agreeingServes
            attach prov manifest{depCageToken = T.pack (replicate 64 '0')} parts
                `shouldThrow` refusalContaining "but the manifest records 0x"

        it
            "refuses a release whose state validator hash differs from the manifest"
            $ do
                (_, prov) <- providerServing agreeingServes
                attach prov manifest{depStatePolicy = otherStateHex} parts
                    `shouldThrow` refusalContaining "the manifest belongs to another release"

        it
            "refuses when no output at the registry address carries the recorded token"
            $ do
                let serves = Map.fromList [(refAddr1, [refUtxo1]), (refAddr2, [refUtxo2])]
                (_, prov) <- providerServing serves
                attach prov manifest parts
                    `shouldThrow` refusalContaining
                        "no output at the registry address carries the recorded token"

    describe "checking one against a node" $ do
        it "reports every claim when the node agrees" $ do
            (logRef, prov) <- providerServing agreeingServes
            claims <- verifyDeployment prov manifest parts
            claims
                `shouldBe` [ "release identity-check compiles the state validator to the recorded 0x"
                                <> T.unpack (depStatePolicy manifest)
                           , "seed "
                                <> T.unpack (depSeedOutRef manifest)
                                <> " determines the recorded registry token 0x"
                                <> T.unpack (depCageToken manifest)
                           , "compiled representative policy agrees with the manifest and live registry configuration: 0x"
                                <> T.unpack (depRepresentativePolicy manifest)
                           , "registry state carries the recorded request windows: process "
                                <> show (depProcessTime manifest)
                                <> " ms, retract "
                                <> show (depRetractTime manifest)
                                <> " ms"
                           ]
                    <> [ "reference script "
                            <> T.unpack (refRole r)
                            <> " live at "
                            <> T.unpack (refOutRef r)
                            <> " carrying 0x"
                            <> T.unpack (refHash r)
                       | r <- depReferenceScripts manifest
                       ]
                    <> [ "registry state output "
                            <> T.unpack (renderOutRef stateIn)
                            <> " carries the recorded token"
                       ]
            reverse <$> readIORef logRef
                `shouldReturn` [stateAddr]

        it "refuses a live state whose windows disagree with the manifest" $ do
            (_, prov) <-
                providerServing
                    (servingState agreeingState{stateRetractTime = 61_000})
            verifyDeployment prov manifest parts
                `shouldThrow` refusalContaining
                    "the live registry state carries process/retract windows"

        it "refuses a live state whose active policy is not the registry's" $ do
            (_, prov) <-
                providerServing
                    ( servingState
                        agreeingState
                            { stateActivePolicy =
                                BuiltinByteString (BS.replicate 28 0xEE)
                            }
                    )
            verifyDeployment prov manifest parts
                `shouldThrow` refusalContaining
                    "does not configure this registry-bound representative policy"

-- ---------------------------------------------------------
-- The manifest fixture
-- ---------------------------------------------------------

-- | Distinct well-formed PlutusV3 programs, one per recorded half.
lambdas :: Int -> SBS.ShortByteString
lambdas n =
    serialiseUPLC
        ( UPLC.Program
            ()
            plcVersion110
            ( iterate
                (UPLC.LamAbs () (UPLC.DeBruijn 0))
                (UPLC.Var () (UPLC.DeBruijn 1))
                !! n
            )
        )

stateProgram
    , requestProgram
    , applicationProgram
    , activeProgram
    , absentProgram
    , terminalProgram
    , consumerProgram
    , custodyProgram
    , otherProgram
        :: SBS.ShortByteString
stateProgram = lambdas 1
requestProgram = lambdas 2
applicationProgram = lambdas 3
activeProgram = lambdas 4
absentProgram = lambdas 5
terminalProgram = lambdas 6
consumerProgram = lambdas 7
custodyProgram = lambdas 9
otherProgram = lambdas 8

toHex :: ByteString -> String
toHex = BC.unpack . B16.encode

outRefOf :: Char -> Word -> TxIn
outRefOf c ix =
    either (error . ("DeploymentSpec fixture: " <>)) id $
        parseOutRef (T.pack (replicate 64 c <> "#" <> show ix))

seedIn
    , stateIn
    , highIxIn
    , refIn1
    , refIn2
    , refIn3
    , refIn4
    , refIn5
        :: TxIn
seedIn = outRefOf '1' 0
stateIn = outRefOf '9' 7
highIxIn = outRefOf '0' 65_535
refIn1 = outRefOf 'a' 0
refIn2 = outRefOf 'b' 3
refIn3 = outRefOf 'c' 1
refIn4 = outRefOf 'd' 2
refIn5 = outRefOf 'e' 4

secondSeedIn :: TxIn
secondSeedIn = outRefOf '2' 0

{- | The registry token this seed determines, produced by the same
derivation the manifest records.
-}
recordedToken :: TokenId
recordedToken =
    TokenId (AssetName (SBS.toShort (deriveAssetName (txInToRef seedIn))))

secondToken :: TokenId
secondToken =
    TokenId
        (AssetName (SBS.toShort (deriveAssetName (txInToRef secondSeedIn))))

stateHex, requestHex, applicationHex, activeHex, otherStateHex :: Text
stateHex = T.pack (toHex (scriptHashBytes (computeScriptHash stateProgram)))
requestHex = T.pack (toHex (scriptHashBytes (computeScriptHash requestProgram)))
applicationHex =
    T.pack
        (toHex (scriptHashBytes (computeScriptHash applicationProgram)))
activeHex = T.pack (toHex (SBS.fromShort activeProgram))
otherStateHex = T.pack (toHex (scriptHashBytes (computeScriptHash otherProgram)))

refAddr1, refAddr2, refAddr3, stateAddr :: Addr
refAddr1 = addrFromKeyHashBytes Testnet (BS.replicate 28 0x5b)
refAddr2 = addrFromKeyHashBytes Testnet (BS.replicate 28 0x5c)
refAddr3 = addrFromKeyHashBytes Testnet (BS.replicate 28 0x5d)
stateAddr = cageAddrFromCfg fixtureCfg Testnet

refScriptOf
    :: Text -> Addr -> TxIn -> SBS.ShortByteString -> ReferenceScript
refScriptOf role addr inRef prog =
    ReferenceScript
        { refRole = role
        , refHash =
            T.pack
                (toHex (scriptHashBytes (hashScript (scriptFromBytes "spec" prog))))
        , refOutRef = renderOutRef inRef
        , refAddress = T.pack ("addr_test1z" <> T.unpack role)
        , refAddressBytes = renderAddrBytes addr
        }

manifest :: Deployment
manifest =
    Deployment
        { depRelease = "identity-check"
        , depLeanRevision = "f1e6a0ed"
        , depNetworkMagic = 42
        , depSeedOutRef = renderOutRef seedIn
        , depCageToken = T.pack (toHex (deriveAssetName (txInToRef seedIn)))
        , depStatePolicy = stateHex
        , depRequestHash = requestHex
        , depApplicationHash = applicationHex
        , depRepresentativePolicy = activeHex
        , depProcessTime = 30_000
        , depRetractTime = 60_000
        , depTip = 2_000_000
        , depReferenceScripts =
            [ refScriptOf "state" refAddr1 refIn1 stateProgram
            , refScriptOf "request" refAddr2 refIn2 requestProgram
            ]
        , depBootstrapTxs =
            [ T.pack (toHex (BS.replicate 32 1))
            , T.pack (toHex (BS.replicate 32 2))
            ]
        }

{- | The manifest the deployment tool itself writes: the registry roles
it publishes in the receipt vocabulary, with its own custody script
recorded beside them. The producer's vocabulary and the consumer's
must stay one set; the unknown-role refusal is what holds them there.
-}
deploymentManifest :: Deployment
deploymentManifest =
    manifest
        { depReferenceScripts =
            [ refScriptOf "state" refAddr1 refIn1 stateProgram
            , refScriptOf "request" refAddr2 refIn2 requestProgram
            , refScriptOf "witness-active" refAddr3 refIn3 activeProgram
            , refScriptOf "application" refAddr3 refIn5 applicationProgram
            , refScriptOf "custody" refAddr3 refIn4 custodyProgram
            ]
        }

parts :: CageParts
parts =
    CageParts
        { partsStateBytes = stateProgram
        , partsRequestBytes = requestProgram
        , partsApplicationPolicy = applicationProgram
        , partsActivePolicy = activeProgram
        , partsAbsentPolicy = absentProgram
        , partsTerminalPolicy = terminalProgram
        , partsConsumerScript = consumerProgram
        }

{- | The configuration the manifest is expected to describe, built
directly from the same programs so 'cageConfigFor' is compared against
an independently assembled expectation.
-}
fixtureCfg :: CageConfig
fixtureCfg =
    CageConfig
        { cageScriptBytes = stateProgram
        , requestScriptBytes = requestProgram
        , cfgScriptHash = computeScriptHash stateProgram
        , cageSeed = txInToRef seedIn
        , defaultProcessTime = 30_000
        , defaultRetractTime = 60_000
        , defaultTip = Coin 2_000_000
        , cfgApplicationPolicy = applicationProgram
        , cfgActivePolicy = activeProgram
        , cfgAbsentPolicy = absentProgram
        , cfgTerminalPolicy = terminalProgram
        , cfgConsumerScript = consumerProgram
        , network = Testnet
        }

-- | Every field of a cage configuration, as comparable values.
cfgOf
    :: CageConfig
    -> ( SBS.ShortByteString
       , SBS.ShortByteString
       , Text
       , OnChainTxOutRef
       , Integer
       , Integer
       , Integer
       , SBS.ShortByteString
       , SBS.ShortByteString
       , SBS.ShortByteString
       , SBS.ShortByteString
       , SBS.ShortByteString
       , Network
       )
cfgOf c =
    ( cageScriptBytes c
    , requestScriptBytes c
    , T.pack (toHex (scriptHashBytes (cfgScriptHash c)))
    , cageSeed c
    , defaultProcessTime c
    , defaultRetractTime c
    , let Coin n = defaultTip c in n
    , cfgApplicationPolicy c
    , cfgActivePolicy c
    , cfgAbsentPolicy c
    , cfgTerminalPolicy c
    , cfgConsumerScript c
    , network c
    )

expectedManifestValue :: Aeson.Value
expectedManifestValue =
    Aeson.object
        [ "depRelease" Aeson..= ("identity-check" :: Text)
        , "depLeanRevision" Aeson..= ("f1e6a0ed" :: Text)
        , "depNetworkMagic" Aeson..= (42 :: Int)
        , "depSeedOutRef" Aeson..= renderOutRef seedIn
        , "depCageToken"
            Aeson..= T.pack (toHex (deriveAssetName (txInToRef seedIn)))
        , "depStatePolicy" Aeson..= stateHex
        , "depRequestHash" Aeson..= requestHex
        , "depApplicationHash" Aeson..= applicationHex
        , "depRepresentativePolicy" Aeson..= activeHex
        , "depProcessTime" Aeson..= (30_000 :: Integer)
        , "depRetractTime" Aeson..= (60_000 :: Integer)
        , "depTip" Aeson..= (2_000_000 :: Integer)
        , "depBootstrapTxs"
            Aeson..= [ T.pack (toHex (BS.replicate 32 1))
                     , T.pack (toHex (BS.replicate 32 2))
                     ]
        , "depReferenceScripts"
            Aeson..= [ refValue (refScriptOf "state" refAddr1 refIn1 stateProgram)
                     , refValue (refScriptOf "request" refAddr2 refIn2 requestProgram)
                     ]
        ]
  where
    refValue r =
        Aeson.object
            [ "refRole" Aeson..= refRole r
            , "refHash" Aeson..= refHash r
            , "refOutRef" Aeson..= refOutRef r
            , "refAddress" Aeson..= refAddress r
            , "refAddressBytes" Aeson..= refAddressBytes r
            ]

-- ---------------------------------------------------------
-- The provider fixture
-- ---------------------------------------------------------

{- | A view that records every address asked for and serves the given
UTxOs there.
-}
providerServing
    :: Map Addr [(TxIn, TxOut ConwayEra)]
    -> IO (IORef [Addr], Cage.Session NoWitness IO)
providerServing serves = do
    logRef <- newIORef []
    pure
        ( logRef
        , withCarriers
            ( withAddressOutputs
                ( \a -> do
                    modifyIORef' logRef (a :)
                    pure (Map.findWithDefault [] a serves)
                )
                stubSession
            )
        )
  where
    -- The provider's existence index over everything served.
    withCarriers session =
        session
            { Cage.outputs = \case
                Cage.CarryingReferenceScript script ->
                    pure
                        ( Right
                            ( Evidenced
                                [ u
                                | u@(_, o) <- Map.toAscList (Map.fromList (concat (Map.elems serves)))
                                , SJust carried <- [o ^. referenceScriptTxOutL]
                                , hashScript carried == script
                                ]
                                Nothing
                            )
                        )
                other -> Cage.outputs session other
            }

agreeingServes :: Map Addr [(TxIn, TxOut ConwayEra)]
agreeingServes = servingState agreeingState

servingState
    :: OnChainTokenState
    -> Map Addr [(TxIn, TxOut ConwayEra)]
servingState st =
    Map.fromList
        [ (refAddr1, [refUtxo1])
        , (refAddr2, [refUtxo2])
        , (stateAddr, [decoyUtxo, stateUtxoOf st])
        ]

-- | The live state a manifest and a release agree on.
agreeingState :: OnChainTokenState
agreeingState =
    OnChainTokenState
        { stateRoot = OnChainRoot (BS.replicate 32 7)
        , stateMaxFee = 2_000_000
        , stateProcessTime = 30_000
        , stateRetractTime = 60_000
        , stateAppPolicy = BuiltinByteString (SBS.fromShort applicationProgram)
        , stateActivePolicy = BuiltinByteString (SBS.fromShort activeProgram)
        , stateAbsentPolicy = BuiltinByteString (SBS.fromShort absentProgram)
        , stateTerminalPolicy =
            BuiltinByteString (SBS.fromShort terminalProgram)
        }

stateUtxo :: (TxIn, TxOut ConwayEra)
stateUtxo = stateUtxoOf agreeingState

{- | An output at the registry's address without the recorded token,
served before the real one so resolution is by token, not position.
-}
decoyUtxo :: (TxIn, TxOut ConwayEra)
decoyUtxo =
    ( outRefOf '9' 0
    , mkBasicTxOut stateAddr (MaryValue (Coin 3_000_000) mempty)
    )

stateUtxoOf :: OnChainTokenState -> (TxIn, TxOut ConwayEra)
stateUtxoOf st =
    ( stateIn
    , mkBasicTxOut stateAddr (MaryValue (Coin 10_000_000) tokenAsset)
        & datumTxOutL
            .~ mkInlineDatum (toPlcData (StateDatum st))
    )

tokenAsset :: MultiAsset
tokenAsset =
    MultiAsset
        ( Map.singleton
            (cagePolicyIdFromCfg fixtureCfg)
            ( Map.singleton
                (AssetName (SBS.toShort (deriveAssetName (txInToRef seedIn))))
                1
            )
        )

refUtxo1, refUtxo2 :: (TxIn, TxOut ConwayEra)
refUtxo1 = (refIn1, publishedAt refAddr1 stateProgram 5_000_000)
refUtxo2 = (refIn2, publishedAt refAddr2 requestProgram 6_000_000)

witnessActiveUtxo
    , applicationUtxo
    , custodyUtxo
        :: (TxIn, TxOut ConwayEra)
witnessActiveUtxo = (refIn3, publishedAt refAddr3 activeProgram 7_000_000)
applicationUtxo = (refIn5, publishedAt refAddr3 applicationProgram 9_000_000)
custodyUtxo = (refIn4, publishedAt refAddr3 custodyProgram 8_000_000)

publishedAt
    :: Addr -> SBS.ShortByteString -> Integer -> TxOut ConwayEra
publishedAt addr prog lovelace =
    mkBasicTxOut addr (MaryValue (Coin lovelace) mempty)
        & referenceScriptTxOutL
            .~ SJust (scriptFromBytes "spec" prog)

-- ---------------------------------------------------------
-- The mirror fixture
-- ---------------------------------------------------------

mirrorFixture :: Map TokenId MPFInMemoryDB
mirrorFixture =
    Map.fromList
        [ (recordedToken, dbOf [(BS.replicate 1 1, BS.replicate 2 1)])
        ,
            ( secondToken
            , dbOf
                [ (BS.replicate 3 2, BS.replicate 4 2)
                , (BS.replicate 5 2, BS.replicate 6 2)
                ]
            )
        ]
  where
    dbOf mpf =
        MPFInMemoryDB
            { mpfInMemoryMPF = Map.fromList mpf
            , mpfInMemoryKV = Map.fromList [(BS.replicate 7 3, BS.replicate 8 3)]
            , mpfInMemoryJournal =
                Map.fromList [(BS.replicate 9 4, BS.replicate 10 4)]
            , mpfInMemoryMetrics =
                Map.fromList [(BS.replicate 11 5, BS.replicate 12 5)]
            , mpfInMemoryIterators = Map.empty
            }

expectedMirrorValue :: Aeson.Value
expectedMirrorValue =
    Aeson.object
        [ "mirrorTries"
            Aeson..= [trieValue recordedToken [onePair], trieValue secondToken twoPairs]
        ]
  where
    onePair = hexPair (BS.replicate 1 1) (BS.replicate 2 1)
    twoPairs =
        [ hexPair (BS.replicate 3 2) (BS.replicate 4 2)
        , hexPair (BS.replicate 5 2) (BS.replicate 6 2)
        ]
    trieValue tok mpfPairs =
        Aeson.object
            [ "mtToken" Aeson..= T.pack (toHex (assetNameOf tok))
            , "mtMpf" Aeson..= mpfPairs
            , "mtKv" Aeson..= [hexPair (BS.replicate 7 3) (BS.replicate 8 3)]
            , "mtJournal" Aeson..= [hexPair (BS.replicate 9 4) (BS.replicate 10 4)]
            , "mtMetrics" Aeson..= [hexPair (BS.replicate 11 5) (BS.replicate 12 5)]
            ]
    assetNameOf (TokenId (AssetName n)) = SBS.fromShort n
    hexPair k v = Aeson.toJSON (T.pack (toHex k), T.pack (toHex v) :: Text)

-- ---------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------

refusalContaining :: String -> ErrorCall -> Bool
refusalContaining needle (ErrorCall msg) = needle `isInfixOf` msg

leftOf :: Either String a -> String
leftOf (Left e) = e
leftOf (Right _) = ""

withTempDir :: (FilePath -> IO a) -> IO a
withTempDir = withSystemTempDirectory "s269-deployment-spec"

newlineByte :: Word8
newlineByte = 0x0A

{- | Carriers of the recorded scripts at outputs other than the recorded
ones: the state script's under the second address, the request script's
under the first.
-}
movedState, movedRequest :: (TxIn, TxOut ConwayEra)
movedState = (outRefOf 'c' 1, publishedAt refAddr2 stateProgram 7_000_000)
movedRequest = (outRefOf 'd' 2, publishedAt refAddr1 requestProgram 8_000_000)
