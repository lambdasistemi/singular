{-# LANGUAGE LambdaCase #-}

{- |
Module      : Singular.CLI.RegistryReading
Description : The registry a command line names, read once for every program
License     : Apache-2.0

A command names its registry by its address (@--registry@, the variable
@SINGULAR_REGISTRY@ or the key @registry@ of the settings file), or by its
state token and its network as before. The address holds both the state token
and the network, so a command given the address needs neither.

This is the one reading of that setting, used by every program that takes a
registry. It runs before the flags of a command are read, and gives
those flags the state token and the network the address names, so the rest of
the parser needs no second path. The address is read before anything else is
done with it, in the order its causes are checked ("Singular.Registry.Address"),
and a state token or a network magic beside it that names another registry or
another network is refused naming both, wherever each came from.
-}
module Singular.CLI.RegistryReading
    ( RegistryRefusal (..)
    , registryVariable
    , registryGiven
    , completeRegistry
    ) where

import Data.Bifunctor (first)
import Data.Text qualified as T
import Data.Word (Word32)
import Text.Read (readMaybe)

import Singular.Registry.Address
    ( AddressRefusal (..)
    , addressPrefix
    , parseRegistryAddress
    , renderAddressRefusal
    )
import Singular.Registry.LedgerProvider (Asset)
import Singular.Registry.StateToken
    ( parseStateToken
    , renderStateToken
    )

-- | Why the registry a command line names is not usable, naming the flag.
data RegistryRefusal
    = -- | A flag the command needs and the line leaves out
      RegistryMissing String
    | -- | A flag and what is wrong with its value
      RegistryBad String String
    deriving stock (Eq, Show)

-- | The variable that names the registry by its address.
registryVariable :: String
registryVariable = "SINGULAR_REGISTRY"

{- | The registry a command line names by its address: the network magic and
the state token the address holds, or nothing when no address is given. An
address that cannot be read, and a state token or network magic beside it
that disagrees with it, are refused.
-}
registryGiven
    :: [(String, String)]
    -- ^ the environment, for the variables a program reads without a settings layer
    -> [(String, Maybe String)]
    -- ^ the flags, in the form every setting has reached them
    -> Either RegistryRefusal (Maybe (Word32, Asset))
registryGiven environment flags = case address of
    Nothing -> Right Nothing
    Just word -> do
        (magic, token) <-
            first
                (RegistryBad "--registry" . sentence)
                (parseRegistryAddress (T.pack word))
        agreeToken token
        agreeMagic magic
        Right (Just (magic, token))
  where
    address = case lookup "--registry" flags of
        Just (Just word) -> Just word
        _ -> nonEmpty (lookup registryVariable environment)
    sentence refusal =
        T.unpack (renderAddressRefusal refusal) <> case refusal of
            NotAnAddress ->
                "; --registry once named the state directory, which is --state-dir now"
            _ -> ""
    agreeToken token = case given "--state-token" "SINGULAR_STATE_TOKEN" of
        Nothing -> Right ()
        Just spelling -> do
            named <-
                first
                    (RegistryBad "--state-token" . T.unpack)
                    (parseStateToken (T.pack spelling))
            if named == token
                then Right ()
                else
                    Left
                        ( RegistryBad
                            "--state-token"
                            ( "names "
                                <> spelling
                                <> ", but the address given to --registry holds "
                                <> T.unpack (renderStateToken token)
                            )
                        )
    agreeMagic magic = case lookup "--network-magic" flags of
        Just (Just spelling)
            | Just named <- readMaybe spelling :: Maybe Word32
            , named /= magic ->
                Left
                    ( RegistryBad
                        "--network-magic"
                        ( "is "
                            <> spelling
                            <> ", but the address given to --registry is on the network "
                            <> maybe "of no prefix" T.unpack (addressPrefix magic)
                            <> " (network magic "
                            <> show magic
                            <> ")"
                        )
                    )
        _ -> Right ()
    given flag variable = case lookup flag flags of
        Just (Just value) -> Just value
        _ -> nonEmpty (lookup variable environment)
    nonEmpty = \case
        Just value | not (null value) -> Just value
        _ -> Nothing

{- | The flags of a command that takes a registry, with the state token and the
network magic of the address when one is given: the flags a command reads
after this are the ones it always read.
-}
completeRegistry
    :: [(String, String)]
    -> [(String, Maybe String)]
    -> Either RegistryRefusal [(String, Maybe String)]
completeRegistry environment flags = do
    given <- registryGiven environment flags
    pure $ case given of
        Nothing -> flags
        Just (magic, token) ->
            filled "--state-token" (T.unpack (renderStateToken token))
                . filled "--network-magic" (show magic)
                $ flags
  where
    filled name value present = case lookup name present of
        Just (Just _) -> present
        _ -> (name, Just value) : filter ((/= name) . fst) present
