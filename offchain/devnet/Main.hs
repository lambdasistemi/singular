{-# LANGUAGE LambdaCase #-}

{- |
Module      : Main
Description : A devnet that outlives the process that needed it
License     : Apache-2.0

Every runner spawns its own devnet and takes it down again, which is
right when the registry it boots dies with the run. A deployment does
not: it is booted once and attached to by later runs, so proving that
attachment works needs one chain that several processes can reach.

This spawns that chain behind the private Koios-shaped HTTP facade,
prints a JSON object containing its provider URL and immutable time-source
directory, and waits until it is killed. Commands receive those settings.
The socket in the object is solely for separate independent private probes.

@--fund-skey FILE --fund-outputs N --fund-lovelace L@ (#299): before the
settings are printed, pay @N@ outputs of @L@ lovelace from the genesis key
to the address of the payment key in @FILE@, and wait until they are on
chain. A caller wallet generated for a test then holds several ordinary
outputs, as a real wallet does, so a seed it chooses is one of them
rather than the genesis output itself. The key file is read, never
printed; only its public address is reported, on standard error.

@--fund FILE:N:LOVELACE@ pays one wallet-sized group: @N@ outputs of
@LOVELACE@ lovelace to the wallet of @FILE@, beside the uniform flags,
which pay every @--fund-skey@ wallet the same. A journey that needs one
wallet funded differently from the others names it this way; the value
is read before the node starts and a malformed one is refused by name.

@--fund-address ADDRESS:N:LOVELACE@ pays the same kind of group to a
bech32 address instead of a key file's wallet: a wallet made elsewhere
(@singular wallet create@) is funded from its public address alone, and
no signing key is ever handed to the devnet. It may repeat. The address
must be a test-network Shelley address; a malformed group, a malformed
address or one for another network is refused by name before the node
starts.

@--genesis-only@ retains the checked initial allocation without the private
funding actor, for the retained coverage refusal control. It changes no
ledger, genesis, epoch, slot, safe-zone or time-publication setting.

@devnet probe --node-socket PATH [--network-magic N] [--tx-in TXID#IX]...@
(#325) spawns nothing: it asks the node at @PATH@, from one acquired
ledger state, for its chain tip and which of the named outputs are
unspent, and prints one JSON object,
@{"tip":{"slot":N,"hash":HEX},"live":[...],"spent":[...]}@. A control
that rolls a development node back reads the node's own answer through
it, never the answer of the command under test.
-}
module Main (main) where

import Control.Concurrent (myThreadId, threadDelay, throwTo)
import Control.Concurrent.MVar (newMVar, withMVar)
import Control.Exception (AsyncException (UserInterrupt), bracket)
import Control.Monad (forever, unless, void, when)
import Data.List (isPrefixOf, sortOn)
import Data.Maybe (fromMaybe)
import Data.Maybe qualified
import Data.Ord (Down (..))
import Data.Sequence.Strict qualified as StrictSeq
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Text.Encoding qualified as TextEncoding
import Lens.Micro ((&), (.~), (^.))
import System.Directory
    ( createDirectoryIfMissing
    , getTemporaryDirectory
    )
import System.Environment (getArgs, getEnvironment)
import System.Exit (die, exitWith)
import System.FilePath ((</>))
import System.IO
    ( BufferMode (..)
    , hPutStrLn
    , hSetBuffering
    , stderr
    , stdout
    )
import System.IO.Temp (createTempDirectory, withSystemTempDirectory)
import System.Posix.Files (setFileMode)
import System.Posix.Signals
    ( Handler (CatchOnce)
    , installHandler
    , sigTERM
    )
import System.Process
    ( CreateProcess (..)
    , proc
    , rawSystem
    , waitForProcess
    , withCreateProcess
    )
import Text.Read (readMaybe)

import Cardano.Ledger.Address (Addr (..))
import Cardano.Ledger.Api.Tx
    ( bodyTxL
    , estimateMinFeeTx
    , mkBasicTx
    , sizeTxF
    , txIdTx
    )
import Cardano.Ledger.Api.Tx.Body
    ( feeTxBodyL
    , inputsTxBodyL
    , mkBasicTxBody
    , outputsTxBodyL
    )
import Cardano.Ledger.Api.Tx.Out
    ( addrTxOutL
    , coinTxOutL
    , mkBasicTxOut
    , referenceScriptTxOutL
    , valueTxOutL
    )
import Cardano.Ledger.BaseTypes
    ( Network (..)
    , StrictMaybe (..)
    , TxIx (..)
    )
import Cardano.Ledger.Binary (serialize')
import Cardano.Ledger.Core (eraProtVerLow)
import Cardano.Ledger.Mary.Value (MaryValue (..))
import Cardano.Ledger.TxIn (TxIn (..))
import Cardano.Node.Client.E2E.Setup
    ( genesisAddr
    , genesisDir
    , genesisSignKey
    , rawSerialiseSignKeyDSIGN
    )
import Cardano.Tx.Balance (refScriptsSize)
import Control.Tracer (nullTracer)
import Devnet.Probe qualified as Probe
import Singular.Provider.Koios.Wire (parseAddress)
import Singular.Registry.Private.Facade
import Singular.Registry.Private.Smoke (runFacadeSmoke)
import Singular.Registry.ProviderSettings (ProviderSettings (..))
import Singular.Registry.Runner (runnerSettings, withRunner)
import Singular.Registry.SessionIO qualified as Session
import Singular.Registry.Terminal (withReads)

import Data.Aeson (Value, encode, object, (.=))
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Lazy.Char8 qualified as LBS
import Singular.Registry.Capabilities
    ( Capabilities (..)
    )
import Singular.Registry.Deployment (parseOutRef, renderOutRef)
import Singular.Registry.Evidence (NoWitness)
import Singular.Registry.Ledger (Coin (..), ConwayEra)
import Singular.Registry.LedgerProvider (SubmitResult (..))
import Singular.Registry.Signing (signTx, signedTx)
import Singular.Registry.Wallet
    ( Wallet (..)
    , bech32Address
    , loadWallet
    )
import Singular.State.Assemble (assembleTransaction)

-- | Who a funding pays: a key file's wallet, or an address as given.
data Target
    = TargetKey FilePath
    | TargetAddress Addr

-- | The optional funding a caller asked for.
data Funding = Funding
    { fundTarget :: Target
    , fundOutputs :: Int
    , fundLovelace :: Integer
    }

main :: IO ()
main = do
    owner <- myThreadId
    -- The private fixture's shell owner cancels with TERM. Turn that signal
    -- into an interrupt of this owning thread so its node/session brackets
    -- close and join before the generated directory can be removed.
    bracket
        ( installHandler
            sigTERM
            (CatchOnce (throwTo owner UserInterrupt))
            Nothing
        )
        (\previous -> void (installHandler sigTERM previous Nothing))
        (const dispatch)

dispatch :: IO ()
dispatch = do
    hSetBuffering stdout LineBuffering
    args <- getArgs
    case args of
        ("run" : command : arguments) -> run command arguments
        ["run"] -> die "devnet run needs a command executable"
        ("facade-smoke" : rest) -> do
            gDir <- genesisDir
            output <-
                maybe
                    (die "devnet facade-smoke: --evidence-dir is required")
                    pure
                    (flag "--evidence-dir" rest)
            runFacadeSmoke gDir output
        ("probe" : rest) -> probe rest
        ("spend-reference" : rest) -> spendReference rest
        _ -> spawn args

-- | Spawn the private facade, fund through shared HTTP, print settings, wait.
spawn :: [String] -> IO ()
spawn args = case flag "--restart-control-dir" args of
    Nothing -> withFixture args $ \evidence facade -> do
        fundAndPublish evidence True facade
        forever (threadDelay 3_600_000_000)
    Just control -> do
        deadline <- case flag "--restart-resume-timeout-ms" args of
            Nothing -> pure 120_000_000
            Just spelling -> case readMaybe spelling of
                Just milliseconds
                    | milliseconds > (0 :: Int)
                    , milliseconds <= 120_000 ->
                        pure (milliseconds * 1000)
                _ ->
                    die "devnet: restart resume timeout must be 1..120000 milliseconds"
        (gDir, evidence, funding, observe) <- fixtureInputs args
        withRestartableGeneratedFacade funding gDir control deadline observe $ \_ first facade ->
            fundAndPublish evidence first facade
  where
    fundAndPublish evidence first facade =
        withReads nullTracer nullTracer (facadeSettings facade) $ \caps -> do
            when first (mapM_ (fund caps) =<< either die pure (fundingFrom args))
            let settings = facadeSettings facade
            LBS.putStrLn
                ( encode
                    ( object
                        [ "providerUrl" .= providerUrl settings
                        , "networkMagic" .= providerMagic settings
                        , "networkTimeDirectory" .= providerTimeDirectory settings
                        , "privateProbeSocket" .= facadeSocket facade
                        , "independentSourceDirectory" .= evidence
                        ]
                    )
                )

{- | The CI launcher owns the generated node. Its child receives only public
provider/time settings and one ephemeral private fixture wallet file.
-}
run :: FilePath -> [String] -> IO ()
run command arguments = do
    environment <- getEnvironment
    let supplied =
            any configured arguments
                || any
                    (\name -> Data.Maybe.isJust (lookup name environment))
                    [ "SINGULAR_KOIOS_URL"
                    , "SINGULAR_NETWORK_MAGIC"
                    , "SINGULAR_WALLET_SKEY"
                    ]
        placeholders =
            [ ("SINGULAR_KOIOS_URL", "http://127.0.0.1:1/api/v1")
            , ("SINGULAR_NETWORK_MAGIC", "42")
            , ("SINGULAR_WALLET_SKEY", "private-fixture-not-yet-opened")
            ]
    _ <-
        either
            die
            pure
            ( runnerSettings
                arguments
                (if supplied then environment else placeholders <> environment)
            )
    outcome <-
        if supplied
            then rawSystem command arguments
            else withFixture arguments $ \evidence facade -> withSystemTempDirectory "private-runner-wallet" $ \directory -> do
                let key = directory </> "payment.skey"
                    settings = facadeSettings facade
                    overrides =
                        [ ("SINGULAR_KOIOS_URL", providerUrl settings)
                        , ("SINGULAR_NETWORK_MAGIC", show (providerMagic settings))
                        ,
                            ( "SINGULAR_NETWORK_TIME"
                            , fromMaybe "" (providerTimeDirectory settings)
                            )
                        , ("SINGULAR_WALLET_SKEY", key)
                        ,
                            ( "SINGULAR_RUNNER_EVIDENCE"
                            , evidence </> "terminal-runner-trace.json"
                            )
                        ]
                    childEnvironment =
                        overrides
                            <> filter (\(name, _) -> name `notElem` map fst overrides) environment
                BS.writeFile
                    key
                    (B16.encode (rawSerialiseSignKeyDSIGN genesisSignKey))
                setFileMode key 0o600
                withCreateProcess
                    (proc command arguments)
                        { env = Just childEnvironment
                        , delegate_ctlc = True
                        }
                    $ \_ _ _ process ->
                        waitForProcess process
    exitWith outcome
  where
    configured argument =
        any
            (\name -> argument == name || (name <> "=") `isPrefixOf` argument)
            ["--koios-url", "--network-magic", "--wallet-skey"]

withFixture :: [String] -> (FilePath -> Facade -> IO a) -> IO a
withFixture args action = do
    (gDir, evidence, funding, observe) <- fixtureInputs args
    withGeneratedFacade funding gDir observe $ \_ facade -> action evidence facade

-- Ordinary and restart experiments share real source observation and funding.
-- Only the explicit private experiment changes the facade session lifetime.
fixtureInputs
    :: [String] -> IO (FilePath, FilePath, GenesisFunding, Value -> IO ())
fixtureInputs args = do
    gDir <- genesisDir
    tmp <- getTemporaryDirectory
    evidence <-
        maybe
            (createTempDirectory tmp "private-facade-sources-")
            pure
            (flag "--evidence-dir" args)
    createDirectoryIfMissing True evidence
    lock <- newMVar ()
    let observe event =
            withMVar
                lock
                ( \_ ->
                    LBS.appendFile
                        (evidence </> "independent-facade-sources.jsonl")
                        (encode event <> "\n")
                )
    let funding = if "--genesis-only" `elem` args then LeaveGenesis else FundGenesis
    requested <- either die pure (fundingFrom args)
    unless (funding /= LeaveGenesis || null requested) $
        die "devnet: --genesis-only cannot also fund caller wallets"
    pure (gDir, evidence, funding, observe)

{- | Read the funding flags: every @--fund-skey@ given (it may repeat, one
wallet each), all paid the same @--fund-outputs@ of @--fund-lovelace@, plus
every @--fund FILE:N:LOVELACE@ and every @--fund-address ADDRESS:N:LOVELACE@,
one wallet-sized group each. None of the uniform flags pays anything unless
all three are present; each group pays exactly what it says. A malformed
group or address is named, before any node starts.
-}
fundingFrom :: [String] -> Either String [Funding]
fundingFrom args = do
    groups <- traverse fundGroup (every "--fund" args)
    addressed <- traverse fundAddressGroup (every "--fund-address" args)
    let uniform = fromMaybe [] $ do
            outputs <- flag "--fund-outputs" args >>= readMaybe
            lovelace <- flag "--fund-lovelace" args >>= readMaybe
            pure
                [ Funding (TargetKey key) outputs lovelace
                | key <- every "--fund-skey" args
                ]
    pure (uniform <> groups <> addressed)

{- | One @--fund FILE:N:LOVELACE@: a key file, a positive number of outputs
and a positive lovelace amount, each separated by a colon.
-}
fundGroup :: String -> Either String Funding
fundGroup spelling = case break (== ':') spelling of
    (key, ':' : rest) -> case break (== ':') rest of
        (outputs, ':' : lovelace)
            | Just n <- readMaybe outputs
            , Just l <- readMaybe lovelace
            , n > 0
            , l > 0 ->
                Right (Funding (TargetKey key) n l)
        _ -> Left malformed
    _ -> Left malformed
  where
    malformed =
        "devnet: --fund expects FILE:N:LOVELACE, a key file, a positive"
            <> " output count and a positive lovelace amount, not "
            <> show spelling

{- | One @--fund-address ADDRESS:N:LOVELACE@: a bech32 address of the test
network, a positive number of outputs and a positive lovelace amount, each
separated by a colon (a bech32 address holds no colon). The address is
decoded here, so a spelling that is no address, a mainnet address and a
bootstrap address are each refused by name before any node starts.
-}
fundAddressGroup :: String -> Either String Funding
fundAddressGroup spelling = case break (== ':') spelling of
    (address, ':' : rest) -> case break (== ':') rest of
        (outputs, ':' : lovelace)
            | Just n <- readMaybe outputs
            , Just l <- readMaybe lovelace
            , n > 0
            , l > 0 -> do
                target <- testnetAddress address
                Right (Funding (TargetAddress target) n l)
        _ -> Left malformed
    _ -> Left malformed
  where
    malformed =
        "devnet: --fund-address expects ADDRESS:N:LOVELACE, a test-network"
            <> " bech32 address, a positive output count and a positive"
            <> " lovelace amount, not "
            <> show spelling

-- | A test-network Shelley address, or the reason it is none.
testnetAddress :: String -> Either String Addr
testnetAddress spelling = case parseAddress (T.pack spelling) of
    Left reason ->
        refuse ("is not a bech32 address (" <> T.unpack reason <> ")")
    Right address@(Addr Testnet _ _) -> Right address
    Right (Addr Mainnet _ _) -> refuse "is a mainnet address"
    Right (AddrBootstrap _) -> refuse "is a bootstrap address"
  where
    refuse why =
        Left $
            "devnet: --fund-address "
                <> show spelling
                <> " "
                <> why
                <> ": the devnet funds a test-network Shelley address"

-- | Every value a repeatable flag was given.
every :: String -> [String] -> [String]
every name = \case
    (a : v : rest) | a == name -> v : every name rest
    (a : rest)
        | (name <> "=") `isPrefixOf` a ->
            drop (length name + 1) a : every name rest
        | otherwise -> every name rest
    [] -> []

-- | The first value a flag was given.
flag :: String -> [String] -> Maybe String
flag name = \case
    (a : rest)
        | a == name -> case rest of
            (v : _) -> Just v
            [] -> Nothing
        | (name <> "=") `isPrefixOf` a -> Just (drop (length name + 1) a)
        | otherwise -> flag name rest
    [] -> Nothing

-- | Read the probe's flags and ask the node ("Devnet.Probe").
probe :: [String] -> IO ()
probe args = do
    sock <-
        maybe (die "devnet probe: --node-socket is required") pure $
            flag "--node-socket" args
    magicWord <-
        maybe (die "devnet probe: --network-magic is not a number") pure $
            readMaybe (fromMaybe "42" (flag "--network-magic" args))
    txIns <-
        either (die . ("devnet probe: " <>)) pure $
            traverse (parseOutRef . T.pack) (every "--tx-in" args)
    Probe.probe sock magicWord txIns

{- | A development-network control: spend a key-owned reference output and
return its value minus the ledger fee to its owner. This is fixture code,
outside the product commands. If the builder underprices the spend, record
its node rejection before submitting the same spend with the ledger's fee.
No uncertain submission is retried.
-}
spendReference :: [String] -> IO ()
spendReference args = withRunner $ \wallet caps -> do
    ref <-
        either die pure . parseOutRef . T.pack
            =<< maybe (die "spend-reference needs --tx-in") pure (flag "--tx-in" args)
    (original, corrected, bytes, required) <- Session.withLatest (capReads caps) $ \session -> do
        known <- Session.outputsAt session (walletAddr wallet)
        out <-
            maybe
                (fail "reference output is not owned by this wallet")
                pure
                (lookup ref known)
        unless
            (out ^. addrTxOutL == walletAddr wallet)
            (fail "foreign reference owner")
        let MaryValue _ assets = out ^. valueTxOutL
        unless
            (assets == mempty)
            (fail "the reference spend control takes no tokens")
        case out ^. referenceScriptTxOutL of
            SNothing -> fail "the output carries no reference script"
            SJust _ -> pure ()
        built <-
            assembleTransaction
                session
                [(ref, out)]
                []
                (walletAddr wallet)
                (pure ())
                >>= either (fail . show) pure
        protocol <- Session.parameters session
        let bytes = refScriptsSize (Set.singleton ref) [(ref, out)]
            minimumFee tx = estimateMinFeeTx protocol tx 1 0 bytes
            originalFee = built ^. bodyTxL . feeTxBodyL
            -- Changing only fee and change preserves the spent output and
            -- its owner. Iterate because the fee's encoding changes size.
            price remaining fee
                | remaining == (0 :: Int) =
                    fail "reference spend fee did not converge"
                | otherwise = do
                    let Coin held = out ^. coinTxOutL
                        Coin cost = fee
                        tx =
                            built
                                & bodyTxL . feeTxBodyL .~ fee
                                & bodyTxL . outputsTxBodyL
                                    .~ StrictSeq.singleton
                                        ( mkBasicTxOut
                                            (walletAddr wallet)
                                            (MaryValue (Coin (held - cost)) mempty)
                                        )
                        needed = minimumFee tx
                    unless
                        (held > cost)
                        (fail "reference output cannot pay its spending fee")
                    if fee >= needed then pure tx else price (remaining - 1) needed
        priced <- price 10 originalFee
        pure (built, priced, bytes, minimumFee built)
    let supplied = original ^. bodyTxL . feeTxBodyL
        signed = signTx (walletSignKey wallet)
        transaction tx =
            object
                [ "output" .= renderOutRef (TxIn (txIdTx tx) (TxIx 0))
                , "fee" .= (let Coin fee = tx ^. bodyTxL . feeTxBodyL in fee)
                , "unsignedSizeBytes" .= (tx ^. sizeTxF)
                , "sizeBytes" .= (signedTx (signed tx) ^. sizeTxF)
                , "cborHex"
                    .= TextEncoding.decodeUtf8
                        ( B16.encode
                            (serialize' (eraProtVerLow @ConwayEra) (signedTx (signed tx)))
                        )
                ]
    rejection <-
        if supplied < required
            then
                capSubmit caps (signed original) >>= \case
                    SubmitRefused why -> pure (Just why)
                    other ->
                        fail
                            ( "the underpriced control did not produce a ledger refusal: "
                                <> show other
                            )
            else pure Nothing
    result <- capSubmit caps (signed corrected)
    case result of
        SubmitAccepted _ -> capConfirm caps (signedTx (signed corrected))
        other -> fail ("reference spend control was not accepted: " <> show other)
    LBS.putStrLn . encode $
        object
            [ "input" .= renderOutRef ref
            , "scriptBytes" .= bytes
            , "builder" .= transaction original
            , "requiredFee" .= (let Coin fee = required in fee)
            , "builderRefusal" .= rejection
            , "control" .= transaction corrected
            ]

{- | Pay the requested outputs from the genesis key and wait for them,
through the shipping shared HTTP constructor and exact-output confirmation.
-}
fund :: Capabilities NoWitness IO -> Funding -> IO ()
fund caps f = do
    target <- case fundTarget f of
        TargetKey key -> walletAddr <$> loadWallet 42 key
        TargetAddress address -> pure address
    utxos <-
        Session.withLatest (capReads caps) (`Session.outputsAt` genesisAddr)
    (txIn, out) <- case sortOn (Down . (^. coinTxOutL) . snd) utxos of
        (u : _) -> pure u
        [] -> fail "devnet: the genesis address holds nothing to fund from"
    let fee = 1_000_000
        Coin held = out ^. coinTxOutL
        paid = fromIntegral (fundOutputs f) * fundLovelace f
        change = held - paid - fee
        pay n = mkBasicTxOut n (MaryValue (Coin (fundLovelace f)) mempty)
    unless (change > 1_000_000) $
        fail "devnet: the genesis output cannot pay the requested funding"
    let body =
            mkBasicTxBody
                & inputsTxBodyL .~ Set.singleton txIn
                & outputsTxBodyL
                    .~ StrictSeq.fromList
                        ( replicate (fundOutputs f) (pay target)
                            <> [mkBasicTxOut genesisAddr (MaryValue (Coin change) mempty)]
                        )
                & feeTxBodyL .~ Coin fee
        signed = signTx genesisSignKey (mkBasicTx body)
    result <- capSubmit caps signed
    case result of
        SubmitAccepted _ -> pure ()
        refusal -> fail ("devnet: funding rejected: " <> show refusal)
    capConfirm caps (signedTx signed)
    hPutStrLn stderr $
        "devnet: funded "
            <> bech32Address target
            <> " with "
            <> show (fundOutputs f)
            <> " outputs of "
            <> show (fundLovelace f)
            <> " lovelace"
