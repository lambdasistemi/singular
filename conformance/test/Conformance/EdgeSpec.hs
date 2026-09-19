{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Conformance.EdgeSpec
Description : CG21 edge evidence must be complete or the loader refuses it
License     : Apache-2.0

#184. CG21 reports one accepted @insertActive@ fold together with two
DISTINCT refusals, each carrying its own accepting control. The outer
@edge@ field stays optional so every other row keeps writing @null@ and
receipts written before it still parse — but for CG21 it is mandatory
and COMPLETE, and this suite is what makes "complete" mean something.

The subject is 'loadReceipts': these tests hand it JSON and require a
'Left'. They are written against the JSON rather than against the
Haskell record on purpose — a mutant that drops a field must fail
because the LOADER refuses it, not because a constructor stopped
compiling.

Two guards, because a quantified check ranging over nothing reports
success having tested nothing:

* the mutant set is read OUT of the complete artifact rather than
  listed here, so a field added to the observation is covered the day
  it is added;
* the extent is asserted at its known size before any mutant runs, and
  the complete artifact itself must LOAD, so a fixture broken for an
  unrelated reason cannot make every mutant pass for the wrong reason.
-}
module Conformance.EdgeSpec (spec) where

import Data.Aeson (Value (..), encode, object, toJSON, (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Lazy qualified as BSL
import Data.Either (isLeft, isRight)
import Data.Foldable (for_)
import Data.IORef (IORef, atomicModifyIORef', newIORef)
import Data.List (sort)
import System.Directory (
    createDirectoryIfMissing,
    getTemporaryDirectory,
    removeDirectoryRecursive,
 )
import System.FilePath ((</>))
import System.IO.Unsafe (unsafePerformIO)
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)

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

{- | The complete CG21 edge observation: the fold, every fine conjunct
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

-- | The CG21 receipt the runner writes, with a complete observation.
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

-- ---------------------------------------------------------
-- The suite
-- ---------------------------------------------------------

spec :: Spec
spec = describe "CG21 edge evidence (#184)" $ do
    -- The positive control. Every refusal below is only informative
    -- beside an artifact the loader actually accepts.
    it "accepts one complete CG21 observation" $ do
        r <- loadOne completeReceipt
        r `shouldBe` Right 1

    it "refuses a CG21 receipt that carries no observation at all" $ do
        r <- loadOne (withEdge Null)
        r `shouldSatisfy` isLeft

    -- The extent is read out of the artifact, not listed here; these
    -- two sizes are what stop the quantifiers ranging over nothing.
    it "names every field of the observation before mutating one" $ do
        length edgeKeys `shouldBe` 20
        legKeysOf "duplicate"
            `shouldBe` ["controlTxid", "distinguisher", "hashes", "keys", "trace", "txid"]
        legKeysOf "keyedMint"
            `shouldBe` [ "claimedMint"
                       , "controlMint"
                       , "controlTxid"
                       , "distinguisher"
                       , "entailedMint"
                       , "hashes"
                       , "keys"
                       , "trace"
                       , "txid"
                       ]

    it "refuses the observation with any single field absent" $
        for_ edgeKeys $ \k -> do
            r <- loadOne (edgeDrop k)
            (k, isLeft r) `shouldBe` (k, True)

    it "refuses either refusal leg with any required field absent" $
        for_
            [ (leg, k)
            | leg <- ["duplicate", "keyedMint"]
            , k <- legKeysOf leg
            , k `notElem` optionalLegKeys
            ]
            $ \(leg, k) -> do
                r <- loadOne (legDrop leg k)
                ((leg, k), isLeft r) `shouldBe` ((leg, k), True)

    it "accepts a leg whose trace the ledger did not surface" $ do
        r <- loadOne (legDrop "duplicate" "trace")
        r `shouldSatisfy` isRight

    -- A184-FOLD: the identities and the single delivered asset.
    it "refuses an open application that declares a parameter" $ do
        r <- loadOne (edgeSet "openParameters" (Number 1))
        r `shouldSatisfy` isLeft

    it "refuses a delivery that is not exactly one token at the key" $ do
        r <- loadOne (edgeSet "delivered" (toJSON ([] :: [Value])))
        r `shouldSatisfy` isLeft

    it "refuses a delivery of two tokens at the key" $ do
        r <-
            loadOne
                ( edgeSet
                    "delivered"
                    ( toJSON
                        [ object
                            [ "policy" .= activeHex
                            , "name" .= keyHex
                            , "quantity" .= (2 :: Int)
                            ]
                        ]
                    )
                )
        r `shouldSatisfy` isLeft

    it "refuses a delivery under a policy that is not the active one" $ do
        r <-
            loadOne
                ( edgeSet
                    "delivered"
                    ( toJSON
                        [ object
                            [ "policy" .= openHex
                            , "name" .= keyHex
                            , "quantity" .= (1 :: Int)
                            ]
                        ]
                    )
                )
        r `shouldSatisfy` isLeft

    it "refuses a delivery whose asset name is not the key" $ do
        r <-
            loadOne
                ( edgeSet
                    "delivered"
                    ( toJSON
                        [ object
                            [ "policy" .= activeHex
                            , "name" .= String "6f74686572"
                            , "quantity" .= (1 :: Int)
                            ]
                        ]
                    )
                )
        r `shouldSatisfy` isLeft

    it "refuses a mint that is not exactly one token at the key" $ do
        r <- loadOne (edgeSet "minted" (toJSON ([] :: [Value])))
        r `shouldSatisfy` isLeft

    it "refuses a token observed somewhere other than the requested address" $ do
        r <-
            loadOne
                ( edgeSet
                    "observedAddress"
                    (String "60ffffffffffffffffffffffffffffffffffffffffffffffffffffff")
                )
        r `shouldSatisfy` isLeft

    -- A184-CONJUNCTS: each fine conjunct separately observable and
    -- separately fatal.
    it "refuses a fold that paid a refund" $ do
        r <- loadOne (edgeSet "refunds" (toJSON [1_000_000 :: Int]))
        r `shouldSatisfy` isLeft

    it "refuses a fold that required a signer" $ do
        r <- loadOne (edgeSet "signers" (toJSON [walletAddr]))
        r `shouldSatisfy` isLeft

    it "refuses a request whose lovelace does not cover the tip" $ do
        r <- loadOne (edgeSet "requestLovelace" (Number 999_999))
        r `shouldSatisfy` isLeft

    it "refuses a destination binding the approval does not carry" $ do
        r <-
            loadOne
                ( edgeSet
                    "approvalRecomputed"
                    (String "00112233445566778899001122334455667788990011223344556677")
                )
        r `shouldSatisfy` isLeft

    it "refuses a fold that moved a non-root configuration pin" $ do
        r <-
            loadOne
                ( edgeSet
                    "configAfter"
                    ( toJSON
                        [ String "2000000"
                        , String "30000"
                        , String "30000"
                        , openHex
                        , activeHex
                        , String "5c1e7ab390d24f6817be05c3a9f2d148e6730bc5924af18de036b7a1"
                        , String "3b8d02f7561ec49a0d73b15fa28c6e904715d3ba6cf28017e94db5c6"
                        ]
                    )
                )
        r `shouldSatisfy` isLeft

    it "refuses a configuration observation that lost a pin" $ do
        r <- loadOne (edgeSet "configBefore" (toJSON ([] :: [Value])))
        r `shouldSatisfy` isLeft

    -- A184-SEQUENCE: each landed fold advances the committed trie
    -- before the next proof is built.
    it "refuses a landed fold whose root did not move" $ do
        r <-
            loadOne
                ( edgeSet
                    "sequence"
                    ( toJSON
                        [ foldStep foldTx bootRoot bootRoot
                        , foldStep dupControlTx bootRoot root2
                        , foldStep mintControlTx root2 root3
                        ]
                    )
                )
        r `shouldSatisfy` isLeft

    it "refuses a second fold proved against the boot root" $ do
        r <-
            loadOne
                ( edgeSet
                    "sequence"
                    ( toJSON
                        [ foldStep foldTx bootRoot root1
                        , foldStep dupControlTx bootRoot root2
                        , foldStep mintControlTx root2 root3
                        ]
                    )
                )
        r `shouldSatisfy` isLeft

    it "refuses a committed root that disagrees with the chain's" $ do
        r <-
            loadOne
                ( edgeSet
                    "sequence"
                    ( toJSON
                        [ object
                            [ "txid" .= foldTx
                            , "rootBefore" .= bootRoot
                            , "rootAfter" .= root1
                            , "committed" .= root2
                            ]
                        , foldStep dupControlTx root1 root2
                        , foldStep mintControlTx root2 root3
                        ]
                    )
                )
        r `shouldSatisfy` isLeft

    it "refuses an empty landed-fold sequence" $ do
        r <- loadOne (edgeSet "sequence" (toJSON ([] :: [Value])))
        r `shouldSatisfy` isLeft

    it "refuses a fold transaction absent from the landed sequence" $ do
        r <-
            loadOne
                ( edgeSet
                    "sequence"
                    ( toJSON
                        [ foldStep dupControlTx bootRoot root1
                        , foldStep mintControlTx root1 root2
                        ]
                    )
                )
        r `shouldSatisfy` isLeft

    -- A184-DUPLICATE / A184-KEYED-MINT: two refusals, two controls,
    -- and neither standing in for the other.
    it "refuses a leg whose control is the transaction it refused" $ do
        r <- loadOne (legSet "duplicate" "controlTxid" dupTx)
        r `shouldSatisfy` isLeft

    it "refuses a leg naming no failing script" $ do
        r <- loadOne (legSet "duplicate" "hashes" (toJSON ([] :: [Value])))
        r `shouldSatisfy` isLeft

    it "refuses a leg naming an empty failing script" $ do
        r <- loadOne (legSet "duplicate" "hashes" (toJSON [String ""]))
        r `shouldSatisfy` isLeft

    it "refuses a leg whose distinguisher is empty" $ do
        r <- loadOne (legSet "keyedMint" "distinguisher" (String ""))
        r `shouldSatisfy` isLeft

    it "refuses one refusal reused as the other" $ do
        r <- loadOne (legSet "keyedMint" "txid" dupTx)
        r `shouldSatisfy` isLeft

    it "refuses two legs sharing one accepting control" $ do
        r <- loadOne (legSet "keyedMint" "controlTxid" dupControlTx)
        r `shouldSatisfy` isLeft

    it "refuses a control that never landed a fold" $ do
        r <-
            loadOne
                ( legSet
                    "duplicate"
                    "controlTxid"
                    (String "ff66666666666666666666666666666666666666666666666666666666666666")
                )
        r `shouldSatisfy` isLeft

    it "refuses a refused transaction that also landed as a fold" $ do
        r <- loadOne (legSet "duplicate" "txid" mintControlTx)
        r `shouldSatisfy` isLeft

    -- The two-key relation, with a structured subject rather than a
    -- phrase. A leg that only SAYS "two distinct keys" leaves the
    -- loader nothing to reject a same-key batch with.
    it "refuses a keyed-mint leg naming one key" $ do
        r <- loadOne (legSet "keyedMint" "keys" (toJSON [keyAHex]))
        r `shouldSatisfy` isLeft

    it "refuses a keyed-mint leg naming the same key twice" $ do
        r <- loadOne (legSet "keyedMint" "keys" (toJSON [keyAHex, keyAHex]))
        r `shouldSatisfy` isLeft

    it "refuses a keyed-mint leg naming three keys" $ do
        r <-
            loadOne
                (legSet "keyedMint" "keys" (toJSON [keyAHex, keyBHex, keyHex]))
        r `shouldSatisfy` isLeft

    it "refuses a keyed-mint leg naming an empty key" $ do
        r <- loadOne (legSet "keyedMint" "keys" (toJSON [keyAHex, String ""]))
        r `shouldSatisfy` isLeft

    it "refuses a keyed-mint leg reusing the fold's own key" $ do
        r <- loadOne (legSet "keyedMint" "keys" (toJSON [keyHex, keyBHex]))
        r `shouldSatisfy` isLeft

    it "refuses a duplicate leg naming two keys" $ do
        r <- loadOne (legSet "duplicate" "keys" (toJSON [keyHex, keyBHex]))
        r `shouldSatisfy` isLeft

    it "refuses a duplicate leg naming a key the fold did not insert" $ do
        r <- loadOne (legSet "duplicate" "keys" (toJSON [keyAHex]))
        r `shouldSatisfy` isLeft

    -- The duplicate is refused BEFORE any mint arithmetic runs. A leg
    -- carrying mint arithmetic is claiming to be the other fixture.
    it "refuses a duplicate leg carrying mint arithmetic" $ do
        r <- loadOne (legSet "duplicate" "claimedMint" claimedMint)
        r `shouldSatisfy` isLeft

    -- The claimed and entailed mints, compared the two ways that make
    -- this a KEYED fault and not a net one.
    it "refuses a keyed-mint leg whose claim also disagrees per kind" $ do
        r <- loadOne (legSet "keyedMint" "claimedMint" (toJSON [mintOf keyAHex 3]))
        r `shouldSatisfy` isLeft

    it "refuses a keyed-mint leg whose claim agrees per key as well" $ do
        r <- loadOne (legSet "keyedMint" "claimedMint" entailedMint)
        r `shouldSatisfy` isLeft

    it "refuses a keyed-mint leg claiming a mint at neither named key" $ do
        r <-
            loadOne
                (legSet "keyedMint" "claimedMint" (toJSON [mintOf keyHex 2]))
        r `shouldSatisfy` isLeft

    it "refuses a keyed-mint leg entailing a mint at neither named key" $ do
        r <-
            loadOne
                ( legSet
                    "keyedMint"
                    "entailedMint"
                    (toJSON [mintOf keyHex 1, mintOf keyBHex 1])
                )
        r `shouldSatisfy` isLeft

    it "refuses a keyed-mint leg with no claimed mint at all" $ do
        r <- loadOne (legSet "keyedMint" "claimedMint" (toJSON ([] :: [Value])))
        r `shouldSatisfy` isLeft

    -- The accepting control is the SAME batch with the right
    -- distribution: it must mint exactly what the batch entails.
    it "refuses a keyed-mint control that minted the refused claim" $ do
        r <- loadOne (legSet "keyedMint" "controlMint" claimedMint)
        r `shouldSatisfy` isLeft

    it "refuses a keyed-mint control that minted at another key" $ do
        r <-
            loadOne
                ( legSet
                    "keyedMint"
                    "controlMint"
                    (toJSON [mintOf keyAHex 1, mintOf keyHex 1])
                )
        r `shouldSatisfy` isLeft

    it "refuses a CG21 observation with no keyed-mint leg at all" $ do
        r <- loadOne (edgeSet "keyedMint" Null)
        r `shouldSatisfy` isLeft

    -- Backward compatibility, in both directions.
    it "refuses edge evidence on a row that is not CG21" $ do
        r <- loadOne (receiptSet "row" (String "CG02"))
        r `shouldSatisfy` isLeft
