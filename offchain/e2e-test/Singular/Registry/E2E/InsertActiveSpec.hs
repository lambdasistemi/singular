{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.Registry.E2E.InsertActiveSpec
Description : the open registry's insertActive edge on a real devnet
License     : Apache-2.0

Two cages, because the two things being shown need different conditions.

**The named-wallet story.** One `insertActive` folds and exactly one
`(activePolicy, key)` token lands in the output at the address the
request named — a WALLET, not the application's own script address. The
open registry has no application that could ever spend a token back out
of one: `open.ak` is a minting policy with no spending arm, so a token
routed there is locked forever.

**The refusal**, in a cage of its own. The same key is folded, a FRESH
key is folded as the accepting control, and the same key again is
REFUSED. The control runs first, so a broken control is reported rather
than silently leaving the refusal vacuous — "refused" is otherwise
consistent with "this builder cannot fold at all".

That cage routes every delivery AWAY from the funding wallet. This
harness has one wallet and the folder pays fees from it, so an active
token sitting there would be swept into the next fold as a fee input
and refused as a movement no consumed request entails. Keeping the
refusal cage's tokens out of the fee wallet removes that from the
picture.

Refusal NAMES are not asserted here. The ledger's `EvalFailure` carries
an empty Plutus log list, so the cage's trace is not recoverable from
it; the names are asserted under `aiken check`, against the construction
sites the validator reads.

'foldAndMirror' commits each landed fold into the manager's trie and
fails if the committed root does not move. That is not bookkeeping: the
speculative session inside 'updateTokenWithDuties' starts from the
committed trie and is discarded, so a caller that skips this re-proves
the next fold against the BOOT state and fold 2 submits an empty proof.
A stale root is otherwise invisible until a later fold fails for an
unrelated-looking reason.
-}
module Singular.Registry.E2E.InsertActiveSpec (spec) where

import Control.Exception (SomeException, try)
import Control.Monad (when)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Map.Strict qualified as Map
import System.Environment (lookupEnv)
import Test.Hspec

import Cardano.Ledger.Address (serialiseAddr)
import Cardano.Ledger.Mary.Value (MaryValue (..), MultiAsset (..))
import Cardano.Node.Client.E2E.Setup (genesisAddr)
import Data.ByteString.Base16 qualified as Base16
import Data.ByteString.Short qualified as SBS
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Lens.Micro ((^.))

import Cardano.Ledger.Core (valueTxOutL)
import Cardano.Node.Client.Submitter (Submitter)
import Cardano.Tx.Ledger (ConwayTx)
import Cardano.Ledger.Api.Tx.Out (TxOut)
import Singular.Registry.Ledger (ConwayEra)
import Singular.Registry.Blueprint (
    NamingCodes,
    extractCompiledCode,
    loadBlueprint,
    loadRegistryCodesFromEnv,
 )
import Singular.Registry.Config (CageConfig (..))
import Singular.Registry.Ledger (AssetName (..), TokenId, TxIn)
import Singular.Registry.Ledger (Root (..))
import Singular.Registry.Trie (Trie (..), TrieManager (..))
import Singular.Registry.Provider qualified as Cage
import Singular.Registry.TxBuilder.Edges qualified as Edges
import Singular.Registry.TxBuilder.Internal (leafActive, policyIdFromPin)
import Singular.Registry.TxBuilder.Update (updateTokenWithDuties)
import Singular.Registry.Types (OnChainOperation (..))

import Singular.Registry.E2E.CageSpec (
    publishCageRefs,
    registryContextFor,
    submitWithGenesis,
    withBootedCage,
 )

activeKey, refusalKey, controlKey :: ByteString
activeKey = "t173-insert-active"
refusalKey = "t173-insert-active-dup"
controlKey = "t173-insert-active-control"

{- | The destination the open story names: the requester's own wallet,
with no datum. `Edges.edgeDestinationOf` would route an `insertActive`
to the APPLICATION's script address instead — right for naming, wrong
here, because `open.ak` has no spending arm and the token would be
locked forever.
-}
walletDestination :: (ByteString, ByteString)
walletDestination = (serialiseAddr genesisAddr, "")

{- | A destination that is NOT the funding wallet: a bare enterprise
address (header kind 6 plus a 28-byte payment hash), which
`lib.decodeAddress` accepts.

The refusal cage delivers EVERY token here. This harness has one wallet
and the folder pays fees from it, so an active token sitting there gets
swept into the next fold as a fee input and the cage refuses a movement
no consumed request entails — correctly, and for a reason that has
nothing to do with occupancy. Keeping the refusal cage's tokens out of
the fee wallet is what makes its refusal attributable.
-}
elsewhereDestination :: (ByteString, ByteString)
elsewhereDestination = (BS.pack (0x60 : replicate 28 0xab), "")

spec :: Spec
spec = describe "#173 insertActive on the open registry" $ do
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
                            insertActiveSpec stateBytes requestBytes
                        _ ->
                            it "no compiled code" $
                                expectationFailure "state or request script not found"

insertActiveSpec ::
    SBS.ShortByteString -> SBS.ShortByteString -> Spec
insertActiveSpec stateBytes requestBytes = do
    it "folds one insertActive and places exactly one active token at the named wallet" $
        withBootedCage id stateBytes requestBytes $ \cfg prov submit tm tokenId -> do
            refs <- publishCageRefs cfg prov submit tokenId
            codes <- loadRegistryCodesFromEnv
            _ <-
                bookTo cfg codes prov submit tokenId activeKey walletDestination
            _ <- foldAndMirror cfg prov submit tm tokenId refs activeKey

            -- The observation, not the exit code: exactly one token under
            -- the ACTIVE policy, named by the key, at the wallet the
            -- request named.
            --
            -- Non-vacuous in both directions that matter. The policy is
            -- read off the BOOTED CONFIG rather than written down here, so
            -- a fold that minted under another policy fails; and a fold
            -- that silently did nothing leaves zero, not one.
            held <- activeHeldAt prov cfg activeKey
            held `shouldBe` (1 :: Integer)

    it "refuses a second insertActive on the same key, with a fresh key accepted in the same cage" $
        withBootedCage id stateBytes requestBytes $ \cfg prov submit tm tokenId -> do
            refs <- publishCageRefs cfg prov submit tokenId
            codes <- loadRegistryCodesFromEnv

            -- A cage of its own, and every delivery routed away from the
            -- funding wallet, so neither the named-wallet story above nor
            -- a fee-input collision can be confused with occupancy.
            let book key =
                    bookTo cfg codes prov submit tokenId key elsewhereDestination
                fold key = foldAndMirror cfg prov submit tm tokenId refs key

            -- 1. book and fold the key once: it is now taken.
            _ <- book refusalKey
            _ <- fold refusalKey

            -- 2. the accepting control, in THIS cage, through the SAME
            --    builder and the SAME destination: a fresh key folds. It
            --    runs before the duplicate so a failure here is reported
            --    as a broken control rather than silently making step 3
            --    vacuous.
            _ <- book controlKey
            control <- try @SomeException (fold controlKey)
            case control of
                Left e ->
                    expectationFailure
                        ( "A173-REFUSALS control: a FRESH key was refused in \
                          \the same cage, so the duplicate refusal below \
                          \would prove nothing about occupancy: "
                            <> show e
                        )
                Right _ -> pure ()

            -- 3. the same key AGAIN. Everything else is held constant
            --    against step 2 — same cage, same builder, same
            --    destination, same fee wallet holding no active token.
            --    The only difference is that this key is already bound.
            _ <- book refusalKey
            duplicate <- try @SomeException (fold refusalKey)
            case duplicate of
                Right _ ->
                    expectationFailure
                        "A173-REFUSALS: the chain ACCEPTED a second \
                        \insertActive on a key the trie already binds — \
                        \reported, not relabelled"
                Left _ -> pure ()

-- | Book one `insertActive` at an explicitly named destination.
bookTo ::
    CageConfig ->
    NamingCodes ->
    Cage.Provider IO ->
    Submitter IO ->
    TokenId ->
    ByteString ->
    (ByteString, ByteString) ->
    IO TxIn
bookTo cfg codes prov submit tokenId key dest =
    Edges.bookEdgeTo
        cfg
        codes
        prov
        (submitWithGenesis submit)
        genesisAddr
        tokenId
        key
        (OpInsert leafActive)
        dest

{- | Fold the pending requests, submit, and MIRROR the landed fold into
the manager's committed trie.

The mirroring is not bookkeeping. The speculative session inside
`updateTokenWithDuties` starts from the committed trie and is discarded,
so a caller that does not commit each landed fold re-proves the next one
against the BOOT state: fold 2 submits an empty proof and fails. That is
what made every second fold in this spec fail, whatever its destination,
and it is a defect in this harness rather than in the cage —
`Fork81Spec.foldInsert` has done it correctly all along, and says so in
its own comment.
-}
foldAndMirror ::
    CageConfig ->
    Cage.Provider IO ->
    Submitter IO ->
    TrieManager IO ->
    TokenId ->
    [(TxIn, TxOut ConwayEra)] ->
    ByteString ->
    IO ConwayTx
foldAndMirror cfg prov submit tm tokenId refs key = do
    rootBefore <- withTrie tm tokenId getRoot
    ctx <- registryContextFor cfg prov tokenId refs
    unsigned <- updateTokenWithDuties cfg prov tm tokenId genesisAddr ctx
    -- Building the fold is not folding it: the token only moves once the
    -- transaction is on chain.
    signed <- submitWithGenesis submit unsigned
    withTrie tm tokenId $ \t -> do
        _ <- insert t key leafActive
        pure ()
    rootAfter <- withTrie tm tokenId getRoot
    -- A-011 receipt binding: the committed mirror root on either side of
    -- the landed fold. A root that does NOT move is the defect this
    -- repair exists for, and it would otherwise be invisible until the
    -- NEXT fold failed for an unrelated-looking reason.
    putStrLn
        ( "[t173] fold key="
            <> show key
            <> " mirror-root-before=0x"
            <> hexBS (unRoot rootBefore)
            <> " mirror-root-after=0x"
            <> hexBS (unRoot rootAfter)
        )
    when (unRoot rootBefore == unRoot rootAfter) $
        expectationFailure
            "A-011: the committed mirror root did not move across a landed \
            \fold — the next fold would re-prove against a stale root"
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
            , p == policy
            , (AssetName n, q) <- Map.toList names
            , SBS.fromShort n == key
            ]

-- | Hex for the receipt lines.
hexBS :: ByteString -> String
hexBS = T.unpack . TE.decodeUtf8 . Base16.encode
