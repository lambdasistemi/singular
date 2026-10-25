{-# LANGUAGE LambdaCase #-}

{- |
Module      : Singular.State.Records
Description : The datum and the actions of the Singular state validator, as Plutus Data
License     : Apache-2.0

What the state validator reads and the builders write: the root-only state
datum, the actions of its mint and the redeemer of its spend, each in the
Plutus Data layout the validator decodes. The layout follows the validator's
types (@singular_state\/state@, @singular_state\/genesis@,
@singular_state\/fold@). The same functions decode a transaction's redeemers,
so a registry's history can be read with the bytes the builders wrote.
-}
module Singular.State.Records
    ( -- * The state datum
      stateDatum
    , decodeStateDatum

      -- * The mint
    , genesisRedeemer
    , decodeGenesisRedeemer
    , foldedRedeemer

      -- * The spend
    , Change (..)
    , foldRedeemer
    , decodeFoldRedeemer
    ) where

import Data.ByteString (ByteString)
import PlutusCore.Data qualified as PLC
import PlutusTx.Builtins.Internal (BuiltinData (..))
import PlutusTx.IsData.Class (FromData (..), ToData (..))

import Cardano.Crypto.Hash (hashFromBytes)
import Cardano.Ledger.BaseTypes (TxIx (..))
import Cardano.Ledger.Hashes (unsafeMakeSafeHash)
import Cardano.Ledger.TxIn (TxId (..), TxIn (..))

import Singular.Registry.Types (ProofStep)
import Singular.State.Preimage (seedData)

-- | The datum of a state output: the root of the registry's trie.
stateDatum :: ByteString -> PLC.Data
stateDatum root = PLC.Constr 0 [PLC.B root]

-- | The root a state datum carries.
decodeStateDatum :: PLC.Data -> Maybe ByteString
decodeStateDatum = \case
    PLC.Constr 0 [PLC.B root] -> Just root
    _ -> Nothing

-- | The redeemer of the state policy that creates the registry of a seed.
genesisRedeemer :: TxIn -> PLC.Data
genesisRedeemer seed = PLC.Constr 0 [seedData seed]

-- | The seed a genesis redeemer names.
decodeGenesisRedeemer :: PLC.Data -> Maybe TxIn
decodeGenesisRedeemer = \case
    PLC.Constr 0 [reference] -> decodeReference reference
    _ -> Nothing

{- | The redeemer of a state policy mint that belongs to a fold: the spend of
the state output decides it.
-}
foldedRedeemer :: PLC.Data
foldedRedeemer = PLC.Constr 1 []

{- | One change of a fold, in the order of the validator's @Change@. A
termination is declared to keep that order; no builder writes one yet, and a
fold that carries one is refused by the validator.
-}
data Change
    = Register
        { changeRequest :: TxIn
        -- ^ The pending registration the change consumes
        , changeKey :: ByteString
        , changeHolding :: Integer
        -- ^ The index of the output that holds the key's token
        , changeDeposit :: Integer
        , changeProof :: [ProofStep]
        -- ^ The proof that the key was absent, read after its insertion
        }
    | Terminate
        { changeRequest :: TxIn
        , changeKey :: ByteString
        , changeProof :: [ProofStep]
        }
    deriving stock (Eq, Show)

-- | The redeemer of a state output: the seed that names the registry and the changes.
foldRedeemer :: TxIn -> [Change] -> PLC.Data
foldRedeemer seed changes =
    PLC.Constr 0 [seedData seed, PLC.List (map change changes)]
  where
    change = \case
        Register request key holding deposit proof ->
            PLC.Constr
                0
                [ seedData request
                , PLC.B key
                , PLC.I holding
                , PLC.I deposit
                , proofData proof
                ]
        Terminate request key proof ->
            PLC.Constr 1 [seedData request, PLC.B key, proofData proof]

-- | The seed and the changes a fold redeemer carries.
decodeFoldRedeemer :: PLC.Data -> Maybe (TxIn, [Change])
decodeFoldRedeemer = \case
    PLC.Constr 0 [seed, PLC.List changes] ->
        (,) <$> decodeReference seed <*> traverse change changes
    _ -> Nothing
  where
    change = \case
        PLC.Constr 0 [request, PLC.B key, PLC.I holding, PLC.I deposit, proof] ->
            Register
                <$> decodeReference request
                <*> pure key
                <*> pure holding
                <*> pure deposit
                <*> decodeProof proof
        PLC.Constr 1 [request, PLC.B key, proof] ->
            Terminate
                <$> decodeReference request
                <*> pure key
                <*> decodeProof proof
        _ -> Nothing

proofData :: [ProofStep] -> PLC.Data
proofData steps =
    PLC.List [d | step <- steps, let BuiltinData d = toBuiltinData step]

decodeProof :: PLC.Data -> Maybe [ProofStep]
decodeProof = \case
    PLC.List steps -> traverse (fromBuiltinData . BuiltinData) steps
    _ -> Nothing

decodeReference :: PLC.Data -> Maybe TxIn
decodeReference = \case
    PLC.Constr 0 [PLC.B bytes, PLC.I index]
        | index >= 0
        , Just hash <- hashFromBytes bytes ->
            Just
                (TxIn (TxId (unsafeMakeSafeHash hash)) (TxIx (fromInteger index)))
    _ -> Nothing
