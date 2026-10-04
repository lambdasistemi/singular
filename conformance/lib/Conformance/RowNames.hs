{- | Descriptive current requirement names and the original names recorded in
historical receipts. This association changes naming only: the receipt's base,
verdict, measurements and evidence are still validated by the receipt loader.
-}
module Conformance.RowNames
    ( canonicalRowName
    , historicalRowNames
    ) where

import Data.Maybe (fromMaybe)
import Data.Text (Text)

-- | Resolve a historical receipt key; current and unknown names pass through.
canonicalRowName :: Text -> Text
canonicalRowName name = fromMaybe name (lookup name historicalRowNames)

-- | The complete, one-time association for the 46 published requirements.
historicalRowNames :: [(Text, Text)]
historicalRowNames =
    [ ("CA01", "canonical-seed-identity")
    , ("CA02", "rival-seed-authentication")
    , ("CA03", "policy-address-only-authentication-control")
    , ("CA04", "applied-validator-identity")
    , ("CA05", "tokenless-output-authentication")
    , ("CG01", "insert-key")
    , ("CG02", "update-existing-key")
    , ("CG03", "delete-existing-key")
    , ("CG04", "reinsert-deleted-key")
    , ("CG05", "insert-occupied-key")
    , ("CG06", "retract-inside-window")
    , ("CG07", "retract-outside-window")
    , ("CG08", "reject-after-window")
    , ("CG09", "reject-before-deadline-consumer-requirement")
    , ("CG10", "fold-against-superseded-root")
    , ("CG11", "empty-fold")
    , ("CG12", "surplus-fold-actions")
    , ("CG13", "historical-owner-change")
    , ("CG14", "retired-stake-hook-with-withdrawal")
    , ("CG15", "retired-stake-hook-without-withdrawal")
    , ("CG16", "historical-owner-signed-sweep")
    , ("CG17", "historical-non-owner-sweep")
    , ("CG18", "historical-registry-termination")
    , ("CG19", "request-value-and-refund-routing")
    , ("CG20", "historical-permissionless-fold")
    , ("CG21", "register-active-key")
    , ("CG22", "retire-active-key")
    , ("CG23", "reject-and-retract-refund-controls")
    , ("CG24", "reject-inside-processing-and-retraction-windows")
    , ("CS01", "blueprint-encoding-round-trip")
    , ("CS02", "submitted-datum-byte-round-trip")
    , ("CS03", "update-redeemer-constructor-witnesses")
    , ("CS04", "wrong-redeemer-constructor-index")
    , ("CS05", "request-and-mint-constructor-witnesses")
    , ("CS06", "script-parameter-application")
    , ("CS07", "proof-step-constructor-witnesses")
    , ("CS08", "state-fields-chain-round-trip")
    , ("CK01", "resolve-active-registration")
    , ("CK02", "authenticate-representative-token")
    , ("CK03", "resolve-with-no-candidate")
    , ("CK04", "prevent-second-live-representative")
    , ("CK05", "resolve-pending-terminal-request")
    , ("CK06", "checkpoint-and-treasury-policy")
    , ("CL01", "execution-units-and-transaction-size")
    , ("CL02", "fold-batch-size-boundary")
    , ("CL03", "observed-toolchain-and-environment")
    ]
