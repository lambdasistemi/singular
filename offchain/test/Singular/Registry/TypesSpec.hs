module Singular.Registry.TypesSpec (spec) where

import Singular.Registry.AssetName (deriveAssetName)
import Singular.Registry.Types
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

{- | A C2 row index (#183). The seven admitted rows most of the time,
and a tag outside the table some of the time: the wire is a plain
integer, and a request the cage will refuse `edge-inadmissible` still
has to encode and decode, or no row could ever build one.
-}
genEdge :: Gen Edge
genEdge =
    frequency
        [ (7, chooseInteger (0, 6))
        , (3, chooseInteger (-4, 40))
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
        <*> genEdge
        <*> genNonNeg
        <*> genNonNeg
        <*> genDestination

-- | The destination a request names (#157 D-DEST).
genDestination :: Gen (BS.ByteString, BS.ByteString)
genDestination = (,) <$> genBS <*> genBS

genTokenState :: Gen OnChainTokenState
genTokenState =
    OnChainTokenState
        <$> genRoot
        <*> genNonNeg
        <*> genNonNeg
        <*> genNonNeg
        <*> genBBS28
        <*> genBBS28
        <*> genBBS28
        <*> genBBS28

genCageDatum :: Gen CageDatum
genCageDatum =
    oneof
        [ RequestDatum <$> genRequest
        , StateDatum <$> genTokenState
        , AbsentCustody <$> genBS <*> genBS
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

-- | The nth field of a value's own Constr encoding, if it has one.
fieldAt :: (ToData a) => Int -> a -> Maybe Data
fieldAt n x =
    let BuiltinData d = toBuiltinData x
     in case d of
            Constr _ fields
                | length fields > n -> Just (fields !! n)
            _ -> Nothing

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

    describe "Request edge and deposit (#183)" $ do
        -- The cage reads the tag out of field 3 and the deposit out of
        -- field 4 of the request's own Constr 0. A builder that wrote
        -- them anywhere else would make every fold refuse, so the
        -- POSITION is the claim, not just the roundtrip.
        it "the edge is the integer at field 3" $
            property $
                forAll genRequest $
                    \r -> fieldAt 3 r === Just (I (requestEdge r))
        it "the deposit is the integer at field 4" $
            property $
                forAll genRequest $
                    \r -> fieldAt 4 r === Just (I (requestDeposit r))
        -- A tag the cage refuses must still travel: a row that watches
        -- `edge-inadmissible` has to be able to build one.
        it "an inadmissible tag roundtrips like any other" $
            property $
                forAll (chooseInteger (7, 40)) $
                    \e ->
                        forAll genRequest $
                            \r -> roundtrips r{requestEdge = e}

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
        it "encodes the eight-field state in Aiken field order" $ do
            let state =
                    OnChainTokenState
                        { stateRoot =
                            OnChainRoot $
                                BS.replicate 32 0xbb
                        , stateMaxFee = 2000000
                        , stateProcessTime = 300000
                        , stateRetractTime = 600000
                        , stateAppPolicy =
                            BuiltinByteString $
                                BS.replicate 28 0xa9
                        , stateActivePolicy =
                            BuiltinByteString $
                                BS.replicate 28 0xaa
                        , stateAbsentPolicy =
                            BuiltinByteString $
                                BS.replicate 28 0xb0
                        , stateTerminalPolicy =
                            BuiltinByteString $
                                BS.replicate 28 0xc0
                        }
                BuiltinData datum = toBuiltinData state
            datum
                `shouldBe` Constr
                    0
                    [ B $ BS.replicate 32 0xbb
                    , I 2000000
                    , I 300000
                    , I 600000
                    , B $ BS.replicate 28 0xa9
                    , B $ BS.replicate 28 0xaa
                    , B $ BS.replicate 28 0xb0
                    , B $ BS.replicate 28 0xc0
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

    describe "requestPhase" $
        describe "with the fixed boundaries accept=100, retract=200" $ do
            it "folds the request as accepted before the process deadline" $
                requestPhase 100 200 50 `shouldBe` PhaseAccept
            it "retracts inside the retract window" $
                requestPhase 100 200 150 `shouldBe` PhaseRetract
            it "rejects once the retract deadline has passed" $
                requestPhase 100 200 300 `shouldBe` PhaseReject
            it "treats the accept deadline slot itself as too late to accept" $
                requestPhase 100 200 100 `shouldBe` PhaseRetract
            it "treats the retract deadline slot itself as rejectable" $
                requestPhase 100 200 200 `shouldBe` PhaseReject
