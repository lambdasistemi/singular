{-# LANGUAGE GHC2021 #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeApplications #-}

-- Narrow evidence producer: calls the frozen production SDK directly.
module Main (main) where

import Cardano.MPFS.Cage.Blueprint
import Cardano.Crypto.Hash (hashToBytes)
import Cardano.Ledger.Alonzo.Scripts (mkPlutusScript, fromPlutusScript)
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Core (hashScript)
import Cardano.Ledger.Hashes (ScriptHash (..))
import Cardano.Ledger.Plutus.Language (Language (PlutusV3), Plutus (..), PlutusBinary (..))
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as Hex
import Data.ByteString.Char8 qualified as C8
import Data.ByteString.Short qualified as SBS
import System.Environment (getArgs)

-- The ledger operations used by frozen Internal.computeScriptHash and
-- Internal.scriptHashBytes, without loading unrelated transaction builders.
ledgerHash :: SBS.ShortByteString -> IO BS.ByteString
ledgerHash bytes =
    case mkPlutusScript @ConwayEra (Plutus @PlutusV3 (PlutusBinary bytes)) of
        Nothing -> fail "invalid PlutusV3 script"
        Just script -> case hashScript @ConwayEra (fromPlutusScript script) of
            ScriptHash h -> pure (hashToBytes h)

main :: IO ()
main = do
    [blueprintPath, output] <- getArgs
    parsed <- loadBlueprint blueprintPath
    blueprint <- either fail pure parsed
    case filter ((== "state.state.spend") . vTitle) (validators blueprint) of
        [_] -> pure ()
        _ -> fail "expected exactly one state.state.spend validator"
    raw <- maybe (fail "state.state.spend has no compiled code") pure
        (extractCompiledCode "state.state.spend" blueprint)
    let applied = applyPreviousPolicies [] raw
    appliedHash <- ledgerHash applied
    rawHash <- ledgerHash raw
    BS.writeFile (output <> "/unapplied.serialised.cbor") (SBS.fromShort raw)
    BS.writeFile (output <> "/applied.serialised.cbor") (SBS.fromShort applied)
    C8.writeFile (output <> "/applied.single-cbor.hex")
        (Hex.encode (SBS.fromShort applied))
    C8.writeFile (output <> "/applied.script-hash.hex")
        (Hex.encode appliedHash)
    C8.writeFile (output <> "/unapplied.script-hash.hex")
        (Hex.encode rawHash)
    putStrLn "produced applied List[] identity using frozen Blueprint and Internal APIs"
