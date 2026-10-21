{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.Registry.TxBuilder.SelectedFoldSpec
Description : The library fold over booked requests, through its public entry paths
License     : Apache-2.0

The library's public fold entry points ('updateTokenSelected',
'updateTokenWithTrieState', 'updateTokenWithDuties') compose three owners:
discovery of the pending requests by the request policy through the acquired
session, the tagged selection that judges each of them, and the lawful fold
that spends the state and exactly the settled requests. These rows execute
that composition against a stubbed session and a fixture capability snapshot
or a trie manager, with genuine booked registrations and terminations: the
fold's inputs, mints, donation and bound are read from the built body and
every expected value from the pending outputs the builder was given and the
requests they carry, never typed.

The session records every query it is asked, so a row can assert that the
request address is never read for discovery, and the discovery session
serves untagged and legacy outputs at that address to show that they change
nothing. The rows that skip local evaluation (conformance only) judge the
connected fold's own post-build checks.

A legacy untagged request at the request address is no member; the rows that
once chose such requests, their excluded edge and their undecodable
destination, are replaced by the booked requests the law admits and, where a
legacy concept has no booked counterpart, by the refusal the law gives.
-}
module Singular.Registry.TxBuilder.SelectedFoldSpec (spec) where

import Control.Exception (SomeException, displayException, try)
import Control.Monad (forM_)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Short qualified as SBS
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.List (isInfixOf, sort)
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Lens.Micro ((&), (.~), (^.))
import Test.Hspec

import Cardano.Ledger.Address (Addr, serialiseAddr)
import Cardano.Ledger.Allegra.Scripts (ValidityInterval (..))
import Cardano.Ledger.Api.Tx (bodyTxL, witsTxL)
import Cardano.Ledger.Api.Tx.Body
    ( inputsTxBodyL
    , mintTxBodyL
    , outputsTxBodyL
    , treasuryDonationTxBodyL
    , vldtTxBodyL
    )
import Cardano.Ledger.Api.Tx.Out
    ( TxOut
    , addrTxOutL
    , coinTxOutL
    , datumTxOutL
    , getMinCoinTxOut
    , mkBasicTxOut
    , valueTxOutL
    )
import Cardano.Ledger.Api.Tx.Wits (Redeemers (..), rdmrsTxWitsL)
import Cardano.Ledger.BaseTypes (Network (Testnet), StrictMaybe (..))
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Mary.Value
    ( AssetName (..)
    , MaryValue (..)
    , MultiAsset (..)
    , PolicyID
    )
import Cardano.Ledger.Plutus.Data (getPlutusData)
import Cardano.Ledger.TxIn (TxIn)
import Cardano.Slotting.Slot (SlotNo (..))
import Cardano.Tx.Ledger (ConwayTx)
import PlutusTx.Builtins.Internal
    ( BuiltinByteString (..)
    , BuiltinData (..)
    )
import PlutusTx.IsData.Class (FromData (..))

import PlutusCore.Data qualified as PLC
import Singular.Registry.Blueprint (applyDataParam)
import Singular.Registry.Config
    ( CageConfig (..)
    , bootStateFromCfg
    , defaultProcessTime
    )
import Singular.Registry.Deployment (parseOutRef)
import Singular.Registry.Evidence (NoWitness)
import Singular.Registry.FoldAdmission (foldAdmission)
import Singular.Registry.Ledger (ConwayEra, Root (..), TokenId (..))
import Singular.Registry.LedgerProvider
    ( OutputQuery (..)
    , ReadFailure (..)
    , Session (..)
    , TipObservation (..)
    )
import Singular.Registry.SessionIO qualified as Services
import Singular.Registry.StubSession
import Singular.Registry.SyntheticLedger
    ( unitProgram
    , withSyntheticCosts
    )
import Singular.Registry.SyntheticTime (syntheticTime)
import Singular.Registry.Trie (Trie (..), TrieManager (..))
import Singular.Registry.Trie.PureManager (mkPureTrieManagerFrom)
import Singular.Registry.TrieState
    ( CreateRecord (..)
    , ObservedFold (..)
    , RegistryIdentity (..)
    , SessionBinding (..)
    , SessionId (..)
    , StatePoint (..)
    , StatePolicyId (..)
    , TrieSelection (..)
    , TrieSnapshot
    )
import Singular.Registry.TrieState.Fixture
    ( fixtureSnapshot
    , fixtureStore
    )
import Singular.Registry.TxBuilder.BookingFixture qualified as Fixture
import Singular.Registry.TxBuilder.ConnectedFold
    ( ConnectedFoldArgs (..)
    , ConnectedMint (..)
    , RawRedeemer (..)
    , connectedFoldTx
    )
import Singular.Registry.TxBuilder.Internal.Edges (walkEdge)
import Singular.Registry.TxBuilder.Internal.Identity
    ( cageAddrFromCfg
    , cagePolicyIdFromCfg
    , computeScriptHash
    , emptyRoot
    , mkInlineDatum
    , mkRequestDatumWith
    , onChainTokenId
    , policyIdFromPin
    , requestAddrFromCfg
    , scriptFromBytes
    , scriptHashBytes
    , toPlcData
    )
import Singular.Registry.TxBuilder.Internal.Lookup
    ( BookedRequest (..)
    , bookedRequestOf
    , requestPolicyOf
    )
import Singular.Registry.TxBuilder.Update
    ( RegistryContext (..)
    , emptyRegistryContext
    , taggedMints
    , updateTokenSelected
    , updateTokenWithDuties
    , updateTokenWithTrieState
    )
import Singular.Registry.Types
    ( CageDatum (..)
    , OnChainRegistrationRequest (..)
    , OnChainRoot (..)
    , OnChainTerminationRequest (..)
    , RequestAction (..)
    , UpdateRedeemer (..)
    , applicationTagName
    , edgeInsertActive
    , terminationTrieReadyTagName
    , trieReadyTagName
    )

-- ---------------------------------------------------------
-- Fixtures: one registry, booked registrations and terminations
-- ---------------------------------------------------------

{- | The registry the rows fold. The scripts of its state, its requests and
its two token policies are always-succeeding programs, whose hashes are the
pins the registry commits to: the library finds a policy's script by that
pin.
-}
cfg :: CageConfig
cfg =
    Fixture.cfg
        { cageScriptBytes = unitProgram 1
        , cfgScriptHash = computeScriptHash (unitProgram 1)
        , requestScriptBytes = unitProgram 3
        , cfgActivePolicy = pinOf activeProgram
        , cfgApplicationPolicy = pinOf applicationProgram
        }
  where
    pinOf = SBS.toShort . scriptHashBytes . computeScriptHash

-- | An always-succeeding policy that takes one argument, the script context.
activeProgram, applicationProgram :: SBS.ShortByteString
activeProgram = applyDataParam (PLC.I 1) (unitProgram 2)
applicationProgram = applyDataParam (PLC.I 2) (unitProgram 2)

tokenId :: TokenId
tokenId = Fixture.tokenId

payer :: Addr
payer = Fixture.payer

txIn :: Char -> Int -> TxIn
txIn c i =
    either
        (error . ("SelectedFoldSpec fixture: " <>))
        id
        (parseOutRef (T.pack (replicate 64 c <> "#" <> show i)))

stateIn :: TxIn
stateIn = txIn 'b' 0

reqIn1
    , reqIn2
    , reqIn3
    , reqIn4
    , reqIn5
    , reqIn6
    , reqIn9
    , reqIn10
    , reqIn11
    , reqIn12
        :: TxIn
reqIn1 = txIn 'a' 0
reqIn2 = txIn 'a' 1
reqIn3 = txIn 'a' 2
reqIn4 = txIn 'a' 3
reqIn5 = txIn 'a' 4
reqIn6 = txIn 'a' 5
reqIn9 = txIn 'a' 8
reqIn10 = txIn 'a' 9
reqIn11 = txIn 'a' 10
reqIn12 = txIn 'a' 11

feeIn :: TxIn
feeIn = txIn 'e' 0

missingIn :: TxIn
missingIn = txIn 'f' 9

key1, key2, key3, key4, key5, key6, key7 :: ByteString
key1 = "test-key-1"
key2 = "test-key-2"
key3 = "test-key-3"
key4 = "test-key-4"
key5 = "test-key-5"
key6 = "test-key-6"
key7 = "test-key-7"

submitted1, submitted2, submitted3, submitted4 :: Integer
submitted1 = 1_000
submitted2 = 2_000
submitted3 = 3_000
submitted4 = 4_000

-- | A booked registration of a key, as the booking leaves it.
registrationOf :: ByteString -> Integer -> OnChainRegistrationRequest
registrationOf key submittedAt =
    OnChainRegistrationRequest
        { regRegistry = onChainTokenId tokenId
        , regKey = key
        , regRefundAddress = BuiltinByteString (BS.replicate 28 0xd1)
        , regDestination = serialiseAddr payer
        , regDatum = Nothing
        , regSubmittedAt = submittedAt
        , regRegistrationCost = 2_000_000
        , regDeclaredTip = 1_500_000
        , regCarrierAda = 1_500_000
        , regNonce = 1
        }

applicationTagOf :: OnChainRegistrationRequest -> ByteString
applicationTagOf r =
    applicationTagName
        (regKey r)
        (regRefundAddress r)
        (regDestination r)
        (regNonce r)

{- | A booked registration of a key: the request the request policy vouches
for, held with the trie-ready tag its own datum commits to and the
application tag its booking issued.
-}
taggedRegistration :: ByteString -> Integer -> TxOut ConwayEra
taggedRegistration key submittedAt = registrationOutput (registrationOf key submittedAt)

registrationOutput :: OnChainRegistrationRequest -> TxOut ConwayEra
registrationOutput request =
    mkBasicTxOut
        (requestAddrFromCfg cfg tokenId Testnet)
        ( MaryValue
            -- the booking holds exactly its cost, its tip and its declared carrier
            ( Coin
                ( regRegistrationCost request
                    + regDeclaredTip request
                    + regCarrierAda request
                )
            )
            ( MultiAsset
                ( Map.fromList
                    [
                        ( requestPolicyOf cfg tokenId
                        , Map.singleton (AssetName (SBS.toShort (trieReadyTagName request))) 1
                        )
                    ,
                        ( policyIdFromPin (cfgApplicationPolicy cfg)
                        , Map.singleton (AssetName (SBS.toShort (applicationTagOf request))) 1
                        )
                    ]
                )
            )
        )
        & datumTxOutL .~ mkInlineDatum (toPlcData (RegistrationDatum request))

{- | A booked termination of a key: the request holding the key's singular tag
and the trie-ready tag its own datum commits to.
-}
taggedTermination :: ByteString -> TxOut ConwayEra
taggedTermination key =
    mkBasicTxOut
        (requestAddrFromCfg cfg tokenId Testnet)
        ( MaryValue
            (Coin 4_000_000)
            ( MultiAsset
                ( Map.fromList
                    [
                        ( requestPolicyOf cfg tokenId
                        , Map.singleton
                            (AssetName (SBS.toShort (terminationTrieReadyTagName request)))
                            1
                        )
                    ,
                        ( policyIdFromPin (cfgActivePolicy cfg)
                        , Map.singleton (AssetName (SBS.toShort key)) 1
                        )
                    ]
                )
            )
        )
        & datumTxOutL .~ mkInlineDatum (toPlcData (TerminationDatum request))
  where
    request =
        OnChainTerminationRequest
            { termRegistry = onChainTokenId tokenId
            , termKey = key
            , termDestination = BS.empty
            , termDeclaredTip = 1_500_000
            , termCarrierAda = 2_500_000
            , termNonce = 1
            }

-- | Three booked registrations on three keys with three distinct deadlines.
pendingReqs :: [(TxIn, TxOut ConwayEra)]
pendingReqs =
    [ (reqIn1, taggedRegistration key1 submitted1)
    , (reqIn2, taggedRegistration key2 submitted2)
    , (reqIn3, taggedRegistration key3 submitted3)
    ]

pendingReqs4 :: [(TxIn, TxOut ConwayEra)]
pendingReqs4 = pendingReqs <> [(reqIn4, taggedRegistration key4 submitted4)]

-- | One booked registration on its own, for the foreign-mint rows.
pendingSkipSingle :: [(TxIn, TxOut ConwayEra)]
pendingSkipSingle = [(reqIn12, taggedRegistration key7 submitted1)]

{- | A registration of a key and the termination of that same key, booked in
one batch: the pair the model refuses, one request per key.
-}
pendingTaggedPair :: [(TxIn, TxOut ConwayEra)]
pendingTaggedPair =
    [ (reqIn5, taggedRegistration key5 submitted1)
    , (reqIn6, taggedTermination key5)
    ]

{- | A created pair beside a further registration, all windows open: the
model's keyed mint check fires before the pair scan, so with no mints
supplied the builder must refuse @net-mint-mismatch@.
-}
pendingSkipMint :: [(TxIn, TxOut ConwayEra)]
pendingSkipMint =
    [ (reqIn9, taggedRegistration key5 submitted1)
    , (reqIn10, taggedTermination key5)
    , (reqIn11, taggedRegistration key6 submitted3)
    ]

-- | A mint under a policy that is not the registry's: attached application business.
unrelatedMint :: ConnectedMint
unrelatedMint =
    ConnectedMint
        { cmPolicy = Fixture.applicationPolicy
        , cmAssets = Map.singleton (AssetName (SBS.toShort "approval")) 1
        , cmRedeemer = RawRedeemer (PLC.Constr 0 [])
        , cmScript = Fixture.applicationScript
        }

deadlineOf :: Integer -> Integer
deadlineOf submittedAt = submittedAt + defaultProcessTime cfg

feeOut :: TxOut ConwayEra
feeOut = mkBasicTxOut payer (MaryValue (Coin 100_000_000) mempty)

{- | The scripts the library finds by the registry's pins: the active policy's
and the application's.
-}
ctx0 :: RegistryContext
ctx0 =
    emptyRegistryContext
        { rcWitnessScripts =
            Map.fromList
                [ (1, scriptFromBytes "selected-fold-active" activeProgram)
                , (3, scriptFromBytes "selected-fold-application" applicationProgram)
                ]
        }

-- ---------------------------------------------------------
-- The trie, the state and the session
-- ---------------------------------------------------------

-- | A registry's trie holding some keys as active, as a manager and as a snapshot.
data Rig = Rig
    { rigRoot :: Root
    , rigManager :: TrieManager IO
    , rigSnapshot :: TrieSnapshot IO
    }

{- | The registry's trie holding the given keys as active, and the capability
snapshot taken at the state output the fold spends.
-}
rigWith :: [ByteString] -> IO Rig
rigWith = rigAt (TokenId name) stateIn
  where
    TokenId name = tokenId

{- | The same, with the snapshot naming a registry and a state output of its
own, for the rows that show the snapshot's obligations.
-}
rigAt :: TokenId -> TxIn -> [ByteString] -> IO Rig
rigAt (TokenId name) point active = do
    (manager, dump) <- mkPureTrieManagerFrom Map.empty
    createTrie manager tokenId
    root <- withTrie manager tokenId $ \trie -> do
        mapM_ (\key -> walkEdge trie key edgeInsertActive) active
        getRoot trie
    nodes <- dump
    db <-
        maybe
            (fail "SelectedFoldSpec: the trie was lost")
            pure
            (Map.lookup tokenId nodes)
    let who =
            RegistryIdentity
                (StatePolicyId (scriptHashBytes (cfgScriptHash cfg)))
                name
        statePoint = StatePoint (SessionId "selected-fold-fixture") Unbound point
        chosen = TrieSelection who statePoint root
        -- the observed history that leads the empty trie to the active keys
        folds =
            [ ObservedFold
                (TrieSelection who statePoint (Root emptyRoot))
                chosen
                moves
            | moves <-
                maybe [] pure (NE.nonEmpty [(key, edgeInsertActive) | key <- active])
            ]
        store = fixtureStore [(chosen, Just (CreateRecord who point), folds, db)]
    snapshot <- either (fail . show) pure (fixtureSnapshot store chosen)
    pure (Rig root manager snapshot)

stateOutAt :: Root -> TxOut ConwayEra
stateOutAt = stateOutFor cfg

{- | The registry's state output under a configuration: its datum holds the
configuration's registration cost, tip and pins.
-}
stateOutFor :: CageConfig -> Root -> TxOut ConwayEra
stateOutFor configuration (Root root) =
    let TokenId name = tokenId
    in  mkBasicTxOut
            (cageAddrFromCfg configuration Testnet)
            ( MaryValue
                (Coin 3_000_000)
                ( MultiAsset
                    ( Map.singleton
                        (cagePolicyIdFromCfg configuration)
                        (Map.singleton name 1)
                    )
                )
            )
            & datumTxOutL
                .~ mkInlineDatum
                    ( toPlcData
                        (StateDatum (bootStateFromCfg configuration (OnChainRoot root)))
                    )

{- | The same registry configured to charge nothing to register: the identity,
the pins and the programs are the registry's, only the registration cost its
state declares is zero. A booked registration of this registry costs nothing,
and a fold of it donates nothing.
-}
cfgFree :: CageConfig
cfgFree = cfg{defaultRegistrationCost = Coin 0}

-- | What the session serves: what holds the request policy, and what sits at the request address.
data Chain = Chain
    { listed :: [(TxIn, TxOut ConwayEra)]
    , atRequestAddress :: [(TxIn, TxOut ConwayEra)]
    , funding :: TxOut ConwayEra
    -- ^ The folder's one output
    , configured :: CageConfig
    -- ^ The configuration the registry's state output declares and the library is given
    }

-- | A chain whose only outputs at the request address are the listed requests.
chainOf :: [(TxIn, TxOut ConwayEra)] -> Chain
chainOf requests = Chain requests requests feeOut cfg

requestAddr :: Addr
requestAddr = requestAddrFromCfg cfg tokenId Testnet

{- | The session over a chain, with the tip at a slot, recording every query it
is asked.
-}
viewAt
    :: IORef [OutputQuery]
    -> SlotNo
    -> Root
    -> Chain
    -> Session NoWitness IO
viewAt asked slot root Chain{listed, atRequestAddress, funding, configured} =
    recording $
        withTip (TipObservation slot (BS.replicate 32 0) 1 0) $
            withPolicyOutputs
                (\_ -> pure listed)
                ( withAddressOutputs
                    ( \addr ->
                        pure $
                            if addr == requestAddr
                                then atRequestAddress
                                else
                                    if addr == cageAddrFromCfg configured Testnet
                                        then [(stateIn, stateOutFor configured root)]
                                        else [(feeIn, funding)]
                    )
                    ( withParameters (withSyntheticCosts Fixture.preprodParams) $
                        withTime (pure syntheticTime) $
                            withResolvedOutputs
                                ( \wanted ->
                                    pure
                                        [ (reference, output)
                                        | (reference, output) <-
                                            (stateIn, stateOutFor configured root) : (feeIn, funding) : listed
                                        , reference `Set.member` wanted
                                        ]
                                )
                                stubSession
                    )
                )
  where
    recording session =
        session
            { outputs = \query -> do
                modifyIORef' asked (<> [query])
                outputs session query
            }

-- | The default view: the tip at slot 1, inside every registration's window.
viewOver
    :: IORef [OutputQuery] -> Root -> Chain -> Session NoWitness IO
viewOver asked = viewAt asked (SlotNo 1)

-- | Run a fold against a fresh rig and a recording view.
withRig
    :: [ByteString]
    -> Chain
    -> (Rig -> Session NoWitness IO -> IO a)
    -> IO (a, [OutputQuery])
withRig active chain run = do
    rig <- rigWith active
    asked <- newIORef []
    result <- run rig (viewOver asked (rigRoot rig) chain)
    queries <- readIORef asked
    pure (result, queries)

selectedOver
    :: [ByteString]
    -> Chain
    -> NonEmpty TxIn
    -> IO (ConwayTx, [OutputQuery])
selectedOver active chain refs =
    withRig active chain $ \rig view ->
        updateTokenSelected
            (configured chain)
            view
            (rigSnapshot rig)
            tokenId
            payer
            ctx0
            refs

everySettleableOver
    :: [ByteString] -> Chain -> IO (ConwayTx, [OutputQuery])
everySettleableOver active chain =
    withRig active chain $ \rig view ->
        updateTokenWithTrieState cfg view (rigSnapshot rig) tokenId payer ctx0

managerOver :: [ByteString] -> Chain -> IO (ConwayTx, [OutputQuery])
managerOver active chain =
    withRig active chain $ \rig view ->
        updateTokenWithDuties cfg view (rigManager rig) tokenId payer ctx0

-- | The outcome of a build that may be refused, as the refusal's text.
refusedWith :: IO a -> IO (Either String a)
refusedWith action = do
    outcome <- try action
    pure $ case outcome of
        Left err -> Left (displayException (err :: SomeException))
        Right built -> Right built

-- ---------------------------------------------------------
-- What the built fold carries
-- ---------------------------------------------------------

inputsOf :: ConwayTx -> Set.Set TxIn
inputsOf tx = tx ^. bodyTxL . inputsTxBodyL

upperOf :: ConwayTx -> SlotNo
upperOf tx = case tx ^. bodyTxL . vldtTxBodyL of
    ValidityInterval _ (SJust u) -> u
    _ -> error "SelectedFoldSpec: the built fold carries no upper bound"

actionsOf :: ConwayTx -> IO [RequestAction]
actionsOf tx =
    case [ actions
         | (_, (d, _)) <- Map.toList rdmrs
         , Just (Modify actions) <-
            [fromBuiltinData (BuiltinData (getPlutusData d))]
         ] of
        [actions] -> pure actions
        _ -> fail "the built fold carries other than one Modify action list"
  where
    Redeemers rdmrs = tx ^. witsTxL . rdmrsTxWitsL

-- | What the body mints, per policy and asset, zero entries absent.
mintedOf :: ConwayTx -> Map.Map (PolicyID, AssetName) Integer
mintedOf tx =
    Map.fromList
        [ ((policy, asset), quantity)
        | (policy, assets) <- Map.toList minted
        , (asset, quantity) <- Map.toList assets
        , quantity /= 0
        ]
  where
    MultiAsset minted = tx ^. bodyTxL . mintTxBodyL

{- | What the model owes the fold's members, read from the requests they carry:
the burn of each member's trie-ready tag, a registration's application tag
burned and its key's singular tag created, a termination's key singular tag
burned.
-}
owedMint
    :: [(TxIn, TxOut ConwayEra)] -> Map.Map (PolicyID, AssetName) Integer
owedMint members =
    Map.filter (/= 0) . Map.fromListWith (+) $
        concat
            [ case booked of
                BookedRegistration r ->
                    [ (tagged (trieReadyTagName r), -1)
                    ,
                        (
                            ( policyIdFromPin (cfgApplicationPolicy cfg)
                            , name (applicationTagOf r)
                            )
                        , -1
                        )
                    , ((active, name (regKey r)), 1)
                    ]
                BookedTermination t ->
                    [ (tagged (terminationTrieReadyTagName t), -1)
                    , ((active, name (termKey t)), -1)
                    ]
            | (_, out) <- members
            , Just booked <- [bookedRequestOf cfg tokenId out]
            ]
  where
    active = policyIdFromPin (cfgActivePolicy cfg)
    name = AssetName . SBS.toShort
    tagged tag = (requestPolicyOf cfg tokenId, name tag)

{- | What the model donates to the treasury: each registration's cost and each
termination's held lovelace less its declared tip.
-}
owedDonation :: [(TxIn, TxOut ConwayEra)] -> Integer
owedDonation members =
    sum
        [ case booked of
            BookedRegistration r -> regRegistrationCost r
            BookedTermination t ->
                let Coin held = out ^. coinTxOutL in held - termDeclaredTip t
        | (_, out) <- members
        , Just booked <- [bookedRequestOf cfg tokenId out]
        ]

spec :: Spec
spec = describe "chunk3 offchain" $ do
    describe "the library fold over a chosen pending request" $ do
        it "spends the state output and exactly the chosen request output" $ do
            let chosen = reqIn2
                others = [r | (r, _) <- pendingReqs, r /= chosen]
            (tx, asked) <- selectedOver [] (chainOf pendingReqs) (chosen :| [])
            let spent = inputsOf tx
            (chosen `Set.member` spent) `shouldBe` True
            (stateIn `Set.member` spent) `shouldBe` True
            map (`Set.member` spent) others `shouldBe` [False, False]
            actions <- actionsOf tx
            length actions `shouldBe` 1
            case actions of
                [Update _] -> pure ()
                _ ->
                    expectationFailure
                        "the redeemer carries other than the one chosen action"
            -- the chosen registration is folded with the mints the model owes it
            mintedOf tx
                `shouldBe` owedMint [m | m@(r, _) <- pendingReqs, r == chosen]
            tx ^. bodyTxL . treasuryDonationTxBodyL
                `shouldBe` Coin (owedDonation [m | m@(r, _) <- pendingReqs, r == chosen])
            -- and the request address was never read to find it
            asked `shouldNotContain` [AtAddress requestAddr]
        it "refuses a chosen reference that is not pending, naming it" $ do
            result <-
                refusedWith (selectedOver [] (chainOf pendingReqs) (missingIn :| []))
            case result of
                Left err -> err `shouldSatisfy` isInfixOf (show missingIn)
                Right _ ->
                    expectationFailure
                        "a chosen reference that is not pending built a fold"
            _ <- selectedOver [] (chainOf pendingReqs) (reqIn1 :| [])
            pure ()
        it "names the chosen reference when nothing is pending" $ do
            result <- refusedWith (selectedOver [] (chainOf []) (reqIn1 :| []))
            case result of
                Left err -> err `shouldSatisfy` isInfixOf (show reqIn1)
                Right _ ->
                    expectationFailure "an empty pending set built a fold"
        it "bounds the fold by the chosen request deadline" $ do
            (txMid, _) <- selectedOver [] (chainOf pendingReqs) (reqIn2 :| [])
            (txAll, _) <- everySettleableOver [] (chainOf pendingReqs)
            (txEarly, _) <- selectedOver [] (chainOf pendingReqs) (reqIn1 :| [])
            let upperMid = upperOf txMid
                upperAll = upperOf txAll
                upperEarly = upperOf txEarly
                expectedMid = SlotNo (fromInteger (deadlineOf submitted2 `div` 1000))
                expectedAll = SlotNo (fromInteger (deadlineOf submitted1 `div` 1000))
            upperMid `shouldBe` expectedMid
            upperAll `shouldBe` expectedAll
            (upperMid == upperAll) `shouldBe` False
            upperEarly `shouldBe` upperAll
        it
            "spends the state output and exactly two chosen requests, not the first pending"
            $ do
                let chosen = reqIn2 :| [reqIn3]
                    unchosen = [r | (r, _) <- pendingReqs, r `notElem` (reqIn2 : [reqIn3])]
                (tx, _) <- selectedOver [] (chainOf pendingReqs) chosen
                let spent = inputsOf tx
                (reqIn2 `Set.member` spent) `shouldBe` True
                (reqIn3 `Set.member` spent) `shouldBe` True
                (stateIn `Set.member` spent) `shouldBe` True
                map (`Set.member` spent) unchosen `shouldBe` [False]
                actions <- actionsOf tx
                length actions `shouldBe` 2
        it
            "spends the state output and exactly three chosen requests among four pending"
            $ do
                let chosen = reqIn2 :| [reqIn3, reqIn4]
                (tx, _) <- selectedOver [] (chainOf pendingReqs4) chosen
                let spent = inputsOf tx
                (reqIn2 `Set.member` spent) `shouldBe` True
                (reqIn3 `Set.member` spent) `shouldBe` True
                (reqIn4 `Set.member` spent) `shouldBe` True
                (stateIn `Set.member` spent) `shouldBe` True
                (reqIn1 `Set.member` spent) `shouldBe` False
                actions <- actionsOf tx
                length actions `shouldBe` 3
        it
            "bounds the fold by the earliest deadline among the chosen, not the first chosen"
            $ do
                let chosen = reqIn3 :| [reqIn1]
                (tx, _) <- selectedOver [] (chainOf pendingReqs) chosen
                let upper = upperOf tx
                    expectedEarly = SlotNo (fromInteger (deadlineOf submitted1 `div` 1000))
                    firstDeadline = SlotNo (fromInteger (deadlineOf submitted3 `div` 1000))
                upper `shouldBe` expectedEarly
                (upper == firstDeadline) `shouldBe` False
                (tx3, _) <-
                    selectedOver [] (chainOf pendingReqs4) (reqIn4 :| [reqIn3, reqIn1])
                upperOf tx3 `shouldBe` expectedEarly
                (upperOf tx3 == SlotNo (fromInteger (deadlineOf submitted4 `div` 1000)))
                    `shouldBe` False
        it
            "refuses a chosen reference that is not pending among several chosen, naming it"
            $ do
                result <-
                    refusedWith
                        (selectedOver [] (chainOf pendingReqs) (reqIn1 :| [reqIn2, missingIn]))
                case result of
                    Left err -> err `shouldSatisfy` isInfixOf (show missingIn)
                    Right _ ->
                        expectationFailure
                            "chosen references with one not pending built a fold"
        it "admits every built fold reading the bound from its body" $ do
            (tx, _) <- selectedOver [] (chainOf pendingReqs) (reqIn1 :| [reqIn2])
            asked <- newIORef []
            let view = viewOver asked (Root emptyRoot) (chainOf pendingReqs)
            case tx ^. bodyTxL . vldtTxBodyL of
                ValidityInterval _ (SJust u) -> do
                    boundMs <- Services.slotStart view u
                    foldAdmission
                        (defaultProcessTime cfg)
                        boundMs
                        [(reqIn1, submitted1), (reqIn2, submitted2)]
                        `shouldBe` Nothing
                _ ->
                    expectationFailure
                        "a built fold carries no validity upper bound"
        it
            "refuses a chosen registration whose window has closed, naming not-phase1"
            $ do
                let late = SlotNo (fromInteger (deadlineOf submitted1 `div` 1000) + 5)
                rig <- rigWith []
                asked <- newIORef []
                result <-
                    refusedWith
                        ( updateTokenSelected
                            cfg
                            (viewAt asked late (rigRoot rig) (chainOf pendingReqs))
                            (rigSnapshot rig)
                            tokenId
                            payer
                            ctx0
                            (reqIn1 :| [])
                        )
                case result of
                    Left err -> do
                        err `shouldSatisfy` isInfixOf "not-phase1"
                        err `shouldSatisfy` isInfixOf (show reqIn1)
                    Right _ ->
                        expectationFailure "a registration past its window built a fold"
        it "refuses a chosen registration whose destination is not an address" $ do
            let broken =
                    ( reqIn1
                    , registrationOutput
                        (registrationOf key1 submitted1){regDestination = "not-an-address"}
                    )
            result <-
                refusedWith (selectedOver [] (chainOf [broken]) (reqIn1 :| []))
            case result of
                Left err -> err `shouldSatisfy` isInfixOf "destination is not an address"
                Right _ ->
                    expectationFailure
                        "a registration with no deliverable destination built a fold"
        it
            "refuses a chosen registration whose key the registry already knows, naming key-exists"
            $ do
                result <-
                    refusedWith
                        (selectedOver [key1] (chainOf pendingReqs) (reqIn1 :| []))
                case result of
                    Left err -> err `shouldSatisfy` isInfixOf "key-exists"
                    Right _ ->
                        expectationFailure "a registration of a known key built a fold"
    describe "the library fold over a termination and a mixed selection" $ do
        let terminationAt ref key = (ref, taggedTermination key)
            registrationAt ref key at = (ref, taggedRegistration key at)
        it "folds a termination of an active key with no holder input" $ do
            let members = [terminationAt reqIn5 key5]
            (tx, asked) <- selectedOver [key5] (chainOf members) (reqIn5 :| [])
            -- the state, the request and the folder's funding are all it spends
            inputsOf tx `shouldBe` Set.fromList [stateIn, reqIn5, feeIn]
            mintedOf tx `shouldBe` owedMint members
            tx ^. bodyTxL . treasuryDonationTxBodyL
                `shouldBe` Coin (owedDonation members)
            asked `shouldNotContain` [AtAddress requestAddr]
        it
            "folds a registration and a termination of different keys in one body"
            $ do
                let members =
                        [ registrationAt reqIn1 key1 submitted1
                        , terminationAt reqIn5 key5
                        ]
                (tx, _) <- selectedOver [key5] (chainOf members) (reqIn1 :| [reqIn5])
                inputsOf tx `shouldBe` Set.fromList [stateIn, reqIn1, reqIn5, feeIn]
                mintedOf tx `shouldBe` owedMint members
                tx ^. bodyTxL . treasuryDonationTxBodyL
                    `shouldBe` Coin (owedDonation members)
                actions <- actionsOf tx
                length actions `shouldBe` 2
                -- the registration's carrier reaches its booked destination
                let carriers =
                        [ o
                        | o <- foldr (:) [] (tx ^. bodyTxL . outputsTxBodyL)
                        , o ^. addrTxOutL == payer
                        , o ^. coinTxOutL
                            == Coin (regCarrierAda (registrationOf key1 submitted1))
                        ]
                length carriers `shouldBe` 1
        it
            "refuses a termination of a key the registry does not know, naming key-unknown"
            $ do
                result <-
                    refusedWith
                        (selectedOver [] (chainOf [terminationAt reqIn5 key5]) (reqIn5 :| []))
                case result of
                    Left err -> err `shouldSatisfy` isInfixOf "key-unknown"
                    Right _ ->
                        expectationFailure "a termination of an unknown key built a fold"
        it
            "refuses a registration and the termination of its own key chosen together, never token-missing"
            $ do
                result <-
                    refusedWith
                        (selectedOver [] (chainOf pendingTaggedPair) (reqIn5 :| [reqIn6]))
                case result of
                    Left err -> do
                        err `shouldSatisfy` isInfixOf (show reqIn6)
                        err `shouldSatisfy` isInfixOf "key-unknown"
                        err `shouldNotSatisfy` isInfixOf "token-missing"
                    Right _ ->
                        expectationFailure
                            "a registration and the termination of its key built a fold"
        it "names a script no context answers for, before anything is built" $ do
            rig <- rigWith []
            asked <- newIORef []
            result <-
                refusedWith
                    ( updateTokenSelected
                        cfg
                        (viewOver asked (rigRoot rig) (chainOf pendingReqs))
                        (rigSnapshot rig)
                        tokenId
                        payer
                        emptyRegistryContext
                        (reqIn1 :| [])
                    )
            case result of
                Left err -> err `shouldSatisfy` isInfixOf "no script in hand"
                Right _ ->
                    expectationFailure "a fold without its policy scripts was built"
    describe "the library fold over every settleable pending request" $ do
        let mixedPending =
                [ (reqIn1, taggedRegistration key1 submitted1)
                , (reqIn2, taggedRegistration key2 submitted2)
                , (reqIn3, taggedTermination key3)
                , (reqIn4, taggedRegistration key4 submitted4)
                , (reqIn5, taggedTermination key5)
                ]
            -- key3 is unknown (its termination cannot fold), key4 is already
            -- active (its registration cannot fold), key5 is active
            active = [key4, key5]
            settledRefs = [reqIn1, reqIn2, reqIn5]
            leftRefs = [reqIn3, reqIn4]
        it "folds the settleable requests and leaves the others pending" $ do
            (tx, asked) <- everySettleableOver active (chainOf mixedPending)
            let spent = inputsOf tx
            forM_ settledRefs $ \ref -> (ref `Set.member` spent) `shouldBe` True
            forM_ leftRefs $ \ref -> (ref `Set.member` spent) `shouldBe` False
            let settled = [m | m@(ref, _) <- mixedPending, ref `elem` settledRefs]
            mintedOf tx `shouldBe` owedMint settled
            tx ^. bodyTxL . treasuryDonationTxBodyL
                `shouldBe` Coin (owedDonation settled)
            asked `shouldNotContain` [AtAddress requestAddr]
        it "folds the same requests from a trie manager as from a snapshot" $ do
            (fromSnapshot, _) <- everySettleableOver active (chainOf mixedPending)
            (fromManager, askedManager) <-
                managerOver active (chainOf mixedPending)
            inputsOf fromManager `shouldBe` inputsOf fromSnapshot
            mintedOf fromManager `shouldBe` mintedOf fromSnapshot
            fromManager ^. bodyTxL . treasuryDonationTxBodyL
                `shouldBe` fromSnapshot ^. bodyTxL . treasuryDonationTxBodyL
            askedManager `shouldNotContain` [AtAddress requestAddr]
        it "names every pending request it cannot fold when none can" $ do
            let members =
                    [ (reqIn3, taggedTermination key3)
                    , (reqIn4, taggedRegistration key4 submitted4)
                    ]
            result <- refusedWith (everySettleableOver [key4] (chainOf members))
            case result of
                Left err -> do
                    err `shouldSatisfy` isInfixOf "key-unknown"
                    err `shouldSatisfy` isInfixOf "key-exists"
                    err `shouldSatisfy` isInfixOf (show reqIn3)
                    err `shouldSatisfy` isInfixOf (show reqIn4)
                Right _ ->
                    expectationFailure
                        "a pending set no request of which can fold built a fold"
        it "reports no pending requests when the complete listing is empty" $ do
            result <- refusedWith (everySettleableOver [] (chainOf []))
            case result of
                Left err -> err `shouldSatisfy` isInfixOf "no pending requests"
                Right _ -> expectationFailure "an empty pending set built a fold"
        it "folds at most the capacity bound and leaves the rest pending" $ do
            let many =
                    [ ( txIn 'c' i
                      , taggedRegistration
                            (BS.pack (map (fromIntegral . fromEnum) ("k" <> show i)))
                            (1_000 + toInteger i)
                      )
                    | i <- [0 .. 10]
                    ]
            (tx, _) <- everySettleableOver [] (chainOf many)
            let spent = inputsOf tx
                folded = [ref | (ref, _) <- many, ref `Set.member` spent]
            length folded `shouldBe` 9
            -- the first nine in the ledger's input order, the rest wait
            folded `shouldBe` take 9 (sort (map fst many))
    describe
        "the final body the ledger would accept, through the public path"
        $ do
            let params = withSyntheticCosts Fixture.preprodParams
                -- the least lovelace an output may hold under the parameters
                least out = go 0
                  where
                    go c =
                        let Coin needed = getMinCoinTxOut params (out & coinTxOutL .~ Coin c)
                        in  if needed <= c then c else go needed
                holdsKey key out = case out ^. valueTxOutL of
                    MaryValue _ (MultiAsset assets) ->
                        maybe
                            False
                            (Map.member (AssetName (SBS.toShort key)))
                            (Map.lookup (policyIdFromPin (cfgActivePolicy cfg)) assets)
                carrierAt key coin =
                    mkBasicTxOut
                        payer
                        ( MaryValue
                            (Coin coin)
                            ( MultiAsset
                                ( Map.singleton
                                    (policyIdFromPin (cfgActivePolicy cfg))
                                    (Map.singleton (AssetName (SBS.toShort key)) 1)
                                )
                            )
                        )
                -- a booked registration of the registry that charges nothing to register, so
                -- the fold donates nothing: the request declares the cost zero that the
                -- configuration and the registry's state declare, and holds exactly its cost,
                -- its tip and its declared carrier
                free key carrier =
                    ( reqIn1
                    , registrationOutput
                        (registrationOf key submitted1)
                            { regRegistrationCost = 0
                            , regCarrierAda = carrier
                            }
                    )
                freeChain requests = (chainOf requests){configured = cfgFree}
                -- the fixture is the lawful booking it stands for: cost as configured, exact contents
                lawfulFree booking = case bookedRequestOf cfgFree tokenId booking of
                    Just (BookedRegistration r) -> do
                        Coin (regRegistrationCost r)
                            `shouldBe` defaultRegistrationCost cfgFree
                        let Coin held = booking ^. coinTxOutL
                        held
                            `shouldBe` regRegistrationCost r + regDeclaredTip r + regCarrierAda r
                    _ ->
                        expectationFailure
                            "the free registration is not a booked request of the registry"
                outputsOf tx = foldr (:) [] (tx ^. bodyTxL . outputsTxBodyL)
            it
                "folds a registration that costs nothing with its carrier at exactly its minimum, and refuses one lovelace less, and none"
                $ do
                    let m = least (carrierAt key1 0)
                    lawfulFree (snd (free key1 m))
                    (tx, _) <- selectedOver [] (freeChain [free key1 m]) (reqIn1 :| [])
                    tx ^. bodyTxL . treasuryDonationTxBodyL `shouldBe` Coin 0
                    -- the booked allocation reaches the destination exactly
                    [o ^. coinTxOutL | o <- outputsOf tx, holdsKey key1 o]
                        `shouldBe` [Coin m]
                    forM_ [m - 1, 0] $ \short -> do
                        lawfulFree (snd (free key1 short))
                        result <-
                            refusedWith
                                (selectedOver [] (freeChain [free key1 short]) (reqIn1 :| []))
                        case result of
                            Left err -> do
                                err `shouldSatisfy` isInfixOf "the carrier of the registration of key"
                                err `shouldSatisfy` isInfixOf ("holds " <> show short <> " lovelace")
                                err
                                    `shouldSatisfy` isInfixOf "booked allocation is exact and unchanged"
                            Right _ ->
                                expectationFailure
                                    ("a carrier of " <> show short <> " lovelace built a fold")
            it
                "keeps the change of a fold that donates nothing at its minimum, and refuses it a step under"
                $ do
                    let request = free key1 1_500_000
                        booked = case bookedRequestOf cfgFree tokenId (snd request) of
                            Just b -> [(fst request, b)]
                            Nothing -> error "the free registration is not a booked request"
                        mints = either error id (taggedMints cfgFree ctx0 booked)
                        -- the booking holds exactly what it declares; the caller pays an attached
                        -- output from the folder's own funding, which sizes the one thing left,
                        -- the folder's change
                        direct attached = do
                            rig <- rigWith []
                            asked <- newIORef []
                            fst
                                <$> connectedFoldTx
                                    ConnectedFoldArgs
                                        { cfaCfg = cfgFree
                                        , cfaSession = viewOver asked (rigRoot rig) (freeChain [request])
                                        , cfaTrie = rigManager rig
                                        , cfaToken = tokenId
                                        , cfaFeeAddr = payer
                                        , cfaStateUtxo = (stateIn, stateOutFor cfgFree (rigRoot rig))
                                        , cfaReqUtxos = [request]
                                        , cfaFeeUtxo = (feeIn, feeOut)
                                        , cfaSpends = []
                                        , cfaMints = mints
                                        , cfaOutputs = [mkBasicTxOut payer (MaryValue (Coin attached) mempty)]
                                        , cfaSigners = []
                                        , cfaRefUtxos = []
                                        , cfaAttachScripts = []
                                        , cfaSkipEval = False
                                        , cfaAdjustRoot = id
                                        }
                        changeOf tx = case reverse (outputsOf tx) of
                            change : _ -> change
                            [] -> error "no output"
                    lawfulFree (snd request)
                    wide <- direct 1_000_000
                    wide ^. bodyTxL . treasuryDonationTxBodyL `shouldBe` Coin 0
                    let Coin wideChange = changeOf wide ^. coinTxOutL
                        changeMinimum = least (changeOf wide)
                        attachedFor delta = 1_000_000 + wideChange - (changeMinimum + delta)
                    enough <- direct (attachedFor 1_000)
                    changeOf enough ^. coinTxOutL `shouldSatisfy` (>= Coin changeMinimum)
                    result <- refusedWith (direct (attachedFor (-1_000)))
                    case result of
                        Left err -> err `shouldSatisfy` isInfixOf "the folder's change holds"
                        Right _ -> expectationFailure "a change under its minimum built a fold"
    describe "what discovery sees" $ do
        let pollution =
                [ ( txIn 'd' i
                  , mkBasicTxOut
                        requestAddr
                        (MaryValue (Coin (2_000_000 + toInteger i)) mempty)
                  )
                | i <- [0 .. 3]
                ]
                    <> [
                           ( txIn 'd' 9
                           , mkBasicTxOut requestAddr (MaryValue (Coin 10_000_000) mempty)
                                & datumTxOutL
                                    .~ mkInlineDatum
                                        ( mkRequestDatumWith
                                            tokenId
                                            payer
                                            key6
                                            1
                                            2_000_000
                                            submitted1
                                            (serialiseAddr payer, Nothing)
                                        )
                           )
                       ]
        it
            "is not changed by untagged and legacy outputs at the request address"
            $ do
                (clean, askedClean) <-
                    selectedOver [] (chainOf pendingReqs) (reqIn1 :| [reqIn2])
                (polluted, askedPolluted) <-
                    selectedOver
                        []
                        ((chainOf pendingReqs){atRequestAddress = pendingReqs <> pollution})
                        (reqIn1 :| [reqIn2])
                polluted `shouldBe` clean
                askedClean `shouldNotContain` [AtAddress requestAddr]
                askedPolluted `shouldNotContain` [AtAddress requestAddr]
                -- the listing is the request policy's, asked for once
                length
                    [ q
                    | q@(HoldingPolicy p) <- askedPolluted
                    , p == requestPolicyOf cfg tokenId
                    ]
                    `shouldBe` 1
        it "never chooses a legacy request left at the request address" $ do
            let legacyIn = txIn 'd' 9
            result <-
                refusedWith
                    ( selectedOver
                        []
                        ((chainOf pendingReqs){atRequestAddress = pendingReqs <> pollution})
                        (legacyIn :| [])
                    )
            case result of
                Left err -> do
                    err `shouldSatisfy` isInfixOf "selected requests not pending"
                    err `shouldSatisfy` isInfixOf (show legacyIn)
                Right _ ->
                    expectationFailure "a legacy untagged request was folded as a member"
        it
            "finds no pending request when only the request address holds outputs"
            $ do
                result <-
                    refusedWith
                        ( everySettleableOver
                            []
                            ((chainOf []){atRequestAddress = pendingReqs <> pollution})
                        )
                case result of
                    Left err -> err `shouldSatisfy` isInfixOf "no pending requests"
                    Right _ ->
                        expectationFailure
                            "outputs read from the request address built a fold"
        it
            "fails with the listing's own failure, never from the request address"
            $ do
                rig <- rigWith []
                asked <- newIORef []
                let polluted = (chainOf pendingReqs){atRequestAddress = pendingReqs <> pollution}
                    healthy = viewOver asked (rigRoot rig) polluted
                    failing =
                        healthy
                            { outputs = \case
                                HoldingPolicy _ ->
                                    pure (Left (BackendReadFailure "page refused"))
                                other -> outputs healthy other
                            }
                forM_
                    [
                        ( "a snapshot fold of every request"
                        , updateTokenWithTrieState
                            cfg
                            failing
                            (rigSnapshot rig)
                            tokenId
                            payer
                            ctx0
                        )
                    ,
                        ( "a snapshot fold of a chosen request"
                        , updateTokenSelected
                            cfg
                            failing
                            (rigSnapshot rig)
                            tokenId
                            payer
                            ctx0
                            (reqIn1 :| [])
                        )
                    ,
                        ( "a manager fold"
                        , updateTokenWithDuties cfg failing (rigManager rig) tokenId payer ctx0
                        )
                    ]
                    $ \(what, build) -> do
                        result <- refusedWith build
                        case result of
                            Left err ->
                                (what, err)
                                    `shouldSatisfy` isInfixOf "page refused" . snd
                            Right _ ->
                                expectationFailure (what <> " built from a failed listing")
                readIORef asked >>= (`shouldNotContain` [AtAddress requestAddr])
    describe "the selected snapshot's obligations" $ do
        let build rig = do
                asked <- newIORef []
                updateTokenSelected
                    cfg
                    (viewOver asked (rigRoot rig) (chainOf pendingReqs))
                    (rigSnapshot rig)
                    tokenId
                    payer
                    ctx0
                    (reqIn1 :| [])
        it "refuses the snapshot of another registry" $ do
            rig <- rigAt (TokenId (AssetName "another registry")) stateIn []
            result <- refusedWith (build rig)
            case result of
                Left err -> err `shouldSatisfy` isInfixOf "TrieState WrongRegistry"
                Right _ -> expectationFailure "a snapshot of another registry built a fold"
        it "refuses a snapshot taken at another state output" $ do
            rig <- rigAt tokenId (txIn 'b' 7) []
            result <- refusedWith (build rig)
            case result of
                Left err -> err `shouldSatisfy` isInfixOf "TrieState StaleState"
                Right _ -> expectationFailure "a stale snapshot built a fold"
        it "refuses a snapshot whose root is not the state output's root" $ do
            rig <- rigWith [key6]
            asked <- newIORef []
            -- the state output on the chain still carries the empty root
            result <-
                refusedWith
                    ( updateTokenSelected
                        cfg
                        (viewOver asked (Root emptyRoot) (chainOf pendingReqs))
                        (rigSnapshot rig)
                        tokenId
                        payer
                        ctx0
                        (reqIn1 :| [])
                    )
            case result of
                Left err -> err `shouldSatisfy` isInfixOf "TrieState StaleState"
                Right _ -> expectationFailure "a snapshot at another root built a fold"
    describe "the connected fold's own checks, with evaluation skipped" $ do
        let buildSkipFold reqs refs mints = do
                asked <- newIORef []
                rig <- rigWith []
                let view = viewOver asked (rigRoot rig) (chainOf reqs)
                connectedFoldTx
                    ConnectedFoldArgs
                        { cfaCfg = cfg
                        , cfaSession = view
                        , cfaTrie = rigManager rig
                        , cfaToken = tokenId
                        , cfaFeeAddr = payer
                        , cfaStateUtxo = (stateIn, stateOutAt (rigRoot rig))
                        , cfaReqUtxos = [u | u@(r, _) <- reqs, r `elem` refs]
                        , cfaFeeUtxo = (feeIn, feeOut)
                        , cfaSpends = []
                        , cfaMints = mints
                        , cfaOutputs = []
                        , cfaSigners = []
                        , cfaRefUtxos = []
                        , cfaAttachScripts = []
                        , cfaSkipEval = True
                        , cfaAdjustRoot = id
                        }
            mintFor key qty =
                ConnectedMint
                    { cmPolicy = policyIdFromPin (cfgActivePolicy cfg)
                    , cmAssets = Map.singleton (AssetName (SBS.toShort key)) qty
                    , cmRedeemer = RawRedeemer (PLC.Constr 0 [])
                    , cmScript = Fixture.applicationScript
                    }
        it "refuses a keyed mint mismatch before the pair" $ do
            result <-
                refusedWith
                    (buildSkipFold pendingSkipMint [reqIn9, reqIn10, reqIn11] [])
            case result of
                Left err -> err `shouldSatisfy` isInfixOf "net-mint-mismatch"
                Right _ ->
                    expectationFailure
                        "an unbalanced batch beside a created pair built a fold"
        it "reaches the pair on a cancelling delta with no mints" $ do
            result <-
                refusedWith (buildSkipFold pendingTaggedPair [reqIn5, reqIn6] [])
            case result of
                Left err -> err `shouldSatisfy` isInfixOf "key-in-batch"
                Right _ ->
                    expectationFailure "a cancelling delta with no mints built a fold"
        it "reaches the pair beside a funded insertion" $ do
            result <-
                refusedWith
                    ( buildSkipFold
                        pendingSkipMint
                        [reqIn9, reqIn10, reqIn11]
                        [mintFor key6 1]
                    )
            case result of
                Left err -> err `shouldSatisfy` isInfixOf "key-in-batch"
                Right _ ->
                    expectationFailure "a funded batch beside a created pair built a fold"
        it "ignores a foreign-policy mint beside a funded insertion" $ do
            result <-
                refusedWith
                    ( buildSkipFold
                        pendingSkipSingle
                        [reqIn12]
                        [mintFor key7 1, unrelatedMint]
                    )
            case result of
                Left err ->
                    expectationFailure
                        ( "a funded insertion with an attached mint was refused: "
                            <> err
                        )
                Right _ -> pure ()
        it "reaches the pair with an attached foreign mint" $ do
            result <-
                refusedWith
                    (buildSkipFold pendingTaggedPair [reqIn5, reqIn6] [unrelatedMint])
            case result of
                Left err -> err `shouldSatisfy` isInfixOf "key-in-batch"
                Right _ ->
                    expectationFailure "a created pair with an attached mint built a fold"
