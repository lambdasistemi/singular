{- |
Module      : Singular.Registry.TxBuilder.Update.Context
Description : Fold context preparation — queries, proofs, state and slot
License     : Apache-2.0

Everything a fold must know or prepare before it can decide anything:
the registry context a caller hands in (and its empty value), the
state/request/fee queries that find the fold's inputs, the ordered
speculative proofs through the trie, the state continuation output and
its script, the validity upper slot, and the completion of a partly
empty context from the provider.

This module owns no duty decisions and no transaction assembly; see
"Singular.Registry.TxBuilder.Update.Duties" and
"Singular.Registry.TxBuilder.Update.Build". The public surface stays
"Singular.Registry.TxBuilder.Update", which re-exports the context
types unchanged (#267).
-}
module Singular.Registry.TxBuilder.Update.Context
    ( RegistryContext (..)
    , HolderRelease (..)
    , emptyRegistryContext
    , completeContext
    , queryContext
    , computeProofs
    , prepareState
    , computeUpperSlot
    ) where

import Control.Monad (when)
import Data.ByteString (ByteString)
import Data.List (sortOn)
import Data.Map.Strict qualified as Map
import Data.Ord (Down (..))
import Data.Time.Clock (getCurrentTime)
import Data.Time.Clock.POSIX
    ( utcTimeToPOSIXSeconds
    )
import Lens.Micro ((&), (.~), (^.))
import PlutusCore.Data qualified as PLC

import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.Api.Tx.Out
    ( TxOut
    , coinTxOutL
    , datumTxOutL
    , mkBasicTxOut
    , referenceScriptTxOutL
    , valueTxOutL
    )
import Cardano.Ledger.BaseTypes (StrictMaybe (..))
import Cardano.Ledger.Core (Script)
import Cardano.Ledger.Mary.Value (MaryValue (..), MultiAsset (..))
import Cardano.Slotting.Slot (SlotNo)

import Singular.Registry.Config
    ( CageConfig (..)
    )
import Singular.Registry.Ledger
    ( ConwayEra
    , PParams
    , Root (..)
    , TokenId
    , TxIn
    )
import Singular.Registry.Provider
    ( Provider (..)
    )
import Singular.Registry.Trie
    ( Trie (..)
    , TrieManager (..)
    )
import Singular.Registry.TxBuilder.Internal.Edges
import Singular.Registry.TxBuilder.Internal.Identity
import Singular.Registry.TxBuilder.Internal.Lookup
import Singular.Registry.Types
    ( CageDatum (..)
    , OnChainRequest (..)
    , OnChainRoot (..)
    , OnChainTokenState (..)
    , ProofStep
    )

{- | What a fold needs in hand to discharge the obligations: the three
token policies' scripts by kind, the cage script (custody spends run it),
the UTxOs sitting at the cage address (custody lives among them), and the
preimages of any destination datum the bookings named — the request
carries only the hash, and the output has to carry the datum itself.
-}
data RegistryContext = RegistryContext
    { rcWitnessScripts :: Map.Map Integer (Script ConwayEra)
    , rcCageScript :: Maybe (Script ConwayEra)
    , rcCageUtxos :: [(TxIn, TxOut ConwayEra)]
    , rcDatums :: [(ByteString, PLC.Data)]
    , rcAllowInadmissible :: Bool
    {- ^ Build a fold even when a request takes no admissible edge, so a
    row that exists to watch the chain REFUSE one can produce the
    transaction it submits. An honest builder leaves this off and
    fails early, naming the request.
    -}
    , rcHolderUtxos :: [(TxIn, TxOut ConwayEra)]
    {- ^ #177 I177-BUILDER: the candidate inputs a burn may be sourced
    from — the outputs that actually HOLD registry witnesses. A
    retirement or an active deletion destroys an asset it does not
    create, so the fold has to consume the holder's own UTxO; with
    nothing in this
    inventory the builder fails naming the key rather than emitting a
    mint the cage refuses `token-missing`. Left empty, the builder
    queries the fold's own wallet address.
    -}
    , rcHolderReleases :: Map.Map TxIn HolderRelease
    {- ^ #299: holders that sit at an application script rather than a
    key. A burn sourced from one of them spends it with the application's
    own witness instead of as a plain input, and the application's
    release is owed to its recipient together with every other
    obligation of the fold to that key. Empty for key-held witnesses.
    -}
    , rcRefUtxos :: [(TxIn, TxOut ConwayEra)]
    {- ^ Outputs carrying the fold's scripts as reference scripts. The
    state validator alone is fifteen kilobytes, so a fold that
    attaches it, the request script and a token policy does not fit
    in a transaction; with references every purpose resolves through
    them instead.
    -}
    }

{- | How an application-held burn source is spent, and what its spend
releases (#299): the redeemer and script that witness the spend, and the
lovelace owed to the recipient's key because the holder is released.
-}
data HolderRelease = HolderRelease
    { hrRedeemer :: PLC.Data
    , hrScript :: Script ConwayEra
    , hrRecipient :: ByteString
    -- ^ The payment key hash the release is owed to
    , hrReleased :: Integer
    -- ^ Lovelace owed to it, over every other obligation to that key
    }
    deriving stock (Eq, Show)

{- | The context a fold of tree edges needs beyond the registry's own
configuration: the three token policies' scripts, the cage script that
custody spends run, and the preimages of the destination datums the
bookings named.

`emptyRegistryContext` carries none of it, which is right for a caller
that folds only rejections — and refuses loudly, naming the missing
script, for one that folds an edge without it.
-}
emptyRegistryContext :: RegistryContext
emptyRegistryContext =
    RegistryContext
        { rcWitnessScripts = Map.empty
        , rcCageScript = Nothing
        , rcCageUtxos = []
        , rcDatums = []
        , rcAllowInadmissible = False
        , rcHolderUtxos = []
        , rcHolderReleases = Map.empty
        , rcRefUtxos = []
        }

{- | Complete a context the caller left partly empty: the cage's own
UTxOs and the fold's holder inventory are queried from the provider
when the caller did not supply them, and the cage script defaults to
the one this build's own state continuation runs. The caller-supplied
value always wins; only an omission triggers a query (#267: moved
verbatim from the facade's inline completion).
-}
completeContext
    :: CageConfig
    -> Provider IO
    -> Addr
    -> Script ConwayEra
    -> RegistryContext
    -> IO RegistryContext
completeContext cfg prov addr script ctx0 = do
    -- The cage's own UTxOs are where custody sits; the caller need not
    -- have queried them, and the cage script is this build's own.
    cageUtxos <-
        if null (rcCageUtxos ctx0)
            then queryUTxOs prov (cageAddrFromCfg cfg (network cfg))
            else pure (rcCageUtxos ctx0)
    -- #177 I177-BUILDER: the candidate burn sources. A retirement or a
    -- deletion of an active key destroys an asset it does not create,
    -- so the fold has to consume the UTxO that HOLDS it; left unset,
    -- the inventory is the fold's own wallet, which is where
    -- `insertActive` delivered it.
    holderUtxos <-
        if null (rcHolderUtxos ctx0)
            then queryUTxOs prov addr
            else pure (rcHolderUtxos ctx0)
    pure
        ctx0
            { rcCageUtxos = cageUtxos
            , rcHolderUtxos = holderUtxos
            , rcCageScript = case rcCageScript ctx0 of
                Just s -> Just s
                Nothing -> Just script
            }

{- | Query cage UTxOs, find the state and request
UTxOs, pick a fee-paying wallet UTxO.
-}
queryContext
    :: CageConfig
    -> Provider IO
    -> TokenId
    -> Addr
    -> IO
        ( (TxIn, TxOut ConwayEra)
        , [(TxIn, TxOut ConwayEra)]
        , (TxIn, TxOut ConwayEra)
        , PParams ConwayEra
        )
queryContext cfg prov tid addr = do
    let stateAddr =
            cageAddrFromCfg cfg (network cfg)
        reqAddr =
            requestAddrFromCfg cfg tid (network cfg)
    stateUtxos <- queryUTxOs prov stateAddr
    requestUtxos <- queryUTxOs prov reqAddr
    let policyId = cagePolicyIdFromCfg cfg
    stateUtxo <- case findStateUtxo
        policyId
        tid
        stateUtxos of
        Nothing ->
            error
                "updateToken: state UTxO \
                \not found"
        Just x -> pure x
    let reqUtxos =
            sortOn fst $
                findRequestUtxos tid requestUtxos
    when (null reqUtxos) $
        error "updateToken: no pending requests"
    pp <- queryProtocolParams prov
    walletUtxos <- queryUTxOs prov addr
    -- #157: an approval is not burned at the fold, so it returns to the
    -- funder and rides in the wallet from then on. The fee input doubles
    -- as collateral, and collateral must be ada-only.
    feeUtxo <- case sortOn
        (Down . (^. coinTxOutL) . snd)
        (filter (adaOnlyOutput . snd) walletUtxos) of
        [] -> error "updateToken: no ada-only UTxO to fund the fold"
        (u : _) -> pure u
    pure (stateUtxo, reqUtxos, feeUtxo, pp)

{- | Run speculative trie operations to compute
proofs and the new root hash.
-}
computeProofs
    :: TrieManager IO
    -> TokenId
    -> [(TxIn, TxOut ConwayEra)]
    -> IO ([[ProofStep]], Root)
computeProofs tm tid reqUtxos =
    withSpeculativeTrie tm tid $ \trie -> do
        ps <- mapM (processRequest trie) reqUtxos
        r <- getRoot trie
        pure (ps, r)

{- | Extract old state, build new state output,
cage script, and owner key hash.
-}
prepareState
    :: CageConfig
    -> TxOut ConwayEra
    -> Root
    -> (OnChainTokenState, TxOut ConwayEra, Script ConwayEra)
prepareState cfg stateOut newRoot =
    let scriptAddr =
            cageAddrFromCfg cfg (network cfg)
        oldState =
            case extractCageDatum stateOut of
                Just (StateDatum s) -> s
                _ ->
                    error
                        "updateToken: invalid \
                        \state datum"
        newStateDatum =
            StateDatum
                oldState
                    { stateRoot =
                        OnChainRoot
                            (unRoot newRoot)
                    }
        newStateOut =
            mkBasicTxOut
                scriptAddr
                (stateOut ^. valueTxOutL)
                & datumTxOutL
                    .~ mkInlineDatum
                        (toPlcData newStateDatum)
        script = mkCageScript cfg
    in  (oldState, newStateOut, script)

-- | Compute the validity upper slot.
computeUpperSlot
    :: Provider IO
    -> OnChainTokenState
    -> [(TxIn, TxOut ConwayEra)]
    -> IO SlotNo
computeUpperSlot prov oldState reqUtxos = do
    let extractSubmittedAt (_, rOut) =
            case extractCageDatum rOut of
                Just (RequestDatum r) ->
                    requestSubmittedAt r
                _ -> 0
        earliestDeadline =
            minimum $
                map
                    ( \u ->
                        extractSubmittedAt u
                            + stateProcessTime
                                oldState
                    )
                    reqUtxos
    mUpperSlot <- trySync (posixMsToSlot prov earliestDeadline)
    case mUpperSlot of
        Right s -> pure s
        Left _ -> do
            nowUtc <- getCurrentTime
            let posixSec =
                    utcTimeToPOSIXSeconds nowUtc
            tryUpperSlots prov $
                map
                    ( \d ->
                        round
                            ((posixSec + d) * 1000)
                    )
                    [30, 5, 2]

-- | Process a single request.
processRequest
    :: (Monad m)
    => Trie m
    -> (TxIn, TxOut ConwayEra)
    -> m [ProofStep]
processRequest trie (_txIn, txOut) =
    walkEdge trie (requestKey req) (requestEdge req)
  where
    req = case extractCageDatum txOut of
        Just (RequestDatum r) -> r
        _ ->
            error
                "processRequest: \
                \invalid request datum"

{- | Can this output fund a fold? It must hold ada and nothing else,
because it doubles as collateral, and it must not be one of the published
reference outputs, because a transaction may not both spend an output and
reference it.
-}
adaOnlyOutput :: TxOut ConwayEra -> Bool
adaOnlyOutput out =
    (case out ^. valueTxOutL of MaryValue _ (MultiAsset m) -> Map.null m)
        && ( case out ^. referenceScriptTxOutL of
                SNothing -> True
                SJust _ -> False
           )
