{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Conformance.Operational
Description : Slice S2 RED stub: weak operational surface the controls must fail
License     : Apache-2.0

STUB for checkpoint s2-red. Same API the real DSL will keep; weak
implementations the four controls execute and fail:

* 'renderEdit' is constant, ignoring the program (story can drift);
* 'acceptsMeaning' admits any 'Right' (two receipts pass);
* 'validateCase' accepts an empty reason;
* 'validateCollection' accepts 'literalControl' collections.

Checkpoint s2-dsl replaces each weak body with the strong fold. No
test changes between the two: the API is frozen here.
-}
module Conformance.Operational (
    AssetsI (..),
    CaseI (..),
    EditI (..),
    Reason,
    accepts,
    acceptsMeaning,
    activeToken,
    collectAssets,
    deliver,
    executeEdit,
    literalControl,
    rejects,
    renderEdit,
    unchanged,
    validateCase,
    validateCollection,
) where

import Control.Monad.Operational (Program, ProgramViewT (Return, (:>>=)), singleton, view)
import Data.Aeson (Value, toJSON, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.Text (Text)

import Conformance.EdgeFixtures (activeHex, completeReceipt, loadOne)

-- | A rejection reason. Required by 'rejects'; the stub accepts "".
type Reason = Text

-- | Asset collections as programs. 'LiteralAssets' is the negative
-- control instrument: a collection built as a literal rather than a
-- program. The stub accepts it; the real interpreter refuses it.
data AssetsI a where
    ActiveToken :: Value -> Integer -> AssetsI ()
    LiteralAssets :: [Value] -> AssetsI ()

-- | Receipt edits as programs.
data EditI a where
    Deliver :: Program AssetsI () -> EditI ()
    Unchanged :: EditI ()

-- | Cases as programs. Meaning lives in the interpreter, never here.
data CaseI a where
    Accepts :: Text -> Program EditI () -> CaseI ()
    Rejects :: Text -> Reason -> Program EditI () -> CaseI ()

-- | One active token holding.
activeToken :: Value -> Integer -> Program AssetsI ()
activeToken key qty = singleton (ActiveToken key qty)

-- | Negative control: a literal-built collection inside a program world.
literalControl :: [Value] -> Program AssetsI ()
literalControl vs = singleton (LiteralAssets vs)

-- | Deliver a collection program.
deliver :: Program AssetsI () -> Program EditI ()
deliver p = singleton (Deliver p)

-- | No change.
unchanged :: Program EditI ()
unchanged = singleton Unchanged

-- | Accept the observation.
accepts :: Text -> Program EditI () -> Program CaseI ()
accepts name prog = singleton (Accepts name prog)

-- | Refuse the observation. The reason is a required argument.
rejects :: Text -> Reason -> Program EditI () -> Program CaseI ()
rejects name reason prog = singleton (Rejects name reason prog)

-- | Fold an asset program to its JSON values.
collectAssets :: Program AssetsI () -> [Value]
collectAssets prog = case view prog of
    Return () -> []
    instr :>>= k -> case instr of
        ActiveToken key qty ->
            assetOf key qty : collectAssets (k ())
        LiteralAssets vs -> vs <> collectAssets (k ())
  where
    assetOf key qty =
        Aeson.object
            [ "policy" .= activeHex
            , "name" .= key
            , "quantity" .= qty
            ]

-- | Set one field of the receipt's edge observation.
setEdgeField :: String -> Value -> Value -> Value
setEdgeField k v receipt = case receipt of
    Aeson.Object o -> case KM.lookup "edge" o of
        Just (Aeson.Object e) ->
            Aeson.Object (KM.insert "edge" (Aeson.Object (KM.insert (Key.fromString k) v e)) o)
        _ -> receipt
    _ -> receipt

-- | Fold an edit program to a receipt transformer.
foldEdit :: Program EditI () -> Value -> Value
foldEdit prog = case view prog of
    Return () -> id
    instr :>>= k -> case instr of
        Deliver p ->
            let f = setEdgeField "delivered" (toJSON (collectAssets p))
             in \v -> foldEdit (k ()) (f v)
        Unchanged -> foldEdit (k ())

-- | WEAK: constant rendering, ignoring the program. A case whose
-- rendered story and executed program disagree is still accepted.
renderEdit :: Program EditI () -> String
renderEdit _ = "edit"

-- | Execute an edit program against the real loader.
executeEdit :: Program EditI () -> IO (Either String Int)
executeEdit prog = loadOne (foldEdit prog completeReceipt)

-- | WEAK: any 'Right' counts as accepted, so a two-receipt load passes.
acceptsMeaning :: Either String Int -> Bool
acceptsMeaning (Right _) = True
acceptsMeaning (Left _) = False

-- | Fold a case program to its validity. WEAK: always valid, so an
-- empty reason passes. Total over 'CaseI': no catch-all arm, so a new
-- case constructor breaks this with the renderer together (NOTE-001).
validateCase :: Program CaseI () -> Bool
validateCase prog = case view prog of
    Return () -> True
    Accepts _ _ :>>= k -> validateCase (k ())
    Rejects _ _ _ :>>= k -> validateCase (k ())

-- | Fold a collection program to its validity. WEAK: always valid, so
-- a literal-built collection passes. Total over 'AssetsI' (NOTE-001).
validateCollection :: Program AssetsI () -> Bool
validateCollection prog = case view prog of
    Return () -> True
    ActiveToken _ _ :>>= k -> validateCollection (k ())
    LiteralAssets _ :>>= k -> validateCollection (k ())
