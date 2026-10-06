{- | The CLI controls use the same shipping HTTP/time composition as the
ordinary executable. The private node socket belongs only to independent
probes and process-loss controls in the harness.
-}
module Conformance.Cli.Node
    ( NodeCaps (..)
    , withBackendNode
    ) where

import Cardano.Tx.Ledger (ConwayTx)
import Singular.Registry.Capabilities (Capabilities (..))
import Singular.Registry.Evidence (NoWitness)
import Singular.Registry.LedgerProvider
    ( LedgerProvider
    , Network
    , SubmitResult
    )
import Singular.Registry.ProviderSettings (ProviderSettings)
import Singular.Registry.Signing (SignedTx)
import Singular.Registry.Terminal (withWrites)
import Singular.Registry.Wallet (Wallet)

-- | The actual provider operations retained by a backend action.
data NodeCaps = NodeCaps
    { ncReads :: (Network, LedgerProvider NoWitness IO)
    , ncSubmit :: SignedTx -> IO SubmitResult
    , ncConfirm :: ConwayTx -> IO ()
    }

withBackendNode
    :: ProviderSettings -> Wallet -> (NodeCaps -> IO a) -> IO a
withBackendNode settings wallet body =
    withWrites settings wallet $ \caps ->
        body
            NodeCaps
                { ncReads = capReads caps
                , ncSubmit = capSubmit caps
                , ncConfirm = capConfirm caps
                }
