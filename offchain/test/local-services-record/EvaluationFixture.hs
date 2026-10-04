{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE TypeApplications #-}

-- | Non-submitted, content-dependent transactions for the recorded evaluator.
module EvaluationFixture (captureFixtures) where

import Control.Monad (forM_)
import Data.Aeson (encode, object, (.=))
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Lazy qualified as LBS
import Data.Map.Strict qualified as Map
import Data.Sequence.Strict qualified as Seq
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.Text.Encoding (decodeUtf8)
import Lens.Micro ((&), (.~))
import System.FilePath ((</>))

import Cardano.Ledger.Address (Addr, serialiseAddr)
import Cardano.Ledger.Alonzo.Scripts (AsIx (..))
import Cardano.Ledger.Api.Scripts.Data (Data (..))
import Cardano.Ledger.Api.Tx (mkBasicTx, witsTxL)
import Cardano.Ledger.Api.Tx.Body
    ( collateralInputsTxBodyL
    , inputsTxBodyL
    , mintTxBodyL
    , mkBasicTxBody
    , outputsTxBodyL
    , referenceInputsTxBodyL
    , scriptIntegrityHashTxBodyL
    )
import Cardano.Ledger.Api.Tx.Out (TxOut, datumTxOutL, mkBasicTxOut)
import Cardano.Ledger.Api.Tx.Wits
    ( Redeemers (..)
    , rdmrsTxWitsL
    , scriptTxWitsL
    )
import Cardano.Ledger.BaseTypes (Network (Testnet))
import Cardano.Ledger.Binary (decodeFull', serialize')
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Conway.Scripts (ConwayPlutusPurpose (..))
import Cardano.Ledger.Core (PParams, eraProtVerLow, hashScript)
import Cardano.Ledger.Mary.Value
    ( AssetName (..)
    , MaryValue (..)
    , MultiAsset (..)
    , PolicyID (..)
    )
import Cardano.Ledger.Plutus.ExUnits (ExUnits (..))
import Cardano.Ledger.TxIn (TxIn)
import Cardano.Tx.Ledger (ConwayTx)
import Codec.Binary.Bech32 qualified as Bech32
import PlutusCore.Default (DefaultFun (..), DefaultUni)
import PlutusCore.MkPlc (mkConstant)
import PlutusCore.Version (plcVersion110)
import PlutusLedgerApi.V3 qualified as PLC
import UntypedPlutusCore qualified as UPLC

import Singular.Registry.Deployment (parseOutRef)
import Singular.Registry.TxBuilder.Internal
    ( addrFromKeyHashBytes
    , computeScriptIntegrity
    , mkInlineDatum
    , scriptFromBytes
    )

type Term = UPLC.Term UPLC.DeBruijn DefaultUni DefaultFun ()

app :: Term -> Term -> Term
app = UPLC.Apply ()

builtin :: DefaultFun -> Term
builtin = UPLC.Builtin ()

-- Context serialization forces both spent and reference-output contents;
-- checking the redeemer yields a real ledger script failure on the control.
program :: PLC.SerialisedScript
program =
    PLC.serialiseUPLC $
        UPLC.Program () plcVersion110 $
            UPLC.LamAbs () (UPLC.DeBruijn 0) $
                choose
                    ( app
                        (app (builtin EqualsInteger) redeemer)
                        (mkConstant () (42 :: Integer))
                    )
                    (choose serializedSize (mkConstant () ()) (UPLC.Error ()))
                    (UPLC.Error ())
  where
    context = UPLC.Var () (UPLC.DeBruijn 1)
    fields =
        app
            (UPLC.Force () (UPLC.Force () (builtin SndPair)))
            (app (builtin UnConstrData) context)
    redeemer =
        app (builtin UnIData) $
            app (UPLC.Force () (builtin HeadList)) $
                app (UPLC.Force () (builtin TailList)) fields
    serializedSize =
        app
            ( app
                (builtin LessThanInteger)
                (app (builtin LengthOfByteString) (app (builtin SerialiseData) context))
            )
            (mkConstant () (1_000_000 :: Integer))
    choose condition yes no =
        UPLC.Force () $
            app
                ( app
                    (app (UPLC.Force () (builtin IfThenElse)) condition)
                    (UPLC.Delay () yes)
                )
                (UPLC.Delay () no)

payer :: Addr
payer = addrFromKeyHashBytes Testnet (BS.replicate 28 0x5a)

input :: Char -> TxIn
input c =
    either
        error
        id
        (parseOutRef (Text.replicate 64 (Text.singleton c) <> "#0"))

inputs :: [(TxIn, TxOut ConwayEra)]
inputs =
    [ ( input c
      , mkBasicTxOut payer (MaryValue (Coin 9_000_000) mempty)
            & datumTxOutL .~ mkInlineDatum (PLC.B (BS.replicate 8 (fromIntegral n)))
      )
    | (c, n) <- zip "abc" [1 :: Int ..]
    ]

transaction :: PParams ConwayEra -> Integer -> ConwayTx
transaction pp redeemer =
    mkBasicTx
        ( mkBasicTxBody
            & inputsTxBodyL .~ Set.singleton (input 'a')
            & collateralInputsTxBodyL .~ Set.singleton (input 'b')
            & referenceInputsTxBodyL .~ Set.singleton (input 'c')
            & mintTxBodyL
                .~ MultiAsset
                    ( Map.singleton
                        (PolicyID (hashScript script))
                        (Map.singleton (AssetName "local-services") 1)
                    )
            & outputsTxBodyL
                .~ Seq.singleton (mkBasicTxOut payer (MaryValue (Coin 1_000_000) mempty))
            & scriptIntegrityHashTxBodyL .~ computeScriptIntegrity pp witnesses
        )
        & witsTxL . rdmrsTxWitsL .~ witnesses
        & witsTxL . scriptTxWitsL .~ Map.singleton (hashScript script) script
  where
    script = scriptFromBytes "local-services-context" program
    witnesses =
        Redeemers
            ( Map.singleton
                (ConwayMinting (AsIx 0))
                (Data (PLC.I redeemer), ExUnits 17_000_000 9_000_000_000)
            )

captureFixtures :: FilePath -> FilePath -> IO ()
captureFixtures output parametersPath = do
    bytes <- BS.readFile parametersPath
    pp <- either (fail . show) pure (decodeFull' version bytes)
    BS.writeFile (output </> "protocol-parameters.cbor") bytes
    let address =
            Bech32.encodeLenient
                ( either
                    (error . show)
                    id
                    (Bech32.humanReadablePartFromText "addr_test")
                )
                (Bech32.dataPartFromBytes (serialiseAddr payer))
        additional =
            [ object
                [ "transaction" .= object ["id" .= Text.replicate 64 (Text.singleton c)]
                , "index" .= (0 :: Int)
                , "address" .= address
                , "value"
                    .= object ["ada" .= object ["lovelace" .= (9_000_000 :: Integer)]]
                , "datum"
                    .= hex
                        ( serialize'
                            version
                            (Data (PLC.B (BS.replicate 8 (fromIntegral n))) :: Data ConwayEra)
                        )
                ]
            | (c, n) <- zip "abc" [1 :: Int ..]
            ]
    BS.writeFile
        (output </> "resolved-inputs.cbor")
        (serialize' version inputs)
    forM_ [("success", 42), ("script-failure", 43)] $ \(name, redeemer) -> do
        let txBytes = serialize' version (transaction pp redeemer)
        BS.writeFile (output </> name <> ".cbor") txBytes
        LBS.writeFile (output </> name <> ".params.json") $
            encode $
                object
                    [ "transaction" .= object ["cbor" .= hex txBytes]
                    , "additionalUtxo" .= additional
                    ]
    putStrLn
        "Recorded two non-submitted script transactions and their complete input facts"
  where
    version = eraProtVerLow @ConwayEra
    hex = decodeUtf8 . B16.encode
