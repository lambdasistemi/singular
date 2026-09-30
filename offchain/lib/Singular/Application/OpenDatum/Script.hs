{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.Application.OpenDatum.Script
Description : Which application a registry pins, and its applied script
License     : Apache-2.0

A registry pins one application policy at boot (#157 D-BOOT). The open
registry pins the parameterless @open.open@, whose compiled hash is its
policy. An open-datum registry pins @open_datum.open_datum@ applied to
its own registry identity (state policy ‖ state token name). That
identity is known only once the boot seed is chosen, so the applied
script is derived from the seed, never stored as a literal.

'applicationCodes' is the one place the choice is made. It returns the
same 'NamingCodes' the booking, pin and fold builders already take, with
'ncApplication' holding the code as the registry pins it. The open
application's codes come back unchanged, so its callers keep their exact
bytes and behaviour.
-}
module Singular.Application.OpenDatum.Script
    ( -- * The application a registry pins
      Application (..)
    , applicationTitle
    , parseApplication
    , renderApplication

      -- * Codes from a blueprint
    , loadApplicationCodes
    , applicationCodes

      -- * The applied open-datum script
    , openDatumScript
    , openDatumPolicy
    , openDatumAddressBytes
    ) where

import Data.ByteString (ByteString)
import Data.ByteString.Short qualified as SBS
import Data.Text (Text)

import Cardano.Ledger.Address (Addr (..), serialiseAddr)
import Cardano.Ledger.BaseTypes (Network)
import Cardano.Ledger.Credential
    ( Credential (..)
    , StakeReference (..)
    )

import Singular.Registry.Blueprint
    ( Blueprint
    , NamingCodes (..)
    , applyBytesParam
    , extractCompiledCode
    )
import Singular.Registry.TxBuilder.Internal
    ( computeScriptHash
    , scriptHashBytes
    )

-- | The application a registry pins.
data Application
    = -- | @open.open@: parameterless, protects nobody
      OpenApplication
    | -- | @open_datum.open_datum@ applied to the registry identity
      OpenDatumApplication
    deriving stock (Eq, Show, Enum, Bounded)

-- | The blueprint validator an application is compiled from.
applicationTitle :: Application -> Text
applicationTitle = \case
    OpenApplication -> "open.open"
    OpenDatumApplication -> "open_datum.open_datum"

renderApplication :: Application -> Text
renderApplication = applicationTitle

-- | The application a saved identity names, by its blueprint title.
parseApplication :: Text -> Either String Application
parseApplication t = case [a | a <- [minBound .. maxBound], applicationTitle a == t] of
    [a] -> Right a
    _ -> Left ("no application is compiled from " <> show t)

{- | The unapplied codes of an application and the three witnesses, read
from one blueprint, so an application from one build is never paired
with witnesses from another.
-}
loadApplicationCodes
    :: Application -> Blueprint -> Either String NamingCodes
loadApplicationCodes app bp = do
    application <- code (applicationTitle app)
    witness <- code "witness.witness"
    pure NamingCodes{ncApplication = application, ncWitness = witness}
  where
    code title =
        maybe
            (Left ("the blueprint carries no " <> show title))
            Right
            (extractCompiledCode title bp)

{- | The codes as the registry with this identity pins them: the open
application unchanged; the open-datum application applied to the
identity bytes.
-}
applicationCodes
    :: Application
    -> ByteString
    -- ^ The registry identity: state policy then state token name
    -> NamingCodes
    -- ^ As 'loadApplicationCodes' read them
    -> NamingCodes
applicationCodes app registryId codes = case app of
    OpenApplication -> codes
    OpenDatumApplication ->
        codes
            { ncApplication = openDatumScript registryId (ncApplication codes)
            }

-- | @open_datum(registry)@: the unapplied code applied to the identity.
openDatumScript
    :: ByteString -> SBS.ShortByteString -> SBS.ShortByteString
openDatumScript = applyBytesParam

-- | The applied script's hash: its approval policy id and its address.
openDatumPolicy :: SBS.ShortByteString -> ByteString
openDatumPolicy = scriptHashBytes . computeScriptHash

{- | The enterprise script address of the applied script, as the bytes a
request's destination names.
-}
openDatumAddressBytes :: Network -> SBS.ShortByteString -> ByteString
openDatumAddressBytes net applied =
    serialiseAddr
        (Addr net (ScriptHashObj (computeScriptHash applied)) StakeRefNull)
