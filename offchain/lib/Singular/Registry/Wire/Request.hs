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
    , OnChainRegistrationRequest (..)
    , OnChainTerminationRequest (..)
    , RequestDestination
    , registrationRefundBytes

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

{- | On-chain registration request: the datum a booked registration carries
at the request address. Matches Aiken @types/RegistrationRequest@, field for
field. The delivered datum is carried but neither tag name commits to it.
-}
data OnChainRegistrationRequest = OnChainRegistrationRequest
    { regRegistry :: !OnChainTokenId
    -- ^ The registry this request is for, by its state token name
    , regKey :: !ByteString
    -- ^ The registry key being registered
    , regRefundAddress :: !BuiltinByteString
    -- ^ Payment key hash that may retract and is refunded (28 bytes)
    , regDestination :: !ByteString
    -- ^ Binary address bytes of the output that will receive the token
    , regDatum :: !(Maybe Data)
    -- ^ The datum the delivered output must carry, or none
    , regSubmittedAt :: !Integer
    -- ^ The booked time: the upper end of the booking's validity interval
    , regRegistrationCost :: !Integer
    -- ^ The registration cost, equal to the registry's pin
    , regDeclaredTip :: !Integer
    -- ^ The declared tip, at least the registry's minimum tip
    , regCarrierAda :: !Integer
    -- ^ The declared carrier lovelace
    , regNonce :: !Integer
    -- ^ The one nonce both tags commit to
    }
    deriving stock (Show, Eq)

{- | On-chain termination request: the datum a booked termination carries at
the request address. Matches Aiken @types/TerminationRequest@, field for
field. It has no refund address, clock, delivered datum, registration cost
or application tag: the model admits none. The held assets and the output
reference come from the transaction, never from this datum.

Constructor 0 of six fields, in the order of the on-chain type: the registry
token, the key, the destination, the declared tip, the declared carrier
lovelace and the nonce.
-}
data OnChainTerminationRequest = OnChainTerminationRequest
    { termRegistry :: !OnChainTokenId
    -- ^ The registry this request is for, by its state token name
    , termKey :: !ByteString
    -- ^ The registry key being terminated
    , termDestination :: !ByteString
    -- ^ The model's destination 0: empty bytes
    , termDeclaredTip :: !Integer
    -- ^ The declared tip, at least the registry's minimum tip
    , termCarrierAda :: !Integer
    -- ^ The declared carrier lovelace: the held value less the tip
    , termNonce :: !Integer
    -- ^ The nonce the trie-ready tag commits to
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

instance ToData OnChainRegistrationRequest where
    toBuiltinData OnChainRegistrationRequest{..} =
        mkD $
            Constr
                0
                [ unD (toBuiltinData regRegistry)
                , bsToD regKey
                , bbsToD regRefundAddress
                , bsToD regDestination
                , maybe (Constr 1 []) (Constr 0 . pure) regDatum
                , I regSubmittedAt
                , I regRegistrationCost
                , I regDeclaredTip
                , I regCarrierAda
                , I regNonce
                ]

instance FromData OnChainRegistrationRequest where
    fromBuiltinData bd = case unD bd of
        Constr
            0
            [ reg
                , k
                , refund
                , dest
                , carried
                , I sub
                , I cost
                , I tip
                , I carrier
                , I nonce
                ] -> do
                regRegistry <- fromBuiltinData (mkD reg)
                regKey <- bsFromD k
                regRefundAddress <- bbsFromD refund
                regDestination <- bsFromD dest
                regDatum <- carriedDatum carried
                let regSubmittedAt = sub
                    regRegistrationCost = cost
                    regDeclaredTip = tip
                    regCarrierAda = carrier
                    regNonce = nonce
                Just OnChainRegistrationRequest{..}
        _ -> Nothing

instance UnsafeFromData OnChainRegistrationRequest where
    unsafeFromBuiltinData bd = case unD bd of
        Constr
            0
            [ reg
                , B k
                , B refund
                , B dest
                , carried
                , I sub
                , I cost
                , I tip
                , I carrier
                , I nonce
                ]
                | Just datum <- carriedDatum carried ->
                    OnChainRegistrationRequest
                        { regRegistry = unsafeFromBuiltinData (mkD reg)
                        , regKey = k
                        , regRefundAddress = BuiltinByteString refund
                        , regDestination = dest
                        , regDatum = datum
                        , regSubmittedAt = sub
                        , regRegistrationCost = cost
                        , regDeclaredTip = tip
                        , regCarrierAda = carrier
                        , regNonce = nonce
                        }
        _ ->
            error
                "unsafeFromBuiltinData: OnChainRegistrationRequest"

-- ---------------------------------------------------------
-- The termination request codec
-- ---------------------------------------------------------

instance ToData OnChainTerminationRequest where
    toBuiltinData OnChainTerminationRequest{..} =
        mkD $
            Constr
                0
                [ unD (toBuiltinData termRegistry)
                , bsToD termKey
                , bsToD termDestination
                , I termDeclaredTip
                , I termCarrierAda
                , I termNonce
                ]

instance FromData OnChainTerminationRequest where
    fromBuiltinData bd = case unD bd of
        Constr 0 [reg, k, dest, I tip, I carrier, I nonce] -> do
            termRegistry <- fromBuiltinData (mkD reg)
            termKey <- bsFromD k
            termDestination <- bsFromD dest
            let termDeclaredTip = tip
                termCarrierAda = carrier
                termNonce = nonce
            Just OnChainTerminationRequest{..}
        _ -> Nothing

instance UnsafeFromData OnChainTerminationRequest where
    unsafeFromBuiltinData bd = case unD bd of
        Constr 0 [reg, B k, B dest, I tip, I carrier, I nonce] ->
            OnChainTerminationRequest
                { termRegistry = unsafeFromBuiltinData (mkD reg)
                , termKey = k
                , termDestination = dest
                , termDeclaredTip = tip
                , termCarrierAda = carrier
                , termNonce = nonce
                }
        _ -> error "unsafeFromBuiltinData: OnChainTerminationRequest"

-- | The payment key hash a registration's refund address names, as plain bytes.
registrationRefundBytes :: OnChainRegistrationRequest -> ByteString
registrationRefundBytes r = case regRefundAddress r of
    BuiltinByteString bytes -> bytes
