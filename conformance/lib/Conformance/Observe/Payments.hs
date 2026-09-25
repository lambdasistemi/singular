{- | The payments an accepted exit made, read off its transaction.

The chain settles a fold per payee. A fold that delivers a token pays the
deposit with it: the output carrying the token holds at least the deposit. A
fold that delivers nothing, and a reject, pay the request's owner: the owner is
credited the summed lovelace of every output at the owner's payment key that
carries no token the fold delivers. An absent insertion locks the deposit in the
custody output it creates. A spent custody's refund address is credited the
summed lovelace of every output at that address carrying no delivered token. A
retraction returns what the request held through one output at the owner's key
whose inline datum is the retracted request's own output reference: the largest
such output is what the chain reads, never a sum of fragments. Every
amount is read as the chain paid it, never selected by the amount the model
expects, so a short or surplus payment reaches the comparison. This module
reads those payments in the chain's own terms — addresses, keys and lovelace —
and leaves their translation to model identities to the live runner, which
allocated them.
-}
module Conformance.Observe.Payments (
    FoldOutput (..),
    ExitFacts (..),
    Payee (..),
    Payment (..),
    foldPayments,
    creditsOwner,
    OwnerReading (..),
    readOwner,
    readBound,
    ownerOutputObservation,
    OwedPayee (..),
    owedPayee,
    owedOutputs,
    OutputEdit (..),
    tamperEdits,
) where

import Conformance.Story.Live (Edge (..), Exit (..), Tamper (..))
import Data.Aeson (Value (..), object, (.=))
import Data.ByteString (ByteString)
import Data.List (maximumBy, nub)
import Data.Ord (comparing)
import Data.Maybe (isJust)
import Data.Text (Text)

-- | One output of the fold's transaction, reduced to what settlement reads.
data FoldOutput = FoldOutput
    { outputAddress :: ByteString
    -- ^ the serialised address
    , outputKey :: ByteString
    -- ^ the payment key hash; empty for a script credential
    , outputLovelace :: Integer
    , outputCarrier :: Bool
    -- ^ holds a token this fold delivers
    , outputDatum :: Text
    -- ^ the datum form the output presents: @none@, @hashed@ or @inline@
    , outputApprovals :: [Text]
    -- ^ the hex names of the application-policy assets it holds
    , outputCustody :: Bool
    -- ^ holds an absent custody datum at the cage
    , outputReference :: Maybe Text
    -- ^ the output reference its inline datum presents, if it presents one
    }
    deriving stock (Eq, Show)

-- | What the chain records about the exit beside its outputs.
data ExitFacts = ExitFacts
    { factsExit :: Exit
    , factsEdge :: Edge
    , factsOwner :: ByteString
    -- ^ the payment key hash the request names as its owner
    , factsRefund :: Maybe ByteString
    -- ^ the refund address of the custody this fold spent
    , factsReference :: Maybe Text
    -- ^ the output reference the request sat at
    }
    deriving stock (Eq, Show)

-- | Who a payment reached, in the chain's terms.
data Payee
    = -- | the cage's custody
      Custody
    | -- | the address holding the delivered token
      Destination ByteString
    | -- | the request owner's payment key
      Owner ByteString
    | -- | the refund address a spent custody recorded
      Refund ByteString
    deriving stock (Eq, Show)

-- | A payment the fold made: its payee and the lovelace that reached it.
data Payment = Payment
    { payee :: Payee
    , paidLovelace :: Integer
    }
    deriving stock (Eq, Show)

{- | The payments of one accepted fold, in the order the model states them:
what the fold owes for its request, then the custody refund it pays.

What is owed is reported as the chain paid it, however much that is, so a
short payment reaches the comparison as a value below the model's floor. What
cannot be read as a payment at all — a delivered token no single output
carries, a custody lock that is not there, a spent custody whose source was not
observed — is refused rather than reported.
-}
foldPayments :: ExitFacts -> [FoldOutput] -> Either String [Payment]
foldPayments facts outputs = (<>) <$> owed <*> refunds
  where
    owing = map (outputs !!) (owedOutputs facts outputs)
    owed = case owedPayee facts of
        OwedCustody -> case owing of
            [custody] -> Right [Payment Custody (outputLovelace custody)]
            _ -> Left "insertAbsent locked no single custody output"
        OwedCarrier -> case owing of
            [carrier] -> Right [Payment (Destination (outputAddress carrier)) (outputLovelace carrier)]
            _ -> Left "the delivered token is carried by no single output"
        OwedOwner -> Right [Payment (Owner (factsOwner facts)) (sum (map outputLovelace owing))]
        OwedBound -> Right [Payment (Owner (factsOwner facts)) (maximum (0 : map outputLovelace owing))]
    -- A reject or a retraction consumes no custody, whatever edge it named.
    refunds = case (factsExit facts, factsEdge facts, factsRefund facts) of
        (Fold, UpdateActive, Just refund) -> custodyRefund refund
        (Fold, DeleteAbsent, Just refund) -> custodyRefund refund
        (Fold, UpdateActive, Nothing) -> Left "updateActive has no observed custody source"
        (Fold, DeleteAbsent, Nothing) -> Left "deleteAbsent has no observed custody source"
        _ -> Right []
    custodyRefund address =
        Right
            [ Payment
                (Refund address)
                (sum [outputLovelace out | out <- outputs, outputAddress out == address, not (outputCarrier out)])
            ]

{- | Whether the chain credits an output to an owner's key: it sits at that
payment key and carries no token the fold delivers.
-}
creditsOwner :: ByteString -> FoldOutput -> Bool
creditsOwner owner out = outputKey out == owner && not (outputCarrier out)

-- | Whom an exit owes its request's payment, and so which outputs pay it.
data OwedPayee = OwedCustody | OwedCarrier | OwedOwner | OwedBound

-- | Whom this exit owes its request's payment: the model's rule, by edge for a
-- fold; a reject owes the owner, a retraction the owner through a bound output.
owedPayee :: ExitFacts -> OwedPayee
owedPayee facts = case (factsExit facts, factsEdge facts) of
    (Reject, _) -> OwedOwner
    (Retract, _) -> OwedBound
    (Fold, InsertAbsent) -> OwedCustody
    (Fold, InsertActive) -> OwedCarrier
    (Fold, UpdateActive) -> OwedCarrier
    (Fold, WitnessTerminal) -> OwedCarrier
    (Fold, UpdateTerminal) -> OwedOwner
    (Fold, DeleteAbsent) -> OwedOwner
    (Fold, DeleteActive) -> OwedOwner

{- | Whether an output returns a retracted request: it credits the owner's key
and its inline datum presents the request's own output reference.
-}
bindsTo :: ByteString -> Maybe Text -> FoldOutput -> Bool
bindsTo owner reference out =
    creditsOwner owner out && outputDatum out == "inline" && isJust reference && outputReference out == reference

{- | The positions of the outputs through which the chain settles what an exit
owes for its request: the custody output an absent insertion locks, the
outputs carrying a token the fold delivers, for a fold delivering nothing and a
reject every output crediting the owner's key, and for a retraction every
output crediting it bound to the retracted request.
-}
owedOutputs :: ExitFacts -> [FoldOutput] -> [Int]
owedOutputs facts outputs = [i | (i, out) <- zip [0 ..] outputs, pays out]
  where
    pays = case owedPayee facts of
        OwedCustody -> outputCustody
        OwedCarrier -> outputCarrier
        OwedOwner -> creditsOwner (factsOwner facts)
        OwedBound -> bindsTo (factsOwner facts) (factsReference facts)

-- | A change to one output of the fold's transaction, by position.
data OutputEdit
    = -- | send the output to another address, value unchanged
      Readdress Int
    | -- | give the output this lovelace
      Relovelace Int Integer
    | -- | bind the output to another output reference
      Rebind Int
    | -- | spend the registry's state beside the request
      SpendState
    deriving stock (Eq, Show)

{- | The edits a tamper makes to the payment an exit owes, read off the exit's
own outputs. 'OtherAddress' sends every output paying it elsewhere.
'ShortByOne' leaves the payee credited one lovelace less than the first output
paying it holds: that output loses one lovelace, every other output paying it
goes elsewhere, and the lovelace taken goes to the transaction's last output,
its change. 'OtherReference' binds every output returning a retracted request to
another output reference, and 'StateSpent' spends the registry's state beside
the retraction; neither applies to another exit. 'ExtraSigner' changes no
output.
-}
tamperEdits :: Tamper -> ExitFacts -> [FoldOutput] -> Either String [OutputEdit]
tamperEdits alteration facts outputs = case (alteration, owedOutputs facts outputs) of
    (BeforePhase2, _) -> Left "a retraction's validity interval is not a payment edit"
    (AfterPhase2, _) -> Left "a retraction's validity interval is not a payment edit"
    (ExtraSigner, _) -> Right []
    (OtherReference, owed) | retraction, not (null owed) -> Right (map Rebind owed)
    (StateSpent, _ : _) | retraction -> Right [SpendState]
    (OtherReference, _) | not retraction -> Left bindingOnly
    (StateSpent, _) | not retraction -> Left bindingOnly
    (_, []) -> Left "the transaction makes no output paying what the exit owes"
    (OtherAddress, owed) -> Right (map Readdress owed)
    (ShortByOne, first : rest)
        | change == first -> Left "the output paying what the fold owes is its last; no change can take the lovelace"
        | outputCarrier changed || outputCustody changed || outputReference changed /= Nothing
            || (not retraction && not (null (outputApprovals changed))) ->
            Left "the last output is not change that pays nothing the exit owes"
        | otherwise ->
            Right
                ( Relovelace first (outputLovelace (outputs !! first) - 1)
                    : map Readdress rest
                    <> [Relovelace change (outputLovelace changed + 1)]
                )
    (_, _) -> Left ("no edit for " <> show alteration)
  where
    change = length outputs - 1
    changed = outputs !! change
    -- A retraction's change may carry the approval the request held: it returns
    -- no bound output, so it pays nothing the retraction owes.
    retraction = factsExit facts == Retract
    bindingOnly = "only a retraction is bound to its request or refused for what it spends"

-- | The owner output as the ledger outputs crediting the owner present it.
data OwnerReading = OwnerReading
    { readingLovelace :: Integer
    -- ^ their summed lovelace
    , readingDatum :: Text
    -- ^ the datum form they share
    , readingApprovals :: [Text]
    -- ^ the distinct approval names they return
    }
    deriving stock (Eq, Show)

{- | Read the owner output off the outputs crediting the owner's key, or
nothing when no output credits it. Outputs presenting different datum forms
cannot be read as one owner output, and are refused.
-}
readOwner :: ByteString -> [FoldOutput] -> Either String (Maybe OwnerReading)
readOwner owner outputs = case filter (creditsOwner owner) outputs of
    [] -> Right Nothing
    credited -> case nub (map outputDatum credited) of
        [form] ->
            Right
                ( Just
                    OwnerReading
                        { readingLovelace = sum (map outputLovelace credited)
                        , readingDatum = form
                        , readingApprovals = nub (concatMap outputApprovals credited)
                        }
                )
        _ -> Left "the outputs crediting the owner present different datum forms"

{- | The observed owner output, in the model's vocabulary: the owner's
identity, the lovelace and datum form read, the registry tokens and state
tokens it holds, the approval it returns, named by @approvalOf@ — the
run's own binding of each booked approval to its model name, which refuses a
name no booking established. Whichever approval the ledger returns is the one
reported, so another request's approval differs from the model's commitment. The
output reference its datum presents, if any, arrives as its identity.
-}
ownerOutputObservation ::
    Integer -> (Text -> Either String Integer) -> [Value] -> Integer -> Maybe Integer -> OwnerReading
    -> Either String Value
ownerOutputObservation owner approvalOf assets stateTokens reference reading = do
    returned <- case readingApprovals reading of
        [] -> Right Null
        [name] -> Number . fromInteger <$> approvalOf name
        _ -> Left "the owner is returned several approvals; the model's owner output names one"
    pure
        ( object
            [ "role" .= String "owner"
            , "datum" .= String (readingDatum reading)
            , "address" .= owner
            , "stateToken" .= stateTokens
            , "inlineConfig" .= Null
            , "commitment" .= returned
            , "assets" .= assets
            , "custodyDatum" .= Null
            , "lovelace" .= readingLovelace reading
            , "reference" .= reference
            ]
        )

{- | Read a retraction's return off the outputs crediting the owner's key and
bound to the output reference the request sat at, or nothing when no output is
bound to it. The chain settles a retraction by one sufficient bound output, so
the return is read as the largest of them, never a sum; whether it is enough
is the judgement's, not the reader's.
-}
readBound :: ByteString -> Text -> [FoldOutput] -> Either String (Maybe OwnerReading)
readBound owner reference outputs = case filter (bindsTo owner (Just reference)) outputs of
    [] -> Right Nothing
    bound@(_ : _) ->
        let largest = maximumBy (comparing outputLovelace) bound
         in Right
                ( Just
                    OwnerReading
                        { readingLovelace = outputLovelace largest
                        , readingDatum = outputDatum largest
                        , readingApprovals = outputApprovals largest
                        }
                )
