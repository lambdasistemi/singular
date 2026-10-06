{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- |
Module      : Singular.CLI.CommandRunSpec
Description : #416 — every command handler run in process, its typed events compared with its receipt
License     : Apache-2.0

Each command the command line can name is run through 'runCommand', the
same dispatch the packaged command runs, over an environment that serves a
chain fixture instead of Koios: the fixture applies every submitted
transaction to its own outputs, and the registry's scripts are accept-all
programs of the arities the builders apply, so the handlers build, sign,
submit and read back as they do on a network. The fixture is not a ledger:
nothing here claims a script or a ledger rule accepts these transactions.

Every receipt-bound fact a typed event carries must equal the receipt's: the
command and its outcome, the key, the edge and the request (in the receipt's
own fields and in every object it lists), each transaction's step and id
and what the journal says it met, the root, the token, the refusal's kind.
One contradicting event is a failure, whatever other events agree.

The commands run are the 'Command' constructors, read from the type, not
listed here; a constructor no run exercises fails the extent row.
-}
module Singular.CLI.CommandRunSpec (spec) where

import Control.Exception (bracket)
import Control.Monad (forM_)
import Control.Tracer (Tracer (..))
import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as BL
import Data.ByteString.Short qualified as SBS
import Data.Foldable (toList)
import Data.IORef
    ( IORef
    , modifyIORef'
    , newIORef
    , readIORef
    , writeIORef
    )
import Data.List (nub, sort)
import Data.Map.Strict qualified as Map
import Data.Proxy (Proxy (..))
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import GHC.Generics
    ( C1
    , Constructor
    , D1
    , Generic (..)
    , conName
    , (:+:)
    )
import Lens.Micro ((^.))
import System.Exit (ExitCode (..))
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

import Cardano.Ledger.Api.Tx (bodyTxL, txIdTx)
import Cardano.Ledger.Api.Tx.Body (inputsTxBodyL, outputsTxBodyL)
import Cardano.Ledger.Api.Tx.Out (mkBasicTxOut)
import Cardano.Ledger.BaseTypes (TxIx (..))
import Cardano.Ledger.Mary.Value (MaryValue (..))
import Cardano.Ledger.TxIn (TxIn (..))
import Cardano.Slotting.Slot (SlotNo (..))
import Data.Word (Word64)

import Singular.CLI (runCommand)
import Singular.CLI.Command (Command (..), parseCommand)
import Singular.CLI.Session (Env (..))
import Singular.CLI.Trace
import Singular.Registry.Capabilities (Capabilities (..))
import Singular.Registry.Deployment (parseOutRef, renderOutRef)
import Singular.Registry.Evidence (NoWitness, unverifiedVerifier)
import Singular.Registry.Ledger (Coin (..))
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
import Singular.Registry.Wallet (Wallet (..), loadWallet)

spec :: Spec
spec = describe
    "every command handler, run in process, against its receipt (#416)"
    $ do
        it
            "runs every command the command line names, and each stream agrees with its receipt"
            $ withRig
            $ \rig -> do
                runs <- lifecycle rig
                let ran = nub (sort [name | Run{runName = name} <- runs])
                ran `shouldBe` sort commandNames
                forM_ runs $ \r ->
                    ( runLabel r
                    , outcomeOf (runReceipt r)
                    , disagreements (runReceipt r) (runEvents r)
                    )
                        `shouldBe` (runLabel r, outcomeOf (runReceipt r), [])
        it "fails a stream that contradicts its receipt in any one fact" $
            withRig $ \rig -> do
                runs <- lifecycle rig
                -- the control is only a control over a stream that agrees
                [ runLabel r
                  | r <- runs
                  , not (null (disagreements (runReceipt r) (runEvents r)))
                  ]
                    `shouldBe` []
                let altered =
                        [ (runLabel r, what', disagreements (runReceipt r) events')
                        | r <- runs
                        , (what', events') <- alterations (runEvents r)
                        ]
                    kinds = nub [w | (_, w, _) <- altered]
                length altered `shouldSatisfy` (> 50)
                length kinds `shouldSatisfy` (>= 12)
                [(l, w) | (l, w, []) <- altered] `shouldBe` []

-- ---------------------------------------------------------
-- The commands, from the type
-- ---------------------------------------------------------

class ConNames f where
    conNames :: Proxy f -> [String]

instance (ConNames f) => ConNames (D1 c f) where
    conNames _ = conNames (Proxy :: Proxy f)

instance (ConNames f, ConNames g) => ConNames (f :+: g) where
    conNames _ = conNames (Proxy :: Proxy f) <> conNames (Proxy :: Proxy g)

instance (Constructor c) => ConNames (C1 c f) where
    conNames _ = [conName (undefined :: C1 c f p)]

-- | Every command the command line can name, by constructor; help runs nothing.
commandNames :: [String]
commandNames =
    sort [n | n <- conNames (Proxy :: Proxy (Rep Command)), n /= "Help"]

-- | The constructor a parsed command is.
constructorOf :: Command -> String
constructorOf = \case
    Help -> "Help"
    Create _ -> "Create"
    Insert _ -> "Insert"
    Update _ -> "Update"
    Terminate _ -> "Terminate"
    Fold _ -> "Fold"
    Reject _ -> "Reject"
    Reclaim _ -> "Reclaim"
    Inspect _ -> "Inspect"

-- ---------------------------------------------------------
-- The rig
-- ---------------------------------------------------------

data Rig = Rig
    { rigDir :: FilePath
    , rigChain :: RawChain
    , rigWallet :: Wallet
    , rigKey :: FilePath
    , rigBlueprint :: FilePath
    , rigEvents :: IORef [Trace]
    , rigAnswer :: IORef (Maybe Cage.SubmitResult)
    -- ^ When set, what the provider answers the next submission instead of taking it
    }

-- | One command run: its constructor, a label, its exit, its receipt and its events.
data Run = Run
    { runName :: String
    , runLabel :: String
    , runExit :: ExitCode
    , runReceipt :: Aeson.Value
    , runEvents :: [Trace]
    }

magic :: Integer
magic = 42

withRig :: (Rig -> IO a) -> IO a
withRig use = withSystemTempDirectory "command-run" $ \dir -> do
    let keyPath = dir </> "payment.skey"
        blueprint = dir </> "plutus.json"
    BS.writeFile keyPath (B16.encode (BC.replicate 32 'w'))
    BL.writeFile blueprint (Aeson.encode syntheticBlueprint)
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
    use (Rig dir chain wallet keyPath blueprint events answer)

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
syntheticBlueprint =
    Aeson.object
        [ "preamble"
            .= Aeson.object
                ["title" .= ("synthetic" :: Text), "plutusVersion" .= ("v3" :: Text)]
        , "validators"
            .= [ validator "state.state" 1
               , validator "request.request" 3
               , validator "open_datum.open_datum" 2
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

-- | The environment of a run over the rig: the fixture's capabilities.
envOf :: Rig -> Env
envOf rig =
    Env
        { envTracer = Tracer (\t -> modifyIORef' (rigEvents rig) (<> [t]))
        , envSource = "fixture"
        , envReads = \_ k -> k (capabilities rig)
        , envWrites = \_ _ k -> k (capabilities rig)
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

-- ---------------------------------------------------------
-- The lifecycle
-- ---------------------------------------------------------

{- | Run the commands in the order a registry's life takes them, each over the
state the previous left, whatever outcome each reaches.
-}
lifecycle :: Rig -> IO [Run]
lifecycle rig = do
    seed <- fundSeed rig
    create <- run rig "create" ["registry", "create", "--seed", seed]
    insert <-
        run
            rig
            "insert alice-1"
            ["registry", "insert", "--key", "alice-1", "--payload", payload]
    fold1 <-
        run rig "fold alice-1" (["registry", "fold"] <> requestOf insert)
    inspect <-
        run rig "inspect alice-1" ["registry", "inspect", "--key", "alice-1"]
    update <-
        run
            rig
            "update alice-1"
            ["registry", "update", "--key", "alice-1", "--payload", payload2]
    terminate <-
        run
            rig
            "terminate alice-1"
            ["registry", "terminate", "--key", "alice-1"]
    fold2 <-
        run
            rig
            "fold alice-1 terminal"
            (["registry", "fold"] <> requestOf terminate)
    insert2 <-
        run
            rig
            "insert alice-2"
            ["registry", "insert", "--key", "alice-2", "--payload", payload]
    -- the chain moves past the processing deadline: the retract window opens
    jumpPast rig insert2 0
    reclaim <-
        run
            rig
            "reclaim alice-2"
            (["registry", "reclaim"] <> requestOrAny insert2)
    -- a second registry whose windows close at once: its request can only be rejected
    seed2 <- fundSeed2 rig
    create2 <-
        runAt
            rig
            "registry-2"
            "create short windows"
            [ "registry"
            , "create"
            , "--seed"
            , seed2
            , "--process-time"
            , "1"
            , "--retract-time"
            , "1"
            ]
    insert3 <-
        runAt
            rig
            "registry-2"
            "insert alice-3"
            ["registry", "insert", "--key", "alice-3", "--payload", payload]
    jumpPast rig insert3 2
    reject <- runAt rig "registry-2" "reject" ["registry", "reject"]
    -- refusals, each where it happens
    nothingPending <-
        runAt
            rig
            "registry-2"
            "fold with nothing pending"
            ["registry", "fold"]
    overAllowance <-
        run
            rig
            "insert over its allowance"
            [ "registry"
            , "insert"
            , "--key"
            , "alice-4"
            , "--payload"
            , payload
            , "--max-outlay"
            , "1"
            ]
    absent <-
        run
            rig
            "update an absent key"
            ["registry", "update", "--key", "nobody", "--payload", payload2]
    writeIORef
        (rigAnswer rig)
        (Just (Cage.SubmitRefused "the ledger said no"))
    rejected <-
        run
            rig
            "insert the ledger rejects"
            ["registry", "insert", "--key", "alice-5", "--payload", payload]
    writeIORef
        (rigAnswer rig)
        (Just (Cage.SubmitFailed "connection refused"))
    unanswered <-
        run
            rig
            "insert the provider drops"
            ["registry", "insert", "--key", "alice-6", "--payload", payload]
    pure
        [ create
        , insert
        , fold1
        , inspect
        , update
        , terminate
        , fold2
        , insert2
        , reclaim
        , create2
        , insert3
        , reject
        , nothingPending
        , overAllowance
        , absent
        , rejected
        , unanswered
        ]
  where
    payload = rigDir rig </> "payload.json"
    payload2 = rigDir rig </> "payload-2.json"
    requestOf r =
        maybe
            []
            (\q -> ["--request", T.unpack q])
            (textAt "request" (runReceipt r))
    requestOrAny r =
        [ "--request"
        , maybe
            (replicate 64 '0' <> "#0")
            T.unpack
            (textAt "request" (runReceipt r))
        ]

{- | Move the chain's tip past a booking's processing deadline, by this many
slots more, as its receipt names the deadline.
-}
jumpPast :: Rig -> Run -> Word64 -> IO ()
jumpPast rig booking more = case deadlineSlot (runReceipt booking) of
    Just slot -> jumpChainTo (rigChain rig) (SlotNo (slot + more + 1))
    Nothing ->
        fail
            ( "no deadline slot in "
                <> runLabel booking
                <> ": "
                <> show (runReceipt booking)
            )
  where
    -- the fixture's slots are seconds since 1970, so a deadline the view did not
    -- convert still names its slot
    deadlineSlot = \case
        Aeson.Object o
            | Just (Aeson.Object d) <- KeyMap.lookup "foldDeadline" o
            , Just (Aeson.Number n) <- KeyMap.lookup "posixMs" d ->
                Just (round n `div` 1000)
        _ -> Nothing

-- | A wallet output the create can consume as its seed.
fundSeed :: Rig -> IO String
fundSeed _ = pure (T.unpack (renderOutRef (fundOutput 1)))

-- | A wallet output still unspent, for the second registry.
fundSeed2 :: Rig -> IO String
fundSeed2 rig = do
    held <-
        SessionIO.withLatest (rawChainProvider (rigChain rig)) $ \s ->
            SessionIO.outputsAt s (walletAddr (rigWallet rig))
    case reverse (map fst held) of
        i : _ -> pure (T.unpack (renderOutRef i))
        [] -> fail "the wallet holds nothing for a second registry"

-- | One command line, parsed as the packaged command parses it and run in process.
run :: Rig -> String -> [String] -> IO Run
run rig = runAt rig "registry"

-- | The same, against the registry in this directory of the rig.
runAt :: Rig -> FilePath -> String -> [String] -> IO Run
runAt rig registry label args = do
    writeIORef (rigEvents rig) []
    let full =
            args
                <> [ "--registry"
                   , rigDir rig </> registry
                   , "--blueprint"
                   , rigBlueprint rig
                   , "--koios-url"
                   , "http://fixture.invalid"
                   , "--network-magic"
                   , show magic
                   ]
                <> ["--wallet-skey" | wantsKey]
                <> [rigKey rig | wantsKey]
        wantsKey = take 2 args /= ["registry", "inspect"]
    command <- either (fail . show) pure (parseCommand full)
    (code, out, _) <- captured (runCommand (envOf rig) command)
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
            }

-- ---------------------------------------------------------
-- The comparison
-- ---------------------------------------------------------

-- | The receipt's outcome.
outcomeOf :: Aeson.Value -> Maybe Text
outcomeOf = textAt "outcome"

textAt :: Aeson.Key -> Aeson.Value -> Maybe Text
textAt k = \case
    Aeson.Object o | Just (Aeson.String t) <- KeyMap.lookup k o -> Just t
    _ -> Nothing

-- | Every object in a value, itself included.
objectsIn :: Aeson.Value -> [Aeson.Object]
objectsIn = \case
    Aeson.Object o -> o : concatMap objectsIn (KeyMap.elems o)
    Aeson.Array xs -> concatMap objectsIn (toList xs)
    _ -> []

-- | The receipt's request facts: each object naming a request, with the key and edge it names.
requestFacts :: Aeson.Value -> [(Text, Maybe Text, Maybe Text)]
requestFacts receipt =
    [ (r, field "key" o, field "edge" o)
    | o <- objectsIn receipt
    , Just r <- [field "request" o]
    ]
        <> [ (r, Nothing, Nothing)
           | o <- objectsIn receipt
           , Just r <- [field "pendingRequest" o]
           ]
  where
    field k o = case KeyMap.lookup k o of
        Just (Aeson.String t) -> Just t
        _ -> Nothing

-- | The receipt's submissions: step, transaction id, case and whether observed.
submissionsOf :: Aeson.Value -> [(Text, Text, Maybe Text, Bool)]
submissionsOf = \case
    Aeson.Object o
        | Just (Aeson.Array xs) <- KeyMap.lookup "submissions" o ->
            [ (s, t, c, observed)
            | Aeson.Object x <- toList xs
            , Just (Aeson.String s) <- [KeyMap.lookup "step" x]
            , Just (Aeson.String t) <- [KeyMap.lookup "tx" x]
            , let c = case KeyMap.lookup "case" x of
                    Just (Aeson.String v) -> Just v
                    _ -> Nothing
                  observed = KeyMap.lookup "observed" x == Just (Aeson.Bool True)
            ]
    _ -> []

{- | Every way the typed events contradict the receipt; empty when every event
that carries a receipt-bound fact agrees with it.
-}
disagreements :: Aeson.Value -> [Trace] -> [String]
disagreements receipt events =
    concat
        [ ends
        , ["key " <> show k | k <- eventKeys, Just k /= receiptKey]
        , [ "request " <> show r <> " not named by the receipt"
          | r <- eventRequests
          , r `notElem` [q | (q, _, _) <- facts]
          ]
        , [ "request " <> show r <> " " <> what' <> " " <> show v
          | Trace _ (What (RequestSeen r e k _ _)) <- events
          , (q, fk, fe) <- facts
          , q == r
          , (what', v, fv) <- [("key", hexText k, fk), ("edge", e, fe)]
          , Just w <- [fv]
          , w /= v
          ]
        , ["edge " <> show e | e <- eventEdges, Just e /= receiptEdge]
        , [ "transaction "
                <> show (s, t)
                <> " not among the receipt's submissions"
          | (s, t) <- eventTxs
          , (s, t) `notElem` [(s', t') | (s', t', _, _) <- subs]
          ]
        , [ "submission " <> show (s, t) <> " has no signing and submission event"
          | (s, t, _, _) <- subs
          , not (any (signed s t) events) || not (any (submitted s t) events)
          ]
        , [ "submission "
                <> show t
                <> " observed "
                <> show o
                <> " against its events"
          | (s, t, _, o) <- subs
          , o /= any (observedEvent s t) events
          ]
        , [ "submission "
                <> show t
                <> " met "
                <> show c
                <> " but its events say "
                <> show v
          | (_, t, c, _) <- subs
          , v <- verdictsOf t
          , not (consistent v c)
          ]
        , [ "root " <> show a
          | Trace _ (What (RootSeen _ a)) <- events
          , Just a /= textAt "root" receipt
          ]
        , [ "token " <> show tok
          | Trace _ (What (Created tok _)) <- events
          , Just tok /= textAt "token" receipt
          ]
        , [ "refusal " <> show k <> " under outcome " <> show outcome
          | Trace _ (What (Refused k _)) <- events
          , not (refusalFits k outcome)
          ]
        , [ "ledger refusal with no ledger rejection event"
          | outcome == Just "ledger-refusal"
          , null [() | Trace _ (What (Refused LedgerRejected _)) <- events]
          ]
        ]
  where
    outcome = textAt "outcome" receipt
    receiptKey = textAt "key" receipt
    receiptEdge = textAt "edge" receipt
    facts = requestFacts receipt
    subs = submissionsOf receipt
    ends = case [(c, o) | Trace [] (What (CommandEnded c o _)) <- events] of
        [(c, o)]
            | Just c == textAt "command" receipt
            , Just o == outcome
            , isEnd (lastMaybe events) ->
                []
        found ->
            [ "the stream's end "
                <> show found
                <> " against the receipt's command and outcome"
            ]
    isEnd = \case
        Just (Trace [] (What (CommandEnded{}))) -> True
        _ -> False
    lastMaybe xs = if null xs then Nothing else Just (last xs)
    eventKeys =
        [hexText k | Trace _ (What (KeySeen k _ _)) <- events]
            <> [hexText k | Trace _ (What (Folded _ k _)) <- events]
            <> [hexText k | Trace _ (What (Updated k _)) <- events]
            <> [hexText k | Trace scope _ <- events, InKey k <- scope]
    eventRequests =
        [r | Trace _ (What (RequestSeen r _ _ _ _)) <- events]
            <> [r | Trace _ (What (Booked r _)) <- events]
            <> [r | Trace _ (What (Reclaimed r _)) <- events]
            <> concat [rs | Trace _ (What (Rejected rs)) <- events]
            <> [r | Trace scope _ <- events, InRequest r <- scope]
    eventEdges = [e | Trace _ (What (Folded e _ _)) <- events]
    eventTxs =
        [ (s, t)
        | Trace _ (How (Tx e)) <- events
        , Just (s, t) <- [txOf e]
        ]
    txOf = \case
        TxBuilt{} -> Nothing
        TxSigned s t _ _ _ -> Just (s, t)
        TxSubmitted{submitStep = s, submitTx = t} -> Just (s, t)
        TxConfirmed s t _ _ -> Just (s, t)
        TxObserved s t _ -> Just (s, t)
    signed s t = \case
        Trace _ (How (Tx (TxSigned s' t' _ _ _))) -> (s', t') == (s, t)
        _ -> False
    submitted s t = \case
        Trace _ (How (Tx TxSubmitted{submitStep = s', submitTx = t'})) -> (s', t') == (s, t)
        _ -> False
    observedEvent s t = \case
        Trace _ (How (Tx (TxObserved s' t' _))) -> (s', t') == (s, t)
        _ -> False
    verdictsOf t =
        [ Left v
        | Trace _ (How (Tx TxSubmitted{submitTx = t', submitVerdict = v})) <-
            events
        , t' == t
        ]
            <> [ Right v | Trace _ (How (Tx (TxConfirmed _ t' _ v))) <- events, t' == t
               ]
    consistent v c = case (v, c) of
        (Left Accepted, Just x) ->
            x
                `elem` ["acknowledged", "timeout", "included", "rolled-back", "excluded"]
        (Left LedgerRefusedIt, Just x) -> x == "rejected"
        (Left WrongNetwork, Just x) -> x == "rejected"
        (Left ProviderFailed, Just x) -> x == "unknown"
        (Left (SubmitThrew _), Just x) -> x == "unknown"
        (Right Confirmed, Just x) -> x `elem` ["included", "rolled-back", "excluded"]
        (Right ConfirmTimedOut, Just x) -> x == "timeout"
        (Right ConfirmFailed, Just x) -> x == "timeout"
        (_, Nothing) -> False
    refusalFits k o = case k of
        LedgerRejected -> o == Just "ledger-refusal"
        TransportFailed -> o `elem` map Just ["partial", "node-unavailable", "timeout"]
        ClientRefused ->
            o
                `elem` map
                    Just
                    ["client-refusal", "partial", "concurrent-writer", "stale-state"]
        EvaluationRefused -> o `elem` map Just ["client-refusal", "partial"]

hexText :: BS.ByteString -> Text
hexText = TE.decodeUtf8 . B16.encode

{- | One contradiction planted per fact a stream carries: each altered stream
must disagree with the unaltered receipt. Every event is altered in each
fact it carries, its scopes included; an observation is also removed.
-}
alterations :: [Trace] -> [(String, [Trace])]
alterations events =
    [ ( label
      , [if i == n then e' else x | (i, x) <- zip [0 :: Int ..] events]
      )
    | (n, e) <- zip [0 ..] events
    , (label, e') <- alter e <> scoped e
    ]
        <> [ ( "observation removed"
             , [x | (i, x) <- zip [0 :: Int ..] events, i /= n]
             )
           | (n, Trace _ (How (Tx TxObserved{}))) <- zip [0 ..] events
           ]
  where
    flipText t = if T.take 1 t == "0" then "1" <> T.drop 1 t else "0" <> T.drop 1 t
    flipBytes b = "x" <> b
    scoped (Trace scope event) =
        [ (label, Trace (outer <> [s'] <> inner) event)
        | (k, s) <- zip [0 :: Int ..] scope
        , let (outer, rest) = splitAt k scope
              inner = drop 1 rest
        , (label, s') <- case s of
            InKey key -> [("scope key", InKey (flipBytes key))]
            InRequest r -> [("scope request", InRequest (flipText r))]
            _ -> []
        ]
    alter (Trace scope event) = case event of
        What (CommandEnded c o ms) ->
            [ ("outcome", Trace scope (What (CommandEnded c (o <> "-altered") ms)))
            , ("command", Trace scope (What (CommandEnded (c <> "-altered") o ms)))
            ]
        What (KeySeen k l h) -> [("key", Trace scope (What (KeySeen (flipBytes k) l h)))]
        What (RequestSeen r e k d s) ->
            [ ("request", Trace scope (What (RequestSeen (flipText r) e k d s)))
            ,
                ( "request key"
                , Trace scope (What (RequestSeen r e (flipBytes k) d s))
                )
            , ("request edge", Trace scope (What (RequestSeen r (e <> "x") k d s)))
            ]
        What (Booked r d) -> [("booked request", Trace scope (What (Booked (flipText r) d)))]
        What (Folded e k o) ->
            [ ("fold edge", Trace scope (What (Folded (e <> "x") k o)))
            , ("fold key", Trace scope (What (Folded e (flipBytes k) o)))
            ]
        What (Updated k o) -> [("update key", Trace scope (What (Updated (flipBytes k) o)))]
        What (Rejected rs) ->
            [ ("rejected request", Trace scope (What (Rejected (map flipText rs))))
            ]
        What (Reclaimed r v) ->
            [("reclaimed request", Trace scope (What (Reclaimed (flipText r) v)))]
        What (Created t s) -> [("token", Trace scope (What (Created (flipText t) s)))]
        What (RootSeen b a) -> [("root", Trace scope (What (RootSeen b (flipText a))))]
        What (Refused k c) ->
            [ ("refusal kind", Trace scope (What (Refused k' c)))
            | k' <- [minBound .. maxBound]
            , k' /= k
            ]
        How (Tx (TxSigned s t f ms end)) ->
            [
                ( "signed id"
                , Trace scope (How (Tx (TxSigned s (flipText t) f ms end)))
                )
            ]
        How (Tx x@TxSubmitted{}) ->
            [ ("submitted verdict", Trace scope (How (Tx x{submitVerdict = v})))
            | v <- [Accepted, LedgerRefusedIt, ProviderFailed]
            , v /= submitVerdict x
            ]
        How (Tx (TxConfirmed s t ms v)) ->
            [ ("confirmed verdict", Trace scope (How (Tx (TxConfirmed s t ms v'))))
            | v' <- [Confirmed, ConfirmTimedOut]
            , v' /= v
            ]
        How (Tx (TxObserved s t ms)) ->
            [ ("observed step", Trace scope (How (Tx (TxObserved (s <> "x") t ms))))
            ]
        _ -> []

-- Standard streams
-- ---------------------------------------------------------

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
