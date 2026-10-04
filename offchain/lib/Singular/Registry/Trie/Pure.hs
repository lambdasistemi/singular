{- |
Module      : Singular.Registry.Trie.Pure
Description : Pure in-memory Trie backed by mts:mpf
License     : Apache-2.0

In-memory implementation of the 'Trie' interface
backed by an 'IORef' holding an 'MPFInMemoryDB'
from the @mts:mpf@ library.

All keys and values are hashed through MPF
conventions ('mkMPFHash') so proof paths match
what the Aiken on-chain validator expects.
-}
module Singular.Registry.Trie.Pure
    ( -- * Construction
      mkPureTrie
    , mkPureTrieFromRef

      -- * Internals (for TrieManager)
    , getRootFromDb
    , rootFromDb
    , stateTrie
    , membershipFromDb
    , exclusionFromDb
    , verifyExclusion

      -- * Proofs against a trusted root
    , provesMember
    , provesAbsent
    ) where

import Control.Monad.State.Strict (State, get, gets, put)
import Data.ByteString (ByteString)
import Data.ByteString qualified as B
import Data.IORef
    ( IORef
    , modifyIORef'
    , newIORef
    , readIORef
    )

import MPF.Backend.Pure
    ( MPFInMemoryDB
    , MPFPure
    , emptyMPFInMemoryDB
    , runMPFPure
    , runMPFPureTransaction
    )
import MPF.Backend.Standalone
    ( MPFStandalone (..)
    , MPFStandaloneCodecs (..)
    )
import MPF.Deletion (deleting)
import MPF.Hashes
    ( MPFHash
    , isoMPFHash
    , mkMPFHash
    , mpfHashing
    , nullHash
    , parseMPFHash
    , renderMPFHash
    , root
    )
import MPF.Insertion (inserting)
import MPF.Interface
    ( FromHexKV (..)
    , HexKey
    , byteStringToHexKey
    , hexKeyPrism
    )
import MPF.Proof.Exclusion
    ( MPFExclusionProof
    , mkMPFExclusionProof
    , verifyMPFExclusionProof
    )
import MPF.Proof.Insertion
    ( MPFProof
    , mkMPFInclusionProof
    )
import MPF.Verify (verifyAikenInclusionProof)

import Singular.Registry.Ledger (Root (..))
import Singular.Registry.Proof (serializeProof, toProofSteps)
import Singular.Registry.Trie (Trie (..))
import Singular.Registry.Types (ProofStep)

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

exclusionMPFM :: HexKey -> MPFPure (Maybe (MPFExclusionProof MPFHash))
exclusionMPFM k =
    runMPFPureTransaction mpfHashCodecs $
        mkMPFExclusionProof
            []
            fromHexKVIdentity
            mpfHashing
            MPFStandaloneMPFCol
            k

{- | Whether the tree nodes of a database prove this key bound to this
value under a trusted root (#299). Only the tree the root commits to is
read, never the key index kept beside it, and the proof is checked in
the encoding the on-chain validator folds, against the trusted root
rather than the database's own.
-}
provesMember
    :: MPFInMemoryDB -> ByteString -> ByteString -> ByteString -> Bool
provesMember db trusted key value =
    case fst (runMPFPure db (proofMPFM (hashKeyPath key))) of
        Nothing -> False
        Just proof ->
            verifyAikenInclusionProof trusted key value (serializeProof proof)

{- | Whether the tree nodes of a database prove this key bound to
nothing under a trusted root (#299), from the tree alone, as
'provesMember' does. The all-zero root is the empty tree's.
-}
provesAbsent :: MPFInMemoryDB -> ByteString -> ByteString -> Bool
provesAbsent db trusted key =
    case fst (runMPFPure db (exclusionMPFM (hashKeyPath key))) of
        Nothing -> False
        Just proof -> verifyMPFExclusionProof mpfHashing trustedRoot proof
  where
    trustedRoot
        | trusted == renderMPFHash nullHash = Nothing
        | otherwise = parseMPFHash trusted

-- | The serialized membership proof produced from the authenticated nodes.
membershipFromDb :: MPFInMemoryDB -> ByteString -> Maybe ByteString
membershipFromDb db key =
    serializeProof <$> fst (runMPFPure db (proofMPFM (hashKeyPath key)))

-- | An exclusion proof produced from the same authenticated nodes.
exclusionFromDb
    :: MPFInMemoryDB -> ByteString -> Maybe (MPFExclusionProof MPFHash)
exclusionFromDb db key = fst (runMPFPure db (exclusionMPFM (hashKeyPath key)))

-- | Check an exclusion proof against its key and the caller's selected root.
verifyExclusion :: MPFExclusionProof MPFHash -> ByteString -> Bool
verifyExclusion proof trusted
    | trusted == renderMPFHash nullHash =
        verifyMPFExclusionProof mpfHashing Nothing proof
    | otherwise = case parseMPFHash trusted of
        Nothing -> False
        Just rootHash -> verifyMPFExclusionProof mpfHashing (Just rootHash) proof

-- | The pure root computation shared with the existing IO facade.
rootFromDb :: MPFInMemoryDB -> Root
rootFromDb db =
    case fst (runMPFPure db rootHashM) of
        Nothing -> Root (B.replicate 32 0)
        Just h -> Root h

-- | The existing MPF operations in genuine State, with no IORef or IO.
stateTrie :: Trie (State MPFInMemoryDB)
stateTrie =
    Trie
        { insert = \key value -> mutate (insertByteStringM key value)
        , delete = \key -> mutate (deleteMPFM (hashKeyPath key))
        , lookup = \key -> gets $ \db ->
            case membershipFromDb db key of
                Nothing -> Nothing
                Just _ -> Just (renderMPFHash (mkMPFHash key))
        , getRoot = gets rootFromDb
        , getProofSteps = \key -> gets $ \db ->
            toProofSteps <$> fst (runMPFPure db (proofMPFM (hashKeyPath key)))
        }
  where
    mutate action = do
        db <- get
        let ((), changed) = runMPFPure db action
        put changed
        pure (rootFromDb changed)

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
pureInsert
    :: IORef MPFInMemoryDB
    -> ByteString
    -> ByteString
    -> IO Root
pureInsert ref k v = do
    db <- readIORef ref
    let ((), db') =
            runMPFPure db (insertByteStringM k v)
    modifyIORef' ref (const db')
    getRootFromDb db'

-- | Delete a key from the trie.
pureDelete
    :: IORef MPFInMemoryDB
    -> ByteString
    -> IO Root
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
pureLookup
    :: IORef MPFInMemoryDB
    -> ByteString
    -> IO (Maybe ByteString)
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
getRootFromDb = pure . rootFromDb

-- | Generate on-chain proof steps for a key.
pureGetProofSteps
    :: IORef MPFInMemoryDB
    -> ByteString
    -> IO (Maybe [ProofStep])
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
