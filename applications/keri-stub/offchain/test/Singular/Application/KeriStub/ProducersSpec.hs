{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- |
Module      : Singular.Application.KeriStub.ProducersSpec
Description : The keri-stub producers run in process, as the frozen law needs them
License     : Apache-2.0

Each command is parsed and run through 'runKeriStub', the dispatch the packaged
command runs, over an environment that serves a chain fixture instead of Koios:
the fixture applies every submitted transaction to its own outputs, and the
registry's validators are accept-all programs. The stub's own script is an
always-succeeding program: no row here claims protected custody, consent or
production security of the stub, only the shape of what its producers book
and what the fold finds.

Registrations and the active key a termination needs are booked apart from
the stub's producers, by the registry library's registration booking and fold,
so that a control starts from a registry the producers did not write.
Every expectation is read from the booking, the chain or the stub's own
script, never typed.
-}
module Singular.Application.KeriStub.ProducersSpec (spec) where

import Control.Exception (bracket)
import Control.Monad (forM)
import Control.Tracer (Tracer (..))
import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as BL
import Data.ByteString.Short qualified as SBS
import Data.Foldable (toList)
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Lens.Micro ((^.))
import System.FilePath ((</>))
import System.IO (hFlush, stderr, stdout)
import System.IO.Temp (withSystemTempDirectory)
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
import System.Posix.Types (Fd)
import Test.Hspec

import Cardano.Ledger.Address (Addr (..), serialiseAddr)
import Cardano.Ledger.Api.Tx (bodyTxL, txIdTx)
import Cardano.Ledger.Api.Tx.Body
    ( inputsTxBodyL
    , mintTxBodyL
    , outputsTxBodyL
    )
import Cardano.Ledger.Api.Tx.Out
    ( TxOut
    , addrTxOutL
    , coinTxOutL
    , mkBasicTxOut
    , valueTxOutL
    )
import Cardano.Ledger.BaseTypes (Network (Testnet), TxIx (..))
import Cardano.Ledger.Core (hashScript)
import Cardano.Ledger.Credential
    ( Credential (..)
    , StakeReference (..)
    )
import Cardano.Ledger.Mary.Value
    ( AssetName (..)
    , MaryValue (..)
    , MultiAsset (..)
    , PolicyID (..)
    )
import Cardano.Ledger.TxIn (TxIn (..))
import Cardano.Tx.Ledger (ConwayTx)
import PlutusCore.Data qualified as PLC
import PlutusTx.Builtins.Internal (BuiltinByteString (..))

import Singular.Application.KeriStub.Command
    ( KeriStubCommand (..)
    , parseKeriStubCommand
    )
import Singular.Application.KeriStub.Datum
    ( Holding (..)
    , holdingFromData
    , holdingToData
    )
import Singular.Application.KeriStub.Run (runKeriStub)
import Singular.Application.KeriStub.Script
    ( keriStubScript
    , keriStubScriptBytes
    )
import Singular.Application.KeriStub.Value (keriStubApplication)
import Singular.CLI.Command (FoldArgs (..), WriteSettings (..))
import Singular.CLI.Live
    ( Live (..)
    , Saved (..)
    , attachLive
    , requireTrieSelection
    , resolveSaved
    , withTrie
    )
import Singular.CLI.ManagedState (addressPartition, managedDir)
import Singular.CLI.Receipt (JournalEntry (..), readJournal)
import Singular.CLI.ReceiptBody (boundBody)
import Singular.CLI.Registry (loadReleaseCodes)
import Singular.CLI.Session (Env (..), readsIn)
import Singular.Registry.Capabilities (Capabilities (..))
import Singular.Registry.Deployment (parseOutRef, renderOutRef)
import Singular.Registry.Evidence (NoWitness, unverifiedVerifier)
import Singular.Registry.Ledger (Coin (..), ConwayEra)
import Singular.Registry.LedgerProvider qualified as Cage
import Singular.Registry.RawChainFixture
    ( ChainFacts (..)
    , RawChain
    , advanceChain
    , jumpChainTo
    , newRawChain
    , rawChainProvider
    , recordTransaction
    )
import Singular.Registry.SessionEvidence (observeProvider)
import Singular.Registry.SessionIO qualified as SessionIO
import Singular.Registry.Signing (signedTx)
import Singular.Registry.StateToken (ReferenceRole, parseStateToken)
import Singular.Registry.SyntheticLedger
    ( unitProgram
    , withSyntheticCosts
    )
import Singular.Registry.SyntheticTime (syntheticTime)
import Singular.Registry.TxBuilder.BookingFixture (preprodParams)
import Singular.Registry.TxBuilder.Edges (registryContextFor)
import Singular.Registry.TxBuilder.Internal
    ( addrKeyHashBytes
    , computeScriptHash
    , extractCageDatum
    , scriptHashBytes
    )
import Singular.Registry.TxBuilder.RegistrationBooking
    ( RegistrationBooking (..)
    , bookRegistrationImpl
    )
import Singular.Registry.TxBuilder.Update
    ( RegistryContext (..)
    , updateTokenSelected
    )
import Singular.Registry.Types
    ( CageDatum (..)
    , OnChainRegistrationRequest (..)
    , OnChainTerminationRequest (..)
    , applicationTagName
    , terminationTrieReadyTagName
    , trieReadyTagName
    )
import Singular.Registry.Wallet (Wallet (..), loadWallet)

spec :: Spec
spec = describe "chunk4 producers" $ do
    registerRows
    discoveryRows
    convictRows

-- ---------------------------------------------------------
-- The rig
-- ---------------------------------------------------------

data Rig = Rig
    { rigDir :: FilePath
    , rigChain :: RawChain
    , rigWallet :: Wallet
    , rigKey :: FilePath
    , rigBlueprint :: FilePath
    }

magic :: Integer
magic = 42

fundOutput :: Int -> TxIn
fundOutput n =
    either
        (error . ("fundOutput: " <>))
        id
        (parseOutRef (T.pack (replicate 64 'f' <> "#" <> show n)))

-- | The registry's validators as accept-all programs of the arities the builders apply.
blueprintJson :: Aeson.Value
blueprintJson =
    Aeson.object
        [ "preamble"
            .= Aeson.object
                ["title" .= ("synthetic" :: Text), "plutusVersion" .= ("v3" :: Text)]
        , "validators"
            .= [ validator "state.state" 1
               , validator "request.request" 3
               , validator "witness.witness" 3
               , validator "witness.witness" 3
               ]
        , "definitions" .= Aeson.object []
        ]
  where
    validator :: Text -> Int -> Aeson.Value
    validator title arity =
        let code = unitProgram arity
        in  Aeson.object
                [ "title" .= title
                , "redeemer" .= Aeson.object ["schema" .= Aeson.object []]
                , "hash"
                    .= TE.decodeUtf8 (B16.encode (scriptHashBytes (computeScriptHash code)))
                , "compiledCode" .= TE.decodeUtf8 (B16.encode (SBS.fromShort code))
                ]

withRig :: (Rig -> IO a) -> IO a
withRig use = withSystemTempDirectory "keri-stub-producers" $ \dir -> do
    let keyPath = dir </> "payment.skey"
        blueprint = dir </> "plutus.json"
    BS.writeFile keyPath (B16.encode (BC.replicate 32 'w'))
    BL.writeFile blueprint (Aeson.encode blueprintJson)
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
    use (Rig dir chain wallet keyPath blueprint)

-- | The environment of a run over the rig: the fixture's capabilities.
envOf :: Rig -> Env
envOf rig =
    Env
        { envTracer = Tracer (\_ -> pure ())
        , envSource = "fixture"
        , envLoadRelease = loadReleaseCodes
        , envReads = \_ k -> k (capabilities rig)
        , envWrites = \_ k -> k (capabilities rig)
        }

-- | Reads of the chain fixture, and a submission it applies to its outputs.
capabilities :: Rig -> Capabilities NoWitness IO
capabilities rig =
    Capabilities
        { capReads =
            let (net, provider) = rawChainProvider (rigChain rig)
            in  (net, observeProvider unverifiedVerifier (\_ -> pure ()) provider)
        , capSubmit = \signed -> do
            let tx = signedTx signed
            landTx rig tx
            pure (Cage.SubmitAccepted (txIdTx tx))
        , capConfirm = \_ -> pure ()
        , capFacts = pure []
        , capTrace = pure []
        }

-- | A transaction the chain applies: recorded, its outputs live, its inputs spent.
landTx :: Rig -> ConwayTx -> IO ()
landTx rig tx = do
    let txid = txIdTx tx
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

-- | A command line over the rig, as the packaged command is given it.
commandLine :: Rig -> [String] -> [String]
commandLine rig args =
    args
        <> [ "--state-dir"
           , rigDir rig </> "registry"
           , "--blueprint"
           , rigBlueprint rig
           , "--koios-url"
           , "http://fixture.invalid"
           , "--network-magic"
           , show magic
           ]
        <> concat
            [ ["--wallet-skey", rigKey rig] | take 2 args /= ["keri-stub", "status"]
            ]
        <> concat
            [ ["--registration-cost", "0", "--booking-width", "60000"]
            | take 2 args == ["keri-stub", "create"]
            ]

-- | The receipt one command printed.
run :: Rig -> String -> [String] -> IO Aeson.Value
run rig label args = do
    command <-
        either
            (fail . show)
            pure
            (parseKeriStubCommand (commandLine rig args))
    (_, out) <- captured (runKeriStub (envOf rig) command)
    maybe
        (fail ("no receipt for " <> label <> ": " <> show out))
        pure
        (Aeson.decodeStrict out)

captured :: IO a -> IO (a, ByteString)
captured act = withSystemTempDirectory "keri-stub-captured" $ \dir -> do
    let outPath = dir </> "stdout"
        errPath = dir </> "stderr"
    a <- redirecting stdOutput outPath (redirecting stdError errPath act)
    (,) a <$> BS.readFile outPath

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

valueAt :: Aeson.Key -> Aeson.Value -> Maybe Aeson.Value
valueAt k = \case
    Aeson.Object o -> KeyMap.lookup k o
    _ -> Nothing

textAt :: Aeson.Key -> Aeson.Value -> Maybe Text
textAt k v = case valueAt k v of
    Just (Aeson.String t) -> Just t
    _ -> Nothing

outcomeOf :: Aeson.Value -> Maybe Text
outcomeOf = textAt "outcome"

failTest :: String -> IO a
failTest why = expectationFailure why >> fail why

-- | A registry created over the rig, and the state token it printed.
withRegistry :: (Rig -> String -> IO a) -> IO a
withRegistry use = withRig $ \rig -> do
    let seed = T.unpack (renderOutRef (fundOutput 1))
    create <- run rig "create" ["keri-stub", "create", "--seed", seed]
    outcomeOf create `shouldBe` Just "success"
    case textAt "stateToken" create of
        Just t -> use rig (T.unpack t)
        Nothing -> failTest "the create printed no state token"

tokenArgs :: String -> [String]
tokenArgs t = ["--state-token", t]

-- | The transactions a command prepared, read from the registry's journal.
preparedBodies :: Rig -> String -> Text -> IO [ConwayTx]
preparedBodies rig tokenStr command = do
    token <-
        either (failTest . T.unpack) pure (parseStateToken (T.pack tokenStr))
    let partition =
            managedDir
                (rigDir rig </> "registry")
                (fromIntegral magic)
                token
                (addressPartition (walletAddr (rigWallet rig)))
    entries <- readJournal partition
    forM
        [ e
        | e <- entries
        , journalEvent e == "prepared"
        , journalCommand e == command
        ]
        $ \e -> do
            (_, body) <- boundBody entries (journalTxId e)
            either (fail . T.unpack) pure body

preparedFirst :: Rig -> String -> Text -> IO ConwayTx
preparedFirst rig tokenStr command =
    preparedBodies rig tokenStr command >>= \case
        body : _ -> pure body
        [] ->
            failTest ("the " <> T.unpack command <> " prepared no transaction")

walletKeyHash :: Rig -> ByteString
walletKeyHash = addrKeyHashBytes . walletAddr . rigWallet

-- | The stub script's own enterprise address, derived from its bytes.
stubAddress :: Addr
stubAddress =
    Addr Testnet (ScriptHashObj (hashScript keriStubScript)) StakeRefNull

stubAddressBytes :: ByteString
stubAddressBytes = serialiseAddr stubAddress

stubPolicy :: PolicyID
stubPolicy = PolicyID (hashScript keriStubScript)

-- | The outputs of a body that carry a cage datum.
cageOutputs :: ConwayTx -> [(TxOut ConwayEra, CageDatum)]
cageOutputs tx =
    [ (out, datum)
    | out <- toList (tx ^. bodyTxL . outputsTxBodyL)
    , Just datum <- [extractCageDatum out]
    ]

datumKind :: CageDatum -> String
datumKind = \case
    RequestDatum _ -> "a legacy request datum"
    StateDatum _ -> "a state datum"
    AbsentCustody _ -> "an absent-custody datum"
    RegistrationDatum _ -> "a registration request datum"
    TerminationDatum _ -> "a termination request datum"

mintOf :: ConwayTx -> Map.Map PolicyID (Map.Map AssetName Integer)
mintOf tx = let MultiAsset m = tx ^. bodyTxL . mintTxBodyL in m

policyOfAddress :: TxOut ConwayEra -> Maybe PolicyID
policyOfAddress out = case out ^. addrTxOutL of
    Addr _ (ScriptHashObj h) _ -> Just (PolicyID h)
    _ -> Nothing

lovelaceOf :: TxOut ConwayEra -> Integer
lovelaceOf out = let Coin c = out ^. coinTxOutL in c

-- ---------------------------------------------------------
-- A registration booked apart from the stub's producers
-- ---------------------------------------------------------

-- | The registry resolved the way a command resolves it.
withLawful
    :: Rig
    -> String
    -> (Cage.Session NoWitness IO -> Saved -> Live -> IO a)
    -> IO a
withLawful rig t use = do
    command <-
        either
            (fail . show)
            pure
            ( parseKeriStubCommand
                (commandLine rig (["keri-stub", "fold"] <> tokenArgs t))
            )
    args <- case command of
        KeriFold a -> pure a
        _ -> failTest "the line is no fold"
    let env = envOf rig
    release <-
        envLoadRelease env keriStubApplication (foldBlueprint args)
            >>= either failTest pure
    envReads env (writeProvider (foldWrite args)) $ \caps ->
        SessionIO.withLatest (readsIn (envSource env) (envTracer env) caps) $ \v -> do
            saved <-
                resolveSaved
                    keriStubApplication
                    ""
                    release
                    (foldAccess args)
                    (Set.fromList [minBound .. maxBound :: ReferenceRole])
                    Nothing
                    v
            live <- attachLive v saved
            use v saved live

-- | The holding a registration of this key carries.
holdingOf :: Rig -> ByteString -> Integer -> Holding
holdingOf rig key deposit =
    Holding
        { hdKey = key
        , hdController = walletKeyHash rig
        , hdDeposit = deposit
        , hdPayload = PLC.B "prefix"
        }

{- | A registration of this key booked by the registry library and landed, the
tip moved past its booked time: the request it made.
-}
plantRegistration :: Rig -> String -> ByteString -> IO TxIn
plantRegistration rig t key = withLawful rig t $ \v saved live -> do
    tip <- SessionIO.tip v
    let slot = Cage.observedSlot tip
        payer = walletAddr (rigWallet rig)
    tx <-
        bookRegistrationImpl
            (savedCfg saved)
            v
            (savedToken saved)
            (fst (liveState live))
            RegistrationBooking
                { rbKey = key
                , rbRefundAddress = payer
                , rbDestination = stubAddressBytes
                , rbDatum = Just (holdingToData (holdingOf rig key 4_000_000))
                , rbDeclaredTip = Coin 1_000_000
                , rbCarrier = Coin 4_000_000
                , rbNonce = 11
                , rbLower = slot
                , rbUpper = slot + 10
                , rbApplicationScript = keriStubScriptBytes
                }
            payer
    landTx rig tx
    jumpChainTo (rigChain rig) (slot + 40)
    pure (TxIn (txIdTx tx) (TxIx 0))

-- | A key that is active, made apart from the stub's producers: the registration, folded by the library.
activeKeyApart :: Rig -> String -> ByteString -> IO ()
activeKeyApart rig t key = do
    request <- plantRegistration rig t key
    withLawful rig t $ \_ saved live -> do
        let cfg = savedCfg saved
            payer = walletAddr (rigWallet rig)
        SessionIO.withLatest (rawChainProvider (rigChain rig)) $ \v -> do
            live' <- attachLive v saved
            sel <- requireTrieSelection saved live'
            ctx0 <- registryContextFor cfg (savedCodes saved) v (liveRefs live)
            let ctx =
                    ctx0
                        { rcWitnessScripts =
                            -- the witness kinds are 0, 1 and 2: the stub script sits beside them
                            Map.insert
                                100
                                keriStubScript
                                (rcWitnessScripts ctx0)
                        }
            folded <-
                withTrie sel $ \snapshot ->
                    updateTokenSelected
                        cfg
                        v
                        snapshot
                        (savedToken saved)
                        payer
                        ctx
                        (request NE.:| [])
            landTx rig folded

leafOf :: Rig -> String -> ByteString -> IO (Maybe Aeson.Value)
leafOf rig t key = do
    status <-
        run
            rig
            "status"
            (["keri-stub", "status", "--key", BC.unpack key] <> tokenArgs t)
    pure (valueAt "leaf" status)

-- ---------------------------------------------------------
-- register
-- ---------------------------------------------------------

registerRows :: Spec
registerRows =
    describe "a register books a tagged registration request" $ do
        it
            "puts one registration request on chain, carrying the holding for the stub's own address"
            $ withBooked
            $ \rig _ body -> do
                (out, r) <- registrationOf body
                regKey r `shouldBe` "hello"
                refundOf r `shouldBe` walletKeyHash rig
                regDestination r `shouldBe` stubAddressBytes
                holding <- case regDatum r of
                    Just d ->
                        either
                            (failTest . ("the carried datum is no holding: " <>))
                            pure
                            (holdingFromData d)
                    Nothing -> failTest "the registration request carries no datum"
                hdKey holding `shouldBe` "hello"
                hdController holding `shouldBe` walletKeyHash rig
                hdDeposit holding `shouldBe` regCarrierAda r
                lovelaceOf out
                    `shouldBe` regRegistrationCost r + regDeclaredTip r + regCarrierAda r
        it
            "mints the request's trie-ready tag and the application tag it commits to, one each, and nothing else"
            $ withBooked
            $ \_ _ body -> do
                (out, r) <- registrationOf body
                requestPolicy <-
                    maybe
                        (failTest "the request output is not at a script")
                        pure
                        (policyOfAddress out)
                mintOf body
                    `shouldBe` Map.fromList
                        [
                            ( requestPolicy
                            , Map.singleton (AssetName (SBS.toShort (trieReadyTagName r))) 1
                            )
                        ,
                            ( stubPolicy
                            , Map.singleton
                                ( AssetName
                                    ( SBS.toShort
                                        ( applicationTagName
                                            (regKey r)
                                            (regRefundAddress r)
                                            (regDestination r)
                                            (regNonce r)
                                        )
                                    )
                                )
                                1
                            )
                        ]
        it "with the fold, ends with the key active" $
            withRegistry $ \rig t -> do
                done <- run rig "register with the fold" (registerLine ["--fold"] t)
                outcomeOf done `shouldBe` Just "success"
                leafOf rig t "hello" `shouldReturn` Just (Aeson.String "active")
  where
    registerLine extra t =
        ["keri-stub", "register", "--key", "hello", "--deposit", "4000000"]
            <> extra
            <> tokenArgs t
    withBooked use = withRegistry $ \rig t -> do
        booked <- run rig "register" (registerLine [] t)
        outcomeOf booked `shouldBe` Just "success"
        body <- preparedFirst rig t "register"
        use rig t body

refundOf :: OnChainRegistrationRequest -> ByteString
refundOf r = case regRefundAddress r of
    BuiltinByteString bytes -> bytes

registrationOf
    :: ConwayTx -> IO (TxOut ConwayEra, OnChainRegistrationRequest)
registrationOf tx = case cageOutputs tx of
    [(out, RegistrationDatum r)] -> pure (out, r)
    found ->
        failTest
            ( "expected one registration request output in the booking, found "
                <> show (map (datumKind . snd) found)
            )

-- ---------------------------------------------------------
-- fold
-- ---------------------------------------------------------

discoveryRows :: Spec
discoveryRows =
    describe "the fold finds a booked registration by the request policy" $
        it "settles a registration booked apart from the stub's producers" $
            withRegistry $ \rig t -> do
                _ <- plantRegistration rig t "hello"
                folded <- run rig "fold" (["keri-stub", "fold"] <> tokenArgs t)
                case outcomeOf folded of
                    Just "success" -> pure ()
                    other ->
                        failTest
                            ( "the fold ended "
                                <> show other
                                <> ": "
                                <> show (textAt "reason" folded)
                            )
                leafOf rig t "hello" `shouldReturn` Just (Aeson.String "active")

-- ---------------------------------------------------------
-- convict
-- ---------------------------------------------------------

convictRows :: Spec
convictRows =
    describe
        "a convict books the spend of the key's holding as a termination request"
        $ do
            it
                "spends the holding and books one termination request that holds the whole of it"
                $ withConvicted
                $ \_ _ holding body -> do
                    (out, request) <- terminationOf body
                    termKey request `shouldBe` "hello"
                    Set.member (fst holding) (body ^. bodyTxL . inputsTxBodyL)
                        `shouldBe` True
                    lovelaceOf out `shouldSatisfy` (>= lovelaceOf (snd holding))
                    let held = valueOf (snd holding)
                        requested = valueOf out
                    [ (policy, name)
                      | (policy, names) <- Map.toList held
                      , (name, quantity) <- Map.toList names
                      , (Map.lookup policy requested >>= Map.lookup name) /= Just quantity
                      ]
                        `shouldBe` []
            it "mints the request's trie-ready tag and nothing else" $
                withConvicted $ \_ _ _ body -> do
                    (out, request) <- terminationOf body
                    requestPolicy <-
                        maybe
                            (failTest "the request output is not at a script")
                            pure
                            (policyOfAddress out)
                    mintOf body
                        `shouldBe` Map.singleton
                            requestPolicy
                            ( Map.singleton
                                (AssetName (SBS.toShort (terminationTrieReadyTagName request)))
                                1
                            )
            it "with the fold, ends with the key terminal" $
                withRegistry $ \rig t -> do
                    activeKeyApart rig t "hello"
                    done <- run rig "convict with the fold" (convictLine ["--fold"] t)
                    outcomeOf done `shouldBe` Just "success"
                    leafOf rig t "hello" `shouldReturn` Just (Aeson.String "terminal")
  where
    convictLine extra t =
        [ "keri-stub"
        , "convict"
        , "--key"
        , "hello"
        , "--evidence"
        , T.unpack evidenceHex
        ]
            <> extra
            <> tokenArgs t
    evidenceHex = TE.decodeUtf8 (B16.encode (BS.replicate 32 0x0e))
    valueOf out = let MaryValue _ (MultiAsset m) = out ^. valueTxOutL in m
    terminationOf tx = case cageOutputs tx of
        [(out, TerminationDatum r)] -> pure (out, r)
        found ->
            failTest
                ( "expected one termination request output in the booking, found "
                    <> show (map (datumKind . snd) found)
                )
    withConvicted use = withRegistry $ \rig t -> do
        activeKeyApart rig t "hello"
        holding <- holdingOutput rig
        booked <- run rig "convict" (convictLine [] t)
        case outcomeOf booked of
            Just "success" -> pure ()
            other ->
                failTest
                    ( "the convict ended "
                        <> show other
                        <> ": "
                        <> show (textAt "reason" booked)
                    )
        body <- preparedFirst rig t "convict"
        use rig t holding body

-- | The one live output at the stub's address: the key's holding.
holdingOutput :: Rig -> IO (TxIn, TxOut ConwayEra)
holdingOutput rig = do
    outs <-
        SessionIO.withLatest (rawChainProvider (rigChain rig)) $ \v ->
            SessionIO.outputsAt v stubAddress
    case outs of
        [one] -> pure one
        found ->
            failTest
                ( "expected one live output at the stub's address, found "
                    <> show (length found)
                )
