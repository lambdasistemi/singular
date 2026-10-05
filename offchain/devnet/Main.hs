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

@devnet probe --node-socket PATH [--network-magic N] [--tx-in TXID#IX]...@
(#325) spawns nothing: it asks the node at @PATH@, from one acquired
ledger state, for its chain tip and which of the named outputs are
unspent, and prints one JSON object,
@{"tip":{"slot":N,"hash":HEX},"live":[...],"spent":[...]}@. A control
that rolls a development node back reads the node's own answer through
it, never the answer of the command under test.
-}
module Main (main) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.MVar (newMVar, withMVar)
import Control.Monad (forever, unless)
import Data.List (isPrefixOf, sortOn)
import Data.Maybe (fromMaybe)
import Data.Ord (Down (..))
import Data.Sequence.Strict qualified as StrictSeq
import Data.Set qualified as Set
import Data.Text qualified as T
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
import System.Process
    ( CreateProcess (..)
    , proc
    , rawSystem
    , waitForProcess
    , withCreateProcess
    )
import Text.Read (readMaybe)

import Cardano.Ledger.Api.Tx (mkBasicTx)
import Cardano.Ledger.Api.Tx.Body
    ( feeTxBodyL
    , inputsTxBodyL
    , mkBasicTxBody
    , outputsTxBodyL
    )
import Cardano.Ledger.Api.Tx.Out (coinTxOutL, mkBasicTxOut)
import Cardano.Ledger.Mary.Value (MaryValue (..))
import Cardano.Node.Client.E2E.Setup
    ( genesisAddr
    , genesisDir
    , genesisSignKey
    , rawSerialiseSignKeyDSIGN
    )
import Devnet.Probe qualified as Probe
import Singular.Registry.Private.Facade
import Singular.Registry.Private.Smoke (runFacadeSmoke)
import Singular.Registry.ProviderSettings (ProviderSettings (..))
import Singular.Registry.Runner (runnerSettings)
import Singular.Registry.SessionIO qualified as Session
import Singular.Registry.Terminal (withReads)

import Data.Aeson (encode, object, (.=))
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Lazy.Char8 qualified as LBS
import Singular.Registry.Capabilities
    ( Capabilities (..)
    )
import Singular.Registry.Deployment (parseOutRef)
import Singular.Registry.Evidence (NoWitness)
import Singular.Registry.Ledger (Coin (..))
import Singular.Registry.LedgerProvider (SubmitResult (..))
import Singular.Registry.Signing (signTx, signedTx)
import Singular.Registry.Wallet
    ( Wallet (..)
    , bech32Address
    , loadWallet
    )

-- | The optional funding a caller asked for.
data Funding = Funding
    { fundKey :: FilePath
    , fundOutputs :: Int
    , fundLovelace :: Integer
    }

main :: IO ()
main = do
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
        _ -> spawn args

-- | Spawn the private facade, fund through shared HTTP, print settings, wait.
spawn :: [String] -> IO ()
spawn args = do
    withFixture args $ \evidence facade -> withReads (facadeSettings facade) $ \caps -> do
        mapM_ (fund caps) (fundingFrom args)
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
        forever (threadDelay 3_600_000_000)

{- | The CI launcher owns the generated node. Its child receives only public
provider/time settings and one ephemeral private fixture wallet file.
-}
run :: FilePath -> [String] -> IO ()
run command arguments = do
    environment <- getEnvironment
    let supplied =
            any configured arguments
                || any
                    (\name -> maybe False (const True) (lookup name environment))
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
    withGeneratedFacade gDir observe $ \_ facade -> action evidence facade

{- | Read the funding flags: every @--fund-skey@ given (it may repeat, one
wallet each), all paid the same @--fund-outputs@ of @--fund-lovelace@.
None when any of the three is absent.
-}
fundingFrom :: [String] -> [Funding]
fundingFrom args = fromMaybe [] $ do
    outputs <- flag "--fund-outputs" args >>= readMaybe
    lovelace <- flag "--fund-lovelace" args >>= readMaybe
    pure [Funding key outputs lovelace | key <- every "--fund-skey" args]

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

{- | Pay the requested outputs from the genesis key and wait for them,
through the shipping shared HTTP constructor and exact-output confirmation.
-}
fund :: Capabilities NoWitness IO -> Funding -> IO ()
fund caps f = do
    target <- walletAddr <$> loadWallet 42 (fundKey f)
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
