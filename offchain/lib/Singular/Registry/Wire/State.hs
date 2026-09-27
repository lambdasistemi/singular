{- |
Module      : Singular.Registry.Wire.State
Description : Token state, policy accessors, and the cage datum
License     : Apache-2.0

What the cage holds: the eight-field token state with its codec and
policy-byte accessors, and the cage datum — a pending request, a
state, or the refund-only custody of an absent token. Reads
"Singular.Registry.Wire.Primitive" and
"Singular.Registry.Wire.Request"; nothing here is importable by a
caller — the public surface is the "Singular.Registry.Types" facade.
-}
module Singular.Registry.Wire.State (
    -- * On-chain token state
    OnChainTokenState (..),
    stateActivePolicyBytes,
    stateAppPolicyBytes,
    stateAbsentPolicyBytes,
    stateTerminalPolicyBytes,

    -- * Cage datum
    CageDatum (..),
) where

import Data.ByteString (ByteString)
import PlutusCore.Data (Data (..))
import PlutusTx.Builtins.Internal (
    BuiltinByteString (..),
 )
import PlutusTx.IsData.Class (
    FromData (..),
    ToData (..),
    UnsafeFromData (..),
 )
import Singular.Registry.Wire.Primitive (
    OnChainRoot (..),
    bbsFromD,
    bbsToD,
    bsFromD,
    bsToD,
    mkD,
    unD,
 )
import Singular.Registry.Wire.Request (
    OnChainRequest (..),
 )

{- | On-chain token state. Matches Aiken @types\/State@ (#157 C7: eight
fields, replacing the six). `consumer_pin` is deleted with the pinned
consumer; `representative_policy` is renamed `active_policy`; the
application, absent and terminal policies are new. All four policies are
set at genesis and preserved by every `Modify`.
-}
data OnChainTokenState = OnChainTokenState
    { stateRoot :: !OnChainRoot
    -- ^ Current Merkle root of the token's trie
    , stateMaxFee :: !Integer
    -- ^ Oracle tip (lovelace) charged per request
    , stateProcessTime :: !Integer
    -- ^ Oracle processing window duration (ms)
    , stateRetractTime :: !Integer
    -- ^ Requester retract window duration (ms)
    , stateAppPolicy :: !BuiltinByteString
    {- ^ The application policy that certifies requests (#157 C4): a
    request whose operation changes the trie is folded only if its
    UTxO carries one asset under this policy whose name is the
    request's approval binding.
    -}
    , stateActivePolicy :: !BuiltinByteString
    {- ^ The policy that mints the ACTIVE token (renamed from the
    representative policy). Under it the asset name is the registry
    key itself (#157 D-ASSET).
    -}
    , stateAbsentPolicy :: !BuiltinByteString
    {- ^ The policy that mints the ABSENT token, held in the cage's own
    custody beside the inserter's refund address.
    -}
    , stateTerminalPolicy :: !BuiltinByteString
    {- ^ The policy that mints the TERMINAL token: a name is over,
    forever.
    -}
    }
    deriving stock (Show, Eq)

{- | The active-token policy as plain bytes (issue #77 E-001, renamed by
#157 C7): unwraps the `BuiltinByteString` for hex comparison in
verifiers. Named for the field it reads — no alias of the
representative policy survives.
-}
stateActivePolicyBytes :: OnChainTokenState -> ByteString
stateActivePolicyBytes st = case stateActivePolicy st of
    BuiltinByteString bs -> bs

-- | The application policy as plain bytes (#157 C4).
stateAppPolicyBytes :: OnChainTokenState -> ByteString
stateAppPolicyBytes st = case stateAppPolicy st of
    BuiltinByteString bs -> bs

-- | The absent-token policy as plain bytes (#157 C5).
stateAbsentPolicyBytes :: OnChainTokenState -> ByteString
stateAbsentPolicyBytes st = case stateAbsentPolicy st of
    BuiltinByteString bs -> bs

-- | The terminal-token policy as plain bytes (#157 C5).
stateTerminalPolicyBytes :: OnChainTokenState -> ByteString
stateTerminalPolicyBytes st = case stateTerminalPolicy st of
    BuiltinByteString bs -> bs

{- | Cage datum: either a pending request or a token
state. Matches Aiken @types\/CageDatum@.
-}
data CageDatum
    = -- | A pending operation request (Constr 0)
      RequestDatum !OnChainRequest
    | -- | Current token state (Constr 1)
      StateDatum !OnChainTokenState
    | {- | The cage's own custody of an absent token (Constr 2, #157
      D-CUSTODY; appended, so 0 and 1 never move): the address the
      inserter named for the refund. The registry key is the sole
      non-ADA asset carried by the output.
      -}
      AbsentCustody !ByteString
    deriving stock (Show, Eq)

-- ---------------------------------------------------------
-- ToData / FromData instances
-- ---------------------------------------------------------

instance ToData OnChainTokenState where
    toBuiltinData OnChainTokenState{..} =
        mkD $
            Constr
                0
                [ unD (toBuiltinData stateRoot)
                , I stateMaxFee
                , I stateProcessTime
                , I stateRetractTime
                , bbsToD stateAppPolicy
                , bbsToD stateActivePolicy
                , bbsToD stateAbsentPolicy
                , bbsToD stateTerminalPolicy
                ]

instance FromData OnChainTokenState where
    fromBuiltinData bd = case unD bd of
        Constr 0 [r, I mf, I pt, I rt, ap, cp, bp, tp] -> do
            stateRoot <- fromBuiltinData (mkD r)
            stateAppPolicy <- bbsFromD ap
            stateActivePolicy <- bbsFromD cp
            stateAbsentPolicy <- bbsFromD bp
            stateTerminalPolicy <- bbsFromD tp
            let stateMaxFee = mf
                stateProcessTime = pt
                stateRetractTime = rt
            Just OnChainTokenState{..}
        _ -> Nothing

instance UnsafeFromData OnChainTokenState where
    unsafeFromBuiltinData bd = case unD bd of
        Constr 0 [r, I mf, I pt, I rt, ap, cp, bp, tp] ->
            case (bbsFromD ap, bbsFromD cp, bbsFromD bp, bbsFromD tp) of
                (Just appP, Just activeP, Just absentP, Just terminalP) ->
                    OnChainTokenState
                        { stateRoot =
                            unsafeFromBuiltinData (mkD r)
                        , stateMaxFee = mf
                        , stateProcessTime = pt
                        , stateRetractTime = rt
                        , stateAppPolicy = appP
                        , stateActivePolicy = activeP
                        , stateAbsentPolicy = absentP
                        , stateTerminalPolicy = terminalP
                        }
                _ ->
                    error
                        "unsafeFromBuiltinData:\
                        \ OnChainTokenState.policies"
        _ ->
            error
                "unsafeFromBuiltinData:\
                \ OnChainTokenState"

instance ToData CageDatum where
    toBuiltinData (RequestDatum r) =
        mkD $
            Constr 0 [unD (toBuiltinData r)]
    toBuiltinData (StateDatum s) =
        mkD $
            Constr 1 [unD (toBuiltinData s)]
    toBuiltinData (AbsentCustody refund) =
        mkD $
            Constr 2 [bsToD refund]

instance FromData CageDatum where
    fromBuiltinData bd = case unD bd of
        Constr 0 [d] ->
            RequestDatum
                <$> fromBuiltinData (mkD d)
        Constr 1 [d] ->
            StateDatum
                <$> fromBuiltinData (mkD d)
        Constr 2 [refund] ->
            AbsentCustody <$> bsFromD refund
        _ -> Nothing

instance UnsafeFromData CageDatum where
    unsafeFromBuiltinData bd = case unD bd of
        Constr 0 [d] ->
            RequestDatum $
                unsafeFromBuiltinData (mkD d)
        Constr 1 [d] ->
            StateDatum $
                unsafeFromBuiltinData (mkD d)
        Constr 2 [B refund] -> AbsentCustody refund
        _ -> error "unsafeFromBuiltinData: CageDatum"
