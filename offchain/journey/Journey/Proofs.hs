{- |
Module      : Journey.Proofs
Description : The authenticated-state checks, against roots read from chain
License     : Apache-2.0

Verification follows D-013: the library builds proofs
('mkMPFExclusionProof', 'mkMPFInclusionProof') from an in-memory mirror
kept in step with what the journey applied on chain; each proof is
folded to the root it implies and that root is compared against the
root read back from the chain's state datum — never against a root this
runner derived from the same trie.

* 'stepVerifyAbsent' — before the fold, the key is provably absent;
* 'stepVerifyPresent' — after it, the key is provably present with the
  expected value;
* 'rejectFalseClaim' — the same proof carrying a value the state does
  not hold must NOT reproduce the chain root.
-}
module Journey.Proofs
    ( stepVerifyAbsent
    , stepVerifyPresent
    , rejectFalseClaim
    , forgedValue
    ) where

import Control.Monad (unless, when)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.IORef (IORef, readIORef)

import MPF.Backend.Pure
    ( MPFInMemoryDB
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
    , foldMPFExclusionProof
    , mkMPFExclusionProof
    , verifyMPFExclusionProof
    )
import MPF.Proof.Insertion
    ( MPFProof (..)
    , foldMPFProof
    , mkMPFInclusionProof
    )

import Journey.Chain (readChainState)
import Journey.Narration (emit, failWith, hex, textOf)
import Journey.Steps (journeyKey, journeyValue)
import Singular.Registry.Config (CageConfig)
import Singular.Registry.Ledger (TokenId)
import Singular.Registry.Provider qualified as Cage
import Singular.Registry.Trie qualified as CageTrie
import Singular.Registry.Trie.Pure (mkPureTrieFromRef)
import Singular.Registry.Types
    ( OnChainRoot (..)
    , OnChainTokenState (..)
    )

-- | A value the state does not hold: the negative case's claim.
forgedValue :: ByteString
forgedValue = "forged"

{- | MPF codecs and key hashing with the exact conventions
the cage trie uses, so proof paths match what the on-chain
validator expects.
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

{- | Build the exclusion proof for a raw key against a
snapshot of the mirror database.
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

{- | Build the inclusion proof for a raw key against a
snapshot of the mirror database.
-}
inclusionProofFrom
    :: MPFInMemoryDB -> ByteString -> Maybe (MPFProof MPFHash)
inclusionProofFrom db k =
    fst $
        runMPFPure db $
            runMPFPureTransaction mpfCodecs $
                mkMPFInclusionProof
                    []
                    fromHexKVIdentity
                    mpfHashing
                    MPFStandaloneMPFCol
                    (mpfKeyPath k)

{- | The chain-read root as the exclusion verifier's trusted
root: the all-zero root denotes the empty trie.
-}
trustedRootFromChain :: OnChainRoot -> IO (Maybe MPFHash)
trustedRootFromChain (OnChainRoot bs)
    | bs == BS.replicate 32 0 = pure Nothing
    | otherwise = case parseMPFHash bs of
        Just h -> pure (Just h)
        Nothing ->
            failWith
                ("verify: malformed chain root 0x" <> hex bs)

{- | Verify the key is provably absent from the authenticated
state, before the insert: fold the exclusion proof and compare
the root it implies against the root read back from the chain.
-}
stepVerifyAbsent
    :: CageConfig
    -> Cage.Provider IO
    -> IORef MPFInMemoryDB
    -> TokenId
    -> IO ()
stepVerifyAbsent cfg prov mirrorRef tid = do
    chainRoot <- stateRoot <$> readChainState cfg prov tid
    trusted <- trustedRootFromChain chainRoot
    db <- readIORef mirrorRef
    proof <- case exclusionProofFrom db journeyKey of
        Just p -> pure p
        Nothing ->
            failWith $
                "proved-absent failed: key "
                    <> textOf journeyKey
                    <> " has no exclusion proof — the state holds it"
                    <> "; chain root 0x"
                    <> hex (unOnChainRoot chainRoot)
    let implied = foldMPFExclusionProof mpfHashing proof
    unless (verifyMPFExclusionProof mpfHashing trusted proof) $
        failWith $
            "proved-absent failed: key "
                <> textOf journeyKey
                <> " exclusion proof implies root "
                <> maybe "<empty trie>" (hex . renderMPFHash) implied
                <> " but the chain read root 0x"
                <> hex (unOnChainRoot chainRoot)
    emit
        "verify-absent"
        ( "proved absent key="
            <> textOf journeyKey
            <> " against chain root 0x"
            <> hex (unOnChainRoot chainRoot)
        )

{- | Verify the key is provably present with the expected
value, after the apply: replay the applied insert into the
mirror, bind the claimed value into the inclusion proof, fold
it, and compare against the chain-read root. Then run the
negative case, 'rejectFalseClaim', against the same proof and
the same chain root.
-}
stepVerifyPresent
    :: CageConfig
    -> Cage.Provider IO
    -> IORef MPFInMemoryDB
    -> TokenId
    -> IO ()
stepVerifyPresent cfg prov mirrorRef tid = do
    let mirror = mkPureTrieFromRef mirrorRef
    _ <- CageTrie.insert mirror journeyKey journeyValue
    chainRoot <- stateRoot <$> readChainState cfg prov tid
    db <- readIORef mirrorRef
    base <- case inclusionProofFrom db journeyKey of
        Just p -> pure p
        Nothing ->
            failWith $
                "proved-present failed: key "
                    <> textOf journeyKey
                    <> " has no inclusion proof; chain root 0x"
                    <> hex (unOnChainRoot chainRoot)
    let claimed = base{mpfProofValueHash = mkMPFHash journeyValue}
        implied = foldMPFProof mpfHashing claimed
    unless (renderMPFHash implied == unOnChainRoot chainRoot) $
        failWith $
            "proved-present failed: key "
                <> textOf journeyKey
                <> " value "
                <> hex journeyValue
                <> ": proof implies root 0x"
                <> hex (renderMPFHash implied)
                <> " but the chain read root 0x"
                <> hex (unOnChainRoot chainRoot)
    emit
        "verify-present"
        ( "proved present key="
            <> textOf journeyKey
            <> " value="
            <> hex journeyValue
            <> " root=0x"
            <> hex (unOnChainRoot chainRoot)
        )
    rejectFalseClaim base chainRoot

{- | The verifier's negative case: a proof asserting a value the
state does not hold ('forgedValue') must not reproduce the root
read back from the chain, and the runner must reject it. If it
did reproduce it, the negative case is not negative and the run
fails.
-}
rejectFalseClaim :: MPFProof MPFHash -> OnChainRoot -> IO ()
rejectFalseClaim base chainRoot = do
    let falseClaim = base{mpfProofValueHash = mkMPFHash forgedValue}
        falseRoot = foldMPFProof mpfHashing falseClaim
    when (renderMPFHash falseRoot == unOnChainRoot chainRoot) $
        failWith $
            "false-claim accepted: key "
                <> textOf journeyKey
                <> " claimed value "
                <> textOf forgedValue
                <> " reproduced the chain read root 0x"
                <> hex (unOnChainRoot chainRoot)
                <> " — the negative case is not negative"
    emit
        "verify-false-claim"
        ( "rejected false claim key="
            <> textOf journeyKey
            <> " claimed value="
            <> textOf forgedValue
            <> ": proof implies root 0x"
            <> hex (renderMPFHash falseRoot)
            <> " which differs from the chain read root 0x"
            <> hex (unOnChainRoot chainRoot)
        )
