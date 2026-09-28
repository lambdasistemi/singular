{- |
Module      : InsertActive.Observation
Description : The JSON @--observed@ writes, built from executed results
License     : Apache-2.0

'observation' assembles the document a CI step asserts instead of an
exit code. Every value in it is read back from the chain, the
transactions or the blueprint by the steps and controls that produced
it; nothing is a literal written here to make an assertion pass. The
requested address and the wallet address are the same destination the
booking named, read from 'walletDestination'.
-}
module InsertActive.Observation
    ( Observed (..)
    , observation
    , writeObservation
    ) where

import Data.Aeson (Value, object, (.=))
import Data.Aeson.Encode.Pretty (encodePretty)
import Data.ByteString.Lazy qualified as BL
import Data.Text qualified as T

import InsertActive.Controls (controlKey, refusalTrace)
import InsertActive.Narration (hex, say)
import InsertActive.Steps (storyKey, walletDestination)

-- | What one run executed and read back.
data Observed = Observed
    { obsOpenPolicy :: T.Text
    , obsOpenParams :: Int
    , obsActivePolicy :: T.Text
    , obsRegistryToken :: T.Text
    , obsMaxFee :: Integer
    , obsFoldTxid :: T.Text
    , obsHeld :: Integer
    -- ^ Active tokens for the story's key at the requested wallet
    , obsDuplicateRefusal :: String
    -- ^ The ledger's text for the refused duplicate
    , obsControlTxid :: T.Text
    }

-- | The observation document.
observation :: Observed -> Value
observation o =
    object
        [ "edge" .= ("insertActive" :: T.Text)
        , "key" .= hex storyKey
        , "open"
            .= object
                [ "policy" .= obsOpenPolicy o
                , "parameters" .= obsOpenParams o
                ]
        , "active" .= object ["policy" .= obsActivePolicy o]
        , "registry"
            .= object
                [ "token" .= obsRegistryToken o
                , "maxFee" .= obsMaxFee o
                ]
        , "requested"
            .= object ["address" .= hex (fst walletDestination)]
        , "fold" .= object ["txid" .= obsFoldTxid o]
        , "wallet"
            .= object
                [ "address" .= hex (fst walletDestination)
                , "assets"
                    .= [ object
                            [ "policy" .= obsActivePolicy o
                            , "name" .= hex storyKey
                            , "quantity" .= obsHeld o
                            ]
                       ]
                ]
        , "key-exists"
            .= object
                [ "outcome" .= ("refused" :: T.Text)
                , -- The ledger's EvalFailure carries an EMPTY Plutus
                  -- log list, so the cage's trace is usually not
                  -- recoverable. `null` rather than a guess; the
                  -- NAME is asserted at the Aiken layer.
                  "trace" .= refusalTrace (obsDuplicateRefusal o)
                , "detail" .= T.pack (take 2000 (obsDuplicateRefusal o))
                , -- The control belongs to the refusal it controls:
                  -- a FRESH key through the SAME builder, folded in
                  -- the same run. Without it, "refused" is
                  -- consistent with "this command cannot fold at
                  -- all".
                  "control"
                    .= object
                        [ "key" .= hex controlKey
                        , "outcome" .= ("accepted" :: T.Text)
                        , "txid" .= obsControlTxid o
                        ]
                ]
        ]

-- | Write the observation when @--observed@ named a path.
writeObservation :: Maybe FilePath -> Value -> IO ()
writeObservation observedPath doc = case observedPath of
    Nothing -> pure ()
    Just p -> do
        BL.writeFile p (encodePretty doc)
        say ("observation written to " <> p)
