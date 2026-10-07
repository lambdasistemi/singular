{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NumericUnderscores #-}

{- |
Module      : Singular.Registry.StateToken
Description : A registry joined from its state token and the release
License     : Apache-2.0

A registry is its state token and the release that made it. Everything a
command needs — the seed, the state output and its datum, the pinned
configuration, and the hashes of the six scripts the registry runs — is
derived from those two and checked against the chain, refused by name
when the chain disagrees with the release. Nothing is read from disk.

Reference outputs are a convenience found by hash: any live output whose
reference script hashes to an expected hash serves, whoever made it. The
hash is computed here from the output's own script; a hash a provider
states is never read.
-}
module Singular.Registry.StateToken
    ( -- * The release
      Release (..)

      -- * The state token
    , parseStateToken
    , renderStateToken

      -- * Reference roles and the hashes they must carry
    , ReferenceRole (..)
    , roleName
    , parseRole
    , expectedReferences

      -- * Resolving a token into a registry
    , ResolvedRegistry (..)
    , PinField (..)
    , IdentityRefusal (..)
    , resolveRegistry
    , renderIdentityRefusal

      -- * References found by hash
    , ReferenceRefusal (..)
    , carriesReference
    , findReferences
    , renderReferenceRefusal
    , renderHintWarning
    ) where

import Control.Monad (forM_, when)
import Control.Monad.Except (ExceptT (..), runExceptT, throwError)
import Control.Monad.Trans (lift)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Short qualified as SBS
import Data.Containers.ListUtils (nubOrd)
import Data.List (minimumBy)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Ord (comparing)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Lens.Micro ((^.))
import PlutusTx.Builtins.Internal (BuiltinByteString (..))

import Cardano.Crypto.Hash.Class (hashFromBytes)
import Cardano.Ledger.Address (Addr (..))
import Cardano.Ledger.Api.Tx.Out
    ( TxOut
    , addrTxOutL
    , referenceScriptTxOutL
    , valueTxOutL
    )
import Cardano.Ledger.BaseTypes (StrictMaybe (..))
import Cardano.Ledger.BaseTypes qualified as Ledger
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Core (hashScript)
import Cardano.Ledger.Credential
    ( Credential (ScriptHashObj)
    , StakeReference (StakeRefNull)
    )
import Cardano.Ledger.Hashes (ScriptHash (..))
import Cardano.Ledger.Mary.Value
    ( AssetName (..)
    , MaryValue (..)
    , MultiAsset (..)
    , PolicyID (..)
    )
import Cardano.Ledger.TxIn (TxId, TxIn (..))

import Singular.Application.OpenDatum.Script
    ( Application (..)
    , applicationCodes
    )
import Singular.Registry.AssetName (deriveAssetName)
import Singular.Registry.Blueprint (NamingCodes, applyRequestParams)
import Singular.Registry.Config (CageConfig (..))
import Singular.Registry.Config.Application
    ( RegistryEconomics (..)
    , configForApplication
    )
import Singular.Registry.Deployment.Manifest (renderOutRef)
import Singular.Registry.Evidence (Evidenced (..))
import Singular.Registry.Ledger (ConwayEra)
import Singular.Registry.LedgerProvider
    ( Asset
    , MintRecord (..)
    , Network (..)
    , OutputQuery (..)
    , Outputs
    , ReadFailure (..)
    , Session (..)
    )
import Singular.Registry.TxBuilder.Edges (namingPins)
import Singular.Registry.TxBuilder.Internal
    ( computeScriptHash
    , extractCageDatum
    , scriptHashBytes
    , txInToRef
    )
import Singular.Registry.Types
    ( CageDatum (..)
    , OnChainTokenId (..)
    , OnChainTokenState (..)
    , stateAbsentPolicyBytes
    , stateActivePolicyBytes
    , stateAppPolicyBytes
    , stateTerminalPolicyBytes
    )

-- | The compiled code a registry command needs from the blueprint.
data Release = Release
    { releaseState :: SBS.ShortByteString
    , releaseRequest :: SBS.ShortByteString
    , releaseCodes :: NamingCodes
    {- ^ @open_datum.open_datum@ unapplied and @witness.witness@, from the
    same blueprint
    -}
    }

{- | A state token as the command line spells it, @POLICY.NAME@, each part
in hex: a 28-byte policy and a 32-byte name. Any other shape is refused
before any provider is asked.
-}
parseStateToken :: Text -> Either Text Asset
parseStateToken spelling = case T.splitOn "." spelling of
    [policyHex, nameHex] -> do
        policy <- sized 28 "policy" policyHex
        name <- sized 32 "name" nameHex
        hash <-
            maybe
                (Left "the policy is not a script hash")
                Right
                (hashFromBytes policy)
        Right (PolicyID (ScriptHash hash), AssetName (SBS.toShort name))
    _ -> Left "a state token is POLICY.NAME, each part in hex"
  where
    sized n what text = case B16.decode (TE.encodeUtf8 text) of
        Right bytes
            | BS.length bytes == n -> Right bytes
            | otherwise ->
                Left
                    ( "the "
                        <> what
                        <> " is "
                        <> T.pack (show (BS.length bytes))
                        <> " bytes, not "
                        <> T.pack (show n)
                    )
        Left _ -> Left ("the " <> what <> " is not hex")

-- | The @POLICY.NAME@ spelling of a state token.
renderStateToken :: Asset -> Text
renderStateToken (PolicyID policy, AssetName name) =
    hexText (scriptHashBytes policy)
        <> "."
        <> hexText (SBS.fromShort name)

-- | The six scripts a registry runs, by the role their reference plays.
data ReferenceRole
    = RoleState
    | RoleRequest
    | RoleWitnessAbsent
    | RoleWitnessActive
    | RoleWitnessTerminal
    | RoleApplication
    deriving stock (Eq, Ord, Show, Enum, Bounded)

-- | A role as receipts spell it.
roleName :: ReferenceRole -> Text
roleName = \case
    RoleState -> "state"
    RoleRequest -> "request"
    RoleWitnessAbsent -> "witness-absent"
    RoleWitnessActive -> "witness-active"
    RoleWitnessTerminal -> "witness-terminal"
    RoleApplication -> "application"

-- | A role from its receipt spelling.
parseRole :: Text -> Maybe ReferenceRole
parseRole name = lookup name [(roleName r, r) | r <- [minBound .. maxBound]]

{- | The script hash each role must carry, derived from the release and the
token alone. The state hash is the release's state script; every other
role is the release's script for it applied to the registry identity,
state policy then token name.
-}
expectedReferences :: Release -> Asset -> Map ReferenceRole ScriptHash
expectedReferences release (_, AssetName name) =
    Map.fromList
        [ (RoleState, stateHash)
        , (RoleRequest, computeScriptHash requestBytes)
        , (RoleWitnessAbsent, pinHash absentPin)
        , (RoleWitnessActive, pinHash activePin)
        , (RoleWitnessTerminal, pinHash terminalPin)
        , (RoleApplication, pinHash applicationPin)
        ]
  where
    stateHash = computeScriptHash (releaseState release)
    registryId = scriptHashBytes stateHash <> SBS.fromShort name
    pinned =
        applicationCodes
            OpenDatumApplication
            registryId
            (releaseCodes release)
    (applicationPin, absentPin, activePin, terminalPin) =
        namingPins pinned registryId
    requestBytes =
        applyRequestParams
            (scriptHashBytes stateHash)
            (OnChainTokenId (BuiltinByteString (SBS.fromShort name)))
            (releaseRequest release)
    pinHash pin =
        maybe
            (error "expectedReferences: a pin is not a script hash")
            ScriptHash
            (hashFromBytes (SBS.fromShort pin))

-- | The datum policy a registry pins, in the order they are compared.
data PinField
    = PinApplication
    | PinActive
    | PinAbsent
    | PinTerminal
    deriving stock (Eq, Ord, Show, Enum, Bounded)

-- | A registry exists only once every identity check has passed.
data ResolvedRegistry = ResolvedRegistry
    { resolvedToken :: Asset
    , resolvedSeed :: TxIn
    -- ^ The minting transaction's input whose derived name is the token's
    , resolvedCreation :: TxId
    -- ^ The minting transaction
    , resolvedState :: (TxIn, TxOut ConwayEra)
    -- ^ The output holding the token at the state address
    , resolvedDatum :: OnChainTokenState
    -- ^ Its state datum: root, windows, tip and the four pins
    , resolvedConfig :: CageConfig
    {- ^ The configuration derived from the release and the token, with the
    windows and tip read from the datum
    -}
    , resolvedCodes :: NamingCodes
    -- ^ The application and witness codes as this registry runs them
    , resolvedExpected :: Map ReferenceRole ScriptHash
    , resolvedNetwork :: Network
    -- ^ The provider session's network
    }

-- | Why a state token is not a registry of this release, in checking order.
data IdentityRefusal
    = -- | The token's policy is not this release's state script
      StateTokenForeignRelease ScriptHash
    | -- | The provider has no record of the asset
      StateTokenNotFound
    | -- | The supply is not one: the supply found
      StateTokenBurned Integer
    | -- | The minting transaction spends no seed of the token's name
      StateTokenSeedMismatch TxId
    | -- | No output holds the token at the state address with a state datum
      StateOutputMissing
    | -- | A datum pin differs from the hash the release and token derive
      RegistryPinMismatch PinField
    | -- | The provider's network is not the release's
      NetworkMismatch Network
    | -- | The provider could not be read; no identity fact was decided
      IdentityUnreadable ReadFailure
    deriving stock (Eq, Show)

{- | Resolve a state token into a registry, refusing by name in the checking
order. No file is read.
-}
resolveRegistry
    :: (Monad m)
    => Release
    -> Asset
    -> Session w m
    -> m (Either IdentityRefusal ResolvedRegistry)
resolveRegistry release token@(PolicyID policy, AssetName name) session =
    runExceptT $ do
        let stateHash = computeScriptHash (releaseState release)
        when (policy /= stateHash) $
            throwError (StateTokenForeignRelease stateHash)
        record <-
            readFact (mintRecord session token)
                >>= maybe (throwError StateTokenNotFound) pure
        when (mintSupply record /= 1) $
            throwError (StateTokenBurned (mintSupply record))
        seed <-
            case filter derivesName (mintSpentInputs record) of
                found : _ -> pure found
                [] -> throwError (StateTokenSeedMismatch (mintTransaction record))
        held <- readFact (outputs session (HoldingAsset token))
        let stateAddress = Addr Ledger.Testnet (ScriptHashObj stateHash) StakeRefNull
        (stateRef, stateOut, datum) <-
            case [ (i, o, st)
                 | (i, o) <- held
                 , holdsToken o
                 , o ^. addrTxOutL == stateAddress
                 , Just (StateDatum st) <- [extractCageDatum o]
                 ] of
                found : _ -> pure found
                [] -> throwError StateOutputMissing
        let (cfg, codes) =
                configForApplication
                    OpenDatumApplication
                    (releaseCodes release)
                    (releaseState release)
                    (releaseRequest release)
                    RegistryEconomics
                        { reProcessTime = stateProcessTime datum
                        , reRetractTime = stateRetractTime datum
                        , reTip = Coin (stateMaxFee datum)
                        }
                    Ledger.Testnet
                    (txInToRef seed)
        forM_ [minBound .. maxBound] $ \field ->
            when (datumPin field datum /= SBS.fromShort (configPin field cfg)) $
                throwError (RegistryPinMismatch field)
        let network = sessionNetwork session
        when (ledgerNetwork network /= Ledger.Testnet) $
            throwError (NetworkMismatch network)
        pure
            ResolvedRegistry
                { resolvedToken = token
                , resolvedSeed = seed
                , resolvedCreation = mintTransaction record
                , resolvedState = (stateRef, stateOut)
                , resolvedDatum = datum
                , resolvedConfig = cfg
                , resolvedCodes = codes
                , resolvedExpected = expectedReferences release token
                , resolvedNetwork = network
                }
  where
    holdsToken o =
        let MaryValue _ (MultiAsset assets) = o ^. valueTxOutL
        in  maybe
                False
                ((> 0) . Map.findWithDefault 0 (AssetName name))
                (Map.lookup (PolicyID policy) assets)
    derivesName input = deriveAssetName (txInToRef input) == SBS.fromShort name
    readFact action =
        ExceptT
            (fmap (either (Left . IdentityUnreadable) (Right . value)) action)

-- | The refusal's name, then what it found.
renderIdentityRefusal :: IdentityRefusal -> Text
renderIdentityRefusal = \case
    StateTokenForeignRelease expected ->
        "state-token-foreign-release: the token's policy is not this release's state script "
            <> hexText (scriptHashBytes expected)
    StateTokenNotFound ->
        "state-token-not-found: the provider has no record of the asset"
    StateTokenBurned supply ->
        "state-token-burned: the asset's supply is "
            <> T.pack (show supply)
            <> ", not one"
    StateTokenSeedMismatch minting ->
        "state-token-seed-mismatch: the minting transaction "
            <> T.takeWhile (/= '#') (renderOutRef (TxIn minting minBound))
            <> " spends no input whose derived name is the token's"
    StateOutputMissing ->
        "state-output-missing: no output holds the token at the state address with a state datum"
    RegistryPinMismatch field ->
        "registry-pin-mismatch "
            <> pinName field
            <> ": the datum's "
            <> pinName field
            <> " policy differs from the one the release derives for this token"
    NetworkMismatch (Network magic) ->
        "network-mismatch: the provider's network (magic "
            <> T.pack (show magic)
            <> ") is not the network of this release's addresses"
    IdentityUnreadable failure ->
        "the provider could not be read: " <> T.pack (show failure)

-- | Why a command cannot run the scripts it needs.
data ReferenceRefusal
    = -- | No source found a carrier of this role's hash
      ReferenceMissing ReferenceRole ScriptHash
    | -- | A source could not be read
      ReferenceUnreadable ReadFailure
    deriving stock (Eq, Show)

{- | Whether the output carries a reference script whose hash, computed here
from the script itself, is the expected one.
-}
carriesReference :: ScriptHash -> TxOut ConwayEra -> Bool
carriesReference expected output = case output ^. referenceScriptTxOutL of
    SJust script -> hashScript script == expected
    SNothing -> False

{- | Find a carrier for each needed role: from the provider's existence
query, then the hints, then the wallet's outputs. A carrier is admitted
only by 'carriesReference'; among the admitted carriers of the first
source that has any, the lowest output reference is chosen. The second
result lists the hints that carry no needed role's script.
-}
findReferences
    :: (Monad m)
    => Session w m
    -> [TxIn]
    -- ^ Hints
    -> Outputs
    -- ^ The actor's wallet outputs
    -> Map ReferenceRole ScriptHash
    -> Set ReferenceRole
    -- ^ The roles the command's transaction runs
    -> m
        ( Either
            ReferenceRefusal
            (Map ReferenceRole (TxIn, TxOut ConwayEra), [TxIn])
        )
findReferences session hints wallet expected needed = runExceptT $ do
    let wanted =
            [ (role, hash)
            | role <- Set.toAscList needed
            , Just hash <- [Map.lookup role expected]
            ]
    fromProvider <-
        traverse
            ( \(_, hash) -> readFact (outputs session (CarryingReferenceScript hash))
            )
            wanted
    hinted <- concat <$> traverse lookupHint (nubOrd hints)
    let carries hash = filter (carriesReference hash . snd)
        admittedHints =
            [ hint
            | hint <- nubOrd hints
            , any (\(_, hash) -> any ((== hint) . fst) (carries hash hinted)) wanted
            ]
        choose ((role, hash), provided) =
            case filter (not . null) (map (carries hash) [provided, hinted, wallet]) of
                found : _ -> Right (role, minimumBy (comparing fst) found)
                [] -> Left (ReferenceMissing role hash)
    chosen <-
        either throwError pure (traverse choose (zip wanted fromProvider))
    pure
        ( Map.fromList chosen
        , filter (`notElem` admittedHints) (nubOrd hints)
        )
  where
    readFact action =
        ExceptT
            (fmap (either (Left . ReferenceUnreadable) (Right . value)) action)
    lookupHint hint = do
        answer <- lift (outputs session (AtTxIn hint))
        case answer of
            Right found -> pure (value found)
            Left (MissingOutput _) -> pure []
            Left failure -> throwError (ReferenceUnreadable failure)

-- | The refusal, with the remedy.
renderReferenceRefusal :: ReferenceRefusal -> Text
renderReferenceRefusal = \case
    ReferenceMissing role hash ->
        "reference-missing "
            <> roleName role
            <> " "
            <> hexText (scriptHashBytes hash)
            <> ": not found by this provider, hints or wallet; publish it with singular registry publish-references"
    ReferenceUnreadable failure ->
        "the provider could not be read while finding references: "
            <> T.pack (show failure)

-- | The warning printed once for a hint that is not admitted.
renderHintWarning :: TxIn -> Text
renderHintWarning hint = "reference-hint-invalid " <> renderOutRef hint

-- | A pin field as refusals spell it.
pinName :: PinField -> Text
pinName = \case
    PinApplication -> "application"
    PinActive -> "active"
    PinAbsent -> "absent"
    PinTerminal -> "terminal"

-- | The pin a state datum carries.
datumPin :: PinField -> OnChainTokenState -> ByteString
datumPin = \case
    PinApplication -> stateAppPolicyBytes
    PinActive -> stateActivePolicyBytes
    PinAbsent -> stateAbsentPolicyBytes
    PinTerminal -> stateTerminalPolicyBytes

-- | The pin a configuration derives.
configPin :: PinField -> CageConfig -> SBS.ShortByteString
configPin = \case
    PinApplication -> cfgApplicationPolicy
    PinActive -> cfgActivePolicy
    PinAbsent -> cfgAbsentPolicy
    PinTerminal -> cfgTerminalPolicy

-- | The ledger network a provider's magic names: mainnet's, or a test network.
ledgerNetwork :: Network -> Ledger.Network
ledgerNetwork (Network magic)
    | magic == 764_824_073 = Ledger.Mainnet
    | otherwise = Ledger.Testnet

hexText :: ByteString -> Text
hexText = TE.decodeUtf8 . B16.encode
