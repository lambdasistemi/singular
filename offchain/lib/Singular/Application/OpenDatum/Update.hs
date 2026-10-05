{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.Application.OpenDatum.Update
Description : The controller's payload update of a live open-datum output
License     : Apache-2.0

A payload update spends the key's live output with @Update@ and
recreates it: same address, same value, same control, a new payload. The
controller is the required signer. Nothing in the registry moves, so the
registry root stays where it was.

The builder refuses, before anything is built, a live output that does
not carry the envelope it is told to update or does not hold its key's
one active token: submitting either would only earn the script's
refusal, and the command reports the builder's reason instead.
-}
module Singular.Application.OpenDatum.Update
    ( UpdateArgs (..)
    , updatePayloadTx
    , continuationOf
    , updateRedeemer
    , releaseRedeemer
    ) where

import Data.Aeson ((.=))
import Data.ByteString.Short qualified as SBS
import Data.Text (Text)
import Data.Void (Void)
import Lens.Micro ((&), (.~))

import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.Api.Tx.Out (TxOut, datumTxOutL)
import Cardano.Tx.Build qualified as Tx
import Cardano.Tx.Ledger (ConwayTx)
import PlutusCore.Data qualified as PLC

import Singular.Application.OpenDatum.Envelope
    ( Control (..)
    , Envelope (..)
    , envelopeToData
    )
import Singular.Application.OpenDatum.Release (heldOf, liveEnvelope)
import Singular.Registry.Ledger (ConwayEra, TxIn)
import Singular.Registry.PhaseLog (phaseLogFromEnv, timedPhase)
import Singular.Registry.Provider (View (..))
import Singular.Registry.TxBuilder.ConnectedFold (RawRedeemer (..))
import Singular.Registry.TxBuilder.Internal
    ( addrWitnessKeyHash
    , mkInlineDatum
    , scriptFromBytes
    )
import Singular.Registry.TxBuilder.Update.Build (NoCtx, mkEvalTx)

-- | @Update@: the first constructor of @OpenDatumSpend@.
updateRedeemer :: RawRedeemer
updateRedeemer = RawRedeemer (PLC.Constr 0 [])

-- | @Release@: the second constructor of @OpenDatumSpend@.
releaseRedeemer :: RawRedeemer
releaseRedeemer = RawRedeemer (PLC.Constr 1 [])

-- | What one payload update needs in hand.
data UpdateArgs = UpdateArgs
    { uaView :: View IO
    {- ^ The view the update is built from: its parameters, its script
    evaluation
    -}
    , uaApplied :: SBS.ShortByteString
    -- ^ The applied open-datum script
    , uaHolding :: (TxIn, TxOut ConwayEra)
    -- ^ The key's live output
    , uaPayload :: PLC.Data
    -- ^ The new payload; any Plutus data
    , uaFee :: (TxIn, TxOut ConwayEra)
    -- ^ The controller's ada-only output: fee and collateral
    , uaChange :: Addr
    , uaReference :: Maybe (TxIn, TxOut ConwayEra)
    {- ^ An output carrying the applied script as a reference script;
    without one the script is attached
    -}
    }

{- | The live output's successor: the same address and value, the same
control, the new payload.
-}
continuationOf
    :: TxOut ConwayEra -> Envelope -> PLC.Data -> TxOut ConwayEra
continuationOf out e payload =
    out
        & datumTxOutL .~ mkInlineDatum (envelopeToData e{envPayload = payload})

{- | The unsigned update. Refuses a live output whose inline datum is not
an envelope, or that does not hold exactly one of its key's active
token.
-}
updatePayloadTx :: UpdateArgs -> IO (Either String ConwayTx)
updatePayloadTx args = do
    lg <- phaseLogFromEnv
    timedPhase
        lg
        "build-body"
        ["builder" .= ("updatePayloadTx" :: Text)]
        (either (const ["outcome" .= ("refused" :: Text)]) (const []))
        (updateBody args)

-- | The update, unlogged.
updateBody :: UpdateArgs -> IO (Either String ConwayTx)
updateBody args = case liveEnvelope (snd (uaHolding args)) of
    Left why -> pure (Left why)
    Right e -> do
        let c = envControl e
            out = snd (uaHolding args)
        if heldOf c out /= 1
            then
                pure
                    ( Left
                        ( "the live output holds "
                            <> show (heldOf c out)
                            <> " of its key's active token, not exactly one"
                        )
                    )
            else do
                let next = continuationOf out e (uaPayload args)
                    script = scriptFromBytes "open-datum" (uaApplied args)
                    prog :: Tx.TxBuild NoCtx Void ()
                    prog = do
                        _ <- Tx.spendScript (fst (uaHolding args)) updateRedeemer
                        _ <- Tx.output next
                        Tx.requireSignature (addrWitnessKeyHash (ctlController c))
                        case uaReference args of
                            Just (ref, _) -> Tx.reference ref
                            Nothing -> Tx.attachScript script
                        Tx.collateral (fst (uaFee args))
                result <-
                    Tx.build
                        (Tx.mkPParamsBound (viewProtocolParams (uaView args)))
                        (Tx.InterpretIO (const (pure undefined)))
                        (mkEvalTx (uaView args))
                        [uaFee args, uaHolding args]
                        (maybe [] pure (uaReference args))
                        (uaChange args)
                        prog
                pure
                    (either (Left . ("the update did not build: " <>) . show) Right result)
