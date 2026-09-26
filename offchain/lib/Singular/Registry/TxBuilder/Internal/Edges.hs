{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.Registry.TxBuilder.Internal.Edges
Description : edge decisions, consumer binding and failure attribution
License     : Apache-2.0

One owner for the decisions a builder shares with the cage: what each
registry edge does to the trie ('walkEdge', the one place an edge and
its leaf bytes are paired), what an edge owes the mint ('deltaOf',
'policyOfKind', 'approvalName'), the pinned consumer binding
('ConsumerBinding', 'deriveConsumerBinding', 'mkConsumerScript'), and
node and builder-evaluation failure attribution ('failedWitnessHash',
'evalScriptHash', 'isBudgetFailure').

This is the edges-and-binding owner extracted from
@Singular.Registry.TxBuilder.Internal@; the public module re-exports
it and is its only intended consumer surface.
-}
module Singular.Registry.TxBuilder.Internal.Edges (
    -- * Registry-mode edges (#157 C2)
    leafAbsent,
    leafActive,
    leafTerminal,
    walkEdge,
    deltaOf,
    policyOfKind,
    approvalName,

    -- * Pinned-hook invocation (NOTE-021)
    pinScriptHash,
    hookAccountAddress,
    keyAccountAddress,
    ConsumerBinding (..),
    deriveConsumerBinding,
    mkConsumerScript,

    -- * Failure attribution (NOTE-023)
    failedWitnessHash,
    evalScriptHash,
    isBudgetFailure,
) where

import Cardano.Crypto.Hash (
    Blake2b_256,
    hashFromBytes,
    hashToBytes,
    hashWith,
 )
import Cardano.Ledger.Address (AccountAddress (..), AccountId (..))
import Cardano.Ledger.BaseTypes (Network)
import Cardano.Ledger.Core (Script)
import Cardano.Ledger.Credential (Credential (..))
import Cardano.Ledger.Hashes (ScriptHash (..))
import Cardano.Ledger.Keys (
    KeyHash (..),
    KeyRole (..),
 )
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Short qualified as SBS
import Data.Char (isHexDigit)
import Data.Coerce (coerce)
import Data.List (isInfixOf, isPrefixOf, tails)
import Data.Maybe (fromMaybe)
import Singular.Registry.Config (CageConfig (..))
import Singular.Registry.Ledger (ConwayEra)
import Singular.Registry.Trie (Trie (..))
import Singular.Registry.TxBuilder.Internal.Identity (
    computeScriptHash,
    scriptFromBytes,
    scriptHashBytes,
 )
import Singular.Registry.Types (
    Edge,
    ProofStep,
    edgeDeleteAbsent,
    edgeDeleteActive,
    edgeInsertAbsent,
    edgeInsertActive,
    edgeUpdateActive,
    edgeUpdateTerminal,
 )

-- ---------------------------------------------------------
-- Registry-mode edges (#157 C2)
-- ---------------------------------------------------------

{- | The three leaf states the registry admits (#157 D-CODEC). Requests
carry an edge, not a value, so these are no longer something a builder
chooses: they are the bytes each edge's trie move reads and writes, and
'walkEdge' below is the one place that pairs them with their edge.
-}
leafAbsent, leafActive, leafTerminal :: ByteString
leafAbsent = BS.singleton 0x00
leafActive = BS.singleton 0x01
leafTerminal = BS.singleton 0x02

{- | Walk one request's edge through a speculative trie and return the
proof steps the fold states for it (#183).

The edge names the move and its leaf bytes, from the table `types.ak`
publishes. The proof is the one the cage verifies at this request's own
position in the batch, so it is read BEFORE a delete or a replacement
and AFTER an insert, exactly as the cage's own walk does.

A tag outside the table names no move: the cage refuses it
`edge-inadmissible` before touching the trie, so the builder walks
nothing either and states the proof the refusal will be judged against.
A read (edge 6) leaves the leaf where it is (#157 C3).

One site, so the connected fold and the update builder cannot drift
apart about what an edge does to the trie.
-}
walkEdge :: (Monad m) => Trie m -> ByteString -> Edge -> m [ProofStep]
walkEdge trie key edge
    | edge == edgeInsertAbsent = inserting leafAbsent
    | edge == edgeInsertActive = inserting leafActive
    | edge == edgeUpdateActive = replacing leafActive
    | edge == edgeUpdateTerminal = replacing leafTerminal
    | edge == edgeDeleteAbsent = deleting
    | edge == edgeDeleteActive = deleting
    | otherwise = steps
  where
    steps = fromMaybe [] <$> getProofSteps trie key
    inserting leaf = do
        _ <- insert trie key leaf
        steps
    deleting = do
        before <- steps
        _ <- delete trie key
        pure before
    replacing leaf = do
        before <- steps
        _ <- delete trie key
        _ <- insert trie key leaf
        pure before

{- | What an edge owes the mint, as @(kind, quantity)@ over the three token
policies: kind 0 absent, 1 active, 2 terminal.
-}
deltaOf :: Integer -> [(Integer, Integer)]
deltaOf edge = case edge of
    0 -> [(0, 1)]
    1 -> [(1, 1)]
    2 -> [(0, -1), (1, 1)]
    3 -> [(1, -1)]
    4 -> [(0, -1)]
    5 -> [(1, -1)]
    6 -> [(2, 1)]
    _ -> []

-- | The policy a kind names in this registry's configuration.
policyOfKind :: CageConfig -> Integer -> SBS.ShortByteString
policyOfKind cfg kind = case kind of
    0 -> cfgAbsentPolicy cfg
    1 -> cfgActivePolicy cfg
    2 -> cfgTerminalPolicy cfg
    _ -> error "policyOfKind: not a token kind"

{- | The approval binding (#157 D-APPROVAL): the asset name the application
policy mints to certify one edge, @blake2b_256(edge ‖ key ‖ owner ‖
destination address ‖ destination datum hash)@. One formula, recomputed by
the cage from the request it rides; a builder that computes it differently
makes an honest booking refuse loudly at the fold.
-}
approvalName ::
    Integer ->
    -- | Registry key
    ByteString ->
    -- | Owner (the payment key hash the approval binds)
    ByteString ->
    -- | Destination: address bytes and datum hash
    (ByteString, ByteString) ->
    ByteString
approvalName edge key owner (destAddr, datumHash) =
    blake2b256
        ( BS.singleton (fromInteger edge)
            <> key
            <> owner
            <> destAddr
            <> datumHash
        )

blake2b256 :: ByteString -> ByteString
blake2b256 = hashToBytes . hashWith @Blake2b_256 id

-- ---------------------------------------------------------
-- Pinned-hook invocation (NOTE-020 item 1)
-- ---------------------------------------------------------

{- | The consumer pin as a ledger 'ScriptHash'. Loud on bad width
(the mint gate enforces 28 bytes on chain; this mirrors it
builder-side so a misconfigured pin fails at build, not on
ledger).
-}
pinScriptHash :: ByteString -> ScriptHash
pinScriptHash bs = case hashFromBytes bs of
    Just h -> ScriptHash h
    Nothing ->
        error
            "pinScriptHash: consumer pin must be 28 bytes"

{- | The withdrawal account for the pinned consumer: the exact script
credential from the pin, on the cage's network.
-}
hookAccountAddress :: Network -> ByteString -> AccountAddress
hookAccountAddress net pinBs =
    AccountAddress net (AccountId (ScriptHashObj (pinScriptHash pinBs)))

{- | A key-hash withdrawal account (exhibit controls only): lets a
row point a withdrawal at an ordinary key, where no script executes
and only the cage's own credential check can refuse. Loud on bad
width, like the pin helper above.
-}
keyAccountAddress :: Network -> ByteString -> AccountAddress
keyAccountAddress net khBs = case hashFromBytes khBs of
    Just h ->
        AccountAddress
            net
            ( AccountId
                ( KeyHashObj
                    (coerce (KeyHash h :: KeyHash Payment))
                )
            )
    Nothing ->
        error
            "keyAccountAddress: key hash must be 28 bytes"

{- | The bound exhibit consumer, unparameterized (NOTE-021): no
operator key, no appointed processor — the consumer authenticates
batches from transaction evidence alone. One derivation, used for
boot pinning, builder witnesses, and identity checks — never separate
computations that could disagree.
-}
data ConsumerBinding = ConsumerBinding
    { cbPin :: SBS.ShortByteString
    , cbScriptBytes :: SBS.ShortByteString
    , cbScript :: Script ConwayEra
    , cbHash :: ScriptHash
    }

deriveConsumerBinding ::
    SBS.ShortByteString -> ConsumerBinding
deriveConsumerBinding unapplied =
    let h = computeScriptHash unapplied
     in ConsumerBinding
            (SBS.toShort (scriptHashBytes h))
            unapplied
            (scriptFromBytes "consumer" unapplied)
            h

{- | Build the bound consumer 'Script' from config bytes (mirror of
'mkCageScript'). Builders attach this as the hook withdrawal witness.
-}
mkConsumerScript :: CageConfig -> Script ConwayEra
mkConsumerScript cfg =
    scriptFromBytes
        "mkConsumerScript"
        (cfgConsumerScript cfg)

-- ---------------------------------------------------------
-- Failure attribution (NOTE-023 item 2)
-- ---------------------------------------------------------

{- | Parse the node's named failed-witness field
(@The script hash is:ScriptHash "HEX"@) and return the hash — the
FIRST occurrence, which names the failing script (later occurrences
repeat the same failure's context). Anchored on the opening quote
(hash letters also occur in @ScriptHash@ itself, so a hex scan from
the marker misfires). Length-checked to 56 hex chars (a 28-byte
script hash) so partial garbage never matches. @Nothing@ when the
reason carries no named field (non-script failures: extraneous
witnesses, unregistered withdrawals, balance errors).
-}
failedWitnessHash :: String -> Maybe String
failedWitnessHash s =
    case findAfter "The script hash is:" s of
        Nothing -> Nothing
        Just rest -> case dropWhile (/= '"') rest of
            ('"' : after) ->
                let hex = takeWhile isHexDigit after
                 in if length hex == 56 then Just hex else Nothing
            _ -> Nothing

{- | Parse a builder-EVALUATION failure's named script field
(@pwcScriptHash = ScriptHash "HEX"@, first occurrence) and return
the hash. NOTE-018 bind: fork-occupied assertions match THIS field
against the derived applied identity — never a hex substring of the
full @ErrorCall@ show (transaction data, values and parameterized
script bytes can all contain the state policy). Same 56-hex rule.
-}
evalScriptHash :: String -> Maybe String
evalScriptHash s =
    case findAfter "pwcScriptHash = ScriptHash" s of
        Nothing -> Nothing
        Just rest -> case dropWhile (/= '"') rest of
            ('"' : after) ->
                let hex = takeWhile isHexDigit after
                 in if length hex == 56 then Just hex else Nothing
            _ -> Nothing

findAfter :: String -> String -> Maybe String
findAfter needle hay =
    case [ drop (length needle) t
         | t <- tails hay
         , needle `isPrefixOf` t
         ] of
        (r : _) -> Just r
        [] -> Nothing

{- | True when the refusal is budget exhaustion rather than a semantic
predicate failure. Kept to the OBSERVED node wording
(@overspending the budget@); unknown budget wordings fail closed
elsewhere (no named semantic match), never silently accepted.
-}
isBudgetFailure :: String -> Bool
isBudgetFailure s = "overspending the budget" `isInfixOf` s
