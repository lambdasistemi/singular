{- |
Module      : UpdateTerminal.Steps
Description : Book a key active, then retire it, reading each phase back
License     : Apache-2.0

The story's own two folds, at one key, in the story registry:

1. the prerequisite @insertActive@, EXECUTED rather than fabricated: the
   token the retirement destroys is the token this fold created, and a
   fixture dropped into the final state would evidence nothing about the
   transition;
2. the @updateTerminal@ under test, at the SAME key, in the same session.

'retireStoryKey' records, around them, the mirror's root before the
insert, after it and after the retirement, the wallet's active holding
before and after, the exact wallet input carrying the witness (read
BEFORE the burn spends it), and the committed root on chain.

The readers 'mintedActive' and 'bootObservation' compute their fields
from the transactions themselves.
-}
module UpdateTerminal.Steps
    ( storyKey
    , Retirement (..)
    , retireStoryKey
    , mintedActive
    , bootObservation
    ) where

import Data.Aeson (Value, object, (.=))
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as BL
import Data.ByteString.Short qualified as SBS
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Lens.Micro ((^.))

import Cardano.Ledger.Api.Tx (bodyTxL, witsTxL)
import Cardano.Ledger.Api.Tx.Body
    ( mintTxBodyL
    , referenceInputsTxBodyL
    )
import Cardano.Ledger.Api.Tx.Wits (scriptTxWitsL)
import Cardano.Ledger.Binary (serialize)
import Cardano.Ledger.Core (eraProtVerHigh, valueTxOutL)
import Cardano.Ledger.Mary.Value (MaryValue (..), MultiAsset (..))
import Cardano.Ledger.TxIn (txInToText)
import Cardano.Node.Client.E2E.Setup (genesisAddr)
import Cardano.Tx.Ledger (ConwayTx)

import Singular.Registry.Config (CageConfig (..))
import Singular.Registry.Ledger (AssetName (..), ConwayEra, Root)
import Singular.Registry.Provider qualified as Cage
import Singular.Registry.TxBuilder.Internal (policyIdFromPin)
import UpdateTerminal.Narration (die, hex, say)
import UpdateTerminal.Registry
    ( Registry (..)
    , Session (sessProvider)
    , book
    , committedRoot
    , foldAndMirror
    , insertOp
    , retireOp
    , rootNow
    )

-- | The key the documented run books and then retires.
storyKey :: ByteString
storyKey = "update-terminal-demo"

-- | What the story's insert and retirement did, read back.
data Retirement = Retirement
    { retInsertTx :: ConwayTx
    , retRetireTx :: ConwayTx
    , retRootBeforeInsert :: Root
    , retRootActive :: Root
    , retRootTerminal :: Root
    , retHeldBefore :: Integer
    , retHeldAfter :: Integer
    , retSource :: Value
    -- ^ The wallet input that carried the witness, read before the burn
    , retChainRoot :: ByteString
    -- ^ The registry's committed root after the retirement
    }

-- | Insert the story's key active, then retire it, in this registry.
retireStoryKey :: Registry -> IO Retirement
retireStoryKey story = do
    let cfg = regCfg story
    rootBeforeInsert <- rootNow story
    book story storyKey insertOp
    insertTx <- foldAndMirror story storyKey insertOp
    rootActive <- rootNow story
    heldBefore <- activeHeldAt story cfg storyKey
    say
        ( "active tokens at the named wallet after the insert: "
            <> show heldBefore
        )

    -- The exact input the burn will consume, recorded BEFORE it is
    -- spent: the wallet UTxO carrying this key's one active witness.
    source <- activeSourceOf story cfg storyKey

    -- The edge under test, at the same key, in the same session. This
    -- retirement is also the ACCEPTING CONTROL for the Absent refusal:
    -- same registry, same builder, and the only thing that differs
    -- there is the leaf.
    book story storyKey retireOp
    retireTx <- foldAndMirror story storyKey retireOp
    rootTerminal <- rootNow story
    heldAfter <- activeHeldAt story cfg storyKey
    chainRoot <- committedRoot story
    say
        ( "active tokens at the named wallet after the retirement: "
            <> show heldAfter
        )
    pure
        Retirement
            { retInsertTx = insertTx
            , retRetireTx = retireTx
            , retRootBeforeInsert = rootBeforeInsert
            , retRootActive = rootActive
            , retRootTerminal = rootTerminal
            , retHeldBefore = heldBefore
            , retHeldAfter = heldAfter
            , retSource = source
            , retChainRoot = chainRoot
            }

-- | Exactly the quantity held under the ACTIVE policy at this key.
activeHeldAt :: Registry -> CageConfig -> ByteString -> IO Integer
activeHeldAt reg cfg key = do
    walletUtxos <-
        Cage.queryUTxOs (sessProvider (regSession reg)) genesisAddr
    let policy = policyIdFromPin (cfgActivePolicy cfg)
    pure $
        sum
            [ q
            | (_, out) <- walletUtxos
            , let MaryValue _ (MultiAsset ma) = out ^. valueTxOutL
            , (p, names) <- Map.toList ma
            , p == policy
            , (AssetName n, q) <- Map.toList names
            , SBS.fromShort n == key
            ]

{- | The wallet UTxO carrying this key's active witness, by outref and
quantity, read off the chain before the retirement spends it.
-}
activeSourceOf :: Registry -> CageConfig -> ByteString -> IO Value
activeSourceOf reg cfg key = do
    walletUtxos <-
        Cage.queryUTxOs (sessProvider (regSession reg)) genesisAddr
    let policy = policyIdFromPin (cfgActivePolicy cfg)
        carriers =
            [ (txIn, q)
            | (txIn, out) <- walletUtxos
            , let MaryValue _ (MultiAsset ma) = out ^. valueTxOutL
            , (p, names) <- Map.toList ma
            , p == policy
            , (AssetName n, q) <- Map.toList names
            , SBS.fromShort n == key
            ]
    case carriers of
        [(txIn, q)] ->
            pure $
                object
                    [ "outref" .= txInToText txIn
                    , "policy" .= hex (SBS.fromShort (cfgActivePolicy cfg))
                    , "name" .= hex key
                    , "quantity" .= q
                    ]
        _ ->
            die
                ( "the wallet does not hold exactly one carrier of this key's \
                  \active witness: "
                    <> show (length carriers)
                )

{- | Everything the transaction moves under the ACTIVE policy, by key.
The policy comes from the booted config, so a burn under another policy
is absent here rather than silently counted.
-}
mintedActive :: ConwayTx -> CageConfig -> [Value]
mintedActive tx cfg =
    let MultiAsset ma = tx ^. bodyTxL . mintTxBodyL
        policy = policyIdFromPin (cfgActivePolicy cfg)
    in  [ object
            [ "policy" .= hex (SBS.fromShort (cfgActivePolicy cfg))
            , "name" .= hex (SBS.fromShort n)
            , "quantity" .= q
            ]
        | (p, names) <- Map.toList ma
        , p == policy
        , (AssetName n, q) <- Map.toList names
        ]

{- | What the BOOT transaction carries (#177 A-003).

The retirement guard grew the state validator past what a boot
transaction carrying it inline can hold. The repair was to reference the
published script instead, and this is the observation that says so: the
transaction's own serialized size, how many scripts ride in its witness
set, and how many reference inputs it resolves through.

`stateScriptInline` is the fact under test. It is computed from the
transaction, not asserted about it: the state script's hash is looked
for among the witnesses actually attached.
-}
bootObservation :: CageConfig -> ConwayTx -> Value
bootObservation cfg tx =
    object
        [ "bytes"
            .= ( fromIntegral (BL.length (serialize (eraProtVerHigh @ConwayEra) tx))
                    :: Integer
               )
        , "inlineScripts"
            .= (fromIntegral (Map.size (tx ^. witsTxL . scriptTxWitsL)) :: Integer)
        , "referenceInputs"
            .= ( fromIntegral (Set.size (tx ^. bodyTxL . referenceInputsTxBodyL))
                    :: Integer
               )
        , "stateScriptInline"
            .= Map.member (cfgScriptHash cfg) (tx ^. witsTxL . scriptTxWitsL)
        ]
