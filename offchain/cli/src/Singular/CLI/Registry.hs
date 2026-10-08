{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NumericUnderscores #-}

{- |
Module      : Singular.CLI.Registry
Description : The release a command brings, and the files of an actor's directory
License     : Apache-2.0

A registry is its state token and the release that made it
("Singular.Registry.StateToken"); nothing per-registry is kept on disk.
An actor's directory holds only the actor's own in-flight submissions:
the journal ("Singular.CLI.Receipt"), the saved submission bodies, the
lock and, during @create@, the pending identity. Every check here is
pure or reads only those files.
-}
module Singular.CLI.Registry
    ( -- * The release a command brings
      Release (..)
    , loadRelease
    , loadReleaseCodes
    , registryConfigFor
    , economics
    , Pins (..)
    , pinsOf
    , hexT
    , keyFields
    , parseEnterpriseAddress

      -- * Files
    , pendingPath

      -- * Checks
    , IdentityError (..)
    , renderIdentityError
    , checkSeed
    , seedHeld
    , seedChecks
    , refuseExisting
    , publicationFunding
    , checkPendingToken
    ) where

import Data.Aeson (FromJSON (..), ToJSON (..))
import Data.Aeson qualified as Aeson
import Data.ByteString (ByteString)
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Short qualified as SBS
import Data.List (sortOn)
import Data.Ord (Down (..))
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Word (Word32)
import GHC.Generics (Generic)
import Lens.Micro ((&), (.~), (^.))
import System.Directory (doesFileExist)
import System.FilePath ((</>))

import Cardano.Ledger.Address (Addr (..), decodeAddrEither)
import Cardano.Ledger.Api.Tx.Out
    ( TxOut
    , addrTxOutL
    , coinTxOutL
    , getMinCoinTxOut
    , mkBasicTxOut
    , referenceScriptTxOutL
    )
import Cardano.Ledger.BaseTypes (Network (..), StrictMaybe (..))
import Cardano.Ledger.Core (PParams, Script)
import Cardano.Ledger.Credential
    ( Credential (..)
    , StakeReference (..)
    )
import Cardano.Ledger.Mary.Value (MaryValue (..))
import Cardano.Ledger.TxIn (TxIn)
import Codec.Binary.Bech32 qualified as Bech32
import Control.Monad (when)

import Singular.Application.OpenDatum.Script (Application (..))
import Singular.CLI.Permanent (knownScripts)
import Singular.Registry.Blueprint
    ( NamingCodes (..)
    , extractCompiledCode
    , loadBlueprint
    )
import Singular.Registry.Config (CageConfig (..))
import Singular.Registry.Config.Application
    ( RegistryEconomics (..)
    , configForApplication
    )
import Singular.Registry.Deployment (renderOutRef)
import Singular.Registry.Ledger (Coin (..), ConwayEra)
import Singular.Registry.LedgerProvider (Asset)
import Singular.Registry.StateToken (Release (..), renderStateToken)
import Singular.Registry.TxBuilder.Edges (adaOnlyOut)
import Singular.Registry.TxBuilder.Internal
    ( computeScriptHash
    , scriptHashBytes
    )
import Singular.Registry.Types (OnChainTxOutRef)

-- | The pins a registry's configuration carries, as hex.
data Pins = Pins
    { pinState :: Text
    , pinApplication :: Text
    , pinAbsent :: Text
    , pinActive :: Text
    , pinTerminal :: Text
    }
    deriving stock (Eq, Show, Generic)

instance ToJSON Pins where
    toJSON = Aeson.genericToJSON Aeson.defaultOptions
instance FromJSON Pins where
    parseJSON = Aeson.genericParseJSON Aeson.defaultOptions

-- ---------------------------------------------------------
-- The release a command brings
-- ---------------------------------------------------------

-- | Read the registry blueprint a command was given.
loadRelease :: FilePath -> IO (Either String Release)
loadRelease = loadReleaseWith True

{- | Read code for an explicitly supplied implementation fixture. This makes
no recognition claim; the shipping environment always uses 'loadRelease'.
-}
loadReleaseCodes :: FilePath -> IO (Either String Release)
loadReleaseCodes = loadReleaseWith False

loadReleaseWith :: Bool -> FilePath -> IO (Either String Release)
loadReleaseWith recognize path = do
    loaded <- loadBlueprint path
    pure $ do
        bp <-
            either (Left . ("the blueprint does not parse: " <>)) Right loaded
        let code name =
                maybe
                    (Left ("the blueprint carries no " <> name))
                    Right
                    (extractCompiledCode (T.pack name) bp)
        when recognize $
            mapM_
                ( \(title, expected) -> do
                    compiled <- code (T.unpack title)
                    let actual = hexT (scriptHashBytes (computeScriptHash compiled))
                    when (actual /= expected) $
                        Left
                            ( "unknown permanent contract script "
                                <> T.unpack title
                                <> ": expected "
                                <> T.unpack expected
                                <> ", computed "
                                <> T.unpack actual
                            )
                )
                knownScripts
        state <- code "permanent_state.state"
        request <- code "request.request"
        application <- code "permanent_open_datum.open_datum"
        witness <- code "permanent_witness.witness"
        pure
            ( Release
                state
                request
                NamingCodes{ncApplication = application, ncWitness = witness}
            )

-- | The windows and tip a registry this command creates is booted with.
economics :: RegistryEconomics
economics =
    RegistryEconomics
        { reProcessTime = 600_000
        , reRetractTime = 300_000
        , reTip = Coin 1_000_000
        }

{- | The configuration of the open-datum registry this release boots from
this seed, and the codes as that registry runs them: the application
applied to the registry identity the seed determines, and
@witness(kind, registry)@ at kinds 0, 1 and 2.
-}
registryConfigFor
    :: Release
    -> RegistryEconomics
    -> OnChainTxOutRef
    -> (CageConfig, NamingCodes)
registryConfigFor rel chosen =
    configForApplication
        OpenDatumApplication
        (releaseCodes rel)
        (releaseState rel)
        (releaseRequest rel)
        chosen
        Testnet

-- | The pins a configuration carries.
pinsOf :: CageConfig -> Pins
pinsOf cfg =
    Pins
        { pinState = hexT (scriptHashBytes (cfgScriptHash cfg))
        , pinApplication = hexT (SBS.fromShort (cfgApplicationPolicy cfg))
        , pinAbsent = hexT (SBS.fromShort (cfgAbsentPolicy cfg))
        , pinActive = hexT (SBS.fromShort (cfgActivePolicy cfg))
        , pinTerminal = hexT (SBS.fromShort (cfgTerminalPolicy cfg))
        }

hexT :: ByteString -> Text
hexT = T.pack . BC.unpack . B16.encode

{- | The receipt fields that name a key: its hex, and its text when the
bytes are valid UTF-8.
-}
keyFields :: ByteString -> [(Text, Aeson.Value)]
keyFields key =
    ("key", toJSON (hexT key))
        : [ ("keyText", toJSON text)
          | Right text <- [TE.decodeUtf8' key]
          ]

-- ---------------------------------------------------------
-- Files
-- ---------------------------------------------------------

{- | The identity a create records before its first submission, so an
interrupted create stays inspectable and is never booted again. A create
that finishes removes it.
-}
pendingPath :: FilePath -> FilePath
pendingPath dir = dir </> "registry.pending.json"

-- ---------------------------------------------------------
-- Checks
-- ---------------------------------------------------------

-- | Why a create may not use this wallet, seed or directory.
data IdentityError
    = SeedNotInWallet Text
    | SeedNotAdaOnly Text
    | NoFundingBesideSeed Text
    | RegistryExists FilePath
    | {- | A publication the wallet cannot fund: its role, the ada-only output
      it needs, and the largest the wallet holds for it
      -}
      PublicationUnfunded Text Integer Integer
    deriving stock (Eq, Show)

renderIdentityError :: IdentityError -> String
renderIdentityError = \case
    SeedNotInWallet seed ->
        "the seed "
            <> T.unpack seed
            <> " is not an unspent output of this wallet"
    SeedNotAdaOnly seed ->
        "the seed "
            <> T.unpack seed
            <> " carries a token or a reference script; a seed must hold ada only"
    NoFundingBesideSeed seed ->
        "the seed "
            <> T.unpack seed
            <> " is the only ada-only output the wallet holds; the registry's first publication is paid from another one while the seed stays unspent, so fund the wallet with a second ada-only output first"
    RegistryExists dir ->
        dir
            <> " already holds your state or its journal; create never \
               \overwrites one"
    PublicationUnfunded role needed largest ->
        "publication-unfunded "
            <> T.unpack role
            <> ": publishing this reference script needs an ada-only output of more than "
            <> show needed
            <> " lovelace and the largest the wallet has for it holds "
            <> show largest
            <> "; nothing was submitted"

{- | The seed, as this wallet holds it: unspent and ada only. This is all a
registry's identity needs; creating it needs 'checkSeed'.
-}
seedHeld
    :: TxIn
    -> [(TxIn, TxOut ConwayEra)]
    -> Either IdentityError (TxIn, TxOut ConwayEra)
seedHeld seed utxos = case [u | u@(i, _) <- utxos, i == seed] of
    [] -> Left (SeedNotInWallet (renderOutRef seed))
    (u@(_, out) : _)
        | adaOnlyOut out -> Right u
        | otherwise -> Left (SeedNotAdaOnly (renderOutRef seed))

{- | The seed, as a create needs it: held ('seedHeld'), with another ada-only
output beside it to pay the first publication from while the seed stays
unspent.
-}
checkSeed
    :: TxIn
    -> [(TxIn, TxOut ConwayEra)]
    -> Either IdentityError (TxIn, TxOut ConwayEra)
checkSeed seed utxos = do
    u <- seedHeld seed utxos
    if null [() | (i, o) <- utxos, i /= seed, adaOnlyOut o]
        then Left (NoFundingBesideSeed (renderOutRef seed))
        else Right u

{- | The seed checks a create applies, and the receipt fields they add. A
create about to submit needs the seed held with another ada-only output
beside it ('checkSeed') and adds nothing. A preview needs only the seed held
('seedHeld') and adds @createRefusal@: the refusal a create from this wallet
would meet now, or null.
-}
seedChecks
    :: Bool
    -- ^ whether the create is about to submit
    -> TxIn
    -> [(TxIn, TxOut ConwayEra)]
    -> Either IdentityError [(Text, Aeson.Value)]
seedChecks submitting seedIn utxos
    | submitting = [] <$ checkSeed seedIn utxos
    | otherwise = do
        _ <- seedHeld seedIn utxos
        pure
            [
                ( "createRefusal"
                , toJSON
                    ( either (Just . T.pack . renderIdentityError) (const Nothing) $
                        checkSeed seedIn utxos
                    )
                )
            ]

{- | Refuse a directory that holds an actor's journal or a pending create.
Any other file, a @registry.json@ an earlier release wrote included, is
not an input and does not refuse it.
-}
refuseExisting :: FilePath -> IO (Either IdentityError ())
refuseExisting dir = do
    present <-
        or
            <$> mapM
                doesFileExist
                [ pendingPath dir
                , dir </> "journal.jsonl"
                ]
    pure (if present then Left (RegistryExists dir) else Right ())

{- | A caller's enterprise address from its bech32 text: a payment key hash
and no stake part, for the network the magic names. The address is public;
nothing in it can sign.
-}
parseEnterpriseAddress :: Word32 -> String -> Either String Addr
parseEnterpriseAddress magic text = do
    (hrp, dat) <-
        either
            (\e -> Left ("--wallet-address is not bech32: " <> show e))
            Right
            (Bech32.decodeLenient (T.pack text))
    let expected = if magic == 764_824_073 then "addr" else "addr_test"
    when (Bech32.humanReadablePartToText hrp /= expected) $
        Left
            ( "--wallet-address is for another network: expected "
                <> T.unpack expected
                <> ", found "
                <> T.unpack (Bech32.humanReadablePartToText hrp)
            )
    raw <-
        maybe
            (Left "--wallet-address carries no address bytes")
            Right
            (Bech32.dataPartToBytes dat)
    addr <- decodeAddrEither raw
    case addr of
        Addr net (KeyHashObj _) StakeRefNull
            | net == (if magic == 764_824_073 then Mainnet else Testnet) ->
                Right addr
        _ ->
            Left
                "--wallet-address must be an enterprise address: a payment key hash and no stake part"

{- | Whether the wallet funds every reference publication a create makes,
with the boot between them, as the real transactions spend it. Each
publication funds from the largest ada-only output with its change
returned, as 'Singular.Registry.TxBuilder.Edges.publishRefScriptTx' funds
it; the publications before the boot leave the seed alone. The boot spends
the seed and the largest ada-only output beside it, as
'Singular.Registry.TxBuilder.Boot.bootTokenFrom' does, and returns what is
left of them after its cost as change, which the publications after it may
spend. Checked before anything is submitted; the first publication the
publisher would refuse is named, or @boot@ when the boot itself is not
funded.
-}
publicationFunding
    :: PParams ConwayEra
    -> TxIn
    -- ^ The seed
    -> Integer
    {- ^ The most the boot takes from its inputs
    ('Singular.Registry.TxBuilder.Boot.bootCostBound')
    -}
    -> [(Text, Script ConwayEra)]
    -- ^ Published before the boot, by role
    -> [(Text, Script ConwayEra)]
    -- ^ Published after the boot, by role
    -> [(TxIn, TxOut ConwayEra)]
    -- ^ The wallet
    -> Either IdentityError ()
publicationFunding pp seed bootCost before after wallet = do
    left <- publishing before [(Left i, o) | (i, o) <- wallet]
    booted <- booting left
    _ <- publishing after booted
    pure ()
  where
    -- The boot spends the seed and the largest ada-only output beside it,
    -- and returns what is left after its cost as change.
    booting held = case [o | (k, o) <- held, k == Left seed] of
        [] -> Left (PublicationUnfunded "boot" (bootCost + minimumChange) 0)
        seedOut : _ ->
            let funds =
                    take 1 $
                        sortOn
                            (Down . (^. coinTxOutL) . snd)
                            [u | u@(k, o) <- held, k /= Left seed, adaOnlyOut o]
                spent = Left seed : map fst funds
                inCoin =
                    sum [c | o <- seedOut : map snd funds, let Coin c = o ^. coinTxOutL]
                change = inCoin - bootCost
            in  if change > minimumChange
                    then
                        Right
                            ( [u | u@(k, _) <- held, k `notElem` spent]
                                <> [(Right (length held), seedOut & coinTxOutL .~ Coin change)]
                            )
                    else
                        Left (PublicationUnfunded "boot" (bootCost + minimumChange) inCoin)
    publishing scripts held = foldl (\acc s -> acc >>= publishOne s) (Right held) scripts
    -- One publication from the largest ada-only output that is not the
    -- seed; its change, a fresh output, joins the wallet.
    publishOne (role, script) held =
        case sortOn
            (Down . (^. coinTxOutL) . snd)
            [u | u@(k, o) <- held, k /= Left seed, adaOnlyOut o] of
            [] -> Left (PublicationUnfunded role (needed script) 0)
            (fund@(_, out) : _) ->
                let Coin inCoin = out ^. coinTxOutL
                    change = inCoin - fee - referenceCoin script
                in  if change > minimumChange
                        then
                            Right
                                ( filter ((/= fst fund) . fst) held
                                    <> [
                                           ( Right (length held)
                                           , out & coinTxOutL .~ Coin change
                                           )
                                       ]
                                )
                        else Left (PublicationUnfunded role (needed script) inCoin)
    -- The reference output is paid to the wallet's own address.
    referenceCoin script = case wallet of
        (_, o) : _ ->
            let probe =
                    mkBasicTxOut (o ^. addrTxOutL) (MaryValue (Coin 0) mempty)
                        & referenceScriptTxOutL .~ SJust script
                Coin minCoin = getMinCoinTxOut pp probe
            in  minCoin + 1_000_000
        [] -> 1_000_000
    needed script = referenceCoin script + fee + minimumChange
    fee = 1_000_000
    minimumChange = 1_000_000

{- | An inspect of an interrupted create may read its pending identity only
when the requested state token is the pending registry's own: the actor's
in-flight submission, never another registry's. The pending token is the
one the pending seed derives under this release; a token from any other
seed is refused before anything is read.
-}
checkPendingToken
    :: Asset
    -- ^ The token the pending seed derives
    -> Asset
    -- ^ The token the command names
    -> Either Text ()
checkPendingToken pending requested
    | pending == requested = Right ()
    | otherwise =
        Left
            ( "state-token mismatch: this directory's pending create makes "
                <> renderStateToken pending
                <> ", not "
                <> renderStateToken requested
            )
