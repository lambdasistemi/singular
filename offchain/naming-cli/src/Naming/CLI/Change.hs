{-# LANGUAGE LambdaCase #-}

{- |
Module      : Naming.CLI.Change
Description : User-selected maintenance and controller recovery
License     : Apache-2.0

The node evaluates every script purpose and the generic builder balances
the transaction. Datum and asset continuations come from the selected
record; no test actor, fee, execution budget or deployment is introduced.
-}
module Naming.CLI.Change (runChange) where

import Codec.Binary.Bech32 qualified as Bech32
import Control.Monad (unless)
import Data.Aeson (Value, object, (.=))
import Data.ByteString qualified as BS
import Data.List (sortOn)
import Data.Map.Strict qualified as Map
import Data.Ord (Down (..))
import Data.Text qualified as T
import Data.Void (Void)
import Lens.Micro ((&), (.~), (^.))
import PlutusCore.Data qualified as PLC
import System.Environment (getEnv)

import Cardano.Ledger.Api.Tx (txIdTx)
import Cardano.Ledger.Api.Tx.Out (coinTxOutL, datumTxOutL, valueTxOutL)
import Cardano.Ledger.Mary.Value (MaryValue (..))
import Cardano.Node.Client.E2E.Setup (addKeyWitness)
import Cardano.Node.Client.Submitter (SubmitResult (..), Submitter (..))
import Cardano.Tx.Build qualified as Tx

import Naming.CLI.Options (Connection (..), RecordChange (..))
import Naming.CLI.Read (failWith, hex, loadParts, lookupName, recordAt, unhex, validateAttached)
import Naming.Datum (NamingDatum (..), PaymentDestination (..), decodeNamingDatum, encodeNamingDatum)
import Naming.Wire (Address (..), WireData (..), decodeAddress)
import Singular.Registry.Blueprint (extractCompiledCode, loadBlueprint)
import Singular.Registry.Deployment (Attached (..), Deployment (..), attach, readDeployment, renderOutRef)
import Singular.Registry.Node (ExternalNode (..), NodeMode (..), NodeSession (..), Wallet (..), awaitTx, loadWallet, withNodeMode)
import Singular.Registry.Provider qualified as Cage
import Singular.Registry.TxBuilder.ConnectedFold (RawRedeemer (..))
import Singular.Registry.TxBuilder.Internal (addrKeyHashBytes, addrWitnessKeyHash, mkInlineDatum, scriptFromBytes)

-- | A closed transaction program needs no external query language.
data NoCtx a

runChange :: Connection -> FilePath -> String -> FilePath -> RecordChange -> IO Value
runChange conn payerFile name controllerFile change = do
    dep <- readDeployment (deploymentFile conn)
    unless (networkMagic conn == depNetworkMagic dep) $
        failWith "network-mismatch: requested magic differs from the deployment"
    parts <- loadParts dep
    payer <- loadWallet (networkMagic conn) payerFile
    controller <- loadWallet (networkMagic conn) controllerFile
    blueprint <- either failWith pure =<< loadBlueprint =<< getEnv "NAMING_BLUEPRINT"
    appBytes <-
        maybe (failWith "blueprint missing application.application") pure $
            extractCompiledCode "application.application" blueprint
    let script = scriptFromBytes "naming-application" appBytes
        mode = External (ExternalNode (nodeSocket conn) (networkMagic conn) payerFile)
    withNodeMode mode $ \session -> do
        let provider = nsProvider session
        attached <- attach provider dep parts
        validateAttached dep attached
        (_, entry) <- lookupName attached (deploymentFile conn) name
        representative <- case entry of
            Just bytes | BS.length bytes == 32 -> pure bytes
            _ -> failWith "name-not-active: no live representative for this name"
        record <- recordAt provider dep (attCfg attached) representative
        ((recordIn, recordOut), current) <- maybe (failWith "record-unavailable: name has no live application output") pure record
        (successor, redeemer) <- case change of
            Maintain destination -> do
                payment <- maybe (pure NoDestination) (fmap SomeDestination . address) destination
                pure (current{paymentDestination = payment}, PLC.Constr 0 [])
            Recover revealed fresh -> do
                next <- address revealed
                commitment <- unhex (T.pack fresh)
                registry <- unhex (depApplicationHash dep)
                pure
                    ( current{controlAddress = next, nextControlCommitment = commitment}
                    , PLC.Constr 4 [PLC.B (addressBytes next), PLC.List [PLC.B representative], PLC.B registry]
                    )
        unless (decodeNamingDatum (encodeNamingDatum successor) == Just successor) $
            failWith "invalid-successor-datum: address, commitment or quorum violates the naming codec"
        utxos <- Cage.queryUTxOs provider (walletAddr payer)
        funding <- case sortOn
            (Down . (^. coinTxOutL) . snd)
            [u | u@(_, out) <- utxos, let MaryValue _ assets = out ^. valueTxOutL, assets == mempty] of
            [] -> failWith "funding-unavailable: fee wallet needs an ADA-only output for collateral"
            first : _ -> pure first
        let continuation = recordOut & datumTxOutL .~ mkInlineDatum (toData (encodeNamingDatum successor))
            signer = addrWitnessKeyHash (addrKeyHashBytes (walletAddr controller))
            program = do
                _ <- Tx.spendScript recordIn (RawRedeemer redeemer)
                _ <- Tx.output continuation
                Tx.requireSignature signer
                Tx.collateral (fst funding)
                Tx.attachScript script
            evaluate tx = Map.map (either (Left . show) Right) <$> Cage.evaluateTx provider tx
        built <-
            Tx.build
                (Tx.mkPParamsBound (nsPParams session))
                (Tx.InterpretIO (\_ -> failWith "unexpected transaction context query"))
                evaluate
                [funding, (recordIn, recordOut)]
                []
                (walletAddr payer)
                (program :: Tx.TxBuild NoCtx Void ())
        unsigned <- either (failWith . ("transaction-build-refused: " <>) . show) pure built
        let signed = addKeyWitness (walletSignKey controller) (addKeyWitness (walletSignKey payer) unsigned)
        result <- submitTx (nsSubmitter session) signed
        case result of
            Rejected reason -> failWith ("transaction-refused: " <> show reason)
            Submitted _ -> awaitTx signed
        confirmed <- recordAt provider dep (attCfg attached) representative
        case confirmed of
            Just ((newRef, _), actual)
                | actual == successor && newRef /= recordIn ->
                    pure $
                        object
                            [ "status" .= ("confirmed" :: String)
                            , "name" .= name
                            , "transaction" .= show (txIdTx signed)
                            , "recordInput" .= renderOutRef newRef
                            , "representative" .= hex representative
                            ]
            _ -> failWith "confirmation-mismatch: submitted record continuation not observed"

address :: String -> IO Address
address raw = do
    (_, payload) <- either (failWith . ("invalid-bech32-address: " <>) . show) pure (Bech32.decodeLenient (T.pack raw))
    bytes <- maybe (failWith "invalid-address-payload") pure (Bech32.dataPartToBytes payload)
    maybe (failWith "unsupported-naming-address") pure (decodeAddress bytes)

toData :: WireData -> PLC.Data
toData (Constr n fields) = PLC.Constr (toInteger n) (map toData fields)
toData (WBytes bytes) = PLC.B bytes
toData (WInt n) = PLC.I n
toData (WList fields) = PLC.List (map toData fields)
