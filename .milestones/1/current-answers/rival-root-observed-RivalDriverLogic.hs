
-- | Shared pure decisions for the rival witness driver (issue #80 t80e;
-- owner predevnet gate v2). The actual ledger driver and the offline
-- predevnet check both import this module: the five decisions live here
-- exactly once, and neither caller can substitute a private copy.
--
-- Pure value types only: no ledger, node, socket, or submission surface.
module RivalDriverLogic
  ( RivalVariant (..)
  , parseRivalVariant
  , RivalPlan (..)
  , planMode
  , ExpectRefusalOrAccept (..)
  , expectationFor
  , AnchorAvailability (..)
  , AnchorSource (..)
  , selectAnchor
  , RefusalLiveness (..)
  , checkRefusalLiveness
  , SuccessorFacts (..)
  , checkCopiedSuccessor
  , FundingEntry (..)
  , selectLiveFunding
  ) where


-- | The three commissioned rival variants. Never collapsed.
data RivalVariant
  = RivalOwnPolicy
  | RivalCopiedPolicy
  | RivalForgedAnchor
  deriving (Eq, Show)

parseRivalVariant :: String -> Maybe RivalVariant
parseRivalVariant s = case s of
  "own-policy" -> Just RivalOwnPolicy
  "copied-policy" -> Just RivalCopiedPolicy
  "forged-anchor" -> Just RivalForgedAnchor
  _ -> Nothing

data ExpectRefusalOrAccept = ExpectAccept | ExpectRefusal
  deriving (Eq, Show)

-- | The plan decision: whether the run continues the ordinary full-row
-- behaviour or enters the single rival witness terminal.
data RivalPlan
  = FullRows
  | WitnessTerminal RivalVariant ExpectRefusalOrAccept
  deriving (Eq, Show)

-- | The terminal decision: with a variant installed the plan is a witness
-- terminal and runRows RETURNS after it (no fall-through into the ordinary
-- rows); with no variant the ordinary full-row behaviour is unchanged.
planMode :: Maybe RivalVariant -> RivalPlan
planMode Nothing = FullRows
planMode (Just v) = WitnessTerminal v (expectationFor v)

expectationFor :: RivalVariant -> ExpectRefusalOrAccept
expectationFor RivalCopiedPolicy = ExpectAccept
expectationFor _ = ExpectRefusal

-- | The anchor decision inputs: whether the authentic rival bundle is
-- installed (own/copied) and whether the exact saved tokenless anchor
-- exists (forged control).
data AnchorAvailability = AnchorAvailability
  { bundleInstalled :: Bool
  , forgedSaved :: Bool
  } deriving (Eq, Show)

data AnchorSource = AnchorFromBundle | AnchorFromForgedSave
  deriving (Eq, Show)

-- | The anchor decision, by variant: authentic variants anchor on B's
-- bundle state; the forged control anchors on its exact saved tokenless
-- output. Anything else refuses.
selectAnchor
  :: RivalVariant -> AnchorAvailability -> Either String AnchorSource
selectAnchor variant avail = case variant of
  RivalOwnPolicy -> requireBundle
  RivalCopiedPolicy -> requireBundle
  RivalForgedAnchor -> requireForged
  where
    requireBundle
      | bundleInstalled avail = Right AnchorFromBundle
      | otherwise = Left "rival bundle missing after setup"
    requireForged
      | forgedSaved avail = Right AnchorFromForgedSave
      | bundleInstalled avail =
          Left "forged variant must not consume an authentic bundle anchor"
      | otherwise = Left "forged anchor: installed anchor missing"

-- | After a typed Rejected result, BOTH the exact attempted record input
-- and the exact attempted anchor input must remain live/unspent.
data RefusalLiveness = RefusalLiveness
  { attemptedRecordInputLive :: Bool
  , attemptedAnchorInputLive :: Bool
  } deriving (Eq, Show)

checkRefusalLiveness :: RefusalLiveness -> Either String ()
checkRefusalLiveness rl
  | attemptedRecordInputLive rl && attemptedAnchorInputLive rl = Right ()
  | not (attemptedRecordInputLive rl) =
      Left "refusal liveness: the attempted record input is no longer live"
  | otherwise =
      Left "refusal liveness: the attempted anchor input is no longer live"

-- | The copied-policy successor facts the acceptance must prove: the
-- successor joins to the exact full target TxId, sits at B's state
-- address, carries exactly quantity one of B's policy+seed-derived token
-- (and no other asset, excluding any A token), the old exact B anchor is
-- spent, and its decoded root equals the recorded fold result.
data SuccessorFacts = SuccessorFacts
  { sfJoinedToTargetTxId :: Bool
  , sfAtBStateAddress :: Bool
  , sfExactBPolicyAndTokenQtyOne :: Bool
  , sfTokenQtyOne :: Bool
  , sfATokenExcluded :: Bool
  , sfNoOtherAssets :: Bool
  , sfOldExactBAnchorSpent :: Bool
  , sfRootEqualsFoldResult :: Bool
  } deriving (Eq, Show)

checkCopiedSuccessor :: SuccessorFacts -> Either String ()
checkCopiedSuccessor sf
  | sfJoinedToTargetTxId sf
      && sfAtBStateAddress sf
      && sfExactBPolicyAndTokenQtyOne sf
      && sfTokenQtyOne sf
      && sfATokenExcluded sf
      && sfNoOtherAssets sf
      && sfOldExactBAnchorSpent sf
      && sfRootEqualsFoldResult sf =
      Right ()
  | otherwise = Left "copied successor: one or more facts fail"

-- | A funding/collateral pool entry with its liveness observation.
data FundingEntry = FundingEntry
  { feInputId :: String
  , feLive :: Bool
  , feIsConsumedBSeed :: Bool
  } deriving (Eq, Show)

-- | Live-prune the pool: keep only currently-live entries that are not
-- B's consumed seed, so a stale entry can never be selected as
-- fee/collateral for the target body.
selectLiveFunding :: [FundingEntry] -> ([FundingEntry], [FundingEntry])
selectLiveFunding entries =
  ( [e | e <- entries, fundingEntrySelectable e]
  , [e | e <- entries, not (fundingEntrySelectable e)]
  )
  where
    fundingEntrySelectable e = feLive e && not (feIsConsumedBSeed e)
