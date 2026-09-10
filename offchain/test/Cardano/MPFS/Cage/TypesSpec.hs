module Cardano.MPFS.Cage.TypesSpec (spec) where

import Cardano.MPFS.Cage.AssetName (deriveAssetName)
import Cardano.MPFS.Cage.Types
import Data.ByteString qualified as BS
import PlutusCore.Data (Data (..))
import PlutusTx.Builtins.Internal (
    BuiltinByteString (..),
    BuiltinData (..),
 )
import PlutusTx.IsData.Class (
    FromData (..),
    ToData (..),
 )
import Test.Hspec
import Test.QuickCheck

-- ---------------------------------------------------------
-- Generators
-- ---------------------------------------------------------

genBBS :: Gen BuiltinByteString
genBBS = BuiltinByteString . BS.pack <$> listOf arbitrary

genBBS28 :: Gen BuiltinByteString
genBBS28 =
    BuiltinByteString . BS.pack
        <$> vectorOf 28 arbitrary

genBBS32 :: Gen BuiltinByteString
genBBS32 =
    BuiltinByteString . BS.pack
        <$> vectorOf 32 arbitrary

genMaybeStakeScript :: Gen (Maybe BuiltinByteString)
genMaybeStakeScript =
    frequency
        [ (3, pure Nothing)
        , (1, Just <$> genBBS28)
        ]

genBS :: Gen BS.ByteString
genBS = BS.pack <$> listOf arbitrary

genBS32 :: Gen BS.ByteString
genBS32 = BS.pack <$> vectorOf 32 arbitrary

genNonNeg :: Gen Integer
genNonNeg = getNonNegative <$> arbitrary

genTokenId :: Gen OnChainTokenId
genTokenId = OnChainTokenId <$> genBBS32

genTxOutRef :: Gen OnChainTxOutRef
genTxOutRef =
    OnChainTxOutRef
        <$> genBBS32
        <*> genNonNeg

genRoot :: Gen OnChainRoot
genRoot = OnChainRoot <$> genBS32

genOperation :: Gen OnChainOperation
genOperation =
    oneof
        [ OpInsert <$> genBS
        , OpDelete <$> genBS
        , OpUpdate <$> genBS <*> genBS
        ]

genNeighbor :: Gen Neighbor
genNeighbor =
    Neighbor
        <$> chooseInteger (0, 15)
        <*> genBS
        <*> genBS32

genProofStep :: Gen ProofStep
genProofStep =
    oneof
        [ Branch
            <$> genNonNeg
            <*> genBS
        , Fork
            <$> genNonNeg
            <*> genNeighbor
        , Leaf
            <$> genNonNeg
            <*> genBS
            <*> genBS
        ]

genRequest :: Gen OnChainRequest
genRequest =
    OnChainRequest
        <$> genTokenId
        <*> genBBS28
        <*> genBS
        <*> genOperation
        <*> genNonNeg
        <*> genNonNeg

genTokenState :: Gen OnChainTokenState
genTokenState =
    OnChainTokenState
        <$> genBBS28
        <*> genMaybeStakeScript
        <*> genRoot
        <*> genNonNeg
        <*> genNonNeg
        <*> genNonNeg

genCageDatum :: Gen CageDatum
genCageDatum =
    oneof
        [ RequestDatum <$> genRequest
        , StateDatum <$> genTokenState
        ]

genMigration :: Gen Migration
genMigration = Migration <$> genBBS <*> genTokenId

genMintRedeemer :: Gen MintRedeemer
genMintRedeemer =
    oneof
        [ Minting <$> genTxOutRef
        , Migrating <$> genMigration
        , Burning <$> genTokenId
        ]

genRequestAction :: Gen RequestAction
genRequestAction =
    oneof
        [ Update <$> listOf genProofStep
        , pure Rejected
        ]

genUpdateRedeemer :: Gen UpdateRedeemer
genUpdateRedeemer =
    oneof
        [ pure End
        , Contribute <$> genTxOutRef
        , Modify <$> listOf genRequestAction
        , Retract <$> genTxOutRef
        , Sweep <$> genTxOutRef
        ]

-- ---------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------

-- | Roundtrip property via ToData/FromData.
roundtrips ::
    (ToData a, FromData a, Show a, Eq a) =>
    a ->
    Property
roundtrips x =
    fromBuiltinData (toBuiltinData x) === Just x

-- | Extract constructor index from Data encoding.
constrIndex :: (ToData a) => a -> Integer
constrIndex x =
    let BuiltinData d = toBuiltinData x
     in case d of
            Constr n _ -> n
            _ -> error "expected Constr"

-- ---------------------------------------------------------
-- Spec
-- ---------------------------------------------------------

spec :: Spec
spec = do
    describe "OnChainTokenId" $ do
        it "roundtrips via ToData/FromData" $
            property $
                forAll genTokenId roundtrips
        it "uses constructor index 0" $
            property $
                forAll genTokenId $
                    \x -> constrIndex x === 0

    describe "OnChainTxOutRef" $ do
        it "roundtrips via ToData/FromData" $
            property $
                forAll genTxOutRef roundtrips
        it "uses constructor index 0" $
            property $
                forAll genTxOutRef $
                    \x -> constrIndex x === 0

    describe "OnChainRoot" $ do
        it "roundtrips via ToData/FromData" $
            property $
                forAll genRoot roundtrips

    describe "OnChainOperation" $ do
        it "roundtrips via ToData/FromData" $
            property $
                forAll genOperation roundtrips
        it "OpInsert uses constructor 0" $
            property $
                forAll (OpInsert <$> genBS) $
                    \x -> constrIndex x === 0
        it "OpDelete uses constructor 1" $
            property $
                forAll (OpDelete <$> genBS) $
                    \x -> constrIndex x === 1
        it "OpUpdate uses constructor 2" $
            property $
                forAll (OpUpdate <$> genBS <*> genBS) $
                    \x -> constrIndex x === 2

    describe "Neighbor" $ do
        it "roundtrips via ToData/FromData" $
            property $
                forAll genNeighbor roundtrips

    describe "ProofStep" $ do
        it "roundtrips via ToData/FromData" $
            property $
                forAll genProofStep roundtrips
        it "Branch uses constructor 0"
            $ property
            $ forAll
                ( Branch
                    <$> genNonNeg
                    <*> genBS
                )
            $ \x -> constrIndex x === 0
        it "Fork uses constructor 1"
            $ property
            $ forAll
                ( Fork
                    <$> genNonNeg
                    <*> genNeighbor
                )
            $ \x -> constrIndex x === 1
        it "Leaf uses constructor 2"
            $ property
            $ forAll
                ( Leaf
                    <$> genNonNeg
                    <*> genBS
                    <*> genBS
                )
            $ \x -> constrIndex x === 2

    describe "OnChainRequest" $ do
        it "roundtrips via ToData/FromData" $
            property $
                forAll genRequest roundtrips

    describe "OnChainTokenState" $ do
        it "roundtrips via ToData/FromData" $
            property $
                forAll genTokenState roundtrips
        it "encodes Nothing stake script in Aiken field order" $ do
            let state =
                    OnChainTokenState
                        { stateOwner =
                            BuiltinByteString $
                                BS.replicate 28 0xaa
                        , stateStakeScript = Nothing
                        , stateRoot =
                            OnChainRoot $
                                BS.replicate 32 0xbb
                        , stateMaxFee = 2000000
                        , stateProcessTime = 300000
                        , stateRetractTime = 600000
                        }
                BuiltinData datum = toBuiltinData state
            datum
                `shouldBe` Constr
                    0
                    [ B $ BS.replicate 28 0xaa
                    , Constr 1 []
                    , B $ BS.replicate 32 0xbb
                    , I 2000000
                    , I 300000
                    , I 600000
                    ]
        it "encodes Just stake script as Aiken Some" $ do
            let stakeScript =
                    BuiltinByteString $
                        BS.replicate 28 0xcc
                state =
                    OnChainTokenState
                        { stateOwner =
                            BuiltinByteString $
                                BS.replicate 28 0xaa
                        , stateStakeScript = Just stakeScript
                        , stateRoot =
                            OnChainRoot $
                                BS.replicate 32 0xbb
                        , stateMaxFee = 2000000
                        , stateProcessTime = 300000
                        , stateRetractTime = 600000
                        }
                BuiltinData datum = toBuiltinData state
            datum
                `shouldBe` Constr
                    0
                    [ B $ BS.replicate 28 0xaa
                    , Constr 0 [B $ BS.replicate 28 0xcc]
                    , B $ BS.replicate 32 0xbb
                    , I 2000000
                    , I 300000
                    , I 600000
                    ]

    describe "CageDatum" $ do
        it "roundtrips via ToData/FromData" $
            property $
                forAll genCageDatum roundtrips
        it "RequestDatum uses constructor 0" $
            property $
                forAll (RequestDatum <$> genRequest) $
                    \x -> constrIndex x === 0
        it "StateDatum uses constructor 1" $
            property $
                forAll (StateDatum <$> genTokenState) $
                    \x -> constrIndex x === 1

    describe "MintRedeemer" $ do
        it "roundtrips via ToData/FromData" $
            property $
                forAll genMintRedeemer roundtrips
        it "Minting uses constructor 0" $
            property $
                forAll (Minting <$> genTxOutRef) $
                    \x -> constrIndex x === 0
        it "Migrating uses constructor 1" $
            property $
                forAll (Migrating <$> genMigration) $
                    \x -> constrIndex x === 1
        it "Burning uses constructor 2" $
            property $
                forAll (Burning <$> genTokenId) $
                    \x -> constrIndex x === 2

    describe "RequestAction" $ do
        it "roundtrips via ToData/FromData" $
            property $
                forAll genRequestAction roundtrips
        it "Update uses constructor 0" $
            property $
                forAll (Update <$> listOf genProofStep) $
                    \x -> constrIndex x === 0
        it "Rejected uses constructor 1" $
            constrIndex Rejected
                `shouldBe` 1

    describe "UpdateRedeemer" $ do
        it "roundtrips via ToData/FromData" $
            property $
                forAll genUpdateRedeemer roundtrips
        it "End uses constructor 0" $
            constrIndex End
                `shouldBe` 0
        it "Contribute uses constructor 1" $
            property $
                forAll (Contribute <$> genTxOutRef) $
                    \x -> constrIndex x === 1
        it "Modify uses constructor 2"
            $ property
            $ forAll
                (Modify <$> listOf genRequestAction)
            $ \x -> constrIndex x === 2
        it "Retract uses constructor 3" $
            property $
                forAll (Retract <$> genTxOutRef) $
                    \x -> constrIndex x === 3
        it "Sweep uses constructor 4" $
            property $
                forAll (Sweep <$> genTxOutRef) $
                    \x -> constrIndex x === 4
        it "rejects unused Constr 5 encoding" $
            fromBuiltinData
                (BuiltinData (Constr 5 []))
                `shouldBe` (Nothing :: Maybe UpdateRedeemer)

    describe "deriveAssetName" $ do
        it "produces 32-byte output" $
            property $
                forAll genTxOutRef $
                    \ref ->
                        BS.length (deriveAssetName ref) === 32
        it "is deterministic" $
            property $
                forAll genTxOutRef $
                    \ref ->
                        deriveAssetName ref === deriveAssetName ref
        it "different index gives different name" $
            property $
                forAll genBBS32 $
                    \txId ->
                        forAll (arbitrary `suchThat` (/= 0)) $
                            \(n :: Integer) ->
                                let ref0 =
                                        OnChainTxOutRef txId 0
                                    ref1 =
                                        OnChainTxOutRef
                                            txId
                                            (abs n)
                                 in deriveAssetName ref0
                                        =/= deriveAssetName ref1
        it "different txId gives different name" $
            property $
                forAll genBBS32 $
                    \txId1 ->
                        forAll
                            (genBBS32 `suchThat` (/= txId1))
                            $ \txId2 ->
                                let ref1 =
                                        OnChainTxOutRef txId1 0
                                    ref2 =
                                        OnChainTxOutRef txId2 0
                                 in deriveAssetName ref1
                                        =/= deriveAssetName ref2
