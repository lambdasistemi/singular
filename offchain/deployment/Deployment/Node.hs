{- |
Module      : Deployment.Node
Description : What @deployment@ does and asks at a node
License     : Apache-2.0

The node operations the verbs are made of. Each transaction is signed by
the funding wallet, submitted, awaited, and its id recorded in the order
the chain accepted it ('submitted'), so the manifest can list its
bootstrap transactions.

* 'bootRegistry' — boot one registry from the funding wallet's largest
  output that is not a reference publication;
* 'registerCredentials' — register the three stake credentials a run
  withdraws from, reusing any already registered;
* 'publishOne' and 'publishAll' — publish reference scripts, one per
  transaction, each spending the change of the last;
* 'verifyRegisteredDeployment' — the manifest's claims against the node
  ('Singular.Registry.Deployment.verifyDeployment') plus the three stake
  credentials.
-}
module Deployment.Node
    ( verifyRegisteredDeployment
    , bootRegistry
    , registerCredentials
    , publishAll
    , publishOne
    , submitted
    ) where

import Control.Monad (unless)
import Data.IORef (IORef, readIORef, writeIORef)
import Data.List (sortOn)
import Data.Map.Strict qualified as Map
import Data.Ord (Down (..))
import Data.Sequence.Strict qualified as StrictSeq
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Lens.Micro ((&), (.~), (^.))

import Cardano.Ledger.Api.Tx (bodyTxL, mkBasicTx, txIdTx)
import Cardano.Ledger.Api.Tx.Body
    ( feeTxBodyL
    , inputsTxBodyL
    , mintTxBodyL
    , mkBasicTxBody
    , outputsTxBodyL
    )
import Cardano.Ledger.Api.Tx.In (TxIn (..))
import Cardano.Ledger.Api.Tx.Out
    ( TxOut
    , coinTxOutL
    , getMinCoinTxOut
    , mkBasicTxOut
    , referenceScriptTxOutL
    , valueTxOutL
    )
import Cardano.Ledger.BaseTypes (Network (..), StrictMaybe (..))
import Cardano.Ledger.Core (Script, hashScript)
import Cardano.Ledger.Mary.Value (MaryValue (..), MultiAsset (..))
import Cardano.Tx.Ledger (ConwayTx)

import Deployment.Compiled (Compiled (..), bindSeed, partsOf)
import Deployment.Narration (emit, failWith, hexT, tokenText, txText)
import Singular.Registry.Config (CageConfig (..))
import Singular.Registry.Deployment
    ( CageParts (..)
    , Deployment
    , ReferenceScript (..)
    , renderAddrBytes
    , renderOutRef
    , verifyDeployment
    )
import Singular.Registry.Ledger
    ( Coin (..)
    , ConwayEra
    , TokenId (..)
    )
import Singular.Registry.Node
    ( Capabilities (..)
    , SubmitResult (..)
    , bech32Address
    , funderAddr
    , funderSignKey
    , signTx
    , signedTx
    , submitSigned
    )
import Singular.Registry.Provider qualified as Cage
import Singular.Registry.TxBuilder.Boot (bootTokenImpl)
import Singular.Registry.TxBuilder.Internal
    ( cagePolicyIdFromCfg
    , computeScriptHash
    , mkCageScript
    , mkRequestScript
    , scriptFromBytes
    , scriptHashBytes
    , txInToRef
    )
import Singular.Registry.TxBuilder.Register (registerScriptImpl)

{- | The manifest's claims against this node, then the three stake
credentials a run withdraws from.
-}
verifyRegisteredDeployment
    :: Cage.Provider IO -> Deployment -> Compiled -> IO [String]
verifyRegisteredDeployment prov dep compiled =
    Cage.withView prov $ \v -> do
        claims <- verifyDeployment v dep (partsOf compiled)
        credentials <-
            mapM
                (check v)
                [ ("active", cActiveBytes compiled)
                , ("custody", cCustodyBytes compiled)
                , ("staking", cStakingBytes compiled)
                ]
        pure (claims <> credentials)
  where
    check v (name, bytes) = do
        registered <- Cage.viewScriptRegistered v (computeScriptHash bytes)
        unless registered $
            failWith (name <> " stake credential is not registered on this node")
        pure (name <> " stake credential is registered on this node")

-- | Boot one registry from the funding wallet's largest output.
bootRegistry
    :: Cage.Provider IO
    -> Capabilities
    -> Compiled
    -> IORef [Text]
    -> Integer
    -> Integer
    -- ^ Process window (ms), from @--process-time@.
    -> IO (CageConfig, TokenId, ConwayTx, TxIn, Compiled)
    -- ^ Retract window (ms), from @--retract-time@.
bootRegistry prov caps unbound txs processTime retractTime = do
    -- The seed and the boot that spends it are read from one view.
    (seedIn, cfg, compiled, unsigned) <- Cage.withView prov $ \v -> do
        utxos <- Cage.viewUTxOsAt v funderAddr
        -- Never seed from a reference publication: the boot references the
        -- state validator's and may not also spend it.
        seedIn <- case sortOn
            (Down . (^. coinTxOutL) . snd)
            (filter (\(_, o) -> o ^. referenceScriptTxOutL == SNothing) utxos) of
            [] -> failWith "the funding wallet has no outputs to seed from"
            ((i, _) : _) -> pure i
        let compiled = bindSeed unbound seedIn
            parts = partsOf compiled
            cfg =
                CageConfig
                    { cageScriptBytes = cStateBytes compiled
                    , requestScriptBytes = cRequestBytes compiled
                    , cfgScriptHash = computeScriptHash (cStateBytes compiled)
                    , cageSeed = txInToRef seedIn
                    , defaultProcessTime = processTime
                    , defaultRetractTime = retractTime
                    , defaultTip = Coin 1_000_000
                    , -- #157 D-BOOT: the four pins the boot datum carries come
                      -- from the one derivation `partsOf` performs, so the
                      -- manifest, the config and the state datum cannot drift
                      -- apart.
                      cfgApplicationPolicy = partsApplicationPolicy parts
                    , cfgActivePolicy = partsActivePolicy parts
                    , cfgAbsentPolicy = partsAbsentPolicy parts
                    , cfgTerminalPolicy = partsTerminalPolicy parts
                    , cfgConsumerScript = partsConsumerScript parts
                    , network = Testnet
                    }
        unsigned <- bootTokenImpl cfg v funderAddr
        pure (seedIn, cfg, compiled, unsigned)
    signed <- submitted caps txs "boot" unsigned
    let MultiAsset ma = signed ^. bodyTxL . mintTxBodyL
    tok <- case Map.toList (ma Map.! cagePolicyIdFromCfg cfg) of
        [(an, _)] -> pure (TokenId an)
        _ -> failWith "boot minted something other than one registry token"
    emit
        "boot"
        ( "registry 0x"
            <> T.unpack (tokenText tok)
            <> " from seed "
            <> T.unpack (renderOutRef seedIn)
        )
    pure (cfg, tok, signed, seedIn, compiled)

{- | Every stake credential a run withdraws from, registered once.

Three of them in registry mode (#157): the registry-bound active token
policy the retirement rows witness through, the completion-only custody
script those rows pay into, and the always-true staking script that serves
the swapped-hook control — its withdraw arm always succeeds, so the
ledger passes it and only the cage's own exact-credential check can
refuse. The consumer credential is gone with the hook it served: a
@Modify@ withdraws from nothing. A registry that attaches cannot register
these itself (a second registration is refused), so a deployment missing
one turns that runner's row into a refusal with no evidence behind it.
-}
registerCredentials
    :: Cage.Provider IO
    -> Capabilities
    -> Compiled
    -> IORef [Text]
    -> IO ()
registerCredentials prov caps compiled txs = do
    let named name bytes = (name, scriptFromBytes name bytes)
    mapM_
        registerOne
        [ named "active" (cActiveBytes compiled)
        , named "naming-custody" (cCustodyBytes compiled)
        , named "staking" (cStakingBytes compiled)
        ]
  where
    registerOne (name, script) = do
        -- Registration and its transaction are read from one view.
        tx <- Cage.withView prov $ \v -> do
            registered <- Cage.viewScriptRegistered v (hashScript script)
            if registered
                then pure Nothing
                else Just <$> registerScriptImpl v funderAddr (hashScript script)
        case tx of
            Nothing ->
                emit
                    "credential"
                    (name <> " stake credential already registered; reused")
            Just unsigned -> do
                _ <- submitted caps txs (name <> "-registration") unsigned
                emit "credential" (name <> " stake credential registered")

{- | The five reference scripts every runner reads: the registry's state
and request validators, the naming application, the registry-bound
active token policy, and the completion-only custody script.

The state validator was published before the boot, which resolved it
from there; it is recorded at that output. The other four are published
here, one script per transaction, each spending the change of the last.
That is slower than batching and it is the shape that works on a public
network without a funding pool: every step is confirmed before the next
one needs its output.
-}
publishAll
    :: Cage.Provider IO
    -> Capabilities
    -> CageConfig
    -> TokenId
    -> Compiled
    -> TxIn
    -- ^ The state validator's publication, made before the boot.
    -> IORef [Text]
    -> IO [ReferenceScript]
publishAll prov caps cfg tok compiled stateIn txs = do
    state <- record ("state", mkCageScript cfg) stateIn
    rest <-
        mapM
            (\p@(_, script) -> publishOne prov caps txs script >>= record p . fst)
            [ ("request", mkRequestScript cfg tok)
            ,
                ( "application"
                , scriptFromBytes "naming-application" (cAppBytes compiled)
                )
            , ("active", scriptFromBytes "active" (cActiveBytes compiled))
            , ("custody", scriptFromBytes "naming-custody" (cCustodyBytes compiled))
            ]
    pure (state : rest)
  where
    record (role, script) txIn = do
        emit
            "published"
            ( T.unpack role
                <> " reference script at "
                <> T.unpack (renderOutRef txIn)
            )
        pure
            ReferenceScript
                { refRole = role
                , refHash = hexT (scriptHashBytes (hashScript script))
                , refOutRef = renderOutRef txIn
                , refAddress = T.pack (bech32Address funderAddr)
                , refAddressBytes = renderAddrBytes funderAddr
                }

publishOne
    :: Cage.Provider IO
    -> Capabilities
    -> IORef [Text]
    -> Script ConwayEra
    -> IO (TxIn, TxOut ConwayEra)
publishOne prov caps txs script = do
    -- The funding output, the parameters and the body: one view.
    unsigned <- Cage.withView prov $ \v -> do
        let pp = Cage.viewProtocolParams v
        utxos <- Cage.viewUTxOsAt v funderAddr
        fund <- case sortOn (Down . (^. coinTxOutL) . snd) (adaOnly utxos) of
            [] -> failWith "publish: the funding wallet has no ada-only output"
            (u : _) -> pure u
        let probe =
                mkBasicTxOut funderAddr (MaryValue (Coin 0) mempty)
                    & referenceScriptTxOutL .~ SJust script
            Coin minCoin = getMinCoinTxOut pp probe
            refOut =
                mkBasicTxOut
                    funderAddr
                    (MaryValue (Coin (minCoin + 1_000_000)) mempty)
                    & referenceScriptTxOutL .~ SJust script
            Coin inCoin = snd fund ^. coinTxOutL
            changeCoin = inCoin - 1_000_000 - (minCoin + 1_000_000)
        unless (changeCoin > 1_000_000) $
            failWith
                ( "publish: the funding output holds "
                    <> show inCoin
                    <> " lovelace, which does not cover a reference output of "
                    <> show (minCoin + 1_000_000)
                    <> " plus fees and change"
                )
        let body =
                mkBasicTxBody
                    & inputsTxBodyL .~ Set.singleton (fst fund)
                    & outputsTxBodyL
                        .~ StrictSeq.fromList
                            [ refOut
                            , mkBasicTxOut funderAddr (MaryValue (Coin changeCoin) mempty)
                            ]
                    & feeTxBodyL .~ Coin 1_000_000
        pure (mkBasicTx body)
    signed <- submitted caps txs "publish" unsigned
    let published = txIdTx signed
    after <- Cage.withView prov (`Cage.viewUTxOsAt` funderAddr)
    -- The output this transaction created, identified by the
    -- transaction rather than by the script: two publishes of the same
    -- script would otherwise be indistinguishable.
    case [u | u@(TxIn i _, o) <- after, i == published, hasScript o] of
        (u : _) -> pure u
        [] ->
            failWith
                "publish: the node accepted the transaction but no output \
                \of it carries the reference script"
  where
    adaOnly us =
        [ u
        | u@(_, o) <- us
        , let MaryValue _ (MultiAsset m) = o ^. valueTxOutL
        , Map.null m
        , o ^. referenceScriptTxOutL == SNothing
        ]
    hasScript o = case o ^. referenceScriptTxOutL of
        SJust s -> hashScript s == hashScript script
        SNothing -> False

-- | Sign with the funding wallet, submit, wait for the chain, record.
submitted
    :: Capabilities -> IORef [Text] -> String -> ConwayTx -> IO ConwayTx
submitted caps txs label unsigned = do
    let signed = signTx funderSignKey unsigned
        tx = signedTx signed
    result <- submitSigned (capSubmit caps) signed
    case result of
        Submitted _ -> pure ()
        Rejected reason -> failWith (label <> ": rejected: " <> show reason)
    capConfirm caps tx
    old <- readIORef txs
    writeIORef txs (txText tx : old)
    pure tx
