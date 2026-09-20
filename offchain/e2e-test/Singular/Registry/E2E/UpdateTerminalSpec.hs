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
    cageAddrFromCfg,
    cagePolicyIdFromCfg,
    extractCageDatum,
    findStateUtxo,
    policyIdFromPin,
    walkEdge,
 )
import Singular.Registry.TxBuilder.Update (updateTokenWithDuties)
import Singular.Registry.Types (
    CageDatum (..),
    Edge,
    edgeInsertAbsent,
    edgeInsertActive,
    edgeUpdateTerminal,
    OnChainRoot (..),
    OnChainTokenState (..),
 )

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

{- | A retirement delivers nothing, so it names nothing. The approval
still binds this pair, and the cage recomputes it from the request, so it
has to be the same on both sides — it is simply empty.
-}
retireDestination :: (ByteString, ByteString)
retireDestination = (BS.empty, BS.empty)

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
            heldBefore <- activeHeldAt prov cfg storyKey
            heldBefore `shouldBe` (1 :: Integer)

            -- 2. the edge under test, at the SAME key, in the SAME
            --    session, burning the witness step 1 delivered.
            _ <- book cfg codes prov submit tokenId storyKey retire walletDestination
            retireTx <- foldAndMirror cfg prov submit tm tokenId refs storyKey retire

            -- The observation, in three independent directions.
            --
            -- The wallet: a fold that silently did nothing leaves one,
            -- not zero.
            heldAfter <- activeHeldAt prov cfg storyKey
            heldAfter `shouldBe` (0 :: Integer)

            -- The transaction: exactly the keyed `-1` under the ACTIVE
            -- policy read off the BOOTED CONFIG, and nothing else under
            -- it. A burn of another key, or of two, fails here.
            mintedActive retireTx cfg `shouldBe` [(storyKey, -1)]

            -- The LEAF, observed where a leaf can actually be observed.
            -- `Trie.lookup` answers with the key's hash, not its value, so
            -- it cannot see a leaf at all. What can: the registry's own
            -- committed root, read off the state UTxO on chain, against
            -- the mirror root reached by committing `Terminal` at this
            -- key. The chain got there through the validator's
            -- `mpf.update(0x01, 0x02)` and the mirror through an
            -- independent local trie; equality is the statement that the
            -- leaf the next proof begins at is Terminal. Any other leaf
            -- is a different root.
            mirrorRoot <- withTrie tm tokenId getRoot
            chainRoot <- committedRoot prov cfg tokenId
            chainRoot `shouldBe` unRoot mirrorRoot

    it "refuses updateTerminal on a key the trie does not bind, with an accepting control" $
        withBootedCage id stateBytes requestBytes $ \cfg prov submit tm tokenId -> do
            refs <- publishCageRefs cfg prov submit tokenId
            codes <- loadRegistryCodesFromEnv
            -- The control FIRST: a key that was inserted Active retires
            -- in this very cage, through this very builder. A failure
            -- here is reported as a broken control rather than silently
            -- making the refusal below vacuous.
            _ <- book cfg codes prov submit tokenId storyKey insertActive walletDestination
            _ <- foldAndMirror cfg prov submit tm tokenId refs storyKey insertActive
            _ <- book cfg codes prov submit tokenId storyKey retire retireDestination
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
            _ <- book cfg codes prov submit tokenId unknownKey retire retireDestination
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
            _ <- book cfg codes prov submit tokenId storyKey insertActive walletDestination
            _ <- foldAndMirror cfg prov submit tm tokenId refs storyKey insertActive
            _ <- book cfg codes prov submit tokenId storyKey retire retireDestination
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
            _ <- book cfg codes prov submit tokenId absentKey retire retireDestination
            outcome <- try @SomeException (foldOnce cfg prov submit tm tokenId refs)
            case outcome of
                Right _ ->
                    expectationFailure
                        "I177-E2E: the chain ACCEPTED updateTerminal on a key \
                        \witnessed Absent — reported, not relabelled"
                Left _ -> pure ()

-- ---------------------------------------------------------
-- The three edges this spec books
-- ---------------------------------------------------------

insertActive, insertAbsent, retire :: Edge
insertActive = edgeInsertActive
insertAbsent = edgeInsertAbsent
retire = edgeUpdateTerminal

-- | Book one edge at an explicitly named destination.
book ::
    CageConfig ->
    NamingCodes ->
    Cage.Provider IO ->
    Submitter IO ->
    TokenId ->
    ByteString ->
    Edge ->
    (ByteString, ByteString) ->
    IO TxIn
book cfg codes prov submit tokenId key edge dest =
    Edges.bookEdgeTo
        cfg
        codes
        prov
        (submitWithGenesis submit)
        genesisAddr
        tokenId
        key
        edge
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
    Edge ->
    IO ConwayTx
foldAndMirror cfg prov submit tm tokenId refs key edge = do
    rootBefore <- withTrie tm tokenId getRoot
    signed <- foldOnce cfg prov submit tm tokenId refs
    -- #183: the edge names the leaf bytes the mirror writes, from the
    -- same table the cage walks.
    _ <- withTrie tm tokenId $ \t -> walkEdge t key edge
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

{- | The registry's own committed root, read off the state UTxO on
chain.

This is how a LEAF is observed. `Trie.lookup` answers with the key's
hash rather than its value and cannot see one; the root can, because a
trie with a different leaf at this key has a different root. The chain
reached this root through the validator's own `mpf.update`, and the
mirror reaches it through an independent local trie, so their equality
is a statement about the leaf and not about either implementation.
-}
committedRoot :: Cage.Provider IO -> CageConfig -> TokenId -> IO ByteString
committedRoot prov cfg tokenId = do
    utxos <- Cage.queryUTxOs prov (cageAddrFromCfg cfg (network cfg))
    case findStateUtxo (cagePolicyIdFromCfg cfg) tokenId utxos of
        Just (_, out) -> case extractCageDatum out of
            Just (StateDatum s) -> pure (unOnChainRoot (stateRoot s))
            _ -> fail "the state UTxO carries no state datum"
        Nothing -> fail "no state UTxO carrying the registry policy token"
