{- |
Module      : Deployment.Count
Description : @deployment count@ — what a deployment would otherwise create
License     : Apache-2.0

Count what a deployment would otherwise create, so a check can say
whether a run created any.

@--what state@ counts outputs at the registry address carrying a token
of the recorded policy: one per registry ever booted under this state
validator. @--what reference@ counts outputs carrying a reference
script at the funding address and an optional additional publisher address
given as @--reference-address-bytes HEX@. A run that attached
leaves both unchanged; a run that booted and published moves both.

The count is printed alone on standard output. An unknown @--what@ and
undecodable address bytes are refused once the node session is open.
-}
module Deployment.Count (
    count,
) where

import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Char8 qualified as BC
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Lens.Micro ((^.))

import Cardano.Ledger.Address (decodeAddrEither)
import Cardano.Ledger.Api.Tx.Out (referenceScriptTxOutL, valueTxOutL)
import Cardano.Ledger.BaseTypes (Network (..), StrictMaybe (..))
import Cardano.Ledger.Mary.Value (MaryValue (..), MultiAsset (..))

import Deployment.Compiled (bindDeployment, loadCompiled, partsOf)
import Deployment.Narration (failWith)
import Deployment.Options (CountOptions (..), countOptions)
import Singular.Registry.Deployment (cageConfigFor, readDeployment)
import Singular.Registry.Node (NodeSession (..), funderAddr, withNode)
import Singular.Registry.Provider qualified as Cage
import Singular.Registry.TxBuilder.Internal (
    cageAddrFromCfg,
    cagePolicyIdFromCfg,
 )

-- | Count what these arguments ask for, at the node.
count :: [String] -> IO ()
count args = do
    opts <- countOptions args
    dep <- readDeployment (countManifest opts)
    compiled <- loadCompiled >>= (`bindDeployment` dep)
    cfg <- either failWith pure (cageConfigFor dep (partsOf compiled))
    withNode $ \sess -> do
        let prov = nsProvider sess
        case countWhat opts of
            "state" -> do
                utxos <- Cage.queryUTxOs prov (cageAddrFromCfg cfg Testnet)
                print (length [() | (_, o) <- utxos, carriesPolicy cfg o])
            "reference" -> do
                addresses <- case countReferenceAddress opts of
                    Nothing -> pure [funderAddr]
                    Just encoded -> do
                        raw <- either failWith pure (B16.decode (BC.pack encoded))
                        addr <- either (failWith . show) pure (decodeAddrEither raw)
                        pure (Set.toList (Set.fromList [funderAddr, addr]))
                utxos <- concat <$> mapM (Cage.queryUTxOs prov) addresses
                print (length [() | (_, o) <- utxos, hasReferenceScript o])
            what -> failWith ("count: --what must be state or reference, not " <> what)
  where
    carriesPolicy cfg o =
        let MaryValue _ (MultiAsset m) = o ^. valueTxOutL
         in Map.member (cagePolicyIdFromCfg cfg) m
    hasReferenceScript o = case o ^. referenceScriptTxOutL of
        SJust _ -> True
        SNothing -> False
