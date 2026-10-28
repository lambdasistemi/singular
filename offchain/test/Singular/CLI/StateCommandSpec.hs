{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.CLI.StateCommandSpec
Description : As the creator of a registry I create it with one command, and an interrupted command keeps its transaction
License     : Apache-2.0

As the owner of an application I run @singular registry create@ with the policy of
my application and a wallet of mine. The first registry of the application
publishes the state script as a reference script and creates the registry's
state in a second transaction; a later registry finds the live copy and
creates in one. The command prints the registry it made and the transactions it
sent.

If the node's answer is lost, or I cancel the command, the transaction it
prepared keeps its identity in the journal, the next command observes it once
when the chain holds it, and nothing is sent again on its own.

The rows run the packaged command line through the in-process rig: a chain
fixture applies what is submitted, and the validators are accept-all programs,
so what is established here is what the command builds, sends and records; that
the compiled validators accept it is the builders' own rows and the devnet
journey.
-}
module Singular.CLI.StateCommandSpec (spec) where

import Cardano.Crypto.Hash (hashFromBytes)
import Cardano.Ledger.Api.Tx (bodyTxL, witsTxL)
import Cardano.Ledger.Api.Tx.Body
    ( inputsTxBodyL
    , referenceInputsTxBodyL
    )
import Cardano.Ledger.Api.Tx.Out
    ( addrTxOutL
    , mkBasicTxOut
    , referenceScriptTxOutL
    , valueTxOutL
    )
import Cardano.Ledger.Api.Tx.Wits (scriptTxWitsL)
import Cardano.Ledger.BaseTypes
    ( Inject (..)
    , Network (Testnet)
    , StrictMaybe (..)
    )
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Core (hashScript)
import Cardano.Ledger.Hashes (ScriptHash (..))
import Cardano.Ledger.Mary.Value
    ( AssetName (..)
    , MaryValue (..)
    , MultiAsset (..)
    , PolicyID (..)
    )
import Cardano.Ledger.TxIn (TxIn)
import Cardano.Tx.Ledger (ConwayTx)
import Control.Concurrent
    ( newEmptyMVar
    , putMVar
    , takeMVar
    , threadDelay
    )
import Control.Concurrent.Async (async, cancel, race, waitCatch)
import Control.Monad (forM_, void, when)
import Data.Aeson qualified as Aeson
    ( KeyValue ((.=))
    , Value
    , object
    )
import Data.ByteString qualified as BS
    ( ByteString
    , readFile
    , replicate
    )
import Data.ByteString.Base16 qualified as B16 (encode)
import Data.ByteString.Short qualified as SBS (fromShort)
import Data.Foldable (toList)
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Map.Strict qualified as Map (singleton)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T (isInfixOf, pack, unpack)
import Data.Text.Encoding qualified as TE (decodeUtf8)
import Lens.Micro ((&), (.~), (^.))
import Singular.CLI.Command (CLIError (..), parseCommand)
import Singular.CLI.CommandRunSpec
    ( Rig (..)
    , Run (..)
    , capabilities
    , envOf
    , externalArgs
    , outcomeOf
    , policyArgs
    , readWallet
    , runVia
    , submissionsOf
    , textAt
    , valueAt
    , withRigOf
    )
import Singular.CLI.ManagedState (managedDir, walletPartition)
import Singular.CLI.Receipt (JournalEntry (..), readJournal)
import Singular.CLI.Registry (registryFields)
import Singular.CLI.Session (Env (..), txIdHex)
import Singular.Registry.Blueprint (loadBlueprint)
import Singular.Registry.Bundle (Bundle (..), decodeBundle)
import Singular.Registry.Capabilities (Capabilities (..))
import Singular.Registry.Deployment (parseOutRef, renderOutRef)
import Singular.Registry.Evidence
    ( Evidenced (..)
    , NoWitness
    , unverifiedVerifier
    )
import Singular.Registry.Ledger (ConwayEra, TxOut)
import Singular.Registry.LedgerProvider
    ( OutputQuery (..)
    , Session
    )
import Singular.Registry.LedgerProvider qualified as Cage
    ( LedgerProvider (acquire)
    , Session (outputs)
    , SubmitResult (SubmitFailed)
    )
import Singular.Registry.RawChainFixture (rawChainProvider)
import Singular.Registry.SessionEvidence (observeProvider)
import Singular.Registry.SessionIO qualified as SessionIO
    ( withLatest
    )
import Singular.Registry.Signing (signedTx)
import Singular.Registry.SyntheticLedger (unitProgram)
import Singular.Registry.TxBuilder.Edges (selectFunding)
import Singular.Registry.TxBuilder.Internal
    ( addrFromKeyHashBytes
    , computeScriptHash
    , emptyRoot
    , scriptFromBytes
    , scriptHashBytes
    )
import Singular.Registry.Wallet (Wallet (..), bech32Address)
import Singular.State.Assemble (inlineDatumOf, readOutputs)
import Singular.State.Preimage (stateTokenName)
import Singular.State.Records (stateDatum)
import Singular.State.Script
    ( ScriptSource (..)
    , StateScript (..)
    , stateAddress
    , statePolicy
    , stateScriptFromBlueprint
    )
import System.Directory (doesFileExist)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import Test.Hspec
    ( Spec
    , describe
    , expectationFailure
    , it
    , shouldBe
    , shouldContain
    , shouldNotBe
    , shouldNotContain
    , shouldReturn
    , shouldSatisfy
    )

spec :: Spec
spec = describe "singular registry create" $ do
    parserRows
    creationRows
    interruptionRows

-- ---------------------------------------------------------
-- The command line
-- ---------------------------------------------------------

-- | The settings every row of the parser gives.
node :: [String]
node =
    [ "--blueprint"
    , "plutus.json"
    , "--koios-url"
    , "http://koios.example"
    , "--network-magic"
    , "42"
    ]

keyFile :: [String]
keyFile = ["--wallet-skey", "alice.skey"]

vaultFile :: [String]
vaultFile = ["--vault", "alice.vault"]

stateCreate :: [String] -> [String]
stateCreate rest = ["registry", "create"] <> node <> policyArgs <> rest

-- | The constructor a command line is read as, or why it is refused.
reading :: [String] -> Either CLIError String
reading = fmap (concat . take 1 . words . show) . parseCommand

{- | What a refusal is about: its kind and the flag it names, so that two
commands refuse one mistake alike whatever their sentences say.
-}
aboutRefusal :: Either CLIError a -> Maybe (String, String)
aboutRefusal = \case
    Right _ -> Nothing
    Left e -> Just $ case e of
        MissingFlag flag -> ("missing", flag)
        BadValue flag _ -> ("bad value", flag)
        UnsupportedFlag flag _ -> ("unsupported", flag)
        UnsafeSettings _ -> ("unsafe settings", "")
        other -> (concat (take 1 (words (show other))), "")

parserRows :: Spec
parserRows = describe "the command line" $ do
    it "reads a line with the policy of the application and one signer" $ do
        reading (stateCreate keyFile) `shouldBe` Right "StateCreate"
        reading (stateCreate vaultFile) `shouldBe` Right "StateCreate"
        reading
            ( stateCreate
                ["--wallet-address", aWalletAddress, "--bundle", "run.bundle"]
            )
            `shouldBe` Right "StateCreate"
    it
        "takes the seed to spend, and a seed that is no output reference is refused"
        $ do
            reading
                (stateCreate (keyFile <> ["--seed", replicate 64 'a' <> "#1"]))
                `shouldBe` Right "StateCreate"
            aboutRefusal (reading (stateCreate (keyFile <> ["--seed", "alice"])))
                `shouldBe` Just ("bad value", "--seed")
    it
        "names the policy of the application when it is missing or is no 28-byte hash"
        $ do
            aboutRefusal (reading (["registry", "create"] <> node <> keyFile))
                `shouldBe` Just ("missing", "--application-policy")
            aboutRefusal
                ( reading
                    ( ["registry", "create"]
                        <> node
                        <> ["--application-policy", "abcd"]
                        <> keyFile
                    )
                )
                `shouldBe` Just ("bad value", "--application-policy")
    it "names the blueprint when it is missing" $
        aboutRefusal
            ( reading
                ( ["registry", "create"]
                    <> [ "--koios-url"
                       , "http://koios.example"
                       , "--network-magic"
                       , "42"
                       ]
                    <> policyArgs
                    <> keyFile
                )
            )
            `shouldBe` Just ("missing", "--blueprint")
    it "refuses two signers, naming the conflicting vault" $
        aboutRefusal (reading (stateCreate (keyFile <> vaultFile)))
            `shouldBe` Just ("bad value", "--vault")
    it "refuses a setting the command does not take, naming it"
        $ forM_
            [ (["--fund-input", replicate 64 'b' <> "#0"], "--fund-input")
            , (["--max-outlay", "5000000"], "--max-outlay")
            , (["--process-time", "600000"], "--process-time")
            , (["--retract-time", "300000"], "--retract-time")
            , (["--preview"], "--preview")
            ,
                ( ["--state-token", replicate 56 'a' <> "." <> replicate 64 'b']
                , "--state-token"
                )
            , (["--registry", "singular_devnet1xyz"], "--registry")
            ]
        $ \(setting, flag) ->
            fmap snd (aboutRefusal (reading (stateCreate (keyFile <> setting))))
                `shouldBe` Just flag
    it "refuses the retired state group and command" $
        map
            (fmap fst . aboutRefusal . reading)
            [["state"], ["state", "create"]]
            `shouldBe` replicate 2 (Just "UnknownCommand")
    it
        "is a group of the program: the group page, and no command of another group"
        $ do
            reading ["registry"] `shouldBe` Right "Help"
            reading ["registry", "create", "--help"] `shouldBe` Right "Help"
            aboutRefusal (reading ["fold"])
                `shouldBe` Just ("UnknownCommand", "")

-- ---------------------------------------------------------
-- The rig
-- ---------------------------------------------------------

{- | The validator of the registry the commands name, as an accept-all program:
the state validator takes the application policy and then its context. The
commands of the registry read no other validator of the blueprint.
-}
stateBlueprint :: Aeson.Value
stateBlueprint =
    Aeson.object
        [ "preamble"
            Aeson..= Aeson.object
                [ "title" Aeson..= ("synthetic" :: Text)
                , "plutusVersion" Aeson..= ("v3" :: Text)
                ]
        , "validators"
            Aeson..= [validator "singular_state.singular_state.spend" 2]
        , "definitions" Aeson..= Aeson.object []
        ]
  where
    validator :: Text -> Int -> Aeson.Value
    validator title arity =
        let code = unitProgram arity
        in  Aeson.object
                [ "title" Aeson..= title
                , "redeemer"
                    Aeson..= Aeson.object ["schema" Aeson..= Aeson.object []]
                , "hash"
                    Aeson..= TE.decodeUtf8
                        (B16.encode (scriptHashBytes (computeScriptHash code)))
                , "compiledCode"
                    Aeson..= TE.decodeUtf8 (B16.encode (SBS.fromShort code))
                ]

withStateRig :: (Rig -> IO a) -> IO a
withStateRig = withRigOf stateBlueprint pure

-- | The policy of the application the rows pin: 28 bytes of 7.
applicationPolicy :: PolicyID
applicationPolicy =
    PolicyID . ScriptHash $
        fromMaybe (error "28 bytes") (hashFromBytes (BS.replicate 28 7))

-- | The state validator the rig's blueprint yields for that application.
stateScriptOf :: Rig -> IO StateScript
stateScriptOf rig = do
    blueprint <- loadBlueprint (rigBlueprint rig) >>= either fail pure
    script <-
        either
            fail
            pure
            (stateScriptFromBlueprint blueprint applicationPolicy)
    pure (StateScript script Attached)

-- | A view of the chain as it stands.
viewing :: Rig -> (Session NoWitness IO -> IO a) -> IO a
viewing rig = SessionIO.withLatest (rawChainProvider (rigChain rig))

outputsFor :: Rig -> OutputQuery -> IO [(TxIn, TxOut ConwayEra)]
outputsFor rig query =
    viewing rig $ \session ->
        readOutputs session query >>= either (fail . show) pure

{- | The environment of the rig, and what it was asked to submit, signed, in the
order it was asked.
-}
recordingEnv :: Rig -> IO (Env, IO [ConwayTx])
recordingEnv rig = answeringWith rig (const Nothing)

{- | The environment of the rig whose node answers the submissions the rule
names otherwise: the rule gives the number of the submission, counted from one,
and says whether the node applied it before it stopped answering.
-}
answeringWith
    :: Rig
    -> (Int -> Maybe Bool)
    -> IO (Env, IO [ConwayTx])
answeringWith rig rule = do
    sent <- newIORef []
    count <- newIORef (0 :: Int)
    let caps = capabilities rig
        watching =
            caps
                { capSubmit = \signed -> do
                    modifyIORef' sent (<> [signedTx signed])
                    modifyIORef' count (+ 1)
                    here <- readIORef count
                    case rule here of
                        Nothing -> capSubmit caps signed
                        Just applies -> do
                            when applies (void (capSubmit caps signed))
                            pure (Cage.SubmitFailed "the node did not answer")
                }
    pure
        ( (envOf rig){envWrites = \_ k -> k watching}
        , readIORef sent
        )

runState :: Rig -> Env -> FilePath -> String -> [String] -> IO Run
runState rig env dir label extra =
    runVia
        rig
        env
        dir
        label
        (["registry", "create"] <> policyArgs <> extra)

-- | Outputs of the wallet other than the one its funding takes.
spareSeeds :: Rig -> IO [TxIn]
spareSeeds rig = do
    held <- readWallet rig
    let funding = either (const Nothing) (Just . fst) (selectFunding Nothing held)
    pure [i | (i, _) <- held, Just i /= funding]

-- | The journal of the creations of the application by the rig's wallet.
creationJournal :: Rig -> FilePath -> StateScript -> IO [JournalEntry]
creationJournal rig dir script =
    readJournal
        ( managedDir
            (rigDir rig </> dir)
            42
            (statePolicy script, AssetName mempty)
            (walletPartition (rigWallet rig))
        )

-- | The registry a seed creates, as a state token.
tokenOfSeed :: StateScript -> TxIn -> (PolicyID, AssetName)
tokenOfSeed script seed = (statePolicy script, stateTokenName seed)

hexOf :: BS.ByteString -> Text
hexOf = TE.decodeUtf8 . B16.encode

spellToken :: (PolicyID, AssetName) -> Text
spellToken (PolicyID policy, AssetName name) =
    hexOf (scriptHashBytes policy) <> "." <> hexOf (SBS.fromShort name)

holdsToken :: (PolicyID, AssetName) -> TxOut ConwayEra -> Bool
holdsToken (policy, name) out =
    let MaryValue _ (MultiAsset assets) = out ^. valueTxOutL
    in  assets == Map.singleton policy (Map.singleton name 1)

{- | The capabilities of the rig whose node, asked who carries a script, also
names this output, which carries another script: a provider that lies.
-}
lyingAbout
    :: Rig
    -> ScriptHash
    -> (TxIn, TxOut ConwayEra)
    -> Capabilities NoWitness IO
lyingAbout rig hash extra =
    (capabilities rig)
        { capReads =
            (network, observeProvider unverifiedVerifier (\_ -> pure ()) lying)
        }
  where
    (network, provider) = rawChainProvider (rigChain rig)
    lying =
        provider
            { Cage.acquire = \requested action ->
                Cage.acquire provider requested $ \session ->
                    action
                        session
                            { Cage.outputs = \query -> do
                                answer <- Cage.outputs session query
                                pure $ case (query, answer) of
                                    (CarryingReferenceScript asked, Right (Evidenced found w))
                                        | asked == hash -> Right (Evidenced (extra : found) w)
                                    _ -> answer
                            }
            }

-- ---------------------------------------------------------
-- Creating a registry
-- ---------------------------------------------------------

creationRows :: Spec
creationRows = describe "creating a registry" $ do
    it
        "publishes the state script and creates the state from a seed of the wallet, in two transactions"
        $ withStateRig
        $ \rig -> do
            script <- stateScriptOf rig
            seed : _ <- spareSeeds rig
            (env, sent) <- recordingEnv rig
            r <-
                runState
                    rig
                    env
                    "alice"
                    "create"
                    ["--seed", T.unpack (renderOutRef seed)]
            runExit r `shouldBe` ExitSuccess
            outcomeOf (runReceipt r) `shouldBe` Just "success"
            textAt "command" (runReceipt r) `shouldBe` Just "registry create"
            let token = tokenOfSeed script seed
            textAt "stateToken" (runReceipt r) `shouldBe` Just (spellToken token)
            textAt "seed" (runReceipt r) `shouldBe` Just (renderOutRef seed)
            valueAt "registry" (runReceipt r)
                `shouldBe` lookup "registry" (registryFields 42 token)
            -- two transactions, the publication first, each named by the receipt
            let named = [(step, tx) | (step, tx, _, _) <- submissionsOf (runReceipt r)]
            map fst named `shouldBe` ["publish-scripts", "create"]
            transactions <- sent
            map txIdHex transactions `shouldBe` map snd named
            -- the state: one output at the script's address, the token alone, the empty root
            states <- outputsFor rig (HoldingAsset token)
            case states of
                [(ref, out)] -> do
                    out ^. addrTxOutL `shouldBe` stateAddress Testnet script
                    holdsToken token out `shouldBe` True
                    inlineDatumOf out `shouldBe` Just (stateDatum emptyRoot)
                    textAt "stateOutput" (runReceipt r) `shouldBe` Just (renderOutRef ref)
                _ ->
                    expectationFailure "the registry's state is not exactly one output"
            -- the seed is spent
            held <- readWallet rig
            map fst held `shouldNotContain` [seed]
            -- the script is a live reference script of the wallet, and the creation uses it
            copies <-
                outputsFor
                    rig
                    (CarryingReferenceScript (hashScript (ssScript script)))
            case (copies, transactions) of
                ([(copy, _)], [_, creation]) -> do
                    toList (creation ^. bodyTxL . referenceInputsTxBodyL)
                        `shouldContain` [copy]
                    toList (creation ^. bodyTxL . inputsTxBodyL) `shouldContain` [seed]
                    null (creation ^. witsTxL . scriptTxWitsL) `shouldBe` True
                _ -> expectationFailure "no single live copy, or not two transactions"
            -- the journal says each transaction was prepared, confirmed and observed
            entries <- creationJournal rig "alice" script
            [ (journalStep e, journalEvent e)
              | e <- entries
              , journalEvent e `elem` ["prepared", "confirmed", "observed"]
              ]
                `shouldBe` [ ("publish-scripts", "prepared")
                           , ("publish-scripts", "confirmed")
                           , ("publish-scripts", "observed")
                           , ("create", "prepared")
                           , ("create", "confirmed")
                           , ("create", "observed")
                           ]

    it "creates a later registry in one transaction, from the live copy" $
        withStateRig $ \rig -> do
            script <- stateScriptOf rig
            first : second : _ <- spareSeeds rig
            (env, sent) <- recordingEnv rig
            r1 <-
                runState
                    rig
                    env
                    "alice"
                    "first"
                    ["--seed", T.unpack (renderOutRef first)]
            outcomeOf (runReceipt r1) `shouldBe` Just "success"
            already <- length <$> sent
            r2 <-
                runState
                    rig
                    env
                    "alice"
                    "second"
                    ["--seed", T.unpack (renderOutRef second)]
            outcomeOf (runReceipt r2) `shouldBe` Just "success"
            transactions <- sent
            length transactions - already `shouldBe` 1
            [step | (step, _, _, _) <- submissionsOf (runReceipt r2)]
                `shouldBe` ["create"]
            textAt "stateToken" (runReceipt r2)
                `shouldBe` Just (spellToken (tokenOfSeed script second))
            textAt "stateToken" (runReceipt r2)
                `shouldNotBe` textAt "stateToken" (runReceipt r1)
            copies <-
                outputsFor
                    rig
                    (CarryingReferenceScript (hashScript (ssScript script)))
            case (copies, drop already transactions) of
                ([(copy, _)], [creation]) -> do
                    toList (creation ^. bodyTxL . referenceInputsTxBodyL)
                        `shouldContain` [copy]
                    null (creation ^. witsTxL . scriptTxWitsL) `shouldBe` True
                _ -> expectationFailure "not one live copy and one transaction"

    it
        "never reuses a reference output that carries another script, whatever the node says"
        $ withStateRig
        $ \rig -> do
            script <- stateScriptOf rig
            seed : _ <- spareSeeds rig
            impostorAt <-
                either fail pure (parseOutRef (T.pack (replicate 64 '7' <> "#0")))
            let impostor =
                    mkBasicTxOut
                        (walletAddr (rigWallet rig))
                        (inject (Coin 50_000_000))
                        & referenceScriptTxOutL
                            .~ SJust (scriptFromBytes "impostor" (unitProgram 5))
                liar =
                    lyingAbout rig (hashScript (ssScript script)) (impostorAt, impostor)
                lying = (envOf rig){envWrites = \_ k -> k liar, envReads = \_ k -> k liar}
            r <-
                runState
                    rig
                    lying
                    "alice"
                    "impostor"
                    ["--seed", T.unpack (renderOutRef seed)]
            outcomeOf (runReceipt r) `shouldBe` Just "success"
            [step | (step, _, _, _) <- submissionsOf (runReceipt r)]
                `shouldBe` ["publish-scripts", "create"]

    it
        "takes the largest output of the wallet for the seed when none is named"
        $ withStateRig
        $ \rig -> do
            script <- stateScriptOf rig
            (env, sent) <- recordingEnv rig
            r <- runState rig env "alice" "default seed" []
            outcomeOf (runReceipt r) `shouldBe` Just "success"
            named <-
                maybe
                    (fail "no seed in the receipt")
                    (either fail pure . parseOutRef)
                    (textAt "seed" (runReceipt r))
            textAt "stateToken" (runReceipt r)
                `shouldBe` Just (spellToken (tokenOfSeed script named))
            transactions <- sent
            case reverse transactions of
                creation : _ ->
                    toList (creation ^. bodyTxL . inputsTxBodyL) `shouldContain` [named]
                [] -> expectationFailure "nothing was submitted"
            states <- outputsFor rig (HoldingAsset (tokenOfSeed script named))
            length states `shouldBe` 1

    it
        "writes its whole run as one bundle for a signer elsewhere, and sends nothing"
        $ withStateRig
        $ \rig -> do
            script <- stateScriptOf rig
            seed : _ <- spareSeeds rig
            (env, sent) <- recordingEnv rig
            let bundlePath = rigDir rig </> "state-create.bundle"
            r <-
                runState
                    rig
                    env
                    "bob"
                    "external signer"
                    ( ["--seed", T.unpack (renderOutRef seed)]
                        <> externalArgs rig bundlePath
                    )
            runExit r `shouldBe` ExitFailure 19
            outcomeOf (runReceipt r) `shouldBe` Just "waiting-for-signatures"
            sent `shouldReturn` []
            doesFileExist bundlePath `shouldReturn` True
            bytes <- BS.readFile bundlePath
            case decodeBundle bytes of
                Right bundle -> do
                    bundleCommand bundle `shouldBe` "registry create"
                    length (bundleTransactions bundle) `shouldBe` 2
                Left refusal -> expectationFailure (show refusal)
            -- nothing of the registry is on the chain
            states <- outputsFor rig (HoldingAsset (tokenOfSeed script seed))
            states `shouldSatisfy` null

-- ---------------------------------------------------------
-- Interrupted commands
-- ---------------------------------------------------------

interruptionRows :: Spec
interruptionRows = describe "an interrupted creation" $ do
    it
        "keeps the transaction when the node's answer is lost after it took it, and the next command observes it once and sends nothing again"
        $ withStateRig
        $ \rig -> do
            script <- stateScriptOf rig
            first : second : _ <- spareSeeds rig
            -- the publication is submission one, the creation is submission two
            (env, sent) <-
                answeringWith rig (\n -> if n == 2 then Just True else Nothing)
            r <-
                runState
                    rig
                    env
                    "alice"
                    "lost answer"
                    ["--seed", T.unpack (renderOutRef first)]
            runExit r `shouldBe` ExitFailure 15
            outcomeOf (runReceipt r) `shouldBe` Just "partial"
            transactions <- sent
            length transactions `shouldBe` 2
            let lostTx = txIdHex (transactions !! 1)
            lookup
                "create"
                [(s, t) | (s, t, _, _) <- submissionsOf (runReceipt r)]
                `shouldBe` Just lostTx
            entries <- creationJournal rig "alice" script
            [ journalTxId e
              | e <- entries
              , journalStep e == "create"
              , journalEvent e == "prepared"
              ]
                `shouldBe` [lostTx]
            -- the next creation, of another registry, finds the chain holds it
            (env2, sent2) <- recordingEnv rig
            r2 <-
                runState
                    rig
                    env2
                    "alice"
                    "next"
                    ["--seed", T.unpack (renderOutRef second)]
            outcomeOf (runReceipt r2) `shouldBe` Just "success"
            later <- creationJournal rig "alice" script
            length
                [ e | e <- later, journalTxId e == lostTx, journalEvent e == "observed"
                ]
                `shouldBe` 1
            length
                [ e | e <- later, journalTxId e == lostTx, journalEvent e == "prepared"
                ]
                `shouldBe` 1
            submitted <- sent2
            map txIdHex submitted `shouldNotContain` [lostTx]
            length submitted `shouldBe` 1
            states <- outputsFor rig (HoldingAsset (tokenOfSeed script first))
            length states `shouldBe` 1

    it
        "keeps the transaction when the node never saw it, and the next command is refused naming it and sends nothing"
        $ withStateRig
        $ \rig -> do
            script <- stateScriptOf rig
            first : second : _ <- spareSeeds rig
            (env, sent) <-
                answeringWith rig (\n -> if n == 2 then Just False else Nothing)
            r <-
                runState
                    rig
                    env
                    "alice"
                    "never saw"
                    ["--seed", T.unpack (renderOutRef first)]
            outcomeOf (runReceipt r) `shouldBe` Just "partial"
            transactions <- sent
            let lostTx = txIdHex (transactions !! 1)
            (env2, sent2) <- recordingEnv rig
            r2 <-
                runState
                    rig
                    env2
                    "alice"
                    "refused"
                    ["--seed", T.unpack (renderOutRef second)]
            outcomeOf (runReceipt r2) `shouldBe` Just "partial"
            runExit r2 `shouldBe` ExitFailure 15
            fromMaybe "" (textAt "reason" (runReceipt r2))
                `shouldSatisfy` T.isInfixOf lostTx
            sent2 `shouldReturn` []
            entries <- creationJournal rig "alice" script
            [ journalTxId e
              | e <- entries
              , journalEvent e == "prepared"
              , journalStep e == "create"
              ]
                `shouldBe` [lostTx]
            states <- outputsFor rig (HoldingAsset (tokenOfSeed script first))
            states `shouldSatisfy` null

    it
        "keeps the transaction when the command is cancelled while it sends, and nothing is sent again"
        $ withStateRig
        $ \rig -> do
            script <- stateScriptOf rig
            first : second : _ <- spareSeeds rig
            reached <- newEmptyMVar
            count <- newIORef (0 :: Int)
            let caps = capabilities rig
                stalling =
                    caps
                        { capSubmit = \signed -> do
                            modifyIORef' count (+ 1)
                            here <- readIORef count
                            if here == 2
                                then do
                                    putMVar reached (signedTx signed)
                                    threadDelay maxBound
                                    capSubmit caps signed
                                else capSubmit caps signed
                        }
                env = (envOf rig){envWrites = \_ k -> k stalling}
            running <-
                async
                    ( runState
                        rig
                        env
                        "alice"
                        "cancelled"
                        ["--seed", T.unpack (renderOutRef first)]
                    )
            reachedOrEnded <- race (takeMVar reached) (waitCatch running)
            held <- case reachedOrEnded of
                Left signed -> pure signed
                Right ended ->
                    fail
                        ( "the command ended before it sent its creation: "
                            <> either show (const "with a receipt") ended
                        )
            cancel running
            _ <- waitCatch running
            let cancelledTx = txIdHex held
            entries <- creationJournal rig "alice" script
            [ journalTxId e
              | e <- entries
              , journalStep e == "create"
              , journalEvent e == "prepared"
              ]
                `shouldBe` [cancelledTx]
            (env2, sent2) <- recordingEnv rig
            r2 <-
                runState
                    rig
                    env2
                    "alice"
                    "after cancel"
                    ["--seed", T.unpack (renderOutRef second)]
            outcomeOf (runReceipt r2) `shouldBe` Just "partial"
            fromMaybe "" (textAt "reason" (runReceipt r2))
                `shouldSatisfy` T.isInfixOf cancelledTx
            sent2 `shouldReturn` []

-- | The address of a payment key, produced from its hash, never typed.
aWalletAddress :: String
aWalletAddress =
    bech32Address (addrFromKeyHashBytes Testnet (BS.replicate 28 0x5a))
