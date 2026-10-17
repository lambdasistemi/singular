{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.Registry.ChainedViewSpec
Description : #641 slice 1 — the chained view answers every read as landed
License     : Apache-2.0

A run that stages its whole chain before anything is signed or sent must
build each later transaction against a chain that already holds the
earlier ones. The chained view supplies that: one snapshot of the staged
list per acquisition, every output query, the asset history and the mint
record answered as if the staged transactions had landed, and every other
read the chain's own.

Every expected answer here comes from the synthetic chain fixture after
the same transactions are recorded and applied through its own path, the
way the command-run rows apply a submission — never from the module under
test. The staged transactions are built with the real builders over the
view itself: a preparation, the boot publication that mints the registry's
state token, and a fold for the history and selection rows. Each row has
an accepted answer and a planted defect — a view over the wrong staged
list — that the same assertion function rejects by its return status.
-}
module Singular.Registry.ChainedViewSpec (spec) where

import Cardano.Ledger.Address (Addr, serialiseAddr)
import Cardano.Ledger.Api.PParams (ppMaxTxSizeL)
import Cardano.Ledger.Api.Tx (bodyTxL, txIdTx)
import Cardano.Ledger.Api.Tx.Body
    ( inputsTxBodyL
    , outputsTxBodyL
    , referenceInputsTxBodyL
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
    , StrictMaybe (SJust)
    , TxIx (..)
    )
import Cardano.Ledger.Binary (serialize)
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Core (eraProtVerHigh)
import Cardano.Ledger.Mary.Value (MaryValue (..), MultiAsset (..))
import Cardano.Ledger.TxIn (TxIn (..))
import Cardano.Tx.Ledger (ConwayTx)
import Control.Monad (forM_)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BL
import Data.ByteString.Short qualified as SBS
import Data.Either (isLeft)
import Data.Foldable (toList)
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Lens.Micro ((&), (.~), (^.))
import MPF.Backend.Pure (emptyMPFInMemoryDB)
import Test.Hspec

import Singular.Registry.AssetName (deriveAssetName)
import Singular.Registry.ChainedView
import Singular.Registry.Config (CageConfig (..))
import Singular.Registry.Deployment (parseOutRef)
import Singular.Registry.Evidence
    ( Evidenced (..)
    , NoWitness
    , SessionId (..)
    )
import Singular.Registry.Ledger
    ( AssetName (..)
    , Root (..)
    , SlotNo (..)
    , TokenId (..)
    )
import Singular.Registry.LedgerProvider
import Singular.Registry.NetworkTime
    ( networkMagic
    , networkProtocolMajor
    )
import Singular.Registry.RawChainFixture
    ( ChainFacts (..)
    , RawChain
    , advanceChain
    , newRawChain
    , rawChainProvider
    , recordTransaction
    )
import Singular.Registry.SessionIO (outputsAt, parameters, withLatest)
import Singular.Registry.StubSession
    ( stubSession
    , withAddressOutputs
    , withTip
    )
import Singular.Registry.SyntheticLedger
    ( unitProgram
    , withSyntheticCosts
    )
import Singular.Registry.SyntheticTime (syntheticTime)
import Singular.Registry.TrieState
    ( CompleteFromCreate (..)
    , CreateRecord (..)
    , Leaf
    , PublicLineage
    , RegistryIdentity (..)
    , SessionBinding (Unbound)
    , StatePoint (..)
    , StatePolicyId (..)
    , TrieFailure
    , TrieSelection (..)
    , TrieSnapshot
    , leafAt
    , trieCoverage
    , trieLineage
    , trieRoot
    , withTrieState
    )
import Singular.Registry.TrieState.Fixture
    ( fixtureSnapshot
    , fixtureStore
    )
import Singular.Registry.TrieState.Lineage (lineageTrieState)
import Singular.Registry.TxBuilder.BookingFixture qualified as Fixture
import Singular.Registry.TxBuilder.Boot (bootTokenFrom)
import Singular.Registry.TxBuilder.Internal.Identity
    ( addrFromKeyHashBytes
    , cageAddrFromCfg
    , cagePolicyIdFromCfg
    , computeScriptHash
    , emptyRoot
    , extractCageDatum
    , mkCageScript
    , mkInlineDatum
    , mkRequestDatumWith
    , requestAddrFromCfg
    , scriptHashBytes
    , txInToRef
    )
import Singular.Registry.TxBuilder.Prepare
    ( Preparation (..)
    , planPreparation
    )
import Singular.Registry.TxBuilder.Update
    ( RegistryContext (..)
    , emptyRegistryContext
    , updateTokenSelected
    )
import Singular.Registry.Types
    ( CageDatum (..)
    , OnChainRoot (..)
    , stateRoot
    )

-- ---------------------------------------------------------
-- One registry, one payer, the fixture's chain
-- ---------------------------------------------------------

cfg :: CageConfig
cfg =
    Fixture.cfg
        { cageScriptBytes = unitProgram 1
        , cfgScriptHash = computeScriptHash (unitProgram 1)
        , requestScriptBytes = unitProgram 3
        }

payer :: Addr
payer = Fixture.payer

{- | The token the boot actually mints: its name derived from the seed
reference, as the state-token reader resolves it from the chain.
-}
stateTokenId :: TokenId
stateTokenId =
    TokenId
        ( AssetName
            (SBS.toShort (deriveAssetName (txInToRef seedIn)))
        )

tokenId :: TokenId
tokenId = stateTokenId

assetNameOf :: TokenId -> AssetName
assetNameOf (TokenId name) = name

stateAsset :: Asset
stateAsset = (cagePolicyIdFromCfg cfg, assetNameOf tokenId)

otherAsset :: Asset
otherAsset = (cagePolicyIdFromCfg cfg, AssetName "an-asset-nothing-mints")

registryIdentity :: RegistryIdentity
registryIdentity =
    RegistryIdentity
        (StatePolicyId (scriptHashBytes (cfgScriptHash cfg)))
        (assetNameOf tokenId)

txInOf :: Char -> Int -> TxIn
txInOf c i =
    either
        (error . ("ChainedViewSpec fixture: " <>))
        id
        (parseOutRef (T.pack (replicate 64 c <> "#" <> show i)))

seedIn, publicationIn, fundA, fundB :: TxIn
seedIn = txInOf '1' 0
publicationIn = txInOf '2' 0
fundA = txInOf '3' 0
fundB = txInOf '3' 1

requestIn :: TxIn
requestIn = txInOf '4' 0

key :: ByteString
key = "chained-view-key"

stateAddress :: Addr
stateAddress = cageAddrFromCfg cfg Testnet

publicationOutput :: TxOut ConwayEra
publicationOutput =
    mkBasicTxOut payer (MaryValue (Coin 3_000_000) mempty)
        & referenceScriptTxOutL
            .~ SJust (mkCageScript cfg)

{- | The payer's wallet: the boot seed, the state-script publication, and
two ada outputs the preparation spends.
-}
baseWallet :: Outputs
baseWallet =
    [ (seedIn, mkBasicTxOut payer (MaryValue (Coin 1_000_000) mempty))
    , (publicationIn, publicationOutput)
    , (fundA, mkBasicTxOut payer (MaryValue (Coin 4_000_000) mempty))
    , (fundB, mkBasicTxOut payer (MaryValue (Coin 4_000_000) mempty))
    ]

chainFacts :: ChainFacts
chainFacts =
    ChainFacts
        { csNetwork = 42
        , csTip = Nothing
        , csPParams = withSyntheticCosts Fixture.preprodParams
        , csUTxO = Map.fromList baseWallet
        , csRegistered = Set.empty
        , csNetworkTime = syntheticTime
        }

newChain :: IO RawChain
newChain = do
    chain <- newRawChain chainFacts
    advanceChain chain id
    pure chain

{- | Record and apply a transaction the way the command-run rows apply a
submission: one history block, the spent outputs gone, the created ones
live.
-}
applyToChain :: RawChain -> ConwayTx -> IO ()
applyToChain chain tx = do
    let txid = txIdTx tx
        spent = Set.toList (tx ^. bodyTxL . inputsTxBodyL)
        made =
            zipWith
                (\ix out -> (TxIn txid (TxIx ix), out))
                [0 ..]
                (toList (tx ^. bodyTxL . outputsTxBodyL))
    recordTransaction chain tx
    advanceChain chain $ \facts ->
        facts
            { csUTxO =
                Map.union
                    (Map.fromList made)
                    (foldr Map.delete (csUTxO facts) spent)
            }

applyStaged :: RawChain -> [StagedTransaction] -> IO ()
applyStaged chain = mapM_ (applyToChain chain . stagedBody)

{- | Stage a body as the run will: its spent and reference inputs resolved
over the view it was built against, one exact-reference read.
-}
stageOver :: Session NoWitness IO -> ConwayTx -> IO StagedTransaction
stageOver view tx = do
    let spent = tx ^. bodyTxL . inputsTxBodyL
        referenced = tx ^. bodyTxL . referenceInputsTxBodyL
        wanted = Set.toAscList (Set.union spent referenced)
    answer <- outputs view (AnyOf (fmap AtTxIn (nonEmptyOf wanted)))
    resolved <- case answer of
        Left failure ->
            error
                ("ChainedViewSpec: staging cannot resolve inputs: " <> show failure)
        Right evidenced -> pure (value evidenced)
    pure
        StagedTransaction
            { stagedBody = tx
            , stagedSpentOutputs = [(i, o) | (i, o) <- resolved, Set.member i spent]
            , stagedReferenceOutputs =
                [(i, o) | (i, o) <- resolved, Set.member i referenced]
            }
  where
    nonEmptyOf (x : xs) = x :| xs
    nonEmptyOf [] = error "ChainedViewSpec: a staged body reads no input"

holdsStateAsset :: TxOut ConwayEra -> Bool
holdsStateAsset out = case out ^. valueTxOutL of
    MaryValue _ (MultiAsset assets) ->
        maybe
            False
            ((> 0) . Map.findWithDefault 0 (assetNameOf tokenId))
            (Map.lookup (cagePolicyIdFromCfg cfg) assets)

{- | Where a transaction's own state output landed: the one output at the
state address that holds the token.
-}
stateRefOf :: ConwayTx -> TxIn
stateRefOf tx =
    case [ TxIn (txIdTx tx) (TxIx (fromIntegral ix))
         | (ix, out) <-
            zip [0 :: Int ..] (toList (tx ^. bodyTxL . outputsTxBodyL))
         , out ^. addrTxOutL == stateAddress
         , holdsStateAsset out
         ] of
        [single] -> single
        many ->
            error
                ( "ChainedViewSpec: a publication made "
                    <> show (length many)
                    <> " state outputs"
                )

-- ---------------------------------------------------------
-- Reads of the fixture, through its own sessions
-- ---------------------------------------------------------

valueOf :: Either ReadFailure (Evidenced w a) -> Either ReadFailure a
valueOf = fmap value

fixtureAnswers
    :: RawChain -> [OutputQuery] -> IO [Either ReadFailure Outputs]
fixtureAnswers chain queries =
    withLatest (rawChainProvider chain) $ \session ->
        traverse (fmap valueOf . outputs session) queries

fixtureMints
    :: RawChain -> [Asset] -> IO [Either ReadFailure (Maybe MintRecord)]
fixtureMints chain assets =
    withLatest (rawChainProvider chain) $ \session ->
        traverse (fmap valueOf . mintRecord session) assets

drainStream :: HistoryStream IO -> IO [HistoryBlock]
drainStream stream =
    nextBlock stream >>= \case
        Left failure ->
            error ("ChainedViewSpec: a history stream refused: " <> show failure)
        Right Nothing -> pure []
        Right (Just (block, rest)) -> (block :) <$> drainStream rest

fixtureHistory :: RawChain -> Asset -> IO [HistoryBlock]
fixtureHistory chain asset =
    withLatest (rawChainProvider chain) $ \session -> do
        supplied <- history session asset (HistoryRange Nothing Nothing)
        stream <- case supplied of
            Left failure -> error ("ChainedViewSpec: no history: " <> show failure)
            Right ok -> pure ok
        drainStream stream

chainedHistoryOf
    :: Session NoWitness IO
    -> [StagedTransaction]
    -> Asset
    -> IO [HistoryBlock]
chainedHistoryOf base staged asset = do
    view <- chainedSession (pure staged) base
    supplied <- history view asset (HistoryRange Nothing Nothing)
    stream <- case supplied of
        Left failure -> error ("ChainedViewSpec: no chained history: " <> show failure)
        Right ok -> pure ok
    drainStream stream

-- ---------------------------------------------------------
-- The assertion functions, each rejecting by its return status
-- ---------------------------------------------------------

{- | The complete answers the consumer receives: every ledger output of
every answer in full, not a projection of references — a wrong output
behind a right reference is a failure. The diagnostic keeps references
only because a complete output has no readable rendering here.
-}
answersAsLanded
    :: [(String, Either ReadFailure Outputs)]
    -> [(String, Either ReadFailure Outputs)]
    -> Either Text ()
answersAsLanded actual expected
    | actual == expected = Right ()
    | otherwise =
        Left
            ( "the chained answers are not the landed chain's: "
                <> T.pack (show (projected actual))
                <> " against "
                <> T.pack (show (projected expected))
            )
  where
    projected rows =
        [ (name, fmap (map fst) answer)
        | (name, answer) <- rows
        ]

mintsAsLanded
    :: [(String, Either ReadFailure (Maybe MintRecord))]
    -> [(String, Either ReadFailure (Maybe MintRecord))]
    -> Either Text ()
mintsAsLanded actual expected
    | actual == expected = Right ()
    | otherwise =
        Left
            ( "the chained mint records are not the landed chain's: "
                <> T.pack (show actual)
                <> " against "
                <> T.pack (show expected)
            )

{- | The complete replay material of two histories is the same: every
transaction of every block, its identity, its bytes, its own body, every
spent, reference and created output in full, and its validity — empty
bytes or a wrong value behind a right reference is a failure. The
heights need only ascend past each stream's own last block, which is all
the trie replay requires of them, because applying a whole run to the
chain records blocks the asset's own history never lists.
-}
blocksAsLanded :: [HistoryBlock] -> [HistoryBlock] -> Either Text ()
blocksAsLanded actual expected
    | length actual == length expected
    , and (zipWith sameMaterial actual expected)
    , ascending (map blockHeight actual)
    , ascending (map blockHeight expected) =
        Right ()
    | otherwise =
        Left
            ( "the chained history is not the landed chain's: "
                <> T.pack (show (map identityOf actual))
                <> " against "
                <> T.pack (show (map identityOf expected))
            )
  where
    sameMaterial whole other =
        map record (NE.toList (blockTransactions whole))
            == map record (NE.toList (blockTransactions other))
    record HistoricalTransaction{..} =
        ( historicalId
        , historicalCbor
        , historicalTx
        , spentOutputs
        , referenceOutputs
        , createdOutputs
        , scriptValid
        )
    identityOf block = map historicalId (NE.toList (blockTransactions block))
    ascending heights = and (zipWith (<) heights (drop 1 heights))

{- | One lovelace more on the first output of every answer: the right
references paired with a wrong value, the corruption the landed-answer
comparison must reject.
-}
offByOneLovelace
    :: [Either ReadFailure Outputs] -> [Either ReadFailure Outputs]
offByOneLovelace = fmap (fmap bump)
  where
    bump ((reference, out) : rest) =
        (reference, out & coinTxOutL .~ Coin (coinOf out + 1)) : rest
    bump [] = []
    coinOf out = case out ^. coinTxOutL of Coin c -> c

{- | The first block's transaction bytes emptied: identity and references
stay, the replay material does not.
-}
emptyFirstCbor :: [HistoryBlock] -> [HistoryBlock]
emptyFirstCbor = \case
    [] -> []
    (first : rest) ->
        first
            { blockTransactions = case blockTransactions first of
                record :| others -> record{historicalCbor = BS.empty} :| others
            }
            : rest

{- | Two addresses whose answers name the same reference with outputs one
lovelace apart: exactly the disagreement the provider's compound merge
refuses, which the chained composition must refuse too.
-}
firstAddress, secondAddress :: Addr
firstAddress = addrFromKeyHashBytes Testnet (BS.replicate 28 0x61)
secondAddress = addrFromKeyHashBytes Testnet (BS.replicate 28 0x62)

sharedReference :: TxIn
sharedReference = txInOf '9' 0

conflictingLeaves :: Session NoWitness IO
conflictingLeaves =
    withAddressOutputs
        ( \address ->
            pure
                [
                    ( sharedReference
                    , if address == secondAddress
                        then
                            mkBasicTxOut
                                firstAddress
                                (MaryValue (Coin 1_000_001) mempty)
                        else
                            mkBasicTxOut
                                firstAddress
                                (MaryValue (Coin 1_000_000) mempty)
                    )
                ,
                    ( txInOf '9' 1
                    , mkBasicTxOut address (MaryValue (Coin 2_000_000) mempty)
                    )
                ]
        )
        stubSession

{- | One chain block at height 100, served while the read's from-height is
at or below it and withheld above it: a bounded upstream, so the staged
tail must honour the range itself.
-}
boundedHistory :: ConwayTx -> Session NoWitness IO
boundedHistory chainBody =
    withTip
        (TipObservation (SlotNo 100) (BS.replicate 32 0) 100 0)
        stubSession
            { history = \_ range -> pure (Right (upstreamOf range))
            }
  where
    upstreamOf (HistoryRange (Just from) _)
        | from > 100 = HistoryStream (pure (Right Nothing))
    upstreamOf _ =
        HistoryStream
            (pure (Right (Just (chainBlock, HistoryStream (pure (Right Nothing))))))
    chainBlock =
        HistoryBlock
            100
            ( HistoricalTransaction
                { historicalId = txIdTx chainBody
                , historicalCbor =
                    BL.toStrict (serialize (eraProtVerHigh @ConwayEra) chainBody)
                , historicalTx = chainBody
                , spentOutputs = []
                , referenceOutputs = []
                , createdOutputs = []
                , scriptValid = True
                }
                :| []
            )

historyThrough
    :: Session NoWitness IO -> HistoryRange -> IO [HistoryBlock]
historyThrough view range = do
    supplied <- history view stateAsset range
    stream <- case supplied of
        Left failure -> error ("ChainedViewSpec: no history: " <> show failure)
        Right ok -> pure ok
    drainStream stream

-- ---------------------------------------------------------
-- The run's staged list: a preparation, then the boot publication
-- ---------------------------------------------------------

stagedRunWithPublication :: IO (StagedTransaction, StagedTransaction)
stagedRunWithPublication = do
    chain <- newChain
    withLatest (rawChainProvider chain) $ \base -> do
        pp <- parameters base
        wallet <- outputsAt base payer
        planned <- case planPreparation pp payer 5_000_000 wallet of
            Left refusal ->
                error
                    ("ChainedViewSpec: the preparation is refused: " <> show refusal)
            Right fine -> pure fine
        stagedRef <- newIORef []
        let viewNow = readIORef stagedRef
        prepStaged <- stageOver base (prepTx planned)
        modifyIORef' stagedRef (<> [prepStaged])
        afterPrep <- chainedSession viewNow base
        boot <-
            bootTokenFrom cfg (publicationIn, publicationOutput) afterPrep payer
        bootStaged <- stageOver afterPrep boot
        pure (prepStaged, bootStaged)

landedRun :: IO RawChain
landedRun = do
    chain <- newChain
    (prepStaged, bootStaged) <- stagedRunWithPublication
    applyStaged chain [prepStaged, bootStaged]
    pure chain

chainedAnswersOf
    :: RawChain
    -> [StagedTransaction]
    -> [OutputQuery]
    -> IO [Either ReadFailure Outputs]
chainedAnswersOf chain staged queries =
    withLatest (rawChainProvider chain) $ \base -> do
        view <- chainedSession (pure staged) base
        traverse (fmap valueOf . outputs view) queries

chainedMintsOf
    :: RawChain
    -> [StagedTransaction]
    -> [Asset]
    -> IO [Either ReadFailure (Maybe MintRecord)]
chainedMintsOf chain staged assets =
    withLatest (rawChainProvider chain) $ \base -> do
        view <- chainedSession (pure staged) base
        traverse (fmap valueOf . mintRecord view) assets

-- ---------------------------------------------------------
-- The fold rig: a registry that exists, one staged fold
-- ---------------------------------------------------------

data FoldRig = FoldRig
    { frChain :: RawChain
    , frStaged :: [StagedTransaction]
    , frOracle :: RawChain
    , frFoldTx :: ConwayTx
    , frNewRoot :: Root
    }

{- | A registry that exists on the chain — the boot publication applied —
one pending request planted live, and the fold built with the real
builder over the chained view and staged on it. The oracle chain carries
the same registry, the same request and the fold applied.
-}
foldRig :: IO FoldRig
foldRig = do
    chain <- newChain
    boot <- withLatest (rawChainProvider chain) $ \base ->
        bootTokenFrom cfg (publicationIn, publicationOutput) base payer
    applyToChain chain boot
    plantRequest chain
    stagedTx <-
        withLatest (rawChainProvider chain) $ \base -> do
            view <- chainedSession (pure []) base
            foldTx <-
                updateTokenSelected
                    cfg
                    view
                    (foldSnapshot boot)
                    tokenId
                    payer
                    foldContext
                    (requestIn :| [])
            stageOver view foldTx
    let staged = [stagedTx]
    oracle <- newChain
    oracleBoot <-
        withLatest (rawChainProvider oracle) $ \base ->
            bootTokenFrom cfg (publicationIn, publicationOutput) base payer
    applyToChain oracle oracleBoot
    plantRequest oracle
    applyStaged oracle staged
    pure
        FoldRig
            { frChain = chain
            , frStaged = staged
            , frOracle = oracle
            , frFoldTx = stagedBody stagedTx
            , frNewRoot = foldRootOf (stagedBody stagedTx)
            }
  where
    plantRequest chain =
        advanceChain chain $ \facts ->
            facts{csUTxO = Map.insert requestIn requestOutput (csUTxO facts)}
    requestOutput =
        mkBasicTxOut
            (requestAddrFromCfg cfg tokenId Testnet)
            (MaryValue (Coin 10_000_000) mempty)
            & datumTxOutL
                .~ mkInlineDatum
                    ( mkRequestDatumWith
                        tokenId
                        payer
                        key
                        1
                        2_000_000
                        1_000
                        (serialiseAddr payer, Nothing)
                    )
    foldRootOf tx =
        case [ Root (unOnChainRoot (stateRoot st))
             | out <- toList (tx ^. bodyTxL . outputsTxBodyL)
             , holdsStateAsset out
             , Just (StateDatum st) <- [extractCageDatum out]
             ] of
            [single] -> single
            _ -> error "ChainedViewSpec: the fold made no single state output"

{- | The capability snapshot the fold builder proves against: the boot's
state output, at the boot root.
-}
foldSnapshot :: ConwayTx -> TrieSnapshot IO
foldSnapshot boot =
    either (error . show) id $
        fixtureSnapshot
            ( fixtureStore
                [
                    ( chosen
                    , Just (CreateRecord registryIdentity stateIn)
                    , []
                    , emptyMPFInMemoryDB
                    )
                ]
            )
            chosen
  where
    stateIn = stateRefOf boot
    chosen =
        TrieSelection
            registryIdentity
            (StatePoint (SessionId "chained-view-fold-fixture") Unbound stateIn)
            (Root emptyRoot)

foldContext :: RegistryContext
foldContext =
    emptyRegistryContext
        { rcWitnessScripts = Map.singleton 1 Fixture.applicationScript
        }

-- ---------------------------------------------------------
-- The trie selection over a session, and its comparison
-- ---------------------------------------------------------

data SelectionFacts = SelectionFacts
    { sfCoverage :: CompleteFromCreate
    , sfLineage :: Maybe PublicLineage
    , sfLeaf :: Either TrieFailure Leaf
    }
    deriving stock (Eq, Show)

{- | One selection of the registry's trie over a session, at the fold's own
state output, expecting the root the fold's state datum carries.
-}
selectionOver
    :: Session NoWitness IO
    -> TxIn
    -> Root
    -> IO (Either Text SelectionFacts)
selectionOver session stateIn root = do
    let chosen =
            TrieSelection
                registryIdentity
                (StatePoint (sessionId session) (sessionBinding session) stateIn)
                root
    answer <-
        withTrieState (lineageTrieState session) chosen $ \snapshot -> do
            leaf <- leafAt snapshot key
            pure
                ( trieRoot snapshot
                , trieCoverage snapshot
                , trieLineage snapshot
                , leaf
                )
    pure $ case answer of
        Left failure ->
            Left (T.pack ("the selection refused: " <> show failure))
        Right (gotRoot, coverage, lineage, leaf) ->
            if gotRoot == root
                then Right (SelectionFacts coverage lineage leaf)
                else
                    Left
                        ( T.pack
                            ( "the selected root is not the fold's own: "
                                <> show gotRoot
                                <> " against "
                                <> show root
                            )
                        )

selectionOf
    :: RawChain -> TxIn -> Root -> IO (Either Text SelectionFacts)
selectionOf oracle stateIn root =
    withLatest (rawChainProvider oracle) $ \session ->
        selectionOver session stateIn root

selectionsAgree
    :: Either Text SelectionFacts
    -> Either Text SelectionFacts
    -> Either Text ()
selectionsAgree actual expected
    | Right a <- actual
    , Right e <- expected
    , a == e =
        Right ()
    | otherwise =
        Left
            ( "the chained selection is not the landed one: "
                <> T.pack (show actual)
                <> " against "
                <> T.pack (show expected)
            )

-- ---------------------------------------------------------
-- The rows
-- ---------------------------------------------------------

spec :: Spec
spec =
    describe "ChainedView answers as if the staged run had landed" $ do
        it "answers every output query form as the chain does after landing" $ do
            (prepStaged, bootStaged) <- stagedRunWithPublication
            let staged = [prepStaged, bootStaged]
            oracle <- landedRun
            let queries =
                    [ ("the payer's address", AtAddress payer)
                    , ("the state address", AtAddress stateAddress)
                    , ("the state token", HoldingAsset stateAsset)
                    , ("a spent exact reference", AtTxIn fundA)
                    , ("the spent seed", AtTxIn seedIn)
                    ,
                        ( "a staged-created exact reference"
                        , AtTxIn (stateRefOf (stagedBody bootStaged))
                        )
                    ,
                        ( "the state-script carrier"
                        , CarryingReferenceScript (cfgScriptHash cfg)
                        )
                    ,
                        ( "an any-of over two addresses"
                        , AnyOf (AtAddress stateAddress :| [AtAddress payer])
                        )
                    ,
                        ( "an all-of that selects the state output"
                        , AllOf (AtAddress stateAddress :| [HoldingAsset stateAsset])
                        )
                    ,
                        ( "a nested any-of over an all-of and an address"
                        , AnyOf
                            ( AllOf (AtAddress stateAddress :| [HoldingAsset stateAsset])
                                :| [AtAddress payer]
                            )
                        )
                    ,
                        ( "an any-of holding a staged-created reference"
                        , AnyOf
                            (AtTxIn (stateRefOf (stagedBody bootStaged)) :| [AtAddress payer])
                        )
                    ,
                        ( "an all-of holding a spent exact reference"
                        , AllOf (AtTxIn seedIn :| [AtAddress payer])
                        )
                    ]
                names = map fst queries
                expectedPairs = zip names
            expected <- fixtureAnswers oracle (map snd queries)
            chain <- newChain
            actual <- chainedAnswersOf chain staged (map snd queries)
            answersAsLanded (zip names actual) (expectedPairs expected)
                `shouldBe` Right ()
            forM_ [[prepStaged], [bootStaged]] $ \defect -> do
                defective <- chainedAnswersOf chain defect (map snd queries)
                answersAsLanded (zip names defective) (expectedPairs expected)
                    `shouldSatisfy` isLeft
            answersAsLanded
                (zip names actual)
                (expectedPairs (offByOneLovelace expected))
                `shouldSatisfy` isLeft

        it "answers the mint record from the staged transaction that mints" $ do
            (prepStaged, bootStaged) <- stagedRunWithPublication
            let staged = [prepStaged, bootStaged]
            oracle <- landedRun
            let assets =
                    [ ("the staged-minted state token", stateAsset)
                    , ("an asset nothing mints", otherAsset)
                    ]
                names = map fst assets
            expected <- fixtureMints oracle (map snd assets)
            chain <- newChain
            actual <- chainedMintsOf chain staged (map snd assets)
            mintsAsLanded (zip names actual) (zip names expected)
                `shouldBe` Right ()
            defective <- chainedMintsOf chain [prepStaged] (map snd assets)
            mintsAsLanded (zip names defective) (zip names expected)
                `shouldSatisfy` isLeft

        it "serves the asset history with the staged blocks after the chain's" $ do
            (prepStaged, bootStaged) <- stagedRunWithPublication
            let staged = [prepStaged, bootStaged]
            oracle <- landedRun
            expected <- fixtureHistory oracle stateAsset
            chain <- newChain
            actual <-
                withLatest (rawChainProvider chain) $ \base ->
                    chainedHistoryOf base staged stateAsset
            blocksAsLanded actual expected `shouldBe` Right ()
            defective <-
                withLatest (rawChainProvider chain) $ \base ->
                    chainedHistoryOf base [prepStaged] stateAsset
            blocksAsLanded defective expected `shouldSatisfy` isLeft
            blocksAsLanded (emptyFirstCbor actual) expected
                `shouldSatisfy` isLeft

        it
            "refuses a reference two sub-answers disagree about, as the provider does"
            $ do
                (prepStaged, bootStaged) <- stagedRunWithPublication
                let compound =
                        [ AnyOf (AtAddress firstAddress :| [AtAddress secondAddress])
                        , AllOf (AtAddress firstAddress :| [AtAddress secondAddress])
                        ]
                forM_ compound $ \query -> do
                    emptyStaged <- chainedSession (pure []) conflictingLeaves
                    emptyAnswer <- outputs emptyStaged query
                    fmap value emptyAnswer
                        `shouldBe` Left (ConflictingOutput sharedReference)
                    withStaged <-
                        chainedSession (pure [prepStaged, bootStaged]) conflictingLeaves
                    stagedAnswer <- outputs withStaged query
                    fmap value stagedAnswer
                        `shouldBe` Left (ConflictingOutput sharedReference)

        it "honours the read's range over the staged blocks too" $ do
            (_, bootStaged) <- stagedRunWithPublication
            view <-
                chainedSession
                    (pure [bootStaged])
                    (boundedHistory (stagedBody bootStaged))
            full <- historyThrough view (HistoryRange Nothing Nothing)
            map blockHeight full `shouldBe` [100, 101]
            throughHundred <-
                historyThrough view (HistoryRange Nothing (Just 100))
            map blockHeight throughHundred `shouldBe` [100]
            fromHundredAndOne <-
                historyThrough view (HistoryRange (Just 101) Nothing)
            map blockHeight fromHundredAndOne `shouldBe` [101]
            fromFifty <- historyThrough view (HistoryRange (Just 50) Nothing)
            map blockHeight fromFifty `shouldBe` [100, 101]

        it
            "numbers the staged blocks after the view's tip, not the visible answer"
            $ do
                (_, bootStaged) <- stagedRunWithPublication
                view <-
                    chainedSession
                        (pure [bootStaged])
                        (boundedHistory (stagedBody bootStaged))
                hiddenTail <- historyThrough view (HistoryRange (Just 101) Nothing)
                map blockHeight hiddenTail `shouldBe` [101]
                visibleTail <- historyThrough view (HistoryRange (Just 50) Nothing)
                map blockHeight visibleTail `shouldBe` [100, 101]

        it "returns no staged block past the read's upper bound" $ do
            (_, bootStaged) <- stagedRunWithPublication
            view <-
                chainedSession
                    (pure [bootStaged])
                    (boundedHistory (stagedBody bootStaged))
            bounded <- historyThrough view (HistoryRange Nothing (Just 100))
            map blockHeight bounded `shouldBe` [100]
            admitted <- historyThrough view (HistoryRange Nothing (Just 101))
            map blockHeight admitted `shouldBe` [100, 101]

        it "returns no staged block below the read's lower bound" $ do
            (_, bootStaged) <- stagedRunWithPublication
            view <-
                chainedSession
                    (pure [bootStaged])
                    (boundedHistory (stagedBody bootStaged))
            aboveAll <- historyThrough view (HistoryRange (Just 102) Nothing)
            map blockHeight aboveAll `shouldBe` []
            lastAdmitted <- historyThrough view (HistoryRange (Just 101) Nothing)
            map blockHeight lastAdmitted `shouldBe` [101]

        it "keeps one view consistent while the staged list grows" $ do
            (prepStaged, bootStaged) <- stagedRunWithPublication
            let staged = [prepStaged, bootStaged]
            partOracle <- newChain
            applyStaged partOracle [prepStaged]
            fullOracle <- newChain
            applyStaged fullOracle staged
            let probe =
                    [ AtAddress payer
                    , HoldingAsset stateAsset
                    , AtTxIn fundA
                    ]
                labels = map show probe
            partExpected <- fixtureAnswers partOracle probe
            fullExpected <- fixtureAnswers fullOracle probe
            chain <- newChain
            (heldStill, heldBefore, fresh) <-
                withLatest (rawChainProvider chain) $ \base -> do
                    stagedSource <- newIORef [prepStaged]
                    held <- chainedSession (readIORef stagedSource) base
                    beforeGrowth <-
                        traverse (fmap valueOf . outputs held) probe
                    modifyIORef' stagedSource (<> [bootStaged])
                    afterGrowth <-
                        traverse (fmap valueOf . outputs held) probe
                    later <- chainedSession (readIORef stagedSource) base
                    afterAcquisition <-
                        traverse (fmap valueOf . outputs later) probe
                    pure (beforeGrowth == afterGrowth, beforeGrowth, afterAcquisition)
            heldStill `shouldBe` True
            answersAsLanded (zip labels heldBefore) (zip labels partExpected)
                `shouldBe` Right ()
            answersAsLanded (zip labels fresh) (zip labels fullExpected)
                `shouldBe` Right ()
            answersAsLanded (zip labels heldBefore) (zip labels fullExpected)
                `shouldSatisfy` isLeft

        it "leaves the chain's own reads unchanged" $ do
            (prepStaged, bootStaged) <- stagedRunWithPublication
            let staged = [prepStaged, bootStaged]
            chain <- newChain
            agree <-
                withLatest (rawChainProvider chain) $ \base -> do
                    view <- chainedSession (pure staged) base
                    tipBefore <- valueOf <$> tipObservation base
                    tipAfter <- valueOf <$> tipObservation view
                    let paramsOf session = do
                            answer <- valueOf <$> protocolParameters session
                            pure $ case answer of
                                Left failure -> Left failure
                                Right params -> Right (params ^. ppMaxTxSizeL)
                        timeOf session = do
                            answer <- valueOf <$> networkTime session
                            pure $ case answer of
                                Left failure -> Left failure
                                Right time ->
                                    Right (networkMagic time, networkProtocolMajor time)
                    paramsBefore <- paramsOf base
                    paramsAfter <- paramsOf view
                    timeBefore <- timeOf base
                    timeAfter <- timeOf view
                    registered <-
                        valueOf <$> scriptRegistered base (cfgScriptHash cfg)
                    registeredView <-
                        valueOf <$> scriptRegistered view (cfgScriptHash cfg)
                    pure
                        ( tipBefore == tipAfter
                        , paramsBefore == paramsAfter
                        , timeBefore == timeAfter
                        , registered == registeredView
                        , sessionId base == sessionId view
                        , sessionBinding base == sessionBinding view
                        , sessionNetwork base == sessionNetwork view
                        )
            agree
                `shouldBe` ( True
                           , True
                           , True
                           , True
                           , True
                           , True
                           , True
                           )

        it
            "selects the registry's trie over the staged fold as over the landed one"
            $ do
                rig <- foldRig
                let FoldRig{frChain, frStaged, frOracle, frFoldTx, frNewRoot} = rig
                    foldStateIn = stateRefOf frFoldTx
                expected <- selectionOf frOracle foldStateIn frNewRoot
                actual <-
                    withLatest (rawChainProvider frChain) $ \base -> do
                        view <- chainedSession (pure frStaged) base
                        selectionOver view foldStateIn frNewRoot
                selectionsAgree actual expected `shouldBe` Right ()
                defective <-
                    withLatest (rawChainProvider frChain) $ \base -> do
                        view <- chainedSession (pure []) base
                        selectionOver view foldStateIn frNewRoot
                selectionsAgree defective expected `shouldSatisfy` isLeft
