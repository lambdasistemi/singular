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
    , shippedProcessTime
    , shippedRetractTime
    , shippedTip
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
    , selectSeed
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
    , mkBasicTxOut
    )
import Cardano.Ledger.BaseTypes (Network (..))
import Cardano.Ledger.Core (PParams, Script)
import Cardano.Ledger.Credential
    ( Credential (..)
    , StakeReference (..)
    )
import Cardano.Ledger.Mary.Value (MaryValue (..))
import Cardano.Ledger.TxIn (TxIn)
import Codec.Binary.Bech32 qualified as Bech32
import Control.Monad (when)

import Singular.CLI.Permanent (knownScripts)
import Singular.Registry.Application
    ( Application (..)
    , ApplicationPin (..)
    )
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
import Singular.Registry.TxBuilder.Edges
    ( PublicationFundingError (..)
    , adaOnlyOut
    , firstPublicationChange
    , publicationFee
    , publicationMinChange
    , publicationRefCoin
    , selectPublicationInputs
    )
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

-- | Read the registry blueprint a command was given, for the application it pins.
loadRelease :: Application -> FilePath -> IO (Either String Release)
loadRelease app = loadReleaseWith app True

{- | Read code for an explicitly supplied implementation fixture. This makes
no recognition claim; the shipping environment always uses 'loadRelease'.
-}
loadReleaseCodes
    :: Application -> FilePath -> IO (Either String Release)
loadReleaseCodes app = loadReleaseWith app False

loadReleaseWith
    :: Application -> Bool -> FilePath -> IO (Either String Release)
loadReleaseWith app recognize path = do
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
        state <- code "state.state"
        request <- code "request.request"
        -- The application code the pin names, or none when the pin is a hash
        -- or read from state (slice 2: its script bytes do not exist there).
        application <- case appPin app of
            PinByHash _ -> pure SBS.empty
            PinFromState -> pure SBS.empty
            PinByScript title -> code (T.unpack title)
            PinAsCompiled title -> code (T.unpack title)
        witness <- code "witness.witness"
        pure
            ( Release
                state
                request
                NamingCodes{ncApplication = application, ncWitness = witness}
            )

{- | The processing window, the retract window and the minimum tip a registry
is created with when the caller names none. They are the windows and tip the
release has always shipped. The registration cost and the widest booking
interval have no shipped value: the caller states both.
-}
shippedProcessTime, shippedRetractTime :: Integer
shippedProcessTime = 600_000
shippedRetractTime = 300_000

shippedTip :: Coin
shippedTip = Coin 1_000_000

{- | The configuration of the application registry this release boots from
this seed, and the codes as that registry runs them: the application
applied to the registry identity the seed determines, and
@witness(kind, registry)@ at kinds 0, 1 and 2.
-}
registryConfigFor
    :: Application
    -> Release
    -> RegistryEconomics
    -> OnChainTxOutRef
    -> (CageConfig, NamingCodes)
registryConfigFor app rel chosen =
    configForApplication
        (appPin app)
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
    | SoleSeedWhilePublishing Text
    | WalletChangedSinceNamed Text Text
    | RegistryExists FilePath
    | {- | A publication the wallet cannot fund: its role, the total it needs,
      and the largest single output, the total held and the whole run's
      lowest total need it reports. The triple keeps the three-argument
      shape existing callers match with wildcards.
      -}
      PublicationUnfunded Text Integer (Integer, Integer, Integer)
    | {- | A publication whose covering prefix would exceed the protocol
      maximum transaction size: its role, the size and the limit.
      -}
      PublicationTooLarge Text Integer Integer
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
    SoleSeedWhilePublishing seed ->
        "the seed "
            <> T.unpack seed
            <> " is the wallet's only ada-only output and the state script must be published from it; omit `--seed`: the first publication's change becomes the seed"
    WalletChangedSinceNamed expected actual ->
        "the wallet changed since the identity was named: expected "
            <> T.unpack expected
            <> ", now "
            <> T.unpack actual
            <> "; preview again and retry with the new seed"
    RegistryExists dir ->
        dir
            <> " already holds your state or its journal; create never \
               \overwrites one"
    PublicationUnfunded role needed (largest, held, runNeed) ->
        "publication-unfunded "
            <> T.unpack role
            <> ": this step needs "
            <> show needed
            <> " lovelace in total but the wallet holds "
            <> show held
            <> " in ada-only outputs (largest "
            <> show largest
            <> "); the whole run needs at least "
            <> show runNeed
            <> " lovelace; nothing was submitted"
    PublicationTooLarge role size limit ->
        "publication-unfunded "
            <> T.unpack role
            <> ": publishing this reference script needs a transaction size of "
            <> show size
            <> " bytes, over the protocol maximum "
            <> show limit
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

{- | The seed, as a create needs it: held ('seedHeld'). A wallet of one
ada-only output completes from the chained seed (#406 slice 2); the
sole-explicit-seed-while-publishing refusal lives in 'createWith', where
the chain says the state script must be published, not here.
-}
checkSeed
    :: TxIn
    -> [(TxIn, TxOut ConwayEra)]
    -> Either IdentityError (TxIn, TxOut ConwayEra)
checkSeed = seedHeld

{- | The seed checks a create applies, and the receipt fields they add. A
create about to submit needs the seed held ('checkSeed') and adds nothing.
A preview needs only the seed held ('seedHeld') and adds @createRefusal@:
null when held (the whole-run judgement in 'createWith' names funding),
or the held refusal itself.
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
        pure [("createRefusal", toJSON (Nothing :: Maybe Text))]

{- | The seed a create boots from (#406 slice 2), decided from the wallet
view and whether the state script must be published, before anything is
written. With a live carrier the seed is the wallet's largest ada-only
output; otherwise it is the first publication's change, computed from the
body before submission. An explicit seed names a held output, or the
previewed chained seed to pin the identity; any other unheld seed is
refused. A held sole output while the state must be published is refused
for submit (omit-`--seed`); for preview it is named with @output@ so the
caller reports the omit refusal itself. Pure in the wallet view, the
parameters, the state script and the carrier decision: no node read.
-}
selectSeed
    :: Maybe TxIn
    -- ^ explicit @--seed@, already parsed
    -> [(TxIn, TxOut ConwayEra)]
    -- ^ the wallet view
    -> PParams ConwayEra
    -> Script ConwayEra
    -- ^ the state script (seed-independent)
    -> Addr
    -- ^ the payer, for the change address
    -> Bool
    -- ^ whether the state script must be published (no live carrier)
    -> Bool
    -- ^ whether the identity is for a create about to submit
    -> Either IdentityError (TxIn, Text)
    -- ^ the seed and @seedFrom@ (@output@ or @publication-change@)
selectSeed explicit utxos pp stateScript payerAddr mustPublish submitting = case explicit of
    Just wanted -> case seedHeld wanted utxos of
        Right _ ->
            let sole = null [() | (i, o) <- utxos, i /= wanted, adaOnlyOut o]
            in  if sole && mustPublish && submitting
                    then Left (SoleSeedWhilePublishing (renderOutRef wanted))
                    else Right (wanted, "output")
        Left (SeedNotInWallet _) -> case (mustPublish, chainedNow) of
            (True, Right (chained, _, _, _, _))
                | chained == wanted ->
                    Right (wanted, "publication-change")
            _ -> Left (SeedNotInWallet (renderOutRef wanted))
        Left err -> Left err
    Nothing ->
        if mustPublish
            then case chainedNow of
                Right (chained, _, _, _, _) -> Right (chained, "publication-change")
                Left (PublicationShortfall needed held largest) ->
                    Left (PublicationUnfunded "state" needed (largest, held, needed))
                Left (PublicationOversize size limit) ->
                    Left (PublicationTooLarge "state" size limit)
            else case sortOn
                (Down . (^. coinTxOutL) . snd)
                [u | u@(_, o) <- utxos, adaOnlyOut o] of
                ((i, _) : _) -> Right (i, "output")
                [] -> Left (SeedNotInWallet "no ada-only output")
  where
    chainedNow = firstPublicationChange pp payerAddr stateScript utxos

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
publication funds from the shortest largest-first prefix of the ada-only
outputs, with its change returned, as 'Singular.Registry.TxBuilder.Edges.selectPublicationInputs'
funds it. When the seed is an output the wallet holds, the publications
before the boot leave it alone; when it is the first publication's change
(#406 slice 2, not held), the first publication spends a prefix of all the
ada-only outputs (nothing withheld) and its change is the seed. The boot spends
the seed and the largest ada-only output beside it (or the seed alone), as
'Singular.Registry.TxBuilder.Boot.bootTokenFrom' does, and returns what is
left of them after its cost as change, which the publications after it may
spend. Checked before anything is submitted; the first publication the
publisher would refuse is named, or @boot@ when the boot itself is not
funded. The refusal names the short step, the total it needs, the total held,
the largest output and the whole run's lowest total need.
-}
publicationFunding
    :: PParams ConwayEra
    -> TxIn
    -- ^ The seed: held ("output") or the first publication's change
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
    let payerAddr = case wallet of
            (_, o) : _ -> o ^. addrTxOutL
            [] -> error "publicationFunding: empty wallet"
        refCoins =
            [ publicationRefCoin pp payerAddr script
            | (_, script) <- before <> after
            ]
        runNeed =
            sum refCoins
                + fromIntegral (length before + length after) * publicationFee
                + bootCost
                + publicationMinChange
        held0 = [(Left i, o) | (i, o) <- wallet]
        seedHeldNow = seed `elem` map fst wallet
    if seedHeldNow
        then do
            left <- publishing payerAddr runNeed before held0
            booted <- booting runNeed left
            _ <- publishing payerAddr runNeed after booted
            pure ()
        else case before of
            [] ->
                let (heldTotal, largest) = heldTotals held0
                in  Left
                        ( PublicationUnfunded
                            "boot"
                            (bootCost + publicationMinChange)
                            (largest, heldTotal, runNeed)
                        )
            (role0, script0) : rest0 -> do
                -- The first publication from all ada-only outputs; its
                -- change is the seed the boot spends.
                let permitted0 = [u | u@(_, o) <- held0, adaOnlyOut o]
                (funds0, _, change0) <- case selectPublicationInputs pp payerAddr script0 permitted0 of
                    Left (PublicationShortfall needed heldTotal largest) ->
                        Left (PublicationUnfunded role0 needed (largest, heldTotal, runNeed))
                    Left (PublicationOversize size limit) ->
                        Left (PublicationTooLarge role0 size limit)
                    Right chosen -> pure chosen
                let spent0 = map fst funds0
                    seedOut = mkBasicTxOut payerAddr (MaryValue (Coin change0) mempty)
                    held1 =
                        [u | u@(k, _) <- held0, k `notElem` spent0]
                            <> [(Left seed, seedOut)]
                left <- publishing payerAddr runNeed rest0 held1
                booted <- booting runNeed left
                _ <- publishing payerAddr runNeed after booted
                pure ()
  where
    heldTotals held =
        let coins = [c | (_, o) <- held, adaOnlyOut o, let Coin c = o ^. coinTxOutL]
        in  (sum coins, case coins of [] -> 0; _ -> maximum coins)
    -- The boot spends the seed and the largest ada-only output beside it,
    -- and returns what is left after its cost as change.
    booting runNeed held = case [o | (k, o) <- held, k == Left seed] of
        [] ->
            let (heldTotal, largest) = heldTotals held
            in  Left
                    ( PublicationUnfunded
                        "boot"
                        (bootCost + publicationMinChange)
                        (largest, heldTotal, runNeed)
                    )
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
                (heldTotal, largest) = heldTotals held
            in  if change > publicationMinChange
                    then
                        Right
                            ( [u | u@(k, _) <- held, k `notElem` spent]
                                <> [(Right (length held), seedOut & coinTxOutL .~ Coin change)]
                            )
                    else
                        Left
                            ( PublicationUnfunded
                                "boot"
                                (bootCost + publicationMinChange)
                                (largest, heldTotal, runNeed)
                            )
    publishing payerAddr runNeed scripts held =
        foldl
            (\acc s -> acc >>= publishOne payerAddr runNeed s)
            (Right held)
            scripts
    -- One publication from the shortest largest-first prefix outside the
    -- seed; its change, a fresh output, joins the wallet.
    publishOne payerAddr runNeed (role, script) held =
        let permitted = [u | u@(k, o) <- held, k /= Left seed, adaOnlyOut o]
        in  case selectPublicationInputs pp payerAddr script permitted of
                Left (PublicationShortfall needed heldTotal largest) ->
                    Left (PublicationUnfunded role needed (largest, heldTotal, runNeed))
                Left (PublicationOversize size limit) ->
                    Left (PublicationTooLarge role size limit)
                Right (funds, _, changeCoin) ->
                    let spent = map fst funds
                        changeOut = mkBasicTxOut payerAddr (MaryValue (Coin changeCoin) mempty)
                    in  Right
                            ( filter ((`notElem` spent) . fst) held
                                <> [(Right (length held), changeOut)]
                            )

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
