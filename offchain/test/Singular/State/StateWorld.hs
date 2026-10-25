{-# LANGUAGE DataKinds #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NumericUnderscores #-}

{- |
Module      : Singular.State.StateWorld
Description : The compiled state validator, a chain to build against and a ledger to judge with
License     : Apache-2.0

What the rows of the state builders share. The state validator is the compiled
script of the blueprint the test runner names, its unapplied code checked
against the hash the pinned identity manifest records, and the application
policy applied the way a registry's creation applies it. The chain is the raw
chain fixture: a set of outputs and the recorded history of every transaction
applied to it, behind a real session, so a builder reads it the way it reads a
node. A built transaction is judged by the ledger's own script evaluator on
exactly the outputs the transaction names.

The application is a stand-in script that accepts everything, so the rows of
the state validator do not depend on any real application. Transactions that
the builders do not build, the genesis of a registry and the pending
registrations of an application, are written here by hand from the validator's
type definitions.
-}
module Singular.State.StateWorld
    ( -- * The compiled validator
      compiledBlueprint
    , pinnedUnappliedHash
    , unappliedHash
    , stateScriptFor

      -- * The stand-in application
    , standIn
    , standInHash
    , standInPolicy
    , standInAddress
    , standInApplication
    , Booked (..)
    , bookedKey
    , pendingOutput
    , approvalFor

      -- * The parties
    , network
    , keyAddress
    , txInOf
    , ada

      -- * The world
    , World
    , worldChain
    , newWorld
    , withSession
    , applyTx
    , setSlot
    , outputAt
    , addLive
    , expectBuilt

      -- * Hand-assembled transactions
    , handGenesis
    , registryOf
    , seedOf
    , otherScript
    , applicationCode
    , referenceHolder

      -- * A registry to fold into
    , Registered (..)
    , newRegistered
    , processingDeadline
    , book
    , oracleRoot

      -- * Judging a transaction
    , Purpose (..)
    , Judgement
    , judge
    , purposesRun
    , everyScriptAccepts
    , refusedBy
    , soundnessProblems
    , ledgerMinimumFee

      -- * Reading a transaction
    , outputsOf
    , inputsOf
    , mintedOf
    , outputAddress
    , paidTo
    , assetsOf
    , tokenQuantity
    , valueAda
    , inlineDatum
    , validityOf
    , redeemersOf
    , feeOf

      -- * Changing a built transaction
    , mapOutput
    , withDatum
    , holderIndex
    , withMint
    , withoutMintOf
    , mapRedeemers
    ) where

import Control.Monad.State.Strict (evalState)
import Data.Aeson (Value (..), eitherDecodeFileStrict')
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Short qualified as SBS
import Data.Foldable (toList)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Sequence.Strict qualified as StrictSeq
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Word (Word8)
import Lens.Micro ((%~), (&), (.~), (^.))
import MPF.Backend.Pure (emptyMPFInMemoryDB)
import PlutusCore.Data qualified as PLC
import PlutusLedgerApi.V3 qualified as PV3
import PlutusTx.Builtins.Internal (BuiltinData (..))
import System.Environment (lookupEnv)
import Test.Hspec (expectationFailure)

import Cardano.Crypto.Hash
    ( Hash
    , HashAlgorithm
    , hashFromBytes
    , hashToBytes
    )
import Cardano.Ledger.Address (Addr (..), decodeAddr, serialiseAddr)
import Cardano.Ledger.Allegra.Scripts (ValidityInterval (..))
import Cardano.Ledger.Alonzo.Scripts (AsIx (..))
import Cardano.Ledger.Alonzo.TxWits (Redeemers (..))
import Cardano.Ledger.Api.Scripts.Data
    ( Data (..)
    , Datum (..)
    , binaryDataToData
    )
import Cardano.Ledger.Api.Tx
    ( bodyTxL
    , estimateMinFeeTx
    , mkBasicTx
    , txIdTx
    , witsTxL
    )
import Cardano.Ledger.Api.Tx.Body
    ( collateralInputsTxBodyL
    , feeTxBodyL
    , inputsTxBodyL
    , mintTxBodyL
    , mkBasicTxBody
    , outputsTxBodyL
    , referenceInputsTxBodyL
    , vldtTxBodyL
    )
import Cardano.Ledger.Api.Tx.Out
    ( addrTxOutL
    , coinTxOutL
    , datumTxOutL
    , getMinCoinTxOut
    , mkBasicTxOut
    , referenceScriptTxOutL
    , valueTxOutL
    )
import Cardano.Ledger.Api.Tx.Wits (rdmrsTxWitsL, scriptTxWitsL)
import Cardano.Ledger.BaseTypes
    ( Inject (..)
    , Network (Testnet)
    , StrictMaybe (..)
    , TxIx (..)
    )
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Conway.Scripts (ConwayPlutusPurpose (..))
import Cardano.Ledger.Core (Script, hashScript)
import Cardano.Ledger.Credential
    ( Credential (..)
    , StakeReference (..)
    )
import Cardano.Ledger.Hashes (ScriptHash (..), unsafeMakeSafeHash)
import Cardano.Ledger.Keys (KeyHash (..))
import Cardano.Ledger.Mary.Value
    ( AssetName (..)
    , MaryValue (..)
    , MultiAsset (..)
    , PolicyID (..)
    )
import Cardano.Ledger.Plutus.ExUnits (ExUnits (..))
import Cardano.Ledger.Plutus.TxInfo (transAddr)
import Cardano.Ledger.TxIn (TxId (..), TxIn (..))
import Cardano.Slotting.Slot (SlotNo (..))
import Cardano.Tx.Balance (refScriptsSize)
import Cardano.Tx.Build qualified as Tx
import Cardano.Tx.Ledger (ConwayTx)

import Singular.Registry.Blueprint
    ( Blueprint
    , extractCompiledCode
    , loadBlueprint
    )
import Singular.Registry.Evidence (Evidenced (..), NoWitness)
import Singular.Registry.Ledger (ConwayEra, Root (..), TxOut)
import Singular.Registry.LedgerProvider
    ( OutputQuery (..)
    , Session (..)
    )
import Singular.Registry.RawChainFixture
    ( ChainFacts (..)
    , RawChain
    , advanceChain
    , jumpChainTo
    , newRawChain
    , rawChainProvider
    , recordTransaction
    )
import Singular.Registry.SessionIO (evaluateTx, withLatest)
import Singular.Registry.SyntheticLedger
    ( errorProgram
    , paddedProgram
    , unitProgram
    , withSyntheticCosts
    )
import Singular.Registry.SyntheticTime (syntheticTime)
import Singular.Registry.Trie (Trie (..))
import Singular.Registry.Trie.Pure (stateTrie)
import Singular.Registry.TrieState
    ( RegistryIdentity (..)
    , StatePolicyId (..)
    )
import Singular.Registry.TxBuilder.BookingFixture (preprodParams)
import Singular.Registry.TxBuilder.Internal
    ( mkInlineDatum
    , scriptFromBytes
    )
import Singular.State.Fold
    ( Application (..)
    , Folded (..)
    , Registration (..)
    )
import Singular.State.Preimage
    ( approvalName
    , initialDatumHash
    , registrationPreimage
    , stateTokenName
    )
import Singular.State.Records
    ( genesisRedeemer
    , stateDatum
    )
import Singular.State.Script
    ( ScriptSource (..)
    , StateScript (..)
    , stateScriptFromBlueprint
    , stateScriptHash
    , stateScriptTitle
    )

-- ---------------------------------------------------------
-- The compiled validator
-- ---------------------------------------------------------

{- | The blueprint the test runner names in @SINGULAR_STATE_BLUEPRINT@. A
missing variable fails the row: a run that cannot reach the compiled
validator proves nothing.
-}
compiledBlueprint :: IO Blueprint
compiledBlueprint = do
    path <- required "SINGULAR_STATE_BLUEPRINT"
    loadBlueprint path >>= either (fail . ("blueprint: " <>)) pure

{- | The hash of the state validator's code before its parameter is applied,
as the compiled blueprint carries it.
-}
unappliedHash :: IO ScriptHash
unappliedHash = do
    blueprint <- compiledBlueprint
    code <-
        maybe
            (fail ("the blueprint carries no " <> T.unpack stateScriptTitle))
            pure
            (extractCompiledCode stateScriptTitle blueprint)
    pure (hashScript (scriptFromBytes "singular-state" code))

{- | The hash the pinned identity manifest (@SINGULAR_STATE_SCRIPT_IDENTITY@)
records for the state validator.
-}
pinnedUnappliedHash :: IO ScriptHash
pinnedUnappliedHash = do
    path <- required "SINGULAR_STATE_SCRIPT_IDENTITY"
    manifest <- eitherDecodeFileStrict' path >>= either fail pure
    entries <- case manifest of
        Object o
            | Just (Array vs) <- KeyMap.lookup (Key.fromText "validators") o ->
                pure (toList vs)
        _ -> fail "the identity manifest has no validators"
    case [ h
         | Object o <- entries
         , Just (String t) <- [KeyMap.lookup (Key.fromText "title") o]
         , t == stateScriptTitle
         , Just (String h) <- [KeyMap.lookup (Key.fromText "hash") o]
         ] of
        [hex] -> case B16.decode (BS.pack (map (fromIntegral . fromEnum) (T.unpack hex))) of
            Right bytes
                | Just h <- hashFromBytes bytes -> pure (ScriptHash h)
            _ -> fail "the pinned hash is not 28 bytes of hex"
        found ->
            fail
                ( "the manifest pins "
                    <> show (length found)
                    <> " hashes for the state validator"
                )

required :: String -> IO FilePath
required name =
    lookupEnv name >>= \case
        Just value | not (null value) -> pure value
        _ -> fail (name <> " is not set: the rows need the compiled validator")

{- | The state validator of the application with this policy, carried in the
witness set.
-}
stateScriptFor :: PolicyID -> IO StateScript
stateScriptFor application = do
    blueprint <- compiledBlueprint
    script <-
        either (fail . ("state script: " <>)) pure $
            stateScriptFromBlueprint blueprint application
    pure (StateScript script Attached)

-- ---------------------------------------------------------
-- The stand-in application
-- ---------------------------------------------------------

{- | A script that accepts everything: the application of these rows. It is
the policy of the approvals and the address of the pending registrations.
-}
standIn :: Script ConwayEra
standIn = scriptFromBytes "application stand-in" (unitProgram 1)

standInHash :: ScriptHash
standInHash = hashScript standIn

standInPolicy :: PolicyID
standInPolicy = PolicyID standInHash

standInAddress :: Addr
standInAddress = Addr network (ScriptHashObj standInHash) StakeRefNull

-- | A booked registration of the stand-in application.
data Booked = Booked
    { bkKey :: ByteString
    , bkHolding :: Addr
    , bkDatum :: PLC.Data
    , bkDeposit :: Integer
    , bkTip :: Integer
    -- ^ What the pending registration holds above the deposit
    , bkDeadline :: Integer
    -- ^ Processing deadline, in milliseconds
    }
    deriving stock (Eq, Show)

-- | A booking of a short key with a tip, to be folded before a deadline.
bookedKey :: ByteString -> Integer -> Booked
bookedKey key deadline =
    Booked
        { bkKey = key
        , bkHolding = keyAddress 0x77
        , bkDatum = PLC.Constr 2 [PLC.B key, PLC.I 7]
        , bkDeposit = 5_000_000
        , bkTip = 1_000_000
        , bkDeadline = deadline
        }

-- | The approval a booking commits to, named as the validator names it.
approvalFor :: RegistryIdentity -> Booked -> AssetName
approvalFor registry booked =
    approvalName $
        registrationPreimage
            (bkKey booked)
            registry
            ( fromMaybe
                (error "address has no Plutus form")
                (transAddr (bkHolding booked))
            )
            (initialDatumHash (bkDatum booked))
            (PV3.Lovelace (bkDeposit booked))

-- | The pending registration of a booking, at the stand-in's address.
pendingOutput :: RegistryIdentity -> Booked -> TxOut ConwayEra
pendingOutput registry@(RegistryIdentity (StatePolicyId policy) (AssetName name)) booked =
    mkBasicTxOut
        standInAddress
        ( MaryValue
            (Coin (bkDeposit booked + bkTip booked))
            ( MultiAsset
                ( Map.singleton
                    standInPolicy
                    (Map.singleton (approvalFor registry booked) 1)
                )
            )
        )
        & datumTxOutL
            .~ mkInlineDatum
                ( PLC.Constr
                    0
                    [ PLC.B policy
                    , PLC.B (SBS.fromShort name)
                    , PLC.B (bkKey booked)
                    , PLC.B (serialiseAddr (bkHolding booked))
                    , bkDatum booked
                    , PLC.I (bkDeposit booked)
                    , PLC.I (bkDeadline booked)
                    ]
                )

-- | The stand-in as an application of the fold builder.
standInApplication :: Application
standInApplication =
    Application
        { appPolicy = standInPolicy
        , appDecode = decode
        , appReferences = []
        , appFold = \folded -> do
            mapM_
                ( \f ->
                    Tx.spendScript
                        (foldedRequest f)
                        (BuiltinData (PLC.I (toInteger (foldedHolding f))))
                )
                folded
            Tx.mint
                standInPolicy
                (Map.fromList [(foldedApproval f, -1) | f <- folded])
                (BuiltinData (PLC.List []))
            Tx.attachScript standIn
        }
  where
    decode output = case output ^. datumTxOutL of
        Datum binary ->
            let Data d = binaryDataToData binary
            in  case d of
                    PLC.Constr
                        0
                        [ PLC.B policy
                            , PLC.B name
                            , PLC.B key
                            , PLC.B holding
                            , datum
                            , PLC.I deposit
                            , PLC.I deadline
                            ] -> do
                            address <- decodeAddr holding
                            pure
                                Registration
                                    { regRegistry =
                                        RegistryIdentity
                                            (StatePolicyId policy)
                                            (AssetName (SBS.toShort name))
                                    , regKey = key
                                    , regHolding = address
                                    , regDatum = datum
                                    , regDeposit = Coin deposit
                                    , regDeadline = deadline
                                    }
                    _ -> Nothing
        _ -> Nothing

-- ---------------------------------------------------------
-- The parties
-- ---------------------------------------------------------

network :: Network
network = Testnet

hashOf :: (HashAlgorithm h) => Word8 -> Hash h a
hashOf n =
    fromMaybe
        (error "hash")
        (hashFromBytes (BS.replicate (hashSize n) n))
  where
    hashSize _ = 28

-- | The enterprise address of a key.
keyAddress :: Word8 -> Addr
keyAddress n = Addr network (KeyHashObj (KeyHash (hashOf n))) StakeRefNull

-- | An output reference named by a character and an index.
txInOf :: Char -> Word -> TxIn
txInOf c ix =
    TxIn
        ( TxId
            ( case hashFromBytes (BS.replicate 32 (fromIntegral (fromEnum c))) of
                Just h -> unsafeSafeHash h
                Nothing -> error "tx id"
            )
        )
        (TxIx (fromIntegral ix))
  where
    unsafeSafeHash = unsafeMakeSafeHash

ada :: Integer -> Coin
ada n = Coin (n * 1_000_000)

-- ---------------------------------------------------------
-- The world
-- ---------------------------------------------------------

-- | A chain with its history, behind a provider.
newtype World = World {worldChain :: RawChain}

{- | A chain at slot 10000 of the synthetic network, holding these outputs and
no history.
-}
newWorld :: [(TxIn, TxOut ConwayEra)] -> IO World
newWorld outs = do
    chain <-
        newRawChain
            ChainFacts
                { csNetwork = 42
                , csTip = Nothing
                , csPParams = withSyntheticCosts preprodParams
                , csUTxO = Map.fromList outs
                , csRegistered = Set.empty
                , csNetworkTime = syntheticTime
                }
    jumpChainTo chain (SlotNo 10_000)
    pure (World chain)

-- | Acquire one session of the chain and use it.
withSession :: World -> (Session NoWitness IO -> IO a) -> IO a
withSession world = withLatest (rawChainProvider (worldChain world))

-- | Move the tip to a slot.
setSlot :: World -> Word -> IO ()
setSlot world slot = jumpChainTo (worldChain world) (SlotNo (fromIntegral slot))

{- | Apply a transaction as a block would: it joins the history, its inputs
leave the set and its outputs join it.
-}
applyTx :: World -> ConwayTx -> IO ()
applyTx world tx = do
    recordTransaction (worldChain world) tx
    advanceChain (worldChain world) $ \facts ->
        facts
            { csUTxO =
                Map.union
                    (Map.fromList created)
                    (foldr Map.delete (csUTxO facts) (inputsOf tx))
            }
  where
    created =
        [ (TxIn (txIdTx tx) (TxIx ix), out)
        | (ix, out) <- zip [0 ..] (outputsOf tx)
        ]

-- | Add outputs to the live set without a transaction.
addLive :: World -> [(TxIn, TxOut ConwayEra)] -> IO ()
addLive world outs =
    advanceChain (worldChain world) $ \facts ->
        facts{csUTxO = Map.union (Map.fromList outs) (csUTxO facts)}

-- | The output at a reference, when it is live.
outputAt :: World -> TxIn -> IO (Maybe (TxOut ConwayEra))
outputAt world ref = withSession world $ \session -> do
    answer <- outputs session (AtTxIn ref)
    pure $ case answer of
        Right (Evidenced [(_, out)] _) -> Just out
        _ -> Nothing

-- ---------------------------------------------------------
-- A transaction assembled by hand
-- ---------------------------------------------------------

-- | The registry the seed creates under this state validator.
registryOf :: StateScript -> TxIn -> RegistryIdentity
registryOf script seed =
    RegistryIdentity
        (StatePolicyId (hashToBytes (extractHash' (stateScriptHash script))))
        (stateTokenName seed)
  where
    extractHash' (ScriptHash h) = h

-- | A seed of the tests: the output the registry is created from.
seedOf :: TxIn
seedOf = txInOf '1' 0

{- | The genesis assembled by hand from the validator's types, with none of
the builders in it: the seed funds it, is its collateral and is its seed; the
state token is minted once into one output at the state address with the
empty root.
-}
handGenesis :: StateScript -> TxIn -> Coin -> ConwayTx
handGenesis script seed funding =
    mkBasicTx body
        & witsTxL . scriptTxWitsL
            .~ Map.singleton (stateScriptHash script) (ssScript script)
        & witsTxL . rdmrsTxWitsL
            .~ Redeemers
                ( Map.singleton
                    (ConwayMinting (AsIx 0))
                    ( Data (genesisRedeemer seed)
                    , ExUnits 5_000_000 5_000_000_000
                    )
                )
  where
    registry = registryOf script seed
    RegistryIdentity _ name = registry
    tokens =
        MultiAsset
            ( Map.singleton
                (PolicyID (stateScriptHash script))
                (Map.singleton name 1)
            )
    Coin kept = ada 3
    Coin total = funding
    stateAddr = Addr network (ScriptHashObj (stateScriptHash script)) StakeRefNull
    stateOut =
        mkBasicTxOut stateAddr (MaryValue (Coin kept) tokens)
            & datumTxOutL .~ mkInlineDatum (stateDatum (BS.replicate 32 0))
    change =
        mkBasicTxOut
            (keyAddress 0x41)
            (inject (Coin (total - kept - 2_000_000)))
    body =
        mkBasicTxBody
            & inputsTxBodyL .~ Set.singleton seed
            & collateralInputsTxBodyL .~ Set.singleton seed
            & outputsTxBodyL .~ StrictSeq.fromList [stateOut, change]
            & mintTxBodyL .~ tokens
            & feeTxBodyL .~ Coin 2_000_000

-- ---------------------------------------------------------
-- Judging a transaction
-- ---------------------------------------------------------

-- | The script purposes a state transaction can carry.
data Purpose = Mint | Spend | Other
    deriving stock (Eq, Ord, Show)

-- | The ledger's answer for each script purpose.
type Judgement = [(Purpose, Either String ExUnits)]

{- | The ledger's script evaluator on the transaction, with every spent,
collateral and reference input read from the chain.
-}
judge :: World -> ConwayTx -> IO Judgement
judge world tx = do
    result <- withSession world (`evaluateTx` tx)
    pure $
        sortOnFirst
            [ (purposeOf p, either (Left . show) Right r)
            | (p, r) <- Map.toList result
            ]
  where
    purposeOf = \case
        ConwayMinting _ -> Mint
        ConwaySpending _ -> Spend
        _ -> Other
    sortOnFirst = map snd . Map.toAscList . Map.fromList . zip [0 :: Int ..]

-- | How many scripts of each purpose the judgement ran.
purposesRun :: Judgement -> [(Purpose, Int)]
purposesRun verdicts =
    Map.toList
        (Map.fromListWith (+) [(purpose, 1) | (purpose, _) <- verdicts])

{- | Every purpose ran and was accepted, using memory and steps: an empty
answer or a free run is not an acceptance.
-}
everyScriptAccepts :: Judgement -> Bool
everyScriptAccepts verdicts = not (null verdicts) && all ok verdicts
  where
    ok (_, Right (ExUnits memory steps)) = memory > 0 && steps > 0
    ok _ = False

-- | Some purpose was refused by its script.
refusedBy :: Judgement -> Bool
refusedBy = any (either (const True) (const False) . snd)

{- | The ledger rules a builder can break without the validator noticing, as
the problems found: the value the transaction spends and mints is not the
value it pays and burns as fee; an output holds less than its minimum ADA; no
collateral is declared; the fee is below the minimum for a script the
transaction attaches.
-}
soundnessProblems :: World -> ConwayTx -> IO [String]
soundnessProblems world tx = do
    spent <-
        mapM
            ( \ref ->
                outputAt world ref
                    >>= maybe (fail ("no output " <> show ref)) pure
            )
            (inputsOf tx)
    let pp = withSyntheticCosts preprodParams
        body = tx ^. bodyTxL
        Coin fee = body ^. feeTxBodyL
        valueIn =
            mconcat (map (^. valueTxOutL) spent)
                <> MaryValue (Coin 0) (body ^. mintTxBodyL)
        valueOut =
            mconcat (map (^. valueTxOutL) (outputsOf tx))
                <> MaryValue (Coin fee) mempty
        attached = not (Map.null (tx ^. witsTxL . scriptTxWitsL))
        minimumFee = estimateMinFeeTx pp tx 1 0 0
        thin =
            [ i
            | (i, o) <- zip [0 :: Int ..] (outputsOf tx)
            , o ^. coinTxOutL < getMinCoinTxOut pp o
            ]
    pure $
        [ "value is not conserved: "
            <> show valueIn
            <> " in, "
            <> show valueOut
            <> " out"
        | valueIn /= valueOut
        ]
            <> [ "the fee " <> show fee <> " is below the minimum " <> show minimumFee
               | attached && Coin fee < minimumFee
               ]
            <> [ "outputs " <> show thin <> " hold less than their minimum ADA"
               | not (null thin)
               ]
            <> [ "no collateral is declared"
               | not (null (redeemersOf tx))
                    && Set.null (body ^. collateralInputsTxBodyL)
               ]

{- | The least fee the ledger accepts for a transaction as built, priced for one
key witness and for the reference scripts of every input and reference input
it names, read from the chain.
-}
ledgerMinimumFee :: World -> ConwayTx -> IO Integer
ledgerMinimumFee world tx = do
    let named =
            inputsOf tx
                <> Set.toAscList (tx ^. bodyTxL . referenceInputsTxBodyL)
    held <- mapM (outputAt world) named
    let outputs = [(ref, out) | (ref, Just out) <- zip named held]
        pp = withSyntheticCosts preprodParams
        Coin minimumFee =
            estimateMinFeeTx
                pp
                tx
                1
                0
                (refScriptsSize (Set.fromList (map fst outputs)) outputs)
    pure minimumFee

-- ---------------------------------------------------------
-- Reading a transaction
-- ---------------------------------------------------------

outputsOf :: ConwayTx -> [TxOut ConwayEra]
outputsOf tx = toList (tx ^. bodyTxL . outputsTxBodyL)

inputsOf :: ConwayTx -> [TxIn]
inputsOf tx = Set.toAscList (tx ^. bodyTxL . inputsTxBodyL)

-- | The inline datum of an output.
inlineDatum :: TxOut ConwayEra -> Maybe PLC.Data
inlineDatum out = case out ^. datumTxOutL of
    Datum bd -> let Data d = binaryDataToData bd in Just d
    _ -> Nothing

valueAda :: TxOut ConwayEra -> Integer
valueAda out = let Coin c = out ^. coinTxOutL in c

tokenQuantity :: PolicyID -> AssetName -> TxOut ConwayEra -> Integer
tokenQuantity policy name out =
    let MaryValue _ (MultiAsset assets) = out ^. valueTxOutL
    in  fromMaybe 0 (Map.lookup policy assets >>= Map.lookup name)

-- | The assets an output holds besides ADA.
assetsOf :: TxOut ConwayEra -> [(PolicyID, AssetName, Integer)]
assetsOf out =
    let MaryValue _ (MultiAsset assets) = out ^. valueTxOutL
    in  [ (p, n, q)
        | (p, names) <- Map.toList assets
        , (n, q) <- Map.toList names
        ]

-- | What the transaction mints (positive) and burns (negative).
mintedOf :: ConwayTx -> [(PolicyID, AssetName, Integer)]
mintedOf tx =
    let MultiAsset assets = tx ^. bodyTxL . mintTxBodyL
    in  [ (p, n, q)
        | (p, names) <- Map.toList assets
        , (n, q) <- Map.toList names
        ]

-- | The validity interval as slots.
validityOf :: ConwayTx -> (Maybe SlotNo, Maybe SlotNo)
validityOf tx =
    let ValidityInterval lower upper = tx ^. bodyTxL . vldtTxBodyL
    in  (strict lower, strict upper)
  where
    strict (SJust s) = Just s
    strict SNothing = Nothing

-- | The redeemers a transaction declares, with their purposes.
redeemersOf
    :: ConwayTx -> [(ConwayPlutusPurpose AsIx ConwayEra, PLC.Data)]
redeemersOf tx =
    let Redeemers declared = tx ^. witsTxL . rdmrsTxWitsL
    in  [(purpose, d) | (purpose, (Data d, _)) <- Map.toList declared]

feeOf :: ConwayTx -> Integer
feeOf tx = let Coin f = tx ^. bodyTxL . feeTxBodyL in f

-- ---------------------------------------------------------
-- Changing a built transaction
-- ---------------------------------------------------------

mapOutput
    :: Int -> (TxOut ConwayEra -> TxOut ConwayEra) -> ConwayTx -> ConwayTx
mapOutput index change tx =
    tx
        & bodyTxL . outputsTxBodyL
            .~ StrictSeq.fromList
                [ if i == index then change o else o
                | (i, o) <- zip [0 ..] (outputsOf tx)
                ]

withMint :: MultiAsset -> ConwayTx -> ConwayTx
withMint m tx = tx & bodyTxL . mintTxBodyL .~ m

-- | The transaction without the mint of a policy.
withoutMintOf :: PolicyID -> ConwayTx -> ConwayTx
withoutMintOf policy tx =
    tx
        & bodyTxL . mintTxBodyL %~ \(MultiAsset assets) -> MultiAsset (Map.delete policy assets)

-- | Change the data of the redeemers of one purpose class.
mapRedeemers
    :: (ConwayPlutusPurpose AsIx ConwayEra -> PLC.Data -> PLC.Data)
    -> ConwayTx
    -> ConwayTx
mapRedeemers change tx =
    tx
        & witsTxL . rdmrsTxWitsL
            %~ \(Redeemers declared) ->
                Redeemers
                    ( Map.mapWithKey
                        (\purpose (Data d, units) -> (Data (change purpose d), units))
                        declared
                    )

-- | The value a builder returned; a refusal fails the row.
expectBuilt :: (Show r) => Either r a -> IO a
expectBuilt = \case
    Right built -> pure built
    Left refusal -> do
        expectationFailure ("the builder refused: " <> show refusal)
        fail "no transaction"

-- | The address an output pays.
outputAddress :: TxOut ConwayEra -> Addr
outputAddress out = out ^. addrTxOutL

-- | The lovelace the outputs of a transaction pay to an address.
paidTo :: Addr -> ConwayTx -> Integer
paidTo address tx =
    sum [valueAda out | out <- outputsOf tx, outputAddress out == address]

-- ---------------------------------------------------------
-- Scripts and outputs the rows use besides the validator
-- ---------------------------------------------------------

-- | A script that is neither the state validator nor the stand-in.
otherScript :: Script ConwayEra
otherScript = scriptFromBytes "another script" (errorProgram 1)

-- | The code of an application, as large as a compiled validator.
applicationCode :: Script ConwayEra
applicationCode = scriptFromBytes "application code" (paddedProgram 1 8_000)

-- | An output that carries a script as a reference script.
referenceHolder :: Addr -> Script ConwayEra -> TxOut ConwayEra
referenceHolder address script =
    mkBasicTxOut address (inject (ada 60))
        & referenceScriptTxOutL .~ SJust script

-- ---------------------------------------------------------
-- A registry to fold into
-- ---------------------------------------------------------

{- | A registry created by hand on a chain with two wallets: the booker's, which
held the seed, and a second one, the folder's, which holds nothing of the
booker's.
-}
data Registered = Registered
    { rgWorld :: World
    , rgScript :: StateScript
    , rgRegistry :: RegistryIdentity
    , rgState :: TxIn
    -- ^ The live state output
    , rgBooker :: Addr
    , rgFolder :: Addr
    }

-- | The time, in milliseconds, after which only the other phases spend a registration.
processingDeadline :: Integer
processingDeadline = 10_600_000

{- | The hand-made genesis of a registry applied to a chain whose booker holds
the seed and whose folder holds a wallet of its own.
-}
newRegistered :: IO Registered
newRegistered = do
    script <- stateScriptFor standInPolicy
    let booker = keyAddress 0x41
        folder = keyAddress 0x42
    world <-
        newWorld
            [ (seedOf, mkBasicTxOut booker (inject (ada 100)))
            , (txInOf '2' 0, mkBasicTxOut folder (inject (ada 50)))
            ]
    let genesis = handGenesis script seedOf (ada 100)
    applyTx world genesis
    pure
        Registered
            { rgWorld = world
            , rgScript = script
            , rgRegistry = registryOf script seedOf
            , rgState = TxIn (txIdTx genesis) (TxIx 0)
            , rgBooker = booker
            , rgFolder = folder
            }

{- | Put the pending registrations of these bookings on the chain, as the
booker's transactions would have, and name them.
-}
book :: Registered -> Char -> [Booked] -> IO [TxIn]
book registered tag bookings = do
    let refs = [txInOf tag ix | ix <- take (length bookings) [0 ..]]
    addLive
        (rgWorld registered)
        [ (ref, pendingOutput (rgRegistry registered) booked)
        | (ref, booked) <- zip refs bookings
        ]
    pure refs

-- | The root of the trie holding these keys, computed with the trie library alone.
oracleRoot :: [ByteString] -> ByteString
oracleRoot keys =
    let Root root =
            evalState
                ( mapM_ (\key -> insert stateTrie key (BS.singleton 1)) keys
                    >> getRoot stateTrie
                )
                emptyMPFInMemoryDB
    in  root

-- | The output with another inline datum.
withDatum :: PLC.Data -> TxOut ConwayEra -> TxOut ConwayEra
withDatum d out = out & datumTxOutL .~ mkInlineDatum d

-- | The index of the first output of a transaction that holds a token once.
holderIndex :: PolicyID -> AssetName -> ConwayTx -> Int
holderIndex policy name tx =
    case [ ix
         | (ix, out) <- zip [0 ..] (outputsOf tx)
         , tokenQuantity policy name out == 1
         ] of
        ix : _ -> ix
        [] -> error "no output holds the token"
