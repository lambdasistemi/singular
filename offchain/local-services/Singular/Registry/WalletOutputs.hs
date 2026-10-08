{- |
Module      : Singular.Registry.WalletOutputs
Description : The one door through which a builder sees a wallet
License     : Apache-2.0

A wallet's outputs reach transaction builders only as 'WalletOutputs',
whose raw list this module alone reads. Ordinary funding sees the
'fundable' outputs: ada and nothing else, since the funding output doubles
as collateral, and no reference script, since a carrier serves every
registry of its release and a transaction may not both spend and reference
it. The other selections are named by what they select: a chosen funding
input, create's seed, and the carriers of one script. Choosing a funding
input, or reserving the seed, narrows ordinary funding only; the carriers
stay where they are.
-}
module Singular.Registry.WalletOutputs
    ( -- * The wallet
      WalletOutputs
    , walletOutputs

      -- * Ordinary funding
    , fundable
    , fundingOutputs
    , coveringFunding
    , covering
    , FundingRefusal (..)
    , renderFundingRefusal
    , chosenFunding
    , FundingViewRefusal (..)
    , narrowFunding

      -- * Named selections
    , SeedRefusal (..)
    , seedOf
    , carriersOf
    , burnCandidates
    ) where

import Data.List (sortOn)
import Data.Map.Strict qualified as Map
import Data.Ord (Down (..))
import Data.Set (Set)
import Data.Set qualified as Set
import Lens.Micro ((^.))

import Cardano.Ledger.Api.Tx.Out
    ( TxOut
    , coinTxOutL
    , referenceScriptTxOutL
    , valueTxOutL
    )
import Cardano.Ledger.BaseTypes (StrictMaybe (..))
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Core (hashScript)
import Cardano.Ledger.Hashes (ScriptHash)
import Cardano.Ledger.Mary.Value (MaryValue (..), MultiAsset (..))
import Cardano.Ledger.TxIn (TxIn)

import Singular.Registry.Evidence (Evidenced (..))
import Singular.Registry.Ledger (Addr, ConwayEra)
import Singular.Registry.LedgerProvider
    ( Asset
    , OutputQuery (..)
    , ReadFailure
    , Session (..)
    )

-- | The outputs a wallet address holds, as one read saw them.
data WalletOutputs = WalletOutputs
    { held :: [(TxIn, TxOut ConwayEra)]
    , withheld :: Set TxIn
    -- ^ Outputs ordinary funding leaves alone: a seed the boot spends
    , chosen :: Maybe TxIn
    -- ^ The one output ordinary funding may use, when the caller chose it
    }

-- | Read the wallet at this address; a failed read stays the read failure.
walletOutputs
    :: (Monad m)
    => Session w m
    -> Addr
    -> m (Either ReadFailure WalletOutputs)
walletOutputs session address =
    fmap seen <$> outputs session (AtAddress address)
  where
    seen fact =
        WalletOutputs
            { held = value fact
            , withheld = Set.empty
            , chosen = Map.lookup address (sessionFunding session)
            }

-- | Whether ordinary funding may spend this output.
fundable :: TxOut ConwayEra -> Bool
fundable out =
    (case out ^. valueTxOutL of MaryValue _ (MultiAsset m) -> Map.null m)
        && ( case out ^. referenceScriptTxOutL of
                SNothing -> True
                SJust _ -> False
           )

{- | The smallest fundable output covering this amount, if the wallet
has one. A publication takes the output that covers it whenever one
exists instead of stranding on outputs too small.
-}
coveringFunding
    :: Integer -> WalletOutputs -> Maybe (TxIn, TxOut ConwayEra)
coveringFunding needed w = covering needed (fundingOutputs w)

{- | The smallest output covering this amount from fundable candidates,
if one covers. Shared publication selection: callers pass only the
outputs they may spend (never the seed, never carriers). Covering is
strict, as the change it leaves must stay above the minimum.
-}
covering
    :: Integer -> [(k, TxOut ConwayEra)] -> Maybe (k, TxOut ConwayEra)
covering needed outs =
    case [ u
         | u@(_, out) <- sortOn (coinOf . snd) outs
         , fundable out
         , coinOf out > needed
         ] of
        [] -> Nothing
        covered : _ -> Just covered
  where
    coinOf out = let MaryValue (Coin c) _ = out ^. valueTxOutL in c

-- | The fundable outputs, largest first, ties by output reference.
fundingOutputs :: WalletOutputs -> [(TxIn, TxOut ConwayEra)]
fundingOutputs w =
    sortOn
        (\(i, o) -> (Down (o ^. coinTxOutL), i))
        [ u
        | u@(i, o) <- held w
        , fundable o
        , Set.notMember i (withheld w)
        , maybe True (== i) (chosen w)
        ]

{- | Why a chosen funding input cannot fund.
| The wallet does not hold the chosen input, or it is not fundable.
-}
newtype FundingRefusal
    = ChosenNotFundable TxIn
    deriving stock (Eq, Show)

-- | A funding refusal as a command reports it.
renderFundingRefusal :: FundingRefusal -> String
renderFundingRefusal (ChosenNotFundable _) =
    "the chosen funding output is not an ada-only output of the payer"

-- | The wallet narrowed to the chosen input, which must be fundable.
chosenFunding
    :: TxIn -> WalletOutputs -> Either FundingRefusal WalletOutputs
chosenFunding input w
    | input `elem` map fst (fundingOutputs w) =
        Right w{chosen = Just input}
    | otherwise = Left (ChosenNotFundable input)

-- | Why a funding choice could not be applied to a session.
data FundingViewRefusal
    = -- | The wallet could not be read
      FundingReadFailure ReadFailure
    | -- | The wallet does not hold the chosen input as a fundable output
      FundingInputRefusal FundingRefusal
    deriving stock (Eq, Show)

{- | The session whose ordinary funding at the payer address is the chosen
input alone, which must be a fundable output of that wallet now. Every
later wallet read through it keeps that restriction; its carriers and
every other read are unchanged.
-}
narrowFunding
    :: (Monad m)
    => Addr
    -> TxIn
    -> Session w m
    -> m (Either FundingViewRefusal (Session w m))
narrowFunding address input session = do
    acquired <- walletOutputs session address
    pure $ case acquired of
        Left failure -> Left (FundingReadFailure failure)
        Right w -> case chosenFunding input w of
            Left refusal -> Left (FundingInputRefusal refusal)
            Right _ ->
                Right
                    session
                        { sessionFunding =
                            Map.insert address input (sessionFunding session)
                        }

-- | Why an output cannot be create's seed.
data SeedRefusal
    = SeedAbsent
    | SeedNotFundable
    deriving stock (Eq, Show)

{- | Create's seed, which must be fundable, and the wallet with it reserved
for the boot.
-}
seedOf
    :: TxIn
    -> WalletOutputs
    -> Either SeedRefusal ((TxIn, TxOut ConwayEra), WalletOutputs)
seedOf seed w = case [u | u@(i, _) <- held w, i == seed] of
    [] -> Left SeedAbsent
    u@(_, out) : _
        | fundable out ->
            Right (u, w{withheld = Set.insert seed (withheld w)})
        | otherwise -> Left SeedNotFundable

{- | The outputs whose own reference script hashes to this hash, computed
here from the script each carries.
-}
carriersOf :: ScriptHash -> WalletOutputs -> [(TxIn, TxOut ConwayEra)]
carriersOf expected w =
    [ u
    | u@(_, out) <- held w
    , SJust script <- [out ^. referenceScriptTxOutL]
    , hashScript script == expected
    ]

{- | The outputs holding any quantity of this asset: the candidates a fold
burning it may spend, which the fold narrows to the one holding exactly
one unit. Never ordinary funding.
-}
burnCandidates :: Asset -> WalletOutputs -> [(TxIn, TxOut ConwayEra)]
burnCandidates (policy, name) w =
    [ u
    | u@(_, out) <- held w
    , let MaryValue _ (MultiAsset assets) = out ^. valueTxOutL
    , maybe 0 (Map.findWithDefault 0 name) (Map.lookup policy assets) /= 0
    ]
