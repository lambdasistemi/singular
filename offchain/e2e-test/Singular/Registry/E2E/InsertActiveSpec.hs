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

This spec used to carry its own 'foldAndMirror', which committed each
landed fold into the manager and failed if the root did not move — the
same function 'Fork81Spec' carried, with a comment here saying so. Both
are gone: 'Singular.Registry.Driver.foldEdgeTo' books, folds, submits and
commits as one step, and refuses a fold when the manager is behind the
chain. What is left here is what belongs here — the observation that
exactly one active token lands at the wallet the request named, and the
refusal of a second insert on a bound key with its accepting control.
-}
module Singular.Registry.E2E.InsertActiveSpec (spec) where

import Control.Exception (SomeException, try)
import Control.Monad (unless)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.List (isInfixOf)
import Data.Map.Strict qualified as Map
import Test.Hspec

import Cardano.Ledger.Address (serialiseAddr)
import Cardano.Ledger.Mary.Value (MaryValue (..), MultiAsset (..))
import Cardano.Node.Client.E2E.Setup (genesisAddr)
import Data.ByteString.Short qualified as SBS
import Lens.Micro ((^.))

import Cardano.Ledger.Core (valueTxOutL)
import Singular.Registry.Blueprint (
    Blueprint,
    extractCompiledCode,
    loadRegistryCodesFromEnv,
 )
import Singular.Registry.Config (CageConfig (..))
import Singular.Registry.Ledger (AssetName (..), Root (..))
import Singular.Registry.Provider qualified as Cage
import Singular.Registry.TxBuilder.Internal (policyIdFromPin)
import Singular.Registry.Types (edgeInsertActive)

import Singular.Registry.Driver (
    FoldOutcome (..),
    bootRegistry,
    foldEdgeTo,
    renderRoot,
 )
import Singular.Registry.E2E.CageSpec (
    submitWithGenesis,
    withE2E,
 )

spec :: Blueprint -> Spec
spec bp = describe "Inserting an active key" $ do
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
    it "when a fresh key is inserted, delivers exactly one active token to the named wallet" $
        withE2E stateBytes requestBytes $ \cfg prov submit tm -> do
            codes <- loadRegistryCodesFromEnv
            reg <-
                bootRegistry cfg codes prov (submitWithGenesis submit) genesisAddr tm
            _ <- sayFold $ foldEdgeTo reg activeKey edgeInsertActive walletDestination

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

    it "when a key is already active, refuses reinsertion while accepting a fresh key" $
        withE2E stateBytes requestBytes $ \cfg prov submit tm -> do
            codes <- loadRegistryCodesFromEnv
            reg <-
                bootRegistry cfg codes prov (submitWithGenesis submit) genesisAddr tm

            -- A cage of its own, and every delivery routed away from the
            -- funding wallet, so neither the named-wallet story above nor
            -- a fee-input collision can be confused with occupancy.
            let fold key =
                    sayFold $ foldEdgeTo reg key edgeInsertActive elsewhereDestination

            -- 1. book and fold the key once: it is now taken.
            _ <- fold refusalKey

            -- 2. the accepting control, in THIS cage, through the SAME
            --    builder and the SAME destination: a fresh key folds. It
            --    runs before the duplicate so a failure here is reported
            --    as a broken control rather than silently making step 3
            --    vacuous.
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
            duplicate <- try @SomeException (fold refusalKey)
            case duplicate of
                Right _ ->
                    expectationFailure
                        "A173-REFUSALS: the chain ACCEPTED a second \
                        \insertActive on a key the trie already binds — \
                        \reported, not relabelled"
                Left e -> do
                    -- The refusal must be the CAGE refusing the fold, not
                    -- the booking failing first. `foldEdgeTo` books and
                    -- folds in one call, so an undiscriminated `Left _`
                    -- would accept a duplicate-specific booking failure
                    -- and never reach the occupancy this example is about.
                    let msg = show (e :: SomeException)
                        wanted = ["EvalFailure", "ConwaySpending", "CekError"]
                        absent = [w | w <- wanted, not (w `isInfixOf` msg)]
                    unless (null absent) $
                        expectationFailure
                            ( "A173-REFUSALS: the duplicate failed, but not as \
                              \a cage refusal of the fold — "
                                <> show absent
                                <> " absent, so this may be the booking \
                                   \failing before the occupancy is reached. \
                                   \Got: "
                                <> msg
                            )

{- | The trace line this spec's examples printed before the private
harness was deleted: the key and the mirror root on either side of the
fold. It is restored here, byte for byte, rather than in the driver:
these three lines belong to these two examples, and a driver that
printed for every caller would add output to examples that were silent.
-}
sayFold :: IO FoldOutcome -> IO FoldOutcome
sayFold act = do
    o <- act
    putStrLn
        ( "[t173] fold key="
            <> show (foKey o)
            <> " mirror-root-before=0x"
            <> renderRoot (unRoot (foRootBefore o))
            <> " mirror-root-after=0x"
            <> renderRoot (unRoot (foRootAfter o))
        )
    pure o

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
