{- |
Module      : UpdateTerminal.Observation
Description : The JSON @--observed@ writes, built from executed results
License     : Apache-2.0

'observation' assembles the document a CI step asserts instead of an
exit code. Every value in it is read back from the chain, the
transactions, the committed trie or the blueprint by the steps and
controls that produced it; nothing is a literal written here to make an
assertion pass. Where a refusal's name cannot be recovered from the
ledger's error text the field is @null@ rather than a guess.

The Absent refusal's accepting control is the story's own retirement,
so its @controlTxid@ is the retirement's transaction id.
-}
module UpdateTerminal.Observation
    ( Observed (..)
    , observation
    , writeObservation
    ) where

import Data.Aeson (Value (..), object, (.=))
import Data.Aeson.Encode.Pretty (encodePretty)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as BL
import Data.Text qualified as T

import Singular.Registry.Ledger (Root (..))
import UpdateTerminal.Controls (UnknownLeg (..), refusalTrace)
import UpdateTerminal.Narration (hex, say)
import UpdateTerminal.Registry (txIdOf)
import UpdateTerminal.Steps (Retirement (..), storyKey)

-- | What one run executed and read back.
data Observed = Observed
    { obsOpenPolicy :: T.Text
    , obsWalletAddress :: T.Text
    , obsOpenParams :: Int
    , obsActivePolicy :: T.Text
    , obsRegistryToken :: ByteString
    , obsMaxFee :: Integer
    , obsBoot :: Value
    -- ^ What the story registry's boot transaction carried
    , obsMint :: [Value]
    -- ^ What the retirement moved under the active policy
    , obsRetirement :: Retirement
    , obsAbsentDetail :: String
    , obsUnknown :: UnknownLeg
    }

-- | The observation document.
observation :: Observed -> Value
observation o =
    let r = obsRetirement o
        unknown = obsUnknown o
    in  object
            [ "edge" .= ("updateTerminal" :: T.Text)
            , "open"
                .= object
                    [ "policy" .= obsOpenPolicy o
                    , "parameters" .= obsOpenParams o
                    ]
            , "registry"
                .= object
                    [ "token" .= hex (obsRegistryToken o)
                    , "maxFee" .= obsMaxFee o
                    ]
            , "boot" .= obsBoot o
            , "requested" .= object ["address" .= obsWalletAddress o]
            , "retirement"
                .= object
                    [ "activePolicy" .= obsActivePolicy o
                    , "key" .= hex storyKey
                    , "insertTxid" .= hex (txIdOf (retInsertTx r))
                    , "retireTxid" .= hex (txIdOf (retRetireTx r))
                    , "roots"
                        .= object
                            [ "beforeInsert" .= hex (unRoot (retRootBeforeInsert r))
                            , "active" .= hex (unRoot (retRootActive r))
                            , "terminal" .= hex (unRoot (retRootTerminal r))
                            ]
                    , "quantities"
                        .= object
                            [ "before" .= retHeldBefore r
                            , "after" .= retHeldAfter r
                            ]
                    , -- What the RETIREMENT transaction actually
                      -- moved under the active policy, read off its
                      -- own mint field.
                      "mint" .= obsMint o
                    , -- The input the burn consumed, read off the
                      -- chain before it was spent. A mint of -1
                      -- with no such input is the shape the cage
                      -- refuses `token-missing`.
                      "source" .= retSource r
                    , -- The LEAF, observed where a leaf can be
                      -- observed: `Trie.lookup` answers with the
                      -- key's hash rather than its value, while a
                      -- trie with a different leaf at this key has a
                      -- different root. The chain reached this root
                      -- through the validator's own `mpf.update`
                      -- and the mirror through an independent local
                      -- trie.
                      "leaf"
                        .= if retChainRoot r == unRoot (retRootTerminal r)
                            then String "Terminal"
                            else Null
                    , "unknown"
                        .= object
                            [ "outcome" .= ("refused" :: T.Text)
                            , -- The ledger's EvalFailure carries an
                              -- EMPTY Plutus log list, so the cage's
                              -- trace is usually not recoverable.
                              -- `null` rather than a guess; the NAME
                              -- is asserted at the Aiken layer.
                              "trace" .= refusalTrace "key-unknown" (unknownDetail unknown)
                            , "detail" .= T.pack (take 2000 (unknownDetail unknown))
                            , "controlTxid" .= unknownControlTxid unknown
                            , "distinguisher"
                                .= ( "the control retired a key that IS \
                                     \Active in this same registry; this \
                                     \one was never inserted at all"
                                        :: T.Text
                                   )
                            ]
                    , "absent"
                        .= object
                            [ "outcome" .= ("refused" :: T.Text)
                            , "trace" .= refusalTrace "not-booked" (obsAbsentDetail o)
                            , "detail" .= T.pack (take 2000 (obsAbsentDetail o))
                            , "controlTxid" .= hex (txIdOf (retRetireTx r))
                            , "distinguisher"
                                .= ( "the control retired a key that IS \
                                     \Active in this same registry; this \
                                     \one was witnessed Absent"
                                        :: T.Text
                                   )
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
