{-# LANGUAGE NumericUnderscores #-}

{- |
Module      : Singular.Application.OpenDatum.RequestScriptSpec
Description : The builders meet the compiled validator, and nothing else
License     : Apache-2.0

Every transaction a request builder makes is judged by the compiled validator
of the application blueprint, read from the file the runner names and checked
against the hash the pinned identity records. These rows prove the judging:
a transaction assembled by hand without a builder is accepted, and refused
again when one fact is wrong, so an acceptance of a builder's output means
the validator ran. They also prove where a transaction takes the script from:
attached to the witness set, or from a reference output whose script has the
expected hash and from no other.
-}
module Singular.Application.OpenDatum.RequestScriptSpec
    ( spec
    ) where

import Control.Exception (SomeException, try)
import Control.Monad (forM_)
import Data.Aeson qualified as Aeson
import Data.ByteString (ByteString)
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Lazy qualified as BL
import Data.Text.Encoding (decodeUtf8)
import Data.List (isPrefixOf)
import Data.Map.Strict qualified as Map
import Lens.Micro ((&), (.~), (^.))
import PlutusCore.Data qualified as PLC
import Test.Hspec

import Cardano.Ledger.Address (Addr (..))
import Cardano.Ledger.Api.Tx (witsTxL)
import Cardano.Ledger.Api.Tx.Out
    ( coinTxOutL
    , mkBasicTxOut
    , referenceScriptTxOutL
    )
import Cardano.Ledger.Api.Tx.Wits (scriptTxWitsL)
import Cardano.Ledger.BaseTypes (Inject (..), StrictMaybe (..))
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Core (hashScript)
import Cardano.Ledger.Credential
    ( Credential (..)
    , StakeReference (..)
    )
import Cardano.Ledger.Mary.Value (PolicyID (..))
import Cardano.Slotting.Slot (SlotNo (..))

import Singular.Application.OpenDatum.RequestWorld
    ( Purpose (..)
    , Return (..)
    , Scenario (..)
    , ada
    , addOutputs
    , adjustRegistrationField
    , bookWithScript
    , compiledScript
    , defaultPending
    , everyScriptAccepts
    , expectBuilt
    , firstBooking
    , handBooking
    , handReturn
    , inlineDatum
    , judge
    , keyAddress
    , keyHashOf
    , mapOutput
    , network
    , newScenario
    , pendingFixture
    , pinnedScriptHash
    , referencesOf
    , refusedBy
    , removeOutputs
    , soundnessProblems
    , txInOf
    , withDatum
    , withReferences
    , withSigners
    )
import Singular.Application.OpenDatum.Requests.Refusal (Refusal (..))
import Singular.Application.OpenDatum.Requests.Script
    ( RequestScript (..)
    , ScriptSource (..)
    , requestAddress
    , requestPolicy
    , requestScriptFromBlueprint
    , requestScriptHash
    )
import Singular.Registry.Blueprint (Blueprint, loadBlueprint)
import Singular.Registry.ContractTable
    ( Contracts (..), ApplicationIdentity (..), applicationOf, applicationRows
    , contractsOf, loadContractTable, parseContractTable, tableRows
    )
import Singular.State.Script (stateScriptFromBlueprint)
import Singular.Registry.SyntheticLedger (unitProgram)
import Singular.Registry.TxBuilder.Internal (scriptFromBytes, scriptHashBytes)
import System.Environment (lookupEnv)

tipSlot :: SlotNo
tipSlot = SlotNo 10_000

currentIdentity :: IO (ByteString, ByteString)
currentIdentity = do
    application <- compiledScript
    path <- lookupEnv "SINGULAR_STATE_BLUEPRINT" >>= maybe (fail "state blueprint is not set") pure
    blueprint <- loadBlueprint path >>= either fail pure
    state <- either fail pure (stateScriptFromBlueprint blueprint (PolicyID (hashScript application)))
    pure (scriptHashBytes (hashScript state), scriptHashBytes (hashScript application))

spec :: Spec
spec = do
    describe "the compiled validator the rows judge with" $ do
        it "has the current build's applied state policy in the packaged release table" $ do
            application <- compiledScript
            path <- lookupEnv "SINGULAR_STATE_BLUEPRINT" >>= maybe (fail "state blueprint is not set") pure
            blueprint <- loadBlueprint path >>= either fail pure
            state <- either fail pure (stateScriptFromBlueprint blueprint (PolicyID (hashScript application)))
            table <- loadContractTable >>= either (fail . show) pure
            contractsOf table (scriptHashBytes (hashScript state)) `shouldSatisfy` (/= NoKnownRelease)
        it "identifies the current application from the applied state policy" $ do
            (state, application) <- currentIdentity
            table <- loadContractTable >>= either (fail . show) pure
            case applicationOf table state of
                Just identity -> do
                    appliedStatePolicy identity `shouldBe` state
                    applicationPolicy identity `shouldBe` application
                    applicationScript identity `shouldBe` application
                Nothing -> expectationFailure "the current application is unknown"
        it "fails the current-build check when the same table loses its row" $ do
            (state, _) <- currentIdentity
            table <- loadContractTable >>= either (fail . show) pure
            let present candidate = contractsOf candidate state /= NoKnownRelease
                bytes = BL.toStrict (Aeson.encode (Aeson.object
                    [ "rows" Aeson..= [ Aeson.object ["state-contract" Aeson..= decodeUtf8 (B16.encode hash), "releases" Aeson..= releases] | (hash, releases) <- tableRows table ]
                    , "applications" Aeson..= filter ((/= state) . appliedStatePolicy) (applicationRows table)
                    ]))
            without <- either (fail . show) pure (parseContractTable bytes)
            present table `shouldBe` True
            present without `shouldBe` False
        it "is the one the pinned identity records" $ do
            script <- compiledScript
            pinned <- pinnedScriptHash
            hashScript script `shouldBe` pinned
        it "is the one the library reads from the blueprint" $ do
            blueprint <- blueprintHere
            expected <- pinnedScriptHash
            fmap hashScript (requestScriptFromBlueprint blueprint)
                `shouldBe` Right expected
        it
            "gives the policy and the address of the tokens and the pending registrations"
            $ do
                script <- compiledScript
                pinned <- pinnedScriptHash
                let carried = RequestScript script Attached
                requestScriptHash carried `shouldBe` pinned
                requestPolicy carried `shouldBe` PolicyID pinned
                requestAddress network carried
                    `shouldBe` Addr network (ScriptHashObj pinned) StakeRefNull

    describe "the judging of a transaction" $ do
        it "accepts a booking assembled by hand, without a builder" $ do
            sc <- newScenario tipSlot
            verdicts <- judge (scChain sc) (handBooking sc)
            map fst verdicts `shouldBe` [Mint]
            verdicts `shouldSatisfy` everyScriptAccepts
        forM_ handMutations $ \(name, mutate) ->
            it ("refuses the same booking when " <> name) $ do
                sc <- newScenario tipSlot
                verdicts <- judge (scChain sc) (mutate (handBooking sc))
                verdicts `shouldSatisfy` refusedBy
        forM_ [(ByReclaim, "reclaim"), (ByCleanup, "cleanup")] $ \(way, name) -> do
            it ("accepts a " <> name <> " assembled by hand, without a builder") $ do
                sc <- newScenario (SlotNo 10_000)
                let held = defaultPending (scRegistry sc)
                    (ref, out) = pendingFixture (scHash sc) held
                addOutputs (scChain sc) [(ref, out)]
                verdicts <- judge (scChain sc) (handReturn sc held ref way)
                map fst verdicts `shouldBe` [Mint, Spend]
                verdicts `shouldSatisfy` everyScriptAccepts
        it
            "refuses a reclaim assembled by hand when the refund address does not sign"
            $ do
                sc <- newScenario (SlotNo 10_000)
                let held = defaultPending (scRegistry sc)
                    (ref, out) = pendingFixture (scHash sc) held
                addOutputs (scChain sc) [(ref, out)]
                verdicts <-
                    judge (scChain sc) (withSigners [] (handReturn sc held ref ByReclaim))
                verdicts `shouldSatisfy` refusedBy
        it
            "refuses a cleanup assembled by hand when the deposit is not returned"
            $ do
                sc <- newScenario (SlotNo 10_000)
                let held = defaultPending (scRegistry sc)
                    (ref, out) = pendingFixture (scHash sc) held
                addOutputs (scChain sc) [(ref, out)]
                verdicts <-
                    judge
                        (scChain sc)
                        ( mapOutput
                            0
                            (\o -> o & coinTxOutL .~ Coin 1)
                            (handReturn sc held ref ByCleanup)
                        )
                verdicts `shouldSatisfy` refusedBy
        it "reports a transaction that does not balance and pays no fee" $ do
            sc <- newScenario tipSlot
            problems <- soundnessProblems (scChain sc) (handBooking sc)
            problems `shouldSatisfy` any (isPrefixOf "value is not conserved")
            problems
                `shouldSatisfy` any (isPrefixOf "the fee 0 is below the minimum")
        it
            "tells a transaction it cannot judge from one the validator refuses"
            $ do
                sc <- newScenario tipSlot
                removeOutputs (scChain sc) [scRecord sc]
                outcome <- try (judge (scChain sc) (handBooking sc))
                case outcome of
                    Left (_ :: SomeException) -> pure ()
                    Right verdicts ->
                        expectationFailure
                            ("a missing input was judged instead of reported: " <> show verdicts)

    describe "where a booking takes the script from" $ do
        it "attaches it to the witness set when the code is attached" $ do
            sc <- newScenario tipSlot
            tx <- bookWith sc (scScript sc) >>= expectBuilt
            Map.keys (tx ^. witsTxL . scriptTxWitsL) `shouldBe` [scHash sc]
        it "reads it from a reference output that carries the expected script" $ do
            sc <- newScenario tipSlot
            let reference = txInOf 'a' 0
            addOutputs
                (scChain sc)
                [(reference, carrying (rsScript (scScript sc)))]
            tx <-
                bookWith
                    sc
                    (RequestScript (rsScript (scScript sc)) (Referenced reference))
                    >>= expectBuilt
            Map.keys (tx ^. witsTxL . scriptTxWitsL) `shouldBe` []
            referencesOf tx `shouldSatisfy` elem reference
            verdicts <- judge (scChain sc) tx
            verdicts `shouldSatisfy` everyScriptAccepts
        it "refuses a reference output that carries another script" $ do
            sc <- newScenario tipSlot
            let reference = txInOf 'a' 0
                other = scriptFromBytes "another script" (unitProgram 1)
            addOutputs (scChain sc) [(reference, carrying other)]
            bookWith
                sc
                (RequestScript (rsScript (scScript sc)) (Referenced reference))
                `shouldReturn` Left
                    ( ReferenceScriptMismatch
                        reference
                        (Just (hashScript other))
                        (scHash sc)
                    )
        it "refuses a reference output that carries no script" $ do
            sc <- newScenario tipSlot
            let reference = txInOf 'a' 0
            addOutputs
                (scChain sc)
                [(reference, mkBasicTxOut (keyAddress 0x77) (inject (ada 20)))]
            bookWith
                sc
                (RequestScript (rsScript (scScript sc)) (Referenced reference))
                `shouldReturn` Left (ReferenceScriptMismatch reference Nothing (scHash sc))
        it "refuses a reference output that is not on the chain" $ do
            sc <- newScenario tipSlot
            let reference = txInOf 'a' 0
            bookWith
                sc
                (RequestScript (rsScript (scScript sc)) (Referenced reference))
                `shouldReturn` Left (ReferenceScriptMissing reference)
  where
    carrying script =
        mkBasicTxOut (keyAddress 0x77) (inject (ada 20))
            & referenceScriptTxOutL .~ SJust script
    handMutations =
        [
            ( "the deposit it commits is one lovelace more"
            , mapOutput 0 (field 6 plusOne)
            )
        , ("the payer does not sign", withSigners [])
        , ("the configuration record is not read", withReferences [])
        ,
            ( "the controller is another key"
            , mapOutput 0 (field 2 (const (PLC.B (keyHashOf 0x99))))
            )
        ]
    field n change o = case inlineDatum o of
        Just d -> withDatum (adjustRegistrationField n change d) o
        Nothing -> o
    bookWith sc script = bookWithScript sc script firstBooking

plusOne :: PLC.Data -> PLC.Data
plusOne (PLC.I n) = PLC.I (n + 1)
plusOne other = other

-- | The blueprint the runner names.
blueprintHere :: IO Blueprint
blueprintHere = do
    path <- lookupEnv "OPEN_DATUM_BLUEPRINT"
    maybe (fail "OPEN_DATUM_BLUEPRINT is not set") loadBlueprint path
        >>= either fail pure
