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


-- | Where a value sits inside an observation.
data Step = Field Text | Index Int
    deriving (Eq, Show)

-- | Every leaf path in a value, discovered by walking it.
leafPaths :: Value -> [[Step]]
leafPaths value = case value of
    Object fields ->
        [Field (Key.toText name) : rest | (name, inner) <- KM.toList fields, rest <- leafPaths inner]
    Array entries ->
        [Index index : rest | (index, inner) <- zip [0 ..] (V.toList entries), rest <- leafPaths inner]
    _ -> [[]]

-- | Every array inside a value, including the empty ones.
arrayPaths :: Value -> [[Step]]
arrayPaths value = case value of
    Object fields ->
        [Field (Key.toText name) : rest | (name, inner) <- KM.toList fields, rest <- arrayPaths inner]
    Array entries ->
        [] : [Index index : rest | (index, inner) <- zip [0 ..] (V.toList entries), rest <- arrayPaths inner]
    _ -> []

-- | Change the value at a path: a number grows, a string gains a suffix, a
-- boolean flips. Nothing else in the observation moves.
perturbAt :: [Step] -> Value -> Value
perturbAt [] value = case value of
    Number n -> Number (n + 1)
    String s -> String (s <> "-changed")
    Bool b -> Bool (not b)
    Null -> String "changed"
    other -> other
perturbAt (Field name : rest) value = case value of
    Object fields -> case KM.lookup (Key.fromText name) fields of
        Just inner -> Object (KM.insert (Key.fromText name) (perturbAt rest inner) fields)
        Nothing -> value
    _ -> value
perturbAt (Index index : rest) value = case value of
    Array entries
        | index < V.length entries ->
            Array (entries V.// [(index, perturbAt rest (entries V.! index))])
    _ -> value

-- | Append one element to the array at a path, so an empty list is covered too.
appendAt :: [Step] -> Value -> Value
appendAt [] value = case value of
    Array entries -> Array (V.snoc entries (String "appended"))
    other -> other
appendAt (Field name : rest) value = case value of
    Object fields -> case KM.lookup (Key.fromText name) fields of
        Just inner -> Object (KM.insert (Key.fromText name) (appendAt rest inner) fields)
        Nothing -> value
    _ -> value
appendAt (Index index : rest) value = case value of
    Array entries
        | index < V.length entries ->
            Array (entries V.// [(index, appendAt rest (entries V.! index))])
    _ -> value

{- | The one leaf the comparison is allowed to ignore: a transaction output's
lovelace, which the model names @outputMinimumAda@ and states as a logical zero.
-}
isOutputMinimumAda :: Text -> [Step] -> Bool
isOutputMinimumAda "tx" [Field "outputs", Index _, Field "lovelace"] = True
isOutputMinimumAda _ _ = False

-- | Put a changed observation back beside the others.
replacing :: Text -> Value -> Value -> Value
replacing name inner value = case value of
    Object fields -> Object (KM.insert (Key.fromText name) inner fields)
    _ -> value

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


    it "reports a change to any observable value, and ignores only the unobservable one" $ do
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
        -- Exactly one leaf may be ignored, and it is the named unobservable.
        let ignored = [(name, path) | (name, path, _) <- changes, isOutputMinimumAda name path]
        ignored `shouldSatisfy` not . null
        [(name, path) | (name, path, _) <- changes <> growths, isOutputMinimumAda name path]
            `shouldBe` ignored
        mapM_ (requireVerdict declared observations) (changes <> growths)

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

requireVerdict :: Declared -> Value -> (Text, [Step], Value) -> IO ()
requireVerdict declared expected (name, path, changed)
    | isOutputMinimumAda name path =
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
