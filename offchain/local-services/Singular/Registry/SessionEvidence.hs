{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RankNTypes #-}

{- | Observe the facts a consumer actually reads, including refusals and
history continuations. The verifier and sink run in the caller's monad;
pure State uses the same instrumentation as a terminal receipt.
-}
module Singular.Registry.SessionEvidence
    ( FactRecord (..)
    , observeProvider
    , observeSession
    ) where

import Cardano.Ledger.Binary (serialize')
import Cardano.Ledger.Core (eraProtVerHigh)
import Data.Aeson (ToJSON (..), Value, object, (.=))
import Data.ByteString (ByteString)
import Data.ByteString.Base16 qualified as B16
import Data.List.NonEmpty qualified as NE
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding (decodeUtf8)
import Singular.Registry.Evidence
    ( Evidenced (..)
    , Reason (..)
    , SessionBinding (..)
    , SessionId (..)
    , Verdict (..)
    , Verifier (..)
    )
import Singular.Registry.Ledger (ConwayEra)
import Singular.Registry.LedgerProvider
import Singular.Registry.NetworkTime
    ( networkMagic
    , networkSystemStart
    )

-- | One actual capability result and the policy's verdict, at its own scope.
data FactRecord = FactRecord
    { factSession :: SessionId
    , factNetwork :: Network
    , factBinding :: SessionBinding
    , factQuery :: Text
    , factValue :: Value
    , factVerdict :: Text
    , factReason :: Maybe Text
    , factWitnessPresent :: Bool
    }
    deriving stock (Eq, Show)

instance ToJSON FactRecord where
    toJSON record =
        object
            [ "session" .= let SessionId identity = factSession record in identity
            , "networkMagic" .= let Network magic = factNetwork record in magic
            , "binding" .= bindingJson (factBinding record)
            , "query" .= factQuery record
            , "value" .= factValue record
            , "verdict" .= factVerdict record
            , "reason" .= factReason record
            , "witnessPresent" .= factWitnessPresent record
            ]

bindingJson :: SessionBinding -> Value
bindingJson = \case
    Unbound -> object ["kind" .= ("Unbound" :: Text)]
    Bound slot header ->
        object
            [ "kind" .= ("Bound" :: Text)
            , "slot" .= slot
            , "headerHash" .= hex header
            ]

hex :: ByteString -> Text
hex = decodeUtf8 . B16.encode

outputsJson :: Outputs -> Value
outputsJson pairs =
    toJSON
        [ object
            [ "reference" .= show reference
            , "outputCbor" .= hex (serialize' (eraProtVerHigh @ConwayEra) output)
            ]
        | (reference, output) <- pairs
        ]

blockJson :: HistoryBlock -> Value
blockJson block =
    object
        [ "height" .= blockHeight block
        , "transactions"
            .= [ object
                    [ "id" .= show (historicalId transaction)
                    , "cbor" .= hex (historicalCbor transaction)
                    , "spentOutputs" .= outputsJson (spentOutputs transaction)
                    , "referenceOutputs" .= outputsJson (referenceOutputs transaction)
                    , "createdOutputs" .= outputsJson (createdOutputs transaction)
                    , "scriptValid" .= scriptValid transaction
                    ]
               | transaction <- NE.toList (blockTransactions block)
               ]
        ]

-- | Instrument acquisition's actual session without changing submission.
observeProvider
    :: (Monad m)
    => Verifier w m
    -> (FactRecord -> m ())
    -> LedgerProvider w m
    -> LedgerProvider w m
observeProvider verifier sink provider =
    provider
        { acquire = \request action ->
            acquire
                provider
                request
                (action . observeSession verifier sink)
        }

-- | All raw reads, including every deferred block, retain their exact result.
observeSession
    :: (Monad m)
    => Verifier w m -> (FactRecord -> m ()) -> Session w m -> Session w m
observeSession verifier sink session =
    session
        { outputs = \query ->
            observed (Text.pack (show query)) outputsJson (outputs session query)
        , protocolParameters =
            observed "Protocol parameters" toJSON (protocolParameters session)
        , tipObservation =
            observed "Latest block observation" tipJson (tipObservation session)
        , networkTime =
            observed
                "Validated pinned time context"
                timeJson
                (networkTime session)
        , scriptRegistered = \script ->
            observed
                ("Script credential registration: " <> Text.pack (show script))
                toJSON
                (scriptRegistered session script)
        , history = \asset range -> do
            result <- history session asset range
            case result of
                Left failure -> refused (historyQuery asset range) failure >> pure result
                Right stream -> pure (Right (observedStream (historyQuery asset range) stream))
        }
  where
    base =
        FactRecord
            (sessionId session)
            (sessionNetwork session)
            (sessionBinding session)
    refused query failure =
        sink
            ( base
                query
                (object ["refusal" .= show failure])
                "Refused"
                Nothing
                False
            )
    observed query encodeFact action =
        action >>= \case
            Left failure -> refused query failure >> pure (Left failure)
            Right fact -> do
                verdict <- verifyFact verifier fact
                let (label, reason) = case verdict of
                        Unverified _ NoVerifierConfigured -> ("Unverified", Just "NoVerifierConfigured")
                    present = case witness fact of Nothing -> False; Just _ -> True
                sink (base query (encodeFact (value fact)) label reason present)
                pure (Right fact)
    observedStream query stream =
        HistoryStream $
            nextBlock stream >>= \case
                Left failure -> refused query failure >> pure (Left failure)
                Right Nothing -> do
                    observedEnd <-
                        observed
                            query
                            (const (object ["endOfHistory" .= True]))
                            (pure (Right (Evidenced () Nothing)))
                    pure (Nothing <$ observedEnd)
                Right (Just (block, rest)) -> do
                    -- History carries reconstruction material rather than an optional
                    -- ledger witness. Its verdict is obtained through the same policy.
                    voidRecord <-
                        observed query blockJson (pure (Right (Evidenced block Nothing)))
                    case voidRecord of
                        Left failure -> pure (Left failure)
                        Right _ -> pure (Right (Just (block, observedStream query rest)))
    historyQuery asset range = "Asset history: " <> Text.pack (show (asset, range))
    tipJson tip =
        object
            [ "slot" .= observedSlot tip
            , "headerHash" .= hex (observedHash tip)
            , "height" .= observedHeight tip
            , "blockTimeSeconds" .= observedBlockTime tip
            ]
    timeJson time =
        object
            [ "networkMagic" .= networkMagic time
            , "systemStart" .= show (networkSystemStart time)
            , "source"
                .= ("exact raw time source retained with this session" :: Text)
            ]
