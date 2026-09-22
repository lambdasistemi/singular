{- | What the registration comparison must establish.

Appendix material: evidence about our own comparison machinery, not about the
registry. Every case runs the comparison the registration chapter runs —
@Conformance.Compare.Registration.compareRegistration@, which
@checkRegistrationAgainstLean@ calls — over the delivery object that chapter
builds. The expected side and the declared surface are read from the committed
driver corpus, so nothing here is a list written beside the assertion.
-}
module Conformance.Support.RegistrationComparison (spec) where

import Conformance.Compare.Registration (
    Agreement (..),
    Declared (..),
    Difference (..),
    compareRegistration,
    declaredSurface,
    rootOf,
    approvalAssetName,
 )
import Conformance.Story.Identity (identify, observe)
import Conformance.Story.Identity qualified as Identity
import Data.Aeson (Value (..), eitherDecodeFileStrict)
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.List (sort)
import Data.Text (Text)
import Data.Vector qualified as V
import Data.Word (Word8)
import System.Environment (lookupEnv)
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)

-- | The committed corpus, wired in by the package rather than copied here.
corpus :: IO Value
corpus = do
    wired <- lookupEnv "CONFORMANCE_DRIVER_CORPUS"
    path <- case wired of
        Just path -> pure path
        Nothing -> error "CONFORMANCE_DRIVER_CORPUS is not wired; the comparison has no expected side"
    eitherDecodeFileStrict path >>= either error pure

part :: Text -> Value -> Value
part name value = case value of
    Object fields -> case KM.lookup (Key.fromText name) fields of
        Just found -> found
        Nothing -> error ("driver corpus has no " <> show name)
    _ -> error ("not an object while looking for " <> show name)

items :: Value -> [Value]
items value = case value of
    Array vector -> V.toList vector
    _ -> error "expected an array"

number :: Value -> Integer
number value = case value of
    Number n -> truncate n
    _ -> error "expected a number"

scenarios :: Value -> [Value]
scenarios = items . part "scenarios"

row :: Text -> Value -> Value
row identity value =
    case [scenario | scenario <- scenarios value, part "id" scenario == String identity] of
        [found] -> found
        _ -> error ("driver corpus has no scenario " <> show identity)

-- | The leaf byte table the model commits with: absent 0, active 1, terminal 2.
leafByte :: Value -> Word8
leafByte value = case value of
    String "absent" -> 0
    String "active" -> 1
    String "terminal" -> 2
    _ -> 0xFF

-- | Drop one declared observation from an otherwise complete observation.
without :: Text -> Value -> Value
without name value = case value of
    Object fields -> Object (KM.delete (Key.fromText name) fields)
    _ -> error "observations are not an object"

-- | Claim to have observed something the model has no vocabulary for.
claiming :: Text -> Value -> Value
claiming name value = case value of
    Object fields -> Object (KM.insert (Key.fromText name) (String "invented") fields)
    _ -> error "observations are not an object"

-- | Raise the first minted quantity, leaving every other field alone.
raiseMintQuantity :: Value -> Value
raiseMintQuantity value = case value of
    Object fields -> case KM.lookup "mint" fields of
        Just (Array assets) -> case V.toList assets of
            Object asset : rest ->
                let raised = Object (KM.insert "quantity" (Number 99) asset)
                 in Object (KM.insert "mint" (Array (V.fromList (raised : rest))) fields)
            _ -> error "the row mints nothing to raise"
        _ -> error "mint is not an array"
    _ -> error "observations are not an object"

spec :: Spec
spec = describe "Comparing a registration with the model" $ do
    it "accounts for every observation the model declares" $ do
        value <- corpus
        declared <- either error pure (declaredSurface value)
        let observations = part "observations" (row "DR02-register-active" value)
        case compareRegistration declared observations observations of
            Left differences -> error ("an agreeing registration was reported as differing: " <> show differences)
            Right agreement ->
                sort (agreementCompared agreement) `shouldBe` sort (declaredObservations declared)

    it "refuses an observation that leaves any declared field out" $ do
        value <- corpus
        declared <- either error pure (declaredSurface value)
        let observations = part "observations" (row "DR02-register-active" value)
        mapM_
            ( \name -> case compareRegistration declared observations (without name observations) of
                Right _ -> error ("a registration missing " <> show name <> " was accepted")
                Left _ -> pure ()
            )
            (declaredObservations declared)

    it "carries every name the model cannot observe, and compares none of them" $ do
        value <- corpus
        declared <- either error pure (declaredSurface value)
        let observations = part "observations" (row "DR02-register-active" value)
        case compareRegistration declared observations observations of
            Left differences -> error ("an agreeing registration was reported as differing: " <> show differences)
            Right agreement -> do
                sort (agreementUnobserved agreement) `shouldBe` sort (declaredUnobservable declared)
                agreementCompared agreement
                    `shouldSatisfy` all (`notElem` declaredUnobservable declared)

    it "refuses an observation claiming to have seen what the model cannot" $ do
        value <- corpus
        declared <- either error pure (declaredSurface value)
        let observations = part "observations" (row "DR02-register-active" value)
        mapM_
            ( \name -> case compareRegistration declared observations (claiming name observations) of
                Right _ -> error ("a registration claiming " <> show name <> " was accepted")
                Left _ -> pure ()
            )
            (declaredUnobservable declared)

    it "refuses a registration whose delivered quantity differs from the model" $ do
        value <- corpus
        declared <- either error pure (declaredSurface value)
        let observations = part "observations" (row "DR02-register-active" value)
        case compareRegistration declared observations (raiseMintQuantity observations) of
            Right _ -> error "a changed delivered quantity was accepted"
            Left differences ->
                map differenceObservation differences `shouldSatisfy` elem "mint"

    it "refuses to translate a concrete identity that was never bound" $ do
        let bound = snd (identify ("recipient" :: String) Identity.empty)
        observe "recipient" bound `shouldSatisfy` either (const False) (const True)
        observe "a-wallet-nobody-registered" bound
            `shouldSatisfy` either (const True) (const False)

    it "refuses to bind two concrete identities to one model identifier" $ do
        first <- either error pure (Identity.bind ("alice" :: String) 555 Identity.empty)
        Identity.bind "mallory" 555 first `shouldSatisfy` either (const True) (const False)
        Identity.bind "alice" 555 first `shouldSatisfy` either (const False) (const True)

    it "reproduces every row's approval name and destination commitment" $ do
        value <- corpus
        let approvals =
                [ (scenario, approval)
                | scenario <- scenarios value
                , Object _ <- [part "request" scenario]
                , approval <- [part "approval" (part "request" scenario)]
                , approval /= Null
                ]
        approvals `shouldSatisfy` not . null
        mapM_ checkApproval approvals

    it "reproduces every accepted row's root from that row's own trie" $ do
        value <- corpus
        let accepted =
                [ part "observations" scenario
                | scenario <- scenarios value
                , part "outcome" scenario == String "accepted"
                ]
        accepted `shouldSatisfy` not . null
        mapM_ checkRoot accepted

checkRoot :: Value -> IO ()
checkRoot observations = do
    let entries =
            [ (number (part "key" entry), leafByte (part "leaf" entry))
            | entry <- items (part "trie" (part "state" observations))
            ]
        expected = [fromIntegral (number byte) | byte <- items (part "root" observations)]
    rootOf entries `shouldBe` expected


-- | The model's own approval name, recomputed from that row's request tuple.
checkApproval :: (Value, Value) -> IO ()
checkApproval (scenario, approval) = do
    let request = part "request" scenario
        edge = case part "edge" request of
            String e -> e
            _ -> error "request edge is not a string"
        destination = number (part "destination" approval)
    approvalAssetName edge (number (part "key" request)) (number (part "owner" request)) destination
        `shouldBe` Just (number (part "assetName" approval))
    -- The destination commitment is the same function over the same tuple.
    -- A refused row observes nothing, so there is no transaction to read.
    case part "observations" scenario of
        Object _ ->
            case [ out | out <- items (part "outputs" (part "tx" (part "observations" scenario)))
                       , part "role" out == String "destination" ] of
                [out] | part "commitment" out /= Null ->
                    approvalAssetName edge (number (part "key" request)) (number (part "owner" request)) destination
                        `shouldBe` Just (number (part "commitment" out))
                _ -> pure ()
        _ -> pure ()
