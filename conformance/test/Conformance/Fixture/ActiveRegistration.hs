{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Conformance.Fixture.ActiveRegistration
Description : The complete receipt artifact and its JSON mutations
License     : Apache-2.0

The complete observation together with the mutation helpers the
theorem-clause examples run through the loader. Fixtures live below
the example surface: cases name conditions and outcomes, and these
helpers build the JSON those names run against. Shared by the
migrated examples and the usage recipe; a single home, so a fixture
change cannot strand one consumer.

The guards from the original suite survive with the cases that use
them: the mutant set is read OUT of the complete artifact rather
than listed, and the extent is asserted at its known size before any
mutant runs, so a fixture broken for an unrelated reason cannot make
every mutant pass for the wrong reason.
-}
module Conformance.Fixture.ActiveRegistration (
    otherName,
    otherAddress,
    otherApproval,
    emptyValue,
    unlandedTx,
    activeAsset,
    activeHex,
    approvalHex,
    bootRoot,
    claimedMint,
    completeEdge,
    completeReceipt,
    configPins,
    dirCounter,
    duplicateLeg,
    dupControlTx,
    dupTx,
    edgeDrop,
    edgeKeys,
    edgeSet,
    entailedMint,
    foldStep,
    foldTx,
    keyAHex,
    keyBHex,
    keyedMintLeg,
    keyHex,
    legDrop,
    legKeysOf,
    legSet,
    loadOne,
    loadTwoFixtures,
    mintControlTx,
    mintOf,
    mintTx,
    onLeg,
    openHex,
    optionalLegKeys,
    receiptSet,
    refusalLegWith,
    root1,
    root2,
    root3,
    stateScriptHex,
    walletAddr,
    withEdge,
) where

import Data.Aeson (Value (..), encode, object, toJSON, (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Lazy qualified as BSL
import Data.IORef (IORef, atomicModifyIORef', newIORef)
import Data.List (sort)
import System.Directory (
    createDirectoryIfMissing,
    getTemporaryDirectory,
    removeDirectoryRecursive,
 )
import System.FilePath ((</>))
import System.IO.Unsafe (unsafePerformIO)
import Paths_conformance (getDataFileName)

import Conformance.Receipt (loadReceipts)

-- ---------------------------------------------------------
-- The complete artifact
-- ---------------------------------------------------------

-- | The parameterless open application's policy id.
openHex :: Value
openHex = String "4a2f1c9e83b70d5641ae2c08df93b1760ea5c42d8f6b3019ac7e5d22"

-- | The active witness policy: under it the asset name IS the key.
activeHex :: Value
activeHex = String "b71e04d9f2c35a8067de1b49ca20f5836d7e0c194ab52f63d8091e7c"

-- | The state script both refusals are attributed to.
stateScriptHex :: Value
stateScriptHex = String "0f3d5a71c28b4e690da1735c86fb02e94d7a61c30582bf49e7ad6c11"

keyHex :: Value
keyHex = String "743137332d696e736572742d616374697665"

foldTx, dupTx, dupControlTx, mintTx, mintControlTx :: Value
foldTx = String "aa11111111111111111111111111111111111111111111111111111111111111"
dupTx = String "bb22222222222222222222222222222222222222222222222222222222222222"
dupControlTx = String "cc33333333333333333333333333333333333333333333333333333333333333"
mintTx = String "dd44444444444444444444444444444444444444444444444444444444444444"
mintControlTx = String "ee55555555555555555555555555555555555555555555555555555555555555"

bootRoot, root1, root2, root3 :: Value
bootRoot = String "1000000000000000000000000000000000000000000000000000000000000000"
root1 = String "2000000000000000000000000000000000000000000000000000000000000000"
root2 = String "3000000000000000000000000000000000000000000000000000000000000000"
root3 = String "4000000000000000000000000000000000000000000000000000000000000000"

walletAddr :: Value
walletAddr = String "60a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b"

approvalHex :: Value
approvalHex =
    String "9c8b7a6958473625140f2e3d4c5b6a79889786756463524130f1e2d3"

-- | One active token at the key, and nothing else.
activeAsset :: Value
activeAsset =
    object ["policy" .= activeHex, "name" .= keyHex, "quantity" .= (1 :: Int)]

-- | The seven non-root pins of the eight-field state datum.
configPins :: Value
configPins =
    toJSON
        [ String "1000000"
        , String "30000"
        , String "30000"
        , openHex
        , activeHex
        , String "5c1e7ab390d24f6817be05c3a9f2d148e6730bc5924af18de036b7a1"
        , String "3b8d02f7561ec49a0d73b15fa28c6e904715d3ba6cf28017e94db5c6"
        ]

foldStep :: Value -> Value -> Value -> Value
foldStep txid before after =
    object
        [ "txid" .= txid
        , "rootBefore" .= before
        , "rootAfter" .= after
        , "committed" .= after
        ]

{- | A refusal leg, with the structured subjects of every relation it
claims.

A prose distinguisher says what differs between the refused shape and
its control; it cannot be checked. Every relation the row PROMISES —
which keys the batch named, what the transaction claimed to mint, what
its edges actually entail, what the accepting control minted — is
carried as a structured observation so the loader can reject a batch
that merely describes itself correctly.
-}
refusalLegWith :: Value -> Value -> Value -> [Value] -> [(Key.Key, Value)] -> Value
refusalLegWith txid controlTxid distinguisher keys extra =
    object
        ( [ "txid" .= txid
          , "hashes" .= toJSON [stateScriptHex]
          , -- The ledger's EvalFailure carries an EMPTY Plutus log list,
            -- so the validator's own trace is not recoverable from it.
            -- Absent, never guessed: the NAMES live in the compiled suite.
            "trace" .= Null
          , "controlTxid" .= controlTxid
          , "distinguisher" .= distinguisher
          , "keys" .= toJSON keys
          ]
            <> [k .= v | (k, v) <- extra]
        )

-- | The two DISTINCT keys the keyed-mint batch names.
keyAHex, keyBHex :: Value
keyAHex = String "743137332d6b6579656d696e742d61"
keyBHex = String "743137332d6b6579656d696e742d62"

mintOf :: Value -> Integer -> Value
mintOf name q =
    object ["policy" .= activeHex, "name" .= name, "quantity" .= q]

{- | What the two-key batch's edges actually entail: one active token at
each of the two keys.
-}
entailedMint :: Value
entailedMint = toJSON [mintOf keyAHex 1, mintOf keyBHex 1]

{- | What the refused transaction claimed instead: the same total under
the kind, both units at ONE key. A per-kind sum cannot see this; only
the per-(kind, key) comparison can, which is the whole fixture.
-}
claimedMint :: Value
claimedMint = toJSON [mintOf keyAHex 2]

{- | The duplicate leg. It names ONE key — the occupied one — and
carries NO mint arithmetic at all, because it is refused before any
runs. That absence is what keeps it from being read as the keyed-mint
witness.
-}
duplicateLeg :: Value
duplicateLeg =
    refusalLegWith
        dupTx
        dupControlTx
        (String "the key is already bound")
        [keyHex]
        []

-- | The keyed-mint leg: two distinct keys, and every mint it compares.
keyedMintLeg :: Value
keyedMintLeg =
    refusalLegWith
        mintTx
        mintControlTx
        (String "claimed 2/0 against 1/1 actually minted")
        [keyAHex, keyBHex]
        [ ("claimedMint", claimedMint)
        , ("entailedMint", entailedMint)
        , ("controlMint", entailedMint)
        ]

{- | The complete active-registration observation: the fold, every fine conjunct
of @insert_active_transaction_row@, the landed-fold sequence, and both
refusal legs with their accepting controls.
-}
completeEdge :: Value
completeEdge =
    object
        [ "openPolicy" .= openHex
        , "openParameters" .= (0 :: Int)
        , "activePolicy" .= activeHex
        , "key" .= keyHex
        , "foldTxid" .= foldTx
        , "minted" .= toJSON [activeAsset]
        , "requestedAddress" .= walletAddr
        , "observedAddress" .= walletAddr
        , "delivered" .= toJSON [activeAsset]
        , "maxFee" .= (1_000_000 :: Int)
        , "requestLovelace" .= (3_000_000 :: Int)
        , "approvalName" .= approvalHex
        , "approvalRecomputed" .= approvalHex
        , "refunds" .= toJSON ([] :: [Int])
        , "signers" .= toJSON ([] :: [Value])
        , "configBefore" .= configPins
        , "configAfter" .= configPins
        , "sequence"
            .= toJSON
                [ foldStep foldTx bootRoot root1
                , foldStep dupControlTx root1 root2
                , foldStep mintControlTx root2 root3
                ]
        , "duplicate" .= duplicateLeg
        , "keyedMint" .= keyedMintLeg
        ]

-- | The active-registration receipt the runner writes, with a complete observation.
completeReceipt :: Value
completeReceipt =
    object
        [ "row" .= String "CG21"
        , "outcome" .= String "accepted"
        , "verdict" .= String "agrees-with-model"
        , "transactions" .= toJSON [foldTx]
        , "refusal" .= Null
        , "rejected" .= Null
        , "mem" .= (1000 :: Int)
        , "cpu" .= (2000 :: Int)
        , "txSize" .= (500 :: Int)
        , "base" .= String "fixture-base"
        , "dirty" .= False
        , "node" .= String "fixture-node"
        , "blueprint" .= String "fixture-blueprint"
        , "venue" .= String "node-submit"
        , "partial" .= Null
        , "edge" .= completeEdge
        , "derivation" .= Null
        ]

-- ---------------------------------------------------------
-- Mutation helpers
-- ---------------------------------------------------------

-- | Replace the receipt's edge observation.
withEdge :: Value -> Value
withEdge e = case completeReceipt of
    Object o -> Object (KM.insert "edge" e o)
    v -> v

-- | Replace one field of the receipt itself.
receiptSet :: String -> Value -> Value
receiptSet k v = case completeReceipt of
    Object o -> Object (KM.insert (Key.fromString k) v o)
    x -> x

-- | Edit one field of the edge observation.
edgeSet :: String -> Value -> Value
edgeSet k v = case completeEdge of
    Object o -> withEdge (Object (KM.insert (Key.fromString k) v o))
    x -> x

-- | Drop one field of the edge observation.
edgeDrop :: String -> Value
edgeDrop k = case completeEdge of
    Object o -> withEdge (Object (KM.delete (Key.fromString k) o))
    x -> x

-- | Edit one field of a named refusal leg.
legSet :: String -> String -> Value -> Value
legSet leg k v = onLeg leg (KM.insert (Key.fromString k) v)

-- | Drop one field of a named refusal leg.
legDrop :: String -> String -> Value
legDrop leg k = onLeg leg (KM.delete (Key.fromString k))

onLeg :: String -> (KM.KeyMap Value -> KM.KeyMap Value) -> Value
onLeg leg f = case completeEdge of
    Object o -> case KM.lookup (Key.fromString leg) o of
        Just (Object l) ->
            withEdge (Object (KM.insert (Key.fromString leg) (Object (f l)) o))
        _ -> completeReceipt
    _ -> completeReceipt

-- | Every field the complete observation actually carries.
edgeKeys :: [String]
edgeKeys = case completeEdge of
    Object o -> sort (map Key.toString (KM.keys o))
    _ -> []

-- | Every field the named refusal leg actually carries.
legKeysOf :: String -> [String]
legKeysOf leg = case completeEdge of
    Object o -> case KM.lookup (Key.fromString leg) o of
        Just (Object l) -> sort (map Key.toString (KM.keys l))
        _ -> []
    _ -> []

{- | The one leg field that may be absent: the ledger surfaces no trace
for a script-execution failure, so a leg recording its absence is
complete.
-}
optionalLegKeys :: [String]
optionalLegKeys = ["trace"]

-- | Write one receipt into a fresh directory and load it.
loadOne :: Value -> IO (Either String Int)
loadOne receipt = do
    tmp <- getTemporaryDirectory
    n <- atomicModifyIORef' dirCounter (\i -> (i + 1, i))
    let dir = tmp </> ("conformance-edge-spec-" <> show n)
    createDirectoryIfMissing True dir
    BSL.writeFile (dir </> "receipt-CG21.json") (encode receipt)
    result <- loadReceipts dir
    removeDirectoryRecursive dir
    pure (fmap length result)

dirCounter :: IORef Int
dirCounter = unsafePerformIO (newIORef 0)
{-# NOINLINE dirCounter #-}

-- | Load the committed fixture receipts through the real loader. Both
-- rows in @test/fixtures/receipts@ are valid, so this genuinely
-- returns two receipts. Every accepts in this slice promises exactly
-- one, so the DSL must refuse this input.
loadTwoFixtures :: IO (Either String Int)
loadTwoFixtures = do
    dir <- getDataFileName "test/fixtures/receipts"
    fmap length <$> loadReceipts dir


-- | A contrasting value for a refused observation.
otherName :: Value
otherName = String "6f74686572"

-- | A contrasting value for a refused observation.
otherAddress :: Value
otherAddress = String "60ffffffffffffffffffffffffffffffffffffffffffffffffffffff"

-- | A contrasting value for a refused observation.
otherApproval :: Value
otherApproval = String "00112233445566778899001122334455667788990011223344556677"

-- | A contrasting value for a refused observation.
emptyValue :: Value
emptyValue = String ""

-- | A contrasting value for a refused observation.
unlandedTx :: Value
unlandedTx = String "ff66666666666666666666666666666666666666666666666666666666666666"
