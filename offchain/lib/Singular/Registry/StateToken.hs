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

import Data.ByteString.Short qualified as SBS
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Text (Text)

import Cardano.Ledger.Api.Tx.Out (TxOut, referenceScriptTxOutL)
import Cardano.Ledger.BaseTypes (StrictMaybe (..))
import Cardano.Ledger.Core (hashScript)
import Cardano.Ledger.Hashes (ScriptHash)
import Cardano.Ledger.TxIn (TxId, TxIn)
import Lens.Micro ((^.))

import Singular.Registry.Blueprint (NamingCodes)
import Singular.Registry.Config (CageConfig)
import Singular.Registry.Ledger (ConwayEra)
import Singular.Registry.LedgerProvider
    ( Asset
    , Network
    , Outputs
    , ReadFailure (..)
    , Session
    )
import Singular.Registry.Types (OnChainTokenState)

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
parseStateToken _ = Left "parseStateToken: not implemented"

-- | The @POLICY.NAME@ spelling of a state token.
renderStateToken :: Asset -> Text
renderStateToken _ = ""

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
roleName _ = ""

-- | A role from its receipt spelling.
parseRole :: Text -> Maybe ReferenceRole
parseRole _ = Nothing

{- | The script hash each role must carry, derived from the release and the
token alone. The state hash is the release's state script; every other
role is the release's script for it applied to the registry identity,
state policy then token name.
-}
expectedReferences :: Release -> Asset -> Map ReferenceRole ScriptHash
expectedReferences _ _ = Map.empty

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
resolveRegistry _ _ _ =
    pure
        ( Left
            ( IdentityUnreadable
                (BackendReadFailure "resolveRegistry: not implemented")
            )
        )

-- | The refusal's name, then what it found.
renderIdentityRefusal :: IdentityRefusal -> Text
renderIdentityRefusal _ = ""

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
findReferences _ _ _ _ _ =
    pure
        ( Left
            ( ReferenceUnreadable
                (BackendReadFailure "findReferences: not implemented")
            )
        )

-- | The refusal, with the remedy.
renderReferenceRefusal :: ReferenceRefusal -> Text
renderReferenceRefusal _ = ""

-- | The warning printed once for a hint that is not admitted.
renderHintWarning :: TxIn -> Text
renderHintWarning _ = ""
