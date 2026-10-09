{- | Capabilities retained by a command or runner. Reads use the explicit
network and generic provider; submission accepts only signed bytes; clocks
and bounded confirmation belong to the caller's effect composition.
-}
module Singular.Registry.Capabilities
    ( Capabilities (..)
    , sessionReceipt
    , withCapSession
    , submitCap
    , confirmCap
    ) where

import Cardano.Tx.Ledger (ConwayTx)
import Data.Aeson (Value (..), object, toJSON, (.=))
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Base16 qualified as B16
import Data.Text (Text)
import Data.Text.Encoding (decodeUtf8)
import Singular.Registry.Evidence
    ( SessionBinding (..)
    , SessionId (..)
    )
import Singular.Registry.LedgerProvider
    ( LedgerProvider
    , Network (..)
    , Session (..)
    , SubmitResult
    )
import Singular.Registry.SessionEvidence (FactRecord (..))
import Singular.Registry.SessionIO (withLatest)
import Singular.Registry.Signing (SignedTx)

data Capabilities w m = Capabilities
    { capReads :: (Network, LedgerProvider w m)
    {- ^ The provider, undecorated: each scope that reads wraps it with its own
    tracer ('Singular.Registry.ProviderTrace.tracedLedgerProvider')
    -}
    , capSubmit :: SignedTx -> m SubmitResult
    , capConfirm :: ConwayTx -> m ()
    , capFacts :: m [FactRecord]
    , capTrace :: m [Value]
    }

{- | Acquire the capability's read session. This is the one named
acquisition production builders use: the raw provider pair behind
'capReads' never leaves this module.
-}
withCapSession :: Capabilities w IO -> (Session w IO -> IO a) -> IO a
withCapSession caps = withLatest (capReads caps)

-- | Submit signed bytes through the capability.
submitCap :: Capabilities w m -> SignedTx -> m SubmitResult
submitCap = capSubmit

-- | Confirm a submitted transaction through the capability.
confirmCap :: Capabilities w m -> ConwayTx -> m ()
confirmCap = capConfirm

{- | Only the actual scope's facts and source exchanges; later confirmation
and prior funding scopes cannot enter this body's evidence.
-}
sessionReceipt
    :: (Monad m) => Capabilities w m -> Session w n -> m Value
sessionReceipt capabilities session = do
    facts <- capFacts capabilities
    trace <- capTrace capabilities
    let identity@(SessionId label) = sessionId session
        Network magic = sessionNetwork session
        sameScope (Object fields) = KeyMap.lookup "session" fields == Just (String label)
        sameScope _ = False
        binding = case sessionBinding session of
            Unbound -> object ["kind" .= ("Unbound" :: Text)]
            Bound slot header ->
                object
                    [ "kind" .= ("Bound" :: Text)
                    , "slot" .= slot
                    , "headerHash" .= decodeUtf8 (B16.encode header)
                    ]
    pure $
        object
            [ "session" .= label
            , "networkMagic" .= magic
            , "binding" .= binding
            , "facts" .= toJSON (filter ((== identity) . factSession) facts)
            , "rawSources" .= filter sameScope trace
            ]
