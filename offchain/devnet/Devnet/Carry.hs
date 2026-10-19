{- |
Module      : Devnet.Carry
Description : Harness-only setup: a wallet with no ada-only output
License     : Apache-2.0

A test-harness step, never a product command and never booking
evidence. A journey that needs a wallet holding no ada-only output,
so that its next booking has to make one by a preparation, used to
reach that shape through a retired product action. This builds the
shape directly: one transaction spends every ada-only output of the
wallet, mints one unit each of two asset kinds under a native policy
that only the wallet's own key can satisfy, and pays two outputs back
to the same address, each carrying one of the kinds. An output that
already carries an asset or a reference script is not spent, so
nothing else the wallet holds moves.

The receipt it writes says plainly that this is setup.
-}
module Devnet.Carry (carryWallet) where

import Cardano.Ledger.Address (Addr (..))
import Cardano.Ledger.Api.Tx (mkBasicTx, txIdTx, witsTxL)
import Cardano.Ledger.Api.Tx.Body
    ( feeTxBodyL
    , inputsTxBodyL
    , mintTxBodyL
    , mkBasicTxBody
    , outputsTxBodyL
    )
import Cardano.Ledger.Api.Tx.Out
    ( TxOut
    , addrTxOutL
    , coinTxOutL
    , mkBasicTxOut
    )
import Cardano.Ledger.Api.Tx.Wits (scriptTxWitsL)
import Cardano.Ledger.Core (EraScript (..), hashScript)
import Cardano.Ledger.Credential (Credential (..))
import Cardano.Ledger.Keys (asWitness)
import Cardano.Ledger.Mary.Value
    ( AssetName (..)
    , MaryValue (..)
    , MultiAsset (..)
    , PolicyID (..)
    )
import Cardano.Ledger.Shelley.Scripts (ShelleyEraScript (..))
import Control.Monad (unless, when)
import Data.Aeson (encode, object, (.=))
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as LBS
import Data.ByteString.Short qualified as SBS
import Data.Map.Strict qualified as Map
import Data.Sequence.Strict qualified as StrictSeq
import Data.Set qualified as Set
import Data.Text (Text)
import Lens.Micro ((&), (.~), (^.))
import Singular.Provider.Koios.Wire
    ( assetNameHex
    , policyHex
    , txIdHex
    )
import Singular.Registry.Capabilities (Capabilities (..))
import Singular.Registry.Evidence (NoWitness)
import Singular.Registry.Ledger (Coin (..), ConwayEra)
import Singular.Registry.LedgerProvider (SubmitResult (..))
import Singular.Registry.SessionIO qualified as Session
import Singular.Registry.Signing (signTx, signedTx)
import Singular.Registry.TxBuilder.Edges (adaOnlyOut)
import Singular.Registry.Wallet (Wallet (..))
import System.Exit (die)
import System.IO (hPutStrLn, stderr)

-- | What the receipt calls this step.
setupLabel :: Text
setupLabel = "harness-mint"

-- | The warning the receipt carries.
setupNote :: Text
setupNote = "harness setup only, never booking evidence"

-- | The two asset kinds, as asset names under the one policy.
kindA, kindB :: AssetName
kindA = AssetName (SBS.toShort (BC.pack "setup-a"))
kindB = AssetName (SBS.toShort (BC.pack "setup-b"))

-- | Why the wallet cannot be carried.
tooLittle :: Integer -> String
tooLittle held =
    "devnet carry: the wallet's ada-only outputs hold "
        <> show held
        <> " lovelace, too little for a fee and two outputs"

-- | One unit of an asset under the policy.
oneOf :: PolicyID -> AssetName -> MultiAsset
oneOf policy kind =
    MultiAsset (Map.singleton policy (Map.singleton kind 1))

-- | An output of the address holding lovelace and one asset unit.
carrying
    :: Addr
    -> PolicyID
    -> AssetName
    -> Integer
    -> TxOut ConwayEra
carrying address policy kind lovelace =
    mkBasicTxOut
        address
        (MaryValue (Coin lovelace) (oneOf policy kind))

{- | Leave the wallet with two outputs that each carry one of two
asset kinds, and write the setup receipt. The wallet's ada-only
outputs are the only inputs; the first new output holds a fixed
10 000 000 lovelace and the second the rest, less a flat fee of
1 000 000. These amounts are a fixture choice for the development
network, not a ledger rule.
-}
carryWallet
    :: Capabilities NoWitness IO
    -> Wallet
    -> FilePath
    -> IO ()
carryWallet caps wallet receipt = do
    let address = walletAddr wallet
    owned <-
        Session.withLatest
            (capReads caps)
            (`Session.outputsAt` address)
    let spendable =
            [ (ref, out)
            | (ref, out) <- owned
            , out ^. addrTxOutL == address
            , adaOnlyOut out
            ]
    when (null spendable) $
        die "devnet carry: the wallet holds no ada-only output"
    keyHash <- case address of
        Addr _ (KeyHashObj key) _ -> pure (asWitness key)
        _ ->
            die "devnet carry: the wallet address is not a key address"
    let held =
            sum
                [ lovelace
                | (_, out) <- spendable
                , let Coin lovelace = out ^. coinTxOutL
                ]
        fee = 1_000_000 :: Integer
        first = 10_000_000 :: Integer
        rest = held - fee - first
    unless (rest >= first) $ die (tooLittle held)
    let script =
            fromNativeScript @ConwayEra
                (mkRequireSignature @ConwayEra keyHash)
        policy = PolicyID (hashScript @ConwayEra script)
        minted = oneOf policy kindA <> oneOf policy kindB
        outs =
            [ carrying address policy kindA first
            , carrying address policy kindB rest
            ]
        body =
            mkBasicTxBody
                & inputsTxBodyL .~ Set.fromList (map fst spendable)
                & outputsTxBodyL .~ StrictSeq.fromList outs
                & mintTxBodyL .~ minted
                & feeTxBodyL .~ Coin fee
        scripts = Map.singleton (hashScript @ConwayEra script) script
        unsigned =
            mkBasicTx body & witsTxL . scriptTxWitsL .~ scripts
        signed = signTx (walletSignKey wallet) unsigned
    result <- capSubmit caps signed
    case result of
        SubmitAccepted _ -> pure ()
        refusal ->
            die ("devnet carry: setup rejected: " <> show refusal)
    capConfirm caps (signedTx signed)
    LBS.writeFile receipt . (<> "\n") . encode $
        object
            [ "setup" .= setupLabel
            , "note" .= setupNote
            , "transaction" .= txIdHex (txIdTx (signedTx signed))
            , "policy" .= policyHex policy
            , "kinds" .= [assetNameHex kindA, assetNameHex kindB]
            , "spent" .= length spendable
            , "fee" .= fee
            ]
    hPutStrLn stderr $
        "devnet carry: " <> show setupNote
