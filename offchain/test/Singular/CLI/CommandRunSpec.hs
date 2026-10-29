{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- |
Module      : Singular.CLI.CommandRunSpec
Description : Shared in-process fixture for the retained commands
License     : Apache-2.0

The fixture applies submitted transactions to its outputs and uses accept-all
validators. StateCommandSpec exercises the retained create command through this
fixture. The retained pin, funding, settings, wallet and chain-fixture checks also remain
for their library and command consumers. Fixture execution does not establish
ledger acceptance.
-}
module Singular.CLI.CommandRunSpec
    ( spec
    , Rig (..)
    , Run (..)
    , withRig
    , withRigOf
    , run
    , runAt
    , runVia
    , runViaApp
    , envOf
    , capabilities
    , captured
    , readWallet
    , scriptPinned
    , policyArgs
    , tokenArgs
    , externalArgs
    , outcomeOf
    , textAt
    , valueAt
    , elementsAt
    , submissionsOf
    , receiptReason
    ) where

import Cardano.Ledger.Address (Addr (..), serialiseAddr)
import Cardano.Ledger.Api.Tx (bodyTxL, mkBasicTx, txIdTx)
import Cardano.Ledger.Api.Tx.Body
    ( AlonzoEraTxBody (reqSignerHashesTxBodyL)
    , EraTxBody
        ( feeTxBodyL
        , inputsTxBodyL
        , mkBasicTxBody
        , outputsTxBodyL
        )
    )
import Cardano.Ledger.Api.Tx.Out
    ( TxOut
    , addrTxOutL
    , coinTxOutL
    , datumTxOutL
    , mkBasicTxOut
    , referenceScriptTxOutL
    , valueTxOutL
    )
import Cardano.Ledger.BaseTypes
    ( Network (Testnet)
    , StrictMaybe (..)
    , TxIx (..)
    )
import Cardano.Ledger.Mary.Value
    ( AssetName (..)
    , MaryValue (..)
    , MultiAsset (..)
    , PolicyID (..)
    )
import Cardano.Ledger.TxIn (TxIn (..))
import Cardano.Ledger.Val (inject, (<->))
import Cardano.Tx.Balance (BalanceResult (..), balanceTx)
import Cardano.Tx.Ledger (ConwayTx)
import Control.Exception
    ( ErrorCall (ErrorCall)
    , bracket
    , finally
    , throwIO
    , try
    )
import Control.Monad (forM_, when)
import Control.Tracer (Tracer (..))
import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
    ( Key
    , Object
    , ToJSON (toJSON)
    , Value (Array, Bool, Null, Object, String)
    , decodeStrict
    , eitherDecodeStrict
    , encode
    , object
    )
import Data.Aeson.KeyMap qualified as KeyMap
    ( lookup
    , member
    , toList
    )
import Data.ByteString qualified as BS
    ( ByteString
    , appendFile
    , length
    , readFile
    , replicate
    , writeFile
    )
import Data.ByteString.Base16 qualified as B16 (decode, encode)
import Data.ByteString.Char8 qualified as BC
    ( pack
    , replicate
    , unpack
    )
import Data.ByteString.Lazy qualified as BL (writeFile)
import Data.ByteString.Short qualified as SBS
    ( ShortByteString
    , fromShort
    , toShort
    )
import Data.Foldable (toList)
import Data.IORef
    ( IORef
    , modifyIORef'
    , newIORef
    , readIORef
    , writeIORef
    )
import Data.List (isInfixOf, isPrefixOf, sort, sortOn)
import Data.Map.Strict qualified as Map
    ( Map
    , delete
    , fromList
    , insert
    , keys
    , null
    , singleton
    , toList
    , union
    , unionWith
    , unionsWith
    )
import Data.Maybe (isJust, listToMaybe)
import Data.Ord (Down (..))
import Data.Sequence.Strict qualified as StrictSeq
    ( fromList
    , singleton
    )
import Data.Set qualified as Set
    ( empty
    , fromList
    , singleton
    , toList
    )
import Data.Text (Text)
import Data.Text qualified as T
    ( isInfixOf
    , pack
    , splitOn
    , unpack
    )
import Data.Text.Encoding qualified as TE
    ( decodeUtf8
    , encodeUtf8
    )
import Lens.Micro ((&), (.~), (^.))
import PlutusCore.Data qualified as PLC (Data (Constr))
import Singular.CLI (runCommand)
import Singular.CLI.Command
    ( ApplicationPolicy (..)
    , Command (..)
    , CreateArgs (..)
    , EntryMode (..)
    , ProviderSettings (..)
    , WalletArgs
        ( WalletArgs
        , walletNetworkMagic
        , walletPassphraseFd
        , walletVaultPath
        )
    , WriteSettings (..)
    , parseCommand
    )
import Singular.CLI.Create (createApplication, runCreate)
import Singular.CLI.FlagGroup (Signer (..))
import Singular.CLI.Outlay
    ( bookingOutlay
    , outlayTotal
    , spendableHeld
    , updateOutlay
    )
import Singular.CLI.Passphrase
    ( mkPassphrase
    , passphraseVariable
    , publicNetworks
    )
import Singular.CLI.Prepare
    ( PrepareRefusal (AllowanceExceeded, PreparationShortfall)
    , measureRequirement
    , preparationFields
    , prepareFunding
    , previewFunding
    )
import Singular.CLI.Receipt
    ( JournalEntry (journalEvent, journalExpect, journalTxId)
    , OutcomeClass (Success)
    , outcomeName
    , readJournal
    )
import Singular.CLI.Registry
    ( economics
    , loadRelease
    , loadReleaseCodes
    , registryConfigFor
    )
import Singular.CLI.Session
    ( Env (..)
    , WriteContext
        ( WriteContext
        , wcCaller
        , wcCapabilities
        , wcCommand
        , wcDir
        , wcSource
        , wcStaged
        , wcTimeout
        , wcTracer
        , wcWallet
        )
    , txIdHex
    )
import Singular.CLI.SettingsFile (keepStateToken)
import Singular.CLI.Trace
    ( Event (How)
    , How (Tx)
    , Trace (Trace)
    , TxEvent (TxSubmitted, submitStep)
    )
import Singular.CLI.Vault
    ( createVaultFile
    , sealVault
    , vaultWorkFactor
    )
import Singular.Registry.Application
    ( Application (..)
    , ApplicationPin (PinByScript)
    , hashPinnedApplication
    , neutralApplication
    )
import Singular.Registry.Capabilities (Capabilities (..))
import Singular.Registry.Config (CageConfig (..))
import Singular.Registry.Config.Application
    ( RegistryEconomics (..)
    )
import Singular.Registry.Deployment (parseOutRef, renderOutRef)
import Singular.Registry.Evidence
    ( Evidenced (..)
    , NoWitness
    , unverifiedVerifier
    )
import Singular.Registry.Ledger
    ( Coin (..)
    , ConwayEra
    , PParams
    , TokenId (..)
    )
import Singular.Registry.LedgerProvider qualified as Cage
    ( ChainPoint (At)
    , InclusionStatus (IncludedAt)
    , Outputs
    , Session (inclusion)
    , SubmitResult (SubmitAccepted)
    , TipObservation (observedHash, observedSlot)
    )
import Singular.Registry.Lifecycle (protocolFeeReserve)
import Singular.Registry.RawChainFixture
    ( ChainFacts
        ( ChainFacts
        , csNetwork
        , csNetworkTime
        , csPParams
        , csRegistered
        , csTip
        , csUTxO
        )
    , RawChain
    , advanceChain
    , newRawChain
    , rawChainProvider
    , recordTransaction
    )
import Singular.Registry.SessionEvidence (observeProvider)
import Singular.Registry.SessionIO qualified as SessionIO
    ( outputsAt
    , parameters
    , tip
    , withLatest
    )
import Singular.Registry.Signing (SignedTx, signTx, signedTx)
import Singular.Registry.SyntheticLedger
    ( unitProgram
    , withSyntheticCosts
    )
import Singular.Registry.SyntheticTime (syntheticTime)
import Singular.Registry.TxBuilder.BookingFixture (preprodParams)
import Singular.Registry.TxBuilder.Edges
    ( adaOnlyOut
    , selectFunding
    )
import Singular.Registry.TxBuilder.Internal
    ( addrFromKeyHashBytes
    , addrKeyHashBytes
    , approvalDestination
    , approvalName
    , computeScriptHash
    , extractCageDatum
    , extractOwnerBytes
    , mkInlineDatum
    , policyIdFromPin
    , requestAddrFromCfg
    , scriptHashBytes
    , toPlcData
    )
import Singular.Registry.TxBuilder.Internal.Identity
    ( addrWitnessKeyHash
    , txInToRef
    )
import Singular.Registry.TxBuilder.Prepare
    ( Preparation (..)
    , planPreparation
    , spendableOuts
    )
import Singular.Registry.TxBuilder.Request (requestEdgeImpl)
import Singular.Registry.Types
    ( CageDatum (RequestDatum)
    , OnChainRequest
        ( requestDestination
        , requestEdge
        , requestKey
        , requestSubmittedAt
        )
    , edgeInsertActive
    )
import Singular.Registry.Wallet
    ( Wallet (walletAddr, walletSignKey)
    , bech32Address
    , loadWallet
    )
import System.Directory
    ( createDirectoryIfMissing
    , doesDirectoryExist
    , doesPathExist
    , listDirectory
    , renameDirectory
    , renameFile
    )
import System.Exit (ExitCode (..))
import System.FilePath (makeRelative, (</>))
import System.IO (hFlush, stderr, stdout)
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Env.ByteString qualified as PosixEnv
    ( getEnv
    , setEnv
    , unsetEnv
    )
import System.Posix.IO
    ( OpenFileFlags (..)
    , OpenMode (..)
    , closeFd
    , defaultFileFlags
    , dup
    , dupTo
    , openFd
    , stdError
    , stdOutput
    )
import System.Posix.Types (Fd (..))
import Test.Hspec
    ( Spec
    , describe
    , expectationFailure
    , it
    , shouldBe
    , shouldContain
    , shouldNotBe
    , shouldNotContain
    , shouldNotSatisfy
    , shouldReturn
    , shouldSatisfy
    )

spec :: Spec
spec =
    permanentRecognition
        >> previewFundingRows
        >> receiptDecidesRows
        >> inclusionPointRows
        >> walletVariableRow

permanentRecognition :: Spec
permanentRecognition = describe "Permanent contract recognition"
    $ it
        "refuses a caller supplied blueprint whose script identities are unknown"
    $ withRig
    $ \rig -> do
        loaded <- loadRelease neutralApplication (rigBlueprint rig)
        case loaded of
            Left _ -> pure ()
            Right _ ->
                expectationFailure "unknown scripts were recognized as permanent M1"

constructorOf :: Command -> String
constructorOf = \case
    Help _ -> "Help"
    Fold _ -> "Fold"
    RegistryInspect _ -> "RegistryInspect"
    StateCreate _ -> "StateCreate"
    WalletCreate _ -> "WalletCreate"
    WalletAddress _ -> "WalletAddress"
    WalletSign _ -> "WalletSign"
    SubmitBundle _ -> "SubmitBundle"

-- | The bounded chain fixture, owned by withRig.
data Rig = Rig
    { rigDir :: FilePath
    , rigChain :: RawChain
    , rigWallet :: Wallet
    , rigKey :: FilePath
    , rigBlueprint :: FilePath
    , rigEvents :: IORef [Trace]
    , rigAnswer :: IORef (Maybe Cage.SubmitResult)
    -- ^ When set, what the provider answers the next submission instead of taking it
    , rigTracer :: Tracer IO Trace
    -- ^ What the commands trace into: the collector, or a composition holding it
    }

-- | One command run: its constructor, a label, its exit, its receipt and its events.
data Run = Run
    { runName :: String
    , runLabel :: String
    , runExit :: ExitCode
    , runReceipt :: Aeson.Value
    , runEvents :: [Trace]
    , runKey :: Maybe Text
    -- ^ The key the command line names, base16
    }

magic :: Integer
magic = 42

withRig :: (Rig -> IO a) -> IO a
withRig = withRigVia pure

-- | The rig, its commands tracing into a composition built around its collector.
withRigVia
    :: (Tracer IO Trace -> IO (Tracer IO Trace)) -> (Rig -> IO a) -> IO a
withRigVia = withRigOf syntheticBlueprint

-- | The rig over this blueprint.
withRigOf
    :: Aeson.Value
    -> (Tracer IO Trace -> IO (Tracer IO Trace))
    -> (Rig -> IO a)
    -> IO a
withRigOf blueprintJson compose use =
    withSystemTempDirectory "command-run" $ \dir ->
        withRigIn dir blueprintJson compose use

-- | The rig over this blueprint, in this directory.
withRigIn
    :: FilePath
    -> Aeson.Value
    -> (Tracer IO Trace -> IO (Tracer IO Trace))
    -> (Rig -> IO a)
    -> IO a
withRigIn dir blueprintJson compose use = do
    let keyPath = dir </> "payment.skey"
        blueprint = dir </> "plutus.json"
    BS.writeFile keyPath (B16.encode (BC.replicate 32 'w'))
    BL.writeFile blueprint (Aeson.encode blueprintJson)
    BL.writeFile
        (dir </> "payload.json")
        (Aeson.encode (Aeson.object ["int" .= (7 :: Int)]))
    BL.writeFile
        (dir </> "payload-2.json")
        (Aeson.encode (Aeson.object ["int" .= (8 :: Int)]))
    wallet <- loadWallet (fromIntegral magic) keyPath
    chain <-
        newRawChain
            ChainFacts
                { csNetwork = fromIntegral magic
                , csTip = Nothing
                , csPParams = withSyntheticCosts preprodParams
                , csUTxO =
                    Map.fromList
                        [ ( fundOutput n
                          , mkBasicTxOut
                                (walletAddr wallet)
                                (MaryValue (Coin 2_000_000_000) mempty)
                          )
                        | n <- [1 .. 6]
                        ]
                , csRegistered = Set.empty
                , csNetworkTime = syntheticTime
                }
    advanceChain chain id
    events <- newIORef []
    answer <- newIORef Nothing
    tracer <- compose (Tracer (\t -> modifyIORef' events (<> [t])))
    use (Rig dir chain wallet keyPath blueprint events answer tracer)

-- | A wallet output at the start of the chain.
fundOutput :: Int -> TxIn
fundOutput n =
    either
        (error . ("fundOutput: " <>))
        id
        (parseOutRef (T.pack (replicate 64 'f' <> "#" <> show n)))

{- | The registry's validators as accept-all programs, each taking the
parameters the builders apply and then the script context.
-}
syntheticBlueprint :: Aeson.Value
syntheticBlueprint = blueprintOf (const unitProgram)

-- | The registry's validators, each program made from its title and arity.
blueprintOf :: (Text -> Int -> SBS.ShortByteString) -> Aeson.Value
blueprintOf program =
    Aeson.object
        [ "preamble"
            .= Aeson.object
                ["title" .= ("synthetic" :: Text), "plutusVersion" .= ("v3" :: Text)]
        , "validators"
            .= [ validator "state.state" 1
               , validator "request.request" 3
               , validator "script-app.script-app" 2
               , validator "witness.witness" 3
               , validator "witness.witness" 3
               , validator "singular_state.singular_state.spend" 2
               ]
        , "definitions" .= Aeson.object []
        ]
  where
    validator :: Text -> Int -> Aeson.Value
    validator title arity =
        let code = program title arity
        in  Aeson.object
                [ "title" .= title
                , "redeemer" .= Aeson.object ["schema" .= Aeson.object []]
                , "hash"
                    .= TE.decodeUtf8 (B16.encode (scriptHashBytes (computeScriptHash code)))
                , "compiledCode" .= TE.decodeUtf8 (B16.encode (SBS.fromShort code))
                ]

-- | The environment of a run over the rig: the fixture's capabilities.
envOf :: Rig -> Env
envOf rig =
    Env
        { envTracer = rigTracer rig
        , envSource = "fixture"
        , envLoadRelease = loadReleaseCodes
        , envReads = \_ k -> k (capabilities rig)
        , envReaderReads = \_ k -> k (capabilities rig)
        , envWrites = \_ k -> k (capabilities rig)
        }

-- | Reads of the chain fixture, and a submission it applies to its outputs.
capabilities :: Rig -> Capabilities NoWitness IO
capabilities rig =
    Capabilities
        { capReads =
            let (network, provider) = rawChainProvider (rigChain rig)
            in  (network, observeProvider unverifiedVerifier (\_ -> pure ()) provider)
        , capSubmit = \signed ->
            readIORef (rigAnswer rig) >>= \case
                Just answer -> writeIORef (rigAnswer rig) Nothing >> pure answer
                Nothing -> do
                    let tx = signedTx signed
                        txid = txIdTx tx
                        spent = Set.toList (tx ^. bodyTxL . inputsTxBodyL)
                        made = zip [0 ..] (toList (tx ^. bodyTxL . outputsTxBodyL))
                    recordTransaction (rigChain rig) tx
                    advanceChain (rigChain rig) $ \facts ->
                        facts
                            { csUTxO =
                                Map.union
                                    (Map.fromList [(TxIn txid (TxIx ix), out) | (ix, out) <- made])
                                    (foldr Map.delete (csUTxO facts) spent)
                            }
                    pure (Cage.SubmitAccepted txid)
        , capConfirm = \_ -> pure ()
        , capFacts = pure []
        , capTrace = pure []
        }

{- | The rig's capabilities with every exact-input read answered by this —
a refused read as a typed failure, or a successful empty answer — every
other read served by the chain as it stands: a provider that cannot
make one read, or one that answers nothing there, not one that is down.
-}
tokenArgs :: String -> [String]
tokenArgs t = ["--state-token", t]

-- ---------------------------------------------------------
-- A wallet whose ada sits beside approvals (#491 remainder, PR 1)
-- ---------------------------------------------------------

-- | The wallet outputs read from the fixture provider.
readWallet :: Rig -> IO [(TxIn, TxOut ConwayEra)]
readWallet rig =
    SessionIO.withLatest (rawChainProvider (rigChain rig)) $ \v ->
        SessionIO.outputsAt v (walletAddr (rigWallet rig))

{- | Every file under a directory with its bytes, each path recorded
relative to the FIXED root given: a relocation, a rename, a deletion and
an append all change the snapshot. A refusal that submits nothing must
leave the whole state directory byte-identical, journal, saved bodies
and all.
-}
run :: Rig -> String -> [String] -> IO Run
run rig = runAt rig "registry"

-- | The same, against the registry in this directory of the rig.
runAt :: Rig -> FilePath -> String -> [String] -> IO Run
runAt rig = runVia rig (envOf rig)

{- | The same, over an environment of the caller's: the packaged one, or
one whose provider cannot answer a read.
-}
runVia :: Rig -> Env -> FilePath -> String -> [String] -> IO Run
runVia rig env = runViaApp rig env neutralApplication

{- | The same, composing the caller's application value: the neutral value
for the switched creates (the policy comes through the parser), another
value for the refusal rows.
-}
runViaApp
    :: Rig -> Env -> Application -> FilePath -> String -> [String] -> IO Run
runViaApp rig env app registry label args = do
    writeIORef (rigEvents rig) []
    command <-
        either
            (fail . show)
            pure
            (parseCommand (commandLine rig registry args))
    (code, out, _) <-
        captured
            (runCommand app env command)
    receipt <-
        maybe
            (fail ("no receipt for " <> label <> ": " <> show out))
            pure
            (Aeson.decodeStrict out)
    events <- readIORef (rigEvents rig)
    pure
        Run
            { runName = constructorOf command
            , runLabel = label
            , runExit = code
            , runReceipt = receipt
            , runEvents = events
            , runKey =
                listToMaybe
                    [ hexText (TE.encodeUtf8 (T.pack k))
                    | ("--key", k) <- zip args (drop 1 args)
                    ]
            }

{- | A command line through the same dispatch and receipt plumbing, over
a provider that answers every exact-input read with this: a refused
read as a typed failure, or a successful empty answer — the read-back
a create must make of a reference it just published.
-}
commandLine :: Rig -> FilePath -> [String] -> [String]
commandLine rig registry args
    | take 1 args == ["submit"] =
        args
            <> [ "--koios-url"
               , "http://fixture.invalid"
               , "--network-magic"
               , show magic
               ]
    | otherwise =
        args
            <> ["--state-dir", rigDir rig </> registry]
            <> [ "--blueprint"
               , rigBlueprint rig
               , "--koios-url"
               , "http://fixture.invalid"
               , "--network-magic"
               , show magic
               ]
            <> ["--wallet-skey" | wantsKey]
            <> [rigKey rig | wantsKey]
  where
    wantsKey = not (any (`elem` args) ["--wallet-address", "--bundle", "--vault"])

-- ---------------------------------------------------------
-- --application-policy (#528)
-- ---------------------------------------------------------

{- | The policy the switched creates pin, through the parser: 28 0x07
bytes as hex, computed here at run time and never typed.
-}
policyArgs :: [String]
policyArgs = ["--application-policy", T.unpack (hexText (BS.replicate 28 7))]

-- | The refusal reason a receipt names.
receiptReason :: Run -> Maybe Text
receiptReason r = textAt "reason" (runReceipt r)

{- | A script-pinned value, standing in for the application's value the
registry-cli never names: the pin comes from the script.
-}
scriptPinned :: Application
scriptPinned =
    Application
        { appName = Just "script-app"
        , appExecutable = Just "script-app"
        , appPin = PinByScript "script-app.script-app"
        , appDecoder = Nothing
        , appHolding = Nothing
        }

{- | Run a create pinning these policy bytes through the flag, and check
the receipt's pins, the published references and the state datum on the
chain.
-}
outcomeOf :: Aeson.Value -> Maybe Text
outcomeOf = textAt "outcome"

textAt :: Aeson.Key -> Aeson.Value -> Maybe Text
textAt k = \case
    Aeson.Object o | Just (Aeson.String t) <- KeyMap.lookup k o -> Just t
    _ -> Nothing

-- | Every object in a value, itself included.
valueAt :: Aeson.Key -> Aeson.Value -> Maybe Aeson.Value
valueAt k = \case
    Aeson.Object o -> KeyMap.lookup k o
    _ -> Nothing

-- | The elements of an array field.
elementsAt :: Aeson.Key -> Aeson.Value -> Maybe [Aeson.Value]
elementsAt k v = case valueAt k v of
    Just (Aeson.Array xs) -> Just (toList xs)
    _ -> Nothing

-- | The receipt's submissions: step, transaction id, case and whether observed.
submissionsOf :: Aeson.Value -> [(Text, Text, Maybe Text, Bool)]
submissionsOf = \case
    Aeson.Object o
        | Just (Aeson.Array xs) <- KeyMap.lookup "submissions" o ->
            [ (s, t, c, observed)
            | Aeson.Object x <- toList xs
            , let c = case KeyMap.lookup "case" x of
                    Just (Aeson.String v) -> Just v
                    _ -> Nothing
                  observed = KeyMap.lookup "observed" x == Just (Aeson.Bool True)
            , Just (Aeson.String s) <- [KeyMap.lookup "step" x]
            , Just (Aeson.String t) <- [KeyMap.lookup "tx" x]
            ]
    _ -> []

{- | The edge actions a command performs, by its receipt's command: create
boots, insert and terminate book the edge their plan books (and fold it when
asked), update updates, reject rejects, fold and reclaim act on the edge
their receipt names. Inspect performs none.
-}
hexText :: BS.ByteString -> Text
hexText = TE.decodeUtf8 . B16.encode

{- | One contradiction planted per fact a stream carries, wherever the
receipt binds that fact: each altered stream must disagree with the
unaltered receipt. Every event is altered in each fact it carries, its
scopes included; an observation is also removed. A refusal is altered only to
kinds its outcome cannot stand under.
-}
captured :: IO a -> IO (a, BS.ByteString, BS.ByteString)
captured act = withSystemTempDirectory "command-run-captured" $ \dir -> do
    let outPath = dir </> "stdout"
        errPath = dir </> "stderr"
    a <- redirecting stdOutput outPath (redirecting stdError errPath act)
    (,,) a <$> BS.readFile outPath <*> BS.readFile errPath

redirecting :: Fd -> FilePath -> IO a -> IO a
redirecting target path act =
    bracket
        ( do
            hFlush stdout >> hFlush stderr
            saved <- dup target
            f <-
                openFd
                    path
                    WriteOnly
                    defaultFileFlags{creat = Just 0o644, trunc = True}
            _ <- dupTo f target
            closeFd f
            pure saved
        )
        ( \saved -> do
            hFlush stdout >> hFlush stderr
            _ <- dupTo saved target
            closeFd saved
        )
        (const act)

-- | Every fact 'alterations' plants a contradiction in.
externalArgs :: Rig -> FilePath -> [String]
externalArgs rig bundlePath =
    [ "--wallet-address"
    , bech32Address (walletAddr (rigWallet rig))
    , "--bundle"
    , bundlePath
    ]

-- | The bech32 spelling of an address whose payment part is a script.
reshapeRehearsalWallet
    :: Rig -> Map.Map PolicyID (Map.Map AssetName Integer) -> IO Int
reshapeRehearsalWallet rig approvals = do
    when (Map.null approvals) $
        fail "reshapeRehearsalWallet: no certified approvals to hold"
    wallet <-
        SessionIO.withLatest (rawChainProvider (rigChain rig)) $ \v ->
            SessionIO.outputsAt v (walletAddr (rigWallet rig))
    case sortOn (Down . adaOf . snd) [u | u@(_, o) <- wallet, adaOnlyOut o] of
        [] ->
            fail
                "reshapeRehearsalWallet: the wallet holds no ada-only output to reshape"
        ((heldIn, heldOut) : rest) -> do
            let Coin lovelace = heldOut ^. coinTxOutL
                made =
                    heldOut
                        & valueTxOutL .~ MaryValue (Coin lovelace) (MultiAsset approvals)
            advanceChain (rigChain rig) $ \facts ->
                facts
                    { csUTxO =
                        Map.insert
                            heldIn
                            made
                            (foldr (Map.delete . fst) (csUTxO facts) rest)
                    }
            pure (length [n | (_, ns) <- Map.toList approvals, n <- Map.keys ns])
  where
    adaOf out = let Coin c = out ^. coinTxOutL in c

{- | Certify the planted requests as real bookings do, then report the
certified assets: for each planted request output, read its datum and bytes
at run time and derive the expected commitment exactly as the fold's own
selection does — @approvalName@ over the request's edge, key and owner with
@approvalDestination@ over the request's destination — under the registry's
application pin read at run time. Planted requests carry no destination
datum, which the neutral fold refuses as unreadable, so each datum is
rewritten first with the wallet address and a stand-in carried datum
(lovelace, edge, key, owner, deposit and submission time untouched); the
commitment is derived from the rewritten datum, exactly what the fold
reads. The rewritten request outputs carry what a certified booking locks,
so the fold's selection passes them for the production reason; the union is
what the rehearsal wallet holds beside its ada, as the devnet legs show a
reject's change doing. Nothing is typed except the key labels the plants
already use.
-}
certifyPlanted
    :: Rig
    -> String
    -> String
    -> RegistryEconomics
    -> [TxIn]
    -> IO (Map.Map PolicyID (Map.Map AssetName Integer))
certifyPlanted rig tokenStr seedStr econ reqIns = do
    seedIn <-
        either
            (fail . ("certifyPlanted seed: " <>))
            pure
            (parseOutRef (T.pack seedStr))
    tid <- parseTokenId tokenStr
    let dummy = hashPinnedApplication (SBS.toShort (BS.replicate 28 7))
    rel <- loadReleaseCodes dummy (rigBlueprint rig) >>= either fail pure
    let (cfg, _) = registryConfigFor dummy rel econ (txInToRef seedIn)
        pinned = policyIdFromPin (cfgApplicationPolicy cfg)
        walletAt = walletAddr (rigWallet rig)
        walletBytes = serialiseAddr walletAt
        reqAddr = requestAddrFromCfg cfg tid Testnet
    atReq <-
        SessionIO.withLatest (rawChainProvider (rigChain rig)) $ \v ->
            SessionIO.outputsAt v reqAddr
    let found = [(i, o) | (i, o) <- atReq, i `elem` reqIns]
    when (length found /= length reqIns) $
        fail "certifyPlanted: a planted request output is missing"
    certRows <- mapM (certifyOne pinned walletBytes) found
    advanceChain (rigChain rig) $ \facts ->
        facts
            { csUTxO =
                foldr (\(i, _, o) m -> Map.insert i o m) (csUTxO facts) certRows
            }
    pure
        ( Map.unionsWith
            (Map.unionWith (+))
            [a | (_, a, _) <- certRows]
        )
  where
    certifyOne pinned walletBytes (i, o) = case extractCageDatum o of
        Just (RequestDatum req) -> do
            let req' = req{requestDestination = (walletBytes, Just (PLC.Constr 0 []))}
                expected =
                    approvalName
                        (requestEdge req')
                        (requestKey req')
                        (extractOwnerBytes o)
                        (approvalDestination (requestDestination req'))
                asset =
                    Map.singleton
                        pinned
                        (Map.singleton (AssetName (SBS.toShort expected)) 1)
                Coin lovelace = o ^. coinTxOutL
                made =
                    o
                        & datumTxOutL .~ mkInlineDatum (toPlcData (RequestDatum req'))
                        & valueTxOutL .~ MaryValue (Coin lovelace) (MultiAsset asset)
            pure (i, asset, made)
        _ ->
            fail
                "certifyPlanted: a planted request output carries no request datum"

-- | Every output of the rig wallet, read at run time.
snapshotDir :: FilePath -> IO [(FilePath, BS.ByteString)]
snapshotDir root = walk root
  where
    walk dir = do
        names <- sort <$> listDirectory dir
        fmap concat (mapM one names)
      where
        one n = do
            let p = dir </> n
            isDir <- doesDirectoryExist p
            if isDir
                then walk p
                else do
                    bytes <- BS.readFile p
                    pure [(makeRelative root p, bytes)]

-- | How many wallet outputs carry a reference script.
shortenWallet :: Rig -> Integer -> IO ()
shortenWallet rig lovelace = do
    wallet <- readWallet rig
    case [ u
         | u@(_, o) <- wallet
         , not (adaOnlyOut o)
         , o ^. referenceScriptTxOutL == SNothing
         ] of
        [] -> fail "shortenWallet: no token-carrying output to shrink"
        ((i, o) : _) ->
            let MaryValue _ m = o ^. valueTxOutL
            in  advanceChain (rigChain rig) $ \facts ->
                    facts
                        { csUTxO =
                            Map.insert
                                i
                                (o & valueTxOutL .~ MaryValue (Coin lovelace) m)
                                (csUTxO facts)
                        }

previewFundingRows :: Spec
previewFundingRows = describe
    "previewFunding plans without submitting (#491 PR2)"
    $ do
        it "a funded wallet previews with no preparation and submits nothing" $ withRig $ \rig -> do
            _ <- fundSeed rig
            _ <- createLegacyFixture rig
            walletBefore <- readWallet rig
            let payer = walletAddr (rigWallet rig)
            dummy <- SessionIO.withLatest (rawChainProvider (rigChain rig)) $ \v -> do
                pp <- SessionIO.parameters v
                dummyTxFromWallet pp payer walletBefore
            chainBefore <- readWallet rig
            result <- SessionIO.withLatest (rawChainProvider (rigChain rig)) $ \v ->
                previewFunding
                    "fold"
                    payer
                    Nothing
                    Nothing
                    updateOutlay
                    (\_ -> pure dummy)
                    v
            case result of
                Right (shown, Nothing, tx) -> do
                    tx `shouldBe` dummy
                    shown `shouldSatisfy` (not . null)
                other ->
                    expectationFailure
                        ("funded preview planned unexpectedly: " <> show (voidPrep other))
            chainAfter <- readWallet rig
            chainAfter `shouldBe` chainBefore
        it "a token-only wallet previews one preparation and submits nothing" $ withRig $ \rig -> do
            seed <- fundSeed rig
            create <- createLegacyFixture rig
            t1 <- legacyToken create
            let keyA = TE.encodeUtf8 "carol-a"
                keyB = TE.encodeUtf8 "carol-b"
            (reqA, _) <- plantRequest rig t1 seed economics keyA
            (reqB, _) <- plantRequest rig t1 seed economics keyB
            assets <- certifyPlanted rig t1 seed economics [reqA, reqB]
            _ <- reshapeRehearsalWallet rig assets
            wallet <- readWallet rig
            [o | (_, o) <- wallet, adaOnlyOut o] `shouldBe` []
            let payer = walletAddr (rigWallet rig)
            dummy <- SessionIO.withLatest (rawChainProvider (rigChain rig)) $ \v -> do
                pp <- SessionIO.parameters v
                dummyTxFromWallet pp payer wallet
            chainBefore <- readWallet rig
            result <- SessionIO.withLatest (rawChainProvider (rigChain rig)) $ \v ->
                previewFunding
                    "fold"
                    payer
                    Nothing
                    Nothing
                    updateOutlay
                    (buildFundingAware dummy payer)
                    v
            case result of
                Right (shown, Just prep, tx) -> do
                    tx `shouldBe` dummy
                    shown `shouldBe` [prepFunding prep]
                    prepFundingCoin prep `shouldSatisfy` (> 0)
                    prepFee prep `shouldSatisfy` (> 0)
                    case preparationFields (Just prep) of
                        [(_, Aeson.Object o)] -> do
                            KeyMap.member "transaction" o `shouldBe` True
                            KeyMap.member "output" o `shouldBe` True
                            KeyMap.member "lovelace" o `shouldBe` True
                            KeyMap.member "fee" o `shouldBe` True
                        _ -> expectationFailure "preview preparation has another shape"
                other ->
                    expectationFailure
                        ("token-only preview planned unexpectedly: " <> show (voidPrep other))
            chainAfter <- readWallet rig
            chainAfter `shouldBe` chainBefore
        it "preview figures equal the actual preparation on the same wallet" $ withRig $ \rig -> do
            seed <- fundSeed rig
            create <- createLegacyFixture rig
            t1 <- legacyToken create
            let keyA = TE.encodeUtf8 "carol-a"
                keyB = TE.encodeUtf8 "carol-b"
            (reqA, _) <- plantRequest rig t1 seed economics keyA
            (reqB, _) <- plantRequest rig t1 seed economics keyB
            assets <- certifyPlanted rig t1 seed economics [reqA, reqB]
            _ <- reshapeRehearsalWallet rig assets
            wallet <- readWallet rig
            [o | (_, o) <- wallet, adaOnlyOut o] `shouldBe` []
            let payer = walletAddr (rigWallet rig)
            eventsBefore <- readIORef (rigEvents rig)
            chainBefore <- readWallet rig
            previewed <- SessionIO.withLatest (rawChainProvider (rigChain rig)) $ \v ->
                previewFunding
                    "fold"
                    payer
                    Nothing
                    Nothing
                    updateOutlay
                    (buildFromView payer)
                    v
            (prepPreview, overTxPreview) <- case previewed of
                Right (_, Just prep, tx) -> pure (prep, tx)
                other -> fail ("preview did not plan: " <> show (voidPrep other))
            eventsAfterPreview <- readIORef (rigEvents rig)
            length eventsAfterPreview `shouldBe` length eventsBefore
            chainAfterPreview <- readWallet rig
            chainAfterPreview `shouldBe` chainBefore
            ppPreview <-
                SessionIO.withLatest
                    (rawChainProvider (rigChain rig))
                    SessionIO.parameters
            let requirement = measureRequirement ppPreview payer overTxPreview
            prepFundingCoin prepPreview `shouldSatisfy` (>= requirement)
            prepFee prepPreview `shouldSatisfy` (> 0)
            (prepFee prepPreview < prepFundingCoin prepPreview) `shouldBe` True
            let wc =
                    WriteContext
                        { wcDir = rigDir rig
                        , wcCommand = "preview-test"
                        , wcWallet = Just (rigWallet rig)
                        , wcCaller = walletAddr (rigWallet rig)
                        , wcCapabilities = capabilities rig
                        , wcTimeout = Nothing
                        , wcTracer = rigTracer rig
                        , wcSource = "fixture"
                        , wcStaged = Nothing
                        }
            actual <- SessionIO.withLatest (rawChainProvider (rigChain rig)) $ \v ->
                prepareFunding
                    wc
                    "fold"
                    payer
                    Nothing
                    Nothing
                    updateOutlay
                    (buildFromView payer)
                    v
            (prepReal, _) <- case actual of
                Right (_, Just prep, tx) -> pure (prep, tx)
                other -> fail ("real did not prepare: " <> show (voidPrep other))
            txIdTx (prepTx prepPreview) `shouldBe` txIdTx (prepTx prepReal)
            prepFundingCoin prepPreview `shouldBe` prepFundingCoin prepReal
            prepFee prepPreview `shouldBe` prepFee prepReal
            eventsAfterReal <- readIORef (rigEvents rig)
            length eventsAfterReal `shouldSatisfy` (> length eventsBefore)
            chainAfterReal <- readWallet rig
            chainAfterReal `shouldNotBe` chainBefore
        it "an explicit smaller ada-only choice is used with no preparation" $ withRig $ \rig -> do
            _ <- fundSeed rig
            _ <- createLegacyFixture rig
            walletBefore <- readWallet rig
            let payer = walletAddr (rigWallet rig)
            (bigIn, bigCoin) <- case sortOn
                (Down . snd)
                [ (i, c)
                | (i, o) <- walletBefore
                , adaOnlyOut o
                , let Coin c = o ^. coinTxOutL
                ] of
                (i, c) : _ -> pure (i, c)
                [] -> fail "explicit preview leg: no ada-only output to split"
            bigOut <- case [o | (i, o) <- walletBefore, i == bigIn] of
                [o] -> pure o
                _ -> fail "explicit preview leg: split output vanished"
            let smallCoin = bigCoin `div` 3
                largeCoin = bigCoin - smallCoin
            when (smallCoin <= 0 || largeCoin <= smallCoin) $
                fail "explicit preview leg: cannot split an eligible pair"
            smallIn <-
                either fail pure (parseOutRef (T.pack (replicate 64 'd' <> "#1")))
            largeIn <-
                either fail pure (parseOutRef (T.pack (replicate 64 'd' <> "#2")))
            let mkSmall = bigOut & valueTxOutL .~ MaryValue (Coin smallCoin) mempty
                mkLarge = bigOut & valueTxOutL .~ MaryValue (Coin largeCoin) mempty
            advanceChain (rigChain rig) $ \facts ->
                facts
                    { csUTxO =
                        Map.insert
                            smallIn
                            mkSmall
                            (Map.insert largeIn mkLarge (Map.delete bigIn (csUTxO facts)))
                    }
            eventsBefore <- readIORef (rigEvents rig)
            chainBefore <- readWallet rig
            result <- SessionIO.withLatest (rawChainProvider (rigChain rig)) $ \v ->
                previewFunding
                    "fold"
                    payer
                    (Just smallIn)
                    Nothing
                    updateOutlay
                    (buildFromView payer)
                    v
            case result of
                Right (shown, Nothing, tx) -> do
                    shown `shouldBe` [smallIn]
                    shown `shouldNotContain` [largeIn]
                    let spent = Set.toList (tx ^. bodyTxL . inputsTxBodyL)
                    spent `shouldContain` [smallIn]
                    spent `shouldNotContain` [largeIn]
                other ->
                    expectationFailure
                        ("named preview planned unexpectedly: " <> show (voidPrep other))
            chainAfter <- readWallet rig
            chainAfter `shouldBe` chainBefore
            eventsAfter <- readIORef (rigEvents rig)
            eventsAfter `shouldBe` eventsBefore
        it
            "a short wallet is refused before signing with nothing submitted"
            $ withRig
            $ \rig -> do
                seed <- fundSeed rig
                create <- createLegacyFixture rig
                t1 <- legacyToken create
                let keyR = TE.encodeUtf8 "carol-r"
                (reqR, _) <- plantRequest rig t1 seed economics keyR
                assets <- certifyPlanted rig t1 seed economics [reqR]
                _ <- reshapeRehearsalWallet rig assets
                let payer = walletAddr (rigWallet rig)
                dummy <- SessionIO.withLatest (rawChainProvider (rigChain rig)) $ \v -> do
                    pp <- SessionIO.parameters v
                    full <- SessionIO.outputsAt v payer
                    dummyTxFromWallet pp payer full
                shortenWallet rig 500_000
                wallet <- readWallet rig
                [o | (_, o) <- wallet, adaOnlyOut o] `shouldBe` []
                chainBefore <- readWallet rig
                result <- SessionIO.withLatest (rawChainProvider (rigChain rig)) $ \v ->
                    previewFunding
                        "fold"
                        payer
                        Nothing
                        Nothing
                        updateOutlay
                        (buildFundingAware dummy payer)
                        v
                case result of
                    Left (PreparationShortfall text _) -> do
                        text `shouldSatisfy` isInfixOf "preparation-unfunded:"
                        text
                            `shouldSatisfy` isInfixOf "(client policy); nothing was submitted"
                    other ->
                        expectationFailure
                            ("short preview planned unexpectedly: " <> show (voidPrep other))
                chainAfter <- readWallet rig
                chainAfter `shouldBe` chainBefore
        it "an allowance below command plus preparation refuses naming both" $ withRig $ \rig -> do
            seed <- fundSeed rig
            create <- createLegacyFixture rig
            t1 <- legacyToken create
            let keyA = TE.encodeUtf8 "carol-a"
                keyB = TE.encodeUtf8 "carol-b"
            (reqA, _) <- plantRequest rig t1 seed economics keyA
            (reqB, _) <- plantRequest rig t1 seed economics keyB
            assets <- certifyPlanted rig t1 seed economics [reqA, reqB]
            _ <- reshapeRehearsalWallet rig assets
            wallet <- readWallet rig
            let payer = walletAddr (rigWallet rig)
            (dummy, outlay, fee) <- SessionIO.withLatest (rawChainProvider (rigChain rig)) $ \v -> do
                pp <- SessionIO.parameters v
                tx <- dummyTxFromWallet pp payer wallet
                let outlay = updateOutlay tx
                    requirement = measureRequirement pp payer tx
                prepFee <- case planPreparation pp payer requirement wallet of
                    Left err ->
                        fail ("allowance leg: cannot plan covering preparation: " <> show err)
                    Right prep -> pure (prepFee prep)
                pure (tx, outlay, prepFee)
            let limit = outlayTotal outlay + fee
            tiny <- SessionIO.withLatest (rawChainProvider (rigChain rig)) $ \v ->
                previewFunding
                    "fold"
                    payer
                    Nothing
                    (Just 1)
                    updateOutlay
                    (buildFundingAware dummy payer)
                    v
            case tiny of
                Left (AllowanceExceeded text _) ->
                    text `shouldSatisfy` isInfixOf "passes the approved allowance"
                other ->
                    expectationFailure
                        ("tiny allowance planned unexpectedly: " <> show (voidPrep other))
            exact <- SessionIO.withLatest (rawChainProvider (rigChain rig)) $ \v ->
                previewFunding
                    "fold"
                    payer
                    Nothing
                    (Just limit)
                    updateOutlay
                    (buildFundingAware dummy payer)
                    v
            case exact of
                Right (_, Just _, _) -> pure ()
                other ->
                    expectationFailure
                        ("exact allowance refused unexpectedly: " <> show (voidPrep other))
            below <- SessionIO.withLatest (rawChainProvider (rigChain rig)) $ \v ->
                previewFunding
                    "fold"
                    payer
                    Nothing
                    (Just (limit - 1))
                    updateOutlay
                    (buildFundingAware dummy payer)
                    v
            case below of
                Left (AllowanceExceeded _ _) -> pure ()
                other ->
                    expectationFailure
                        ("one-below allowance passed unexpectedly: " <> show (voidPrep other))
            alone <- SessionIO.withLatest (rawChainProvider (rigChain rig)) $ \v ->
                previewFunding
                    "fold"
                    payer
                    Nothing
                    (Just (outlayTotal outlay))
                    updateOutlay
                    (buildFundingAware dummy payer)
                    v
            case alone of
                Left (AllowanceExceeded _ _) -> pure ()
                other ->
                    expectationFailure
                        ( "command-alone allowance passed unexpectedly: "
                            <> show (voidPrep other)
                        )
            chainAfter <- readWallet rig
            chainAfter `shouldBe` wallet
        it
            "whole-outlay interval refuses before signing with nothing submitted"
            $ withRig
            $ \rig -> do
                seed <- fundSeed rig
                create <- createLegacyFixture rig
                t1 <- legacyToken create
                let keyA = TE.encodeUtf8 "carol-a"
                    keyB = TE.encodeUtf8 "carol-b"
                (reqA, _) <- plantRequest rig t1 seed economics keyA
                (reqB, _) <- plantRequest rig t1 seed economics keyB
                assets <- certifyPlanted rig t1 seed economics [reqA, reqB]
                names <- reshapeRehearsalWallet rig assets
                names `shouldBe` 2
                wallet0 <- readWallet rig
                [o | (_, o) <- wallet0, adaOnlyOut o] `shouldBe` []
                let payer = walletAddr (rigWallet rig)
                pp <-
                    SessionIO.withLatest
                        (rawChainProvider (rigChain rig))
                        SessionIO.parameters
                let measure = bookingOutlay pp []
                    Coin reserveInt = protocolFeeReserve pp []
                    build = buildBookingLike payer
                large <- SessionIO.withLatest (rawChainProvider (rigChain rig)) $ \v ->
                    previewFunding "book" payer Nothing Nothing measure build v
                (oLarge, pLarge) <- case large of
                    Right (_, Just prep, overTx) ->
                        pure (outlayTotal (measure overTx), prepFee prep)
                    other ->
                        fail
                            ( "whole-outlay interval: large wallet did not prepare: "
                                <> show (voidPrep other)
                            )
                let hBelow = oLarge + pLarge - 100_000
                shortenWallet rig hBelow
                walletBelow <- readWallet rig
                [o | (_, o) <- walletBelow, adaOnlyOut o] `shouldBe` []
                length (spendableOuts walletBelow) `shouldBe` 1
                let heldBelow = spendableHeld walletBelow
                heldBelow `shouldBe` hBelow
                heldBelow `shouldSatisfy` (>= reserveInt)
                nLarge <- case large of
                    Right (_, Just prep, _) -> pure (prepFundingCoin prep)
                    _ -> fail "whole-outlay interval: no large preparation"
                case planPreparation pp payer nLarge walletBelow of
                    Left err ->
                        fail
                            ("whole-outlay interval: below still short of N+P+M: " <> show err)
                    Right _ -> pure ()
                chainBefore <- readWallet rig
                stateBeforePreview <- snapshotDir (rigDir rig)
                previewed <- SessionIO.withLatest (rawChainProvider (rigChain rig)) $ \v ->
                    previewFunding "book" payer Nothing Nothing measure build v
                case previewed of
                    Left (PreparationShortfall text fields) -> do
                        text `shouldSatisfy` isInfixOf "preparation-unfunded:"
                        text
                            `shouldSatisfy` isInfixOf "(client policy); nothing was submitted"
                        lookup "remainderMin" fields
                            `shouldBe` Just (Aeson.toJSON (0 :: Integer))
                        lookup "held" fields `shouldBe` Just (Aeson.toJSON hBelow)
                        lookup "required" fields
                            `shouldBe` Just (Aeson.toJSON (oLarge + pLarge))
                    other ->
                        expectationFailure
                            ( "whole-outlay interval preview planned unexpectedly: "
                                <> show (voidPrep other)
                            )
                chainAfterPreview <- readWallet rig
                chainAfterPreview `shouldBe` chainBefore
                stateAfterPreview <- snapshotDir (rigDir rig)
                stateAfterPreview `shouldBe` stateBeforePreview
                eventsBefore <- readIORef (rigEvents rig)
                stateBeforeWrite <- snapshotDir (rigDir rig)
                let wc =
                        WriteContext
                            { wcDir = rigDir rig
                            , wcCommand = "whole-outlay-interval"
                            , wcWallet = Just (rigWallet rig)
                            , wcCaller = walletAddr (rigWallet rig)
                            , wcCapabilities = capabilities rig
                            , wcTimeout = Nothing
                            , wcTracer = rigTracer rig
                            , wcSource = "fixture"
                            , wcStaged = Nothing
                            }
                actual <- SessionIO.withLatest (rawChainProvider (rigChain rig)) $ \v ->
                    prepareFunding wc "book" payer Nothing Nothing measure build v
                case actual of
                    Left (PreparationShortfall text _) -> do
                        text `shouldSatisfy` isInfixOf "preparation-unfunded:"
                        text
                            `shouldSatisfy` isInfixOf "(client policy); nothing was submitted"
                    other ->
                        expectationFailure
                            ( "whole-outlay interval prepare planned unexpectedly: "
                                <> show (voidPrep other)
                            )
                eventsAfter <- readIORef (rigEvents rig)
                eventsAfter `shouldBe` eventsBefore
                chainAfter <- readWallet rig
                chainAfter `shouldBe` chainBefore
                stateAfterWrite <- snapshotDir (rigDir rig)
                stateAfterWrite `shouldBe` stateBeforeWrite
        it
            "whole-outlay boundary accepts at outlay plus fee and refuses one below"
            $ withRig
            $ \rig -> do
                seed <- fundSeed rig
                create <- createLegacyFixture rig
                t1 <- legacyToken create
                let keyA = TE.encodeUtf8 "carol-a"
                    keyB = TE.encodeUtf8 "carol-b"
                (reqA, _) <- plantRequest rig t1 seed economics keyA
                (reqB, _) <- plantRequest rig t1 seed economics keyB
                assets <- certifyPlanted rig t1 seed economics [reqA, reqB]
                names <- reshapeRehearsalWallet rig assets
                names `shouldBe` 2
                let payer = walletAddr (rigWallet rig)
                pp <-
                    SessionIO.withLatest
                        (rawChainProvider (rigChain rig))
                        SessionIO.parameters
                let measure = bookingOutlay pp []
                    build = buildBookingLike payer
                    findExact :: Integer -> Int -> IO (Integer, Integer, Integer, Integer)
                    findExact _ 0 = fail "whole-outlay boundary: fee did not stabilise"
                    findExact h n = do
                        shortenWallet rig h
                        wallet <- readWallet rig
                        [o | (_, o) <- wallet, adaOnlyOut o] `shouldBe` []
                        previewed <- SessionIO.withLatest (rawChainProvider (rigChain rig)) $ \v ->
                            previewFunding "book" payer Nothing Nothing measure build v
                        case previewed of
                            Right (_, Just prep, overTx) -> do
                                let o = outlayTotal (measure overTx)
                                    p = prepFee prep
                                    target = o + p
                                if h == target
                                    then pure (h, o, p, prepFundingCoin prep)
                                    else findExact target (n - 1)
                            other ->
                                fail
                                    ( "whole-outlay boundary: exact candidate refused: "
                                        <> show (voidPrep other)
                                    )
                large <- SessionIO.withLatest (rawChainProvider (rigChain rig)) $ \v ->
                    previewFunding "book" payer Nothing Nothing measure build v
                (o0, p0) <- case large of
                    Right (_, Just prep, overTx) ->
                        pure (outlayTotal (measure overTx), prepFee prep)
                    other ->
                        fail
                            ( "whole-outlay boundary: large wallet did not prepare: "
                                <> show (voidPrep other)
                            )
                (hExact, oExact, pExact, nExact) <- findExact (o0 + p0) 5
                hExact `shouldBe` (oExact + pExact)
                walletExact <- readWallet rig
                case planPreparation pp payer nExact walletExact of
                    Left err -> fail ("whole-outlay boundary: exact short of N+P+M: " <> show err)
                    Right _ -> pure ()
                chainBeforeExact <- readWallet rig
                previewExact <- SessionIO.withLatest (rawChainProvider (rigChain rig)) $ \v ->
                    previewFunding "book" payer Nothing Nothing measure build v
                case previewExact of
                    Right (shown, Just prep, _) -> do
                        shown `shouldBe` [prepFunding prep]
                        prepFundingCoin prep `shouldBe` nExact
                        prepFee prep `shouldBe` pExact
                    other ->
                        expectationFailure
                            ( "whole-outlay boundary exact refused unexpectedly: "
                                <> show (voidPrep other)
                            )
                chainAfterExact <- readWallet rig
                chainAfterExact `shouldBe` chainBeforeExact
                let hBelow = hExact - 1
                shortenWallet rig hBelow
                walletBelow <- readWallet rig
                length (spendableOuts walletBelow) `shouldBe` 1
                spendableHeld walletBelow `shouldBe` hBelow
                case planPreparation pp payer nExact walletBelow of
                    Left err -> fail ("whole-outlay boundary: below short of N+P+M: " <> show err)
                    Right _ -> pure ()
                previewBelow <- SessionIO.withLatest (rawChainProvider (rigChain rig)) $ \v ->
                    previewFunding "book" payer Nothing Nothing measure build v
                case previewBelow of
                    Left (PreparationShortfall text fields) -> do
                        text `shouldSatisfy` isInfixOf "preparation-unfunded:"
                        text
                            `shouldSatisfy` isInfixOf "(client policy); nothing was submitted"
                        lookup "remainderMin" fields
                            `shouldBe` Just (Aeson.toJSON (0 :: Integer))
                        lookup "held" fields `shouldBe` Just (Aeson.toJSON hBelow)
                    other ->
                        expectationFailure
                            ( "whole-outlay boundary below planned unexpectedly: "
                                <> show (voidPrep other)
                            )
                chainAfterBelow <- readWallet rig
                chainAfterBelow `shouldBe` walletBelow
                -- The write at the same boundary: one lovelace below,
                -- prepareFunding itself refuses with nothing submitted —
                -- journal and state directory byte-identical — and at
                -- exactly outlay plus fee it accepts, submitting one
                -- preparation journalled with the funding expectation.
                eventsBeforeWrite <- readIORef (rigEvents rig)
                stateBeforeWrite <- snapshotDir (rigDir rig)
                let wc =
                        WriteContext
                            { wcDir = rigDir rig
                            , wcCommand = "whole-outlay-boundary"
                            , wcWallet = Just (rigWallet rig)
                            , wcCaller = walletAddr (rigWallet rig)
                            , wcCapabilities = capabilities rig
                            , wcTimeout = Nothing
                            , wcTracer = rigTracer rig
                            , wcSource = "fixture"
                            , wcStaged = Nothing
                            }
                refusedWrite <-
                    SessionIO.withLatest (rawChainProvider (rigChain rig)) $ \v ->
                        prepareFunding wc "book" payer Nothing Nothing measure build v
                case refusedWrite of
                    Left (PreparationShortfall text fields) -> do
                        text `shouldSatisfy` isInfixOf "preparation-unfunded:"
                        text
                            `shouldSatisfy` isInfixOf "(client policy); nothing was submitted"
                        lookup "remainderMin" fields
                            `shouldBe` Just (Aeson.toJSON (0 :: Integer))
                        lookup "held" fields `shouldBe` Just (Aeson.toJSON hBelow)
                    other ->
                        expectationFailure
                            ( "whole-outlay boundary write refused unexpectedly: "
                                <> show (voidPrep other)
                            )
                eventsAfterRefusal <- readIORef (rigEvents rig)
                eventsAfterRefusal `shouldBe` eventsBeforeWrite
                stateAfterRefusal <- snapshotDir (rigDir rig)
                stateAfterRefusal `shouldBe` stateBeforeWrite
                chainAfterRefusal <- readWallet rig
                chainAfterRefusal `shouldBe` walletBelow
                shortenWallet rig hExact
                walletExactAgain <- readWallet rig
                spendableHeld walletExactAgain `shouldBe` hExact
                acceptedWrite <-
                    SessionIO.withLatest (rawChainProvider (rigChain rig)) $ \v ->
                        prepareFunding wc "book" payer Nothing Nothing measure build v
                accepted <- case acceptedWrite of
                    Right (shown, Just prep, realTx) -> do
                        shown `shouldBe` [prepFunding prep]
                        prepFundingCoin prep `shouldBe` nExact
                        prepFee prep `shouldBe` pExact
                        pure (prepTx prep, realTx)
                    other -> do
                        expectationFailure
                            ( "whole-outlay boundary write accepted unexpectedly: "
                                <> show (voidPrep other)
                            )
                        fail "unreachable"
                eventsAfterAccepted <- readIORef (rigEvents rig)
                let newEvents = drop (length eventsAfterRefusal) eventsAfterAccepted
                    submittedSteps =
                        [ step
                        | Trace _ (How (Tx TxSubmitted{submitStep = step})) <- newEvents
                        ]
                submittedSteps `shouldBe` ["book"]
                entries <- readJournal (rigDir rig)
                let txid = txIdHex (fst accepted)
                    phases = [journalEvent e | e <- entries, journalTxId e == txid]
                phases `shouldBe` ["prepared", "submitted", "confirmed", "observed"]
                let expects =
                        [ journalExpect e
                        | e <- entries
                        , journalTxId e == txid
                        , journalEvent e == "prepared"
                        ]
                expects
                    `shouldBe` [Just ("funding:" <> T.pack (bech32Address payer))]
                chainAfterAccepted <- readWallet rig
                chainAfterAccepted `shouldNotBe` walletExactAgain
        it
            "a state directory snapshot detects a moved subtree and a renamed file"
            $ withSystemTempDirectory "snapshot-detect"
            $ \dir -> do
                createDirectoryIfMissing True (dir </> "registry" </> "wallets")
                BS.writeFile (dir </> "registry" </> "journal.jsonl") "one line\n"
                BS.writeFile
                    (dir </> "registry" </> "wallets" </> "body.cbor.hex")
                    "bytes"
                snapshotBefore <- snapshotDir dir
                createDirectoryIfMissing True (dir </> "registry-moved")
                renameDirectory (dir </> "registry") (dir </> "registry-moved")
                moved <- snapshotDir dir
                moved `shouldNotBe` snapshotBefore
                renameFile
                    (dir </> "registry-moved" </> "journal.jsonl")
                    (dir </> "registry-moved" </> "journal2.jsonl")
                renamed <- snapshotDir dir
                renamed `shouldNotBe` moved
                BS.appendFile
                    (dir </> "registry-moved" </> "journal2.jsonl")
                    "two lines\n"
                appended <- snapshotDir dir
                appended `shouldNotBe` renamed

dummyTxFromWallet
    :: PParams ConwayEra -> Addr -> [(TxIn, TxOut ConwayEra)] -> IO ConwayTx
dummyTxFromWallet pp payer wallet = case sortOn (Down . coinOf . snd) (spendableOuts wallet) of
    [] -> fail "dummyTxFromWallet: no spendable output to build from"
    (spentIn, spentOut) : _ -> do
        let Coin c = spentOut ^. coinTxOutL
            half = c `div` 2
            unsigned =
                mkBasicTx $
                    mkBasicTxBody
                        & inputsTxBodyL .~ Set.singleton spentIn
                        & outputsTxBodyL
                            .~ StrictSeq.singleton
                                (mkBasicTxOut payer (MaryValue (Coin half) mempty))
                        & feeTxBodyL .~ Coin 0
                        & reqSignerHashesTxBodyL
                            .~ Set.singleton (addrWitnessKeyHash (addrKeyHashBytes payer))
        case balanceTx pp [(spentIn, spentOut)] [] payer unsigned of
            Left err -> fail ("dummyTxFromWallet: balancing failed: " <> show err)
            Right (BalanceResult tx _) -> pure tx
  where
    coinOf out = let Coin c = out ^. coinTxOutL in c

buildFromView :: Addr -> Cage.Session NoWitness IO -> IO ConwayTx
buildFromView payer v = do
    pp <- SessionIO.parameters v
    viewWallet <- SessionIO.outputsAt v payer
    dummyTxFromWallet pp payer viewWallet

buildFundingAware
    :: ConwayTx -> Addr -> Cage.Session NoWitness IO -> IO ConwayTx
buildFundingAware dummy payer v = do
    wallet <- SessionIO.outputsAt v payer
    case selectFunding Nothing wallet of
        Left why -> throwIO (ErrorCall why)
        Right _ -> pure dummy

{- | A booking-like build for the whole-outlay interval (#491 PR2b line 1).
Singleton funding input, a bond out to another address plus change back,
balanced by the ledger. Fails when no ada-only output exists (natural),
succeeds from the oversized probe. The bond is a fixture input; every
bound (outlay, requirement, fee, reserve) is read from producers.
-}
bookingBond :: Integer
bookingBond = 2_000_000

otherBookingAddr :: Addr
otherBookingAddr =
    addrFromKeyHashBytes Testnet (BS.replicate 28 0xbb)

buildBookingLike
    :: Addr -> Cage.Session NoWitness IO -> IO ConwayTx
buildBookingLike payer v = do
    wallet <- SessionIO.outputsAt v payer
    case selectFunding Nothing wallet of
        Left why -> throwIO (ErrorCall why)
        Right (fundIn, fundOut) -> do
            pp <- SessionIO.parameters v
            let unsigned =
                    mkBasicTx $
                        mkBasicTxBody
                            & inputsTxBodyL .~ Set.singleton fundIn
                            & outputsTxBodyL
                                .~ StrictSeq.fromList
                                    [ mkBasicTxOut
                                        otherBookingAddr
                                        (MaryValue (Coin bookingBond) mempty)
                                    , mkBasicTxOut
                                        payer
                                        (MaryValue (Coin 1_000_000) mempty)
                                    ]
                            & feeTxBodyL .~ Coin 0
                            & reqSignerHashesTxBodyL
                                .~ Set.singleton
                                    (addrWitnessKeyHash (addrKeyHashBytes payer))
            case balanceTx pp [(fundIn, fundOut)] [] payer unsigned of
                Left err ->
                    throwIO (ErrorCall ("buildBookingLike: " <> show err))
                Right (BalanceResult tx _) -> pure tx

voidPrep
    :: Either PrepareRefusal ([TxIn], Maybe Preparation, ConwayTx) -> String
voidPrep =
    either
        (const "refusal")
        (\(shown, prep, _) -> show (shown, isJust prep))

parseTokenId :: String -> IO TokenId
parseTokenId tokenStr = case T.splitOn "." (T.pack tokenStr) of
    [_, nameHex] -> case B16.decode (TE.encodeUtf8 nameHex) of
        Right bytes
            | BS.length bytes == 32 ->
                pure (TokenId (AssetName (SBS.toShort bytes)))
        Right bytes ->
            fail
                ("parseTokenId: name is " <> show (BS.length bytes) <> " bytes, not 32")
        Left _ -> fail "parseTokenId: name is not hex"
    _ -> fail ("parseTokenId: no policy.name in " <> tokenStr)

{- | Plant a generic insertion request for reclaim and reject: the edge alone,
no envelope and no payload file. The request output is submitted through the
fixture exactly as 'capabilities' submits, and its submission time is read
from its own datum.
-}
plantRequest
    :: Rig
    -> String
    -> String
    -> RegistryEconomics
    -> BS.ByteString
    -> IO (TxIn, Integer)
plantRequest rig tokenStr seedStr econ key =
    plantRequestDeposit rig tokenStr seedStr econ key 1_000_000

{- | 'plantRequest' with the request's deposit in lovelace named: a deposit
beyond the wallet's largest ada-only output forces a later write to make a
preparation.
-}
plantRequestDeposit
    :: Rig
    -> String
    -> String
    -> RegistryEconomics
    -> BS.ByteString
    -> Integer
    -> IO (TxIn, Integer)
plantRequestDeposit rig tokenStr seedStr econ key deposit = do
    seedIn <-
        either
            (fail . ("plantRequest seed: " <>))
            pure
            (parseOutRef (T.pack seedStr))
    let seedRef = txInToRef seedIn
    tid <- parseTokenId tokenStr
    let dummy = hashPinnedApplication (SBS.toShort (BS.replicate 28 7))
    rel <- loadReleaseCodes dummy (rigBlueprint rig) >>= either fail pure
    let (cfg, _) = registryConfigFor dummy rel econ seedRef
        reqAddr = requestAddrFromCfg cfg tid Testnet
        wallet = walletAddr (rigWallet rig)
    unsigned <-
        SessionIO.withLatest (rawChainProvider (rigChain rig)) $ \v ->
            requestEdgeImpl cfg v (Coin deposit) tid key edgeInsertActive wallet
    let txid = txIdTx unsigned
        spent = Set.toList (unsigned ^. bodyTxL . inputsTxBodyL)
        made = zip [0 ..] (toList (unsigned ^. bodyTxL . outputsTxBodyL))
        atReq =
            [ (TxIn txid (TxIx ix), out)
            | (ix, out) <- made
            , out ^. addrTxOutL == reqAddr
            ]
    (reqIn, reqOut) <- case atReq of
        [one] -> pure one
        _ ->
            fail
                ( "plantRequest: expected one request output at "
                    <> show reqAddr
                    <> ", found "
                    <> show (length atReq)
                )
    submitted <- case extractCageDatum reqOut of
        Just (RequestDatum r) -> pure (requestSubmittedAt r)
        _ -> fail "plantRequest: request output carries no request datum"
    recordTransaction (rigChain rig) unsigned
    advanceChain (rigChain rig) $ \facts ->
        facts
            { csUTxO =
                Map.union
                    (Map.fromList [(TxIn txid (TxIx ix), out) | (ix, out) <- made])
                    (foldr Map.delete (csUTxO facts) spent)
            }
    pure (reqIn, submitted)

-- | Move the chain tip past this millisecond instant, by this many slots more.
fundSeed :: Rig -> IO String
fundSeed _ = pure (T.unpack (renderOutRef (fundOutput 1)))

-- | A wallet output still unspent, for the second registry.
selfPayment :: Wallet -> Cage.Outputs -> SignedTx
selfPayment wallet held = signTx (walletSignKey wallet) (mkBasicTx body)
  where
    fee = Coin 1_000_000
    value = foldMap ((^. valueTxOutL) . snd) held
    body =
        mkBasicTxBody
            & inputsTxBodyL .~ Set.fromList (map fst held)
            & outputsTxBodyL
                .~ StrictSeq.singleton
                    (mkBasicTxOut (walletAddr wallet) (value <-> inject fee))
            & feeTxBodyL .~ fee

inclusionPointRows :: Spec
inclusionPointRows = describe
    "the fixture's inclusion read reports the block that applied the transaction"
    $ do
        it "names the slot and header the submit path advanced the chain to" $
            withRig $ \rig -> do
                held <-
                    SessionIO.withLatest (rawChainProvider (rigChain rig)) $ \v ->
                        SessionIO.outputsAt v (walletAddr (rigWallet rig))
                let transaction = selfPayment (rigWallet rig) held
                answer <- capSubmit (capabilities rig) transaction
                _ <- case answer of
                    Cage.SubmitAccepted accepted -> pure accepted
                    other -> fail ("the rig refused the payment: " <> show other)
                (included, tip) <-
                    SessionIO.withLatest (rawChainProvider (rigChain rig)) $ \v -> do
                        statuses <-
                            either
                                (fail . ("inclusion read failed: " <>) . show)
                                (pure . value)
                                =<< Cage.inclusion v [txIdTx (signedTx transaction)]
                        status <- case statuses of
                            [one] -> pure one
                            _ -> fail "the inclusion read did not answer the payment once"
                        observed <- SessionIO.tip v
                        pure (status, observed)
                case included of
                    Cage.IncludedAt point _ -> do
                        point
                            `shouldBe` Cage.At
                                (Cage.observedSlot tip)
                                (Cage.observedHash tip)
                    other ->
                        expectationFailure
                            ("the chain does not hold the payment: " <> show other)
        it "names the slot and header the planted request entered" $
            withRig $ \rig -> do
                seed <- fundSeed rig
                create <- createLegacyFixture rig
                t1 <- legacyToken create
                (reqIn, _) <-
                    plantRequest rig t1 seed economics (TE.encodeUtf8 "inclusion")
                let planted = case reqIn of TxIn identity _ -> identity
                (included, tip) <-
                    SessionIO.withLatest (rawChainProvider (rigChain rig)) $ \v -> do
                        statuses <-
                            either
                                (fail . ("inclusion read failed: " <>) . show)
                                (pure . value)
                                =<< Cage.inclusion v [planted]
                        status <- case statuses of
                            [one] -> pure one
                            _ -> fail "the inclusion read did not answer the planted request once"
                        observed <- SessionIO.tip v
                        pure (status, observed)
                case included of
                    Cage.IncludedAt point _ ->
                        point
                            `shouldBe` Cage.At (Cage.observedSlot tip) (Cage.observedHash tip)
                    other ->
                        expectationFailure
                            ("the chain does not hold the planted request: " <> show other)

walletVariableRow :: Spec
walletVariableRow =
    it
        "wallet create and wallet address take SINGULAR_PASSPHRASE on the development network and refuse it on mainnet, preprod and preview before they read or make a vault"
        $ withRig
        $ \rig -> do
            vault <- rigVault rig "alice"
            let absent = rigDir rig </> "absent.vault"
                fresh = rigDir rig </> "fresh.vault"
                arguments path network =
                    WalletArgs
                        { walletVaultPath = path
                        , walletNetworkMagic = network
                        , walletPassphraseFd = Nothing
                        }
                running command =
                    withVariable (Just (BC.pack vaultPassphrase)) $
                        captured (runCommand neutralApplication (envOf rig) command)
            forM_ publicNetworks $ \(name, public) -> do
                (code, out, err) <- running (WalletAddress (arguments absent public))
                code `shouldBe` ExitFailure 1
                out `shouldBe` ""
                forM_ [passphraseVariable, name, show public] $ \word ->
                    BC.unpack err `shouldSatisfy` isInfixOf word
                BC.unpack err `shouldNotSatisfy` isInfixOf "absent.vault"
                (createCode, createOut, _) <-
                    running (WalletCreate (arguments fresh public))
                createCode `shouldBe` ExitFailure 1
                createOut `shouldBe` ""
                doesPathExist fresh `shouldReturn` False
            (code, out, _) <-
                running (WalletAddress (arguments vault (fromIntegral magic)))
            code `shouldBe` ExitSuccess
            BC.unpack out `shouldSatisfy` isPrefixOf "addr_test1"
            (createCode, createOut, _) <-
                running (WalletCreate (arguments fresh (fromIntegral magic)))
            createCode `shouldBe` ExitSuccess
            BC.unpack createOut `shouldSatisfy` isPrefixOf "addr_test1"
            doesPathExist fresh `shouldReturn` True

-- | A command line with the network magic its value names.
withVariable :: Maybe BS.ByteString -> IO a -> IO a
withVariable wanted act = do
    saved <- PosixEnv.getEnv name
    set wanted
    act `finally` set saved
  where
    name = BC.pack passphraseVariable
    set =
        maybe
            (PosixEnv.unsetEnv name)
            (\value -> PosixEnv.setEnv name value True)

-- | The passphrase the rows' vaults are sealed with.
vaultPassphrase :: String
vaultPassphrase = "a passphrase only the rig's vault knows"

-- | The rig wallet's key sealed into a vault of this name, under the rig.
rigVault :: Rig -> String -> IO FilePath
rigVault rig name = do
    passphrase <-
        either (fail . show) pure (mkPassphrase (BC.pack vaultPassphrase))
    sealed <-
        sealVault vaultWorkFactor passphrase (walletSignKey (rigWallet rig))
            >>= either (fail . show) pure
    let path = rigDir rig </> (name <> ".vault")
    createVaultFile path sealed >>= either (fail . show) pure
    pure path

{- | A descriptor that yields this passphrase once, as a script hands it
over; the reader closes it.
-}
settingsKeys :: FilePath -> IO Aeson.Object
settingsKeys file =
    BS.readFile file >>= \bytes -> case Aeson.eitherDecodeStrict bytes of
        Right (Aeson.Object o) -> pure o
        Right other -> fail (file <> " is not one object: " <> show other)
        Left why -> fail (file <> " is not JSON: " <> why)

-- | The permission bits of a file.
receiptDecidesRows :: Spec
receiptDecidesRows =
    describe "the receipt decides what is written" $ do
        it "writes the token of a success and returns the receipt as it was" $
            withSystemTempDirectory "keep" $ \dir -> do
                let file = dir </> "settings.json"
                    made =
                        Aeson.object
                            [ "outcome" .= outcomeName Success
                            , "stateToken" .= ("p.n" :: Text)
                            , "root" .= ("00" :: Text)
                            ]
                (returned, _, err) <-
                    captured (keepStateToken "singular" (Just file) (pure made))
                returned `shouldBe` made
                keys <- settingsKeys file
                KeyMap.toList keys `shouldBe` [("state-token", Aeson.String "p.n")]
                BC.unpack err `shouldSatisfy` isInfixOf file
        it
            "writes nothing for any other outcome, whatever the receipt carries"
            $ withSystemTempDirectory "keep"
            $ \dir ->
                forM_ [c | c <- [minBound .. maxBound], c /= Success] $ \other -> do
                    let file = dir </> (T.unpack (outcomeName other) <> ".json")
                        made =
                            Aeson.object
                                ["outcome" .= outcomeName other, "stateToken" .= ("p.n" :: Text)]
                    (returned, _, err) <-
                        captured (keepStateToken "singular" (Just file) (pure made))
                    returned `shouldBe` made
                    doesPathExist file `shouldReturn` False
                    err `shouldBe` ""
        it
            "writes nothing for a preview, whose success names a registry that does not exist"
            $ withSystemTempDirectory "keep"
            $ \dir -> do
                let file = dir </> "settings.json"
                    made =
                        Aeson.object
                            [ "outcome" .= outcomeName Success
                            , "preview" .= True
                            , "stateToken" .= ("p.n" :: Text)
                            ]
                (returned, _, _) <-
                    captured (keepStateToken "singular" (Just file) (pure made))
                returned `shouldBe` made
                doesPathExist file `shouldReturn` False
        it
            "says so, and writes nothing, for a success that names no state token"
            $ withSystemTempDirectory "keep"
            $ \dir -> do
                let file = dir </> "settings.json"
                    made =
                        Aeson.object
                            ["outcome" .= outcomeName Success, "stateToken" .= Aeson.Null]
                (returned, _, err) <-
                    captured (keepStateToken "singular" (Just file) (pure made))
                returned `shouldBe` made
                doesPathExist file `shouldReturn` False
                TE.decodeUtf8 err `shouldSatisfy` T.isInfixOf "no state token"
        it "writes nothing when no file was asked for" $
            withSystemTempDirectory "keep" $ \dir -> do
                let made =
                        Aeson.object
                            ["outcome" .= outcomeName Success, "stateToken" .= ("p.n" :: Text)]
                (returned, _, err) <-
                    captured (keepStateToken "singular" Nothing (pure made))
                returned `shouldBe` made
                err `shouldBe` ""
                listDirectory dir `shouldReturn` []
        it "leaves a thrown failure to the caller and writes nothing" $
            withSystemTempDirectory "keep" $ \dir -> do
                let file = dir </> "settings.json"
                result <-
                    try
                        ( captured
                            ( keepStateToken
                                "singular"
                                (Just file)
                                (throwIO (ErrorCall "the create failed"))
                            )
                        )
                case result of
                    Left (ErrorCall why) -> why `shouldBe` "the create failed"
                    Right _ -> expectationFailure "the failure was swallowed"
                doesPathExist file `shouldReturn` False

-- ---------------------------------------------------------
-- A registry has an address (#728)
-- ---------------------------------------------------------

{- | The receipts and the refusals of a registry that has an address, run
through the same dispatch as every command above. The address and the
fingerprint a receipt gives are judged by 'Singular.Registry.AddressOracle', which
reads the word with the @bech32@ package and hashes with @crypton@ directly,
never by the code that wrote them.
-}

-- | Build only the legacy fixture needed by retained library checks.
createLegacyFixture :: Rig -> IO Aeson.Value
createLegacyFixture rig = do
    app <-
        createApplication
            neutralApplication
            (Just (ApplicationPolicy (SBS.toShort (BS.replicate 28 7))))
    receipt <-
        runCreate
            app
            (envOf rig)
            CreateArgs
                { createStateDir = Just (rigDir rig </> "registry")
                , createBlueprint = rigBlueprint rig
                , createMode =
                    Submit
                        ( WriteSettings
                            (ProviderSettings "http://fixture.invalid" 42 Nothing Nothing)
                            (SignerKeyFile (rigKey rig))
                            Nothing
                        )
                , createSeed = Nothing
                , createPreview = False
                , createReceipt = Nothing
                , createSaveStateTokenTo = Nothing
                , createProcessTime = reProcessTime economics
                , createRetractTime = reRetractTime economics
                }
    outcomeOf receipt `shouldBe` Just "success"
    pure receipt

legacyToken :: Aeson.Value -> IO String
legacyToken receipt = do
    outcomeOf receipt `shouldBe` Just "success"
    maybe
        (fail "legacy fixture has no token")
        (pure . T.unpack)
        (textAt "stateToken" receipt)
