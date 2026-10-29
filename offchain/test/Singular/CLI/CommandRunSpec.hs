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
fixture. The retained pin, wallet and chain-fixture checks remain for their library
and command consumers. Fixture execution does not establish
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

import Cardano.Ledger.Api.Tx (bodyTxL, mkBasicTx, txIdTx)
import Cardano.Ledger.Api.Tx.Body
    ( EraTxBody
        ( feeTxBodyL
        , inputsTxBodyL
        , mkBasicTxBody
        , outputsTxBodyL
        )
    )
import Cardano.Ledger.Api.Tx.Out
    ( EraTxOut (TxOut, mkBasicTxOut, valueTxOutL)
    )
import Cardano.Ledger.BaseTypes (TxIx (TxIx))
import Cardano.Ledger.Mary.Value (MaryValue (MaryValue))
import Cardano.Ledger.TxIn (TxIn (..))
import Cardano.Ledger.Val (inject, (<->))
import Control.Exception (bracket, finally)
import Control.Monad (forM_)
import Control.Tracer (Tracer (..))
import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
    ( Key
    , Value (Array, Bool, Object, String)
    , decodeStrict
    , encode
    , object
    )
import Data.Aeson.KeyMap qualified as KeyMap (lookup)
import Data.ByteString qualified as BS
    ( ByteString
    , readFile
    , replicate
    , writeFile
    )
import Data.ByteString.Base16 qualified as B16 (encode)
import Data.ByteString.Char8 qualified as BC
    ( pack
    , replicate
    , unpack
    )
import Data.ByteString.Lazy qualified as BL (writeFile)
import Data.ByteString.Short qualified as SBS
    ( ShortByteString
    , fromShort
    )
import Data.Foldable (toList)
import Data.IORef
    ( IORef
    , modifyIORef'
    , newIORef
    , readIORef
    , writeIORef
    )
import Data.List (isInfixOf, isPrefixOf)
import Data.Map.Strict qualified as Map (delete, fromList, union)
import Data.Maybe (listToMaybe)
import Data.Sequence.Strict qualified as StrictSeq (singleton)
import Data.Set qualified as Set (empty, fromList, toList)
import Data.Text (Text)
import Data.Text qualified as T (pack, unpack)
import Data.Text.Encoding qualified as TE
    ( decodeUtf8
    , encodeUtf8
    )
import Lens.Micro ((&), (.~), (^.))
import Singular.CLI (runCommand)
import Singular.CLI.Command
    ( Command (..)
    , WalletArgs
        ( WalletArgs
        , walletNetworkMagic
        , walletPassphraseFd
        , walletVaultPath
        )
    , parseCommand
    )
import Singular.CLI.Passphrase
    ( mkPassphrase
    , passphraseVariable
    , publicNetworks
    )
import Singular.CLI.Registry (loadRelease, loadReleaseCodes)
import Singular.CLI.Session (Env (..))
import Singular.CLI.Trace (Trace)
import Singular.CLI.Vault
    ( createVaultFile
    , sealVault
    , vaultWorkFactor
    )
import Singular.Registry.Application
    ( Application (..)
    , ApplicationPin (PinByScript)
    , neutralApplication
    )
import Singular.Registry.Capabilities (Capabilities (..))
import Singular.Registry.Deployment (parseOutRef)
import Singular.Registry.Evidence
    ( Evidenced (..)
    , NoWitness
    , unverifiedVerifier
    )
import Singular.Registry.Ledger (Coin (Coin), ConwayEra)
import Singular.Registry.LedgerProvider qualified as Cage
    ( ChainPoint (At)
    , InclusionStatus (IncludedAt)
    , Outputs
    , Session (inclusion)
    , SubmitResult (SubmitAccepted)
    , TipObservation (observedHash, observedSlot)
    )
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
import Singular.Registry.TxBuilder.Internal
    ( computeScriptHash
    , scriptHashBytes
    )
import Singular.Registry.Wallet
    ( Wallet (walletAddr, walletSignKey)
    , bech32Address
    , loadWallet
    )
import System.Directory (doesPathExist)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
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
    , shouldNotSatisfy
    , shouldReturn
    , shouldSatisfy
    )

spec :: Spec
spec =
    permanentRecognition
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
