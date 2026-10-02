{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.Application.OpenDatum.BuildersSpec
Description : The open-datum application's script choice, bookings and update
License     : Apache-2.0

Pure rows over the production builders the CLI calls. Which application
a registry pins, and its applied script. The approval each booking mints,
the redeemer the mint arm reads and the outputs it reads by reference —
each redeemer is checked against the constructor order
@onchain/validators/application/envelope.ak@ declares. The refusals the
update builder makes before anything is built. Script acceptance of
these shapes is the Aiken rows' and the devnet journey's evidence, not
these.
-}
module Singular.Application.OpenDatum.BuildersSpec (spec) where

import Data.Bifunctor (bimap)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Short qualified as SBS
import Data.Either (isLeft, isRight)
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Lens.Micro ((&), (.~), (^.))
import Test.Hspec

import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.Api.Tx (witsTxL)
import Cardano.Ledger.Api.Tx.Out (TxOut, datumTxOutL, mkBasicTxOut)
import Cardano.Ledger.Api.Tx.Wits (Redeemers (..), rdmrsTxWitsL)
import Cardano.Ledger.BaseTypes (Network (Testnet))
import Cardano.Ledger.Mary.Value
    ( AssetName (..)
    , MaryValue (..)
    , MultiAsset (..)
    , PolicyID (..)
    )
import Cardano.Ledger.Plutus.ExUnits (ExUnits (..))
import PlutusCore.Data qualified as PLC
import PlutusCore.Version (plcVersion110)
import PlutusLedgerApi.V3 (serialiseUPLC)
import UntypedPlutusCore qualified as UPLC
import UntypedPlutusCore.DeBruijn ()

import Singular.Application.OpenDatum.Book
import Singular.Application.OpenDatum.Envelope
import Singular.Application.OpenDatum.Script
import Singular.Application.OpenDatum.Update
import Singular.PhaseLogFixture
    ( logObjects
    , phaseLines
    , textField
    , withLogFile
    )
import Singular.Registry.AssetName (deriveAssetName)
import Singular.Registry.Blueprint (NamingCodes (..), applyBytesParam)
import Singular.Registry.Config (CageConfig (..))
import Singular.Registry.Config.Application
import Singular.Registry.Deployment
    ( Deployment (..)
    , parseOutRef
    , renderOutRef
    )
import Singular.Registry.Ledger (Coin (..), ConwayEra, TxIn)
import Singular.Registry.Node.PhaseLog (loggedProvider, phaseLogAt)
import Singular.Registry.Provider (View (..), withView)
import Singular.Registry.StubView (servingView, stubView)
import Singular.Registry.TxBuilder.BookingFixture (preprodParams)
import Singular.Registry.TxBuilder.Edges (BookingApproval (..))
import Singular.Registry.TxBuilder.Internal
    ( addrFromKeyHashBytes
    , approvalName
    , computeScriptHash
    , mkInlineDatum
    , policyIdFromPin
    , scriptHashBytes
    , txInToRef
    )

spec :: Spec
spec = describe "the open-datum builders" $ do
    choice
    pinning
    bookings
    updates

-- ---------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------

-- | A well-formed one-parameter program, so parameters can be applied.
program :: SBS.ShortByteString
program =
    serialiseUPLC
        ( UPLC.Program
            ()
            plcVersion110
            (UPLC.LamAbs () (UPLC.DeBruijn 0) (UPLC.Var () (UPLC.DeBruijn 1)))
        )

registryId, otherRegistryId :: ByteString
registryId = BS.replicate 28 0x1f <> "cage-token"
otherRegistryId = BS.replicate 28 0x1f <> "cage-other"

codes :: NamingCodes
codes = NamingCodes{ncApplication = program, ncWitness = program}

applied :: SBS.ShortByteString
applied = openDatumScript registryId program

controller :: ByteString
controller = BS.replicate 28 0xd1

envelope :: Envelope
envelope =
    Envelope
        { envControl =
            Control
                { ctlVersion = envelopeVersion
                , ctlRegistry = StateAsset (BS.replicate 28 0x1f) "cage-token"
                , ctlActivePolicy = BS.replicate 28 0xaa
                , ctlKey = "keyA"
                , ctlController = controller
                , ctlDeposit = 2_000_000
                }
        , envPayload = PLC.B "alice"
        }

ref :: Char -> Int -> TxIn
ref c i = case parseOutRef (T.pack (replicate 64 c <> "#" <> show i)) of
    Right r -> r
    Left e -> error e

-- | The controller's wallet address.
wallet :: Addr
wallet = addrFromKeyHashBytes Testnet controller

-- ---------------------------------------------------------
-- The application a registry pins
-- ---------------------------------------------------------

choice :: Spec
choice = describe "the application a registry pins" $ do
    it "reads every application back from its blueprint title" $
        mapM (parseApplication . applicationTitle) [minBound .. maxBound]
            `shouldBe` Right [minBound .. maxBound]
    it "refuses a title no application is compiled from" $
        parseApplication "naming.naming" `shouldSatisfy` isLeft
    it "leaves the open application's codes exactly as read" $
        let out = applicationCodes OpenApplication registryId codes
        in  (ncApplication out, ncWitness out) `shouldBe` (program, program)
    it "applies the open-datum application to the registry identity" $
        ncApplication (applicationCodes OpenDatumApplication registryId codes)
            `shouldBe` applyBytesParam registryId program
    it "keeps the witnesses unapplied: the pins apply them per kind" $
        ncWitness (applicationCodes OpenDatumApplication registryId codes)
            `shouldBe` program
    it "gives two registries two open-datum policies" $
        openDatumPolicy (openDatumScript registryId program)
            `shouldNotBe` openDatumPolicy (openDatumScript otherRegistryId program)
    it "puts the address at the applied script's own hash" $
        BS.drop 1 (openDatumAddressBytes Testnet applied)
            `shouldBe` scriptHashBytes (computeScriptHash applied)

-- ---------------------------------------------------------
-- Bookings
-- ---------------------------------------------------------

mintedName :: BookingApproval -> Maybe ByteString
mintedName a = case baAsset a of
    MultiAsset m -> case Map.toList m of
        [(PolicyID _, names)] -> case Map.toList names of
            [(AssetName n, 1)] -> Just (SBS.fromShort n)
            _ -> Nothing
        _ -> Nothing

bookings :: Spec
bookings = describe "bookings" $ do
    let stateIn = ref '5' 0
        holdingIn = ref '4' 1
        insert = insertApproval Testnet applied stateIn envelope
        terminate = terminateApproval applied stateIn holdingIn "keyA" controller
    it
        "names an insertion's destination as this script and the envelope's hash"
        $ insertDestination Testnet applied envelope
            `shouldBe` (openDatumAddressBytes Testnet applied, envelopeHash envelope)
    it "mints one approval bound to the insertion it certifies" $
        mintedName insert
            `shouldBe` Just
                ( approvalName
                    1
                    "keyA"
                    controller
                    (insertDestination Testnet applied envelope)
                )
    it
        "carries BookInsert { key, owner, address, envelope } as constructor 0"
        $ baRedeemer insert
            `shouldBe` PLC.Constr
                0
                [ PLC.B "keyA"
                , PLC.B controller
                , PLC.B (openDatumAddressBytes Testnet applied)
                , envelopeToData envelope
                ]
    it "reads the registry state by reference when booking an insertion" $
        baReferenceInputs insert `shouldBe` Set.singleton stateIn
    it "binds a termination's approval to no destination" $
        mintedName terminate
            `shouldBe` Just (approvalName 3 "keyA" controller terminateDestination)
    it "carries BookTerminate { key, owner, holding } as constructor 1" $
        case baRedeemer terminate of
            PLC.Constr 1 [PLC.B k, PLC.B o, PLC.Constr 0 [PLC.B tx, PLC.I ix]] -> do
                (k, o, ix) `shouldBe` ("keyA", controller, 1)
                BS.length tx `shouldBe` 32
            other -> expectationFailure ("unexpected redeemer " <> show other)
    it
        "reads the state and the live output by reference, spending neither"
        $ baReferenceInputs terminate
            `shouldBe` Set.fromList [stateIn, holdingIn]

-- ---------------------------------------------------------
-- Update
-- ---------------------------------------------------------

liveWith :: Integer -> Maybe PLC.Data -> TxOut ConwayEra
liveWith quantity datum =
    let out =
            mkBasicTxOut
                wallet
                ( MaryValue
                    (Coin 2_000_000)
                    ( MultiAsset
                        ( Map.singleton
                            (policyIdFromPin (SBS.toShort (BS.replicate 28 0xaa)))
                            (Map.singleton (AssetName "keyA") quantity)
                        )
                    )
                )
    in  maybe out (\d -> out & datumTxOutL .~ mkInlineDatum d) datum

updates :: Spec
updates = describe "a payload update" $ do
    let args holding =
            UpdateArgs
                { uaView = stubView
                , uaApplied = applied
                , uaHolding = (ref '4' 1, holding)
                , uaPayload = PLC.I 7
                , uaFee = (ref '6' 0, liveWith 0 Nothing)
                , uaChange = wallet
                , uaReference = Nothing
                }
    it
        "logs the build of an update, refused or built, as the preview of an update reaches it (#363)"
        $ withLogFile
        $ \path -> do
            r <- updatePayloadTx (args (liveWith 1 Nothing))
            r `shouldSatisfy` isLeft
            objects <- logObjects path
            map (textField "builder") (phaseLines "build-body" objects)
                `shouldBe` [Just "updatePayloadTx"]
            map (textField "outcome") (phaseLines "build-body" objects)
                `shouldBe` [Just "refused"]
    it
        "an update that builds is logged as one build and its evaluations, \
        \the same as a refused one is (#363)"
        $ withLogFile
        $ \path -> do
            evaluations <- newIORef (0 :: Int)
            let view =
                    stubView
                        { viewProtocolParams = preprodParams
                        , viewEvaluateTx = \tx -> do
                            atomicModifyIORef' evaluations (\n -> (n + 1, ()))
                            let Redeemers m = tx ^. witsTxL . rdmrsTxWitsL
                            pure (Map.map (const (Right (ExUnits 500_000 200_000_000))) m)
                        }
                funding = mkBasicTxOut wallet (MaryValue (Coin 9_000_000_000) mempty)
                held = liveWith 1 (Just (envelopeToData envelope))
            built <-
                withView (loggedProvider (phaseLogAt path) (servingView view)) $ \v ->
                    updatePayloadTx
                        UpdateArgs
                            { uaView = v
                            , uaApplied = applied
                            , uaHolding = (ref '4' 1, held)
                            , uaPayload = PLC.I 7
                            , uaFee = (ref '6' 0, funding)
                            , uaChange = wallet
                            , uaReference = Nothing
                            }
            built `shouldSatisfy` isRight
            measured <- readIORef evaluations
            objects <- logObjects path
            measured `shouldSatisfy` (> 0)
            length (phaseLines "eval" objects) `shouldBe` measured
            map (textField "outcome") (phaseLines "build-body" objects)
                `shouldBe` [Just "ok"]
    it "refuses a live output with no inline datum, building nothing" $ do
        r <- updatePayloadTx (args (liveWith 1 Nothing))
        r `shouldSatisfy` isLeft
    it "refuses a live output whose datum is not an envelope" $ do
        r <- updatePayloadTx (args (liveWith 1 (Just (PLC.I 0))))
        r `shouldSatisfy` isLeft
    it "refuses a live output without its key's token" $ do
        r <-
            updatePayloadTx (args (liveWith 0 (Just (envelopeToData envelope))))
        r `shouldSatisfy` isLeft
    it "refuses a live output holding two of its key's token" $ do
        r <-
            updatePayloadTx (args (liveWith 2 (Just (envelopeToData envelope))))
        r `shouldSatisfy` isLeft
    it "keeps address, value and control, changing only the payload" $
        let live = liveWith 1 (Just (envelopeToData envelope))
            next = continuationOf live envelope (PLC.List [PLC.I 1])
        in  next
                `shouldBe` ( live
                                & datumTxOutL
                                    .~ mkInlineDatum
                                        (envelopeToData envelope{envPayload = PLC.List [PLC.I 1]})
                           )

-- ---------------------------------------------------------
-- Pinning at boot, re-deriving at attach
-- ---------------------------------------------------------

stateBytes, requestBytes :: SBS.ShortByteString
stateBytes = program
requestBytes = program

seedRef :: TxIn
seedRef = ref '9' 0

economics :: RegistryEconomics
economics = RegistryEconomics 30_000 30_000 (Coin 1_000_000)

bootWith :: Application -> TxIn -> (CageConfig, NamingCodes)
bootWith app seed =
    configForApplication
        app
        codes
        stateBytes
        requestBytes
        economics
        Testnet
        (txInToRef seed)

hexOf :: SBS.ShortByteString -> T.Text
hexOf = TE.decodeUtf8 . B16.encode . SBS.fromShort

-- | The deployment record a boot of this application from `seedRef` writes.
recordOf :: Application -> Deployment
recordOf app =
    let (cfg, _) = bootWith app seedRef
    in  Deployment
            { depRelease = "test"
            , depLeanRevision = "test"
            , depNetworkMagic = 42
            , depSeedOutRef = renderOutRef seedRef
            , depCageToken =
                TE.decodeUtf8 (B16.encode (deriveAssetName (txInToRef seedRef)))
            , depStatePolicy =
                TE.decodeUtf8 (B16.encode (scriptHashBytes (cfgScriptHash cfg)))
            , depRequestHash = "00"
            , depApplicationHash = hexOf (cfgApplicationPolicy cfg)
            , depRepresentativePolicy = hexOf (cfgActivePolicy cfg)
            , depProcessTime = 30_000
            , depRetractTime = 30_000
            , depTip = 1_000_000
            , depReferenceScripts = []
            , depBootstrapTxs = []
            }

-- | The application pin and the pinned code, the parts these rows compare.
pinsOf
    :: Either String (CageConfig, NamingCodes)
    -> Either String (SBS.ShortByteString, SBS.ShortByteString)
pinsOf = fmap (bimap cfgApplicationPolicy ncApplication)

pinning :: Spec
pinning = describe "pinning the application at boot and attach" $ do
    it
        "pins the open-datum script applied to the identity the seed determines"
        $ let (cfg, pinned) = bootWith OpenDatumApplication seedRef
              identity = registryIdentity stateBytes (txInToRef seedRef)
          in  do
                ncApplication pinned `shouldBe` openDatumScript identity program
                SBS.fromShort (cfgApplicationPolicy cfg)
                    `shouldBe` openDatumPolicy (ncApplication pinned)
    it "pins the open application as compiled, whatever the seed" $
        cfgApplicationPolicy (fst (bootWith OpenApplication seedRef))
            `shouldBe` cfgApplicationPolicy (fst (bootWith OpenApplication (ref '8' 0)))
    it "pins another open-datum policy for another seed" $
        cfgApplicationPolicy (fst (bootWith OpenDatumApplication seedRef))
            `shouldNotBe` cfgApplicationPolicy (fst (bootWith OpenDatumApplication (ref '8' 0)))
    it
        "re-derives, at attach, the configuration and codes the boot pinned"
        $ attachAs OpenDatumApplication (recordOf OpenDatumApplication)
            `shouldBe` pinsOf (Right (bootWith OpenDatumApplication seedRef))
    it
        "refuses to attach as open-datum to a registry that pins the open application"
        $ attachAs OpenDatumApplication (recordOf OpenApplication)
            `shouldSatisfy` isLeft
    it "refuses a record whose application hash was altered" $
        attachAs
            OpenDatumApplication
            (recordOf OpenDatumApplication){depApplicationHash = "00"}
            `shouldSatisfy` isLeft
    it "refuses a record whose seed was altered: every derived pin moves" $
        attachAs
            OpenDatumApplication
            (recordOf OpenDatumApplication)
                { depSeedOutRef = renderOutRef (ref '8' 0)
                }
            `shouldSatisfy` isLeft

-- | Attach as `app` to `dep`, keeping the parts these rows compare.
attachAs
    :: Application
    -> Deployment
    -> Either String (SBS.ShortByteString, SBS.ShortByteString)
attachAs app dep =
    pinsOf
        (cageConfigForApplication app codes stateBytes requestBytes dep)
