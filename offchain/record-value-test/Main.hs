{- | Compiled naming value checks. The context is a component fixture, not a
submitted ledger transaction. The blueprint comes from the production build.
-}
module Main (main) where

import Data.ByteString qualified as BS
import PlutusCore.Data (Data (..))
import PlutusCore.Evaluation.Machine.ExBudgetingDefaults (defaultCekParametersForTesting)
import PlutusLedgerApi.V3 (uncheckedDeserialiseUPLC)
import Singular.Registry.Blueprint (applyDataParam, extractCompiledCode, loadBlueprint)
import System.Environment (getEnv)
import Test.Hspec (hspec, it, shouldBe)
import UntypedPlutusCore (Program (..), fakeNameDeBruijn, termMapNames)
import UntypedPlutusCore.Evaluation.Machine.Cek (
    CekReport (..),
    counting,
    logEmitter,
    runCekDeBruijn,
 )
import UntypedPlutusCore.Evaluation.Machine.Cek.Internal (CekResult (..))

main :: IO ()
main = do
    path <- getEnv "NAMING_BLUEPRINT"
    blueprint <- loadBlueprint path >>= either (fail . show) pure
    script <-
        maybe (fail "application compiled code missing") pure $
            extractCompiledCode "application.application.spend" blueprint
    let evaluate context =
            let Program _ _ term = uncheckedDeserialiseUPLC (applyDataParam context script)
             in runCekDeBruijn
                    defaultCekParametersForTesting
                    counting
                    logEmitter
                    (termMapNames fakeNameDeBruijn term)
    hspec $ do
        it "accepts maintenance preserving the representative" $ do
            let report = evaluate (recordContext False False (Constr 0 []))
            succeeded (_cekReportResult report) `shouldBe` True
            _cekReportLogs report `shouldBe` []
        it "refuses an extra-token maintenance continuation by name" $ do
            let report = evaluate (recordContext False True (Constr 0 []))
            refused (_cekReportResult report) `shouldBe` True
            _cekReportLogs report `shouldBe` ["record-value-preservation"]
        it "diagnoses a polluted recovery input by name" $ do
            -- #157 N-redeemers: `Recover { revealed_control, registry }`
            -- is constructor 2 of the three that survived the claim
            -- lifecycle's removal. The polluted record still refuses at
            -- the single-asset check, before recovery is considered.
            let redeemer = Constr 2 [B "reveal", B "registry"]
                report = evaluate (recordContext True True redeemer)
            refused (_cekReportResult report) `shouldBe` True
            _cekReportLogs report `shouldBe` ["record-single-asset"]
        it "diagnoses a polluted retirement input by name" $ do
            -- `Retire { key, revealed_control }` is constructor 1, and it
            -- carries the registry key it ends (#157 N6).
            let redeemer = Constr 1 [B "alice", B "reveal"]
                report = evaluate (recordContext True True redeemer)
            refused (_cekReportResult report) `shouldBe` True
            _cekReportLogs report `shouldBe` ["record-single-asset"]
  where
    succeeded CekSuccessConstant{} = True
    succeeded _ = False
    refused CekFailure{} = True
    refused _ = False

{- | A well-formed four-field record and an authorized Maintain. Only the
continuation's extra asset differs between the accepted and refused cases.
-}
recordContext :: Bool -> Bool -> Data -> Data
recordContext pollutedInput pollutedOutput redeemer =
    Constr 0 [transaction, redeemer, Constr 1 [self, Constr 0 [datum]]]
  where
    controller = BS.replicate 28 0x11
    self = Constr 0 [B (BS.replicate 32 0x22), I 0]
    datum =
        Constr
            0
            [ Constr
                0
                [ B (BS.cons 0x60 controller)
                , Constr 0 []
                , B (BS.replicate 32 0x33)
                , Constr 0 [I 1, List [B controller]]
                ]
            ]
    value extra =
        Map $
            [ (B "", Map [(B "", I 5000000)])
            , (B (BS.replicate 28 0x44), Map [(B "representative", I 1)])
            ]
                <> [(B (BS.replicate 28 0x55), Map [(B "junk", I 1)]) | extra]
    output extra =
        Constr
            0
            [ Constr 0 [Constr 1 [B (BS.replicate 28 0x66)], Constr 1 []]
            , value extra
            , Constr 2 [datum]
            , Constr 1 []
            ]
    transaction =
        Constr
            0
            [ List [Constr 0 [self, output pollutedInput]]
            , List []
            , List [output pollutedOutput]
            , I 0
            , Map []
            , List []
            , Map []
            , Constr
                0
                [ Constr 0 [Constr 0 [], Constr 1 []]
                , Constr 0 [Constr 2 [], Constr 1 []]
                ]
            , List [B controller]
            , Map []
            , Map []
            , B (BS.replicate 32 0x77)
            , Map []
            , List []
            , Constr 1 []
            , Constr 1 []
            ]
