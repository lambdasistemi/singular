{- |
Module      : Conformance.Mirror
Description : Chain-read proof verification for conformance rows
License     : Apache-2.0

The proof mirror: an in-memory trie kept in step with the operations
a run applies on chain. It builds the proofs; the roots those proofs
are checked against are always read back from the chain's state
datum (D-013), never from this trie. A value computed locally is not
evidence about the ledger; a locally built proof that implies the
chain-read root is.

The mirror machinery (@mpfCodecs@, the proof builders, the
fold-and-compare discipline) follows
@offchain\/journey\/Main.hs@, the closest working example of
everything this runner verifies.
-}
module Conformance.Mirror
    ( Mirror
    , newMirror
    , mirrorInsert
    , readChainState
    , mirrorExclusionSteps
    , mirrorExclusionVerifies
    , emit
    , failWith
    , require
    , hex
    , textOf
    , txIdHex
    ) where

import Control.Exception (ErrorCall (..), throwIO)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as Base16
import Data.IORef (IORef, newIORef, readIORef)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Singular.Registry.Evidence qualified as Cage
import System.IO (BufferMode (..), hSetBuffering, stdout)

import Cardano.Crypto.Hash.Class (hashToBytes)
import Cardano.Ledger.Api.Tx (txIdTx)
import Cardano.Ledger.Core (extractHash)
import Cardano.Ledger.TxIn (TxId (..))
import Cardano.Tx.Ledger (ConwayTx)
import MPF.Backend.Pure
    ( MPFInMemoryDB
    , emptyMPFInMemoryDB
    , runMPFPure
    , runMPFPureTransaction
    )
import MPF.Backend.Standalone
    ( MPFStandalone (..)
    , MPFStandaloneCodecs (..)
    )
import MPF.Hashes
    ( MPFHash
    , isoMPFHash
    , mkMPFHash
    , mpfHashing
    , parseMPFHash
    , renderMPFHash
    )
import MPF.Interface
    ( FromHexKV (..)
    , HexKey
    , byteStringToHexKey
    , hexKeyPrism
    )
import MPF.Proof.Exclusion
    ( MPFExclusionProof
    , mkMPFExclusionProof
    , mpfExclusionProofSteps
    , verifyMPFExclusionProof
    )
import MPF.Proof.Insertion (MPFProofStep (..))

import Singular.Registry.Config (CageConfig (..))
import Singular.Registry.Ledger (TokenId)
import Singular.Registry.LedgerProvider qualified as Cage
import Singular.Registry.SessionIO qualified as Cage
import Singular.Registry.Trie qualified as CageTrie
import Singular.Registry.Trie.Pure (mkPureTrieFromRef)
import Singular.Registry.TxBuilder.Internal
    ( cageAddrFromCfg
    , cagePolicyIdFromCfg
    , extractCageDatum
    , findStateUtxo
    )
import Singular.Registry.Types
    ( CageDatum (..)
    , OnChainRoot (..)
    , OnChainTokenState (..)
    )

-- | An in-memory trie kept in step with the chain.
type Mirror = IORef MPFInMemoryDB

newMirror :: IO Mirror
newMirror = newIORef emptyMPFInMemoryDB

mirrorInsert :: Mirror -> ByteString -> ByteString -> IO ()
mirrorInsert ref k v = do
    _ <- CageTrie.insert (mkPureTrieFromRef ref) k v
    pure ()

{- | Whether mts itself verifies an absence proof for @key@ against the
mirror\'s own root: prove via @mkMPFExclusionProof@, verify via
@verifyMPFExclusionProof@. No node, no chain — it separates "the
builder emits steps mts-core itself rejects" from "mts verifies but
the on-chain validator refuses".
-}

{- | Constructor names of mts-core\'s exclusion proof for @key@, if one is
constructible. Compares against what the cage layer emits for the same
key and trie: same shape means the refusal lies across the
Haskell/Aiken boundary; different shapes point at the builder.
-}
mirrorExclusionSteps :: Mirror -> ByteString -> IO (Maybe [String])
mirrorExclusionSteps ref key = do
    db <- readIORef ref
    pure $ case exclusionProofFrom db key of
        Nothing -> Nothing
        Just proof -> Just (map stepName (mpfExclusionProofSteps proof))
  where
    stepName s = case s of
        ProofStepLeaf{} -> "Leaf"
        ProofStepFork{} -> "Fork"
        ProofStepBranch{} -> "Branch"

mirrorExclusionVerifies
    :: Mirror -> ByteString -> ByteString -> IO Bool
mirrorExclusionVerifies ref key rootBytes = do
    db <- readIORef ref
    proof <- case exclusionProofFrom db key of
        Just p -> pure p
        Nothing ->
            failWith
                "mirrorExclusionVerifies: no exclusion proof constructible"
    trusted <- trustedRootFromChain (OnChainRoot rootBytes)
    pure (verifyMPFExclusionProof mpfHashing trusted proof)

{- | Read the current state datum for a token straight from the
chain: the state UTxO at the cage address. This is the only
comparison target for every verification below.
-}
readChainState
    :: CageConfig
    -> (Cage.Network, Cage.LedgerProvider Cage.NoWitness IO)
    -> TokenId
    -> IO OnChainTokenState
readChainState cfg prov tid = do
    stateUtxos <-
        Cage.withLatest
            prov
            (`Cage.outputsAt` cageAddrFromCfg cfg (network cfg))
    case findStateUtxo (cagePolicyIdFromCfg cfg) tid stateUtxos of
        Nothing ->
            failWith "verify: no state UTxO carrying the policy token"
        Just (_, out) -> case extractCageDatum out of
            Just (StateDatum s) -> pure s
            _ ->
                failWith
                    "verify: state UTxO datum is not a StateDatum"

-- ---------------------------------------------------------
-- Mirror internals (the journey pattern)
-- ---------------------------------------------------------

{- | The codecs the cage trie uses, so proof paths match what the
on-chain validator expects.
-}
mpfCodecs :: MPFStandaloneCodecs HexKey MPFHash MPFHash
mpfCodecs =
    MPFStandaloneCodecs
        { mpfKeyCodec = hexKeyPrism
        , mpfValueCodec = isoMPFHash
        , mpfNodeCodec = isoMPFHash
        }

fromHexKVIdentity :: FromHexKV HexKey MPFHash MPFHash
fromHexKVIdentity =
    FromHexKV
        { fromHexK = id
        , fromHexV = id
        , hexTreePrefix = const []
        }

-- | Keys enter the trie hashed, as the cage library hashes them.
mpfKeyPath :: ByteString -> HexKey
mpfKeyPath = byteStringToHexKey . renderMPFHash . mkMPFHash

{- | Build the exclusion proof for a raw key against a snapshot of
the mirror database.
-}
exclusionProofFrom
    :: MPFInMemoryDB -> ByteString -> Maybe (MPFExclusionProof MPFHash)
exclusionProofFrom db k =
    fst $
        runMPFPure db $
            runMPFPureTransaction mpfCodecs $
                mkMPFExclusionProof
                    []
                    fromHexKVIdentity
                    mpfHashing
                    MPFStandaloneMPFCol
                    (mpfKeyPath k)

{- | The chain-read root as the exclusion verifier's trusted root:
the all-zero root denotes the empty trie.
-}
trustedRootFromChain :: OnChainRoot -> IO (Maybe MPFHash)
trustedRootFromChain (OnChainRoot bs)
    | bs == BS.replicate 32 0 = pure Nothing
    | otherwise = case parseMPFHash bs of
        Just h -> pure (Just h)
        Nothing ->
            failWith
                ("verify: malformed chain root 0x" <> hex bs)

-- ---------------------------------------------------------
-- Output helpers
-- ---------------------------------------------------------

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

hex :: ByteString -> String
hex = T.unpack . TE.decodeUtf8 . Base16.encode

textOf :: ByteString -> String
textOf = T.unpack . TE.decodeUtf8Lenient

txIdHex :: ConwayTx -> String
txIdHex tx =
    let TxId h = txIdTx tx
    in  hex (hashToBytes (extractHash h))
