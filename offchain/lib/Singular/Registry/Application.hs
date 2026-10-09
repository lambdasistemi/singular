{- |
Module      : Singular.Registry.Application
Description : The application a registry pins, as a value
License     : Apache-2.0

A registry pins one application policy at boot (#157 genesis-policy-pins).
This module carries what the registry needs to know of an application
without naming any: a name for receipts and refusals, the executable that
folds its terminations, how the policy is fixed, and the decoder and
holding rules, which @create@ and @fold@ do not use until slice 2. Each
executable composes its value and hands it to the library.

The pin has four forms: a hash given as input (a registry booted for an
application whose script does not depend on the registry identity), a
blueprint validator title applied to the registry identity (the state
policy then the token name), a blueprint validator title pinned as
compiled (the parameterless form the tests use; production registries
are always identity-scoped), or read from the state datum of a registry
that already exists. 'applyPin' derives the pinned bytes and codes for
the first three; the fourth needs the datum, so only 'resolveRegistry'
passes it after reading the datum, and 'configForApplication' refuses it
by name.
-}
module Singular.Registry.Application
    ( -- * The pin
      ApplicationPin (..)

      -- * The value
    , Application (..)
    , neutralApplication
    , hashPinnedApplication

      -- * Deriving from a pin
    , applyPin
    ) where

import Data.ByteString (ByteString)
import Data.ByteString.Short qualified as SBS
import Data.Text (Text)

import Singular.Registry.Blueprint (NamingCodes (..), applyBytesParam)
import Singular.Registry.TxBuilder.Internal
    ( computeScriptHash
    , scriptHashBytes
    )

-- | How the registry's application policy is fixed.
data ApplicationPin
    = -- | A 28-byte policy hash given as input
      PinByHash SBS.ShortByteString
    | -- | The blueprint validator title, applied to the registry identity
      PinByScript Text
    | {- | The blueprint validator title, pinned as compiled: the
      parameterless form the tests use, never a production registry
      -}
      PinAsCompiled Text
    | -- | Read from the state datum of the registry being attached to
      PinFromState
    deriving stock (Eq, Show)

{- | What the registry knows of an application. The decoder and holding
rules are carried, never read, until slice 2; their types stay
parameters so this library never names an application to name them.
-}
data Application decoder holding = Application
    { appName :: Maybe Text
    -- ^ What receipts and refusals call the application; none is neutral
    , appExecutable :: Maybe Text
    -- ^ The binary that folds this application's terminations
    , appPin :: ApplicationPin
    , appDecoder :: Maybe decoder
    -- ^ Reads a datum into a holding view; absent on the neutral value
    , appHolding :: Maybe holding
    -- ^ Finds and releases this registry's holding; absent on neutral
    }
    deriving stock (Eq, Show)

{- | The value @singular@ folds with: no name, no executable, no decoder,
no holding rules; the pin is read from the state datum.
-}
neutralApplication :: Application decoder holding
neutralApplication =
    Application
        { appName = Nothing
        , appExecutable = Nothing
        , appPin = PinFromState
        , appDecoder = Nothing
        , appHolding = Nothing
        }

-- | The neutral value with the pin fixed to the given 28-byte policy hash.
hashPinnedApplication
    :: SBS.ShortByteString -> Application decoder holding
hashPinnedApplication policy =
    neutralApplication{appPin = PinByHash policy}

{- | The pinned policy bytes and the codes as the registry runs them, for
a pin that carries its own derivation. 'PinFromState' needs the state
datum, which this function is never given, so it is refused by name;
'resolveRegistry' reads the datum first and passes its pin as 'PinByHash'.
-}
applyPin
    :: ApplicationPin
    -> ByteString
    -- ^ The registry identity: state policy then state token name
    -> NamingCodes
    -- ^ The application and witness codes as the blueprint carries them
    -> (SBS.ShortByteString, NamingCodes)
applyPin pin registryId codes = case pin of
    PinByHash policy -> (policy, codes{ncApplication = SBS.empty})
    PinByScript _title ->
        let applied = applyBytesParam registryId (ncApplication codes)
        in  (pinOf applied, codes{ncApplication = applied})
    PinAsCompiled _title -> (pinOf (ncApplication codes), codes)
    PinFromState ->
        error
            "applyPin: PinFromState reads the pin from the state datum, which this derivation is never given"
  where
    pinOf = SBS.toShort . scriptHashBytes . computeScriptHash
