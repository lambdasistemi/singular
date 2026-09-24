{- | Ledger-constructed script error, bound to the saved node submission prefix.
The full budget refusal is node-log evidence. The ordinary script's suffix
was discarded by the old formatter, so its error is constructed by the same
ledger Show instances using the observed script bytes and evaluation cause.
The named trace is deliberately a fixture, not an observed validator trace.
-}
module Conformance.Fixture.NodeRejection (scriptRejection) where

import Cardano.Ledger.Alonzo.Rules (FailureDescription (..), TagMismatchDescription (..))
import Cardano.Ledger.Alonzo.Tx (IsValid (..))
import Cardano.Ledger.Conway (ApplyTxError (..))
import Cardano.Ledger.Conway.Rules qualified as Conway
import Data.ByteString.Char8 qualified as BS
import Data.SOP.Strict (NS (..))
import Data.Text (Text)
import Data.Text qualified as T
import Ouroboros.Consensus.Cardano.Block (CardanoBlock, StandardCrypto)
import Ouroboros.Consensus.Cardano.CanHardFork ()
import Ouroboros.Consensus.Shelley.Ledger.SupportsProtocol ()
import Ouroboros.Consensus.HardFork.Combinator.AcrossEras (OneEraApplyTxErr (..))
import Ouroboros.Consensus.HardFork.Combinator.Mempool (HardForkApplyTxErr (..))
import Ouroboros.Consensus.Ledger.SupportsMempool (ApplyTxErr)
import Ouroboros.Consensus.TypeFamilyWrappers (WrapApplyTxErr (..))

-- | Generate the full error with real ledger constructors; never type its Show shape.
scriptRejection :: Text -> Text -> Either String Text
scriptRejection budget evaluation = do
    let payload = T.drop (T.length "PlutusFailure ") (snd (T.breakOn "PlutusFailure " budget))
    (message, rest) <- readPart (T.unpack payload)
    (debug, _) <- readPart rest
    let header = fst (T.breakOn "The plutus evaluation error is:" (T.pack message))
        cause = fst (T.breakOn ") [] (PlutusWithContext" (snd (T.breakOn "CekError" evaluation)))
        detail = header <> "The plutus evaluation error is: " <> cause
            <> "\nTrace: fixture-guard\nThe protocol version is: Version 10\n"
        ledger = ConwayApplyTxError (pure (Conway.ConwayUtxowFailure
            (Conway.UtxoFailure (Conway.UtxosFailure (Conway.ValidationTagMismatch
                (IsValid True) (FailedUnexpectedly (pure (PlutusFailure detail (BS.pack debug)))))))))
        wrapped = HardForkApplyTxErrFromEra (OneEraApplyTxErr
            (S (S (S (S (S (S (Z (WrapApplyTxErr ledger)))))))))
            :: ApplyTxErr (CardanoBlock StandardCrypto)
    if T.null header || T.null cause
        then Left "node fixture lacks script header or evaluation cause"
        else Right (T.pack (show wrapped))
  where
    readPart input = case reads input :: [(String, String)] of
        [(value, rest)] -> Right (value, rest)
        _ -> Left "node fixture does not contain ledger Show string fields"
