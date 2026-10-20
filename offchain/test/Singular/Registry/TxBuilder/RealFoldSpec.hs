{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.Registry.TxBuilder.RealFoldSpec
Description : The fold of booked requests, judged by the retained state and request validators
License     : Apache-2.0

The folds that 'Singular.Registry.TxBuilder.ConnectedFoldSpec' builds, over the
registry's actual compiled programs. The state validator and the request
validator are the ones of the retained blueprint, applied as the registry's
boot applies them, with the pins that boot derives; the application and
witness policies, which only mint and burn the tags a member moves, are toy
programs that accept (their pins are those of the toy programs). So the
purposes that run real code are the state's spend (the fold decision: members,
trie, tags, carriers, donation, balance) and every member's spend and the
request-policy burn (the request validator); the application burn and the
singular mint run toy code.

A fold is built by the production builder, which evaluates the scripts while it
builds and once more on the final body: a built fold is a fold the real
programs accept. The rows judge the built body again with the ledger's own
evaluator and name each purpose. The chain view is a stub with a synthetic
ledger and the cost model of the synthetic defaults, so what these rows
establish is the observed offline behavior of the validators on bodies the
library builds: script evaluation, not ledger inclusion; not a deployment, not
a live ledger, and not the consent of a protected application, whose custody
is out of scope here.

The discriminators take a body the builder accepted and change it in one
coherent way, keeping the real programs: the donation moved by one lovelace
(with the folder's change moved the other way, so that lovelace stays
conserved), and the state's proofs emptied. Each is refused, and the refusal
is the state's spend alone.
-}
module Singular.Registry.TxBuilder.RealFoldSpec (spec) where

import Control.Monad (forM_)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Short qualified as SBS
import Data.Foldable (toList)
import Data.List (sort)
import Data.Map.Strict qualified as Map
import Data.Maybe (mapMaybe)
import Data.Sequence.Strict qualified as StrictSeq
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Word (Word32)
import Lens.Micro ((%~), (&), (.~), (^.))
import PlutusCore.Data qualified as PLC
import PlutusCore.Default (DefaultFun (..), DefaultUni)
import PlutusCore.MkPlc (mkConstant)
import PlutusCore.Version (plcVersion110)
import PlutusLedgerApi.V3 qualified as PLCV3
import PlutusTx.Builtins.Internal (BuiltinByteString (..))
import Test.Hspec
import UntypedPlutusCore qualified as UPLC

import Cardano.Ledger.Address (Addr (..))
import Cardano.Ledger.Alonzo.Plutus.Evaluate (evalTxExUnits)
import Cardano.Ledger.Alonzo.Scripts (AsIx (..))
import Cardano.Ledger.Api.Scripts.Data (Data (..))
import Cardano.Ledger.Api.Tx (bodyTxL, estimateMinFeeTx, witsTxL)
import Cardano.Ledger.Api.Tx.Body
    ( feeTxBodyL
    , inputsTxBodyL
    , mintTxBodyL
    , outputsTxBodyL
    , scriptIntegrityHashTxBodyL
    , treasuryDonationTxBodyL
    )
import Cardano.Ledger.Api.Tx.Out
    ( TxOut
    , addrTxOutL
    , coinTxOutL
    , datumTxOutL
    , mkBasicTxOut
    )
import Cardano.Ledger.Api.Tx.Wits
    ( Redeemers (..)
    , rdmrsTxWitsL
    )
import Cardano.Ledger.BaseTypes (Network (Testnet))
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Conway.Scripts (ConwayPlutusPurpose (..))
import Cardano.Ledger.Core (Script, hashScript)
import Cardano.Ledger.Credential (Credential (..))
import Cardano.Ledger.Hashes (ScriptHash)
import Cardano.Ledger.Mary.Value
    ( AssetName (..)
    , MaryValue (..)
    , MultiAsset (..)
    , PolicyID (..)
    )
import Cardano.Ledger.Plutus.ExUnits (ExUnits (..))
import Cardano.Ledger.State (UTxO (..))
import Cardano.Ledger.TxIn (TxIn)
import Cardano.Slotting.Slot (SlotNo (..))
import Cardano.Tx.Ledger (ConwayTx)

import Singular.Registry.Blueprint (NamingCodes (..))
import Singular.Registry.Config
    ( CageConfig (..)
    , bootStateFromCfg
    )
import Singular.Registry.Deployment (parseOutRef)
import Singular.Registry.Evidence (NoWitness)
import Singular.Registry.Ledger
    ( ConwayEra
    , PParams
    , Root (..)
    , TokenId (..)
    )
import Singular.Registry.LedgerProvider (Session, TipObservation (..))
import Singular.Registry.NetworkTime
    ( networkEpochInfo
    , networkSystemStart
    )
import Singular.Registry.StubSession
import Singular.Registry.SyntheticLedger
    ( unitProgram
    , withSyntheticCosts
    )
import Singular.Registry.SyntheticTime (syntheticTime)
import Singular.Registry.Trie (Trie (getRoot), TrieManager (..))
import Singular.Registry.Trie.PureManager (mkPureTrieManagerFrom)
import Singular.Registry.TxBuilder.BookingFixture
    ( RetainedRegistry (..)
    , loadRetained
    )
import Singular.Registry.TxBuilder.BookingFixture qualified as Fixture
import Singular.Registry.TxBuilder.ConnectedFold
    ( ConnectedFoldArgs (..)
    , ConnectedMint (..)
    , RawRedeemer (..)
    , connectedFoldTx
    )
import Singular.Registry.TxBuilder.Edges
    ( namingPins
    , registryIdOf
    , witnessScriptOf
    )
import Singular.Registry.TxBuilder.Internal
    ( cageAddrFromCfg
    , cagePolicyIdFromCfg
    , computeScriptIntegrity
    , mkCageScript
    , mkInlineDatum
    , mkRequestScript
    , policyIdFromPin
    , requestAddrFromCfg
    , requestPolicyOf
    , scriptFromBytes
    , toPlcData
    , walkEdge
    )
import Singular.Registry.TxBuilder.Update
    ( RegistryContext (..)
    , emptyRegistryContext
    , updateTokenWithDuties
    )
import Singular.Registry.Types
    ( CageDatum (..)
    , OnChainRegistrationRequest (..)
    , OnChainRoot (..)
    , OnChainTokenId (..)
    , RequestAction (..)
    , UpdateRedeemer (..)
    , applicationTagName
    , edgeInsertActive
    , trieReadyTagName
    )

-- ---------------------------------------------------------
-- The registry: real state and request programs, toy naming programs
-- ---------------------------------------------------------

-- | The toy programs that stand for the application and witness policies.
toyCodes :: NamingCodes
toyCodes =
    NamingCodes
        { ncApplication = unitProgram 1
        , ncWitness = unitProgram 3
        }

{- | A toy V3 policy whose cost follows the transaction's fee: it reads the fee
from its script context and writes a zero of a width given by the fee plus an
offset, modulo 8000. It accepts whatever it is shown, so only the units it
costs depend on the body: a body whose fee moves after the scripts were
measured needs different units.
-}
feeSensitiveProgram :: Integer -> SBS.ShortByteString
feeSensitiveProgram offset =
    PLCV3.serialiseUPLC . UPLC.Program () plcVersion110 $
        UPLC.LamAbs () (UPLC.DeBruijn 0) body
  where
    body =
        app
            (UPLC.LamAbs () (UPLC.DeBruijn 0) (mkConstant () ()))
            (app (builtin LengthOfByteString) bytes)
    bytes =
        app
            (app (app (builtin IntegerToByteString) (mkConstant () True)) count)
            (integer 0)
    count =
        app
            ( app
                (builtin ModInteger)
                (app (app (builtin AddInteger) fee) (integer offset))
            )
            (integer 8000)
    -- the script context, its transaction info, and the fee: field 3 of it
    ctx = UPLC.Var () (UPLC.DeBruijn 1)
    fields term =
        app
            (force (force (builtin SndPair)))
            (app (builtin UnConstrData) term)
    first = app (force (builtin HeadList))
    rest = app (force (builtin TailList))
    fee =
        app
            (builtin UnIData)
            (first (rest (rest (rest (fields (first (fields ctx)))))))
    app = UPLC.Apply ()
    force = UPLC.Force ()
    builtin = UPLC.Builtin ()
    integer :: Integer -> UPLC.Term UPLC.DeBruijn DefaultUni DefaultFun ()
    integer = mkConstant ()

-- | The naming programs of the registry in which the application's burn follows the fee.
feeSensitiveCodes :: Integer -> NamingCodes
feeSensitiveCodes offset =
    NamingCodes
        { ncApplication = feeSensitiveProgram offset
        , ncWitness = unitProgram 3
        }

-- | Everything a row needs of the registry the retained blueprint boots.
data World = World
    { wCfg :: CageConfig
    , wToken :: TokenId
    , wActiveId :: PolicyID
    , wApplicationId :: PolicyID
    , wRequestId :: PolicyID
    , wActiveScript :: Script ConwayEra
    , wApplicationScript :: Script ConwayEra
    , wRegistryName :: ByteString
    }

{- | The registry the retained blueprint boots from the fixture seed, with the
naming pins of the toy programs. The state and request programs and every
pin that does not name a toy policy are the boot's own.
-}
worldOf :: RetainedRegistry -> World
worldOf = worldWith toyCodes

-- | The same registry with other programs for the naming policies.
worldWith :: NamingCodes -> RetainedRegistry -> World
worldWith codes r =
    World
        { wCfg = cfg
        , wToken = rrToken r
        , wActiveId = policyIdFromPin (cfgActivePolicy cfg)
        , wApplicationId = policyIdFromPin (cfgApplicationPolicy cfg)
        , wRequestId = requestPolicyOf cfg (rrToken r)
        , wActiveScript = witnessScriptOf cfg codes 1
        , wApplicationScript =
            scriptFromBytes "application" (ncApplication codes)
        , wRegistryName = case unTokenId (rrToken r) of
            AssetName n -> SBS.fromShort n
        }
  where
    booted = rrConfig r
    (applicationPin, absentPin, activePin, terminalPin) =
        namingPins codes (registryIdOf booted)
    cfg =
        booted
            { cfgApplicationPolicy = applicationPin
            , cfgAbsentPolicy = absentPin
            , cfgActivePolicy = activePin
            , cfgTerminalPolicy = terminalPin
            }

unhex :: ByteString -> ByteString
unhex = either (error . ("unhex: " <>)) id . B16.decode

nameOf :: ByteString -> AssetName
nameOf = AssetName . SBS.toShort

-- | The key of the registration and the key of the termination.
registrationKey, terminationKey :: ByteString
registrationKey = "registered-key"
terminationKey = unhex "6b657942"

{- | The trie-ready tag of the termination of that key, empty destination, nonce
1: written by @termination_tag_vectors.py@ by an independent route, as in
the unit rows.
-}
terminationTag :: ByteString
terminationTag =
    unhex
        "054c1c37bccb9747e1b4e0b76a7ddd96daf15b06d109654eecab7cde86b02e8a"

registrationOf :: World -> OnChainRegistrationRequest
registrationOf w =
    OnChainRegistrationRequest
        { regRegistry = OnChainTokenId (BuiltinByteString (wRegistryName w))
        , regKey = registrationKey
        , regRefundAddress = BuiltinByteString (BS.replicate 28 0xd1)
        , regDestination = BS.cons 0x60 (BS.replicate 28 0x77)
        , regDatum = Just (PLC.I 7)
        , regSubmittedAt = 5_000_000
        , regRegistrationCost = 2_000_000
        , regDeclaredTip = 1_500_000
        , regCarrierAda = 1_500_000
        , regNonce = 5
        }

registrationApplicationTag :: OnChainRegistrationRequest -> ByteString
registrationApplicationTag r =
    applicationTagName
        (regKey r)
        (regRefundAddress r)
        (regDestination r)
        (regNonce r)

-- | The booked registration, holding both of its tags.
registrationOut :: World -> TxOut ConwayEra
registrationOut w =
    mkBasicTxOut
        (requestAddrFromCfg (wCfg w) (wToken w) Testnet)
        ( MaryValue
            (Coin 5_000_000)
            ( MultiAsset
                ( Map.fromList
                    [ (wRequestId w, Map.singleton (nameOf (trieReadyTagName r)) 1)
                    ,
                        ( wApplicationId w
                        , Map.singleton (nameOf (registrationApplicationTag r)) 1
                        )
                    ]
                )
            )
        )
        & datumTxOutL .~ mkInlineDatum (toPlcData (RegistrationDatum r))
  where
    r = registrationOf w

-- | The booked termination of the active key, holding the key's singular tag and its trie-ready tag.
terminationOut :: World -> TxOut ConwayEra
terminationOut w =
    mkBasicTxOut
        (requestAddrFromCfg (wCfg w) (wToken w) Testnet)
        ( MaryValue
            (Coin 4_000_000)
            ( MultiAsset
                ( Map.fromList
                    [ (wRequestId w, Map.singleton (nameOf terminationTag) 1)
                    , (wActiveId w, Map.singleton (nameOf terminationKey) 1)
                    ]
                )
            )
        )
        & datumTxOutL
            .~ mkInlineDatum
                ( PLC.Constr
                    4
                    [ PLC.Constr
                        0
                        [ PLC.Constr 0 [PLC.B (wRegistryName w)]
                        , PLC.B terminationKey
                        , PLC.B BS.empty
                        , PLC.I 1_500_000
                        , PLC.I 2_500_000
                        , PLC.I 1
                        ]
                    ]
                )

outRef :: Char -> Int -> TxIn
outRef c i =
    either
        (error . ("RealFoldSpec fixture: " <>))
        id
        (parseOutRef (T.pack (replicate 64 c <> "#" <> show i)))

stateRef, feeRef, registrationRef, terminationRef :: TxIn
stateRef = outRef 'b' 0
feeRef = outRef 'e' 0
registrationRef = outRef 'a' 0
terminationRef = outRef 'a' 1

payer :: Addr
payer = Fixture.payer

feeOut :: TxOut ConwayEra
feeOut = mkBasicTxOut payer (MaryValue (Coin 100_000_000) mempty)

-- | A trie that already holds the termination's key as active, and its root.
worldTrie :: World -> IO (TrieManager IO, Root)
worldTrie w = do
    (manager, _) <- mkPureTrieManagerFrom Map.empty
    createTrie manager (wToken w)
    root <- withTrie manager (wToken w) $ \trie -> do
        _ <- walkEdge trie terminationKey edgeInsertActive
        getRoot trie
    pure (manager, root)

stateOutAt :: World -> Root -> TxOut ConwayEra
stateOutAt w root =
    mkBasicTxOut
        (cageAddrFromCfg (wCfg w) Testnet)
        ( MaryValue
            (Coin 2_000_000)
            ( MultiAsset
                ( Map.singleton
                    (cagePolicyIdFromCfg (wCfg w))
                    (Map.singleton (unTokenId (wToken w)) 1)
                )
            )
        )
        & datumTxOutL
            .~ mkInlineDatum
                ( toPlcData
                    (StateDatum (bootStateFromCfg (wCfg w) (OnChainRoot (unRoot root))))
                )

-- ---------------------------------------------------------
-- The view and the fold
-- ---------------------------------------------------------

ledgerParameters :: PParams ConwayEra
ledgerParameters = withSyntheticCosts Fixture.preprodParams

-- | The view: the tip inside the registration's window, every output resolvable.
viewOver
    :: World -> Root -> [(TxIn, TxOut ConwayEra)] -> Session NoWitness IO
viewOver w root requests =
    withTip (TipObservation (SlotNo 5_005) (BS.replicate 32 0) 1 0) $
        withAddressOutputs
            ( \a ->
                pure $
                    if a == requestAddrFromCfg (wCfg w) (wToken w) Testnet
                        then requests
                        else
                            if a == cageAddrFromCfg (wCfg w) Testnet
                                then [(stateRef, stateOutAt w root)]
                                else [(feeRef, feeOut)]
            )
            ( withParameters ledgerParameters $
                withTime (pure syntheticTime) $
                    withResolvedOutputs
                        ( \wanted ->
                            pure
                                [ (ref, o)
                                | (ref, o) <-
                                    (stateRef, stateOutAt w root) : (feeRef, feeOut) : requests
                                , ref `Set.member` wanted
                                ]
                        )
                        stubSession
            )

-- | The registration's application tag burn.
applicationBurn :: World -> ConnectedMint
applicationBurn w =
    ConnectedMint
        { cmPolicy = wApplicationId w
        , cmAssets =
            Map.singleton
                (nameOf (registrationApplicationTag (registrationOf w)))
                (-1)
        , cmRedeemer = RawRedeemer (PLC.Constr 0 [])
        , cmScript = wApplicationScript w
        }

-- | The singular moves of the selected members.
activeMint :: World -> [(ByteString, Integer)] -> ConnectedMint
activeMint w moved =
    ConnectedMint
        { cmPolicy = wActiveId w
        , cmAssets = Map.mapKeys nameOf (Map.fromList moved)
        , cmRedeemer = RawRedeemer (PLC.Constr 0 [])
        , cmScript = wActiveScript w
        }

-- | One shape of fold: the members it folds and the mints the caller attaches for exactly them.
data Shape = Shape
    { shapeName :: String
    , shapeMembers :: World -> [(TxIn, TxOut ConwayEra)]
    , shapeMints :: World -> [ConnectedMint]
    }

mixed, registrationAlone, terminationAlone :: Shape
mixed =
    Shape
        "both members"
        ( \w ->
            [ (registrationRef, registrationOut w)
            , (terminationRef, terminationOut w)
            ]
        )
        ( \w ->
            [ applicationBurn w
            , activeMint w [(registrationKey, 1), (terminationKey, -1)]
            ]
        )
registrationAlone =
    Shape
        "the registration alone"
        (\w -> [(registrationRef, registrationOut w)])
        (\w -> [applicationBurn w, activeMint w [(registrationKey, 1)]])
terminationAlone =
    Shape
        "the termination alone"
        (\w -> [(terminationRef, terminationOut w)])
        (\w -> [activeMint w [(terminationKey, -1)]])

-- | The fold of a shape, built by the production builder with the scripts evaluated.
built :: World -> Shape -> IO (ConwayTx, [(TxIn, TxOut ConwayEra)])
built w shape = do
    (manager, root) <- worldTrie w
    let requests = shapeMembers shape w
        state = stateOutAt w root
    (tx, _) <-
        connectedFoldTx
            ConnectedFoldArgs
                { cfaCfg = wCfg w
                , cfaSession = viewOver w root requests
                , cfaTrie = manager
                , cfaToken = wToken w
                , cfaFeeAddr = payer
                , cfaStateUtxo = (stateRef, state)
                , cfaReqUtxos = requests
                , cfaFeeUtxo = (feeRef, feeOut)
                , cfaSpends = []
                , cfaMints = shapeMints shape w
                , cfaOutputs = []
                , cfaSigners = []
                , cfaRefUtxos = []
                , cfaAttachScripts = []
                , cfaSkipEval = False
                , cfaAdjustRoot = id
                }
    pure (tx, (stateRef, state) : (feeRef, feeOut) : requests)

{- | What the ledger's evaluator says of every script purpose of a body over its
inputs: the units it measured, or the failure.
-}
judged
    :: [(TxIn, TxOut ConwayEra)]
    -> ConwayTx
    -> Map.Map (ConwayPlutusPurpose AsIx ConwayEra) (Either String ExUnits)
judged inputs tx =
    Map.map
        (either (Left . show) Right)
        ( evalTxExUnits
            ledgerParameters
            tx
            (UTxO (Map.fromList inputs))
            (networkEpochInfo syntheticTime)
            (networkSystemStart syntheticTime)
        )

failures :: Map.Map p (Either String ExUnits) -> [p]
failures judgments = [p | (p, Left _) <- Map.toList judgments]

-- | The index of an input among the body's inputs, which the ledger orders.
indexOf :: ConwayTx -> TxIn -> Word32
indexOf tx ref =
    fromIntegral
        ( length
            (takeWhile (/= ref) (Set.toAscList (tx ^. bodyTxL . inputsTxBodyL)))
        )

{- | The script a purpose of the body runs: a spend runs the script its input's
address names, a mint the script its policy is the hash of.
-}
scriptOf
    :: ConwayTx
    -> [(TxIn, TxOut ConwayEra)]
    -> ConwayPlutusPurpose AsIx ConwayEra
    -> Maybe ScriptHash
scriptOf tx inputs = \case
    ConwaySpending (AsIx i) -> do
        ref <-
            nth (fromIntegral i) (Set.toAscList (tx ^. bodyTxL . inputsTxBodyL))
        out <- lookup ref inputs
        case out ^. addrTxOutL of
            Addr _ (ScriptHashObj h) _ -> Just h
            _ -> Nothing
    ConwayMinting (AsIx i) -> do
        PolicyID h <- nth (fromIntegral i) (Map.keys minted)
        Just h
    _ -> Nothing
  where
    MultiAsset minted = tx ^. bodyTxL . mintTxBodyL
    nth n xs = case drop n xs of
        x : _ -> Just x
        [] -> Nothing

-- | Whether the body conserves lovelace: its inputs equal its outputs, its donation and its fee.
conserved :: [(TxIn, TxOut ConwayEra)] -> ConwayTx -> Bool
conserved inputs tx =
    sum
        [ c
        | i <- Set.toList (tx ^. bodyTxL . inputsTxBodyL)
        , Just o <- [lookup i inputs]
        , let Coin c = o ^. coinTxOutL
        ]
        == sum
            [ c
            | o <- toList (tx ^. bodyTxL . outputsTxBodyL)
            , let Coin c = o ^. coinTxOutL
            ]
            + (let Coin d = tx ^. bodyTxL . treasuryDonationTxBodyL in d)
            + (let Coin f = tx ^. bodyTxL . feeTxBodyL in f)

{- | The same body with its donation moved by some lovelace and the folder's
change, the last output, moved the other way: lovelace stays conserved, and
nothing else of the body changes.
-}
withDonationMoved :: Integer -> ConwayTx -> ConwayTx
withDonationMoved d tx =
    tx
        & bodyTxL . treasuryDonationTxBodyL %~ (\(Coin c) -> Coin (c + d))
        & bodyTxL . outputsTxBodyL %~ \case
            rest StrictSeq.:|> change
                | change ^. addrTxOutL == payer ->
                    rest
                        StrictSeq.:|> (change & coinTxOutL %~ (\(Coin c) -> Coin (c - d)))
            outs -> outs

{- | The same body with the state's action replaced by one update per member,
each with an empty proof: the root, the mint and every amount stay as built.
-}
withProofsEmptied :: ConwayTx -> ConwayTx
withProofsEmptied tx =
    tx & witsTxL . rdmrsTxWitsL %~ replaced
  where
    stated = ConwaySpending (AsIx (indexOf tx stateRef))
    Redeemers redeemers0 = tx ^. witsTxL . rdmrsTxWitsL
    members =
        length
            ( Map.keys
                (Map.filterWithKey (\p _ -> isSpend p && p /= stated) redeemers0)
            )
    isSpend = \case ConwaySpending _ -> True; _ -> False
    replaced (Redeemers rs) =
        Redeemers $
            Map.adjust
                ( \(_, units) ->
                    (Data (toPlcData (Modify (replicate members (Update [])))), units)
                )
                stated
                rs

-- | The units the body declares for each purpose.
declaredUnits
    :: ConwayTx -> Map.Map (ConwayPlutusPurpose AsIx ConwayEra) ExUnits
declaredUnits tx = Map.map snd redeemers
  where
    Redeemers redeemers = tx ^. witsTxL . rdmrsTxWitsL

{- | The same body with its fee moved by some lovelace and the folder's change,
the last output, moved the other way: lovelace stays conserved and nothing
else changes.
-}

{- | The purposes whose declared units fall short of those measured on the very
body that declares them, or that are declared without a measurement.
-}
uncovered
    :: Map.Map (ConwayPlutusPurpose AsIx ConwayEra) (Either String ExUnits)
    -> ConwayTx
    -> [String]
uncovered measured tx =
    concatMap one (Map.toList measured)
        <> [ show p <> ": declared without a measurement"
           | p <- Map.keys declared
           , Map.notMember p measured
           ]
  where
    declared = declaredUnits tx
    one (p, got) = case (got, Map.lookup p declared) of
        (Right (ExUnits m s), Just (ExUnits dm ds))
            | m <= dm && s <= ds -> []
            | otherwise ->
                [ show p
                    <> ": measured on the final body "
                    <> show (m, s)
                    <> ", declared "
                    <> show (dm, ds)
                ]
        other -> [show p <> ": " <> show other]

-- | The body with every declared memory budget one unit lower.
withDeclarationsShort :: ConwayTx -> ConwayTx
withDeclarationsShort =
    witsTxL . rdmrsTxWitsL %~ \(Redeemers r) ->
        Redeemers
            ( Map.map
                (\(d, ExUnits m s) -> (d, ExUnits (if m > 0 then m - 1 else 0) s))
                r
            )

withFeeMoved :: Integer -> ConwayTx -> ConwayTx
withFeeMoved d tx =
    tx
        & bodyTxL . feeTxBodyL %~ (\(Coin c) -> Coin (c + d))
        & bodyTxL . outputsTxBodyL %~ \case
            rest StrictSeq.:|> change
                | change ^. addrTxOutL == payer ->
                    rest
                        StrictSeq.:|> (change & coinTxOutL %~ (\(Coin c) -> Coin (c - d)))
            outs -> outs

-- ---------------------------------------------------------
-- The rows
-- ---------------------------------------------------------

spec :: Spec
spec =
    describe "chunk3 offchain" $
        describe "the fold over the retained state and request validators" $
            beforeAll loadRetained $ do
                it
                    "carries the retained state and request programs beside the toy naming programs"
                    $ \r -> do
                        let w = worldOf r
                            realState = hashScript (mkCageScript (wCfg w))
                            realRequest = hashScript (mkRequestScript (wCfg w) (wToken w))
                        -- the real programs are the ones the boot pinned
                        realState `shouldBe` cfgScriptHash (wCfg w)
                        PolicyID realRequest
                            `shouldBe` policyIdFromPin (cfgRequestPolicy (wCfg w))
                        -- the naming programs are the toy ones the pins name
                        PolicyID (hashScript (wApplicationScript w))
                            `shouldBe` wApplicationId w
                        PolicyID (hashScript (wActiveScript w)) `shouldBe` wActiveId w
                        (tx, inputs) <- built w mixed
                        let judgments = judged inputs tx
                        Map.size judgments `shouldBe` 6
                        sort (mapMaybe (scriptOf tx inputs) (Map.keys judgments))
                            `shouldBe` sort
                                [ realState
                                , realRequest
                                , realRequest
                                , realRequest
                                , hashScript (wApplicationScript w)
                                , hashScript (wActiveScript w)
                                ]
                forM_ [mixed, registrationAlone, terminationAlone] $ \shape ->
                    it
                        ( "builds the fold of "
                            <> shapeName shape
                            <> ", and the ledger's evaluator accepts every purpose of it"
                        )
                        $ \r -> do
                            let w = worldOf r
                            (tx, inputs) <- built w shape
                            conserved inputs tx `shouldBe` True
                            let judgments = judged inputs tx
                            Map.null judgments `shouldBe` False
                            failures judgments `shouldBe` []
                            forM_ (Map.elems judgments) $ \case
                                Right (ExUnits m s) -> (m > 0 && s > 0) `shouldBe` True
                                Left e -> expectationFailure e
                describe "the library entry path over the same validators" $ do
                    let entry w root requests manager =
                            updateTokenWithDuties
                                (wCfg w)
                                (withPolicyOutputs (\_ -> pure requests) (viewOver w root requests))
                                manager
                                (wToken w)
                                payer
                                emptyRegistryContext
                                    { rcWitnessScripts =
                                        Map.fromList
                                            [ (1, wActiveScript w)
                                            , (3, wApplicationScript w)
                                            ]
                                    }
                    it
                        "discovers the booked requests by the request policy and builds a fold the ledger's evaluator accepts at every purpose"
                        $ \r -> do
                            let w = worldOf r
                            (manager, root) <- worldTrie w
                            let requests = shapeMembers mixed w
                                inputs = (stateRef, stateOutAt w root) : (feeRef, feeOut) : requests
                            tx <- entry w root requests manager
                            conserved inputs tx `shouldBe` True
                            Map.size (judged inputs tx) `shouldBe` 6
                            failures (judged inputs tx) `shouldBe` []
                            -- the same members, the same mints, the same donation as the builder
                            (direct, _) <- built w mixed
                            tx ^. bodyTxL . inputsTxBodyL
                                `shouldBe` direct ^. bodyTxL . inputsTxBodyL
                            tx ^. bodyTxL . mintTxBodyL `shouldBe` direct ^. bodyTxL . mintTxBodyL
                            tx ^. bodyTxL . treasuryDonationTxBodyL
                                `shouldBe` direct ^. bodyTxL . treasuryDonationTxBodyL
                    it
                        "builds a body whose donation moved by one lovelace the real state validator refuses, at the state's spend alone"
                        $ \r -> do
                            let w = worldOf r
                            (manager, root) <- worldTrie w
                            let requests = shapeMembers mixed w
                                inputs = (stateRef, stateOutAt w root) : (feeRef, feeOut) : requests
                            tx <- entry w root requests manager
                            let variant = withDonationMoved 1 tx
                                stated = ConwaySpending (AsIx (indexOf tx stateRef))
                            failures (judged inputs tx) `shouldBe` []
                            conserved inputs variant `shouldBe` True
                            failures (judged inputs variant) `shouldBe` [stated]
                describe "a purpose whose cost follows the fee" $ do
                    let feeWorld = worldWith (feeSensitiveCodes 3_000)
                    it
                        "is run by the toy application policy and costs units that follow the body's fee"
                        $ \r -> do
                            let w = feeWorld r
                            (tx, inputs) <- built w registrationAlone
                            let application = hashScript (wApplicationScript w)
                                unitsOf body =
                                    [ (m, s)
                                    | (p, Right (ExUnits m s)) <- Map.toList (judged inputs body)
                                    , scriptOf body inputs p == Just application
                                    ]
                            failures (judged inputs tx) `shouldBe` []
                            length (unitsOf tx) `shouldBe` 1
                            -- the same body with its fee moved by a thousand lovelace
                            -- costs the application purpose different units
                            conserved inputs (withFeeMoved 1_000 tx) `shouldBe` True
                            unitsOf (withFeeMoved 1_000 tx) `shouldNotBe` unitsOf tx
                    it
                        "returns a fold whose declarations cover the units measured on that exact final body"
                        $ \r -> do
                            let w = feeWorld r
                            forM_ [registrationAlone, mixed] $ \shape -> do
                                (tx, inputs) <- built w shape
                                let measured = judged inputs tx
                                Map.null measured `shouldBe` False
                                (shapeName shape, uncovered measured tx)
                                    `shouldBe` (shapeName shape, [])
                    it
                        "reports a declaration one unit short of the units measured on its body"
                        $ \r -> do
                            let w = feeWorld r
                            (tx, inputs) <- built w registrationAlone
                            let short = withDeclarationsShort tx
                                measured = judged inputs short
                            -- the measurement does not depend on the declared units
                            measured `shouldBe` judged inputs tx
                            length (uncovered measured short)
                                `shouldBe` Map.size measured
                            Map.size measured `shouldSatisfy` (> 1)
                    it
                        "returns a body whose integrity hash, fee, change and minima agree with its declarations"
                        $ \r -> do
                            let w = feeWorld r
                            (tx, inputs) <- built w mixed
                            conserved inputs tx `shouldBe` True
                            tx ^. bodyTxL . scriptIntegrityHashTxBodyL
                                `shouldBe` computeScriptIntegrity ledgerParameters (tx ^. witsTxL . rdmrsTxWitsL)
                            -- the fee covers the ledger's own estimate for the body as declared
                            (tx ^. bodyTxL . feeTxBodyL)
                                `shouldSatisfy` (>= estimateMinFeeTx ledgerParameters tx 1 0 0)
                it
                    "refuses the fold of both members with its donation moved by one lovelace, at the state's spend alone"
                    $ \r -> do
                        let w = worldOf r
                        (tx, inputs) <- built w mixed
                        let variant = withDonationMoved 1 tx
                            stated = ConwaySpending (AsIx (indexOf tx stateRef))
                        -- the paired positive: the body as built is accepted whole
                        failures (judged inputs tx) `shouldBe` []
                        -- the variant is coherent: lovelace still conserved, nothing else moved
                        conserved inputs variant `shouldBe` True
                        variant ^. bodyTxL . treasuryDonationTxBodyL
                            `shouldNotBe` tx ^. bodyTxL . treasuryDonationTxBodyL
                        variant ^. bodyTxL . mintTxBodyL
                            `shouldBe` tx ^. bodyTxL . mintTxBodyL
                        variant ^. witsTxL . rdmrsTxWitsL
                            `shouldBe` tx ^. witsTxL . rdmrsTxWitsL
                        -- and it is the real state's spend that refuses it, no other purpose
                        failures (judged inputs variant) `shouldBe` [stated]
                it
                    "refuses the fold of both members with its state action's proofs emptied, at the state's spend alone"
                    $ \r -> do
                        let w = worldOf r
                        (tx, inputs) <- built w mixed
                        let variant = withProofsEmptied tx
                            stated = ConwaySpending (AsIx (indexOf tx stateRef))
                        failures (judged inputs tx) `shouldBe` []
                        variant ^. bodyTxL `shouldBe` tx ^. bodyTxL
                        variant ^. witsTxL . rdmrsTxWitsL
                            `shouldNotBe` tx ^. witsTxL . rdmrsTxWitsL
                        failures (judged inputs variant) `shouldBe` [stated]
