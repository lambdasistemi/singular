{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NumericUnderscores #-}

{- |
Module      : Singular.Registry.StateTokenFixture
Description : One registry booted from one seed, and a chain that answers for it
License     : Apache-2.0

A release of toy PlutusV3 programs, a seed, the registry a boot from that
seed makes — configuration and pins from 'configForApplication', the state
datum from 'bootStateFromCfg', the reference scripts from the builders that
publish them — and a chain session over a UTxO map, a mint record per asset
and an existence index. Every expected value a resolution or a reference
search is compared against is produced by those boot-side functions, never
typed, and never by the code under test.
-}
module Singular.Registry.StateTokenFixture
    ( -- * The release and the registry it boots
      release
    , seedIn
    , token
    , tokenOf
    , creationTx
    , bootEconomics
    , bootCfg
    , bootCodes
    , bootState
    , stateIn
    , stateOutput
    , bootScripts
    , carrierOf

      -- * A chain that answers for it
    , Chain (..)
    , honestChain
    , chainSession
    , refOf
    ) where

import Data.ByteString.Short qualified as SBS
import Data.IORef (IORef, modifyIORef')
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Lens.Micro ((&), (.~), (^.))

import Cardano.Ledger.Api.Tx.Out
    ( TxOut
    , addrTxOutL
    , datumTxOutL
    , mkBasicTxOut
    , referenceScriptTxOutL
    , valueTxOutL
    )
import Cardano.Ledger.BaseTypes
    ( Network (Testnet)
    , StrictMaybe (..)
    , TxIx (..)
    )
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Core (Script)
import Cardano.Ledger.Hashes (ScriptHash)
import Cardano.Ledger.Mary.Value
    ( AssetName (..)
    , MaryValue (..)
    , MultiAsset (..)
    , PolicyID (..)
    )
import Cardano.Ledger.TxIn (TxId, TxIn (..))

import Singular.Application.OpenDatum.Script (Application (..))
import Singular.Registry.AssetName (deriveAssetName)
import Singular.Registry.Blueprint (NamingCodes (..), applyBytesParam)
import Singular.Registry.Config (CageConfig (..), bootStateFromCfg)
import Singular.Registry.Config.Application
    ( RegistryEconomics (..)
    , configForApplication
    )
import Singular.Registry.Deployment (parseOutRef)
import Singular.Registry.Evidence (Evidenced (..), NoWitness)
import Singular.Registry.Ledger (ConwayEra, TokenId (..))
import Singular.Registry.LedgerProvider qualified as LP
import Singular.Registry.StateToken (Release (..))
import Singular.Registry.StubSession (stubSession)
import Singular.Registry.TxBuilder.BookingFixture (codes, program)
import Singular.Registry.TxBuilder.Edges (witnessScriptOf)
import Singular.Registry.TxBuilder.Internal
    ( cageAddrFromCfg
    , computeScriptHash
    , emptyRoot
    , mkInlineDatum
    , mkRequestScript
    , scriptFromBytes
    , toPlcData
    , txInToRef
    )
import Singular.Registry.Types
    ( CageDatum (..)
    , OnChainRoot (..)
    , OnChainTokenState
    )

-- | A release whose state and request programs differ.
release :: Release
release =
    Release
        { releaseState = applyBytesParam "singular-state" program
        , releaseRequest = program
        , releaseCodes = codes
        }

seedIn :: TxIn
seedIn = refOf (T.replicate 64 "1" <> "#0")

-- | The state token a seed determines under this release.
tokenOf :: TxIn -> LP.Asset
tokenOf seed =
    ( PolicyID (computeScriptHash (releaseState release))
    , AssetName (SBS.toShort (deriveAssetName (txInToRef seed)))
    )

token :: LP.Asset
token = tokenOf seedIn

creationTx :: TxId
creationTx = let TxIn i _ = refOf (T.replicate 64 "2" <> "#0") in i

-- | Windows and tip unlike any default, so a resolution must read them.
bootEconomics :: RegistryEconomics
bootEconomics =
    RegistryEconomics
        { reProcessTime = 777_000
        , reRetractTime = 333_000
        , reTip = Coin 3_000_000
        }

bootCfg :: CageConfig
bootCodes :: NamingCodes
(bootCfg, bootCodes) =
    configForApplication
        OpenDatumApplication
        (releaseCodes release)
        (releaseState release)
        (releaseRequest release)
        bootEconomics
        Testnet
        (txInToRef seedIn)

bootState :: OnChainTokenState
bootState = bootStateFromCfg bootCfg (OnChainRoot emptyRoot)

stateIn :: TxIn
stateIn = TxIn creationTx (TxIx 0)

-- | The state output holding the token, with this datum.
stateOutput :: OnChainTokenState -> TxOut ConwayEra
stateOutput st =
    mkBasicTxOut (cageAddrFromCfg bootCfg Testnet) value
        & datumTxOutL .~ mkInlineDatum (toPlcData (StateDatum st))
  where
    (policy, name) = token
    value =
        MaryValue
            (Coin 2_000_000)
            (MultiAsset (Map.singleton policy (Map.singleton name 1)))

{- | The six scripts a boot publishes, by their receipt role, as create
builds them.
-}
bootScripts :: [(Text, Script ConwayEra)]
bootScripts =
    [ ("state", scriptFromBytes "state" (cageScriptBytes bootCfg))
    , ("request", mkRequestScript bootCfg (TokenId (snd token)))
    , ("witness-absent", witnessScriptOf bootCfg bootCodes 0)
    , ("witness-active", witnessScriptOf bootCfg bootCodes 1)
    , ("witness-terminal", witnessScriptOf bootCfg bootCodes 2)
    ,
        ( "application"
        , scriptFromBytes "open-datum" (ncApplication bootCodes)
        )
    ]

-- | An output carrying the script as its reference script.
carrierOf :: Script ConwayEra -> TxOut ConwayEra
carrierOf script =
    mkBasicTxOut
        (cageAddrFromCfg bootCfg Testnet)
        (MaryValue (Coin 20_000_000) mempty)
        & referenceScriptTxOutL .~ SJust script

-- | What a chain holds and what its provider answers.
data Chain = Chain
    { chainNetwork :: LP.Network
    , chainOutputs :: Map TxIn (TxOut ConwayEra)
    , chainMints :: Map LP.Asset LP.MintRecord
    , chainCarriers :: ScriptHash -> LP.Outputs
    {- ^ The existence index: what the provider answers for a script. It
    may lag or misname; the honest one lists the live carriers.
    -}
    }

-- | The booted registry: its state output, its mint, no reference outputs.
honestChain :: Chain
honestChain =
    Chain
        { chainNetwork = LP.Network 42
        , chainOutputs = Map.singleton stateIn (stateOutput bootState)
        , chainMints =
            Map.singleton
                token
                LP.MintRecord
                    { LP.mintTransaction = creationTx
                    , LP.mintSpentInputs = [refOf (T.replicate 64 "3" <> "#1"), seedIn]
                    , LP.mintSupply = 1
                    }
        , chainCarriers = const []
        }

{- | A session over the chain. Every read is appended to the log, so a test
can state which reads happened.
-}
chainSession :: IORef [Text] -> Chain -> LP.Session NoWitness IO
chainSession logRef chain =
    stubSession
        { LP.sessionNetwork = chainNetwork chain
        , LP.outputs = \query -> do
            modifyIORef' logRef (<> [T.pack (show query)])
            pure (fmap (`Evidenced` Nothing) (select query))
        , LP.mintRecord = \asset -> do
            modifyIORef' logRef (<> ["mintRecord " <> T.pack (show asset)])
            pure (Right (Evidenced (Map.lookup asset (chainMints chain)) Nothing))
        }
  where
    live = chainOutputs chain
    select = \case
        LP.AtAddress address ->
            Right [u | u@(_, o) <- Map.toAscList live, o ^. addrTxOutL == address]
        LP.HoldingAsset (policy, name) ->
            Right
                [ u
                | u@(_, o) <- Map.toAscList live
                , let MaryValue _ (MultiAsset assets) = o ^. valueTxOutL
                , maybe
                    False
                    ((/= 0) . Map.findWithDefault 0 name)
                    (Map.lookup policy assets)
                ]
        LP.AtTxIn reference -> case Map.lookup reference live of
            Nothing -> Left (LP.MissingOutput reference)
            Just o -> Right [(reference, o)]
        LP.CarryingReferenceScript script -> Right (chainCarriers chain script)
        LP.AnyOf queries ->
            fmap
                (Map.toAscList . Map.fromList . concat)
                (traverse select (NE.toList queries))
        LP.AllOf queries -> do
            found <- traverse select (NE.toList queries)
            pure
                [ u
                | u@(i, _) <- Map.toAscList (Map.fromList (concat found))
                , all (elem i . map fst) found
                ]

refOf :: Text -> TxIn
refOf = either error id . parseOutRef
