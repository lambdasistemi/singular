{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.CLI.OneOutputCreateSpec
Description : A create completes from a wallet of one ada-only output
License     : Apache-2.0

Carol funds a fresh wallet with one ada-only output and runs
@singular registry create@. The preview names the registry's state token
and its seed before anything is submitted. The create runs its
transactions, each paid from the change of the one before, and the last
change comes back to her wallet. Nothing asks her to fund a second
output (#406, #491 create part).

These rows prove the seed rule and the chained judgement ((a)): 'selectSeed'
decides the seed from the wallet view and the carrier (explicit held, explicit
pinned chained, auto chained with no carrier, auto largest with a carrier);
a held sole output while the state must be published is refused naming
omit-`--seed`, never a second output. 'firstPublicationChange' computes the
chained seed from the body before submission, agreeing with the builder;
'publicationFunding' judges the chained run. Each expected value is derived
at run time from the producer, never typed. Preview in both modes is proved
by the devnet legs (Gina/Hank key and public previews agree).
-}
module Singular.CLI.OneOutputCreateSpec (spec) where

import Data.List (isInfixOf)
import Data.Set qualified as Set
import Data.Text qualified as T
import Numeric (showHex)
import Test.Hspec

import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.Api.Tx (txIdTx)
import Cardano.Ledger.Api.Tx.Out (TxOut, mkBasicTxOut)
import Cardano.Ledger.BaseTypes (TxIx (..))
import Cardano.Ledger.Core (Script)
import Cardano.Ledger.Mary.Value (MaryValue (..))
import Cardano.Ledger.TxIn (TxIn (..))
import Cardano.Tx.Ledger (ConwayTx)

import Singular.CLI.Registry
    ( IdentityError (..)
    , publicationFunding
    , renderIdentityError
    , seedChecks
    , selectSeed
    )
import Singular.Registry.Deployment (parseOutRef)
import Singular.Registry.Ledger (Coin (..), ConwayEra)
import Singular.Registry.StubSession
import Singular.Registry.SyntheticTime (syntheticTime)
import Singular.Registry.TxBuilder.BookingFixture
    ( applicationScript
    , cfg
    , payer
    , preprodParams
    )
import Singular.Registry.TxBuilder.Boot (bootCostBound)
import Singular.Registry.TxBuilder.Edges
    ( firstPublicationChange
    , publishRefScriptTx
    )

spec :: Spec
spec = do
    explicitHeldSeedUnchanged
    soleExplicitSeedNamesOmitRemedy
    autoChainedVersusLargest
    explicitPinnedChained
    firstPublicationIsTheSeed
    chainedJudgementAcceptsOneOutput
    movedWalletChangesTheSeed
    shortOneOutputOneVerdict
    severalOutputsUnchanged

outRef :: Char -> TxIn
outRef c =
    either (error . ("OneOutputCreateSpec fixture: " <>)) id $
        parseOutRef (T.pack (replicate 64 c <> "#0"))

seedIn :: TxIn
seedIn = outRef '1'

fundRef :: Int -> TxIn
fundRef n =
    either (error . ("OneOutputCreateSpec fixture: " <>)) id $
        parseOutRef (T.pack (pad <> "#0"))
  where
    h = showHex n ""
    pad = replicate (64 - length h) '0' <> h

testPayer :: Addr
testPayer = payer

adaAt :: Integer -> TxOut ConwayEra
adaAt n = mkBasicTxOut testPayer (MaryValue (Coin n) mempty)

-- | Gina: one ada-only output of 200 tADA, nothing else.
ginaWallet :: [(TxIn, TxOut ConwayEra)]
ginaWallet = [(seedIn, adaAt 200_000_000)]

beforeOne :: [(T.Text, Script ConwayEra)]
beforeOne = [("state", applicationScript)]

explicitHeldSeedUnchanged :: Spec
explicitHeldSeedUnchanged = describe "an explicit held seed" $ do
    it "with another output beside it behaves as in slice 1" $ do
        let wallet =
                [ (seedIn, adaAt 5_000_000)
                , (fundRef 0, adaAt 200_000_000)
                ]
        seedChecks True seedIn wallet `shouldBe` Right []

soleExplicitSeedNamesOmitRemedy :: Spec
soleExplicitSeedNamesOmitRemedy = describe "a sole explicit seed" $ do
    it "is refused naming omit --seed, never fund a second output" $ do
        case selectSeed
            (Just seedIn)
            ginaWallet
            preprodParams
            applicationScript
            testPayer
            True
            True of
            Right _ ->
                expectationFailure
                    "an explicit sole seed was accepted; the design refuses it while the state script must be published from it"
            Left err -> do
                let text = renderIdentityError err
                text `shouldSatisfy` ("omit `--seed`" `isInfixOf`)
                text `shouldSatisfy` (not . ("second ada-only output" `isInfixOf`))
    it "is accepted with a live carrier (output, as today)" $ do
        selectSeed
            (Just seedIn)
            ginaWallet
            preprodParams
            applicationScript
            testPayer
            False
            True
            `shouldBe` Right (seedIn, "output")

autoChainedVersusLargest :: Spec
autoChainedVersusLargest = describe "auto seed follows the carrier" $ do
    it "with no carrier the seed is the first publication's change" $ do
        case selectSeed
            Nothing
            ginaWallet
            preprodParams
            applicationScript
            testPayer
            True
            False of
            Right (_, from) -> from `shouldBe` "publication-change"
            Left err ->
                expectationFailure
                    ("auto chained refused: " <> renderIdentityError err)
    it "with a live carrier the seed is the largest output" $ do
        let wallet =
                [ (seedIn, adaAt 5_000_000)
                , (fundRef 0, adaAt 10_000_000)
                , (fundRef 1, adaAt 100_000_000)
                ]
        selectSeed
            Nothing
            wallet
            preprodParams
            applicationScript
            testPayer
            False
            False
            `shouldBe` Right (fundRef 1, "output")

explicitPinnedChained :: Spec
explicitPinnedChained = describe "an explicit previewed chained seed" $ do
    it "pins the identity from the unchanged wallet" $ do
        chained <- case firstPublicationChange
            preprodParams
            testPayer
            applicationScript
            ginaWallet of
            Right (seed, _, _, _, _) -> pure seed
            Left err -> fail ("chained seed not built: " <> show err)
        selectSeed
            (Just chained)
            ginaWallet
            preprodParams
            applicationScript
            testPayer
            True
            False
            `shouldBe` Right (chained, "publication-change")
    it "any other unheld seed is still refused" $ do
        selectSeed
            (Just (fundRef 9))
            ginaWallet
            preprodParams
            applicationScript
            testPayer
            True
            False
            `shouldSatisfy` (\case Left (SeedNotInWallet _) -> True; _ -> False)

firstPublicationIsTheSeed :: Spec
firstPublicationIsTheSeed = describe "the first publication's change" $ do
    it
        "is output 1 of the body the builder submits, and a moved view is refused"
        $ do
            named <- case firstPublicationChange
                preprodParams
                testPayer
                applicationScript
                ginaWallet of
                Right (seed@(TxIn seedId _), tx, _, funds, _) -> do
                    seed `shouldSatisfy` (\(TxIn _ (TxIx ix)) -> ix == 1)
                    funds `shouldSatisfy` (not . null)
                    txIdTx tx `shouldBe` seedId
                    pure seed
                Left err -> fail ("chained seed not built: " <> show err)
            (builtTx, _) <- runPublishChained ginaWallet applicationScript
            TxIn (txIdTx builtTx) (TxIx 1) `shouldBe` named
            let moved = [(seedIn, adaAt 199_000_000)]
            movedSeed <- case firstPublicationChange preprodParams testPayer applicationScript moved of
                Right (seed, _, _, _, _) -> pure seed
                Left err -> fail ("moved chained seed not built: " <> show err)
            movedSeed `shouldSatisfy` (/= named)
    it "a 1 tADA wallet cannot fund the first publication" $ do
        case firstPublicationChange
            preprodParams
            testPayer
            applicationScript
            [(seedIn, adaAt 1_000_000)] of
            Right _ -> expectationFailure "a 1 tADA wallet funded the first publication"
            Left _ -> pure ()

chainedJudgementAcceptsOneOutput :: Spec
chainedJudgementAcceptsOneOutput = describe "the chained judgement" $ do
    it "accepts a 200 tADA one-output wallet with no carrier" $ do
        chained <- case firstPublicationChange
            preprodParams
            testPayer
            applicationScript
            ginaWallet of
            Right (seed, _, _, _, _) -> pure seed
            Left err -> fail ("chained seed not built: " <> show err)
        let carrier = (chained, adaAt 200_000_000)
        publicationFunding
            preprodParams
            chained
            (bootCostBound preprodParams cfg carrier)
            beforeOne
            []
            ginaWallet
            `shouldBe` Right ()
    it "agrees with the builder at the first-publication boundary" $ do
        let covers x = case firstPublicationChange
                preprodParams
                testPayer
                applicationScript
                [(seedIn, adaAt x)] of
                Right _ -> True
                Left _ -> False
            lowest = smallest covers 1_000_000 400_000_000
            covering = [(seedIn, adaAt lowest)]
            short = [(seedIn, adaAt (lowest - 1))]
        covers lowest `shouldBe` True
        covers (lowest - 1) `shouldBe` False
        chained <- case firstPublicationChange
            preprodParams
            testPayer
            applicationScript
            covering of
            Right (seed, _, _, _, _) -> pure seed
            Left err -> fail ("boundary covering wallet not built: " <> show err)
        publicationFunding preprodParams chained 0 beforeOne [] covering
            `shouldBe` Right ()
        case publicationFunding preprodParams chained 0 beforeOne [] short of
            Right _ ->
                expectationFailure "one lovelace less still funded the chained run"
            Left _ -> pure ()

-- | The smallest value in the range satisfying a monotone predicate.
smallest :: (Integer -> Bool) -> Integer -> Integer -> Integer
smallest holds low high
    | low >= high = high
    | holds middle = smallest holds low middle
    | otherwise = smallest holds (middle + 1) high
  where
    middle = (low + high) `div` 2

shortOneOutputOneVerdict :: Spec
shortOneOutputOneVerdict = describe "a short one-output wallet" $ do
    it "below the first publication the selection refuses" $ do
        case selectSeed
            Nothing
            [(seedIn, adaAt 1_000_000)]
            preprodParams
            applicationScript
            testPayer
            True
            False of
            Right _ -> expectationFailure "a 1 tADA wallet named a chained seed"
            Left err -> do
                let text = renderIdentityError err
                text `shouldSatisfy` ("publication-unfunded" `isInfixOf`)
                text `shouldSatisfy` ("nothing was submitted" `isInfixOf`)
    it
        "covering the first but not the whole run, the whole-run judgement refuses"
        $ do
            let coversFirst x = case firstPublicationChange
                    preprodParams
                    testPayer
                    applicationScript
                    [(seedIn, adaAt x)] of
                    Right _ -> True
                    Left _ -> False
                firstLowest = smallest coversFirst 1_000_000 400_000_000
                coversWhole x =
                    let wallet = [(seedIn, adaAt x)]
                    in  case firstPublicationChange
                            preprodParams
                            testPayer
                            applicationScript
                            wallet of
                            Right (seed, _, _, _, _) ->
                                publicationFunding preprodParams seed 5_000_000 beforeOne [] wallet
                                    == Right ()
                            Left _ -> False
                wholeLowest = smallest coversWhole firstLowest 400_000_000
                between = wholeLowest - 1
            wholeLowest `shouldSatisfy` (> firstLowest)
            between `shouldSatisfy` (>= firstLowest)
            chained <- case firstPublicationChange
                preprodParams
                testPayer
                applicationScript
                [(seedIn, adaAt between)] of
                Right (seed, _, _, _, _) -> pure seed
                Left err -> fail ("first fits but whole does not: first failed: " <> show err)
            case publicationFunding
                preprodParams
                chained
                5_000_000
                beforeOne
                []
                [(seedIn, adaAt between)] of
                Right _ -> expectationFailure "a short whole run funded"
                Left err -> do
                    let text = renderIdentityError err
                    text `shouldSatisfy` ("publication-unfunded" `isInfixOf`)
                    text `shouldSatisfy` ("nothing was submitted" `isInfixOf`)

movedWalletChangesTheSeed :: Spec
movedWalletChangesTheSeed = describe "a moved wallet" $ do
    it "names the wallet change before anything is submitted" $ do
        let text = renderIdentityError (WalletChangedSinceNamed "a#1" "b#1")
        text
            `shouldSatisfy` ("the wallet changed since the identity was named" `isInfixOf`)
    it "builds a different chained seed from a changed view" $ do
        let other = [(seedIn, adaAt 199_000_000)]
        s0 <- case firstPublicationChange
            preprodParams
            testPayer
            applicationScript
            ginaWallet of
            Right (seed, _, _, _, _) -> pure seed
            Left err -> fail ("chained seed not built: " <> show err)
        s1 <- case firstPublicationChange preprodParams testPayer applicationScript other of
            Right (seed, _, _, _, _) -> pure seed
            Left err -> fail ("moved chained seed not built: " <> show err)
        s0 `shouldSatisfy` (/= s1)

severalOutputsUnchanged :: Spec
severalOutputsUnchanged = describe "several outputs keep today's behaviour" $ do
    it "a held seed with outputs beside it still passes submit checks" $ do
        let wallet =
                [ (seedIn, adaAt 5_000_000)
                , (fundRef 0, adaAt 10_000_000)
                , (fundRef 1, adaAt 100_000_000)
                ]
        seedChecks True seedIn wallet `shouldBe` Right []

{- | Run the real builder against exact wallet outputs over a stub session,
with nothing withheld (the chained first publication spends a prefix of all
the ada-only outputs), as the create's submission step does.
-}
runPublishChained
    :: [(TxIn, TxOut ConwayEra)]
    -> Script ConwayEra
    -> IO (ConwayTx, TxOut ConwayEra)
runPublishChained wallet script = do
    let session =
            withAddressOutputs (\_ -> pure wallet) $
                withParameters preprodParams $
                    withTime (pure syntheticTime) stubSession
    publishRefScriptTx Set.empty session testPayer script
