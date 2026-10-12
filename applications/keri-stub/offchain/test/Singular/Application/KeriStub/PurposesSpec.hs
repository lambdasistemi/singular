{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.Application.KeriStub.PurposesSpec
Description : The stub's one script serves both purposes it is pinned for
License     : Apache-2.0

The stub's script is one program serving two purposes: the approval
minting policy of every booking and the spending script of the holdings
the registry folds into being. The ledger applies a Plutus V3 script to
one argument, the 'ScriptContext' as data, whose script-info constructor
names the purpose; the program dispatches on that constructor, so
accepting one purpose proves nothing about the other.

These rows evaluate the production script bytes through the ledger's own
deserialiser and counter with a script context of each purpose, built as
plain data: the minting context of a booking, the spending context of a
holding release, and a rewarding context the script does not serve. The
program the stub refused to ship — a mint handler alone, whose bytes this
suite keeps as the control — is evaluated beside them: it must pass the
mint and fail the spend, which is exactly the finding that blocked its
merge and the reason this check exists.

What the rows cannot see: a zero cost model makes the verdicts
budget-free (accepted is accepted, not accepted within a budget), the
transaction infos are minimal shapes, and no chain confirms the
evaluation — the devnet journey does that for the mint, while the spend
itself is convicted in a later brief.
-}
module Singular.Application.KeriStub.PurposesSpec (spec) where

import Control.Monad.Except (runExceptT)
import Control.Monad.Writer (runWriter)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Short (ShortByteString)
import Data.ByteString.Short qualified as SBS
import Data.Either (isRight)
import Data.Text (Text)
import Data.Text.Encoding (encodeUtf8)
import Test.Hspec

import PlutusCore.Data (Data (..))
import PlutusCore.Evaluation.Machine.CostModelInterface
    ( CostModelApplyWarn
    )
import PlutusLedgerApi.V3
    ( MajorProtocolVersion (..)
    , VerboseMode (Quiet)
    , deserialiseScript
    , evaluateScriptCounting
    , mkEvaluationContext
    )

import Singular.Application.KeriStub.Script (keriStubScriptBytes)

{- | The program the stub refused to ship: one mint handler returning
true, compiled by the same pinned Aiken from
@validator only { mint(_, _, _) { True } else(_) { fail } }@. A
booking's mint succeeds under it — the devnet proved that before the
change — while the spend of the holding the booking strands is
refused by its failing fallback. Kept as the control these rows run
against, so a future script that drops the spend fails here again.
-}
mintOnlyBytes :: ShortByteString
mintOnlyBytes =
    hex
        "585401010029800aba2aba1aab9eaab9dab9a4888896600264653001300600198031803800cc0180092225980099b8748000c01cdd500144c9289bae30093008375400516401830060013003375400d149a26cac8009"

hex :: Text -> ShortByteString
hex t =
    SBS.toShort
        (either (error "PurposesSpec: bad hex") id (B16.decode (encodeUtf8 t)))

{- | A minimal transaction info as data: the always-succeeding script
reads nothing of it, but the context must be shaped as one.
-}
emptyTxInfo :: Data
emptyTxInfo =
    Constr
        0
        [ List []
        , List []
        , List []
        , I 0
        , Map []
        , List []
        , List []
        , Constr 0 []
        , List []
        , Map []
        , Map []
        , B (BS.replicate 32 0)
        , Map []
        , List []
        , Constr 1 []
        , I 0
        ]

{- | A script context as data: the transaction info, the redeemer, and
the script info whose constructor names the purpose.
-}
contextOf :: Data -> Data -> Data
contextOf redeemer info = Constr 0 [emptyTxInfo, redeemer, info]

-- | The minting script info of a booking: constructor 0 with the policy.
minting :: Data
minting = Constr 0 [B "00"]

{- | The spending script info of a holding release: constructor 1 with
the output reference.
-}
spending :: Data
spending = Constr 1 [B (BS.pack [1 .. 32]), I 0]

-- | A purpose the stub's script does not serve: constructor 2.
rewarding :: Data
rewarding = Constr 2 [B (BS.replicate 28 1)]

{- | The ledger's answer to a script under one argument: accepted when
the evaluation finishes, refused on any evaluation error. The zero
cost model makes acceptance budget-free, so the verdict is the
program's decision alone.
-}
accepted :: ShortByteString -> Data -> Bool
accepted programBytes argument =
    case deserialiseScript (MajorProtocolVersion 9) programBytes of
        Left _ -> False
        Right forEvaluation ->
            isRight
                ( snd
                    ( evaluateScriptCounting
                        (MajorProtocolVersion 9)
                        Quiet
                        zeroCostModel
                        forEvaluation
                        argument
                    )
                )
  where
    zeroCostModel = case candidates of
        (one : _) -> one
        [] -> error "PurposesSpec: no zero cost model length applies"
    candidates =
        [ ok
        | n <- [180 .. 200]
        , (Right ok, _ :: [CostModelApplyWarn]) <-
            [runWriter (runExceptT (mkEvaluationContext (replicate n 0)))]
        ]

spec :: Spec
spec = describe "the stub script's two purposes" $ do
    it "accepts its minting purpose: the booking's approval" $
        accepted keriStubScriptBytes (contextOf redeemer minting)
            `shouldBe` True
    it "accepts its spending purpose: the holding's release" $
        accepted keriStubScriptBytes (contextOf redeemer spending)
            `shouldBe` True
    it "refuses a purpose it does not serve" $
        accepted keriStubScriptBytes (contextOf redeemer rewarding)
            `shouldBe` False
    it "the refused mint-only program passes the mint and fails the spend" $ do
        accepted mintOnlyBytes (contextOf redeemer minting) `shouldBe` True
        accepted mintOnlyBytes (contextOf redeemer spending) `shouldBe` False
  where
    redeemer = Constr 0 [I 1, B "key", B "ctrl", List [B "a", B "h"]]
