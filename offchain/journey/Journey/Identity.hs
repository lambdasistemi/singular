{- |
Module      : Journey.Identity
Description : Which contracts a journey run exercises, pinned and derived
License     : Apache-2.0

At start the journey prints the upstream source revision and the pinned
validator hashes read from @onchain/script-identity.json@. Those pins
are the /unapplied/ blueprint identities — the stable, reviewable
scripts issue #34 enforces — not the hashes a transaction carries. The
request validator takes 2 parameters, so its applied hash differs from
its pin; the state and staking validators take none, so their two
layers coincide.

After the fold, 'stepDerivedIdentity' ties the two layers together
(marker @derived-applied-identity@): each pin must be the hash of the
blueprint code this run loaded, and each applied hash — the unapplied
code with this instance's parameters — must be exactly what the boot and
fold transactions carried to the node, through their witness sets or
the reference outputs they resolved.
-}
module Journey.Identity
    ( ScriptIdentity (..)
    , ValidatorPin (..)
    , readScriptIdentity
    , printIdentity
    , stepDerivedIdentity
    ) where

import Control.Monad (unless)
import Data.Aeson (FromJSON (..), eitherDecode', withObject, (.:))
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BSL
import Data.ByteString.Short (fromShort)
import Data.ByteString.Short qualified as SBS
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Lens.Micro ((^.))

import Cardano.Ledger.Api.Tx (bodyTxL, witsTxL)
import Cardano.Ledger.Api.Tx.Body (referenceInputsTxBodyL)
import Cardano.Ledger.Api.Tx.Out (TxOut, referenceScriptTxOutL)
import Cardano.Ledger.Api.Tx.Wits (scriptTxWitsL)
import Cardano.Ledger.BaseTypes (StrictMaybe (..))
import Cardano.Ledger.Core (hashScript)
import Cardano.Tx.Ledger (ConwayTx)

import Journey.Narration (emit, failWith, hex)
import Singular.Registry.Blueprint (applyRequestParams)
import Singular.Registry.Config (CageConfig (..))
import Singular.Registry.Ledger
    ( AssetName (..)
    , ConwayEra
    , TokenId (..)
    , TxIn
    )
import Singular.Registry.TxBuilder.Internal
    ( computeScriptHash
    , onChainTokenId
    , scriptHashBytes
    )

{- | The pinned identities in @onchain\/script-identity.json@:
the upstream source revision, each validator's parameter
count, and the compiled validator hashes the repository
pins. Those pins are the /unapplied/ blueprint scripts —
the stable, reviewable identity — not the hashes the
transactions of a particular instance carry.
-}
data ScriptIdentity = ScriptIdentity
    { siRevision :: Text
    , siValidators :: [ValidatorPin]
    }

data ValidatorPin = ValidatorPin
    { vpTitle :: Text
    -- ^ Validator title, e.g. @state.state.spend@
    , vpHash :: Text
    -- ^ Unapplied compiled script hash pinned in the manifest
    , vpParameters :: Int
    -- ^ How many parameters the on-chain instance applies
    }

instance FromJSON ValidatorPin where
    parseJSON = withObject "ValidatorPin" $ \o ->
        ValidatorPin
            <$> o .: "title"
            <*> o .: "hash"
            <*> o .: "parameters"

instance FromJSON ScriptIdentity where
    parseJSON = withObject "ScriptIdentity" $ \o ->
        ScriptIdentity
            <$> (o .: "upstream" >>= (.: "source_revision"))
            <*> o .: "validators"

readScriptIdentity :: FilePath -> IO ScriptIdentity
readScriptIdentity path = do
    bytes <- BS.readFile path
    either failWith pure (eitherDecode' (BSL.fromStrict bytes))

printIdentity :: ScriptIdentity -> IO ()
printIdentity si = do
    emit
        "identity"
        ("upstream source revision " <> T.unpack (siRevision si))
    mapM_ one (siValidators si)
  where
    one v =
        emit
            "identity"
            ( "pinned unapplied validator "
                <> T.unpack (vpTitle v)
                <> " hash 0x"
                <> T.unpack (vpHash v)
                <> " (parameters="
                <> show (vpParameters v)
                <> ")"
            )

{- | Assert the derivation between the two identity layers
(marker @derived-applied-identity@).

The manifest pins the /unapplied/ blueprint scripts. Of the
scripts that run on chain only the request validator is
parameterized, with 2 parameters (@statePolicyId@,
@cageToken@); the state and staking validators take none, so
their two layers coincide and their applied hash is the hash
of the raw code. The state line's narration still names
@previousPolicies=[]@ and @(1 parameter)@, kept byte for byte
as existing narration; it is not the state validator's arity,
which the manifest pins as 0. This step

  * requires each pinned unapplied hash to be the hash of
    the blueprint's raw code, so the pinned layer is what
    this run's blueprint actually contains;

  * applies this instance's parameters to the unapplied
    code, hashes the result, and requires it to equal the
    hash of the script the run actually carried to the
    node: the boot transaction carries exactly the
    derived state script in its witness set or through a
    reference output, the update transaction carries
    exactly the derived state and request scripts and the
    three witness policies this registry pins.

Any mismatch fails the run naming both hashes and the
parameters used — the relationship between the layers is a
check, not an assumption.
-}
stepDerivedIdentity
    :: ScriptIdentity
    -> CageConfig
    -> SBS.ShortByteString
    -> SBS.ShortByteString
    -> SBS.ShortByteString
    -> TokenId
    -> ConwayTx
    -> ConwayTx
    -> [(TxIn, TxOut ConwayEra)]
    -> IO ()
stepDerivedIdentity si cfg rawState rawRequest rawStaking tid bootTx updateTx refs = do
    let hashHex = hex . scriptHashBytes
        -- The unapplied layer: the blueprint's raw code hashes.
        unappliedState = hashHex (computeScriptHash rawState)
        unappliedRequest = hashHex (computeScriptHash rawRequest)
        unappliedStaking = hashHex (computeScriptHash rawStaking)
    -- The pinned layer is the unapplied code this run's
    -- blueprint actually contains.
    checkPinnedUnapplied si "state.state" unappliedState
    checkPinnedUnapplied si "request.request" unappliedRequest
    checkPinnedUnapplied si "staking.staking" unappliedStaking
    -- Derivation: apply this instance's parameters to the
    -- unapplied code and hash the result.
    let stateHash = computeScriptHash rawState
        stateHex = hashHex stateHash
        stateParams = "previousPolicies=[]"
        tokenName = let TokenId (AssetName an) = tid in fromShort an
        requestHash =
            computeScriptHash $
                applyRequestParams
                    (scriptHashBytes stateHash)
                    (onChainTokenId tid)
                    rawRequest
        requestHex = hashHex requestHash
        requestParams =
            "statePolicyId=0x"
                <> stateHex
                <> " cageToken=0x"
                <> hex tokenName
    unless (cfgScriptHash cfg == stateHash) $
        failWith $
            "derived-applied-identity failed for state: \
            \derived applied hash 0x"
                <> stateHex
                <> " (parameters "
                <> stateParams
                <> ") but the run's state policy hash is 0x"
                <> hashHex (cfgScriptHash cfg)
    -- The scripts the run actually carried to the node.
    let bootWitness = carriedScriptHashes refs bootTx
        updateWitness = carriedScriptHashes refs updateTx
        pinHex p = hex (SBS.fromShort p)
        -- The fold spends the state and the request and mints under the
        -- three witness policies this registry pins, so those five are
        -- exactly what it carries.
        updateExpected =
            Set.fromList
                ( [stateHex, requestHex]
                    <> map
                        pinHex
                        [ cfgAbsentPolicy cfg
                        , cfgActivePolicy cfg
                        , cfgTerminalPolicy cfg
                        ]
                )
    unless (bootWitness == Set.singleton stateHex) $
        failWith $
            "derived-applied-identity failed for state: \
            \expected the boot transaction to carry exactly \
            \the derived applied hash 0x"
                <> stateHex
                <> " (parameters "
                <> stateParams
                <> ") but the scripts it carried held "
                <> show (Set.toList bootWitness)
    -- #157: the fold withdraws from nothing, so the update transaction
    -- carries exactly the two derived scripts it spends plus the three
    -- witness policies it may mint under — the retired consumer hook is
    -- no longer among them.
    unless (updateWitness == updateExpected) $
        failWith $
            "derived-applied-identity failed for request: \
            \expected the update transaction to carry exactly \
            \the derived applied hashes 0x"
                <> stateHex
                <> " and 0x"
                <> requestHex
                <> " with the three pinned witness policies "
                <> show
                    ( map
                        pinHex
                        [cfgAbsentPolicy cfg, cfgActivePolicy cfg, cfgTerminalPolicy cfg]
                    )
                <> " (request parameters "
                <> requestParams
                <> ") but its script witness held "
                <> show (Set.toList updateWitness)
    emit
        "derived-applied-identity"
        ( "state applied hash 0x"
            <> stateHex
            <> " = unapplied 0x"
            <> unappliedState
            <> " with parameters "
            <> stateParams
            <> " (1 parameter) — the boot tx carried \
               \exactly this script"
        )
    emit
        "derived-applied-identity"
        ( "request applied hash 0x"
            <> requestHex
            <> " = unapplied 0x"
            <> unappliedRequest
            <> " with parameters "
            <> requestParams
            <> " (2 parameters) — the update tx carried \
               \exactly this script"
        )
    emit
        "derived-applied-identity"
        ( "staking applied hash 0x"
            <> unappliedStaking
            <> " takes no parameters (0) — applied and \
               \unapplied coincide, matching the pin"
        )

{- | Require every manifest entry under the validator
prefix to pin exactly @unappliedHex@ — the hash of this
run's blueprint raw code.
-}
checkPinnedUnapplied :: ScriptIdentity -> Text -> String -> IO ()
checkPinnedUnapplied si prefix unappliedHex =
    case pins of
        [] ->
            failWith
                ( "derived-applied-identity: no pinned unapplied \
                  \entry for "
                    <> T.unpack prefix
                )
        (h : rest) ->
            unless (all (== h) rest && h == T.pack unappliedHex) $
                failWith $
                    "derived-applied-identity: the manifest pins \
                    \unapplied hash "
                        <> T.unpack h
                        <> " for "
                        <> T.unpack prefix
                        <> " but this run's blueprint code \
                           \hashes to 0x"
                        <> unappliedHex
  where
    pins =
        [ vpHash v
        | v <- siValidators si
        , prefix `T.isPrefixOf` vpTitle v
        ]

{- | The hashes of the PlutusV3 scripts a submitted
transaction carried in its witness set — the bytes the
node received and executed.
-}
witnessScriptHashes :: ConwayTx -> Set.Set String
witnessScriptHashes tx =
    Set.fromList
        [ hex (scriptHashBytes sh)
        | sh <- Map.keys (tx ^. witsTxL . scriptTxWitsL)
        ]

{- | Every script a transaction carried to the node: the witness set it
attached, plus the reference outputs it resolved through. A fold
resolves every purpose through published references, so its witness set
is empty and the scripts it executed travel in the outputs its body
names.
-}
carriedScriptHashes
    :: [(TxIn, TxOut ConwayEra)] -> ConwayTx -> Set.Set String
carriedScriptHashes refs tx =
    witnessScriptHashes tx
        <> Set.fromList
            [ hex (scriptHashBytes (hashScript s))
            | (i, o) <- refs
            , i `Set.member` (tx ^. bodyTxL . referenceInputsTxBodyL)
            , SJust s <- [o ^. referenceScriptTxOutL]
            ]
