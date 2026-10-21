{-# LANGUAGE DataKinds #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}

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

import Control.Exception (SomeException, displayException, try)
import Control.Monad (forM_, when)
import Data.Bits (complement, shiftR, testBit, xor)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Lazy qualified as BSL
import Data.ByteString.Short qualified as SBS
import Data.Foldable (toList)
import Data.List (isInfixOf, sort)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromJust, mapMaybe)
import Data.Sequence.Strict qualified as StrictSeq
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Word (Word32, Word8)
import Lens.Micro ((%~), (&), (.~), (<>~), (^.))
import PlutusCore.Data qualified as PLC
import PlutusCore.Default (DefaultFun (..), DefaultUni)
import PlutusCore.MkPlc (mkConstant)
import PlutusCore.Version (plcVersion110)
import PlutusLedgerApi.V3 qualified as PLCV3
import PlutusTx.Builtins.Internal (BuiltinByteString (..))
import Test.Hspec
import UntypedPlutusCore qualified as UPLC

import Cardano.Ledger.Address
    ( Addr (..)
    , bootstrapAddressAttrsSize
    , decodeAddrEither
    , serialiseAddr
    )
import Cardano.Ledger.Allegra.Scripts (pattern RequireTimeStart)
import Cardano.Ledger.Alonzo.Plutus.Evaluate (evalTxExUnits)
import Cardano.Ledger.Alonzo.Scripts
    ( AsIx (..)
    , fromPlutusScript
    , mkPlutusScript
    )
import Cardano.Ledger.Api.PParams
    ( ppCollateralPercentageL
    , ppCostModelsL
    , ppMaxCollateralInputsL
    , ppMaxTxExUnitsL
    , ppMaxTxSizeL
    , ppMaxValSizeL
    , ppProtocolVersionL
    )
import Cardano.Ledger.Api.Scripts.Data
    ( Data (..)
    , Datum (..)
    , hashData
    )
import Cardano.Ledger.Api.Tx (bodyTxL, estimateMinFeeTx, witsTxL)
import Cardano.Ledger.Api.Tx.Body
    ( collateralInputsTxBodyL
    , collateralReturnTxBodyL
    , feeTxBodyL
    , inputsTxBodyL
    , mintTxBodyL
    , outputsTxBodyL
    , referenceInputsTxBodyL
    , scriptIntegrityHashTxBodyL
    , totalCollateralTxBodyL
    , treasuryDonationTxBodyL
    )
import Cardano.Ledger.Api.Tx.Out
    ( TxOut
    , addrTxOutL
    , coinTxOutL
    , datumTxOutL
    , getMinCoinTxOut
    , mkBasicTxOut
    , referenceScriptTxOutL
    , valueTxOutL
    )
import Cardano.Ledger.Api.Tx.Wits
    ( Redeemers (..)
    , TxDats (..)
    , datsTxWitsL
    , rdmrsTxWitsL
    , scriptTxWitsL
    )
import Cardano.Ledger.BaseTypes
    ( Network (Testnet)
    , ProtVer (..)
    , StrictMaybe (..)
    , mkVersion
    , pvMajor
    )
import Cardano.Ledger.Binary (serialize)
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Conway.PParams
    ( ConwayEraPParams (ppMaxRefScriptSizePerTxG)
    )
import Cardano.Ledger.Conway.Scripts (ConwayPlutusPurpose (..))
import Cardano.Ledger.Core
    ( Script
    , fromNativeScript
    , hashScript
    , sizeTxF
    )
import Cardano.Ledger.Credential
    ( Credential (..)
    , StakeReference (..)
    )
import Cardano.Ledger.Hashes (ScriptHash, originalBytes)
import Cardano.Ledger.Mary.Value
    ( AssetName (..)
    , MaryValue (..)
    , MultiAsset (..)
    , PolicyID (..)
    )
import Cardano.Ledger.Plutus.CostModels (emptyCostModels)
import Cardano.Ledger.Plutus.ExUnits (ExUnits (..))
import Cardano.Ledger.Plutus.Language
    ( Language (PlutusV2)
    , Plutus (..)
    , PlutusBinary (..)
    )
import Cardano.Ledger.State (UTxO (..))
import Cardano.Ledger.Tools (addDummyWitsTx)
import Cardano.Ledger.TxIn (TxIn)
import Cardano.Slotting.Slot (SlotNo (..))
import Cardano.Tx.Balance (refScriptsSize)
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
    , FinalFacts (..)
    , RawRedeemer (..)
    , connectedFoldTx
    , finalBodyRefusals
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
    , wCarrier :: Integer
    -- ^ The lovelace the registration declares for its carrier
    , wStateCoin :: Integer
    -- ^ The lovelace the state output holds
    , wCost :: Integer
    -- ^ The registration cost the registry configures and the registration declares
    , wDestination :: ByteString
    -- ^ The address the registration asks its carrier to be delivered to, as the registrant wrote it
    }

{- | The same registry configured to charge nothing to register: the state it
declares and the registration it books both carry the cost zero, and a fold of
the registration donates nothing. Identity, pins and programs are unchanged.
-}
freeOf :: World -> World
freeOf w = w{wCfg = (wCfg w){defaultRegistrationCost = Coin 0}, wCost = 0}

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
        , wCarrier = 1_500_000
        , wStateCoin = 3_000_000
        , wCost = 2_000_000
        , wDestination = BS.cons 0x60 (BS.replicate 28 0x77)
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
        , regDestination = wDestination w
        , regDatum = Just (PLC.I 7)
        , regSubmittedAt = 5_000_000
        , regRegistrationCost = wCost w
        , regDeclaredTip = 1_500_000
        , regCarrierAda = wCarrier w
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
            -- the booking holds exactly its cost, its tip and its declared carrier
            (Coin (regRegistrationCost r + regDeclaredTip r + regCarrierAda r))
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

{- | The outputs that carry the four scripts of a fold as reference scripts, as
a deployment publishes them: the state and request validators are retained
bytes of about fifteen kilobytes, and a fold that attached them could not fit a
transaction. Spending nothing, they ride in as reference inputs.
-}
scriptCarriers :: World -> [(TxIn, TxOut ConwayEra)]
scriptCarriers w =
    [ ( outRef 'f' i
      , mkBasicTxOut payer (MaryValue (Coin 40_000_000) mempty)
            & referenceScriptTxOutL .~ SJust script
      )
    | (i, script) <-
        zip
            [0 ..]
            [ mkCageScript (wCfg w)
            , mkRequestScript (wCfg w) (wToken w)
            , wApplicationScript w
            , wActiveScript w
            ]
    ]

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
            (Coin (wStateCoin w))
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

-- | What a build runs under: the protocol parameters, the folder's funding output and a change of the arguments.
data Build = Build
    { buildParams :: PParams ConwayEra
    , buildFunding :: TxOut ConwayEra
    , buildAdjust :: ConnectedFoldArgs -> ConnectedFoldArgs
    , buildReferences :: [(TxIn, TxOut ConwayEra)]
    -- ^ Outputs that publish further scripts, offered as reference inputs beside the four the fold needs
    }

standardBuild :: Build
standardBuild = Build ledgerParameters feeOut id []

-- | The view: the tip inside the registration's window, every output resolvable.
viewOver
    :: World -> Root -> [(TxIn, TxOut ConwayEra)] -> Session NoWitness IO
viewOver = viewOverWith standardBuild

viewOverWith
    :: Build
    -> World
    -> Root
    -> [(TxIn, TxOut ConwayEra)]
    -> Session NoWitness IO
viewOverWith b w root requests =
    withTip (TipObservation (SlotNo 5_005) (BS.replicate 32 0) 1 0) $
        withAddressOutputs
            ( \a ->
                pure $
                    if a == requestAddrFromCfg (wCfg w) (wToken w) Testnet
                        then requests
                        else
                            if a == cageAddrFromCfg (wCfg w) Testnet
                                then [(stateRef, stateOutAt w root)]
                                else [(feeRef, buildFunding b)]
            )
            ( withParameters (buildParams b) $
                withTime (pure syntheticTime) $
                    withResolvedOutputs
                        ( \wanted ->
                            pure
                                [ (ref, o)
                                | (ref, o) <-
                                    (stateRef, stateOutAt w root)
                                        : (feeRef, buildFunding b)
                                        : requests
                                            <> scriptCarriers w
                                            <> buildReferences b
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
built = builtUnder standardBuild

-- | The same under other parameters, funding or arguments.
builtUnder
    :: Build -> World -> Shape -> IO (ConwayTx, [(TxIn, TxOut ConwayEra)])
builtUnder b w shape = do
    (manager, root) <- worldTrie w
    let requests = shapeMembers shape w
        state = stateOutAt w root
    (tx, _) <-
        connectedFoldTx $
            buildAdjust
                b
                ConnectedFoldArgs
                    { cfaCfg = wCfg w
                    , cfaSession = viewOverWith b w root requests
                    , cfaTrie = manager
                    , cfaToken = wToken w
                    , cfaFeeAddr = payer
                    , cfaStateUtxo = (stateRef, state)
                    , cfaReqUtxos = requests
                    , cfaFeeUtxo = (feeRef, buildFunding b)
                    , cfaSpends = []
                    , cfaMints = shapeMints shape w
                    , cfaOutputs = []
                    , cfaSigners = []
                    , cfaRefUtxos = scriptCarriers w <> buildReferences b
                    , cfaAttachScripts = []
                    , cfaSkipEval = False
                    , cfaAdjustRoot = id
                    }
    pure
        ( tx
        , (stateRef, state)
            : (feeRef, buildFunding b)
            : requests <> scriptCarriers w <> buildReferences b
        )

{- | What the ledger's evaluator says of every script purpose of a body over its
inputs: the units it measured, or the failure.
-}
judged
    :: [(TxIn, TxOut ConwayEra)]
    -> ConwayTx
    -> Map.Map (ConwayPlutusPurpose AsIx ConwayEra) (Either String ExUnits)
judged = judgedUnder ledgerParameters

judgedUnder
    :: PParams ConwayEra
    -> [(TxIn, TxOut ConwayEra)]
    -> ConwayTx
    -> Map.Map (ConwayPlutusPurpose AsIx ConwayEra) (Either String ExUnits)
judgedUnder params inputs tx =
    Map.map
        (either (Left . show) Right)
        ( evalTxExUnits
            params
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

-- ---------------------------------------------------------
-- The final body, judged against the protocol
-- ---------------------------------------------------------

{- | The least lovelace an output may hold under the parameters: the smallest
amount that is at least the minimum the ledger computes for the output
carrying that amount.
-}
minimumFor :: PParams ConwayEra -> TxOut ConwayEra -> Integer
minimumFor params out = go 0
  where
    go c =
        let Coin needed = getMinCoinTxOut params (out & coinTxOutL .~ Coin c)
        in  if needed <= c then c else go needed

-- | The carrier of the registration as the fold must deliver it, built independently of the builder.
carrierOf :: World -> Integer -> TxOut ConwayEra
carrierOf w coin =
    mkBasicTxOut
        destination
        ( MaryValue
            (Coin coin)
            ( MultiAsset
                ( Map.singleton
                    (wActiveId w)
                    (Map.singleton (nameOf registrationKey) 1)
                )
            )
        )
        & datumTxOutL .~ mkInlineDatum (PLC.I 7)
  where
    destination =
        either
            (error . ("carrierOf: " <>))
            id
            (decodeAddrEither (regDestination (registrationOf w)))

-- | What the final-body validation is told about a build: the spent inputs and the reference outputs.
factsFor :: World -> [(TxIn, TxOut ConwayEra)] -> FinalFacts
factsFor = factsUnder ledgerParameters

factsUnder
    :: PParams ConwayEra -> World -> [(TxIn, TxOut ConwayEra)] -> FinalFacts
factsUnder params w inputs =
    FinalFacts
        { ffParams = params
        , ffNetwork = Testnet
        , ffInputs =
            Map.fromList
                [ x
                | x@(ref, _) <- inputs
                , ref `notElem` map fst (scriptCarriers w)
                ]
        , ffReferences = scriptCarriers w
        , ffLabel = \i -> "output number " <> show i
        }

-- | The text of a refusal of a build, or the body it built.
refusedBuild :: IO a -> IO (Either String a)
refusedBuild action = do
    outcome <- try action
    pure $ case outcome of
        Left err -> Left (displayException (err :: SomeException))
        Right built' -> Right built'

-- | The size, in bytes, of the transaction with the key witnesses it still needs.
witnessedSize :: PParams ConwayEra -> Int -> ConwayTx -> Integer
witnessedSize params witnesses tx =
    toInteger (addDummyWitsTx params tx witnesses [] ^. sizeTxF)

-- | The declared units of a body, summed.
declaredTotal :: ConwayTx -> ExUnits
declaredTotal tx =
    foldr
        (\(ExUnits a b) (ExUnits c d) -> ExUnits (a + c) (b + d))
        (ExUnits 0 0)
        (Map.elems (declaredUnits tx))

-- | The body with its change (the last output) set to a coin and the difference stated as donation, so lovelace still balances.
withChangeAt :: Integer -> ConwayTx -> ConwayTx
withChangeAt c tx =
    case body ^. outputsTxBodyL of
        rest StrictSeq.:|> change ->
            let Coin old = change ^. coinTxOutL
            in  tx
                    & bodyTxL . outputsTxBodyL
                        .~ (rest StrictSeq.:|> (change & coinTxOutL .~ Coin c))
                    & bodyTxL . treasuryDonationTxBodyL %~ (\(Coin d) -> Coin (d + old - c))
        _ -> tx
  where
    body = tx ^. bodyTxL

-- | The body with its fee set and its change moved the other way, so lovelace still balances.
withFeeSet :: Integer -> ConwayTx -> ConwayTx
withFeeSet f tx =
    withFeeMoved (f - fee) tx
  where
    Coin fee = tx ^. bodyTxL . feeTxBodyL

{- | A script of exactly the given number of bytes, as the ledger measures a
script. The fill byte tells scripts apart: the same fill and size is the same
script, so a copy at another input.
-}
paddedScript :: Word8 -> Int -> Script ConwayEra
paddedScript fill size =
    scriptFromBytes "padded" (SBS.pack (replicate size fill))

{- | The bytes of a bootstrap (Byron) address on a testnet whose derivation-path
attribute is the given number of bytes: what a registrant may write as the
destination of a carrier. The ledger measures such an address by that attribute
and refuses an output over 64 bytes of it.
-}
byronAddress :: Int -> ByteString
byronAddress n =
    BS.concat
        [BS.pack [0x82, 0xd8, 0x18], cborBytes payload, BS.pack (0x1a : crc)]
  where
    payload =
        BS.concat
            [ BS.pack [0x83]
            , cborBytes (BS.replicate 28 0x11)
            , BS.pack [0xa2, 0x01]
            , cborBytes (cborBytes (BS.replicate n 0x22))
            , BS.pack [0x02]
            , cborBytes (BS.pack [0x01])
            , BS.pack [0x00]
            ]
    checksum = crc32 payload
    crc = [fromIntegral (checksum `shiftR` k) | k <- [24, 16, 8, 0]]

-- | A CBOR byte string.
cborBytes :: ByteString -> ByteString
cborBytes b
    | n < 24 = BS.cons (0x40 + fromIntegral n) b
    | n < 256 = BS.cons 0x58 (BS.cons (fromIntegral n) b)
    | otherwise =
        BS.cons
            0x59
            (BS.cons (fromIntegral (n `shiftR` 8)) (BS.cons (fromIntegral n) b))
  where
    n = BS.length b

-- | The CRC-32 a bootstrap address carries over its payload.
crc32 :: ByteString -> Word32
crc32 = complement . BS.foldl' byte 0xffff_ffff
  where
    byte c b =
        foldl'
            ( \a _ ->
                if testBit a 0 then (a `shiftR` 1) `xor` 0xedb8_8320 else a `shiftR` 1
            )
            (c `xor` fromIntegral b)
            [1 .. 8 :: Int]

-- | An output that publishes a script as a reference script, as a deployment does.
publishing
    :: Char -> Int -> Script ConwayEra -> (TxIn, TxOut ConwayEra)
publishing c i script =
    ( outRef c i
    , mkBasicTxOut payer (MaryValue (Coin 40_000_000) mempty)
        & referenceScriptTxOutL .~ SJust script
    )

-- | The bytes of the scripts the outputs publish, each counted.
publishedBytes :: [(TxIn, TxOut ConwayEra)] -> Integer
publishedBytes outputs =
    sum
        [ toInteger (BS.length (originalBytes script))
        | (_, o) <- outputs
        , SJust script <- [o ^. referenceScriptTxOutL]
        ]

{- | The bytes of reference scripts a body brings in, counted one occurrence
per input it spends or references (the sum is over inputs, not over scripts),
and the same with every script counted once.
-}
referencedBytes
    :: ConwayTx -> [(TxIn, TxOut ConwayEra)] -> (Integer, Integer)
referencedBytes tx known =
    ( sum (map snd carried)
    , sum (Map.elems (Map.fromList [(hashScript s, n) | (s, n) <- carried]))
    )
  where
    body = tx ^. bodyTxL
    carried =
        [ (script, toInteger (BS.length (originalBytes script)))
        | i <-
            Set.toList (body ^. inputsTxBodyL <> body ^. referenceInputsTxBodyL)
        , Just o <- [lookup i known]
        , SJust script <- [o ^. referenceScriptTxOutL]
        ]

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
                                    , rcRefUtxos = scriptCarriers w
                                    }
                    it
                        "discovers the booked requests by the request policy and builds a fold the ledger's evaluator accepts at every purpose"
                        $ \r -> do
                            let w = worldOf r
                            (manager, root) <- worldTrie w
                            let requests = shapeMembers mixed w
                                inputs =
                                    (stateRef, stateOutAt w root)
                                        : (feeRef, feeOut)
                                        : requests
                                            <> scriptCarriers w
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
                                inputs =
                                    (stateRef, stateOutAt w root)
                                        : (feeRef, feeOut)
                                        : requests
                                            <> scriptCarriers w
                            tx <- entry w root requests manager
                            let variant = withDonationMoved 1 tx
                                stated = ConwaySpending (AsIx (indexOf tx stateRef))
                            failures (judged inputs tx) `shouldBe` []
                            conserved inputs variant `shouldBe` True
                            failures (judged inputs variant) `shouldBe` [stated]
                describe "the final body the ledger would accept" $ do
                    let outputsOf tx = toList (tx ^. bodyTxL . outputsTxBodyL)
                        mentions fragment = any (isInfixOf fragment)
                        under change = standardBuild{buildParams = change ledgerParameters}
                    it
                        "accepts every shape of fold as built, under every rule at once"
                        $ \r -> do
                            let w = worldOf r
                            forM_ [mixed, registrationAlone, terminationAlone] $ \shape -> do
                                (tx, inputs) <- built w shape
                                (shapeName shape, finalBodyRefusals (factsFor w inputs) tx)
                                    `shouldBe` (shapeName shape, [])
                    describe "every output holds its ledger minimum" $ do
                        it
                            "delivers a genuinely tagged registration's carrier at exactly its minimum and refuses one lovelace less, and none"
                            $ \r -> do
                                let w0 = worldOf r
                                    m = minimumFor ledgerParameters (carrierOf w0 0)
                                    w = w0{wCarrier = m}
                                (tx, inputs) <- built w registrationAlone
                                finalBodyRefusals (factsFor w inputs) tx `shouldBe` []
                                failures (judged inputs tx) `shouldBe` []
                                -- the booked allocation reaches the destination exactly
                                [ o ^. coinTxOutL
                                  | o <- outputsOf tx
                                  , o ^. addrTxOutL == carrierOf w m ^. addrTxOutL
                                  ]
                                    `shouldBe` [Coin m]
                                forM_ [m - 1, 0] $ \short -> do
                                    outcome <- refusedBuild (built w0{wCarrier = short} registrationAlone)
                                    case outcome of
                                        Left err -> do
                                            err `shouldSatisfy` isInfixOf "the carrier of the registration of key"
                                            err
                                                `shouldSatisfy` isInfixOf ("holds " <> show short <> " lovelace, under the ")
                                            -- one lovelace under the least amount is under the minimum that very amount asks
                                            when (short == m - 1) $
                                                err
                                                    `shouldSatisfy` isInfixOf ("under the " <> show m <> " the ledger requires")
                                            err
                                                `shouldSatisfy` isInfixOf "booked allocation is exact and unchanged"
                                        Right _ ->
                                            expectationFailure
                                                ("a carrier of " <> show short <> " lovelace built a fold")
                        it
                            "delivers the carrier of a registration that costs nothing, donating nothing, at exactly its minimum under the real validators, and refuses one lovelace less"
                            $ \r -> do
                                let w0 = freeOf (worldOf r)
                                    m = minimumFor ledgerParameters (carrierOf w0 0)
                                    w = w0{wCarrier = m}
                                    Coin configured = defaultRegistrationCost (wCfg w)
                                -- the registry configures the cost the request declares, and the request holds exactly it with its tip and carrier
                                configured `shouldBe` regRegistrationCost (registrationOf w)
                                registrationOut w ^. coinTxOutL
                                    `shouldBe` Coin (regRegistrationCost (registrationOf w) + 1_500_000 + m)
                                (tx, inputs) <- built w registrationAlone
                                tx ^. bodyTxL . treasuryDonationTxBodyL `shouldBe` Coin 0
                                finalBodyRefusals (factsFor w inputs) tx `shouldBe` []
                                failures (judged inputs tx) `shouldBe` []
                                [ o ^. coinTxOutL
                                  | o <- outputsOf tx
                                  , o ^. addrTxOutL == carrierOf w m ^. addrTxOutL
                                  ]
                                    `shouldBe` [Coin m]
                                forM_ [m - 1, 0] $ \short -> do
                                    outcome <- refusedBuild (built w0{wCarrier = short} registrationAlone)
                                    case outcome of
                                        Left err -> do
                                            err `shouldSatisfy` isInfixOf "the carrier of the registration of key"
                                            err
                                                `shouldSatisfy` isInfixOf ("holds " <> show short <> " lovelace, under the ")
                                            err
                                                `shouldSatisfy` isInfixOf "booked allocation is exact and unchanged"
                                        Right _ ->
                                            expectationFailure
                                                ("a carrier of " <> show short <> " lovelace built a fold")
                        it
                            "continues the state at exactly its minimum and refuses one lovelace less"
                            $ \r -> do
                                let w0 = worldOf r
                                (_, root) <- worldTrie w0
                                let m = minimumFor ledgerParameters (stateOutAt w0{wStateCoin = 0} root)
                                (tx, inputs) <- built w0{wStateCoin = m} terminationAlone
                                finalBodyRefusals (factsFor w0{wStateCoin = m} inputs) tx
                                    `shouldBe` []
                                outcome <-
                                    refusedBuild (built w0{wStateCoin = m - 1} terminationAlone)
                                case outcome of
                                    Left err -> do
                                        err `shouldSatisfy` isInfixOf "the state continuation holds"
                                        err `shouldSatisfy` isInfixOf (show (m - 1))
                                    Right _ -> expectationFailure "a state output under its minimum built a fold"
                        it
                            "keeps an output the caller attaches at exactly its minimum and refuses one lovelace less"
                            $ \r -> do
                                let w = worldOf r
                                    extra c = mkBasicTxOut payer (MaryValue (Coin c) mempty)
                                    m = minimumFor ledgerParameters (extra 0)
                                    attaching c = standardBuild{buildAdjust = \a -> a{cfaOutputs = [extra c]}}
                                (tx, inputs) <- builtUnder (attaching m) w registrationAlone
                                finalBodyRefusals (factsFor w inputs) tx `shouldBe` []
                                outcome <-
                                    refusedBuild (builtUnder (attaching (m - 1)) w registrationAlone)
                                case outcome of
                                    Left err -> do
                                        err `shouldSatisfy` isInfixOf "an attached output (number 1) holds"
                                        err `shouldSatisfy` isInfixOf (show (m - 1))
                                    Right _ ->
                                        expectationFailure "an attached output under its minimum built a fold"
                        it
                            "tells the folder's change and the collateral return at their minimum from one lovelace under it"
                            $ \r -> do
                                let w = worldOf r
                                (tx, inputs) <- built w mixed
                                let facts = factsFor w inputs
                                    Coin funding = buildFunding standardBuild ^. coinTxOutL
                                    changeMin = case reverse (outputsOf tx) of
                                        change : _ -> minimumFor ledgerParameters change
                                        [] -> error "no output"
                                    returnMin = case tx ^. bodyTxL . collateralReturnTxBodyL of
                                        SJust ret -> minimumFor ledgerParameters ret
                                        SNothing -> error "no collateral return"
                                    withReturnAt c =
                                        tx
                                            & bodyTxL . collateralReturnTxBodyL %~ fmap (coinTxOutL .~ Coin c)
                                            & bodyTxL . totalCollateralTxBodyL .~ SJust (Coin (funding - c))
                                finalBodyRefusals facts (withChangeAt changeMin tx) `shouldBe` []
                                finalBodyRefusals facts (withChangeAt (changeMin - 1) tx)
                                    `shouldSatisfy` mentions ("holds " <> show (changeMin - 1) <> " lovelace")
                                finalBodyRefusals facts (withReturnAt returnMin) `shouldBe` []
                                finalBodyRefusals facts (withReturnAt (returnMin - 1))
                                    `shouldSatisfy` mentions "the collateral return holds"
                    describe "the declared execution units fit the transaction limit"
                        $ it
                            "refuses one unit over in memory and one over in steps, each purpose still estimating alone, and accepts the limit itself"
                        $ \r -> do
                            let w = worldOf r
                            (tx0, inputs0) <- built w mixed
                            let ExUnits totalMem totalSteps = declaredTotal tx0
                                limited limit = under (ppMaxTxExUnitsL .~ limit)
                            (atLimit, _) <-
                                builtUnder (limited (ExUnits totalMem totalSteps)) w mixed
                            declaredUnits atLimit `shouldBe` declaredUnits tx0
                            forM_
                                [ ("memory", ExUnits (totalMem - 1) totalSteps)
                                , ("steps", ExUnits totalMem (totalSteps - 1))
                                ]
                                $ \(which, limit) -> do
                                    -- under the lowered limit every purpose of the accepted body still estimates
                                    let alone =
                                            judgedUnder (ledgerParameters & ppMaxTxExUnitsL .~ limit) inputs0 tx0
                                    (which, Map.size alone, failures alone) `shouldBe` (which, 6, [])
                                    outcome <- refusedBuild (builtUnder (limited limit) w mixed)
                                    case outcome of
                                        Left err ->
                                            err `shouldSatisfy` isInfixOf "the declared execution units add up to"
                                        Right _ ->
                                            expectationFailure
                                                ("units one over the limit in " <> which <> " built a fold")
                    describe
                        "the transaction fits the size limit with the witnesses it still needs"
                        $ it
                            "refuses one byte over although the body without its witnesses fits, and accepts the size itself"
                        $ \r -> do
                            let w = worldOf r
                            (tx0, _) <- built w mixed
                            let witnessed = witnessedSize ledgerParameters 1 tx0
                                limited n = under (ppMaxTxSizeL .~ fromInteger n)
                            toInteger (tx0 ^. sizeTxF) `shouldSatisfy` (< witnessed - 1)
                            (atLimit, _) <- builtUnder (limited witnessed) w mixed
                            atLimit ^. bodyTxL . inputsTxBodyL
                                `shouldBe` tx0 ^. bodyTxL . inputsTxBodyL
                            outcome <- refusedBuild (builtUnder (limited (witnessed - 1)) w mixed)
                            case outcome of
                                Left err -> do
                                    err
                                        `shouldSatisfy` isInfixOf "key witnesses it still needs, over the limit of"
                                    err `shouldSatisfy` isInfixOf (show witnessed)
                                Right _ ->
                                    expectationFailure
                                        "a transaction one byte over the limit built a fold"
                    describe "the fee covers the minimum of the final body" $ do
                        it
                            "charges the reference scripts it names: the minimum passes, one lovelace under it does not, and a zero reference cost would have passed it"
                            $ \r -> do
                                let w = worldOf r
                                (tx, inputs) <- built w mixed
                                let facts = factsFor w inputs
                                    refBytes =
                                        refScriptsSize
                                            (tx ^. bodyTxL . referenceInputsTxBodyL)
                                            (scriptCarriers w)
                                    needed bytes = let Coin c = estimateMinFeeTx ledgerParameters tx 1 0 bytes in c
                                    Coin fee = tx ^. bodyTxL . feeTxBodyL
                                refBytes `shouldSatisfy` (> 0)
                                needed refBytes `shouldSatisfy` (> needed 0)
                                fee `shouldSatisfy` (>= needed refBytes)
                                finalBodyRefusals facts (withFeeSet (needed refBytes) tx)
                                    `shouldBe` []
                                finalBodyRefusals facts (withFeeSet (needed refBytes - 1) tx)
                                    `shouldSatisfy` mentions "the fee of"
                                needed 0 `shouldSatisfy` (<= needed refBytes - 1)
                        it
                            "prices a reference script the funding output carries, which the transaction library does not"
                            $ \r -> do
                                let w = worldOf r
                                    heavy = feeOut & referenceScriptTxOutL .~ SJust (mkCageScript (wCfg w))
                                outcome <-
                                    refusedBuild (builtUnder standardBuild{buildFunding = heavy} w mixed)
                                case outcome of
                                    Left err -> do
                                        err `shouldSatisfy` isInfixOf "the fee of"
                                        err `shouldSatisfy` isInfixOf "bytes of reference scripts"
                                    Right _ -> expectationFailure "an unpriced reference script built a fold"
                    describe
                        "the scripts the inputs reference fit the ledger's limit for one transaction"
                        $ do
                            let limit = toInteger (ledgerParameters ^. ppMaxRefScriptSizePerTxG)
                                overLimit = mentions "bytes of reference scripts in one transaction"
                            it "reads the era's limit of 200 KiB through the acquired parameters" $ \_ ->
                                limit `shouldBe` 204_800
                            it
                                "builds with scripts adding up to exactly the limit, every copy at a distinct input counting, and refuses one byte more"
                                $ \r -> do
                                    let w = worldOf r
                                        carried = publishedBytes (scriptCarriers w)
                                        copy = 80_000
                                        -- two copies of one script at two inputs, and a filler that
                                        -- brings the total to the limit plus the given excess
                                        published excess =
                                            [ publishing 'c' 0 (paddedScript 1 copy)
                                            , publishing 'c' 1 (paddedScript 1 copy)
                                            , publishing
                                                'c'
                                                2
                                                ( paddedScript
                                                    2
                                                    (fromInteger (limit + excess - carried - 2 * toInteger copy))
                                                )
                                            ]
                                        carrying excess = standardBuild{buildReferences = published excess}
                                    (atLimit, inputs) <- builtUnder (carrying 0) w mixed
                                    -- measured here, on the built body and its resolved inputs
                                    let (occurrences, distinct) = referencedBytes atLimit inputs
                                    occurrences `shouldBe` limit
                                    -- the two copies are one script: counting scripts instead of
                                    -- occurrences would have fitted, and the ledger does not
                                    distinct `shouldSatisfy` (< limit)
                                    outcome <- refusedBuild (builtUnder (carrying 1) w mixed)
                                    case outcome of
                                        Left err -> do
                                            err
                                                `shouldSatisfy` isInfixOf
                                                    "the fold is not built, because the ledger would refuse its final body"
                                            err
                                                `shouldSatisfy` isInfixOf
                                                    ( show (limit + 1)
                                                        <> " bytes, over the ledger's limit of "
                                                        <> show limit
                                                        <> " bytes of reference scripts in one transaction"
                                                    )
                                        Right _ ->
                                            expectationFailure
                                                "scripts one byte over the ledger's limit built a fold"
                            it
                                "counts the script a spent input carries with those the reference inputs carry"
                                $ \r -> do
                                    let w = worldOf r
                                    (tx, inputs) <- built w mixed
                                    let carried = publishedBytes (scriptCarriers w)
                                        fundedWith n =
                                            [ ( ref
                                              , if ref == feeRef
                                                    then o & referenceScriptTxOutL .~ SJust (paddedScript 3 n)
                                                    else o
                                              )
                                            | (ref, o) <- inputs
                                            ]
                                        judgedWith n = finalBodyRefusals (factsFor w (fundedWith n)) tx
                                        fits = fromInteger (limit - carried)
                                    -- the references alone are within the limit, as is the whole at it
                                    judgedWith 1_000 `shouldSatisfy` (not . overLimit)
                                    judgedWith fits `shouldSatisfy` (not . overLimit)
                                    judgedWith (fits + 1) `shouldSatisfy` overLimit
                    describe
                        "the ledger's other rules for a body of this shape, asked of the ledger's own tests"
                        $ do
                            it
                                "refuses a carrier destination on another network, and a bootstrap destination, which no script can see; measures a bootstrap address's attributes at 64 bytes"
                                $ \r -> do
                                    let w0 = worldOf r
                                        withDestination d =
                                            let wd = w0{wDestination = d}
                                            in  wd{wCarrier = minimumFor ledgerParameters (carrierOf wd 0)}
                                        attributesOf d = case decodeAddrEither d of
                                            Right (AddrBootstrap b) -> bootstrapAddressAttrsSize b
                                            _ -> -1
                                        otherNetwork = BS.cons 0x61 (BS.replicate 28 0x77)
                                        bootstrap n =
                                            either
                                                (error . ("byronAddress: " <>))
                                                id
                                                (decodeAddrEither (byronAddress n))
                                    -- the bootstrap addresses written here are the ones they say
                                    map (attributesOf . byronAddress) [64, 65] `shouldBe` [64, 65]
                                    map (fmap serialiseAddr . decodeAddrEither . byronAddress) [64, 65]
                                        `shouldBe` map (Right . byronAddress) [64, 65]
                                    -- another network is refused by the ledger's own test on the built body
                                    outcomeNetwork <-
                                        refusedBuild (built (withDestination otherNetwork) registrationAlone)
                                    case outcomeNetwork of
                                        Left err -> do
                                            err `shouldSatisfy` isInfixOf "the ledger would refuse the body"
                                            err `shouldSatisfy` isInfixOf "WrongNetwork"
                                        Right _ -> expectationFailure "a destination on another network built a fold"
                                    -- a bootstrap output cannot be put in the context of the scripts a fold runs,
                                    -- so the build is refused while the scripts are evaluated, whatever its attributes
                                    forM_ [64, 65] $ \n -> do
                                        outcome <-
                                            refusedBuild
                                                (built (withDestination (byronAddress n)) registrationAlone)
                                        case outcome of
                                            Left err -> err `shouldSatisfy` isInfixOf "ByronTxOutInContext"
                                            Right _ -> expectationFailure "a bootstrap destination built a fold"
                                    -- and the ledger's own test of the attributes, on the body as built, with the change at a bootstrap address
                                    (tx, inputs) <- built w0 registrationAlone
                                    let facts = factsFor w0 inputs
                                        changeAt n =
                                            tx
                                                & bodyTxL . outputsTxBodyL %~ \case
                                                    rest StrictSeq.:|> change -> rest StrictSeq.:|> (change & addrTxOutL .~ bootstrap n)
                                                    outs -> outs
                                        tooBig = mentions "OutputBootAddrAttrsTooBig"
                                    finalBodyRefusals facts tx `shouldBe` []
                                    finalBodyRefusals facts (changeAt 64) `shouldSatisfy` (not . tooBig)
                                    finalBodyRefusals facts (changeAt 65) `shouldSatisfy` tooBig
                            it
                                "refuses an output whose value is over the largest the protocol allows, and builds with the largest"
                                $ \r -> do
                                    let w = worldOf r
                                    (tx, _) <- built w mixed
                                    let version = pvMajor (ledgerParameters ^. ppProtocolVersionL)
                                        valueSize o = toInteger (BSL.length (serialize version (o ^. valueTxOutL)))
                                        outputs =
                                            toList (tx ^. bodyTxL . outputsTxBodyL)
                                                <> [o | SJust o <- [tx ^. bodyTxL . collateralReturnTxBodyL]]
                                        largest = maximum (map valueSize outputs)
                                        limited n = under (ppMaxValSizeL .~ fromInteger n)
                                    _ <- builtUnder (limited largest) w mixed
                                    outcome <- refusedBuild (builtUnder (limited (largest - 1)) w mixed)
                                    case outcome of
                                        Left err -> do
                                            err `shouldSatisfy` isInfixOf "the ledger would refuse the body"
                                            err `shouldSatisfy` isInfixOf "OutputTooBigUTxO"
                                        Right _ ->
                                            expectationFailure
                                                "an output one byte over the largest value built a fold"
                            it
                                "refuses a script attached as a witness that the references already provide"
                                $ \r -> do
                                    let w = worldOf r
                                    outcome <-
                                        refusedBuild
                                            ( builtUnder
                                                standardBuild
                                                    { buildAdjust = \a -> a{cfaAttachScripts = [wActiveScript w]}
                                                    }
                                                w
                                                mixed
                                            )
                                    case outcome of
                                        Left err -> do
                                            err `shouldSatisfy` isInfixOf "the ledger would refuse the body"
                                            err `shouldSatisfy` isInfixOf "ExtraneousScriptWitnessesUTXOW"
                                        Right _ ->
                                            expectationFailure
                                                "a script both attached and referenced built a fold"
                            it
                                "tells a script the body needs that nothing provides, a native script that does not validate, and a script that is not well formed"
                                $ \r -> do
                                    let w = worldOf r
                                    (tx, inputs) <- built w mixed
                                    let facts = factsFor w inputs
                                        nativeAt s' = fromNativeScript (RequireTimeStart (SlotNo s')) :: Script ConwayEra
                                        mintedBy script =
                                            tx
                                                & bodyTxL . mintTxBodyL
                                                    <>~ MultiAsset
                                                        ( Map.singleton
                                                            (PolicyID (hashScript script))
                                                            (Map.singleton (nameOf "native") 1)
                                                        )
                                                & witsTxL . scriptTxWitsL %~ Map.insert (hashScript script) script
                                        broken = scriptFromBytes "broken" (SBS.pack [0xff, 0xff, 0xff])
                                        withWitness =
                                            tx & witsTxL . scriptTxWitsL %~ Map.insert (hashScript broken) broken
                                        withReference =
                                            tx
                                                & bodyTxL . outputsTxBodyL %~ \case
                                                    rest StrictSeq.:|> change ->
                                                        rest StrictSeq.:|> (change & referenceScriptTxOutL .~ SJust broken)
                                                    outs -> outs
                                    finalBodyRefusals facts tx `shouldBe` []
                                    -- the first of the references provides the state's script
                                    finalBodyRefusals facts{ffReferences = drop 1 (ffReferences facts)} tx
                                        `shouldSatisfy` mentions "MissingScriptWitnessesUTXOW"
                                    -- a native script is judged by the body's own interval
                                    finalBodyRefusals facts (mintedBy (nativeAt 0))
                                        `shouldSatisfy` (not . mentions "ScriptWitnessNotValidatingUTXOW")
                                    finalBodyRefusals facts (mintedBy (nativeAt 4_000_000_000))
                                        `shouldSatisfy` mentions "ScriptWitnessNotValidatingUTXOW"
                                    finalBodyRefusals facts withWitness
                                        `shouldSatisfy` mentions "MalformedScriptWitnesses"
                                    finalBodyRefusals facts withReference
                                        `shouldSatisfy` mentions "MalformedReferenceScripts"
                            it
                                "tells a redeemer nothing needs and one a script needs that is missing, a datum an input needs that is missing and one nothing allows"
                                $ \r -> do
                                    let w = worldOf r
                                    (tx, inputs) <- built w mixed
                                    let facts = factsFor w inputs
                                        Redeemers declared = tx ^. witsTxL . rdmrsTxWitsL
                                        (firstPurpose, firstRedeemer) = Map.findMin declared
                                        withoutFirst =
                                            tx
                                                & witsTxL . rdmrsTxWitsL .~ Redeemers (Map.delete firstPurpose declared)
                                        withExtra =
                                            tx
                                                & witsTxL . rdmrsTxWitsL
                                                    .~ Redeemers
                                                        (Map.insert (ConwaySpending (AsIx 99)) firstRedeemer declared)
                                        datum = Data (PLC.I 7) :: Data ConwayEra
                                        stateByHash =
                                            facts
                                                { ffInputs =
                                                    Map.adjust
                                                        (datumTxOutL .~ DatumHash (hashData datum))
                                                        stateRef
                                                        (ffInputs facts)
                                                }
                                        withDatum =
                                            tx
                                                & witsTxL . datsTxWitsL .~ TxDats (Map.singleton (hashData datum) datum)
                                        -- an input locked by a PlutusV2 script, which still asks for a datum, and holds none
                                        v2 =
                                            fromPlutusScript
                                                ( fromJust
                                                    (mkPlutusScript (Plutus @PlutusV2 (PlutusBinary (SBS.pack [1, 2, 3]))))
                                                )
                                                :: Script ConwayEra
                                        stateByV2 =
                                            facts
                                                { ffInputs =
                                                    Map.adjust
                                                        ( \o ->
                                                            o
                                                                & addrTxOutL
                                                                    .~ Addr Testnet (ScriptHashObj (hashScript v2)) StakeRefNull
                                                                & datumTxOutL .~ NoDatum
                                                        )
                                                        stateRef
                                                        (ffInputs facts)
                                                }
                                        withV2 = tx & witsTxL . scriptTxWitsL %~ Map.insert (hashScript v2) v2
                                    finalBodyRefusals facts tx `shouldBe` []
                                    finalBodyRefusals facts withoutFirst
                                        `shouldSatisfy` mentions "MissingRedeemers"
                                    finalBodyRefusals facts withExtra
                                        `shouldSatisfy` mentions "ExtraRedeemers"
                                    finalBodyRefusals stateByHash tx
                                        `shouldSatisfy` mentions "MissingRequiredDatums"
                                    finalBodyRefusals facts withDatum
                                        `shouldSatisfy` mentions "NotAllowedSupplementalDatums"
                                    finalBodyRefusals stateByV2 withV2
                                        `shouldSatisfy` mentions "UnspendableUTxONoDatumHash"
                            it
                                "refuses an input that is also a reference input where the protocol forbids it, and not where it does not"
                                $ \r -> do
                                    let w = worldOf r
                                    (tx, inputs) <- built w mixed
                                    let version n = ProtVer (fromJust (mkVersion (n :: Integer))) 0
                                        factsAt n =
                                            (factsFor w inputs)
                                                { ffParams = ledgerParameters & ppProtocolVersionL .~ version n
                                                }
                                        overlapping = tx & bodyTxL . referenceInputsTxBodyL %~ Set.insert feeRef
                                        forbids = mentions "BabbageNonDisjointRefInputs"
                                    -- a body that keeps them apart is accepted at every version
                                    forM_ [9, 10, 11] $ \n -> finalBodyRefusals (factsAt n) tx `shouldBe` []
                                    forM_ [9, 10] $ \n -> finalBodyRefusals (factsAt n) overlapping `shouldSatisfy` forbids
                                    finalBodyRefusals (factsAt 11) overlapping
                                        `shouldSatisfy` (not . forbids)
                            it
                                "refuses to build a fold the scripts refuse, and builds the same fold when they accept it"
                                $ \r -> do
                                    let w = worldOf r
                                        -- the registration's singular tag is not created: the state validator refuses it
                                        unminted =
                                            registrationAlone{shapeMints = \w' -> [applicationBurn w']}
                                    (tx, inputs) <- built w registrationAlone
                                    failures (judged inputs tx) `shouldBe` []
                                    outcome <- refusedBuild (built w unminted)
                                    case outcome of
                                        Left err -> err `shouldSatisfy` isInfixOf "build failed: EvalFailure"
                                        Right _ -> expectationFailure "a fold the scripts refuse was built"
                            it
                                "refuses a build whose parameters carry no cost model for the scripts, and builds with them"
                                $ \r -> do
                                    let w = worldOf r
                                    _ <- built w mixed
                                    outcome <-
                                        refusedBuild
                                            (builtUnder (under (ppCostModelsL .~ emptyCostModels)) w mixed)
                                    case outcome of
                                        Left err -> err `shouldSatisfy` isInfixOf "NoCostModelInLedgerState PlutusV3"
                                        Right _ ->
                                            expectationFailure
                                                "a build without a cost model for its scripts succeeded"
                    describe "collateral is present, sufficient and coherent" $ do
                        it "judges its presence, its total and its sufficiency from the fee" $ \r -> do
                            let w = worldOf r
                            (tx, inputs) <- built w mixed
                            let facts = factsFor w inputs
                                Coin funding = buildFunding standardBuild ^. coinTxOutL
                                Coin fee = tx ^. bodyTxL . feeTxBodyL
                                required = (fee * 150 + 99) `div` 100
                                collateralising c =
                                    tx
                                        & bodyTxL . collateralReturnTxBodyL
                                            %~ fmap (coinTxOutL .~ Coin (funding - c))
                                        & bodyTxL . totalCollateralTxBodyL .~ SJust (Coin c)
                            finalBodyRefusals facts tx `shouldBe` []
                            finalBodyRefusals facts (collateralising required) `shouldBe` []
                            finalBodyRefusals facts (collateralising (required - 1))
                                `shouldSatisfy` mentions "does not cover"
                            finalBodyRefusals
                                facts
                                (tx & bodyTxL . collateralInputsTxBodyL .~ mempty)
                                `shouldSatisfy` mentions "offers no collateral input"
                            finalBodyRefusals
                                facts
                                ( tx
                                    & bodyTxL . totalCollateralTxBodyL %~ fmap (\(Coin c) -> Coin (c + 1))
                                )
                                `shouldSatisfy` mentions "the stated total collateral"
                        it
                            "tells a script-locked collateral input, assets the return does not give back and too many collateral inputs"
                            $ \r -> do
                                let w = worldOf r
                                (tx, inputs) <- built w mixed
                                let facts = factsFor w inputs
                                    scriptLocked =
                                        feeOut
                                            & addrTxOutL
                                                .~ Addr
                                                    Testnet
                                                    (ScriptHashObj (hashScript (wApplicationScript w)))
                                                    StakeRefNull
                                    withFunding o f =
                                        f{ffInputs = Map.insert feeRef o (ffInputs f)}
                                    holdingAsset =
                                        feeOut
                                            & valueTxOutL
                                                .~ MaryValue
                                                    (feeOut ^. coinTxOutL)
                                                    ( MultiAsset
                                                        (Map.singleton (wApplicationId w) (Map.singleton (nameOf "stray") 1))
                                                    )
                                    noneAllowed = facts{ffParams = ledgerParameters & ppMaxCollateralInputsL .~ 0}
                                finalBodyRefusals facts tx `shouldBe` []
                                finalBodyRefusals (withFunding scriptLocked facts) tx
                                    `shouldSatisfy` mentions "locked by a script"
                                finalBodyRefusals (withFunding holdingAsset facts) tx
                                    `shouldSatisfy` mentions "assets the collateral return does not give back"
                                finalBodyRefusals noneAllowed tx
                                    `shouldSatisfy` mentions "over the limit of 0"
                        it
                            "stops a build whose collateral the protocol percentage cannot be met by"
                            $ \r -> do
                                let w = worldOf r
                                outcome <-
                                    refusedBuild
                                        (builtUnder (under (ppCollateralPercentageL .~ 65_000)) w mixed)
                                case outcome of
                                    Left err -> err `shouldSatisfy` isInfixOf "CollateralShortfall"
                                    Right _ ->
                                        expectationFailure "a build with insufficient collateral succeeded"
                    describe
                        "value is conserved and the integrity hash follows the redeemers"
                        $ it
                            "tells a lovelace short, a stray asset and an altered redeemer from the body as built"
                        $ \r -> do
                            let w = worldOf r
                            (tx, inputs) <- built w mixed
                            let facts = factsFor w inputs
                                stray =
                                    MultiAsset
                                        (Map.singleton (wApplicationId w) (Map.singleton (nameOf "stray") 1))
                                lowered =
                                    tx
                                        & bodyTxL . outputsTxBodyL %~ \case
                                            rest StrictSeq.:|> change ->
                                                rest
                                                    StrictSeq.:|> (change & coinTxOutL %~ (\(Coin c) -> Coin (c - 1)))
                                            outs -> outs
                                altered =
                                    tx
                                        & witsTxL . rdmrsTxWitsL
                                            %~ ( \(Redeemers m) ->
                                                    Redeemers (Map.map (\(d, ExUnits a b) -> (d, ExUnits (a + 1) b)) m)
                                               )
                            finalBodyRefusals facts tx `shouldBe` []
                            finalBodyRefusals facts lowered
                                `shouldSatisfy` mentions "lovelace differ by"
                            finalBodyRefusals facts (tx & bodyTxL . mintTxBodyL %~ (<> stray))
                                `shouldSatisfy` mentions "assets differ"
                            finalBodyRefusals facts altered
                                `shouldSatisfy` mentions "the script-integrity hash is not that of the redeemers"
                describe "the inputs the body spends are the ones the build was given"
                    $ it
                        "refuses a body that spends an input the build did not resolve, and accepts one that spends only resolved inputs"
                    $ \r -> do
                        let w = worldOf r
                        (tx, inputs) <- built w mixed
                        let facts = factsFor w inputs
                        finalBodyRefusals facts tx `shouldBe` []
                        finalBodyRefusals
                            facts{ffInputs = Map.delete feeRef (ffInputs facts)}
                            tx
                            `shouldSatisfy` any (isInfixOf "an input is not among the inputs the build was given")
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
