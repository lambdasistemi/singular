{- | Optional harness evidence from completed capability operations. The
observations originate in the common engine that computes their values.
-}
module Singular.CLI.TrieTrace (observeTrie) where

import Data.Aeson (encode, object, (.=))
import Data.Aeson.Types (Pair)
import Data.ByteString.Lazy.Char8 qualified as BL
import Data.ByteString.Short qualified as SBS
import Data.Text (Text)
import Singular.CLI.Registry (hexT)
import Singular.Registry.Deployment (renderOutRef)
import Singular.Registry.Ledger (AssetName (..), Root (..))
import Singular.Registry.TrieState
import Singular.Registry.TrieState.Mirror (TrieObservation (..))
import System.Environment (lookupEnv)

observeTrie :: TrieObservation -> IO ()
observeTrie observation = case observation of
    Created chosen -> record "create" chosen []
    Selected chosen -> record "select" chosen []
    LeafRead chosen key leaf ->
        record "leafAt" chosen ["key" .= hexT key, "leaf" .= leafName leaf]
    MemberProved chosen key leaf bytes ->
        record
            "membership"
            chosen
            ["key" .= hexT key, "leaf" .= leafName leaf, "proof" .= hexT bytes]
    AbsenceProved chosen key -> record "nonMembership" chosen ["key" .= hexT key]
    Speculated chosen walked ->
        record
            "speculateEdges"
            chosen
            [ "rootAfter" .= hexT (unRoot (walkRoot walked))
            , "proofCount" .= length (walkProofs walked)
            , "proofs" .= show (walkProofs walked)
            ]
    FoldAccepted _ after ->
        record
            "accept"
            after
            ["rootAfter" .= hexT (unRoot (trieSelectionRoot after))]

record :: Text -> TrieSelection -> [Pair] -> IO ()
record
    operation
    ( TrieSelection
            (RegistryIdentity (StatePolicyId policy) (AssetName name))
            point
            root
        )
    fields = do
        target <- lookupEnv "SINGULAR_HARNESS_TRIE_TRACE"
        case target of
            Nothing -> pure ()
            Just path ->
                BL.appendFile
                    path
                    ( encode
                        ( object
                            ( [ "operation" .= operation
                              , "identity"
                                    .= object ["policy" .= hexT policy, "name" .= hexT (SBS.fromShort name)]
                              , "output" .= renderOutRef (pointOutput point)
                              , "root" .= hexT (unRoot root)
                              ]
                                <> fields
                            )
                        )
                        <> "\n"
                    )
