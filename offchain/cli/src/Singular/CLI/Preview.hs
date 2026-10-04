{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.CLI.Preview
Description : @--preview@: build and measure what an entry command would submit, and submit nothing
License     : Apache-2.0

Before anything is written to a public network a reviewer needs the real
numbers: the fee each transaction pays, the execution units the node's own
evaluator measured for it, the collateral it states and the outlay it
asks of the wallet, all under the parameters the selected network reports.
A preview attaches the saved registry to the chain exactly as the writing
command does — identity, network, live references, the state output and the
mirror's root against the ledger's — then builds the same transactions from
the same plan ("Singular.CLI.Plan") and prints them.

It holds no signing key. It names the caller by a public enterprise address,
reads through the read capability alone, one acquired view (`withReads`), and
writes no journal, mirror or registry file. A preview is not a
confirmation: its bodies are built for this moment — a booking carries the
time it was built — and nothing it prints is an observation of a chain
effect.

An insertion or a termination is booked by one transaction and folded by
another, which exists only once the booking is on chain and is built by
`registry fold` (or by the booking command given its fold switch). The
preview measures the booking, and bounds the fold from the network's
parameters; the fold is measured when it is built, after the booking
confirms and before it is signed.
-}
module Singular.CLI.Preview
    ( Kind (..)
    , runPreview
    ) where

import Control.Monad (when)
import Data.Aeson (Value, object, toJSON, (.=))
import Data.Aeson qualified as Aeson
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as BL
import Data.Foldable (toList)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T

import Lens.Micro ((^.))

import Cardano.Crypto.Hash.Blake2b (Blake2b_256)
import Cardano.Crypto.Hash.Class (hashToBytes, hashWith)
import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.Api.PParams (ppCollateralPercentageL)
import Cardano.Ledger.Api.Tx (bodyTxL, sizeTxF, witsTxL)
import Cardano.Ledger.Api.Tx.Body
    ( collateralInputsTxBodyL
    , collateralReturnTxBodyL
    , feeTxBodyL
    , inputsTxBodyL
    , referenceInputsTxBodyL
    , totalCollateralTxBodyL
    )
import Cardano.Ledger.Api.Tx.Out (TxOut, coinTxOutL)
import Cardano.Ledger.Api.Tx.Wits (Redeemers (..), rdmrsTxWitsL)
import Cardano.Ledger.BaseTypes (StrictMaybe (..))
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Plutus.ExUnits (ExUnits (..))
import Cardano.Tx.Ledger (ConwayTx)

import Singular.Application.OpenDatum.Envelope
    ( dataFromJson
    , envelopeToJson
    )
import Singular.CLI.Command
    ( EntryArgs (..)
    , Key (..)
    , NodeSettings (..)
    )
import Singular.CLI.Live
import Singular.CLI.Node (withReads)
import Singular.CLI.Outlay
    ( Outlay (..)
    , bookingOutlay
    , collateralOf
    , collateralOfFee
    , updateOutlay
    )
import Singular.CLI.Plan
import Singular.CLI.Receipt (OutcomeClass (..))
import Singular.CLI.Registry
    ( checkNetwork
    , hexT
    , keyFields
    , parseEnterpriseAddress
    , renderIdentityError
    )
import Singular.CLI.Session (failWith, txIdHex)
import Singular.Registry.Ledger (ConwayEra, PParams)
import Singular.Registry.Provider qualified as Cage
import Singular.Registry.TxBuilder.Edges (bookEdgeMeasured)
import Singular.Registry.TxBuilder.Internal (addrKeyHashBytes)

-- | Which entry command is being prepared.
data Kind = KInsert | KUpdate | KTerminate
    deriving stock (Eq, Show)

kindName :: Kind -> Text
kindName KInsert = "insert"
kindName KUpdate = "update"
kindName KTerminate = "terminate"

{- | Prepare one entry command against the saved registry, for the public
address the caller named, and report what it would submit.
-}
runPreview :: Kind -> EntryArgs -> NodeSettings -> String -> IO Value
runPreview kind a (NodeSettings sock magic) addrText = do
    addr <-
        either
            (failWith ClientRefusal)
            pure
            (parseEnterpriseAddress magic addrText)
    saved <- loadSaved (entryRegistry a) (entryBlueprint a)
    let Key key = entryKey a
        caller = addrKeyHashBytes addr
    -- An insert's envelope is built, and its payload refused if it is not
    -- Plutus data, before the node is read.
    inserted <- case kind of
        KInsert ->
            Just . insertionOf saved a caller <$> readInsertPayload a
        _ -> pure Nothing
    -- One view for the whole preparation: the state, the mirror's root
    -- against it, the wallet, the parameters, the evaluation and the chain
    -- point the report names are all that view's.
    withReads magic sock $ \prov -> Cage.withView prov $ \v -> do
        let pp = Cage.viewProtocolParams v
            point = Cage.viewPoint v
        either
            (failWith ClientRefusal . renderIdentityError)
            pure
            (checkNetwork (savedConfig saved) magic)
        mirror <- openMirror saved
        live <- attachLive v saved
        observed <- either (failWith StaleState) pure (observedRoot live)
        local <- mirrorRoot saved mirror
        when (local /= observed) $
            failWith
                StaleState
                ( "the saved mirror commits to 0x"
                    <> T.unpack (hexT local)
                    <> " but the ledger holds 0x"
                    <> T.unpack (hexT observed)
                    <> ": stale, concurrent or altered local state is refused, \
                       \never repaired"
                )
        requireMirrorSelection saved live mirror
        prepared <- case kind of
            KInsert -> do
                envelope <-
                    maybe (failWith ClientRefusal "insert has no envelope") pure inserted
                booked <- planInsert live envelope
                (<> [("envelope", envelopeToJson envelope)])
                    <$> previewBooking a v live addr key booked
            KTerminate -> do
                outs <- liveOutputs v saved
                (booked, _, _) <- planTerminate live caller key outs
                previewBooking a v live addr key booked
            KUpdate -> do
                payload <- document "update needs --payload" dataFromJson
                outs <- liveOutputs v saved
                (holding, _) <- planUpdate live caller key outs
                tx <- buildUpdate v live addr (entryFund a) holding payload
                let outlay = updateOutlay tx
                refuseOver (entryMaxOutlay a) outlay
                pure
                    [ ("update", bodyReport pp tx)
                    , ("outlay", outlayReport (entryMaxOutlay a) outlay)
                    ]
        pure $
            receipt
                (kindName kind)
                Success
                ( [("preview", toJSON True)]
                    <> keyFields key
                    <> [ ("networkMagic", toJSON magic)
                       , ("caller", callerReport addrText caller)
                       , ("stateRoot", toJSON (hexT observed))
                       , ("chainPoint", toJSON (pointText point))
                       , ("protocolParameters", parametersDigest pp)
                       ]
                    <> prepared
                )
  where
    document :: String -> (Aeson.Value -> Either String b) -> IO b
    document missing parse = do
        path <- maybe (failWith ClientRefusal missing) pure (entryDocument a)
        readJson path >>= either (failWith ClientRefusal) pure . parse

{- | Build the booking exactly as the writing command will — measured,
collateralised, funded from the chosen or the largest ada-only output — and
report it beside the bound on the fold that follows.
-}
previewBooking
    :: EntryArgs
    -> Cage.View IO
    -> Live
    -> Addr
    -> ByteString
    -> Booked
    -> IO [(Text, Value)]
previewBooking a v live addr key b = do
    let s = liveSaved live
        cfg = savedCfg s
        pp = Cage.viewProtocolParams v
    booking <-
        bookEdgeMeasured
            cfg
            v
            addr
            (savedToken s)
            key
            (bookedEdge b)
            (bookedDestination b)
            (bookedDeposit b)
            (bookedApproval b)
            (liveRefs live)
            (entryFund a)
    let outlay = bookingOutlay pp (liveRefs live) booking
    refuseOver (entryMaxOutlay a) outlay
    pure
        [ ("booking", bodyReport pp booking)
        , ("fold", foldBound pp live outlay)
        , ("outlay", outlayReport (entryMaxOutlay a) outlay)
        ]

-- | The caller, by the public address named and the key hash it carries.
callerReport :: String -> ByteString -> Value
callerReport addrText caller =
    object
        [ "address" .= addrText
        , "paymentKeyHash" .= hexT caller
        ]

-- | What one built transaction states, read from its body.
bodyReport :: PParams ConwayEra -> ConwayTx -> Value
bodyReport pp tx =
    object
        [ "txId" .= txIdHex tx
        , "sizeBytes" .= (tx ^. sizeTxF)
        , "fee" .= lovelace (tx ^. bodyTxL . feeTxBodyL)
        , "inputs" .= inputsOf (tx ^. bodyTxL . inputsTxBodyL)
        , "referenceInputs" .= inputsOf (tx ^. bodyTxL . referenceInputsTxBodyL)
        , "purposes"
            .= [ object
                    [ "purpose" .= show purpose
                    , "memory" .= toInteger mem
                    , "steps" .= toInteger steps
                    ]
               | (purpose, (_, ExUnits mem steps)) <- Map.toList redeemers
               ]
        , "collateral"
            .= object
                [ "inputs" .= inputsOf (tx ^. bodyTxL . collateralInputsTxBodyL)
                , "total" .= declared (tx ^. bodyTxL . totalCollateralTxBodyL)
                , "return" .= returned (tx ^. bodyTxL . collateralReturnTxBodyL)
                , "exposure" .= collateralOf pp tx
                ]
        ]
  where
    Redeemers redeemers = tx ^. witsTxL . rdmrsTxWitsL
    inputsOf = map txInText . toList
    declared (SJust c) = Just (lovelace c)
    declared SNothing = Nothing
    returned :: StrictMaybe (TxOut ConwayEra) -> Maybe Integer
    returned (SJust o) = Just (lovelace (o ^. coinTxOutL))
    returned SNothing = Nothing

lovelace :: Coin -> Integer
lovelace (Coin c) = c

-- | The bound on the fold that follows a booking, and why it is only a bound.
foldBound :: PParams ConwayEra -> Live -> Outlay -> Value
foldBound pp live outlay =
    object
        [ "status"
            .= ( "measured when the fold is built, after the booking confirms and \
                 \before it is signed; bounded here from the network's parameters"
                    :: Text
               )
        , "feeBound" .= outlayFoldBound outlay
        , "collateralBound" .= collateralOfFee pp (outlayFoldBound outlay)
        , "boundedBy"
            .= ( "a transaction of the maximum size carrying the maximum \
                 \execution units and the reference scripts the fold reads"
                    :: Text
               )
        , "referenceScriptOutputs" .= length (liveRefs live)
        ]

-- | The view's chain point, as the other commands print it: slot, a dot, the block hash.
pointText :: Cage.ChainPoint -> Text
pointText p =
    T.pack (show (Cage.unSlotNo (Cage.cpSlot p)))
        <> "."
        <> hexT (Cage.cpBlockHash p)

{- | A digest of the parameters the bodies were built under, so a later
reader can tell whether they moved: BLAKE2b-256 of their JSON.
-}
parametersDigest :: PParams ConwayEra -> Value
parametersDigest pp =
    object
        [ "blake2b256"
            .= hexT
                ( hashToBytes
                    (hashWith @Blake2b_256 id (BL.toStrict (Aeson.encode pp)))
                )
        , "collateralPercentage" .= toInteger (pp ^. ppCollateralPercentageL)
        ]
