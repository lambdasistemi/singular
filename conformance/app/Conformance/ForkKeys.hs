{- |
Module      : Conformance.ForkKeys
Description : Offline grind for CS07 Fork-yielding trie keys
License     : Apache-2.0

CS07 needs a fold whose `ProofStep` list contains `Fork` (index 1).
Per @mts@\' @MPF.Proof.Insertion@: a level yields `Fork` when the
branch has exactly one non-empty sibling and that sibling is itself
a branch (a subtree holding two or more keys) rather than a leaf.
Random keys almost never form that shape — fifty sequential Insert
and Update folds produced only `Branch` and `Leaf`.

Keys enter the trie hashed (@mkMPFHash@ is BLAKE2b-256), so the shape
is ground out over key preimages with the real pipeline, then the
claim is verified with a pure trie before anything touches a devnet:

* @A,B@ share the first three nibbles and differ at the fourth: the
  pair forms a sub-branch under their shared prefix.
* @D,E@ share the first two nibbles with @A@ and differ from @A@\'s
  third nibble and from each other: they widen the sub-branch so a
  `Branch` step (two siblings) appears alongside the `Fork`.
* @C@ shares only the first nibble with @A@: at the root its sole
  sibling is the @A\/B\/D\/E@ sub-branch, which is exactly the `Fork`
  shape. Inserting @C@ last, its fold carries the `Fork`.

@runFindForkKeys@ prints the five ASCII keys and the verified proof
constructors for @C@. It fails loudly instead of printing keys whose
proof lacks a `Fork`.
-}
module Conformance.ForkKeys (
    findForkKeys,
    findPresentForkKeys,
    runCheckForkExclusion,
    runGrindPresentFork,
    runFindForkKeys,
    runShowAllProofs,
    runShowDProof,
    runShowNibbles,
) where

import Control.Exception (ErrorCall (..), throwIO)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as Base16
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Word (Word8)
import System.IO (BufferMode (..), hSetBuffering, stdout)

import MPF.Hashes (mkMPFHash, renderMPFHash)
import MPF.Interface (HexDigit (..), byteStringToHexKey)

import Cardano.Ledger.Mary.Value (AssetName (..))

import Cardano.MPFS.Cage.Ledger (Root (..), TokenId (..))
import Cardano.MPFS.Cage.Trie (TrieManager (..))
import Cardano.MPFS.Cage.Trie qualified as CageTrie
import Cardano.MPFS.Cage.Trie.Pure (mkPureTrieFromRef)
import Cardano.MPFS.Cage.Trie.PureManager (mkPureTrieManager)
import Cardano.MPFS.Cage.Types (Neighbor (..), ProofStep (..))
import Conformance.Mirror (mirrorExclusionSteps, mirrorExclusionVerifies, mirrorInsert, newMirror)

-- | Hash pipeline nibbles for a candidate key: the exact mapping the
-- trie uses to place the key.
nibbles :: ByteString -> [Word8]
nibbles =
    map unHexDigit
        . byteStringToHexKey
        . renderMPFHash
        . mkMPFHash

-- | Total prefix equality and positional difference on nibble lists.
eqPrefix :: Int -> [Word8] -> [Word8] -> Bool
eqPrefix n xs ys = take n xs == take n ys

diffAt :: Int -> [Word8] -> [Word8] -> Bool
diffAt i xs ys = case (drop i xs, drop i ys) of
    (x : _, y : _) -> x /= y
    _ -> False

-- | Grind @prefix <> show n@ for the first @n@ satisfying @ok@ on its
-- nibbles. Fails loudly past @cap@ rather than looping forever.
grind :: ByteString -> Int -> ([Word8] -> Bool) -> IO ByteString
grind prefix cap ok = go (0 :: Int)
  where
    go i
        | i > cap =
            failWith
                ( "find-fork-keys: no key for prefix "
                    <> show prefix
                    <> " in "
                    <> show cap
                    <> " tries"
                )
        | ok (nibbles cand) = pure cand
        | otherwise = go (i + 1)
      where
        cand = prefix <> TE.encodeUtf8 (T.pack (show i))

-- | The five keys @(A,B,D,E,C)@ with the shape described above, plus
-- the verified proof constructors for @C@\'s inclusion proof.
-- | The seven keys @(A,B,D,E,F,G,C)@ with the shape described above, plus
-- the verified proof constructors for @C@\'s inclusion proof (over the full
-- set) and @A@\'s update proof (over the pre-@C@ set, mirroring the devnet
-- fold order).
findForkKeys :: IO (ByteString, ByteString, ByteString, ByteString, ByteString, ByteString, ByteString, [String], [String], [String])
findForkKeys = do
    let keyA = "cs07-fork-A"
        na = nibbles keyA
    keyB <-
        grind
            "cs07-fork-B"
            500000
            (\nb -> eqPrefix 3 nb na && diffAt 3 nb na)
    keyD <-
        grind
            "cs07-fork-D"
            50000
            (\nd -> eqPrefix 2 nd na && diffAt 2 nd na)
    let nd = nibbles keyD
    keyE <-
        grind
            "cs07-fork-E"
            50000
            (\ne -> eqPrefix 2 ne na && diffAt 2 ne na && diffAt 2 ne nd)
    let na3 = nibbles keyA
        nb3 = nibbles keyB
    keyF <-
        grind
            "cs07-fork-F"
            500000
            (\nf -> eqPrefix 3 nf na && diffAt 3 nf na3 && diffAt 3 nf nb3)
    let nf3 = nibbles keyF
    keyG <-
        grind
            "cs07-fork-G"
            500000
            (\ng -> eqPrefix 3 ng na && diffAt 3 ng na3 && diffAt 3 ng nb3 && diffAt 3 ng nf3)
    keyC <-
        grind
            "cs07-fork-C"
            5000
            (\nc -> eqPrefix 1 nc na && diffAt 1 nc na)
    stepsC <- proofConstrsFor keyA keyB keyD keyE keyF keyG keyC
    require
        ("C proof lacks Fork: " <> show stepsC)
        ("Fork" `elem` stepsC)
    stepsB <- proofConstrsOn keyA keyB
    require
        ("B proof lacks Leaf: " <> show stepsB)
        ("Leaf" `elem` stepsB)
    stepsA <- updateProofConstrsOn keyA keyB keyD keyE keyF keyG
    require
        ("A update proof lacks Branch: " <> show stepsA)
        ("Branch" `elem` stepsA)
    pure (keyA, keyB, keyD, keyE, keyF, keyG, keyC, stepsC, stepsB, stepsA)

-- | Inclusion-proof constructors over a pure trie holding exactly the
-- given keys. No node, no chain: each shape claim, checked.
proofConstrsFor :: ByteString -> ByteString -> ByteString -> ByteString -> ByteString -> ByteString -> ByteString -> IO [String]
proofConstrsFor keyA keyB keyD keyE keyF keyG keyC = do
    tm <- mkPureTrieManager
    let tid = TokenId (AssetName "cs07-fork-token")
    createTrie tm tid
    withSpeculativeTrie tm tid $ \trie -> do
        _ <- CageTrie.insert trie keyA "va"
        _ <- CageTrie.insert trie keyB "vb"
        _ <- CageTrie.insert trie keyD "vd"
        _ <- CageTrie.insert trie keyE "ve"
        _ <- CageTrie.insert trie keyF "vf"
        _ <- CageTrie.insert trie keyG "vg"
        _ <- CageTrie.insert trie keyC "vc"
        mSteps <- CageTrie.getProofSteps trie keyC
        pure $ case mSteps of
            Nothing -> []
            Just steps -> map constrName steps

-- | @B@\'s inclusion proof over @{A,B}@ (mirrors devnet fold 2, which
-- proves after inserting, exactly like the builder\'s validProofs).
proofConstrsOn :: ByteString -> ByteString -> IO [String]
proofConstrsOn keyA keyB = do
    tm <- mkPureTrieManager
    let tid = TokenId (AssetName "cs07-fork-token")
    createTrie tm tid
    withSpeculativeTrie tm tid $ \trie -> do
        _ <- CageTrie.insert trie keyA "va"
        _ <- CageTrie.insert trie keyB "vb"
        mSteps <- CageTrie.getProofSteps trie keyB
        pure $ case mSteps of
            Nothing -> []
            Just steps -> map constrName steps

-- | @A@\'s update proof over @{A,B,D,E,F,G}@ (mirrors devnet fold 8,
-- which proves the existing value before replacing it).
updateProofConstrsOn :: ByteString -> ByteString -> ByteString -> ByteString -> ByteString -> ByteString -> IO [String]
updateProofConstrsOn keyA keyB keyD keyE keyF keyG = do
    tm <- mkPureTrieManager
    let tid = TokenId (AssetName "cs07-fork-token")
    createTrie tm tid
    withSpeculativeTrie tm tid $ \trie -> do
        _ <- CageTrie.insert trie keyA "va"
        _ <- CageTrie.insert trie keyB "vb"
        _ <- CageTrie.insert trie keyD "vd"
        _ <- CageTrie.insert trie keyE "ve"
        _ <- CageTrie.insert trie keyF "vf"
        _ <- CageTrie.insert trie keyG "vg"
        mSteps <- CageTrie.getProofSteps trie keyA
        pure $ case mSteps of
            Nothing -> []
            Just steps -> map constrName steps

constrName :: ProofStep -> String
constrName (Branch _ _) = "Branch"
constrName (Fork _ _) = "Fork"
constrName (Leaf _ _ _) = "Leaf"

-- | Nibble vectors refusing all theory: the ground keys\' exact paths.
runShowNibbles :: IO ()
runShowNibbles = do
    let showN k = emit (show k) (show (nibbles (TE.encodeUtf8 (T.pack k))))
    mapM_
        showN
        [ "cs07-fork-A"
        , "cs07-fork-B1294"
        , "cs07-fork-D127"
        , "cs07-fork-E400"
        , "cs07-fork-F1508"
        , "cs07-fork-G8495"
        , "cs07-fork-C11"
        ]

-- | Full Fork details for @D@ over @{A,B}@ (the refused devnet shape):
-- skip, neighbor nibble, neighbor prefix, neighbor root.
runShowDProof :: IO ()
runShowDProof = do
    tm <- mkPureTrieManager
    let tid = TokenId (AssetName "cs07-fork-token")
    createTrie tm tid
    strs <- withSpeculativeTrie tm tid $ \trie -> do
        _ <- CageTrie.insert trie "cs07-fork-A" "va"
        _ <- CageTrie.insert trie "cs07-fork-B1294" "vb"
        _ <- CageTrie.insert trie "cs07-fork-D127" "vd"
        mSteps <- CageTrie.getProofSteps trie "cs07-fork-D127"
        pure $ case mSteps of
            Nothing -> ["none"]
            Just steps -> map showStep steps
    mapM_ (emit "d-step") strs
  where
    showStep (Branch sk nb) = "Branch skip=" <> show sk <> " neighbors=" <> show (BS.length nb)
    showStep (Fork sk n) = "Fork skip=" <> show sk <> " nibble=" <> show (neighborNibble n) <> " prefix=" <> show (neighborPrefix n) <> " root=" <> show (neighborRoot n)
    showStep (Leaf sk k v) = "Leaf skip=" <> show sk <> " key=" <> show k <> " value=" <> show v

-- | Inclusion proofs for every present key over the full seven-key set.
-- An update fold proves a PRESENT key (Aiken\'s including() path, no
-- excluding()), so a Fork here is witnessable even if absent-key Forks
-- are not.
runShowAllProofs :: IO ()
runShowAllProofs = do
    (keyA, keyB, keyD, keyE, keyF, keyG, keyC, _, _, _) <- findForkKeys
    let keys =
            [ ("a", keyA, "va")
            , ("b", keyB, "vb")
            , ("d", keyD, "vd")
            , ("e", keyE, "ve")
            , ("f", keyF, "vf")
            , ("g", keyG, "vg")
            , ("c", keyC, "vc")
            ]
    tm <- mkPureTrieManager
    let tid = TokenId (AssetName "cs07-fork-token")
    createTrie tm tid
    strs <- withSpeculativeTrie tm tid $ \trie -> do
        mapM_ (\(_, k, v) -> CageTrie.insert trie k v) keys
        mapM
            (\(tag, k, _) -> do
                mSteps <- CageTrie.getProofSteps trie k
                pure $ case mSteps of
                    Nothing -> tag <> ": none"
                    Just steps -> tag <> ": " <> show (map constrName steps)
            )
            keys
    mapM_ (emit "present-proof") strs

-- | Offline verdict on the refused shape: cage/mirror backend root agreement
-- plus mts-core exclusion verification of @D@ over mirror @{A,B}@.
-- No node. A TRUE verdict with an on-chain refusal means the mts and
-- Aiken implementations diverge on Fork absence proofs; FALSE means mts
-- cannot verify the shape its sibling API generates.
-- | Proof constructors for @target@ over a pure cage trie holding exactly
-- @kvs@ (inserted in order). Present targets mirror update folds;
-- targets inserted last mirror insert folds. No node.
shapeOf :: [(ByteString, ByteString)] -> ByteString -> IO [String]
shapeOf kvs target = do
    tm <- mkPureTrieManager
    let tid = TokenId (AssetName "t81-probe-token")
    createTrie tm tid
    strs <- withSpeculativeTrie tm tid $ \trie -> do
        mapM_ (\(k, v) -> CageTrie.insert trie k v) kvs
        mSteps <- CageTrie.getProofSteps trie target
        pure $ case mSteps of
            Nothing -> ["none"]
            Just steps -> map constrName steps
    pure strs

-- | Present-key `Fork` grind (P-A): fixed K1; P shares nibble `[0]`;
-- Q shares `[0]` with a fresh index-1 nibble. Verified in the pure
-- cage trie with builder-identical call order.
findPresentForkKeys :: IO (ByteString, ByteString, ByteString, [String], [String], [String])
findPresentForkKeys = do
    let keyK = "t81-k1"
        nk = nibbles keyK
    keyP <-
        grind
            "t81-p"
            5000
            (\np -> eqPrefix 1 np nk && diffAt 1 np nk)
    let np1 = nibbles keyP
    keyQ <-
        grind
            "t81-q"
            50000
            (\nq -> eqPrefix 2 nq np1 && diffAt 2 nq np1)
    stepsP <- shapeOf [(keyK, "t81-v1"), (keyP, "t81-vp")] keyP
    require
        ("P proof unexpected: " <> show stepsP)
        ("Leaf" `elem` stepsP && "Fork" `notElem` stepsP)
    stepsQ <- shapeOf [(keyK, "t81-v1"), (keyP, "t81-vp"), (keyQ, "t81-vq")] keyQ
    require
        ("Q proof unexpected: " <> show stepsQ)
        ("Fork" `notElem` stepsQ)
    stepsK <- shapeOf [(keyK, "t81-v1"), (keyP, "t81-vp"), (keyQ, "t81-vq")] keyK
    require
        ("K1 proof lacks Fork: " <> show stepsK)
        ("Fork" `elem` stepsK)
    pure (keyK, keyP, keyQ, stepsP, stepsQ, stepsK)

runGrindPresentFork :: IO ()
runGrindPresentFork = do
    (keyK, keyP, keyQ, stepsP, stepsQ, stepsK) <- findPresentForkKeys
    emit "fork-key-k1" (show keyK)
    emit "fork-key-p" (show keyP)
    emit "fork-key-q" (show keyQ)
    emit "p-proof" (show stepsP)
    emit "q-proof" (show stepsQ)
    emit "k1-proof" (show stepsK)

runCheckForkExclusion :: IO ()
runCheckForkExclusion = do
    mirror <- newMirror
    mirrorInsert mirror "cs07-fork-A" "va"
    mirrorInsert mirror "cs07-fork-B1294" "vb"
    mirrorRoot <- unRoot <$> CageTrie.getRoot (mkPureTrieFromRef mirror)
    tm <- mkPureTrieManager
    let tid = TokenId (AssetName "cs07-fork-token")
    createTrie tm tid
    cageRoot <-
        withSpeculativeTrie tm tid $ \trie -> do
            _ <- CageTrie.insert trie "cs07-fork-A" "va"
            _ <- CageTrie.insert trie "cs07-fork-B1294" "vb"
            unRoot <$> CageTrie.getRoot trie
    emit "mirror-root" (hexBytes mirrorRoot)
    emit "cage-root" (hexBytes cageRoot)
    require
        ("cage and mirror roots disagree for {A,B}: " <> show (hexBytes cageRoot) <> " vs " <> show (hexBytes mirrorRoot))
        (cageRoot == mirrorRoot)
    verdict <- mirrorExclusionVerifies mirror "cs07-fork-D127" mirrorRoot
    emit "mts-exclusion-verifies" (show verdict)
    coreSteps <- mirrorExclusionSteps mirror "cs07-fork-D127"
    emit "mts-core-exclusion-steps" (show coreSteps)

runFindForkKeys :: IO ()
runFindForkKeys = do
    (keyA, keyB, keyD, keyE, keyF, keyG, keyC, stepsC, stepsB, stepsA) <- findForkKeys
    emit "fork-key-a" (show keyA)
    emit "fork-key-b" (show keyB)
    emit "fork-key-d" (show keyD)
    emit "fork-key-e" (show keyE)
    emit "fork-key-f" (show keyF)
    emit "fork-key-g" (show keyG)
    emit "fork-key-c" (show keyC)
    emit "c-proof" (show stepsC)
    emit "b-proof" (show stepsB)
    emit "a-update-proof" (show stepsA)

hexBytes :: ByteString -> String
hexBytes = T.unpack . TE.decodeUtf8 . Base16.encode

emit :: String -> String -> IO ()
emit stepName detail = do
    hSetBuffering stdout LineBuffering
    putStrLn (stepName <> ": " <> detail)

require :: String -> Bool -> IO ()
require label cond =
    if cond
        then pure ()
        else failWith label

failWith :: String -> IO a
failWith msg = throwIO (ErrorCall ("conformance: " <> msg))
