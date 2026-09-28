module Singular.Registry.TypesSpec (spec) where

import Control.Exception (evaluate)
import Data.ByteString qualified as BS
import PlutusCore.Data (Data (..))
import PlutusTx.Builtins.Internal
    ( BuiltinByteString (..)
    , BuiltinData (..)
    )
import PlutusTx.IsData.Class
    ( FromData (..)
    , ToData (..)
    , UnsafeFromData (..)
    )
import Singular.Registry.AssetName (deriveAssetName)
import Singular.Registry.Types
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
        , AbsentCustody <$> genBS
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
roundtrips
    :: (ToData a, FromData a, Show a, Eq a)
    => a
    -> Property
roundtrips x =
    fromBuiltinData (toBuiltinData x) === Just x

-- | The nth field of a value's own Constr encoding, if it has one.
fieldAt :: (ToData a) => Int -> a -> Maybe Data
fieldAt n x =
    let BuiltinData d = toBuiltinData x
    in  case d of
            Constr _ fields
                | length fields > n -> Just (fields !! n)
            _ -> Nothing

-- | Extract constructor index from Data encoding.
constrIndex :: (ToData a) => a -> Integer
constrIndex x =
    let BuiltinData d = toBuiltinData x
    in  case d of
            Constr n _ -> n
            _ -> error "expected Constr"

-- ---------------------------------------------------------
-- Fixed wire values (independent literal Data oracle)
-- ---------------------------------------------------------

-- The literals below are typed from the Aiken wire shapes, never
-- produced by the codec under test: they are the oracle the move must
-- keep byte-identical (roundtrips cannot see a symmetric field swap).

fixedTokenId :: OnChainTokenId
fixedTokenId = OnChainTokenId (BuiltinByteString "asset-name")

fixedTokenIdWire :: Data
fixedTokenIdWire = Constr 0 [B "asset-name"]

fixedRef :: OnChainTxOutRef
fixedRef = OnChainTxOutRef (BuiltinByteString "txid") 3

fixedRefWire :: Data
fixedRefWire = Constr 0 [B "txid", I 3]

fixedRoot :: OnChainRoot
fixedRoot = OnChainRoot "root-bytes"

fixedNeighbor :: Neighbor
fixedNeighbor =
    Neighbor 5 "prefix-nibbles" "neighbor-root-32-bytes"

fixedNeighborWire :: Data
fixedNeighborWire =
    Constr 0 [I 5, B "prefix-nibbles", B "neighbor-root-32-bytes"]

fixedMigration :: Migration
fixedMigration =
    Migration (BuiltinByteString "old-policy") fixedTokenId

fixedMigrationWire :: Data
fixedMigrationWire =
    Constr 0 [B "old-policy", fixedTokenIdWire]

fixedRequest :: OnChainRequest
fixedRequest =
    OnChainRequest
        fixedTokenId
        (BuiltinByteString "owner-28-byte-key")
        "trie-key"
        2
        7000001
        1700000000000
        ("dest-addr", "dest-datum-hash")

fixedRequestWire :: Data
fixedRequestWire =
    Constr
        0
        [ fixedTokenIdWire
        , B "owner-28-byte-key"
        , B "trie-key"
        , I 2
        , I 7000001
        , I 1700000000000
        , List [B "dest-addr", B "dest-datum-hash"]
        ]

fixedState :: OnChainTokenState
fixedState =
    OnChainTokenState
        { stateRoot = OnChainRoot "state-root-32-bytes"
        , stateMaxFee = 2000000
        , stateProcessTime = 300000
        , stateRetractTime = 600000
        , stateAppPolicy = BuiltinByteString "app-policy-bytes"
        , stateActivePolicy = BuiltinByteString "active-policy-bytes"
        , stateAbsentPolicy = BuiltinByteString "absent-policy-bytes"
        , stateTerminalPolicy = BuiltinByteString "terminal-policy-bytes"
        }

fixedStateWire :: Data
fixedStateWire =
    Constr
        0
        [ B "state-root-32-bytes"
        , I 2000000
        , I 300000
        , I 600000
        , B "app-policy-bytes"
        , B "active-policy-bytes"
        , B "absent-policy-bytes"
        , B "terminal-policy-bytes"
        ]

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
        it "wraps the asset name alone in constructor zero" $
            toBuiltinData fixedTokenId
                `shouldBe` BuiltinData fixedTokenIdWire

    describe "OnChainTxOutRef" $ do
        it "roundtrips via ToData/FromData" $
            property $
                forAll genTxOutRef roundtrips
        it "uses constructor index 0" $
            property $
                forAll genTxOutRef $
                    \x -> constrIndex x === 0
        it "puts the hash before the index in constructor zero" $
            toBuiltinData fixedRef
                `shouldBe` BuiltinData fixedRefWire

    describe "OnChainRoot" $ do
        it "roundtrips via ToData/FromData" $
            property $
                forAll genRoot roundtrips
        it "is a bare byte literal with no constructor wrapper" $
            toBuiltinData fixedRoot
                `shouldBe` BuiltinData (B "root-bytes")

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
        it "the seven admitted tags are zero through six in edge order" $ do
            edgeInsertAbsent `shouldBe` 0
            edgeInsertActive `shouldBe` 1
            edgeUpdateActive `shouldBe` 2
            edgeUpdateTerminal `shouldBe` 3
            edgeDeleteAbsent `shouldBe` 4
            edgeDeleteActive `shouldBe` 5
            edgeWitnessTerminal `shouldBe` 6
        it "names each admitted edge and any other tag by number" $ do
            edgeName edgeInsertAbsent `shouldBe` "insertAbsent"
            edgeName edgeInsertActive `shouldBe` "insertActive"
            edgeName edgeUpdateActive `shouldBe` "updateActive"
            edgeName edgeUpdateTerminal `shouldBe` "updateTerminal"
            edgeName edgeDeleteAbsent `shouldBe` "deleteAbsent"
            edgeName edgeDeleteActive `shouldBe` "deleteActive"
            edgeName edgeWitnessTerminal `shouldBe` "witnessTerminal"
            edgeName 9 `shouldBe` "edge-9"
            edgeName (-4) `shouldBe` "edge--4"

    describe "Neighbor" $ do
        it "roundtrips via ToData/FromData" $
            property $
                forAll genNeighbor roundtrips
        it "encodes nibble, prefix and root in constructor zero" $
            toBuiltinData fixedNeighbor
                `shouldBe` BuiltinData fixedNeighborWire

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
        it "a branch carries skip and neighbors in constructor zero" $
            toBuiltinData (Branch 1 "neighbor-hashes")
                `shouldBe` BuiltinData (Constr 0 [I 1, B "neighbor-hashes"])
        it "a fork carries skip and its nested neighbor in constructor one" $
            toBuiltinData (Fork 2 fixedNeighbor)
                `shouldBe` BuiltinData
                    (Constr 1 [I 2, fixedNeighborWire])
        it "a leaf carries skip, key and value in constructor two" $
            toBuiltinData (Leaf 3 "leaf-key" "leaf-value")
                `shouldBe` BuiltinData
                    (Constr 2 [I 3, B "leaf-key", B "leaf-value"])

    describe "OnChainRequest" $ do
        it "roundtrips via ToData/FromData" $
            property $
                forAll genRequest roundtrips
        it "encodes the seven fields in the exact Aiken order" $
            toBuiltinData fixedRequest
                `shouldBe` BuiltinData fixedRequestWire

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
        it "each policy accessor unwraps its own field's bytes" $ do
            stateAppPolicyBytes fixedState
                `shouldBe` "app-policy-bytes"
            stateActivePolicyBytes fixedState
                `shouldBe` "active-policy-bytes"
            stateAbsentPolicyBytes fixedState
                `shouldBe` "absent-policy-bytes"
            stateTerminalPolicyBytes fixedState
                `shouldBe` "terminal-policy-bytes"

    describe "CageDatum" $ do
        it "roundtrips via ToData/FromData" $
            property $
                forAll genCageDatum roundtrips
        it
            "decodes and re-encodes absent custody as refund-only constructor 2"
            $ do
                let wire = BuiltinData (Constr 2 [B "refund-only"])
                    decoded = fromBuiltinData wire :: Maybe CageDatum
                fmap toBuiltinData decoded `shouldBe` Just wire
        it "rejects the retired two-field absent-custody payload" $ do
            let wire = BuiltinData (Constr 2 [B "duplicated-key", B "refund"])
            (fromBuiltinData wire :: Maybe CageDatum) `shouldBe` Nothing
        it "RequestDatum uses constructor 0" $
            property $
                forAll (RequestDatum <$> genRequest) $
                    \x -> constrIndex x === 0
        it "StateDatum uses constructor 1" $
            property $
                forAll (StateDatum <$> genTokenState) $
                    \x -> constrIndex x === 1
        it "a request datum nests the request alone in constructor zero" $
            toBuiltinData (RequestDatum fixedRequest)
                `shouldBe` BuiltinData (Constr 0 [fixedRequestWire])
        it "a state datum nests the state alone in constructor one" $
            toBuiltinData (StateDatum fixedState)
                `shouldBe` BuiltinData (Constr 1 [fixedStateWire])

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
        it "a minting nests the output reference in constructor zero" $
            toBuiltinData (Minting fixedRef)
                `shouldBe` BuiltinData (Constr 0 [fixedRefWire])
        it "a migration nests old policy and token in constructor one" $
            toBuiltinData (Migrating fixedMigration)
                `shouldBe` BuiltinData (Constr 1 [fixedMigrationWire])
        it "a burning nests the token identifier in constructor two" $
            toBuiltinData (Burning fixedTokenId)
                `shouldBe` BuiltinData (Constr 2 [fixedTokenIdWire])

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
        it "an update lists its proof steps in constructor zero" $
            toBuiltinData (Update [Branch 1 "nb", Leaf 2 "k" "v"])
                `shouldBe` BuiltinData
                    ( Constr
                        0
                        [ List
                            [ Constr 0 [I 1, B "nb"]
                            , Constr 2 [I 2, B "k", B "v"]
                            ]
                        ]
                    )
        it "a rejection is the empty constructor one" $
            toBuiltinData Rejected
                `shouldBe` BuiltinData (Constr 1 [])

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
        it "an end is the empty constructor zero" $
            toBuiltinData End
                `shouldBe` BuiltinData (Constr 0 [])
        it "a contribute nests its reference in constructor one" $
            toBuiltinData (Contribute fixedRef)
                `shouldBe` BuiltinData (Constr 1 [fixedRefWire])
        it "a modify lists its actions in constructor two" $
            toBuiltinData (Modify [Rejected])
                `shouldBe` BuiltinData
                    (Constr 2 [List [Constr 1 []]])
        it "a retract nests its reference in constructor three" $
            toBuiltinData (Retract fixedRef)
                `shouldBe` BuiltinData (Constr 3 [fixedRefWire])
        it "a sweep nests its reference in constructor four" $
            toBuiltinData (Sweep fixedRef)
                `shouldBe` BuiltinData (Constr 4 [fixedRefWire])

    describe "UnsafeFromData" $ do
        it "reads the asset name back from its hand-typed wire" $
            unsafeFromBuiltinData (BuiltinData fixedTokenIdWire)
                `shouldBe` fixedTokenId
        it "reads the output reference back from its hand-typed wire" $
            unsafeFromBuiltinData (BuiltinData fixedRefWire)
                `shouldBe` fixedRef
        it "reads the root back from its bare hand-typed wire" $
            unsafeFromBuiltinData (BuiltinData (B "root-bytes"))
                `shouldBe` fixedRoot
        it "reads the seven-field request back from its hand-typed wire" $
            unsafeFromBuiltinData (BuiltinData fixedRequestWire)
                `shouldBe` fixedRequest
        it "reads the eight-field state back from its hand-typed wire" $
            unsafeFromBuiltinData (BuiltinData fixedStateWire)
                `shouldBe` fixedState
        it "reads a request datum back from its hand-typed wire" $
            unsafeFromBuiltinData
                (BuiltinData (Constr 0 [fixedRequestWire]))
                `shouldBe` RequestDatum fixedRequest
        it "reads a state datum back from its hand-typed wire" $
            unsafeFromBuiltinData
                (BuiltinData (Constr 1 [fixedStateWire]))
                `shouldBe` StateDatum fixedState
        it "reads refund-only custody back from its hand-typed wire" $
            unsafeFromBuiltinData
                (BuiltinData (Constr 2 [B "refund-addr"]))
                `shouldBe` AbsentCustody "refund-addr"
        it "reads the neighbor back from its hand-typed wire" $
            unsafeFromBuiltinData (BuiltinData fixedNeighborWire)
                `shouldBe` fixedNeighbor
        it "reads a branch step back from its hand-typed wire" $
            unsafeFromBuiltinData
                (BuiltinData (Constr 0 [I 1, B "nb"]))
                `shouldBe` Branch 1 "nb"
        it "reads a fork step back from its hand-typed wire" $
            unsafeFromBuiltinData
                (BuiltinData (Constr 1 [I 2, fixedNeighborWire]))
                `shouldBe` Fork 2 fixedNeighbor
        it "reads a leaf step back from its hand-typed wire" $
            unsafeFromBuiltinData
                ( BuiltinData
                    (Constr 2 [I 3, B "leaf-key", B "leaf-value"])
                )
                `shouldBe` Leaf 3 "leaf-key" "leaf-value"
        it "reads the migration parameters back from their wire" $
            unsafeFromBuiltinData (BuiltinData fixedMigrationWire)
                `shouldBe` fixedMigration
        it "reads a minting back from its hand-typed wire" $
            unsafeFromBuiltinData
                (BuiltinData (Constr 0 [fixedRefWire]))
                `shouldBe` Minting fixedRef
        it "reads a migrating back from its hand-typed wire" $
            unsafeFromBuiltinData
                (BuiltinData (Constr 1 [fixedMigrationWire]))
                `shouldBe` Migrating fixedMigration
        it "reads a burning back from its hand-typed wire" $
            unsafeFromBuiltinData
                (BuiltinData (Constr 2 [fixedTokenIdWire]))
                `shouldBe` Burning fixedTokenId
        it "reads an update action back from its hand-typed wire" $
            unsafeFromBuiltinData
                ( BuiltinData
                    ( Constr
                        0
                        [ List
                            [ Constr 0 [I 1, B "nb"]
                            , Constr 2 [I 3, B "leaf-key", B "leaf-value"]
                            ]
                        ]
                    )
                )
                `shouldBe` Update
                    [Branch 1 "nb", Leaf 3 "leaf-key" "leaf-value"]
        it "reads a rejection back from its hand-typed wire" $
            unsafeFromBuiltinData (BuiltinData (Constr 1 []))
                `shouldBe` Rejected
        it "reads an end back from its hand-typed wire" $
            unsafeFromBuiltinData (BuiltinData (Constr 0 []))
                `shouldBe` End
        it "reads a contribute back from its hand-typed wire" $
            unsafeFromBuiltinData
                (BuiltinData (Constr 1 [fixedRefWire]))
                `shouldBe` Contribute fixedRef
        it "reads a modify back from its hand-typed wire" $
            unsafeFromBuiltinData
                (BuiltinData (Constr 2 [List [Constr 1 []]]))
                `shouldBe` Modify [Rejected]
        it "reads a retract back from its hand-typed wire" $
            unsafeFromBuiltinData
                (BuiltinData (Constr 3 [fixedRefWire]))
                `shouldBe` Retract fixedRef
        it "reads a sweep back from its hand-typed wire" $
            unsafeFromBuiltinData
                (BuiltinData (Constr 4 [fixedRefWire]))
                `shouldBe` Sweep fixedRef
        it "a malformed asset wire is refused by the safe decoder" $
            fromBuiltinData (BuiltinData (Constr 0 [I 5]))
                `shouldBe` (Nothing :: Maybe OnChainTokenId)
        it "the same malformed wire makes the unsafe decoder fail" $
            evaluate
                ( unsafeFromBuiltinData
                    (BuiltinData (Constr 0 [I 5]))
                    :: OnChainTokenId
                )
                `shouldThrow` anyErrorCall

    describe "ConsumerRedeemer" $ do
        it "the hook is the empty constructor zero" $
            toBuiltinData Hook
                `shouldBe` BuiltinData (Constr 0 [])

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
                                in  deriveAssetName ref0
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
                                in  deriveAssetName ref1
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
