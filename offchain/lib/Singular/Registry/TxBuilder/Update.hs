{-# LANGUAGE DataKinds #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE LambdaCase #-}

{- |
Module      : Singular.Registry.TxBuilder.Update
Description : Update token transaction
License     : Apache-2.0

Builds the oracle update transaction that processes
all pending requests for a token. Consumes the State
UTxO and all request UTxOs, applies each operation
speculatively through the trie to generate proofs,
then outputs a new State UTxO with the updated root
and per-request refund outputs.
-}
module Singular.Registry.TxBuilder.Update (
    updateTokenImpl,
    updateTokenWithDuties,
    emptyRegistryContext,
    RegistryDuties (..),
    RegistryContext (..),
    registryDuties,
) where

import Control.Exception (SomeException, try)
import Control.Monad (when)
import Data.List (sortOn)
import Data.Map.Strict qualified as Map
import Data.Ord (Down (..))
import Data.Time.Clock (getCurrentTime)
import Data.Time.Clock.POSIX (
    utcTimeToPOSIXSeconds,
 )
import Data.Void (Void)
import Lens.Micro ((&), (.~), (^.))

import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.Alonzo.Scripts (AsIx)
import Cardano.Ledger.Api.Tx (
    bodyTxL,
 )
import Cardano.Ledger.Api.Tx.Body (
    feeTxBodyL,
 )
import Cardano.Ledger.Api.Tx.Out (
    TxOut,
    coinTxOutL,
    datumTxOutL,
    mkBasicTxOut,
    valueTxOutL,
 )
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Keys (KeyHash)
import Cardano.Tx.Build (Guard)
import Cardano.Ledger.Mary.Value (AssetName (..), MaryValue (..), MultiAsset (..), PolicyID (..))
import Cardano.Ledger.Api.Tx.Out (getMinCoinTxOut, referenceScriptTxOutL)
import Cardano.Ledger.BaseTypes (StrictMaybe (..))
import Cardano.Ledger.Core (hashScript)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Short qualified as SBS
import PlutusCore.Data qualified as PLC
import Singular.Registry.TxBuilder.ConnectedFold (
    ConnectedMint (..),
    ConnectedSpend (..),
    RawRedeemer (..),
 )
import Cardano.Ledger.Conway.Scripts (
    ConwayPlutusPurpose,
 )
import Cardano.Ledger.Core (Script)
import Cardano.Ledger.Plutus.ExUnits (ExUnits)

import Singular.Registry.Config (
    CageConfig (..),
 )
import Singular.Registry.Ledger (
    ConwayEra,
    PParams,
    Root (..),
    TokenId,
    TxIn,
 )
import Singular.Registry.Provider (
    Provider (..),
 )
import Singular.Registry.Trie (
    Trie (..),
    TrieManager (..),
 )
import Singular.Registry.TxBuilder.Internal
import PlutusTx.Builtins.Internal (BuiltinByteString (..))
import Singular.Registry.Types (
    CageDatum (..),
    edgeInsertAbsent,
    edgeWitnessTerminal,
    OnChainRequest (..),
    OnChainRoot (..),
    OnChainTokenState (..),
    ProofStep,
    RequestAction (..),
    UpdateRedeemer (..),
 )
import Cardano.Slotting.Slot (SlotNo)
import Cardano.Tx.Build qualified as Tx
import Cardano.Tx.Ledger (ConwayTx)

-- | Empty query GADT (no context needed).
data NoCtx a

-- | Build an update-token transaction (fair fee).
updateTokenImpl ::
    CageConfig ->
    Provider IO ->
    TrieManager IO ->
    TokenId ->
    Addr ->
    IO ConwayTx
updateTokenImpl cfg prov tm tid addr =
    updateTokenWithDuties cfg prov tm tid addr emptyRegistryContext

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
        , rcRefUtxos = []
        }

{- | Fold the pending requests, discharging every obligation the edges
they take create (#157 C5, C6, T1-T6).
-}
updateTokenWithDuties ::
    CageConfig ->
    Provider IO ->
    TrieManager IO ->
    TokenId ->
    Addr ->
    RegistryContext ->
    IO ConwayTx
updateTokenWithDuties cfg prov tm tid addr ctx0 = do
    (stateUtxo, reqUtxos, feeUtxo, pp) <-
        queryContext cfg prov tid addr
    let (stateIn, stateOut) = stateUtxo
    (proofs, newRoot) <-
        computeProofs tm tid reqUtxos
    let (oldState, newStateOut, script) =
            prepareState
                cfg
                stateOut
                newRoot
        requestScript = mkRequestScript cfg tid
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
    let ctx =
            ctx0
                { rcCageUtxos = cageUtxos
                , rcHolderUtxos = holderUtxos
                , rcCageScript = case rcCageScript ctx0 of
                    Just s -> Just s
                    Nothing -> Just script
                }
    duties <- case registryDuties cfg pp oldState ctx reqUtxos (map (const True) reqUtxos) of
        Right d -> pure d
        Left err -> error ("updateToken: " <> err)
    upperSlot <-
        computeUpperSlot prov oldState reqUtxos
    let evalTx = mkEvalTx prov
        prog =
            buildProgram
                cfg
                pp
                stateIn
                stateOut
                reqUtxos
                feeUtxo
                oldState
                newStateOut
                script
                requestScript
                proofs
                upperSlot
                duties
                (rcRefUtxos ctx)
    result <-
        Tx.build
            (Tx.mkPParamsBound pp)
            (Tx.InterpretIO (const (pure undefined)))
            evalTx
            ( feeUtxo
                : stateUtxo
                : reqUtxos
                    <> map csUtxo (rdSpends duties)
                    <> rdInputs duties
            )
            (rcRefUtxos ctx)
            addr
            (prog :: Tx.TxBuild NoCtx Void ())
    case result of
        Right tx -> pure tx
        Left err ->
            error $
                "updateToken: build failed: "
                    <> show err

{- | Query cage UTxOs, find the state and request
UTxOs, pick a fee-paying wallet UTxO.
-}
queryContext ::
    CageConfig ->
    Provider IO ->
    TokenId ->
    Addr ->
    IO
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
computeProofs ::
    TrieManager IO ->
    TokenId ->
    [(TxIn, TxOut ConwayEra)] ->
    IO ([[ProofStep]], Root)
computeProofs tm tid reqUtxos =
    withSpeculativeTrie tm tid $ \trie -> do
        ps <- mapM (processRequest trie) reqUtxos
        r <- getRoot trie
        pure (ps, r)

{- | Extract old state, build new state output,
cage script, and owner key hash.
-}
prepareState ::
    CageConfig ->
    TxOut ConwayEra ->
    Root ->
    (OnChainTokenState, TxOut ConwayEra, Script ConwayEra)
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
     in (oldState, newStateOut, script)

-- | Compute the validity upper slot.
computeUpperSlot ::
    Provider IO ->
    OnChainTokenState ->
    [(TxIn, TxOut ConwayEra)] ->
    IO SlotNo
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
    mUpperSlot <-
        try @SomeException
            (posixMsToSlot prov earliestDeadline)
    case mUpperSlot of
        Right s -> pure s
        Left _ -> do
            nowUtc <- getCurrentTime
            let posixSec =
                    utcTimeToPOSIXSeconds nowUtc
            trySlots prov $
                map
                    ( \d ->
                        round
                            ((posixSec + d) * 1000)
                    )
                    [30, 5, 2]

-- | Wrap the Provider's evaluateTx for the DSL.
mkEvalTx ::
    Provider IO ->
    ConwayTx ->
    IO
        ( Map.Map
            ( ConwayPlutusPurpose
                AsIx
                ConwayEra
            )
            (Either String ExUnits)
        )
mkEvalTx prov tx = do
    r <- evaluateTx prov tx
    pure $
        Map.map
            ( \case
                Left e -> Left (show e)
                Right eu -> Right eu
            )
            r

-- | The TxBuild DSL program for an update tx.
buildProgram ::
    CageConfig ->
    PParams ConwayEra ->
    TxIn ->
    TxOut ConwayEra ->
    [(TxIn, TxOut ConwayEra)] ->
    (TxIn, TxOut ConwayEra) ->
    OnChainTokenState ->
    TxOut ConwayEra ->
    Script ConwayEra ->
    Script ConwayEra ->
    [[ProofStep]] ->
    SlotNo ->
    RegistryDuties ->
    [(TxIn, TxOut ConwayEra)] ->
    Tx.TxBuild NoCtx Void ()
buildProgram
    _cfg
    _pp
    stateIn
    _stateOut
    reqUtxos
    feeUtxo
    _oldState
    newStateOut
    script
    requestScript
    proofs
    upperSlot
    duties
    refUtxos = do
        let stateRef = txInToRef stateIn
        let actions = map Update proofs
        _ <- Tx.spendScript stateIn (Modify actions)
        mapM_
            ( \(rIn, _) ->
                Tx.spendScript
                    rIn
                    (Contribute stateRef)
            )
            reqUtxos
        _ <- Tx.output newStateOut
        Coin _fee <- Tx.peek $ \tx ->
            let f = tx ^. bodyTxL . feeTxBodyL
             in if f > Coin 0
                    then Tx.Ok f
                    else Tx.Iterate f
        -- #157 C10: the pinned consumer and its mandatory withdrawal are
        -- gone. Every rule it re-walked beside the fold — request value
        -- coverage, the mint binding — is the cage's own now, checked
        -- once from the transaction's own evidence.
        -- #157 C5/C6/T1-T6: what the edges owe. The custody an edge
        -- consumes is spent, the tokens it moves are minted or burned
        -- under the registry's own three policies, and the carriers it
        -- owes — custody, destination, deposit return — are created.
        mapM_
            (\sp -> Tx.spendScript (fst (csUtxo sp)) (csRedeemer sp))
            (rdSpends duties)
        -- #177 I177-BUILDER: the burn source of a retirement or of an
        -- active deletion. It is an ordinary input, not a script spend:
        -- the active witness sits at the holder's own address, and the
        -- key that signs the fold is the key that owns it.
        mapM_ (Tx.spend . fst) (rdInputs duties)
        mapM_
            (\m -> Tx.mint (cmPolicy m) (cmAssets m) (cmRedeemer m))
            (rdMints duties)
        mapM_ Tx.output (rdOutputs duties)
        mapM_ Tx.requireSignature (rdSigners duties)
        if null refUtxos
            then do
                Tx.attachScript script
                Tx.attachScript requestScript
                mapM_ (Tx.attachScript . csScript) (rdSpends duties)
                mapM_ (Tx.attachScript . cmScript) (rdMints duties)
            else mapM_ (Tx.reference . fst) refUtxos
        Tx.collateral (fst feeUtxo)
        Tx.validTo upperSlot

-- | Process a single request.
processRequest ::
    (Monad m) =>
    Trie m ->
    (TxIn, TxOut ConwayEra) ->
    m [ProofStep]
processRequest trie (_txIn, txOut) =
    walkEdge trie (requestKey req) (requestEdge req)
  where
    req = case extractCageDatum txOut of
        Just (RequestDatum r) -> r
        _ ->
            error
                "processRequest: \
                \invalid request datum"

-- ---------------------------------------------------------
-- Registry-mode obligations (#157 C5, C6, T1-T6)
-- ---------------------------------------------------------

{- | Everything an edge owes a fold beyond the trie: what must move under
the three token policies, where the minted token has to land, which
custody has to be spent, and who has to sign.

The cage computes these from the requests it consumes (`dutiesOf`,
`dutyOk`); this recomputes them from the same requests so a fold can be
built that discharges them. The two are deliberately separate
derivations — a builder that agrees with the validator by construction
would not catch a disagreement.
-}
data RegistryDuties = RegistryDuties
    { rdMints :: [ConnectedMint]
    , rdOutputs :: [TxOut ConwayEra]
    , rdSpends :: [ConnectedSpend]
    , rdSigners :: [KeyHash Guard]
    , rdInputs :: [(TxIn, TxOut ConwayEra)]
    -- ^ #177 I177-BUILDER: ordinary (non-script) inputs the edge needs
    -- the transaction to consume. A retirement or a deletion of an
    -- active key burns an asset it does not create, so the holder UTxO
    -- carrying that asset has to ride in as an input; a mint of `-1` with nothing to burn is a transaction
    -- whose only possible outcome is a refusal.
    }

instance Semigroup RegistryDuties where
    a <> b =
        RegistryDuties
            (rdMints a <> rdMints b)
            (rdOutputs a <> rdOutputs b)
            (rdSpends a <> rdSpends b)
            (rdSigners a <> rdSigners b)
            (rdInputs a <> rdInputs b)

instance Monoid RegistryDuties where
    mempty = RegistryDuties [] [] [] [] []

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
    -- ^ Build a fold even when a request takes no admissible edge, so a
    -- row that exists to watch the chain REFUSE one can produce the
    -- transaction it submits. An honest builder leaves this off and
    -- fails early, naming the request.
    , rcHolderUtxos :: [(TxIn, TxOut ConwayEra)]
    -- ^ #177 I177-BUILDER: the candidate inputs a burn may be sourced
    -- from — the outputs that actually HOLD registry witnesses. A
    -- retirement or an active deletion destroys an asset it does not
    -- create, so the fold has to consume the holder's own UTxO; with
    -- nothing in this
    -- inventory the builder fails naming the key rather than emitting a
    -- mint the cage refuses `token-missing`. Left empty, the builder
    -- queries the fold's own wallet address.
    , rcRefUtxos :: [(TxIn, TxOut ConwayEra)]
    -- ^ Outputs carrying the fold's scripts as reference scripts. The
    -- state validator alone is fifteen kilobytes, so a fold that
    -- attaches it, the request script and a token policy does not fit
    -- in a transaction; with references every purpose resolves through
    -- them instead.
    }

{- | The obligations this set of requests creates, or the reason they
cannot be met. A fold whose duties cannot be built is a fold that would be
refused on chain; failing here names why, in the builder, where it is
cheap.
-}
registryDuties ::
    CageConfig ->
    PParams ConwayEra ->
    OnChainTokenState ->
    RegistryContext ->
    [(TxIn, TxOut ConwayEra)] ->
    -- | Whether each request is PROCESSED by this fold. A rejected
    -- request takes no edge: it owes its owner a refund, and the
    -- approval that certified it was never spent.
    [Bool] ->
    Either String RegistryDuties
registryDuties cfg pp st ctx reqUtxos processed =
    -- Unmatched requests are NOT processed: a deficit fold has more
    -- requests than actions, and the tail of it takes no edge.
    mconcat <$> mapM one (zip reqUtxos (processed <> repeat False))
  where
    net = network cfg
    cageAddr = cageAddrFromCfg cfg net
    tip = stateMaxFee st
    one (_, isProcessed)
        | not isProcessed = Right mempty
    one ((_, reqOut), _) = do
        req <- case extractCageDatum reqOut of
            Just (RequestDatum r) -> Right r
            _ -> Left "registryDuties: a request input carries no request datum"
        let key = requestKey req
            edge = requestEdge req
            dest@(destAddr, destHash) = requestDestination req
            Coin held = reqOut ^. coinTxOutL
            floorAda = held - tip
        -- #183: the tag IS the edge, so admissibility is a range and
        -- nothing is derived from bytes. A tag outside the table owes
        -- the fold no mint and no destination, because the cage refuses
        -- it `edge-inadmissible` before either is read.
        if edge < edgeInsertAbsent || edge > edgeWitnessTerminal
            then
                if rcAllowInadmissible ctx
                    then
                        -- The cage will refuse this, which is the point:
                        -- a row that exists to watch the refusal needs
                        -- the transaction built, not withheld.
                        approvalReturn req reqOut
                    else
                        Left
                            ( "registryDuties: edge "
                                <> show edge
                                <> " on key "
                                <> show key
                                <> " is not one of the seven admissible edges"
                            )
            else do
                mints <- mintsFor edge key
                rest <- dutiesFor edge key dest destAddr destHash floorAda
                back <- approvalReturn req reqOut
                pure (mints <> rest <> back)
    {- An approval is not burned at the fold (D-APPROVAL), so it has to
    land somewhere. It goes back to the owner who booked it, in an output
    of its own: left to the balancer it would settle in the folder's
    change, and the folder's wallet would stop being able to fund a fold
    at all, because collateral must be ada-only. -}
    approvalReturn :: OnChainRequest -> TxOut ConwayEra -> Either String RegistryDuties
    approvalReturn req reqOut = do
        let BuiltinByteString owner = requestOwner req
            carried =
                case reqOut ^. valueTxOutL of
                    MaryValue _ (MultiAsset m) ->
                        Map.filterWithKey
                            (\p _ -> p == policyIdFromPin (cfgApplicationPolicy cfg))
                            m
        if Map.null carried
            then pure mempty
            else do
                addr <- case addrFromBytes owner of
                    Just a -> Right a
                    Nothing -> Right (addrFromKeyHashBytes net owner)
                -- The minimum depends on the serialised size, and the coin
                -- field is part of it, so the empty probe understates it.
                -- One more pass at the answer it gives converges.
                let at c = mkBasicTxOut addr (MaryValue (Coin c) (MultiAsset carried))
                    Coin first = getMinCoinTxOut @ConwayEra pp (at 0)
                    Coin settled = getMinCoinTxOut @ConwayEra pp (at first)
                pure mempty{rdOutputs = [at settled]}
    mintsFor edge key =
        fmap mconcat $
            mapM
                ( \(kind, quantity) -> do
                    script <- case Map.lookup kind (rcWitnessScripts ctx) of
                        Just s -> Right s
                        Nothing ->
                            Left
                                ( "registryDuties: no witness script for kind "
                                    <> show kind
                                )
                    pure
                        mempty
                            { rdMints =
                                [ ConnectedMint
                                    { cmPolicy = PolicyID (hashScript script)
                                    , cmAssets = Map.singleton (AssetName (SBS.toShort key)) quantity
                                    , cmRedeemer = RawRedeemer (PLC.Constr 0 [])
                                    , cmScript = script
                                    }
                                ]
                            }
                )
                (deltaOf edge)
    dutiesFor edge key dest destAddr destHash floorAda
        | edge == 0 = lockCustody key destAddr floorAda
        | edge == 1 = deliver (cfgActivePolicy cfg) key dest destHash floorAda
        | edge == 2 = (<>) <$> spendCustody key <*> deliver (cfgActivePolicy cfg) key dest destHash floorAda
        | edge == 3 = burnSource (cfgActivePolicy cfg) key
        | edge == 4 = spendCustody key
        | edge == 5 = burnSource (cfgActivePolicy cfg) key
        | edge == 6 = deliver (cfgTerminalPolicy cfg) key dest destHash floorAda
        | otherwise = Left ("registryDuties: unknown edge " <> show edge)
    {- #177 I177-BUILDER, #236: the retirement and the deletion of an
    active key burn a token they must first hold. `deltaOf 3` and
    `deltaOf 5` are both `[(active, -1)]` with no carrier output, so the
    asset the mint destroys has to arrive on an input — the Lean row's
    witness input,
    @{ role := .witness, assets := [((.active, r.key), 1)] }@.

    Selection is exact in both directions: the policy is THIS registry's
    active pin and the name is THIS key, so a holder of another key or
    another policy is not a candidate and cannot be swept in. Exactly
    one candidate must hold exactly one unit; none, several, or a
    different quantity is the state the cage refuses `token-missing`,
    and the builder says so here rather than emitting a transaction
    whose only possible outcome is that refusal. -}
    burnSource policy key =
        let policyId = policyIdOf policy
            name = AssetName (SBS.toShort key)
            held out = case out ^. valueTxOutL of
                MaryValue _ (MultiAsset m) ->
                    maybe 0 (Map.findWithDefault 0 name) (Map.lookup policyId m)
            candidates =
                [ (u, q)
                | u@(_, o) <- rcHolderUtxos ctx
                , let q = held o
                , q /= 0
                ]
         in case candidates of
                [(u, 1)] -> Right mempty{rdInputs = [u]}
                -- A row that exists to watch the CHAIN refuse this edge
                -- needs the transaction built, not withheld: the cage
                -- refuses `key-unknown` or `not-booked` before it ever
                -- reaches the burn, and a builder failure here would
                -- substitute its own reason for the one under test.
                -- Same flag, same reason, as the inadmissible-edge arm.
                _ | rcAllowInadmissible ctx -> Right mempty
                [(_, q)] ->
                    Left
                        ( "registryDuties: the holder of the active witness \
                          \for key "
                            <> show key
                            <> " carries "
                            <> show q
                            <> " of it, not exactly one"
                        )
                [] ->
                    Left
                        ( "registryDuties: no input in hand carries the \
                          \active witness for key "
                            <> show key
                            <> "; an edge that burns it must consume it"
                        )
                _ ->
                    Left
                        ( "registryDuties: more than one input carries the \
                          \active witness for key "
                            <> show key
                            <> "; the burn must name one source"
                        )
    -- C6: the absent token sits at the cage, alone, under a custody datum
    -- naming the address the deposit goes back to. Its sole asset is its key.
    lockCustody key refund floorAda = do
        let value =
                MaryValue
                    (Coin floorAda)
                    (MultiAsset (Map.singleton (policyIdOf (cfgAbsentPolicy cfg)) (Map.singleton (AssetName (SBS.toShort key)) 1)))
            out =
                mkBasicTxOut cageAddr value
                    & datumTxOutL .~ mkInlineDatum (toPlcData (AbsentCustody refund))
        requireMinAda "custody" out
        pure mempty{rdOutputs = [out]}
    -- T1/T2: the minted token lands in exactly the output the request
    -- named, carrying the datum whose hash the approval bound.
    deliver policy key _dest destHash floorAda = do
        addr <- destinationAddr
        datum <- destinationDatum destHash
        let value =
                MaryValue
                    (Coin floorAda)
                    (MultiAsset (Map.singleton (policyIdOf policy) (Map.singleton (AssetName (SBS.toShort key)) 1)))
            out = case datum of
                Nothing -> mkBasicTxOut addr value
                Just d -> mkBasicTxOut addr value & datumTxOutL .~ mkInlineDatum d
        requireMinAda "destination" out
        pure mempty{rdOutputs = [out]}
      where
        destinationAddr = case addrFromBytes (fst _dest) of
            Just a -> Right a
            Nothing ->
                Left
                    ( "registryDuties: the request names an address this \
                      \builder cannot decode: "
                        <> show (fst _dest)
                    )
        destinationDatum h
            | BS.null h = Right Nothing
            | otherwise = case Prelude.lookup h (rcDatums ctx) of
                Just d -> Right (Just d)
                Nothing ->
                    Left
                        ( "registryDuties: no preimage in hand for the \
                          \destination datum hash "
                            <> show h
                        )
    -- T4/T5: the custody this edge consumes is spent, and its deposit
    -- goes back to the address it recorded.
    spendCustody key = do
        (utxo, refund, owed) <- findCustody key
        cageScript <- case rcCageScript ctx of
            Just s -> Right s
            Nothing ->
                Left
                    "registryDuties: this edge spends custody, and the \
                    \builder was given no cage script to spend it with"
        let refundAddr = case addrFromBytes refund of
                Just a -> a
                Nothing -> error "registryDuties: custody records an undecodable refund address"
            out = mkBasicTxOut refundAddr (MaryValue (Coin owed) mempty)
        requireMinAda "refund" out
        pure
            mempty
                { rdSpends =
                    [ ConnectedSpend
                        { csUtxo = utxo
                        , csRedeemer = RawRedeemer (toPlcData (Modify []))
                        , csScript = cageScript
                        }
                    ]
                , rdOutputs = [out]
                }
    findCustody key =
        case
            [ (u, refund, coin)
            | u@(_, o) <- rcCageUtxos ctx
            , Just (AbsentCustody refund) <- [extractCageDatum o]
            , Just (policy, name) <- [custodyAssetOf o]
            , policy == policyIdOf (cfgAbsentPolicy cfg)
            , name == AssetName (SBS.toShort key)
            , let Coin coin = o ^. coinTxOutL
            ]
            of
            [c] -> Right c
            [] -> Left ("registryDuties: no custody UTxO for key " <> show key)
            _ -> Left ("registryDuties: more than one custody UTxO for key " <> show key)
    custodyAssetOf out =
        case out ^. valueTxOutL of
            MaryValue _ (MultiAsset policies) ->
                case
                    [ (policy, name, quantity)
                    | (policy, names) <- Map.toList policies
                    , (name, quantity) <- Map.toList names
                    ]
                    of
                    [(policy, name, 1)] -> Just (policy, name)
                    _ -> Nothing
    requireMinAda what out =
        let Coin minAda = getMinCoinTxOut @ConwayEra pp out
            Coin got = out ^. coinTxOutL
         in if got >= minAda
                then Right ()
                else
                    Left
                        ( "registryDuties: the "
                            <> what
                            <> " output holds "
                            <> show got
                            <> " lovelace, under the "
                            <> show minAda
                            <> " minimum"
                        )
    policyIdOf = policyIdFromPin

{- | Can this output fund a fold? It must hold ada and nothing else,
because it doubles as collateral, and it must not be one of the published
reference outputs, because a transaction may not both spend an output and
reference it.
-}
adaOnlyOutput :: TxOut ConwayEra -> Bool
adaOnlyOutput out =
    (case out ^. valueTxOutL of MaryValue _ (MultiAsset m) -> Map.null m)
        && (case out ^. referenceScriptTxOutL of SNothing -> True; SJust _ -> False)
