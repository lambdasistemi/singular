{- | The payments an accepted fold made, read off its transaction.

The chain settles a fold per payee. A fold that delivers a token pays the
deposit with it: the output carrying the token holds at least the deposit. A
fold that delivers nothing pays the request's owner: the owner is credited the
summed lovelace of every output at the owner's payment key that carries no
token the fold delivers. An absent insertion locks the deposit in the custody
output it creates. A spent custody's refund address is credited the summed
lovelace of every output at that address carrying no delivered token. Every
amount is read as the chain paid it, never selected by the amount the model
expects, so a short or surplus payment reaches the comparison. This module
reads those payments in the chain's own terms — addresses, keys and lovelace —
and leaves their translation to model identities to the live runner, which
allocated them.
-}
module Conformance.Observe.Payments (
    FoldOutput (..),
    FoldFacts (..),
    Payee (..),
    Payment (..),
    foldPayments,
    creditsOwner,
    OwnerReading (..),
    readOwner,
    ownerOutputObservation,
) where

import Conformance.Story.Live (Edge (..))
import Data.Aeson (Value (..), object, (.=))
import Data.ByteString (ByteString)
import Data.List (nub)
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
    }
    deriving stock (Eq, Show)

-- | What the chain records about the fold beside its outputs.
data FoldFacts = FoldFacts
    { factsEdge :: Edge
    , factsOwner :: ByteString
    -- ^ the payment key hash the request names as its owner
    , factsCustody :: Maybe Integer
    -- ^ the lovelace of the custody output this fold locked, if it locked one
    , factsRefund :: Maybe ByteString
    -- ^ the refund address of the custody this fold spent
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
foldPayments :: FoldFacts -> [FoldOutput] -> Either String [Payment]
foldPayments facts outputs = (<>) <$> owed <*> refunds
  where
    owed = case factsEdge facts of
        InsertAbsent -> case factsCustody facts of
            Just lovelace -> Right [Payment Custody lovelace]
            Nothing -> Left "insertAbsent locked no custody output"
        InsertActive -> delivered
        UpdateActive -> delivered
        WitnessTerminal -> delivered
        UpdateTerminal -> returned
        DeleteAbsent -> returned
        DeleteActive -> returned
    delivered = case filter outputCarrier outputs of
        [carrier] -> Right [Payment (Destination (outputAddress carrier)) (outputLovelace carrier)]
        _ -> Left "the delivered token is carried by no single output"
    returned =
        Right
            [ Payment
                (Owner (factsOwner facts))
                (sum [outputLovelace out | out <- outputs, creditsOwner (factsOwner facts) out])
            ]
    refunds = case (factsEdge facts, factsRefund facts) of
        (UpdateActive, Just refund) -> custodyRefund refund
        (DeleteAbsent, Just refund) -> custodyRefund refund
        (UpdateActive, Nothing) -> Left "updateActive has no observed custody source"
        (DeleteAbsent, Nothing) -> Left "deleteAbsent has no observed custody source"
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
tokens it holds, and the approval it returns, named by @approvalOf@ — the
run's own binding of each booked approval to its model name, which refuses a
name no booking established. Whichever approval the ledger returns is the one
reported, so another request's approval differs from the model's commitment.
-}
ownerOutputObservation ::
    Integer -> (Text -> Either String Integer) -> [Value] -> Integer -> OwnerReading -> Either String Value
ownerOutputObservation owner approvalOf assets stateTokens reading = do
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
            ]
        )
