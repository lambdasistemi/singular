{- |
Module      : Singular.Registry.Wire.Request
Description : Edge vocabulary, request datum, and phase classification
License     : Apache-2.0

What a registry request names and when its age allows acting on it: the
seven-admitted-edges row-index edge vocabulary, the request datum with its codec, and the
accept\/retract\/reject phase classification. Reads only
"Singular.Registry.Wire.Primitive"; nothing here is importable by a
caller — the public surface is the "Singular.Registry.Types" facade.
-}
module Singular.Registry.Wire.Request
    ( -- * On-chain domain types
      Edge
    , edgeInsertAbsent
    , edgeInsertActive
    , edgeUpdateActive
    , edgeUpdateTerminal
    , edgeDeleteAbsent
    , edgeDeleteActive
    , edgeWitnessTerminal
    , edgeName
    , OnChainRequest (..)
    , RequestDestination

      -- * Request phase
    , RequestPhase (..)
    , requestPhase
    ) where

import Cardano.Ledger.BaseTypes (SlotNo (..))
import Data.ByteString (ByteString)
import PlutusCore.Data (Data (..))
import PlutusTx.Builtins.Internal
    ( BuiltinByteString (..)
    )
import PlutusTx.IsData.Class
    ( FromData (..)
    , ToData (..)
    , UnsafeFromData (..)
    )
import Singular.Registry.Wire.Primitive
    ( OnChainTokenId (..)
    , bbsFromD
    , bbsToD
    , bsFromD
    , bsToD
    , mkD
    , unD
    )

{- | The seven-admitted-edges row index a request names (#183, Lean @Request.edge@,
Aiken @lib\/edgeInsertAbsent@ … @edgeWitnessTerminal@).

An edge names its own leaf bytes, so no value bytes travel with a
request and an illegal value-byte shape is not expressible:

@
0  insertAbsent     insert 0x00
1  insertActive     insert 0x01
2  updateActive     update 0x00 -> 0x01
3  updateTerminal   update 0x01 -> 0x02
4  deleteAbsent     delete 0x00
5  deleteActive     delete 0x01
6  witnessTerminal  read   0x02
@

It is a plain 'Integer', exactly as it is a plain @Int@ on chain, so a
tag outside @0..6@ can still be encoded and sent — which is what the
cage's @edge-inadmissible@ refusal is there to answer, and what a row
that exercises that refusal needs to be able to build.
-}
type Edge = Integer

edgeInsertAbsent :: Edge
edgeInsertAbsent = 0

edgeInsertActive :: Edge
edgeInsertActive = 1

edgeUpdateActive :: Edge
edgeUpdateActive = 2

edgeUpdateTerminal :: Edge
edgeUpdateTerminal = 3

edgeDeleteAbsent :: Edge
edgeDeleteAbsent = 4

edgeDeleteActive :: Edge
edgeDeleteActive = 5

edgeWitnessTerminal :: Edge
edgeWitnessTerminal = 6

-- | The name of an admitted edge, for diagnostics and receipts.
edgeName :: Edge -> String
edgeName e = case e of
    0 -> "insertAbsent"
    1 -> "insertActive"
    2 -> "updateActive"
    3 -> "updateTerminal"
    4 -> "deleteAbsent"
    5 -> "deleteActive"
    6 -> "witnessTerminal"
    _ -> "edge-" <> show e

{- | Where a request's minted token goes, and the datum the receiving output
must carry, or none (#419): what the request carries on the chain.
-}
type RequestDestination = (ByteString, Maybe Data)

{- | On-chain request to modify a token's trie.
Matches Aiken @types\/Request@.
-}
data OnChainRequest = OnChainRequest
    { requestToken :: !OnChainTokenId
    -- ^ Token whose trie is being modified
    , requestOwner :: !BuiltinByteString
    -- ^ Payment key hash of the requester (28 bytes)
    , requestKey :: !ByteString
    -- ^ Trie key to operate on
    , requestEdge :: !Edge
    {- ^ The seven-admitted-edges row index this request names (#183). The edge names the
    trie move and its leaf bytes; no value bytes travel here.
    -}
    , requestDeposit :: !Integer
    {- ^ The deposit (lovelace) the request rides with, over and above
    the tip. Must equal the request output's lovelace less
    @state.tip@ at fold time; the fold returns it to the destination.
    -}
    , requestSubmittedAt :: !Integer
    -- ^ POSIX time (ms) when the request was submitted
    , requestDestination :: !RequestDestination
    {- ^ Where this request's minted token goes, and the inline datum the
    receiving output must carry, or none for a datum-less output (#157
    request-destination-binding, appended last; #419: the request carries
    the datum itself, so any party can build the fold from the chain).
    Encoded as a two-element list, exactly as Aiken encodes a tuple, the
    datum as Aiken's @Option@. For edge 0 the address component is the
    refund address.
    -}
    }
    deriving stock (Show, Eq)

-- ---------------------------------------------------------
-- Request phase (A-002): a resuming client's choice of exit
-- ---------------------------------------------------------

{- | The exit a resuming client chooses for one of its pending requests at
a chain tip.

It follows the windows of @onchain/validators/shared.ak@: an update is
folded only while the tip is before @submitted_at + process_time@ (phase
1), and the owner may retract only before @submitted_at + process_time +
retract_time@ (phase 2). After both the client rejects (phase 3). This is
the client's choice, not the validator's rule for a reject: a reject
carries no admission and is accepted in every window (#320).
-}
data RequestPhase = PhaseAccept | PhaseRetract | PhaseReject
    deriving stock (Show, Eq)

{- | Classify a request from its two boundary slots and the live tip.

The boundaries are the slots the builders can express: the accept
fold's validity upper bound is the process deadline slot, the retract's
is the retract deadline slot. The comparison is strict, so a phase is
chosen only while the tip is inside what that phase's builder can
still build — a window already behind the tip never classifies into
the phase that would build it.
-}
requestPhase
    :: SlotNo
    -- ^ Last slot an accept fold can carry (process deadline).
    -> SlotNo
    -- ^ Last slot a retract can carry (retract deadline).
    -> SlotNo
    -- ^ The live tip.
    -> RequestPhase
requestPhase acceptDeadline retractDeadline tip
    | tip < acceptDeadline = PhaseAccept
    | tip < retractDeadline = PhaseRetract
    | otherwise = PhaseReject

-- ---------------------------------------------------------
-- ToData / FromData instances
-- ---------------------------------------------------------

instance ToData OnChainRequest where
    toBuiltinData OnChainRequest{..} =
        mkD $
            Constr
                0
                [ unD (toBuiltinData requestToken)
                , bbsToD requestOwner
                , bsToD requestKey
                , I requestEdge
                , I requestDeposit
                , I requestSubmittedAt
                , List
                    [ bsToD (fst requestDestination)
                    , maybe (Constr 1 []) (Constr 0 . pure) (snd requestDestination)
                    ]
                ]

instance FromData OnChainRequest where
    fromBuiltinData bd = case unD bd of
        Constr
            0
            [tok, own, k, I edge, I dep, I sub, List [da, dd]] -> do
                requestToken <-
                    fromBuiltinData (mkD tok)
                requestOwner <- bbsFromD own
                requestKey <- bsFromD k
                destAddress <- bsFromD da
                destDatum <- carriedDatum dd
                let requestEdge = edge
                    requestDeposit = dep
                    requestSubmittedAt = sub
                    requestDestination = (destAddress, destDatum)
                Just OnChainRequest{..}
        _ -> Nothing

instance UnsafeFromData OnChainRequest where
    unsafeFromBuiltinData bd = case unD bd of
        Constr
            0
            [tok, B own, B k, I edge, I dep, I sub, List [B da, dd]]
                | Just datum <- carriedDatum dd ->
                    OnChainRequest
                        { requestToken =
                            unsafeFromBuiltinData (mkD tok)
                        , requestOwner =
                            BuiltinByteString own
                        , requestKey = k
                        , requestEdge = edge
                        , requestDeposit = dep
                        , requestSubmittedAt = sub
                        , requestDestination = (da, datum)
                        }
        _ ->
            error
                "unsafeFromBuiltinData:\
                \ OnChainRequest"

-- | The datum a request carries, decoded from Aiken's @Option<Data>@.
carriedDatum :: Data -> Maybe (Maybe Data)
carriedDatum option = case option of
    Constr 0 [datum] -> Just (Just datum)
    Constr 1 [] -> Just Nothing
    _ -> Nothing
