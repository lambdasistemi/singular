{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

{- | The public builder books registration and permanent retirement with
exactly their tuple-bound approvals. The other five historical wire tags
must be refused before a transaction is submitted.
-}
module Singular.Registry.TxBuilder.BookEdgeSpec (spec) where

import Control.Monad (forM_)
import Data.ByteString (ByteString)
import Data.ByteString.Short qualified as SBS
import Data.Foldable (toList)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Lens.Micro ((^.))
import Test.Hspec

import Cardano.Ledger.Alonzo.Scripts (AsIx (..))
import Cardano.Ledger.Api.Tx (bodyTxL, witsTxL)
import Cardano.Ledger.Api.Tx.Body
    ( collateralInputsTxBodyL
    , mintTxBodyL
    , outputsTxBodyL
    , scriptIntegrityHashTxBodyL
    )
import Cardano.Ledger.Api.Tx.Out
    ( addrTxOutL
    , mkBasicTxOut
    , valueTxOutL
    )
import Cardano.Ledger.Api.Tx.Wits
    ( Redeemers (..)
    , rdmrsTxWitsL
    , scriptTxWitsL
    )
import Cardano.Ledger.BaseTypes
    ( Network (Testnet)
    , StrictMaybe (..)
    )
import Cardano.Ledger.Conway.Scripts (ConwayPlutusPurpose (..))
import Cardano.Ledger.Core (ScriptHash, hashScript)
import Cardano.Ledger.Mary.Value
    ( AssetName (..)
    , MaryValue (..)
    , MultiAsset (..)
    , PolicyID
    )
import Cardano.Ledger.Plutus.Data (getPlutusData)
import Cardano.Tx.Ledger (ConwayTx)
import PlutusCore.Data qualified as PLCData

import Singular.Registry.Evidence (NoWitness)
import Singular.Registry.Ledger (Coin (..), ConwayEra)
import Singular.Registry.LedgerProvider (LedgerProvider)
import Singular.Registry.LedgerProvider qualified as LedgerProvider
import Singular.Registry.StubSession
import Singular.Registry.SyntheticTime (syntheticTime)
import Singular.Registry.TxBuilder.BookingFixture
import Singular.Registry.TxBuilder.Edges
    ( bookEdge
    , edgeDestinationOf
    )
import Singular.Registry.TxBuilder.Internal
    ( addrKeyHashBytes
    , approvalDestination
    , approvalName
    , requestAddrFromCfg
    )
import Singular.Registry.Types
    ( Edge
    )

{- | A wallet holding one ada-only output, and nothing else to say. The
raw time is supplied for the pre-build major guard. The remaining stubs
fail loudly: if the builder ever evaluates or asks for resolved inputs,
every row fails with that message instead of a silent pass.
-}
provider :: (LedgerProvider.Network, LedgerProvider NoWitness IO)
provider =
    servingSession $
        withAddressOutputs
            ( \_ ->
                pure
                    [(fundIn, mkBasicTxOut payer (MaryValue (Coin 100_000_000) mempty))]
            )
            (withTime (pure syntheticTime) stubSession)

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
redeemersOf
    :: ConwayTx -> [(ConwayPlutusPurpose AsIx ConwayEra, PLCData.Data)]
redeemersOf tx =
    let Redeemers m = tx ^. witsTxL . rdmrsTxWitsL
    in  [(purpose, getPlutusData d) | (purpose, (d, _)) <- Map.toList m]

{- | The approval redeemer the design binds: the @Approve@ constructor
over @(edge, key, owner, (destination address, destination datum))@ —
the tuple the approval name hashes (DM-1-BIND).
-}
approveRedeemer
    :: Edge
    -> ByteString
    -> ByteString
    -> (ByteString, ByteString)
    -> PLCData.Data
approveRedeemer edge key owner destination =
    let (destAddr, destHash) = destination
    in  PLCData.Constr
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
            in  pure
                    (Map.findWithDefault Map.empty applicationPolicy (policies assets))
        outs ->
            fail ("the booking has " <> show (length outs) <> " request outputs")

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

{- | DM-1b, present row: a tree-edge booking mints exactly its bound
approval under the application policy and nothing under any other,
names it with one @Approve@ redeemer, carries the application script as
witness, the wallet input as collateral and a script-integrity hash,
and the request output carries the same approval.
-}
carriesItsApproval :: Edge -> ByteString -> ConwayTx -> IO ()
carriesItsApproval edge key tx = do
    let owner = addrKeyHashBytes payer
        destination = approvalDestination (edgeDestinationOf cfg codes payer edge)
        name = AssetName (SBS.toShort (approvalName edge key owner destination))
        approval = Map.singleton name 1
    Map.keys (mintOf tx) `shouldBe` [applicationPolicy]
    mintedUnder tx `shouldBe` approval
    redeemersOf tx
        `shouldBe` [(ConwayMinting (AsIx 0), approveRedeemer edge key owner destination)]
    witnessOf tx `shouldBe` [hashScript applicationScript]
    tx ^. bodyTxL . collateralInputsTxBodyL
        `shouldBe` Set.singleton fundIn
    tx ^. bodyTxL . scriptIntegrityHashTxBodyL `shouldSatisfy` setS
    requestHolds tx `shouldReturn` approval

spec :: Spec
spec =
    describe
        "bookEdge certifies exactly the edges the application approves"
        $ forM_ keys
        $ \key ->
            forM_ edges $ \(edge, name) ->
                if edge `elem` [1, 3]
                    then
                        it
                            (name <> " on " <> show key <> " carries exactly its bound approval")
                            (carriesItsApproval edge key =<< booked edge key)
                    else
                        it
                            (name <> " on " <> show key <> " is refused before submission")
                            (booked edge key `shouldThrow` anyException)
