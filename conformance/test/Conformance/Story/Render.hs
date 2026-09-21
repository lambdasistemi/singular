{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Render every instruction and nested argument in reading order.
module Conformance.Story.Render (
    valueText,
    renderAssets,
    renderEdit,
    renderLegProg,
    next,
    renderKeys,
    renderMints,
    renderRefunds,
    renderSigners,
    renderConfig,
    renderSequence,
    renderHashes,
    renderFailure,
    renderStory
) where

import Control.Monad.Operational (Program, ProgramViewT (Return, (:>>=)), view)
import Data.Text qualified as T
import Data.Aeson (Value, toJSON)
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as BSL
import Data.Text.Encoding qualified as T
import Conformance.Story.Binding
import Conformance.Story.Instruction

-- | Preserve the complete value, including hash suffixes and JSON structure.
valueText :: Value -> String
valueText = T.unpack . T.decodeUtf8 . BSL.toStrict . Aeson.encode

-- | Render an asset program.
renderAssets :: Program AssetsI () -> String
renderAssets prog = case view prog of
    Return () -> ""
    ActiveToken k qty :>>= rest ->
        "activeToken " <> valueText k <> " " <> show qty <> then_ (renderAssets (rest ()))
    Token policy name qty :>>= rest ->
        "token " <> valueText policy <> " " <> valueText name <> " " <> show qty <> then_ (renderAssets (rest ()))
    NoAssets :>>= rest -> "nothing" <> then_ (renderAssets (rest ()))
    LitAssets vs :>>= rest -> "literal " <> valueText (toJSON vs) <> then_ (renderAssets (rest ()))
  where
    then_ "" = ""
    then_ s = "; " <> s

-- | Render the edit line from the instructions that ran.
renderEdit :: Program EditI () -> String
renderEdit prog = case view prog of
    Return () -> "unchanged"
    Deliver p :>>= rest -> "deliver: " <> renderAssets p <> then_ (renderEdit (rest ()))
    Minted p :>>= rest -> "minted: " <> renderAssets p <> then_ (renderEdit (rest ()))
    ObservedAddress addr :>>= rest ->
        "observedAddress " <> valueText addr <> then_ (renderEdit (rest ()))
    OpenParameters n :>>= rest -> "openParameters " <> show n <> then_ (renderEdit (rest ()))
    RequestLovelace n :>>= rest -> "requestLovelace " <> show n <> then_ (renderEdit (rest ()))
    ApprovalRecomputed v :>>= rest ->
        "approvalRecomputed " <> valueText v <> then_ (renderEdit (rest ()))
    Refunds p :>>= rest -> "refunds: " <> renderRefunds p <> then_ (renderEdit (rest ()))
    Signers p :>>= rest -> "signers: " <> renderSigners p <> then_ (renderEdit (rest ()))
    ConfigAfter p :>>= rest -> "configAfter: " <> renderConfig p <> then_ (renderEdit (rest ()))
    ConfigBefore p :>>= rest -> "configBefore: " <> renderConfig p <> then_ (renderEdit (rest ()))
    LandedFolds p :>>= rest -> "landedFolds: " <> renderSequence p <> then_ (renderEdit (rest ()))
    OnLeg leg p :>>= rest ->
        "onLeg " <> renderLeg leg <> ": " <> renderLegProg p <> then_ (renderEdit (rest ()))
    DropLeg leg :>>= rest -> "without " <> renderLeg leg <> then_ (renderEdit (rest ()))
    Unchanged :>>= rest -> renderEdit (rest ())
  where
    then_ "unchanged" = ""
    then_ "" = ""
    then_ s = "; " <> s

-- | Render a leg program.
renderLegProg :: Program LegI () -> String
renderLegProg prog = case view prog of
    Return () -> ""
    LegKeys p :>>= rest -> "keys: " <> renderKeys p <> then_ (renderLegProg (rest ()))
    LegClaimed p :>>= rest -> "claimedMint: " <> renderMints p <> then_ (renderLegProg (rest ()))
    LegEntailed p :>>= rest -> "entailedMint: " <> renderMints p <> then_ (renderLegProg (rest ()))
    LegControl p :>>= rest -> "controlMint: " <> renderMints p <> then_ (renderLegProg (rest ()))
    LegDistinguisher v :>>= rest -> "distinguisher: " <> valueText (Aeson.String v) <> then_ (renderLegProg (rest ()))
    LegTxid v :>>= rest -> "txid: " <> valueText v <> then_ (renderLegProg (rest ()))
    LegControlTxid v :>>= rest -> "controlTxid: " <> valueText v <> then_ (renderLegProg (rest ()))
    LegHashes p :>>= rest -> "hashes: " <> renderHashes p <> then_ (renderLegProg (rest ()))
    OmitTrace :>>= rest -> "without trace" <> then_ (renderLegProg (rest ()))
  where
    then_ "" = ""
    then_ s = "; " <> s

-- | Join rendered instructions without losing their order.
next :: String -> String
next "" = ""
next text = "; " <> text

-- | Render every instruction in a keys program.
renderKeys :: Program KeysI () -> String
renderKeys prog = case view prog of
    Return () -> ""
    Key k :>>= rest -> "key " <> valueText k <> next (renderKeys (rest ()))

-- | Render every instruction in a mints program.
renderMints :: Program MintI () -> String
renderMints prog = case view prog of
    Return () -> ""
    Mint policy name qty :>>= rest -> "mint " <> valueText policy <> " " <> valueText name <> " " <> show qty <> next (renderMints (rest ()))
    NoMints :>>= rest -> "no mint" <> next (renderMints (rest ()))

-- | Render every instruction in a refunds program.
renderRefunds :: Program RefundsI () -> String
renderRefunds prog = case view prog of
    Return () -> ""
    Lovelace n :>>= rest -> "lovelace " <> show n <> next (renderRefunds (rest ()))
    NoRefunds :>>= rest -> "no refund" <> next (renderRefunds (rest ()))

-- | Render every instruction in a signers program.
renderSigners :: Program SignersI () -> String
renderSigners prog = case view prog of
    Return () -> ""
    Signer addr :>>= rest -> "signer " <> valueText addr <> next (renderSigners (rest ()))
    NoSigners :>>= rest -> "no signer" <> next (renderSigners (rest ()))

-- | Render every instruction in a config program.
renderConfig :: Program ConfigI () -> String
renderConfig prog = case view prog of
    Return () -> ""
    MaxFee n :>>= rest -> "max fee " <> show n <> next (renderConfig (rest ()))
    RestUnchanged :>>= rest -> "other pins unchanged" <> next (renderConfig (rest ()))
    NoPins :>>= rest -> "no pins" <> next (renderConfig (rest ()))

-- | Render every instruction in a sequence program.
renderSequence :: Program SequenceI () -> String
renderSequence prog = case view prog of
    Return () -> ""
    Step tx before after committed :>>= rest -> "transaction " <> valueText tx <> " from " <> valueText before <> " to " <> valueText after <> " committed " <> valueText committed <> next (renderSequence (rest ()))
    NoSteps :>>= rest -> "no landed folds" <> next (renderSequence (rest ()))

-- | Render every instruction in a hashes program.
renderHashes :: Program HashesI () -> String
renderHashes prog = case view prog of
    Return () -> ""
    Hash h :>>= rest -> "script " <> valueText h <> next (renderHashes (rest ()))
    NoHashes :>>= rest -> "no failing script" <> next (renderHashes (rest ()))

-- | Render the failure report in reading order.
renderFailure :: FailureReport -> String
renderFailure report =
    unlines
        [ "FAILED"
        , "  theorem   " <> frTheorem report
        , "  clause    " <> frClause report
        , "  example   " <> frExample report
        , "  because   " <> maybe "(accepted without a stated reason)" id (frBecause report)
        , "  boundary  " <> frBoundary report
        , "  edit      " <> frEdit report
        , "  expected  " <> frExpected report
        , "  actual    " <> frActual report
        ]

-- | Render one story as the readable theorem-clause-example text.
renderStory :: Program StoryI () -> String
renderStory prog = case view prog of
    Return () -> ""
    Theorem binding clauses :>>= rest ->
        unlines
            [ boName binding <> " @" <> boRevision binding <> " " <> take 8 (boDigest binding) <> "\8230"
            ]
            <> renderClauses clauses
            <> renderStory (rest ())
  where
    renderClauses :: Program ClauseI () -> String
    renderClauses p = case view p of
        Return () -> ""
        Clause alias selects cases :>>= rest ->
            "  " <> T.unpack alias <> "\n"
                <> renderSelects selects
                <> renderCases cases
                <> renderClauses (rest ())
        Unexercised alias missing :>>= rest ->
            "    \8251 unexercised: " <> T.unpack alias <> "\n"
                <> "        " <> T.unpack missing <> "\n"
                <> renderClauses (rest ())
    renderSelects :: Program SelectI () -> String
    renderSelects p = case view p of
        Return () -> ""
        Conjunct t :>>= rest ->
            "      \183 " <> T.unpack t <> "\n" <> renderSelects (rest ())
    renderCases :: Program CaseI () -> String
    renderCases p = case view p of
        Return () -> ""
        Accepts name edit :>>= rest ->
            "      accepts: " <> T.unpack name <> "\n"
                <> "          edit " <> renderEdit edit <> "\n"
                <> renderCases (rest ())
        AcceptsBecause name edit reason :>>= rest ->
            "      accepts: " <> T.unpack name <> "\n"
                <> "          because " <> T.unpack reason <> "\n"
                <> "          edit " <> renderEdit edit <> "\n"
                <> renderCases (rest ())
        Rejects name reason edit :>>= rest ->
            "      refuses: " <> T.unpack name <> "\n"
                <> "          because " <> T.unpack reason <> "\n"
                <> "          edit " <> renderEdit edit <> "\n"
                <> renderCases (rest ())

