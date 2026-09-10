{- |
Module      : Cardano.MPFS.Cage.Trie.Pure
Description : Pure in-memory Trie backed by mts:mpf
License     : Apache-2.0

In-memory implementation of the 'Trie' interface
backed by an 'IORef' holding an 'MPFInMemoryDB'
from the @mts:mpf@ library.

All keys and values are hashed through MPF
conventions ('mkMPFHash') so proof paths match
what the Aiken on-chain validator expects.
-}
module Cardano.MPFS.Cage.Trie.Pure (
    -- * Construction
    mkPureTrie,
    mkPureTrieFromRef,

    -- * Internals (for TrieManager)
    getRootFromDb,
) where

import Data.ByteString (ByteString)
import Data.ByteString qualified as B
import Data.IORef (
    IORef,
    modifyIORef',
    newIORef,
    readIORef,
 )

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
import MPF.Deletion (deleting)
import MPF.Hashes (
    MPFHash,
    isoMPFHash,
    mkMPFHash,
    mpfHashing,
    renderMPFHash,
    root,
 )
import MPF.Insertion (inserting)
import MPF.Interface (
    FromHexKV (..),
    HexKey,
    byteStringToHexKey,
    hexKeyPrism,
 )
import MPF.Proof.Insertion (
    MPFProof,
    mkMPFInclusionProof,
 )

import Cardano.MPFS.Cage.Ledger (Root (..))
import Cardano.MPFS.Cage.Proof (toProofSteps)
import Cardano.MPFS.Cage.Trie (Trie (..))
import Cardano.MPFS.Cage.Types (ProofStep)

mpfHashCodecs :: MPFStandaloneCodecs HexKey MPFHash MPFHash
mpfHashCodecs =
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

hashKeyPath :: ByteString -> HexKey
hashKeyPath =
    byteStringToHexKey . renderMPFHash . mkMPFHash

insertByteStringM :: ByteString -> ByteString -> MPFPure ()
insertByteStringM k v =
    runMPFPureTransaction mpfHashCodecs $
        inserting
            []
            fromHexKVIdentity
            mpfHashing
            MPFStandaloneKVCol
            MPFStandaloneMPFCol
            (hashKeyPath k)
            (mkMPFHash v)

deleteMPFM :: HexKey -> MPFPure ()
deleteMPFM k =
    runMPFPureTransaction mpfHashCodecs $
        deleting
            []
            fromHexKVIdentity
            mpfHashing
            MPFStandaloneKVCol
            MPFStandaloneMPFCol
            k

proofMPFM :: HexKey -> MPFPure (Maybe (MPFProof MPFHash))
proofMPFM k =
    runMPFPureTransaction mpfHashCodecs $
        mkMPFInclusionProof
            []
            fromHexKVIdentity
            mpfHashing
            MPFStandaloneMPFCol
            k

rootHashM :: MPFPure (Maybe ByteString)
rootHashM =
    runMPFPureTransaction mpfHashCodecs $
        root MPFStandaloneMPFCol []

{- | Create a new empty 'Trie IO' backed by a fresh
'IORef' holding an empty in-memory MPF database.
-}
mkPureTrie :: IO (Trie IO)
mkPureTrie = do
    ref <- newIORef emptyMPFInMemoryDB
    pure (mkPureTrieFromRef ref)

{- | Build a 'Trie IO' from an existing 'IORef'.
Allows sharing the database with a 'TrieManager'.
-}
mkPureTrieFromRef :: IORef MPFInMemoryDB -> Trie IO
mkPureTrieFromRef ref =
    Trie
        { insert = pureInsert ref
        , delete = pureDelete ref
        , lookup = pureLookup ref
        , getRoot = pureGetRoot ref
        , getProofSteps = pureGetProofSteps ref
        }

-- | Insert a key-value pair.
pureInsert ::
    IORef MPFInMemoryDB ->
    ByteString ->
    ByteString ->
    IO Root
pureInsert ref k v = do
    db <- readIORef ref
    let ((), db') =
            runMPFPure db (insertByteStringM k v)
    modifyIORef' ref (const db')
    getRootFromDb db'

-- | Delete a key from the trie.
pureDelete ::
    IORef MPFInMemoryDB ->
    ByteString ->
    IO Root
pureDelete ref k = do
    db <- readIORef ref
    let hexKey =
            byteStringToHexKey $
                renderMPFHash $
                    mkMPFHash k
        ((), db') =
            runMPFPure db (deleteMPFM hexKey)
    modifyIORef' ref (const db')
    getRootFromDb db'

-- | Look up a value by key.
pureLookup ::
    IORef MPFInMemoryDB ->
    ByteString ->
    IO (Maybe ByteString)
pureLookup ref k = do
    db <- readIORef ref
    let hexKey =
            byteStringToHexKey $
                renderMPFHash $
                    mkMPFHash k
        (mProof, _) =
            runMPFPure db (proofMPFM hexKey)
    pure $ case mProof of
        Nothing -> Nothing
        Just _ ->
            Just (renderMPFHash (mkMPFHash k))

-- | Get current root hash.
pureGetRoot :: IORef MPFInMemoryDB -> IO Root
pureGetRoot ref = readIORef ref >>= getRootFromDb

-- | Get root hash from a database snapshot.
getRootFromDb :: MPFInMemoryDB -> IO Root
getRootFromDb db =
    let (mHash, _) = runMPFPure db rootHashM
     in pure $ case mHash of
            Nothing -> Root (B.replicate 32 0)
            Just h -> Root h

-- | Generate on-chain proof steps for a key.
pureGetProofSteps ::
    IORef MPFInMemoryDB ->
    ByteString ->
    IO (Maybe [ProofStep])
pureGetProofSteps ref k = do
    db <- readIORef ref
    let hexKey =
            byteStringToHexKey $
                renderMPFHash $
                    mkMPFHash k
        (mProof, _) =
            runMPFPure db (proofMPFM hexKey)
    pure $ case mProof of
        Nothing -> Nothing
        Just proof -> Just (toProofSteps proof)
