{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.Registry.E2E.UpdateTerminalSpec
Description : #177 I177-E2E — the open registry's updateTerminal edge on a real devnet
License     : Apache-2.0

The retirement, end to end, through the same public builder every other
consumer uses.

One cage boots, one key is INSERTED ACTIVE to a named wallet, and the
same key is then RETIRED from that wallet. The retirement is the only
registry edge that destroys a token it does not first create, so the
things worth watching are all about the asset:

- the active quantity at the wallet goes from one to zero;
- the transaction burns exactly `(activePolicy, key) -1` and nothing
  else under the three registry policies;
- the token it burns rides in on an INPUT — the holder's own UTxO — and
  no output carries it afterwards;
- the committed trie leaf reads `Terminal`.

The lifecycle is connected on purpose (constitution III): the Active
leaf and the token this edge consumes are produced by the `insertActive`
fold in the same session, not fabricated. A fixture dropped straight
into the final state would evidence nothing about the transition.

The two refusals are separate facts and get separate cages, each with
its own ACCEPTING CONTROL run first, so "refused" can never stand in for
"this harness cannot fold at all":

- a key the trie does not bind at all — Lean `key-unknown`;
- a key witnessed only `Absent` — Lean `not-booked`.

Refusal NAMES are not asserted here. The ledger's `EvalFailure` carries
an empty Plutus log list, so the cage's trace is not recoverable from
it; the names are asserted under `aiken check`, against the construction
site the validator reads (`lib.terminalRefusal`).

`foldAndMirror` commits each landed fold into the manager's trie and
fails if the committed root does not move. The speculative session
inside `updateTokenWithDuties` starts from the committed trie and is
discarded, so a caller that skips this re-proves the next fold against
the BOOT state and the retirement submits a proof for the wrong root.
-}
module Singular.Registry.E2E.UpdateTerminalSpec (spec) where

import Control.Exception (SomeException, try)
import Control.Monad (when)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Map.Strict qualified as Map
import System.Environment (lookupEnv)
import Test.Hspec

import Cardano.Ledger.Address (serialiseAddr)
import Cardano.Ledger.Api.Tx (bodyTxL)
import Cardano.Ledger.Api.Tx.Body (mintTxBodyL)
import Cardano.Ledger.Api.Tx.Out (TxOut)
import Cardano.Ledger.Core (valueTxOutL)
import Cardano.Ledger.Mary.Value (AssetName (..), MaryValue (..), MultiAsset (..))
import Cardano.Node.Client.E2E.Setup (genesisAddr)
import Cardano.Node.Client.Submitter (Submitter)
import Cardano.Tx.Ledger (ConwayTx)
import Data.ByteString.Base16 qualified as Base16
import Data.ByteString.Short qualified as SBS
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Lens.Micro ((^.))

import Singular.Registry.Blueprint (
    NamingCodes,
    extractCompiledCode,
    loadBlueprint,
    loadRegistryCodesFromEnv,
 )
import Singular.Registry.Config (CageConfig (..))
import Singular.Registry.Ledger (ConwayEra, Root (..), TokenId, TxIn)
import Singular.Registry.Provider qualified as Cage
import Singular.Registry.Trie (Trie (..), TrieManager (..))
import Singular.Registry.TxBuilder.Edges qualified as Edges
import Singular.Registry.TxBuilder.Internal (
    leafAbsent,
    leafActive,
    leafTerminal,
    policyIdFromPin,
 )
import Singular.Registry.TxBuilder.Update (updateTokenWithDuties)
import Singular.Registry.Types (OnChainOperation (..))

import Singular.Registry.E2E.CageSpec (
    publishCageRefs,
    registryContextFor,
    submitWithGenesis,
    withBootedCage,
 )

-- | The key the connected story books and then retires.
storyKey :: ByteString
storyKey = "t177-update-terminal"

-- | A key nothing ever inserted: the trie does not bind it at all.
unknownKey :: ByteString
unknownKey = "t177-update-terminal-unknown"

-- | A key witnessed ABSENT and never booked.
absentKey :: ByteString
absentKey = "t177-update-terminal-absent"

{- | The destination the open story names: the requester's own wallet.
`Edges.edgeDestinationOf` would route to the APPLICATION's script
address, which is right for naming and wrong here — `open.ak` is a
minting policy with no spending arm, so a token routed there is locked
forever and could never be retired.
-}
walletDestination :: (ByteString, ByteString)
walletDestination = (serialiseAddr genesisAddr, "")

{- | A destination that is NOT the funding wallet: a bare enterprise
address that `lib.decodeAddress` accepts. The refusal cages deliver
their control tokens here, so an active token sitting in the fee wallet
cannot be swept into a later fold and refused for a reason that has
nothing to do with the leaf under test.
-}
elsewhereDestination :: (ByteString, ByteString)
elsewhereDestination = (BS.pack (0x60 : replicate 28 0xcd), "")

spec :: Spec
spec = describe "#177 updateTerminal on the open registry" $ do
    mPath <- runIO $ lookupEnv "REGISTRY_BLUEPRINT"
    case mPath of
        Nothing -> it "skipped (REGISTRY_BLUEPRINT not set)" (pure () :: IO ())
        Just path -> do
            ebp <- runIO $ loadBlueprint path
            case ebp of
                Left err -> it ("blueprint error: " <> err) (expectationFailure err)
                Right bp ->
                    case ( extractCompiledCode "state.state" bp
                         , extractCompiledCode "request.request" bp
                         ) of
                        (Just stateBytes, Just requestBytes) ->
                            updateTerminalSpec stateBytes requestBytes
                        _ ->
                            it "no compiled code" $
                                expectationFailure "state or request script not found"

updateTerminalSpec :: SBS.ShortByteString -> SBS.ShortByteString -> Spec
updateTerminalSpec stateBytes requestBytes = do
    it "retires the active token it inserted: quantity 1 -> 0, keyed -1 burn, Terminal leaf" $
        withBootedCage id stateBytes requestBytes $ \cfg prov submit tm tokenId -> do
            refs <- publishCageRefs cfg prov submit tokenId
            codes <- loadRegistryCodesFromEnv

            -- 1. the prerequisite, executed rather than fabricated: the
            --    key becomes Active and the wallet holds its witness.
            _ <- book cfg codes prov submit tokenId storyKey insertActive walletDestination
            _ <- foldAndMirror cfg prov submit tm tokenId refs storyKey insertActive
            before <- activeHeldAt prov cfg storyKey
            before `shouldBe` (1 :: Integer)

            -- 2. the edge under test, at the SAME key, in the SAME
            --    session, burning the witness step 1 delivered.
            _ <- book cfg codes prov submit tokenId storyKey retire walletDestination
            retireTx <- foldAndMirror cfg prov submit tm tokenId refs storyKey retire

            -- The observation, in three independent directions.
            --
            -- The wallet: a fold that silently did nothing leaves one,
            -- not zero.
            after <- activeHeldAt prov cfg storyKey
            after `shouldBe` (0 :: Integer)

            -- The transaction: exactly the keyed `-1` under the ACTIVE
            -- policy read off the BOOTED CONFIG, and nothing else under
            -- it. A burn of another key, or of two, fails here.
            mintedActive retireTx cfg `shouldBe` [(storyKey, -1)]

            -- The trie: the committed leaf the next proof begins at.
            leaf <- withTrie tm tokenId (`Singular.Registry.Trie.lookup` storyKey)
            leaf `shouldBe` Just leafTerminal

    it "refuses updateTerminal on a key the trie does not bind, with an accepting control" $
        withBootedCage id stateBytes requestBytes $ \cfg prov submit tm tokenId -> do
            refs <- publishCageRefs cfg prov submit tokenId
            codes <- loadRegistryCodesFromEnv
            -- The control FIRST: a key that was inserted Active retires
            -- in this very cage, through this very builder. A failure
            -- here is reported as a broken control rather than silently
            -- making the refusal below vacuous.
            _ <- book cfg codes prov submit tokenId storyKey insertActive elsewhereDestination
            _ <- foldAndMirror cfg prov submit tm tokenId refs storyKey insertActive
            _ <- book cfg codes prov submit tokenId storyKey retire elsewhereDestination
            control <- try @SomeException (foldAndMirror cfg prov submit tm tokenId refs storyKey retire)
            case control of
                Left e ->
                    expectationFailure
                        ( "I177-E2E control: a key that IS Active was refused \
                          \retirement, so the unknown-key refusal below would \
                          \prove nothing about the leaf: "
                            <> show e
                        )
                Right _ -> pure ()

            -- The refusal. Everything is held constant against the
            -- control except the one fact under test: this key was
            -- never inserted, so the trie does not bind it.
            _ <- book cfg codes prov submit tokenId unknownKey retire elsewhereDestination
            outcome <- try @SomeException (foldOnce cfg prov submit tm tokenId refs)
            case outcome of
                Right _ ->
                    expectationFailure
                        "I177-E2E: the chain ACCEPTED updateTerminal on a key \
                        \the trie does not bind — reported, not relabelled"
                Left _ -> pure ()

    it "refuses updateTerminal on a key witnessed Absent, with an accepting control" $
        withBootedCage id stateBytes requestBytes $ \cfg prov submit tm tokenId -> do
            refs <- publishCageRefs cfg prov submit tokenId
            codes <- loadRegistryCodesFromEnv
            -- The control, again first and in this same cage.
            _ <- book cfg codes prov submit tokenId storyKey insertActive elsewhereDestination
            _ <- foldAndMirror cfg prov submit tm tokenId refs storyKey insertActive
            _ <- book cfg codes prov submit tokenId storyKey retire elsewhereDestination
            control <- try @SomeException (foldAndMirror cfg prov submit tm tokenId refs storyKey retire)
            case control of
                Left e ->
                    expectationFailure
                        ( "I177-E2E control: a key that IS Active was refused \
                          \retirement, so the not-booked refusal below would \
                          \prove nothing about the leaf: "
                            <> show e
                        )
                Right _ -> pure ()

            -- The refusal. This key IS bound — it was witnessed absent
            -- by a real `insertAbsent` fold — and the only thing that
            -- differs from the control is the leaf it is bound to.
            _ <- book cfg codes prov submit tokenId absentKey insertAbsent walletDestination
            _ <- foldAndMirror cfg prov submit tm tokenId refs absentKey insertAbsent
            _ <- book cfg codes prov submit tokenId absentKey retire elsewhereDestination
            outcome <- try @SomeException (foldOnce cfg prov submit tm tokenId refs)
            case outcome of
                Right _ ->
                    expectationFailure
                        "I177-E2E: the chain ACCEPTED updateTerminal on a key \
                        \witnessed Absent — reported, not relabelled"
                Left _ -> pure ()

-- ---------------------------------------------------------
-- The three operations this spec books
-- ---------------------------------------------------------

insertActive, insertAbsent, retire :: OnChainOperation
insertActive = OpInsert leafActive
insertAbsent = OpInsert leafAbsent
retire = OpUpdate leafActive leafTerminal

-- | Book one edge at an explicitly named destination.
book ::
    CageConfig ->
    NamingCodes ->
    Cage.Provider IO ->
    Submitter IO ->
    TokenId ->
    ByteString ->
    OnChainOperation ->
    (ByteString, ByteString) ->
    IO TxIn
book cfg codes prov submit tokenId key op dest =
    Edges.bookEdgeTo
        cfg
        codes
        prov
        (submitWithGenesis submit)
        genesisAddr
        tokenId
        key
        op
        dest

{- | Build and submit the fold of whatever is pending, WITHOUT mirroring.
The refusal rows use this: a fold that never lands must not move the
committed trie.
-}
foldOnce ::
    CageConfig ->
    Cage.Provider IO ->
    Submitter IO ->
    TrieManager IO ->
    TokenId ->
    [(TxIn, TxOut ConwayEra)] ->
    IO ConwayTx
foldOnce cfg prov submit tm tokenId refs = do
    ctx <- registryContextFor cfg prov tokenId refs
    unsigned <- updateTokenWithDuties cfg prov tm tokenId genesisAddr ctx
    submitWithGenesis submit unsigned

{- | Fold, submit, and MIRROR the landed fold into the committed trie.

The mirror is not bookkeeping: the speculative session inside
`updateTokenWithDuties` starts from the committed trie and is discarded,
so a caller that skips it re-proves the next fold against a stale root.
The root is read on either side and must move.
-}
foldAndMirror ::
    CageConfig ->
    Cage.Provider IO ->
    Submitter IO ->
    TrieManager IO ->
    TokenId ->
    [(TxIn, TxOut ConwayEra)] ->
    ByteString ->
    OnChainOperation ->
    IO ConwayTx
foldAndMirror cfg prov submit tm tokenId refs key op = do
    rootBefore <- withTrie tm tokenId getRoot
    signed <- foldOnce cfg prov submit tm tokenId refs
    withTrie tm tokenId $ \t -> case op of
        OpInsert v -> () <$ insert t key v
        OpUpdate _ v -> do
            _ <- Singular.Registry.Trie.delete t key
            () <$ insert t key v
        OpDelete _ -> () <$ Singular.Registry.Trie.delete t key
        OpRead _ -> pure ()
    rootAfter <- withTrie tm tokenId getRoot
    putStrLn
        ( "[t177] fold key="
            <> show key
            <> " mirror-root-before=0x"
            <> hexBS (unRoot rootBefore)
            <> " mirror-root-after=0x"
            <> hexBS (unRoot rootAfter)
        )
    when (unRoot rootBefore == unRoot rootAfter) $
        expectationFailure
            "I177-E2E: the committed mirror root did not move across a \
            \landed fold — the next fold would re-prove against a stale root"
    pure signed

-- | The quantity held under the ACTIVE policy at this key, at the wallet.
activeHeldAt :: Cage.Provider IO -> CageConfig -> ByteString -> IO Integer
activeHeldAt prov cfg key = do
    walletUtxos <- Cage.queryUTxOs prov genesisAddr
    let policy = policyIdFromPin (cfgActivePolicy cfg)
    pure $
        sum
            [ q
            | (_, out) <- walletUtxos
            , let MaryValue _ (MultiAsset ma) = out ^. valueTxOutL
            , (p, names) <- Map.toList ma
            , (AssetName n, q) <- Map.toList names
            , p == policy
            , SBS.fromShort n == key
            ]

{- | Everything the transaction moves under the ACTIVE policy, by key.
The policy comes from the booted config, so a burn under another policy
is absent here rather than silently counted.
-}
mintedActive :: ConwayTx -> CageConfig -> [(ByteString, Integer)]
mintedActive tx cfg =
    let MultiAsset ma = tx ^. bodyTxL . mintTxBodyL
        policy = policyIdFromPin (cfgActivePolicy cfg)
     in [ (SBS.fromShort n, q)
        | (p, names) <- Map.toList ma
        , p == policy
        , (AssetName n, q) <- Map.toList names
        ]

-- | Hex for the receipt lines.
hexBS :: ByteString -> String
hexBS = T.unpack . TE.decodeUtf8 . Base16.encode
