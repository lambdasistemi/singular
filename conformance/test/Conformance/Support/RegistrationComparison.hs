{- | What the registration comparison must establish.

Appendix material: evidence about our own comparison machinery, not about the
registry. Every case runs the comparison the registration chapter runs —
@Conformance.Compare.Registration.compareRegistration@, which
@checkRegistrationAgainstLean@ calls — over the delivery object that chapter
builds. The expected side and the declared surface are read from the committed
driver corpus, so nothing here is a list written beside the assertion.
-}
module Conformance.Support.RegistrationComparison (spec) where

import Conformance.Compare.Perturbation (
    Step (..),
    appendAt,
    arrayPaths,
    checkPerturbations,
    isLovelaceFloor,
    leafPaths,
    perturbAt,
    replacing,
    reportedDifferences,
 )
import Conformance.Compare.Registration (
    Agreement (..),
    Declared (..),
    Difference (..),
    approvalAssetName,
    compareRegistration,
    declaredSurface,
    rootOf,
 )
import Conformance.Observe.Payments (OwnerReading (..), ownerOutputObservation)
import Conformance.Story.Identity (identify, observe)
import Conformance.Story.Identity qualified as Identity
import Data.Aeson (Value (..), eitherDecodeFileStrict)
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.List (sort)
import Data.Map.Strict qualified as Map
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

setOutputLovelace :: Int -> Integer -> Value -> Value
setOutputLovelace index amount observations =
    case part "tx" observations of
        Object fields -> case part "outputs" (Object fields) of
            Array outputs ->
                let output = outputs V.! index
                    updated = case output of
                        Object outputFields ->
                            Object (KM.insert "lovelace" (Number (fromInteger amount)) outputFields)
                        _ -> error "transaction output is not an object"
                    tx = Object (KM.insert "outputs" (Array (outputs V.// [(index, updated)])) fields)
                 in replacing "tx" tx observations
            _ -> error "transaction outputs are not an array"
        _ -> error "transaction is not an object"

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

    it "compares transaction output lovelace as a floor" $ do
        value <- corpus
        declared <- either error pure (declaredSurface value)
        let observations = part "observations" (row "DR01-register-absent" value)
            outputs = items (part "outputs" (part "tx" observations))
            positiveFloors =
                [ (index, number (part "lovelace" output))
                | (index, output) <- zip [0 ..] outputs
                , number (part "lovelace" output) > 0
                ]
        positiveFloors `shouldSatisfy` not . null
        let (index, minimumAda) = case positiveFloors of
                first : _ -> first
                [] -> error "the insert-absent model row has no positive output floor"
            below = setOutputLovelace index (minimumAda - 1) observations
            above = setOutputLovelace index (minimumAda + 1) observations
        case compareRegistration declared observations below of
            Right _ -> error "an output below the model's lovelace floor was accepted"
            Left differences ->
                map differenceObservation differences `shouldSatisfy` elem "tx"
        case compareRegistration declared observations above of
            Left differences -> error ("an output above its floor disagreed: " <> show differences)
            Right _ -> pure ()

    it "compares every payment's value as a floor, in paid and in the transaction's refunds" $ do
        value <- corpus
        declared <- either error pure (declaredSurface value)
        let payingRows =
                [ part "observations" scenario
                | scenario <- scenarios value
                , part "outcome" scenario == String "accepted"
                , not (null (items (part "paid" (part "observations" scenario))))
                ]
        payingRows `shouldSatisfy` (> 1) . length
        mapM_ (checkPaymentFloors declared) payingRows

    it "compares a custody refund as a floor: paid in full or more agrees, short is refused" $ do
        value <- corpus
        declared <- either error pure (declaredSurface value)
        -- The refund a custody pays when it is spent is its own recorded
        -- address and value, read off the model's insert-absent row.
        let absent = part "observations" (row "DR01-register-absent" value)
            refunds =
                [ Object (KM.fromList [("address", part "refundAddress" entry), ("value", part "value" entry)])
                | entry <- items (part "custody" absent)
                ]
        refunds `shouldSatisfy` not . null
        let observations = appendPayments refunds (part "observations" (row "DR07-reject-registered-twice" value))
        checkPaymentFloors declared observations

    it "reads the owner output's returned approval off the ledger: another approval is a transaction difference" $ do
        value <- corpus
        declared <- either error pure (declaredSurface value)
        let observations = part "observations" (row "DR03-retire-registered" value)
            outputs = items (part "outputs" (part "tx" observations))
            owners = [(index, output) | (index, output) <- zip [0 ..] outputs, part "role" output == String "owner"]
        (index, modelOwner) <- case owners of
            [found] -> pure found
            _ -> error "the retirement row has no single owner output"
        let commitment = number (part "commitment" modelOwner)
            reading approvals =
                OwnerReading
                    { readingLovelace = number (part "lovelace" modelOwner)
                    , readingDatum = case part "datum" modelOwner of
                        String form -> form
                        _ -> error "datum form is not a string"
                    , readingApprovals = approvals
                    }
            observedWith approvals =
                either error (\owner -> replaceOutput index owner observations) $
                    ownerOutputObservation (number (part "address" modelOwner)) approvalOf [] 0 (reading approvals)
            -- The run's bindings: this request's approval, and another's.
            approvalOf name = case name of
                "requested" -> Right commitment
                "another" -> Right (commitment + 1)
                _ -> Left "observed an approval no booking established"
        case compareRegistration declared observations (observedWith ["requested"]) of
            Left differences -> error ("the request's own returned approval disagreed: " <> show differences)
            Right _ -> pure ()
        case compareRegistration declared observations (observedWith ["another"]) of
            Right _ -> error "an owner output returning another approval was accepted"
            Left differences -> map differenceObservation differences `shouldBe` ["tx"]
        ownerOutputObservation 1 approvalOf [] 0 (reading ["unbooked"])
            `shouldSatisfy` either (const True) (const False)

    it "reports only an extra signer when a transaction also has floor surplus" $ do
        value <- corpus
        declared <- either error pure (declaredSurface value)
        let observations = part "observations" (row "DR02-register-active" value)
            modelOutputs = items (part "outputs" (part "tx" observations))
            modelFloor = case modelOutputs of
                first : _ -> number (part "lovelace" first)
                [] -> error "the model transaction has no outputs"
            surplus = setOutputLovelace 0 (modelFloor + 1) observations
            changedTx = appendAt [Field "signers"] (part "tx" surplus)
            observed = replacing "tx" changedTx surplus
        case compareRegistration declared observations observed of
            Right _ -> error "an extra signer was accepted"
            Left differences ->
                reportedDifferences differences
                    `shouldBe` [("tx", [Field "signers"])]

    it "refuses to translate a concrete identity that was never bound" $ do
        let bound = snd (identify ("recipient" :: String) Identity.empty)
        observe "recipient" bound `shouldSatisfy` either (const False) (const True)
        observe "a-wallet-nobody-registered" bound
            `shouldSatisfy` either (const True) (const False)

    it "refuses to bind two concrete identities to one model identifier" $ do
        first <- either error pure (Identity.bind ("alice" :: String) 555 Identity.empty)
        Identity.bind "mallory" 555 first `shouldSatisfy` either (const True) (const False)
        Identity.bind "alice" 555 first `shouldSatisfy` either (const False) (const True)

    it "reports observable changes and allows output floor surplus" $ do
        value <- corpus
        declared <- either error pure (declaredSurface value)
        let observations = part "observations" (row "DR02-register-active" value)
            -- Discovered by walking the row, never listed here.
            changes =
                [ (name, path, replacing name (perturbAt path inner) observations)
                | name <- declaredObservations declared
                , inner <- [part name observations]
                , path <- leafPaths inner
                ]
            growths =
                [ (name, path, replacing name (appendAt path inner) observations)
                | name <- declaredObservations declared
                , inner <- [part name observations]
                , path <- arrayPaths inner
                ]
        -- Every declared observation contributes at least one perturbation.
        -- An empty array such as `custody` or `paid` has no leaf to change, so
        -- its discovered variant is the one with an element appended.
        [ name
          | name <- declaredObservations declared
          , null [() | (n, _, _) <- changes <> growths, n == name]
          ]
            `shouldBe` []
        -- and the transaction contributes the fields a reader would name
        let txLeaves = [path | ("tx", path, _) <- changes]
        map (Field "outputs" :) [[Index 1, Field "address"], [Index 1, Field "datum"]]
            `shouldSatisfy` all (`elem` txLeaves)
        txLeaves `shouldSatisfy` any (\path -> Field "assets" `elem` path)
        -- The wrong-signer control: signers is an empty list, so its discovered
        -- variant is the one with an element appended, and it must be refused.
        [path | ("tx", path, _) <- growths, path == [Field "signers"]]
            `shouldBe` [[Field "signers"]]
        -- Raising output lovelace is accepted as a floor surplus.
        let floorSurpluses = [(name, path) | (name, path, _) <- changes, isLovelaceFloor name path]
        floorSurpluses `shouldSatisfy` not . null
        [(name, path) | (name, path, _) <- changes <> growths, isLovelaceFloor name path]
            `shouldBe` floorSurpluses
        mapM_ (requireVerdict declared observations) (changes <> growths)
        case checkPerturbations declared observations observations of
            Left diagnostic -> error ("the perturbation walk failed: " <> diagnostic)
            Right (refused, byObservation, acceptedFloors) -> do
                refused `shouldBe` length (changes <> growths)
                Map.lookup "tx" byObservation
                    `shouldBe` Just (length [() | ("tx", _, _) <- changes <> growths])
                acceptedFloors `shouldBe` map (show . snd) floorSurpluses

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
            case [ out
                 | out <- items (part "outputs" (part "tx" (part "observations" scenario)))
                 , part "role" out == String "destination"
                 ] of
                [out]
                    | part "commitment" out /= Null ->
                        approvalAssetName edge (number (part "key" request)) (number (part "owner" request)) destination
                            `shouldBe` Just (number (part "commitment" out))
                _ -> pure ()
        _ -> pure ()

{- | Every payment of one row, in @paid@ and in @tx.refunds@: one lovelace more
than the model's floor agrees, one lovelace less is refused under the
observation that carries it. The two lists are moved together, as the chain
reports them together.
-}
checkPaymentFloors :: Declared -> Value -> IO ()
checkPaymentFloors declared observations = do
    let payments = items (part "paid" observations)
        refunds = items (part "refunds" (part "tx" observations))
    refunds `shouldBe` payments
    mapM_
        ( \(index, payment) -> do
            let floor' = number (part "value" payment)
                moved amount = setPaymentValue index amount observations
            case compareRegistration declared observations (moved (floor' + 1)) of
                Left differences -> error ("a payment above its floor disagreed: " <> show differences)
                Right _ -> pure ()
            case compareRegistration declared observations (moved (floor' - 1)) of
                Right _ -> error "a payment below the model's floor was accepted"
                Left differences ->
                    sort (map differenceObservation differences) `shouldBe` ["paid", "tx"]
        )
        (zip [0 ..] payments)

-- | Replace transaction output @index@.
replaceOutput :: Int -> Value -> Value -> Value
replaceOutput index output observations = case part "tx" observations of
    Object fields -> case part "outputs" (Object fields) of
        Array outputs ->
            replacing "tx" (Object (KM.insert "outputs" (Array (outputs V.// [(index, output)])) fields)) observations
        _ -> error "transaction outputs are not an array"
    _ -> error "transaction is not an object"

-- | Append payments to both @paid@ and @tx.refunds@, as a fold that also spent them would report.
appendPayments :: [Value] -> Value -> Value
appendPayments extra observations =
    let grow entries = case entries of
            Array vector -> Array (vector <> V.fromList extra)
            _ -> error "payments are not an array"
        tx = case part "tx" observations of
            Object fields -> Object (KM.insert "refunds" (grow (part "refunds" (Object fields))) fields)
            _ -> error "transaction is not an object"
     in replacing "tx" tx (replacing "paid" (grow (part "paid" observations)) observations)

-- | Set the value of payment @index@ in both @paid@ and @tx.refunds@.
setPaymentValue :: Int -> Integer -> Value -> Value
setPaymentValue index amount observations =
    let setValue entries = case entries of
            Array vector ->
                Array
                    ( vector
                        V.// [
                                 ( index
                                 , case vector V.! index of
                                    Object fields -> Object (KM.insert "value" (Number (fromInteger amount)) fields)
                                    _ -> error "a payment is not an object"
                                 )
                             ]
                    )
            _ -> error "payments are not an array"
        tx = case part "tx" observations of
            Object fields -> Object (KM.insert "refunds" (setValue (part "refunds" (Object fields))) fields)
            _ -> error "transaction is not an object"
     in replacing "tx" tx (replacing "paid" (setValue (part "paid" observations)) observations)

requireVerdict :: Declared -> Value -> (Text, [Step], Value) -> IO ()
requireVerdict declared expected (name, path, changed)
    | isLovelaceFloor name path =
        case compareRegistration declared expected changed of
            Right _ -> pure ()
            Left differences ->
                error ("the unobservable leaf " <> show path <> " was compared: " <> show differences)
    | otherwise =
        case compareRegistration declared expected changed of
            Right _ -> error ("a changed " <> show name <> " at " <> show path <> " was accepted")
            Left differences ->
                map differenceObservation differences
                    `shouldSatisfy` elem name
