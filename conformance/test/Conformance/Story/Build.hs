-- | Verbs for writing a story; each returns one operational instruction.
module Conformance.Story.Build (
    activeToken,
    token,
    literalControl,
    nothing,
    key,
    mint,
    noMints,
    lovelace,
    noRefunds,
    signer,
    noSigners,
    maxFee,
    restUnchanged,
    noPins,
    step,
    noSteps,
    hash,
    noHashes,
    deliver,
    minted,
    observedAddress,
    openParameters,
    requestLovelace,
    approvalRecomputed,
    refunds,
    signers,
    configAfter,
    configBefore,
    landedFolds,
    onLeg,
    dropLeg,
    unchanged,
    keys,
    claimedMint,
    entailedMint,
    controlMint,
    distinguisher,
    txid,
    controlTxid,
    hashes,
    omitTrace,
    accepts,
    acceptsBecause,
    rejects,
    conjunct,
    clause,
    theorem,
    unexercised
) where

import Control.Monad.Operational (Program, singleton)
import Data.Aeson (Value)
import Data.Text (Text)
import Conformance.Story.Binding (Binding)
import Conformance.Story.Instruction

-- | One active token holding: under the active policy the asset name
-- IS the key.
activeToken :: Value -> Integer -> Program AssetsI ()
activeToken k qty = singleton (ActiveToken k qty)

-- | One token holding under any policy.
token :: Value -> Value -> Integer -> Program AssetsI ()
token policy name qty = singleton (Token policy name qty)

-- | Negative control: a literal-built collection inside a program
-- world. Validators refuse it; it is never used in a case.
literalControl :: [Value] -> Program AssetsI ()
literalControl vs = singleton (LitAssets vs)

-- | The empty asset collection, said out loud.
nothing :: Program AssetsI ()
nothing = singleton NoAssets

-- | One key of a batch.
key :: Value -> Program KeysI ()
key k = singleton (Key k)

-- | One mint entry: policy, name, quantity.
mint :: Value -> Value -> Integer -> Program MintI ()
mint policy name qty = singleton (Mint policy name qty)

-- | The empty mint collection.
noMints :: Program MintI ()
noMints = singleton NoMints

-- | A lovelace refund of the given size.
lovelace :: Integer -> Program RefundsI ()
lovelace n = singleton (Lovelace n)

-- | No refund.
noRefunds :: Program RefundsI ()
noRefunds = singleton NoRefunds

-- | One required signer.
signer :: Value -> Program SignersI ()
signer addr = singleton (Signer addr)

-- | No signer.
noSigners :: Program SignersI ()
noSigners = singleton NoSigners

-- | Override the first configuration pin (the max fee).
maxFee :: Integer -> Program ConfigI ()
maxFee n = singleton (MaxFee n)

-- | Every other pin stays as the fixture carries it.
restUnchanged :: Program ConfigI ()
restUnchanged = singleton RestUnchanged

-- | No pins at all: an unobserved configuration.
noPins :: Program ConfigI ()
noPins = singleton NoPins

-- | One landed fold: transaction, root before and after, committed root.
step :: Value -> Value -> Value -> Value -> Program SequenceI ()
step tx before after committed = singleton (Step tx before after committed)

-- | No landed folds.
noSteps :: Program SequenceI ()
noSteps = singleton NoSteps

-- | One failing-script hash.
hash :: Value -> Program HashesI ()
hash h = singleton (Hash h)

-- | No failing script named.
noHashes :: Program HashesI ()
noHashes = singleton NoHashes

-- | Deliver a collection program.
deliver :: Program AssetsI () -> Program EditI ()
deliver p = singleton (Deliver p)

-- | Mint a collection program.
minted :: Program AssetsI () -> Program EditI ()
minted p = singleton (Minted p)

-- | Observe the token at another address.
observedAddress :: Value -> Program EditI ()
observedAddress addr = singleton (ObservedAddress addr)

-- | Declare open parameters.
openParameters :: Integer -> Program EditI ()
openParameters n = singleton (OpenParameters n)

-- | Carry request lovelace.
requestLovelace :: Integer -> Program EditI ()
requestLovelace n = singleton (RequestLovelace n)

-- | Recompute the approval to another name.
approvalRecomputed :: Value -> Program EditI ()
approvalRecomputed v = singleton (ApprovalRecomputed v)

-- | Pay a refund collection program.
refunds :: Program RefundsI () -> Program EditI ()
refunds p = singleton (Refunds p)

-- | Require a signer collection program.
signers :: Program SignersI () -> Program EditI ()
signers p = singleton (Signers p)

-- | Replace the output configuration pins.
configAfter :: Program ConfigI () -> Program EditI ()
configAfter p = singleton (ConfigAfter p)

-- | Replace the input configuration pins.
configBefore :: Program ConfigI () -> Program EditI ()
configBefore p = singleton (ConfigBefore p)

-- | Replace the landed-fold sequence.
landedFolds :: Program SequenceI () -> Program EditI ()
landedFolds p = singleton (LandedFolds p)

-- | Scope an edit program to one refusal leg.
onLeg :: LegName -> Program LegI () -> Program EditI ()
onLeg leg p = singleton (OnLeg leg p)

-- | Drop a refusal leg entirely: an incomplete row.
dropLeg :: LegName -> Program EditI ()
dropLeg leg = singleton (DropLeg leg)

-- | No change.
unchanged :: Program EditI ()
unchanged = singleton Unchanged

-- | Name the keys a leg carries.
keys :: Program KeysI () -> Program LegI ()
keys p = singleton (LegKeys p)

-- | Name what the leg's transaction claimed to mint.
claimedMint :: Program MintI () -> Program LegI ()
claimedMint p = singleton (LegClaimed p)

-- | Name what the leg's edges actually entail.
entailedMint :: Program MintI () -> Program LegI ()
entailedMint p = singleton (LegEntailed p)

-- | Name what the leg's accepting control minted.
controlMint :: Program MintI () -> Program LegI ()
controlMint p = singleton (LegControl p)

-- | State the one thing distinguishing the refused pair.
distinguisher :: Text -> Program LegI ()
distinguisher t = singleton (LegDistinguisher t)

-- | Name the refused transaction.
txid :: Value -> Program LegI ()
txid v = singleton (LegTxid v)

-- | Name the accepting control transaction.
controlTxid :: Value -> Program LegI ()
controlTxid v = singleton (LegControlTxid v)

-- | Name the failing scripts.
hashes :: Program HashesI () -> Program LegI ()
hashes p = singleton (LegHashes p)

-- | Record that the ledger surfaced no trace: a script-execution
-- failure carries an empty log list, so absence is the normal case.
omitTrace :: Program LegI ()
omitTrace = singleton OmitTrace

-- | Accept the observation: the loader must take it.
accepts :: Text -> Program EditI () -> Program CaseI ()
accepts name prog = singleton (Accepts name prog)

-- | Accept the observation, recording why the case matters.
acceptsBecause :: Text -> Reason -> Program EditI () -> Program CaseI ()
acceptsBecause name reason prog = singleton (AcceptsBecause name prog reason)

-- | Refuse the observation. The reason is a required argument: a
-- rejection claims the mutation is caught for a reason, and the type
-- demands it so nobody has to remember it.
rejects :: Text -> Reason -> Program EditI () -> Program CaseI ()
rejects name reason prog = singleton (Rejects name reason prog)

-- | Quote one conjunct anchor verbatim from the bound statement.
conjunct :: Text -> Program SelectI ()
conjunct t = singleton (Conjunct t)

-- | Read a clause through its selected conjuncts and its cases. The
-- only verb taking two block arguments: selects, then cases.
clause :: Text -> Program SelectI () -> Program CaseI () -> Program ClauseI ()
clause alias selects cases = singleton (Clause alias selects cases)

-- | Read a bound obligation through its clauses.
theorem :: Binding -> Program ClauseI () -> Program StoryI ()
theorem binding clauses = singleton (Theorem binding clauses)

-- | Record an unexercised clause as data.
unexercised :: Text -> Text -> Program ClauseI ()
unexercised alias missing = singleton (Unexercised alias missing)

