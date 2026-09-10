{- | Generate test vectors for the MPFS cage validator.

Supports two output formats:

- JSON (default): language-neutral test vectors
- Aiken (@--aiken@): test functions for the Aiken validator
-}
module Main (main) where

import Aiken.Codegen (
    BodyM,
    Def (Blank, Test),
    Expr,
    ModuleM,
    bind,
    bindAs,
    call,
    comment,
    emit,
    field,
    hex,
    int,
    item,
    list,
    record,
    renderModule,
    runBody,
    runModule,
    useAs,
    useFrom,
    var,
    (.==),
 )
import Cardano.MPFS.Cage.AssetName (deriveAssetName)
import Cardano.MPFS.Cage.Proof (serializeProof, toProofSteps)
import Cardano.MPFS.Cage.Types
import Control.Lens (simple)
import Crypto.Hash (Blake2b_256, Digest, hash)
import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Encode.Pretty (encodePretty)
import Data.ByteArray (convert)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Lazy.Char8 qualified as BL8
import Data.Char (isAlphaNum, toLower)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as T
import MPF.Backend.Pure (
    MPFInMemoryDB,
    MPFPure,
    emptyMPFInMemoryDB,
    runMPFPure,
    runMPFPureTransaction,
 )
import MPF.Backend.Standalone (
    MPFStandalone (..),
    MPFStandaloneCodecs (..),
 )
import MPF.Hashes (
    MPFHash,
    fromHexKVHashes,
    isoMPFHash,
    mpfHashing,
    root,
 )
import MPF.Insertion (inserting)
import MPF.Proof.Insertion (MPFProof, mkMPFInclusionProof)
import PlutusCore.Data (Data (..))
import PlutusTx.Builtins.Internal (
    BuiltinByteString (..),
    BuiltinData (..),
 )
import PlutusTx.IsData.Class (ToData (..))
import System.Environment (getArgs)

-- -----------------------------------------------------------
-- MPF backend helpers
-- -----------------------------------------------------------

-- | ByteString codecs for MPF standalone backend.
bsCodecs :: MPFStandaloneCodecs ByteString ByteString MPFHash
bsCodecs =
    MPFStandaloneCodecs
        { mpfKeyCodec = simple
        , mpfValueCodec = simple
        , mpfNodeCodec = isoMPFHash
        }

-- | Insert a key-value pair.
insertKV :: ByteString -> ByteString -> MPFPure ()
insertKV k v =
    runMPFPureTransaction bsCodecs $
        inserting
            []
            fromHexKVHashes
            mpfHashing
            MPFStandaloneKVCol
            MPFStandaloneMPFCol
            k
            v

-- | Get the root hash.
getRootHash :: MPFPure (Maybe ByteString)
getRootHash =
    runMPFPureTransaction bsCodecs $ root MPFStandaloneMPFCol []

-- | Get inclusion proof for a key.
getProof :: ByteString -> MPFPure (Maybe (MPFProof MPFHash))
getProof k =
    runMPFPureTransaction bsCodecs $
        mkMPFInclusionProof
            []
            fromHexKVHashes
            mpfHashing
            MPFStandaloneMPFCol
            k

-- | Build a tree from key-value pairs.
buildTree :: [(ByteString, ByteString)] -> MPFInMemoryDB
buildTree kvs =
    snd $ runMPFPure emptyMPFInMemoryDB $ mapM_ (uncurry insertKV) kvs

-- | Get proof and root from a database (must exist).
getVec ::
    MPFInMemoryDB ->
    ByteString ->
    (MPFProof MPFHash, ByteString)
getVec db k =
    case fst $ runMPFPure db $ (,) <$> getProof k <*> getRootHash of
        (Just p, Just r) -> (p, r)
        _ -> error "getVec: missing proof or root"

-- | Get just the root (must exist).
getRoot :: MPFInMemoryDB -> ByteString -> ByteString
getRoot db k = snd $ getVec db k

-- -----------------------------------------------------------
-- Hex encoding
-- -----------------------------------------------------------

{- | Blake2b-256 hash a ByteString.
The Aiken MPF library hashes keys\/values with blake2b_256
internally. To make Haskell-generated proofs compatible,
we pre-hash keys so the trie paths match.
-}
blake2b :: ByteString -> ByteString
blake2b bs = convert (hash bs :: Digest Blake2b_256)

-- | Hex-encode a ByteString for JSON output.
toHex :: ByteString -> Text
toHex = T.decodeUtf8 . B16.encode

-- -----------------------------------------------------------
-- JSON helpers
-- -----------------------------------------------------------

-- | Encode a PlutusData value to its Data AST and render as JSON.
dataToJson :: Data -> Aeson.Value
dataToJson (Constr tag fields) =
    Aeson.object
        ["constructor" .= tag, "fields" .= map dataToJson fields]
dataToJson (I n) = Aeson.toJSON n
dataToJson (B bs) = Aeson.object ["bytes" .= toHex bs]
dataToJson (List xs) = Aeson.toJSON $ map dataToJson xs
dataToJson (Map kvs) =
    Aeson.toJSON $
        map
            ( \(k, v) ->
                Aeson.object ["k" .= dataToJson k, "v" .= dataToJson v]
            )
            kvs

-- | Encode a ToData value as JSON PlutusData.
toDataJson :: (ToData a) => a -> Aeson.Value
toDataJson x = let BuiltinData d = toBuiltinData x in dataToJson d

-- | Text literal as JSON value (avoids @:: Text@ annotations).
txt :: Text -> Aeson.Value
txt = Aeson.toJSON

-- -----------------------------------------------------------
-- Shared vector data types
-- -----------------------------------------------------------

{- | Raw proof test vector data.

Keys are stored in original (unhashed) form. The Haskell MPF
uses @blake2b(key)@ as the trie path, matching the Aiken MPF
which hashes keys internally.
-}
data ProofVec = ProofVec
    { pvDesc :: Text
    , pvKey :: ByteString
    -- ^ Original key (Aiken hashes internally)
    , pvValue :: ByteString
    -- ^ Original value
    , pvInitialRoot :: ByteString
    , pvExpectedRoot :: ByteString
    , pvProof :: MPFProof MPFHash
    }

-- | Raw asset name test vector data.
data AssetNameVec = AssetNameVec
    { anvDesc :: Text
    , anvTxId :: ByteString
    , anvOutputIndex :: Int
    , anvExpected :: ByteString
    }

-- -----------------------------------------------------------
-- Shared vector definitions
-- -----------------------------------------------------------

-- | The empty root (32 zero bytes).
emptyRoot :: ByteString
emptyRoot = BS.replicate 32 0

{- | Build a tree from key-value pairs, pre-hashing keys with
blake2b_256 to match the Aiken MPF's internal key hashing.
-}
buildTreeB2 :: [(ByteString, ByteString)] -> MPFInMemoryDB
buildTreeB2 kvs = buildTree [(blake2b k, v) | (k, v) <- kvs]

-- | Get proof and root using a blake2b-hashed key.
getVecB2 ::
    MPFInMemoryDB ->
    ByteString ->
    (MPFProof MPFHash, ByteString)
getVecB2 db k = getVec db $ blake2b k

-- | Get just the root using a blake2b-hashed key.
getRootB2 :: MPFInMemoryDB -> ByteString -> ByteString
getRootB2 db k = getRoot db $ blake2b k

rawProofVectors :: [ProofVec]
rawProofVectors =
    [ -- 1. Insert into empty trie
      let db = buildTreeB2 [("ab", "cd")]
          (p, r) = getVecB2 db "ab"
       in ProofVec "insert into empty trie" "ab" "cd" emptyRoot r p
    , -- 2. Insert creating fork
      let db1 = buildTreeB2 [("k1", "v1")]
          r1 = getRootB2 db1 "k1"
          db2 = buildTreeB2 [("k1", "v1"), ("k2", "v2")]
          (p2, r2) = getVecB2 db2 "k2"
       in ProofVec "insert creating fork" "k2" "v2" r1 r2 p2
    , -- 3. Insert with shared prefix
      let db1 = buildTreeB2 [("ka", "va")]
          r1 = getRootB2 db1 "ka"
          db2 = buildTreeB2 [("ka", "va"), ("kb", "vb")]
          (p2, r2) = getVecB2 db2 "kb"
       in ProofVec "insert with shared prefix" "kb" "vb" r1 r2 p2
    , -- 4. Inclusion proof for existing key
      let db = buildTreeB2 [("x", "1"), ("y", "2"), ("z", "3")]
          (p, r) = getVecB2 db "y"
       in ProofVec "inclusion proof for middle key" "y" "2" r r p
    ]

rawAssetNameVectors :: [AssetNameVec]
rawAssetNameVectors =
    [ let txId = BS.pack [0x01 .. 0x20]
          ref = OnChainTxOutRef (BuiltinByteString txId) 0
       in AssetNameVec
            "asset name from TxOutRef index 0"
            txId
            0
            $ deriveAssetName ref
    , let txId = BS.pack [0x01 .. 0x20]
          ref = OnChainTxOutRef (BuiltinByteString txId) 1
       in AssetNameVec
            "asset name from TxOutRef index 1"
            txId
            1
            $ deriveAssetName ref
    , let txId = BS.replicate 32 0
          ref = OnChainTxOutRef (BuiltinByteString txId) 255
       in AssetNameVec
            "asset name from zero txId index 255"
            txId
            255
            $ deriveAssetName ref
    ]

-- -----------------------------------------------------------
-- JSON rendering
-- -----------------------------------------------------------

-- | Render a proof vector as JSON.
proofVecToJson :: ProofVec -> Aeson.Value
proofVecToJson v =
    Aeson.object
        [ "description" .= pvDesc v
        , "initialRoot" .= toHex (pvInitialRoot v)
        , "key" .= toHex (pvKey v)
        , "value" .= toHex (pvValue v)
        , "expectedRoot" .= toHex (pvExpectedRoot v)
        , "proof"
            .= Aeson.object
                [ "steps" .= map toDataJson (toProofSteps $ pvProof v)
                , "cbor" .= toHex (serializeProof $ pvProof v)
                ]
        ]

-- | Render an asset name vector as JSON.
assetNameVecToJson :: AssetNameVec -> Aeson.Value
assetNameVecToJson v =
    Aeson.object
        [ "description" .= anvDesc v
        , "txId" .= toHex (anvTxId v)
        , "outputIndex" .= anvOutputIndex v
        , "expectedAssetName" .= toHex (anvExpected v)
        ]

-- | Datum encoding vectors (JSON only).
datumEncodingVectors :: [Aeson.Value]
datumEncodingVectors =
    [ let state =
            OnChainTokenState
                { stateOwner = BuiltinByteString $ BS.replicate 28 0xaa
                , stateStakeScript = Nothing
                , stateRoot = OnChainRoot $ BS.replicate 32 0xbb
                , stateMaxFee = 2000000
                , stateProcessTime = 300000
                , stateRetractTime = 600000
                }
       in Aeson.object
            [ "description" .= txt "StateDatum encoding"
            , "type" .= txt "CageDatum"
            , "plutusData" .= toDataJson (StateDatum state)
            ]
    , let req =
            OnChainRequest
                { requestToken =
                    OnChainTokenId $
                        BuiltinByteString $
                            BS.replicate 32 0xcc
                , requestOwner =
                    BuiltinByteString $ BS.replicate 28 0xdd
                , requestKey = BS.pack [0x01, 0x02, 0x03]
                , requestValue = OpInsert $ BS.pack [0x04, 0x05]
                , requestFee = 1000000
                , requestSubmittedAt = 1700000000000
                }
       in Aeson.object
            [ "description" .= txt "RequestDatum with OpInsert"
            , "type" .= txt "CageDatum"
            , "plutusData" .= toDataJson (RequestDatum req)
            ]
    , let ref =
            OnChainTxOutRef
                (BuiltinByteString $ BS.replicate 32 0xab)
                1
       in Aeson.object
            [ "description" .= txt "MintRedeemer Minting"
            , "type" .= txt "MintRedeemer"
            , "plutusData" .= toDataJson (Minting ref)
            ]
    , let tokenId =
            OnChainTokenId $
                BuiltinByteString $
                    BS.replicate 32 0xcc
       in Aeson.object
            [ "description" .= txt "MintRedeemer Burning"
            , "type" .= txt "MintRedeemer"
            , "plutusData" .= toDataJson (Burning tokenId)
            ]
    , Aeson.object
        [ "description" .= txt "UpdateRedeemer End"
        , "type" .= txt "UpdateRedeemer"
        , "plutusData" .= toDataJson End
        ]
    , let ref =
            OnChainTxOutRef
                (BuiltinByteString $ BS.replicate 32 0xee)
                0
       in Aeson.object
            [ "description" .= txt "UpdateRedeemer Sweep"
            , "type" .= txt "UpdateRedeemer"
            , "plutusData" .= toDataJson (Sweep ref)
            ]
    , Aeson.object
        [ "description"
            .= txt "UpdateRedeemer Modify mixed"
        , "type" .= txt "UpdateRedeemer"
        , "plutusData"
            .= toDataJson
                ( Modify
                    [ Update
                        [ Leaf 0 "\xaa" "\xbb"
                        ]
                    , Rejected
                    , Update
                        [ Branch 1 (BS.replicate 128 0)
                        ]
                    ]
                )
        ]
    , Aeson.object
        [ "description"
            .= txt "UpdateRedeemer Modify all-reject"
        , "type" .= txt "UpdateRedeemer"
        , "plutusData"
            .= toDataJson
                (Modify [Rejected, Rejected])
        ]
    , Aeson.object
        [ "description" .= txt "OpUpdate encoding"
        , "type" .= txt "OnChainOperation"
        , "plutusData" .= toDataJson (OpUpdate "\x01\x02" "\x03\x04")
        ]
    , Aeson.object
        [ "description" .= txt "OpDelete encoding"
        , "type" .= txt "OnChainOperation"
        , "plutusData" .= toDataJson (OpDelete "\xaa\xbb")
        ]
    ]

-- | All JSON vectors.
allJsonVectors :: [Aeson.Value]
allJsonVectors =
    map proofVecToJson rawProofVectors
        ++ map assetNameVecToJson rawAssetNameVectors
        ++ datumEncodingVectors

-- -----------------------------------------------------------
-- Aiken rendering (via aiken-codegen DSL)
-- -----------------------------------------------------------

-- | Sanitize description to Aiken test name.
descToTestName :: Text -> String
descToTestName desc =
    stripTrailing $ "vec_" ++ go False (T.unpack desc)
  where
    stripTrailing = reverse . dropWhile (== '_') . reverse
    go _ [] = []
    go prev (c : cs)
        | isAlphaNum c = toLower c : go False cs
        | prev = go True cs
        | otherwise = '_' : go True cs

-- | Convert a 'ProofStep' to an Aiken 'Expr'.
stepToExpr :: ProofStep -> Expr
stepToExpr (Branch skip neighbors) =
    record "Branch" $ do
        field "skip" $ int skip
        field "neighbors" $ hex neighbors
stepToExpr (Fork skip neighbor) =
    record "Fork" $ do
        field "skip" $ int skip
        field "neighbor" $ record "Neighbor" $ do
            field "nibble" $ int $ neighborNibble neighbor
            field "prefix" $ hex $ neighborPrefix neighbor
            field "root" $ hex $ neighborRoot neighbor
stepToExpr (Leaf skip key value) =
    record "Leaf" $ do
        field "skip" $ int skip
        field "key" $ hex key
        field "value" $ hex value

-- | Render a proof vector as an Aiken 'Def'.
proofVecToAiken :: ProofVec -> Def
proofVecToAiken ProofVec{..} =
    let name = descToTestName pvDesc
        steps = toProofSteps pvProof
        isInclusion = pvInitialRoot == pvExpectedRoot
        isEmpty = pvInitialRoot == emptyRoot
        trieE
            | isEmpty = var "mpf.empty"
            | otherwise = call "mpf.from_root" [hex pvInitialRoot]
        body :: BodyM Expr
        body = do
            proof <-
                bindAs "proof" "Proof" $
                    list $
                        mapM_ (item . stepToExpr) steps
            if isInclusion
                then
                    pure $
                        call
                            "mpf.has"
                            [trieE, hex pvKey, hex pvValue, proof]
                else do
                    trie <-
                        bind "trie" $
                            call
                                "mpf.insert"
                                [trieE, hex pvKey, hex pvValue, proof]
                    pure $
                        call "mpf.root" [trie]
                            .== hex pvExpectedRoot
     in Test name $ runBody body

-- | Render an asset name vector as an Aiken 'Def'.
assetNameVecToAiken :: AssetNameVec -> Def
assetNameVecToAiken AssetNameVec{..} =
    let name = descToTestName anvDesc
        body :: BodyM Expr
        body = do
            ref <- bind "ref" $ record "OutputReference" $ do
                field "transaction_id" $ hex anvTxId
                field "output_index" $ int $ fromIntegral anvOutputIndex
            pure $ call "assetName" [ref] .== hex anvExpected
     in Test name $ runBody body

-- | Generate complete Aiken module.
aikenModule :: ModuleM ()
aikenModule = do
    emit $ comment "Auto-generated cage test vectors"
    emit $ comment "Do not edit"
    emit $ comment "  run 'just generate-vectors'"
    emit $ comment "  to regenerate"
    emit Blank
    emit $
        useFrom
            "aiken/merkle_patricia_forestry"
            ["Branch", "Fork", "Leaf", "Neighbor", "Proof"]
    emit $ useAs "aiken/merkle_patricia_forestry" "mpf"
    emit $ useFrom "cardano/transaction" ["OutputReference"]
    emit $ useFrom "lib" ["assetName"]
    emit Blank
    mapM_ (emit . proofVecToAiken) rawProofVectors
    mapM_ (emit . assetNameVecToAiken) rawAssetNameVectors

-- -----------------------------------------------------------
-- Main
-- -----------------------------------------------------------

main :: IO ()
main = do
    args <- getArgs
    case args of
        ["--aiken"] ->
            putStr $ renderModule $ runModule aikenModule
        [] -> do
            let vectors = Aeson.object ["vectors" .= allJsonVectors]
            BL8.putStrLn $ encodePretty vectors
        _ -> do
            putStrLn "Usage: cage-test-vectors [--aiken]"
            putStrLn ""
            putStrLn "  (no args)  JSON test vectors"
            putStrLn "  --aiken    Aiken source with test functions"
