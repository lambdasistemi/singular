{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Execute the declared cases against the receipt loader.
module Conformance.Story.Run (
    assetOf,
    collectAssets,
    collectKeys,
    collectMints,
    collectRefunds,
    collectSigners,
    completePins,
    collectConfig,
    collectSequence,
    collectHashes,
    setEdgeField,
    setLegField,
    dropLegField,
    foldLeg,
    foldEdit,
    acceptsMeaning,
    validateCase,
    validateCollection,
    validateLeg,
    validateEdit,
    executeEdit,
    checkOne,
    checkCase,
    runStory,
    outcomeMatches
) where

import Control.Monad.Operational (Program, ProgramViewT (Return, (:>>=)), view)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Aeson (Value, toJSON, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.Foldable (toList)
import Test.Hspec (Spec, describe, expectationFailure, it)
import Conformance.Fixture.ActiveRegistration (activeHex, completeReceipt, configPins, loadOne)
import Conformance.Story.Binding
import Conformance.Story.Instruction
import Conformance.Story.Render (renderEdit, renderFailure)

-- | One asset entry.
assetOf :: Value -> Value -> Integer -> Value
assetOf policy name qty =
    Aeson.object
        [ "policy" .= policy
        , "name" .= name
        , "quantity" .= qty
        ]

-- | Fold an asset program to its JSON values.
collectAssets :: Program AssetsI () -> [Value]
collectAssets prog = case view prog of
    Return () -> []
    ActiveToken k qty :>>= k2 -> assetOf activeHex k qty : collectAssets (k2 ())
    Token policy name qty :>>= k -> assetOf policy name qty : collectAssets (k ())
    NoAssets :>>= k -> collectAssets (k ())
    LitAssets vs :>>= k -> vs <> collectAssets (k ())

-- | Fold a key program to its JSON values.
collectKeys :: Program KeysI () -> [Value]
collectKeys prog = case view prog of
    Return () -> []
    Key k :>>= rest -> k : collectKeys (rest ())

-- | Fold a mint program to its JSON values.
collectMints :: Program MintI () -> [Value]
collectMints prog = case view prog of
    Return () -> []
    Mint policy name qty :>>= rest -> assetOf policy name qty : collectMints (rest ())
    NoMints :>>= rest -> collectMints (rest ())

-- | Fold a refund program to its JSON values.
collectRefunds :: Program RefundsI () -> [Value]
collectRefunds prog = case view prog of
    Return () -> []
    Lovelace n :>>= rest -> Aeson.Number (fromInteger n) : collectRefunds (rest ())
    NoRefunds :>>= rest -> collectRefunds (rest ())

-- | Fold a signer program to its JSON values.
collectSigners :: Program SignersI () -> [Value]
collectSigners prog = case view prog of
    Return () -> []
    Signer addr :>>= rest -> addr : collectSigners (rest ())
    NoSigners :>>= rest -> collectSigners (rest ())

-- | The complete configuration pins the fixture carries.
completePins :: [Value]
completePins = case configPins of
    Aeson.Array arr -> toList arr
    _ -> []

-- | Fold a config program to its pins.
collectConfig :: Program ConfigI () -> [Value]
collectConfig prog = go prog completePins
  where
    go :: Program ConfigI () -> [Value] -> [Value]
    go p pins = case view p of
        Return () -> pins
        MaxFee n :>>= rest -> go (rest ()) (Aeson.String (T.pack (show n)) : drop 1 pins)
        RestUnchanged :>>= rest -> go (rest ()) pins
        NoPins :>>= rest -> go (rest ()) []

-- | Fold a sequence program to its JSON values.
collectSequence :: Program SequenceI () -> [Value]
collectSequence prog = case view prog of
    Return () -> []
    Step tx before after committed :>>= rest ->
        Aeson.object
            [ "txid" .= tx
            , "rootBefore" .= before
            , "rootAfter" .= after
            , "committed" .= committed
            ]
            : collectSequence (rest ())
    NoSteps :>>= rest -> collectSequence (rest ())

-- | Fold a hash program to its JSON values.
collectHashes :: Program HashesI () -> [Value]
collectHashes prog = case view prog of
    Return () -> []
    Hash h :>>= rest -> h : collectHashes (rest ())
    NoHashes :>>= rest -> collectHashes (rest ())

-- | Set one field of the receipt's edge observation.
setEdgeField :: String -> Value -> Value -> Value
setEdgeField k v receipt = case receipt of
    Aeson.Object o -> case KM.lookup "edge" o of
        Just (Aeson.Object e) ->
            Aeson.Object (KM.insert "edge" (Aeson.Object (KM.insert (Key.fromString k) v e)) o)
        _ -> receipt
    _ -> receipt

-- | Set one field of one refusal leg.
setLegField :: LegName -> String -> Value -> Value -> Value
setLegField leg k v receipt = case receipt of
    Aeson.Object o -> case KM.lookup "edge" o of
        Just (Aeson.Object e) -> case KM.lookup (Key.fromString (renderLeg leg)) e of
            Just (Aeson.Object l) ->
                let e2 = KM.insert (Key.fromString (renderLeg leg)) (Aeson.Object (KM.insert (Key.fromString k) v l)) e
                 in Aeson.Object (KM.insert "edge" (Aeson.Object e2) o)
            _ -> receipt
        _ -> receipt
    _ -> receipt

-- | Delete one field of one refusal leg.
dropLegField :: LegName -> String -> Value -> Value
dropLegField leg k receipt = case receipt of
    Aeson.Object o -> case KM.lookup "edge" o of
        Just (Aeson.Object e) -> case KM.lookup (Key.fromString (renderLeg leg)) e of
            Just (Aeson.Object l) ->
                let e2 = KM.insert (Key.fromString (renderLeg leg)) (Aeson.Object (KM.delete (Key.fromString k) l)) e
                 in Aeson.Object (KM.insert "edge" (Aeson.Object e2) o)
            _ -> receipt
        _ -> receipt
    _ -> receipt

-- | Fold a leg program to a receipt transformer, scoped to the leg.
foldLeg :: LegName -> Program LegI () -> Value -> Value
foldLeg leg prog = case view prog of
    Return () -> id
    LegKeys p :>>= rest ->
        \v -> foldLeg leg (rest ()) (setLegField leg "keys" (toJSON (collectKeys p)) v)
    LegClaimed p :>>= rest ->
        \v -> foldLeg leg (rest ()) (setLegField leg "claimedMint" (toJSON (collectMints p)) v)
    LegEntailed p :>>= rest ->
        \v -> foldLeg leg (rest ()) (setLegField leg "entailedMint" (toJSON (collectMints p)) v)
    LegControl p :>>= rest ->
        \v -> foldLeg leg (rest ()) (setLegField leg "controlMint" (toJSON (collectMints p)) v)
    LegDistinguisher t :>>= rest ->
        \v -> foldLeg leg (rest ()) (setLegField leg "distinguisher" (Aeson.String t) v)
    LegTxid tx :>>= rest ->
        \v -> foldLeg leg (rest ()) (setLegField leg "txid" tx v)
    LegControlTxid tx :>>= rest ->
        \v -> foldLeg leg (rest ()) (setLegField leg "controlTxid" tx v)
    LegHashes p :>>= rest ->
        \v -> foldLeg leg (rest ()) (setLegField leg "hashes" (toJSON (collectHashes p)) v)
    OmitTrace :>>= rest ->
        \v -> foldLeg leg (rest ()) (dropLegField leg "trace" v)

-- | Fold an edit program to a receipt transformer.
foldEdit :: Program EditI () -> Value -> Value
foldEdit prog = case view prog of
    Return () -> id
    Deliver p :>>= rest ->
        \v -> foldEdit (rest ()) (setEdgeField "delivered" (toJSON (collectAssets p)) v)
    Minted p :>>= rest ->
        \v -> foldEdit (rest ()) (setEdgeField "minted" (toJSON (collectAssets p)) v)
    ObservedAddress addr :>>= rest ->
        \v -> foldEdit (rest ()) (setEdgeField "observedAddress" addr v)
    OpenParameters n :>>= rest ->
        \v -> foldEdit (rest ()) (setEdgeField "openParameters" (Aeson.Number (fromInteger n)) v)
    RequestLovelace n :>>= rest ->
        \v -> foldEdit (rest ()) (setEdgeField "requestLovelace" (Aeson.Number (fromInteger n)) v)
    ApprovalRecomputed newVal :>>= rest ->
        \r -> foldEdit (rest ()) (setEdgeField "approvalRecomputed" newVal r)
    Refunds p :>>= rest ->
        \v -> foldEdit (rest ()) (setEdgeField "refunds" (toJSON (collectRefunds p)) v)
    Signers p :>>= rest ->
        \v -> foldEdit (rest ()) (setEdgeField "signers" (toJSON (collectSigners p)) v)
    ConfigAfter p :>>= rest ->
        \v -> foldEdit (rest ()) (setEdgeField "configAfter" (toJSON (collectConfig p)) v)
    ConfigBefore p :>>= rest ->
        \v -> foldEdit (rest ()) (setEdgeField "configBefore" (toJSON (collectConfig p)) v)
    LandedFolds p :>>= rest ->
        \v -> foldEdit (rest ()) (setEdgeField "sequence" (toJSON (collectSequence p)) v)
    OnLeg leg p :>>= rest ->
        \v -> foldEdit (rest ()) (foldLeg leg p v)
    DropLeg leg :>>= rest ->
        \v -> foldEdit (rest ()) (setEdgeField (renderLeg leg) Aeson.Null v)
    Unchanged :>>= rest -> foldEdit (rest ())

-- ---------------------------------------------------------
-- The one place saying what accepted means
-- ---------------------------------------------------------

-- | Accepted means the loader returned exactly the fixture's receipt
-- count: one written file loads exactly one receipt. An accepts over
-- zero or two receipts is refused, not vacuously passed.
acceptsMeaning :: Either String Int -> Bool
acceptsMeaning (Right 1) = True
acceptsMeaning _ = False

-- | A case is well-formed when every rejection carries a non-empty
-- reason. Presence is enforced by the type; this refuses emptiness.
validateCase :: Program CaseI () -> Bool
validateCase prog = case view prog of
    Return () -> True
    Accepts _ _ :>>= rest -> validateCase (rest ())
    AcceptsBecause _ _ reason :>>= rest -> not (T.null reason) && validateCase (rest ())
    Rejects _ reason _ :>>= rest -> not (T.null reason) && validateCase (rest ())

-- | A collection is well-formed when no literal instrument built it.
validateCollection :: Program AssetsI () -> Bool
validateCollection prog = case view prog of
    Return () -> True
    ActiveToken _ _ :>>= rest -> validateCollection (rest ())
    Token _ _ _ :>>= rest -> validateCollection (rest ())
    NoAssets :>>= rest -> validateCollection (rest ())
    LitAssets _ :>>= _ -> False

-- | A leg program is well-formed. Leg collections have no literal
-- instrument, so this folds total and true.
validateLeg :: Program LegI () -> Bool
validateLeg prog = case view prog of
    Return () -> True
    LegKeys _ :>>= rest -> validateLeg (rest ())
    LegClaimed _ :>>= rest -> validateLeg (rest ())
    LegEntailed _ :>>= rest -> validateLeg (rest ())
    LegControl _ :>>= rest -> validateLeg (rest ())
    LegDistinguisher _ :>>= rest -> validateLeg (rest ())
    LegTxid _ :>>= rest -> validateLeg (rest ())
    LegControlTxid _ :>>= rest -> validateLeg (rest ())
    LegHashes _ :>>= rest -> validateLeg (rest ())
    OmitTrace :>>= rest -> validateLeg (rest ())

-- | An edit program is well-formed when every nested collection is.
validateEdit :: Program EditI () -> Bool
validateEdit prog = case view prog of
    Return () -> True
    Deliver p :>>= rest -> validateCollection p && validateEdit (rest ())
    Minted p :>>= rest -> validateCollection p && validateEdit (rest ())
    ObservedAddress _ :>>= rest -> validateEdit (rest ())
    OpenParameters _ :>>= rest -> validateEdit (rest ())
    RequestLovelace _ :>>= rest -> validateEdit (rest ())
    ApprovalRecomputed _ :>>= rest -> validateEdit (rest ())
    Refunds _ :>>= rest -> validateEdit (rest ())
    Signers _ :>>= rest -> validateEdit (rest ())
    ConfigAfter _ :>>= rest -> validateEdit (rest ())
    ConfigBefore _ :>>= rest -> validateEdit (rest ())
    LandedFolds _ :>>= rest -> validateEdit (rest ())
    OnLeg _ p :>>= rest -> validateLeg p && validateEdit (rest ())
    DropLeg _ :>>= rest -> validateEdit (rest ())
    Unchanged :>>= rest -> validateEdit (rest ())

-- | Execute an edit program against the real loader.
executeEdit :: Program EditI () -> IO (Either String Int)
executeEdit prog = loadOne (foldEdit prog completeReceipt)

-- | Check one case: well-formedness first, then the loader's answer
-- against the named outcome. A missing reason ('Nothing', plain
-- 'accepts') is well-formed; an empty one is refused.
checkOne
    :: BoundObligation -> Text -> EvidenceBoundary -> Text -> Maybe Reason -> Program EditI () -> Bool -> IO (Either FailureReport ())
checkOne obligation clauseName boundary name mreason prog expectAccept = do
    result <- executeEdit prog
    let reasonOk = maybe True (not . T.null) mreason
        wellFormed = reasonOk && validateEdit prog
        good = wellFormed && outcomeMatches expectAccept result
    pure
        ( if good
            then Right ()
            else
                Left
                    ( FailureReport
                        { frTheorem = boName obligation <> " @" <> boRevision obligation
                        , frClause = T.unpack clauseName
                        , frExample = T.unpack name
                        , frBoundary = renderBoundary boundary
                        , frExpected =
                            if expectAccept
                                then "the loader accepts the observation"
                                else "the loader refuses the observation"
                        , frActual = case result of
                            Right n -> "the loader accepted it, returning " <> show n <> " receipt"
                            Left err -> "the loader refused: " <> err
                        , frBecause = fmap T.unpack mreason
                        , frEdit = renderEdit prog
                        }
                    )
        )

-- | Check a case program with its clause context.
checkCase :: Binding -> Text -> EvidenceBoundary -> Program CaseI () -> IO (Either FailureReport ())
checkCase obligation clauseName boundary prog = go prog
  where
    go :: Program CaseI () -> IO (Either FailureReport ())
    go p = case view p of
        Return () -> pure (Right ())
        Accepts name edit :>>= rest -> do
            r <- checkOne obligation clauseName boundary name Nothing edit True
            case r of
                Left report -> pure (Left report)
                Right _ -> go (rest ())
        AcceptsBecause name edit reason :>>= rest -> do
            r <- checkOne obligation clauseName boundary name (Just reason) edit True
            case r of
                Left report -> pure (Left report)
                Right _ -> go (rest ())
        Rejects name reason edit :>>= rest -> do
            r <- checkOne obligation clauseName boundary name (Just reason) edit False
            case r of
                Left report -> pure (Left report)
                Right _ -> go (rest ())

-- | Run one story as Hspec: theorem, clause, then example. Every
-- example executes the loader using the same edits the story renders.
runStory :: Program StoryI () -> Spec
runStory prog = case view prog of
    Return () -> pure ()
    Theorem binding clauses :>>= rest -> do
        describe (boName binding <> " @" <> boRevision binding) (runClauses binding clauses)
        runStory (rest ())
  where
    runClauses :: Binding -> Program ClauseI () -> Spec
    runClauses binding p = case view p of
        Return () -> pure ()
        Clause alias _ cases :>>= rest -> do
            describe (T.unpack alias) $ do
                runCases binding alias cases
            runClauses binding (rest ())
        Unexercised _ _ :>>= rest -> runClauses binding (rest ())
    runCases :: Binding -> Text -> Program CaseI () -> Spec
    runCases binding clauseName p = case view p of
        Return () -> pure ()
        Accepts name edit :>>= rest -> do
            it (T.unpack name) $ do
                result <- checkOne binding clauseName ReceiptValidation name Nothing edit True
                case result of
                    Left report -> expectationFailure (renderFailure report)
                    Right _ -> pure ()
            runCases binding clauseName (rest ())
        AcceptsBecause name edit reason :>>= rest -> do
            it (T.unpack name) $ do
                result <- checkOne binding clauseName ReceiptValidation name (Just reason) edit True
                case result of
                    Left report -> expectationFailure (renderFailure report)
                    Right _ -> pure ()
            runCases binding clauseName (rest ())
        Rejects name reason edit :>>= rest -> do
            it (T.unpack name) $ do
                result <- checkOne binding clauseName ReceiptValidation name (Just reason) edit False
                case result of
                    Left report -> expectationFailure (renderFailure report)
                    Right _ -> pure ()
            runCases binding clauseName (rest ())

-- | Preserve both old predicates: exact fixture count for acceptance, Left for refusal.
outcomeMatches :: Bool -> Either String Int -> Bool
outcomeMatches True result = acceptsMeaning result
outcomeMatches False (Left _) = True
outcomeMatches False (Right _) = False
