module Naming.RegisterSpec (spec) where

import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as Base16
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Word (Word8)
import Naming.Register
import Naming.Wire (decodeAddress)
import Test.Hspec
import Test.QuickCheck

-- ---------------------------------------------------------
-- Generators
-- ---------------------------------------------------------

genBytes :: Int -> Gen ByteString
genBytes n = BS.pack <$> vectorOf n arbitrary

genKeyHash :: Gen ByteString
genKeyHash = genBytes 28

genPolicyBytes :: Gen ByteString
genPolicyBytes = genBytes 28

genTokenName :: Gen ByteString
genTokenName = genBytes 32

genControl :: Gen ByteString
genControl = genBytes 29

genCommitment :: Gen ByteString
genCommitment = genBytes 32

genIncarnation :: Gen Word8
genIncarnation = arbitrary

-- ---------------------------------------------------------
-- Fixture vectors
-- ---------------------------------------------------------

-- | Seed-derived key1 control address bytes (29-byte enterprise
-- address of the ordinary party) from the first green devnet run.
vectorControl :: ByteString
vectorControl =
    mustHex "60adb59bbc097e8051233f8aa3c5a5113406e10c8510bc99378e78f242"

-- | Its next-control commitment from the same run.
vectorCommitment :: ByteString
vectorCommitment =
    mustHex "5516452c14bbaf610d6477e6aed883a500f5294349d291002c529e168dcd844d"

-- | Its 28-byte control key hash.
vectorKeyHash :: ByteString
vectorKeyHash =
    mustHex "adb59bbc097e8051233f8aa3c5a5113406e10c8510bc99378e78f242"

-- | Registry-identity fixtures for the bound name (NOTE-007): a mock state
-- policy and cage token name. INTERIM: the pinned name below is computed by
-- the mirror itself (same-side) pending replacement with a devnet-observed
-- triple after the new-names ledger run — see the handoff. It pins exact
-- output bytes for consumers either way.
vectorPolicy :: ByteString
vectorPolicy =
    mustHex "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

vectorToken :: ByteString
vectorToken =
    mustHex "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

mustHex :: String -> ByteString
mustHex s = case Base16.decode (TE.encodeUtf8 (T.pack s)) of
    Right bs -> bs
    Left _ -> error "fixture: bad hex literal"

-- ---------------------------------------------------------
-- Properties
-- ---------------------------------------------------------

spec :: Spec
spec = describe "Naming.Register (issue #77 derivations)" $ do
    describe "insertApprovalName" $ do
        it "is 32 bytes for generated control/commitment inputs" $
            property $
                forAll genControl $ \control ->
                    forAll genCommitment $ \commitment ->
                        BS.length (insertApprovalName control commitment) == 32
        it "never decodes as a canonical address" $
            property $
                forAll genControl $ \control ->
                    forAll genCommitment $ \commitment ->
                        decodeAddress (insertApprovalName control commitment)
                            == Nothing
        it "binds the control address: a different control gives a different name" $
            property $
                forAll genControl $ \control1 ->
                    forAll genControl $ \control2 ->
                        forAll genCommitment $ \commitment ->
                            (control1 /= control2)
                                ==> insertApprovalName control1 commitment
                                    /= insertApprovalName control2 commitment
        it "binds the commitment: a different commitment gives a different name" $
            property $
                forAll genControl $ \control ->
                    forAll genCommitment $ \commitment1 ->
                        forAll genCommitment $ \commitment2 ->
                            (commitment1 /= commitment2)
                                ==> insertApprovalName control commitment1
                                    /= insertApprovalName control commitment2
    describe "representativeName" $ do
        it "is 32 bytes: Rep prefix, 28-byte digest, incarnation last" $
            property $
                forAll genKeyHash $ \keyHash ->
                    forAll genPolicyBytes $ \policy ->
                        forAll genTokenName $ \token ->
                            forAll genIncarnation $ \incarnation ->
                                let name = representativeName keyHash policy token incarnation
                                 in BS.length name == 32
                                        && BS.take 3 name == representativePrefix
                                        && BS.last name == incarnation
        it "binds the key: a different key hash gives a different name" $
            property $
                forAll genKeyHash $ \keyHash1 ->
                    forAll genKeyHash $ \keyHash2 ->
                        forAll genPolicyBytes $ \policy ->
                            forAll genTokenName $ \token ->
                                (keyHash1 /= keyHash2)
                                    ==> representativeName keyHash1 policy token freshIncarnation
                                        /= representativeName keyHash2 policy token freshIncarnation
        it "binds the registry: a different policy or token gives a different name" $
            property $
                forAll genKeyHash $ \keyHash ->
                    forAll genPolicyBytes $ \policy1 ->
                        forAll genPolicyBytes $ \policy2 ->
                            forAll genTokenName $ \token1 ->
                                forAll genTokenName $ \token2 ->
                                    ((policy1 /= policy2) || (token1 /= token2))
                                        ==> representativeName keyHash policy1 token1 freshIncarnation
                                            /= representativeName keyHash policy2 token2 freshIncarnation
        it "never decodes as a canonical address" $
            property $
                forAll genKeyHash $ \keyHash ->
                    forAll genPolicyBytes $ \policy ->
                        forAll genTokenName $ \token ->
                            forAll genIncarnation $ \incarnation ->
                                decodeAddress (representativeName keyHash policy token incarnation)
                                    == Nothing
        it "fresh inserts scope incarnation 0x00" $
            property $
                forAll genKeyHash $ \keyHash ->
                    forAll genPolicyBytes $ \policy ->
                        forAll genTokenName $ \token ->
                            BS.last (representativeName keyHash policy token freshIncarnation)
                                == 0x00
    describe "fixture vectors (observed on devnet, agreed by the Aiken \
             \recomputation in the accepting fold)" $ do
        it "insertApprovalName pins the observed proposal binding" $
            insertApprovalName vectorControl vectorCommitment
                == mustHex "1f511271268613b7fecd6fe8946a2664e9c76caa24820dbb60ac295b0e593e43"
        it "representativeName pins the registry-bound representative" $
            representativeName vectorKeyHash vectorPolicy vectorToken freshIncarnation
                `shouldBe` mustHex "526570eb5767e31501fe4dc985e03a9bb3b249b1b50009fe50dbc09536bd6d00"
