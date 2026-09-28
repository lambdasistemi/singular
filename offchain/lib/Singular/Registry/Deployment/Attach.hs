{- |
Module      : Singular.Registry.Deployment.Attach
Description : Checking a manifest against a node and attaching to it
License     : Apache-2.0

One owner for the deployment family's node decisions: the compiled
release halves a manifest pins only by hash ('CageParts',
'cageConfigFor'), the registry token a seed determines, the resolution
of the recorded reference outputs and the registry's state output, and
the two operations built on them — 'verifyDeployment', which goes on
to read the live state datum and refuse a mismatched active policy or
process\/retract window, and 'attach', which returns the resolved
outputs without those additional checks. Neither operation loads or
compares a mirror; the caller that attaches does that afterwards.

This module is an internal owner behind the 'Singular.Registry.Deployment'
facade: callers import the facade, which re-exports the unchanged public
surface. It reads manifest values, 'parseOutRef', 'renderOutRef',
'hex' and 'die' from "Singular.Registry.Deployment.Manifest" and the
focused identity and lookup adapters from the builder's internal
family.
-}
module Singular.Registry.Deployment.Attach
    ( -- * The release halves the manifest pins only by hash
      CageParts (..)
    , cageConfigFor

      -- * Checking one against a node
    , verifyDeployment

      -- * Attaching a run to one
    , Attached (..)
    , attach
    ) where

import Control.Monad (unless, when)
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Short qualified as SBS
import Data.Text (Text)
import Data.Text qualified as T

import Lens.Micro ((^.))

import Cardano.Ledger.Address (Addr, decodeAddrEither)
import Cardano.Ledger.Api.Tx.In (TxIn (..))
import Cardano.Ledger.Api.Tx.Out (TxOut, referenceScriptTxOutL)
import Cardano.Ledger.BaseTypes (Network (..), StrictMaybe (..))
import Cardano.Ledger.Core (hashScript)

import Singular.Registry.AssetName (deriveAssetName)
import Singular.Registry.Config (CageConfig (..))
import Singular.Registry.Deployment.Manifest
    ( Deployment (..)
    , ReferenceScript (..)
    , die
    , hex
    , parseOutRef
    , renderOutRef
    )
import Singular.Registry.Ledger
    ( AssetName (..)
    , Coin (..)
    , ConwayEra
    , TokenId (..)
    )
import Singular.Registry.Provider qualified as Cage
import Singular.Registry.TxBuilder.Internal.Identity
    ( cageAddrFromCfg
    , cagePolicyIdFromCfg
    , computeScriptHash
    , extractCageDatum
    , scriptHashBytes
    , txInToRef
    )
import Singular.Registry.TxBuilder.Internal.Lookup (findStateUtxo)
import Singular.Registry.Types
    ( CageDatum (..)
    , OnChainTokenState (..)
    , stateActivePolicyBytes
    )

-- ---------------------------------------------------------
-- The release halves the manifest pins only by hash
-- ---------------------------------------------------------

{- | The compiled bytes a release ships. The manifest records their
hashes; the bytes themselves come from the blueprints in hand, so a
manifest can never be used to smuggle in a different validator.
-}
data CageParts = CageParts
    { partsStateBytes :: SBS.ShortByteString
    , partsRequestBytes :: SBS.ShortByteString
    , partsApplicationPolicy :: SBS.ShortByteString
    {- ^ The application policy the registry pins (#157 D-BOOT): the
    naming application script's applied hash for this registry
    identity, read from the partitions' `script-identity.json`.
    -}
    , partsActivePolicy :: SBS.ShortByteString
    -- ^ The active-token policy: `witness(1, registry)` applied.
    , partsAbsentPolicy :: SBS.ShortByteString
    -- ^ The absent-token policy: `witness(0, registry)` applied.
    , partsTerminalPolicy :: SBS.ShortByteString
    -- ^ The terminal-token policy: `witness(2, registry)` applied.
    , partsConsumerScript :: SBS.ShortByteString
    }

{- | The cage configuration a manifest describes: this release's
compiled scripts, with the seed and the economics the deployment was
booted with.

Refuses when the release in hand compiles the state validator to a
different hash than the deployment was made with — the manifest then
belongs to another release and attaching to it would spend against a
registry whose validator this code does not implement.
-}
cageConfigFor :: Deployment -> CageParts -> Either String CageConfig
cageConfigFor dep parts = do
    seedIn <- parseOutRef (depSeedOutRef dep)
    -- The manifest keeps its own vocabulary for the pin it recorded; the
    -- field it names is the one #157 C7 renamed the active policy.
    when
        ( T.pack (hex (SBS.fromShort (partsActivePolicy parts)))
            /= depRepresentativePolicy dep
        )
        $ Left
            "this release's registry-bound active policy differs from the deployment"
    let stateHash = computeScriptHash (partsStateBytes parts)
        stateHex = T.pack (hex (scriptHashBytes stateHash))
    if stateHex /= depStatePolicy dep
        then
            Left
                ( "this release compiles the state validator to 0x"
                    <> T.unpack stateHex
                    <> " but the deployment was made with 0x"
                    <> T.unpack (depStatePolicy dep)
                    <> ": the manifest belongs to another release"
                )
        else
            Right
                CageConfig
                    { cageScriptBytes = partsStateBytes parts
                    , requestScriptBytes = partsRequestBytes parts
                    , cfgScriptHash = stateHash
                    , cageSeed = txInToRef seedIn
                    , defaultProcessTime = depProcessTime dep
                    , defaultRetractTime = depRetractTime dep
                    , defaultTip = Coin (depTip dep)
                    , cfgApplicationPolicy = partsApplicationPolicy parts
                    , cfgActivePolicy = partsActivePolicy parts
                    , cfgAbsentPolicy = partsAbsentPolicy parts
                    , cfgTerminalPolicy = partsTerminalPolicy parts
                    , cfgConsumerScript = partsConsumerScript parts
                    , network = Testnet
                    }

{- | The registry token a seed determines. Derived, never trusted from
the file: the manifest's own claim is checked against it.
-}
tokenFor :: Deployment -> Either String TokenId
tokenFor dep = do
    seedIn <- parseOutRef (depSeedOutRef dep)
    let name = deriveAssetName (txInToRef seedIn)
        nameHex = T.pack (hex name)
    if nameHex /= depCageToken dep
        then
            Left
                ( "the seed "
                    <> T.unpack (depSeedOutRef dep)
                    <> " determines registry token 0x"
                    <> T.unpack nameHex
                    <> " but the manifest records 0x"
                    <> T.unpack (depCageToken dep)
                )
        else Right (TokenId (AssetName (SBS.toShort name)))

-- ---------------------------------------------------------
-- Checking a manifest against a node
-- ---------------------------------------------------------

{- | Ask a node whether it still agrees with a manifest, and return what
it answered, one line per claim.

Every claim is about the chain or about the compiled release, never
about the file restating itself: the seed determines the recorded
token, this release compiles to the recorded state hash, every recorded
reference output is live at its recorded address carrying the hash the
manifest pins, and the registry's state output carries the recorded
token under the recorded policy. The first claim that fails is raised
by name.
-}
verifyDeployment
    :: Cage.Provider IO
    -> Deployment
    -> CageParts
    -> IO [String]
verifyDeployment prov dep parts = do
    cfg <- either die pure (cageConfigFor dep parts)
    tok <- either die pure (tokenFor dep)
    refs <- resolveReferenceScripts prov dep
    (stateIn, stateOut) <- resolveStateUtxo prov cfg tok
    stateLive <- case extractCageDatum stateOut of
        Just (StateDatum st)
            | stateActivePolicyBytes st == SBS.fromShort (partsActivePolicy parts) ->
                pure st
        _ ->
            die
                "the live registry state does not configure this registry-bound representative policy"
    unless
        ( stateProcessTime stateLive == depProcessTime dep
            && stateRetractTime stateLive == depRetractTime dep
        )
        $ die
            ( "the live registry state carries process/retract windows "
                <> show (stateProcessTime stateLive, stateRetractTime stateLive)
                <> " but the manifest records "
                <> show (depProcessTime dep, depRetractTime dep)
            )
    pure
        ( [ "release "
                <> T.unpack (depRelease dep)
                <> " compiles the state validator to the recorded 0x"
                <> T.unpack (depStatePolicy dep)
          , "seed "
                <> T.unpack (depSeedOutRef dep)
                <> " determines the recorded registry token 0x"
                <> T.unpack (depCageToken dep)
          , "compiled representative policy agrees with the manifest and live registry configuration: 0x"
                <> T.unpack (depRepresentativePolicy dep)
          , "registry state carries the recorded request windows: process "
                <> show (depProcessTime dep)
                <> " ms, retract "
                <> show (depRetractTime dep)
                <> " ms"
          ]
            <> [ "reference script "
                    <> T.unpack (refRole r)
                    <> " live at "
                    <> T.unpack (refOutRef r)
                    <> " carrying 0x"
                    <> T.unpack (refHash r)
               | (r, _) <- refs
               ]
            <> [ "registry state output "
                    <> T.unpack (renderOutRef stateIn)
                    <> " carries the recorded token"
               ]
        )

{- | The recorded reference outputs, as the node reports them, checked
one by one against the hash the manifest pins.
-}
resolveReferenceScripts
    :: Cage.Provider IO
    -> Deployment
    -> IO [(ReferenceScript, (TxIn, TxOut ConwayEra))]
resolveReferenceScripts prov dep =
    mapM one (depReferenceScripts dep)
  where
    one r = do
        wanted <- either die pure (parseOutRef (refOutRef r))
        addr <- addrOf r
        utxos <- Cage.queryUTxOs prov addr
        case [u | u@(i, _) <- utxos, i == wanted] of
            [] ->
                die
                    ( "the deployment's "
                        <> T.unpack (refRole r)
                        <> " reference output "
                        <> T.unpack (refOutRef r)
                        <> " is not live at "
                        <> T.unpack (refAddress r)
                        <> ". A reference output that has been spent cannot \
                           \be attached to; the deployment must be made again."
                    )
            ((i, o) : _) -> do
                onChain <- case o ^. referenceScriptTxOutL of
                    SJust s -> pure (T.pack (hex (scriptHashBytes (hashScript s))))
                    SNothing ->
                        die
                            ( "the deployment's "
                                <> T.unpack (refRole r)
                                <> " output "
                                <> T.unpack (refOutRef r)
                                <> " carries no reference script"
                            )
                if onChain == refHash r
                    then pure (r, (i, o))
                    else
                        die
                            ( "the deployment's "
                                <> T.unpack (refRole r)
                                <> " output "
                                <> T.unpack (refOutRef r)
                                <> " carries 0x"
                                <> T.unpack onChain
                                <> " but the manifest pins 0x"
                                <> T.unpack (refHash r)
                            )
    addrOf r = case decodeAddrText (refAddressBytes r) of
        Just a -> pure a
        Nothing ->
            die
                ( "the deployment's "
                    <> T.unpack (refRole r)
                    <> " address is not readable: "
                    <> T.unpack (refAddress r)
                )

-- | The registry's state output, by the token it must carry.
resolveStateUtxo
    :: Cage.Provider IO
    -> CageConfig
    -> TokenId
    -> IO (TxIn, TxOut ConwayEra)
resolveStateUtxo prov cfg tok = do
    let stateAddr = cageAddrFromCfg cfg Testnet
    utxos <- Cage.queryUTxOs prov stateAddr
    case findStateUtxo (cagePolicyIdFromCfg cfg) tok utxos of
        Just u -> pure u
        Nothing ->
            die
                "no output at the registry address carries the recorded \
                \token; the node does not know this deployment (wrong \
                \network, or the registry was never booted here)"

-- ---------------------------------------------------------
-- Attaching
-- ---------------------------------------------------------

-- | What a run gets instead of booting and publishing.
data Attached = Attached
    { attCfg :: CageConfig
    -- ^ The deployed registry's configuration
    , attToken :: TokenId
    -- ^ The deployed registry's token
    , attRefUtxos :: [(TxIn, TxOut ConwayEra)]
    -- ^ The published reference outputs, in manifest order
    , attStateUtxo :: (TxIn, TxOut ConwayEra)
    -- ^ The registry's current state output
    }

{- | Attach a run to a recorded deployment: the release, token and
reference\/state resolution 'verifyDeployment' performs, plus the
resolved outputs a runner needs in hand. The live state's active policy
and windows are not checked here; verification is the operation that
reads them.
-}
attach
    :: Cage.Provider IO
    -> Deployment
    -> CageParts
    -> IO Attached
attach prov dep parts = do
    cfg <- either die pure (cageConfigFor dep parts)
    tok <- either die pure (tokenFor dep)
    refs <- resolveReferenceScripts prov dep
    state <- resolveStateUtxo prov cfg tok
    pure
        Attached
            { attCfg = cfg
            , attToken = tok
            , attRefUtxos = map snd refs
            , attStateUtxo = state
            }

-- ---------------------------------------------------------
-- Small helpers
-- ---------------------------------------------------------

{- | The authoritative address bytes of a recorded reference output.

The bech32 spelling beside it is for the reader; this is what is
queried, because it round-trips through the manifest exactly.
-}
decodeAddrText :: Text -> Maybe Addr
decodeAddrText t = case B16.decode (BC.pack (T.unpack t)) of
    Right raw -> case decodeAddrEither raw of
        Right a -> Just a
        Left _ -> Nothing
    Left _ -> Nothing
