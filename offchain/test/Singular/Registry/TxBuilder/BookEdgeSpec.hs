{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.Registry.TxBuilder.BookEdgeSpec
Description : #240 — a Terminal read is booked without an approval
License     : Apache-2.0

`bookEdge` is how every consumer puts one registry edge on chain. The
naming application certifies the six tree edges and refuses to certify
`witnessTerminal` (edge 6) at all (`open.ak`, @approval-edge@): the
model admits a read without an approval and the cage never looks for
one on it. A booking that mints an approval for edge 6 is therefore a
transaction the node can only reject.

These rows run the builder itself against a provider serving one
ada-only wallet output and a submitter that keeps what it is handed,
then read the transaction the builder produced — what it mints, which
redeemers, script witness, collateral and script-integrity hash it
carries, and what the request output holds. Every expected value is the
design's own derivation evaluated here: the application policy from the
registry's naming pins, the approval name, the destination the builder
is given. Nothing is copied from the builder's output.

On the base, every booking mints an approval, so the `witnessTerminal`
rows are red for that named reason; the six tree-edge rows are their
control and must pass unchanged.
-}
module Singular.Registry.TxBuilder.BookEdgeSpec (spec) where

import Control.Monad (forM_)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Short qualified as SBS
import Data.Foldable (toList)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Lens.Micro ((^.))
import Test.Hspec

import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.Alonzo.Scripts (AsIx (..))
import Cardano.Ledger.Api.PParams (emptyPParams)
import Cardano.Ledger.Api.Tx (bodyTxL, witsTxL)
import Cardano.Ledger.Api.Tx.Body (
    collateralInputsTxBodyL,
    mintTxBodyL,
    outputsTxBodyL,
    scriptIntegrityHashTxBodyL,
 )
import Cardano.Ledger.Api.Tx.Out (
    addrTxOutL,
    mkBasicTxOut,
    valueTxOutL,
 )
import Cardano.Ledger.Api.Tx.Wits (Redeemers (..), rdmrsTxWitsL, scriptTxWitsL)
import Cardano.Ledger.BaseTypes (
    Network (Testnet),
    StrictMaybe (..),
 )
import Cardano.Ledger.Conway.Scripts (ConwayPlutusPurpose (..))
import Cardano.Ledger.Core (Script, ScriptHash, hashScript)
import Cardano.Ledger.Mary.Value (
    AssetName (..),
    MaryValue (..),
    MultiAsset (..),
    PolicyID,
 )
import Cardano.Ledger.Plutus.Data (getPlutusData)
import Cardano.Ledger.TxIn (TxIn)
import Cardano.Tx.Ledger (ConwayTx)
import PlutusCore.Data qualified as PLCData
import PlutusCore.Version (plcVersion110)
import PlutusLedgerApi.V3 (serialiseUPLC)
import UntypedPlutusCore qualified as UPLC
import UntypedPlutusCore.DeBruijn ()

import Singular.Registry.Blueprint (NamingCodes (..), applyBytesParam)
import Singular.Registry.Config (CageConfig (..))
import Singular.Registry.Deployment (parseOutRef)
import Singular.Registry.Ledger (Coin (..), ConwayEra, TokenId (..))
import Singular.Registry.Provider (Provider (..))
import Singular.Registry.TxBuilder.Edges (
    bookEdge,
    edgeDestinationOf,
    namingPins,
    registryIdOf,
 )
import Singular.Registry.TxBuilder.Internal (
    addrFromKeyHashBytes,
    addrKeyHashBytes,
    approvalName,
    computeScriptHash,
    policyIdFromPin,
    requestAddrFromCfg,
    scriptFromBytes,
    txInToRef,
 )
import Singular.Registry.Types (Edge, OnChainTxOutRef, edgeWitnessTerminal)

-- ---------------------------------------------------------
-- Fixtures: one registry, one payer, two keys
-- ---------------------------------------------------------

{- | A well-formed PlutusV3 program: the registry scripts are
parameterized by applying one argument after another, so the fixture
takes two (`applyRequestParams` applies the state policy and then the
token name; `witnessPin` applies one). @\\x y -> x@ in DeBruijn
indices.
-}
program :: SBS.ShortByteString
program =
    serialiseUPLC
        ( UPLC.Program
            ()
            plcVersion110
            ( UPLC.LamAbs
                ()
                (UPLC.DeBruijn 0)
                ( UPLC.LamAbs
                    ()
                    (UPLC.DeBruijn 0)
                    (UPLC.Var () (UPLC.DeBruijn 2))
                )
            )
        )

codes :: NamingCodes
codes =
    NamingCodes
        { ncApplication = applyBytesParam "t240-application" program
        , ncWitness = applyBytesParam "t240-witness" program
        }

{- | The registry before its pins: the pins derive from its identity,
the state script hash and the boot seed. The pins are filled in
separately — with strict record fields the config and its own pins
would otherwise force each other.
-}
unpinned :: CageConfig
unpinned =
    CageConfig
        { cageScriptBytes = program
        , requestScriptBytes = program
        , cfgScriptHash = computeScriptHash program
        , cageSeed = seedRef
        , defaultProcessTime = 30_000
        , defaultRetractTime = 30_000
        , defaultTip = Coin 1_000_000
        , cfgApplicationPolicy = SBS.empty
        , cfgActivePolicy = SBS.empty
        , cfgAbsentPolicy = SBS.empty
        , cfgTerminalPolicy = SBS.empty
        , cfgConsumerScript = SBS.empty
        , network = Testnet
        }

seedRef :: OnChainTxOutRef
seedRef = txInToRef $ either (error . ("BookEdgeSpec fixture: " <>)) id (parseOutRef (T.pack (replicate 64 '1' <> "#0")))

fundIn :: TxIn
fundIn = either (error . ("BookEdgeSpec fixture: " <>)) id (parseOutRef (T.pack (replicate 64 '3' <> "#0")))

{- | The registry with the four pins its naming partition derives. The
design pins the application hash, and the rows below assert against the
same hash — evaluated from the pins, never from builder output.
-}
cfg :: CageConfig
cfg =
    unpinned
        { cfgApplicationPolicy = applicationPin
        , cfgAbsentPolicy = absentPin
        , cfgActivePolicy = activePin
        , cfgTerminalPolicy = terminalPin
        }

applicationPin, absentPin, activePin, terminalPin :: SBS.ShortByteString
(applicationPin, absentPin, activePin, terminalPin) =
    namingPins codes (registryIdOf unpinned)

{- | The policy the naming application certifies approvals under: the
hash of the applied application script (DM-1 @baAsset@'s policy).
-}
applicationPolicy :: PolicyID
applicationPolicy = policyIdFromPin applicationPin

-- | The naming application script, the design's @baScript@.
applicationScript :: Script ConwayEra
applicationScript = scriptFromBytes "naming-application" (ncApplication codes)

payer :: Addr
payer = addrFromKeyHashBytes Testnet (BS.replicate 28 0x5a)

tokenId :: TokenId
tokenId = TokenId (AssetName "t240-registry")

keys :: [ByteString]
keys = ["t240-key-a", "t240-key-b"]

-- | The seven admissible edges, by the name the model gives each.
edges :: [(Edge, String)]
edges =
    zip
        [0 ..]
        [ "insertAbsent"
        , "insertActive"
        , "updateActive"
        , "updateTerminal"
        , "deleteAbsent"
        , "deleteActive"
        , "witnessTerminal"
        ]

{- | A wallet holding one ada-only output, and nothing else to say. The
stubs fail loudly: if the builder ever evaluates or asks for a slot,
every row fails with that message instead of a silent pass.
-}
provider :: Provider IO
provider =
    Provider
        { queryUTxOs = \_ ->
            pure [(fundIn, mkBasicTxOut payer (MaryValue (Coin 100_000_000) mempty))]
        , queryProtocolParams = pure emptyPParams
        , evaluateTx = \_ -> fail "bookEdge evaluates nothing"
        , posixMsToSlot = \_ -> fail "bookEdge queries no slot"
        , posixMsCeilSlot = \_ -> fail "bookEdge queries no slot"
        }

-- | Run the builder and keep the transaction it submits.
booked :: Edge -> ByteString -> IO ConwayTx
booked edge key = do
    kept <- newIORef Nothing
    _ <-
        bookEdge
            cfg
            codes
            provider
            (\tx -> tx <$ writeIORef kept (Just tx))
            payer
            tokenId
            key
            edge
    readIORef kept >>= maybe (fail "bookEdge submitted nothing") pure

-- ---------------------------------------------------------
-- What a booking carries
-- ---------------------------------------------------------

-- | Every policy a multi-asset names, with its assets.
policies :: MultiAsset -> Map PolicyID (Map AssetName Integer)
policies (MultiAsset m) = m

-- | The transaction's whole mint, every policy.
mintOf :: ConwayTx -> Map PolicyID (Map AssetName Integer)
mintOf tx = policies (tx ^. bodyTxL . mintTxBodyL)

-- | What the transaction mints under the application policy.
mintedUnder :: ConwayTx -> Map AssetName Integer
mintedUnder tx = Map.findWithDefault Map.empty applicationPolicy (mintOf tx)

{- | Every redeemer the transaction carries, as plain data, with the
purpose that names it.
-}
redeemersOf :: ConwayTx -> [(ConwayPlutusPurpose AsIx ConwayEra, PLCData.Data)]
redeemersOf tx =
    let Redeemers m = tx ^. witsTxL . rdmrsTxWitsL
     in [(purpose, getPlutusData d) | (purpose, (d, _)) <- Map.toList m]

{- | The approval redeemer the design binds: the @Approve@ constructor
over @(edge, key, owner, (destination address, destination datum))@ —
the tuple the approval name hashes (DM-1-BIND).
-}
approveRedeemer :: Edge -> ByteString -> ByteString -> (ByteString, ByteString) -> PLCData.Data
approveRedeemer edge key owner destination =
    let (destAddr, destHash) = destination
     in PLCData.Constr
            0
            [ PLCData.I edge
            , PLCData.B key
            , PLCData.B owner
            , PLCData.List [PLCData.B destAddr, PLCData.B destHash]
            ]

-- | What the request output holds under the application policy.
requestHolds :: ConwayTx -> IO (Map AssetName Integer)
requestHolds tx =
    case [ out
         | out <- toList (tx ^. bodyTxL . outputsTxBodyL)
         , out ^. addrTxOutL == requestAddrFromCfg cfg tokenId Testnet
         ] of
        [out] ->
            let MaryValue _ assets = out ^. valueTxOutL
             in pure (Map.findWithDefault Map.empty applicationPolicy (policies assets))
        outs -> fail ("the booking has " <> show (length outs) <> " request outputs")

-- | The hashes of the scripts the transaction witnesses.
witnessOf :: ConwayTx -> [ScriptHash]
witnessOf tx = Map.keys (tx ^. witsTxL . scriptTxWitsL)

-- | Whether a strict-optional field is set.
setS :: StrictMaybe a -> Bool
setS (SJust _) = True
setS SNothing = False

-- ---------------------------------------------------------
-- The rows
-- ---------------------------------------------------------

{- | DM-1b, absent row: edge 6 carries nothing at all. Every violation
is named — the row's failure message reports what it found, so a red
names the mint or the redeemer it caught.
-}
carriesNothing :: ConwayTx -> IO ()
carriesNothing tx = do
    holds <- requestHolds tx
    let mint = mintOf tx
        redeemers = redeemersOf tx
        witness = witnessOf tx
        collateral = tx ^. bodyTxL . collateralInputsTxBodyL
        integrity = tx ^. bodyTxL . scriptIntegrityHashTxBodyL
        findings =
            concat
                [ ["it mints " <> T.pack (show mint) | not (Map.null mint)]
                , ["it carries redeemers " <> T.pack (show redeemers) | not (null redeemers)]
                , ["it carries a script witness " <> T.pack (show witness) | not (null witness)]
                , ["it carries collateral " <> T.pack (show collateral) | not (Set.null collateral)]
                , ["it carries a script-integrity hash" | setS integrity]
                , ["its request output holds " <> T.pack (show holds) | not (Map.null holds)]
                ]
    case findings of
        [] -> pure ()
        found ->
            expectationFailure $
                "the booking certifies a read that needs no approval: "
                    <> T.unpack (T.intercalate "; " found)

{- | DM-1b, present row: a tree-edge booking mints exactly its bound
approval under the application policy and nothing under any other,
names it with one @Approve@ redeemer, carries the application script as
witness, the wallet input as collateral and a script-integrity hash,
and the request output carries the same approval.
-}
carriesItsApproval :: Edge -> ByteString -> ConwayTx -> IO ()
carriesItsApproval edge key tx = do
    let owner = addrKeyHashBytes payer
        destination = edgeDestinationOf cfg codes payer edge
        name = AssetName (SBS.toShort (approvalName edge key owner destination))
        approval = Map.singleton name 1
    Map.keys (mintOf tx) `shouldBe` [applicationPolicy]
    mintedUnder tx `shouldBe` approval
    redeemersOf tx
        `shouldBe` [(ConwayMinting (AsIx 0), approveRedeemer edge key owner destination)]
    witnessOf tx `shouldBe` [hashScript applicationScript]
    tx ^. bodyTxL . collateralInputsTxBodyL `shouldBe` Set.singleton fundIn
    tx ^. bodyTxL . scriptIntegrityHashTxBodyL `shouldSatisfy` setS
    requestHolds tx `shouldReturn` approval

spec :: Spec
spec =
    describe "bookEdge certifies exactly the edges the application approves" $
        forM_ keys $ \key ->
            forM_ edges $ \(edge, name) ->
                if edge == edgeWitnessTerminal
                    then
                        it
                            (name <> " on " <> show key <> " carries nothing under the application")
                            (carriesNothing =<< booked edge key)
                    else
                        it
                            (name <> " on " <> show key <> " carries exactly its bound approval")
                            (carriesItsApproval edge key =<< booked edge key)
