{-# LANGUAGE LambdaCase #-}

{- |
Module      : Singular.Registry.StateTokenSpec
Description : A state token resolved into a registry, and its references found by hash
License     : Apache-2.0

The registry of "Singular.Registry.StateTokenFixture", booted from one
seed, is resolved from its state token alone: each identity refusal is
caused in isolation and in competition with every later one, and the
resolved registry is compared with what the boot derived. Reference
carriers are admitted by the hash computed from their own script, looked
for in the provider, then the hints, then the wallet, and chosen by the
lowest output reference within the first source that has one.
-}
module Singular.Registry.StateTokenSpec (spec) where

import Control.Monad (void)
import Data.Bifunctor (first)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Short qualified as SBS
import Data.IORef (newIORef, readIORef)
import Data.List (sortOn)
import Data.Map.Strict qualified as Map
import Data.Ord (Down (..))
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Lens.Micro ((&), (.~))
import Test.Hspec

import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.Api.Tx.Out
    ( TxOut
    , addrTxOutL
    , datumTxOutL
    , mkBasicTxOut
    , valueTxOutL
    )
import Cardano.Ledger.BaseTypes (Network (Testnet))
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Core (Script, hashScript)
import Cardano.Ledger.Hashes (ScriptHash)
import Cardano.Ledger.Mary.Value
    ( AssetName (..)
    , MaryValue (..)
    , MultiAsset (..)
    , PolicyID (..)
    )
import Cardano.Ledger.Plutus.Data (Datum (NoDatum))
import Cardano.Ledger.TxIn (TxIn)
import PlutusTx.Builtins.Internal (BuiltinByteString (..))

import Singular.Application.OpenDatum.Value (openDatumApplication)
import Singular.Registry.Application (appPin)
import Singular.Registry.Config (CageConfig (..))
import Singular.Registry.Ledger (ConwayEra)
import Singular.Registry.LedgerProvider qualified as LP
import Singular.Registry.StateToken
import Singular.Registry.StateTokenFixture
import Singular.Registry.TxBuilder.Internal
    ( addrFromKeyHashBytes
    , cageAddrFromCfg
    , scriptFromBytes
    , scriptHashBytes
    )
import Singular.Registry.Types (OnChainTokenState (..))

spec :: Spec
spec = do
    stateTokens
    expectedHashes
    resolution
    refusals
    carriers
    search

-- ---------------------------------------------------------------------------
-- The state token on the command line
-- ---------------------------------------------------------------------------

stateTokens :: Spec
stateTokens = describe "a state token as the command line spells it" $ do
    it "reads POLICY.NAME, two hex parts, and spells it back" $ do
        let spelled = spelling token
        parseStateToken spelled `shouldBe` Right token
        renderStateToken token `shouldBe` spelled
    it "refuses every other shape before any provider is asked" $ do
        parseStateToken (spelling token) `shouldBe` Right token
        let (policyHex, nameHex) = T.breakOn "." (spelling token)
            name = T.drop 1 nameHex
        mapM_
            (\bad -> parseStateToken bad `shouldSatisfy` isLeft)
            [ ""
            , policyHex
            , policyHex <> name
            , T.drop 2 policyHex <> "." <> name
            , policyHex <> "." <> T.drop 2 name
            , policyHex <> "00." <> name
            , policyHex <> "." <> name <> "00"
            , policyHex <> "." <> T.replace (T.take 1 name) "z" name
            , policyHex <> "." <> name <> "." <> name
            ]

-- ---------------------------------------------------------------------------
-- Expected hashes
-- ---------------------------------------------------------------------------

expectedHashes :: Spec
expectedHashes = describe "the hashes a registry's references must carry" $ do
    it "names every role" $
        Map.keys
            (expectedReferences (appPin openDatumApplication) release token)
            `shouldBe` [minBound .. maxBound]
    it
        "are the hashes of the scripts the boot published, derived from the token alone"
        $ do
            let published =
                    Map.fromList
                        [ (role, hashScript script)
                        | (name, script) <- bootScripts
                        , Just role <- [testParseRole name]
                        ]
            Map.size published `shouldBe` length bootScripts
            expectedReferences (appPin openDatumApplication) release token
                `shouldBe` published
    it "spell their roles as receipts do" $
        map
            (roleName . fst)
            ( Map.toAscList
                (expectedReferences (appPin openDatumApplication) release token)
            )
            `shouldBe` map fst bootScripts
    it
        "differ between two registries of one release in everything but the state script"
        $ do
            let other = tokenOf (refOf (T.replicate 64 "4" <> "#2"))
                here = expectedReferences (appPin openDatumApplication) release token
                there = expectedReferences (appPin openDatumApplication) release other
            Map.lookup RoleState here `shouldBe` Map.lookup RoleState there
            [ role
              | role <- [minBound .. maxBound]
              , role /= RoleState
              , Map.lookup role here == Map.lookup role there
              ]
                `shouldBe` []

-- ---------------------------------------------------------------------------
-- Resolution
-- ---------------------------------------------------------------------------

resolution :: Spec
resolution = describe "resolving the state token" $ do
    it
        "finds the seed, the creation, the state output and the pins the boot made"
        $ do
            (result, _) <- resolveOn honestChain token
            case result of
                Left refusal -> expectationFailure (show refusal)
                Right r -> do
                    resolvedToken r `shouldBe` token
                    resolvedSeed r `shouldBe` seedIn
                    resolvedCreation r `shouldBe` creationTx
                    fst (resolvedState r) `shouldBe` stateIn
                    snd (resolvedState r) `shouldBe` stateOutput bootState
                    resolvedDatum r `shouldBe` bootState
                    resolvedExpected r `shouldBe` bootExpected
                    resolvedNetwork r `shouldBe` LP.Network 42
                    pins (resolvedConfig r) `shouldBe` pins bootCfg
                    cageSeed (resolvedConfig r) `shouldBe` cageSeed bootCfg
    it "reads the windows and the tip from the datum, not from a default" $ do
        let st =
                bootState
                    { stateProcessTime = 912_000
                    , stateRetractTime = 456_000
                    , stateMaxFee = 4_500_000
                    }
        (result, _) <- resolveOn (withState st honestChain) token
        case result of
            Left refusal -> expectationFailure (show refusal)
            Right r -> do
                defaultProcessTime (resolvedConfig r) `shouldBe` 912_000
                defaultRetractTime (resolvedConfig r) `shouldBe` 456_000
                defaultTip (resolvedConfig r) `shouldBe` Coin 4_500_000

-- ---------------------------------------------------------------------------
-- The seven refusals
-- ---------------------------------------------------------------------------

-- | One cause of each refusal, in checking order, applied to a chain.
data Fault = Fault
    { faultName :: Text
    , faultApply :: (Chain, LP.Asset) -> (Chain, LP.Asset)
    }

faults :: [Fault]
faults =
    [ Fault "state-token-foreign-release" $ \(c, (_, name)) ->
        (c, (PolicyID (hashScript otherScript), name))
    , Fault "state-token-not-found" $ first $ \c -> c{chainMints = Map.empty}
    , Fault "state-token-burned" $ first $ \c ->
        c{chainMints = Map.map (\m -> m{LP.mintSupply = 0}) (chainMints c)}
    , Fault "state-token-seed-mismatch" $ first $ \c ->
        c
            { chainMints =
                Map.map
                    ( \m -> m{LP.mintSpentInputs = filter (/= seedIn) (LP.mintSpentInputs m)}
                    )
                    (chainMints c)
            }
    , Fault "state-output-missing" $ first $ \c ->
        c{chainOutputs = Map.delete stateIn (chainOutputs c)}
    , Fault "registry-pin-mismatch application" $
        first (withState bootState{stateAppPolicy = otherPin})
    , Fault "network-mismatch" $ first $ \c ->
        c{chainNetwork = LP.Network 764_824_073}
    ]

refusals :: Spec
refusals = describe "the identity refusals" $ do
    it "fire each for its own cause, alone" $
        mapM_
            ( \f -> do
                let (chain, asked) = faultApply f (honestChain, token)
                (result, _) <- resolveOn chain asked
                void result `shouldSatisfy` refusedAs (faultName f)
            )
            faults
    it "fire in the declared order when causes compete" $
        mapM_
            ( \(earlier, later) -> do
                let (chain, asked) =
                        faultApply earlier (faultApply later (honestChain, token))
                (result, _) <- resolveOn chain asked
                void result `shouldSatisfy` refusedAs (faultName earlier)
            )
            [ (faults !! i, faults !! j)
            | i <- [0 .. length faults - 1]
            , j <- [i + 1 .. length faults - 1]
            ]
    it "name the pin that differs, for each of the four" $
        mapM_
            ( \(field, st) -> do
                (result, _) <- resolveOn (withState st honestChain) token
                void result
                    `shouldBe` Left (RegistryPinMismatch field)
            )
            [ (PinApplication, bootState{stateAppPolicy = otherPin})
            , (PinActive, bootState{stateActivePolicy = otherPin})
            , (PinAbsent, bootState{stateAbsentPolicy = otherPin})
            , (PinTerminal, bootState{stateTerminalPolicy = otherPin})
            ]
    it "refuse a foreign release before the provider is asked anything" $ do
        foreignFault <- case faults of
            f : _ -> pure f
            [] -> fail "no faults"
        let (chain, asked) = faultApply foreignFault (honestChain, token)
        (result, reads') <- resolveOn chain asked
        void result
            `shouldSatisfy` refusedAs "state-token-foreign-release"
        reads' `shouldBe` []
    it
        "refuse a token held only away from the state address, or without a state datum"
        $ do
            let moved =
                    honestChain
                        { chainOutputs =
                            Map.singleton
                                stateIn
                                (relocated (stateOutput bootState))
                        }
                undated =
                    honestChain
                        { chainOutputs =
                            Map.singleton stateIn (withoutDatum (stateOutput bootState))
                        }
            mapM_
                ( \chain -> do
                    (result, _) <- resolveOn chain token
                    void result
                        `shouldSatisfy` refusedAs "state-output-missing"
                )
                [moved, undated]
    it
        "refuse a state output that does not hold the token, whatever the provider says holds it"
        $ do
            found <-
                traverse
                    ( \(what, impostor) -> do
                        let chain = claimedHolders [(stateIn, impostor)] honestChain
                        (result, _) <- resolveOn chain token
                        pure (what, void result)
                    )
                    impostors
            found
                `shouldBe` [(what, Left StateOutputMissing) | (what, _) <- impostors]
    it
        "pass over impostors listed before the output that holds the token"
        $ do
            found <-
                traverse
                    ( \(what, impostor) -> do
                        let chain =
                                claimedHolders
                                    [(decoyIn, impostor), (stateIn, stateOutput bootState)]
                                    honestChain
                        (result, _) <- resolveOn chain token
                        pure (what, fmap (fst . resolvedState) result)
                    )
                    impostors
            found `shouldBe` [(what, Right stateIn) | (what, _) <- impostors]
    it
        "keep the declared order when an impostor competes with a later cause"
        $ do
            let mismatched = stateOutput bootState{stateAppPolicy = otherPin}
                chain =
                    claimedHolders
                        [(stateIn, holdingOnly Nothing mismatched)]
                        honestChain
            (result, _) <- resolveOn chain token
            void result `shouldBe` Left StateOutputMissing
    it "render each refusal starting with its name" $
        mapM_
            ( \(refusal, name) ->
                renderIdentityRefusal refusal `shouldSatisfy` T.isPrefixOf name
            )
            [
                ( StateTokenForeignRelease (hashScript otherScript)
                , "state-token-foreign-release"
                )
            , (StateTokenNotFound, "state-token-not-found")
            , (StateTokenBurned 0, "state-token-burned")
            , (StateTokenSeedMismatch creationTx, "state-token-seed-mismatch")
            , (StateOutputMissing, "state-output-missing")
            ,
                ( RegistryPinMismatch PinApplication
                , "registry-pin-mismatch application"
                )
            , (RegistryPinMismatch PinActive, "registry-pin-mismatch active")
            , (RegistryPinMismatch PinAbsent, "registry-pin-mismatch absent")
            , (RegistryPinMismatch PinTerminal, "registry-pin-mismatch terminal")
            , (NetworkMismatch (LP.Network 764_824_073), "network-mismatch")
            ]

-- ---------------------------------------------------------------------------
-- Carriers
-- ---------------------------------------------------------------------------

carriers :: Spec
carriers = describe "a reference carrier" $ do
    it "is admitted by the hash computed from the script it carries" $
        mapM_
            ( \(_, script) ->
                carriesReference (hashScript script) (carrierOf script)
                    `shouldBe` True
            )
            bootScripts
    it "is refused for any other expected hash, and without a script" $ do
        let hashes = map (hashScript . snd) bootScripts
        sequence_
            [ carriesReference wanted (carrierOf script) `shouldBe` False
            | (_, script) <- bootScripts
            , wanted <- hashes
            , wanted /= hashScript script
            ]
        mapM_ (\h -> carriesReference h plain `shouldBe` False) hashes

-- ---------------------------------------------------------------------------
-- The search
-- ---------------------------------------------------------------------------

search :: Spec
search = describe "finding the references a command needs" $ do
    it
        "takes the provider's lowest admitted carrier, whatever order the provider lists them in"
        $ do
            let (role, script) = needed RoleRequest
                low = refOf (T.replicate 64 "a" <> "#5")
                high = refOf (T.replicate 64 "b" <> "#0")
                chain = carrying [(low, script), (high, script)] Reverse honestChain
            (found, _) <- searchOn chain (Set.singleton role)
            fmap (Map.map fst) found `shouldBe` Right (Map.singleton role low)
    it
        "never admits a carrier the provider names for a hash its script does not have"
        $ do
            let (role, script) = needed RoleRequest
                liar = refOf (T.replicate 64 "0" <> "#0")
                honest = refOf (T.replicate 64 "c" <> "#0")
                chain =
                    honestChain
                        { chainOutputs =
                            Map.fromList
                                [(liar, carrierOf otherScript), (honest, carrierOf script)]
                                <> chainOutputs honestChain
                        , chainCarriers = \h ->
                            if h == hashScript script
                                then [(liar, carrierOf otherScript), (honest, carrierOf script)]
                                else []
                        }
            (found, _) <- searchOn chain (Set.singleton role)
            fmap (Map.map fst) found `shouldBe` Right (Map.singleton role honest)
    it
        "does not read the wallet when the provider carries every role the command runs"
        $ do
            let wanted = [RoleRequest, RoleApplication]
                fromProvider =
                    [ ( refOf (T.pack (replicate 63 'f' <> show (fromEnum r)) <> "#0")
                      , snd (needed r)
                      )
                    | r <- wanted
                    ]
                inWallet =
                    [ ( refOf (T.pack (replicate 63 '1' <> show (fromEnum r)) <> "#0")
                      , snd (needed r)
                      )
                    | r <- wanted
                    ]
                chain = inTheWallet inWallet (carrying fromProvider Forward honestChain)
            (found, reads') <- searchOn chain (Set.fromList wanted)
            fmap (Map.map fst) found
                `shouldBe` Right (Map.fromList (zip wanted (map fst fromProvider)))
            filter walletRead reads' `shouldBe` []
    it
        "takes the wallet's lowest admitted carrier when the provider has none"
        $ do
            let (role, script) = needed RoleWitnessActive
                low = refOf (T.replicate 64 "9" <> "#4")
                high = refOf (T.replicate 64 "a" <> "#0")
                wrongScript = refOf (T.replicate 64 "2" <> "#0")
                noScript = refOf (T.replicate 64 "3" <> "#0")
                chain =
                    inTheWallet
                        [(high, script), (low, script), (wrongScript, otherScript)]
                        honestChain
                            { chainOutputs =
                                Map.insert noScript (atWallet plain) (chainOutputs honestChain)
                            }
            (found, reads') <- searchOn chain (Set.singleton role)
            fmap (Map.map fst) found `shouldBe` Right (Map.singleton role low)
            length (filter walletRead reads') `shouldBe` 1
    it
        "refuses a role neither the provider nor the wallet carries, naming its hash and the remedy"
        $ do
            let wanted = Set.fromList [RoleWitnessAbsent, RoleWitnessTerminal]
                hash = bootExpected Map.! RoleWitnessAbsent
            (found, _) <- searchOn honestChain wanted
            found `shouldBe` Left (ReferenceMissing RoleWitnessAbsent hash)
            renderReferenceRefusal (ReferenceMissing RoleWitnessAbsent hash)
                `shouldBe` ( "reference-missing witness-absent "
                                <> hashHex hash
                                <> ": not found by this provider or wallet; publish it with singular registry publish-references"
                           )
    it "reads nothing when the command runs no reference script" $ do
        let published =
                [ (refOf (T.pack (replicate 63 c <> "1") <> "#0"), script)
                | (c, (_, script)) <- zip "abcdef" bootScripts
                ]
            chain = carrying published Forward honestChain
        (found, reads') <- searchOn chain Set.empty
        found `shouldBe` Right Map.empty
        reads' `shouldBe` []
    it "looks up only the roles the command runs" $ do
        let wanted = Set.fromList [RoleRequest, RoleApplication]
            published =
                [ (refOf (T.pack (replicate 63 c <> "1") <> "#0"), script)
                | (c, (_, script)) <- zip "abcdef" bootScripts
                ]
            chain = carrying published Forward honestChain
        (found, reads') <- searchOn chain wanted
        fmap Map.keysSet found `shouldBe` Right wanted
        length (filter ("CarryingReferenceScript" `T.isPrefixOf`) reads')
            `shouldBe` 2

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

resolveOn
    :: Chain
    -> LP.Asset
    -> IO (Either IdentityRefusal ResolvedRegistry, [Text])
resolveOn chain asked = do
    logRef <- newIORef []
    result <-
        resolveRegistry
            openDatumApplication
            release
            asked
            (chainSession logRef chain)
    reads' <- readIORef logRef
    pure (result, reads')

{- | Search the chain for the roles, from the actor's wallet at
'walletAddress', returning the outcome and every read the search made.
-}
searchOn
    :: Chain
    -> Set.Set ReferenceRole
    -> IO
        ( Either
            ReferenceRefusal
            (Map.Map ReferenceRole (TxIn, TxOut ConwayEra))
        , [Text]
        )
searchOn chain wanted = do
    logRef <- newIORef []
    found <-
        findReferences
            (chainSession logRef chain)
            (Just walletAddress)
            bootExpected
            wanted
    reads' <- readIORef logRef
    pure (found, reads')

-- | The actor's own wallet address.
walletAddress :: Addr
walletAddress = addrFromKeyHashBytes Testnet (BS.replicate 28 0x77)

-- | The output moved to the actor's wallet.
atWallet :: TxOut ConwayEra -> TxOut ConwayEra
atWallet o = o & addrTxOutL .~ walletAddress

-- | The chain with these carriers live in the actor's wallet, unlisted by the provider.
inTheWallet :: [(TxIn, Script ConwayEra)] -> Chain -> Chain
inTheWallet held chain =
    chain
        { chainOutputs =
            Map.fromList [(i, atWallet (carrierOf s)) | (i, s) <- held]
                <> chainOutputs chain
        }

-- | Whether a read was of the actor's wallet.
walletRead :: Text -> Bool
walletRead = (== T.pack (show (LP.AtAddress walletAddress)))

{- | A receipt name to its role, written by hand from the six names the
boot publishes, never by the code under test.
-}
testParseRole :: Text -> Maybe ReferenceRole
testParseRole = \case
    "state" -> Just RoleState
    "request" -> Just RoleRequest
    "witness-absent" -> Just RoleWitnessAbsent
    "witness-active" -> Just RoleWitnessActive
    "witness-terminal" -> Just RoleWitnessTerminal
    "application" -> Just RoleApplication
    _ -> Nothing

-- | The hashes the boot published, by role, from the fixture scripts alone.
bootExpected :: Map.Map ReferenceRole ScriptHash
bootExpected =
    Map.fromList
        [ (role, hashScript script)
        | (name, script) <- bootScripts
        , Just role <- [testParseRole name]
        ]

-- | The role and the script the boot published for it.
needed :: ReferenceRole -> (ReferenceRole, Script ConwayEra)
needed role =
    case [ script
         | (name, script) <- bootScripts
         , testParseRole name == Just role
         ] of
        [script] -> (role, script)
        _ -> error ("no boot script for " <> show role)

data Listing = Forward | Reverse

-- | The chain with these carriers live and listed by the provider.
carrying :: [(TxIn, Script ConwayEra)] -> Listing -> Chain -> Chain
carrying published listing chain =
    chain
        { chainOutputs =
            Map.fromList [(i, carrierOf s) | (i, s) <- published]
                <> chainOutputs chain
        , chainCarriers = \h ->
            order
                [ (i, carrierOf s)
                | (i, s) <- sortOn fst published
                , hashScript s == h
                ]
        }
  where
    order = case listing of
        Forward -> id
        Reverse -> map snd . sortOn (Down . fst) . map (\u -> (fst u, u))

{- | The chain whose provider names these outputs, live, as the holders of
any asset, the way an unverified answer may.
-}
claimedHolders :: [(TxIn, TxOut ConwayEra)] -> Chain -> Chain
claimedHolders listed chain =
    chain
        { chainOutputs = Map.fromList listed <> chainOutputs chain
        , chainHolders = Just listed
        }

{- | Outputs at the state address with a valid state datum that do not hold
the token: no asset at all, the token's name under another policy, another
name under the token's policy.
-}
impostors :: [(String, TxOut ConwayEra)]
impostors =
    [ ("tokenless", holdingOnly Nothing genuine)
    ,
        ( "wrong policy"
        , holdingOnly (Just (PolicyID (hashScript otherScript), name)) genuine
        )
    ,
        ( "wrong name"
        , holdingOnly
            (Just (policy, AssetName (SBS.toShort (BS.replicate 32 0xab))))
            genuine
        )
    ]
  where
    (policy, name) = token
    genuine = stateOutput bootState

-- | The output with its assets replaced by one unit of this one, or none.
holdingOnly :: Maybe LP.Asset -> TxOut ConwayEra -> TxOut ConwayEra
holdingOnly held o = o & valueTxOutL .~ MaryValue (Coin 2_000_000) assets
  where
    assets = case held of
        Nothing -> mempty
        Just (p, n) -> MultiAsset (Map.singleton p (Map.singleton n 1))

-- | An output reference lower than the state output's.
decoyIn :: TxIn
decoyIn = refOf (T.replicate 64 "0" <> "#0")

withState :: OnChainTokenState -> Chain -> Chain
withState st chain =
    chain
        { chainOutputs =
            Map.insert stateIn (stateOutput st) (chainOutputs chain)
        }

refusedAs :: Text -> Either IdentityRefusal () -> Bool
refusedAs name = \case
    Left refusal -> refusalName refusal == name
    Right () -> False

-- | The refusal's name as the data model spells it, independent of rendering.
refusalName :: IdentityRefusal -> Text
refusalName = \case
    StateTokenForeignRelease _ -> "state-token-foreign-release"
    StateTokenNotFound -> "state-token-not-found"
    StateTokenBurned _ -> "state-token-burned"
    StateTokenSeedMismatch _ -> "state-token-seed-mismatch"
    StateOutputMissing -> "state-output-missing"
    RegistryPinMismatch PinApplication -> "registry-pin-mismatch application"
    RegistryPinMismatch PinActive -> "registry-pin-mismatch active"
    RegistryPinMismatch PinAbsent -> "registry-pin-mismatch absent"
    RegistryPinMismatch PinTerminal -> "registry-pin-mismatch terminal"
    NetworkMismatch _ -> "network-mismatch"
    IdentityUnreadable _ -> "unreadable"

pins :: CageConfig -> [SBS.ShortByteString]
pins c =
    [ cfgApplicationPolicy c
    , cfgActivePolicy c
    , cfgAbsentPolicy c
    , cfgTerminalPolicy c
    ]

otherScript :: Script ConwayEra
otherScript = scriptFromBytes "other" (releaseRequest release <> SBS.pack [0])

otherPin :: BuiltinByteString
otherPin = BuiltinByteString (BS.replicate 28 0xee)

plain :: TxOut ConwayEra
plain =
    mkBasicTxOut
        (cageAddrFromCfg bootCfg Testnet)
        (MaryValue (Coin 5_000_000) mempty)

relocated :: TxOut ConwayEra -> TxOut ConwayEra
relocated o =
    o
        & addrTxOutL
            .~ cageAddrFromCfg
                bootCfg{cfgScriptHash = hashScript otherScript}
                Testnet

withoutDatum :: TxOut ConwayEra -> TxOut ConwayEra
withoutDatum o = o & datumTxOutL .~ NoDatum

spelling :: LP.Asset -> Text
spelling (PolicyID policy, AssetName name) =
    hex (scriptHashBytes policy) <> "." <> hex (SBS.fromShort name)

hashHex :: ScriptHash -> Text
hashHex = hex . scriptHashBytes

hex :: BS.ByteString -> Text
hex = TE.decodeUtf8 . B16.encode

isLeft :: Either a b -> Bool
isLeft = either (const True) (const False)
