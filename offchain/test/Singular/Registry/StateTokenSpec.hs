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

import Cardano.Ledger.Api.Tx.Out
    ( TxOut
    , addrTxOutL
    , datumTxOutL
    , mkBasicTxOut
    )
import Cardano.Ledger.BaseTypes (Network (Testnet))
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Core (Script, hashScript)
import Cardano.Ledger.Hashes (ScriptHash)
import Cardano.Ledger.Mary.Value
    ( AssetName (..)
    , MaryValue (..)
    , PolicyID (..)
    )
import Cardano.Ledger.Plutus.Data (Datum (NoDatum))
import Cardano.Ledger.TxIn (TxIn)
import PlutusTx.Builtins.Internal (BuiltinByteString (..))

import Singular.Registry.Config (CageConfig (..))
import Singular.Registry.Ledger (ConwayEra)
import Singular.Registry.LedgerProvider qualified as LP
import Singular.Registry.StateToken
import Singular.Registry.StateTokenFixture
import Singular.Registry.TxBuilder.Internal
    ( cageAddrFromCfg
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
        Map.keys (expectedReferences release token)
            `shouldBe` [minBound .. maxBound]
    it
        "are the hashes of the scripts the boot published, derived from the token alone"
        $ do
            let published =
                    Map.fromList
                        [ (role, hashScript script)
                        | (name, script) <- bootScripts
                        , Just role <- [parseRole name]
                        ]
            Map.size published `shouldBe` length bootScripts
            expectedReferences release token `shouldBe` published
    it "spell their roles as receipts do" $
        map
            (roleName . fst)
            (Map.toAscList (expectedReferences release token))
            `shouldBe` map fst bootScripts
    it
        "differ between two registries of one release in everything but the state script"
        $ do
            let other = tokenOf (refOf (T.replicate 64 "4" <> "#2"))
                here = expectedReferences release token
                there = expectedReferences release other
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
                    resolvedExpected r `shouldBe` expectedReferences release token
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
            found <- searchOn chain [] [] (Set.singleton role)
            fmap (Map.map fst . fst) found
                `shouldBe` Right (Map.singleton role low)
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
            found <- searchOn chain [] [] (Set.singleton role)
            fmap (Map.map fst . fst) found
                `shouldBe` Right (Map.singleton role honest)
    it
        "tries the hints when the provider has none, and warns once for each hint not admitted"
        $ do
            let (role, script) = needed RoleApplication
                hinted = refOf (T.replicate 64 "d" <> "#1")
                gone = refOf (T.replicate 64 "e" <> "#0")
                empty = refOf (T.replicate 64 "f" <> "#3")
                chain =
                    honestChain
                        { chainOutputs =
                            Map.fromList [(hinted, carrierOf script), (empty, plain)]
                                <> chainOutputs honestChain
                        }
            found <-
                searchOn chain [gone, hinted, empty, gone] [] (Set.singleton role)
            fmap (Map.map fst . fst) found
                `shouldBe` Right (Map.singleton role hinted)
            fmap (sortOn id . snd) found
                `shouldBe` Right (sortOn id [gone, empty])
    it "tries the wallet when neither the provider nor a hint has one" $ do
        let (role, script) = needed RoleWitnessActive
            mine = refOf (T.replicate 64 "9" <> "#4")
            wallet =
                [ (mine, carrierOf script)
                , (refOf (T.replicate 64 "8" <> "#0"), plain)
                ]
        found <- searchOn honestChain [] wallet (Set.singleton role)
        fmap (Map.map fst . fst) found
            `shouldBe` Right (Map.singleton role mine)
    it "prefers an earlier source to a lower output reference" $ do
        let (role, script) = needed RoleState
            fromProvider = refOf (T.replicate 64 "f" <> "#9")
            fromHint = refOf (T.replicate 64 "5" <> "#0")
            fromWallet = refOf (T.replicate 64 "1" <> "#7")
            chain =
                (carrying [(fromProvider, script)] Forward honestChain)
                    { chainOutputs =
                        Map.fromList
                            [(fromProvider, carrierOf script), (fromHint, carrierOf script)]
                            <> chainOutputs honestChain
                    }
        found <-
            searchOn
                chain
                [fromHint]
                [(fromWallet, carrierOf script)]
                (Set.singleton role)
        fmap (Map.map fst . fst) found
            `shouldBe` Right (Map.singleton role fromProvider)
        foundNoProvider <-
            searchOn
                chain{chainCarriers = const []}
                [fromHint]
                [(fromWallet, carrierOf script)]
                (Set.singleton role)
        fmap (Map.map fst . fst) foundNoProvider
            `shouldBe` Right (Map.singleton role fromHint)
    it "looks up only the roles the command runs" $ do
        let wanted = Set.fromList [RoleRequest, RoleApplication]
            published =
                [ (refOf (T.pack (replicate 63 c <> "1") <> "#0"), script)
                | (c, (_, script)) <- zip "abcdef" bootScripts
                ]
            chain = carrying published Forward honestChain
        logRef <- newIORef []
        found <-
            findReferences
                (chainSession logRef chain)
                []
                []
                (expectedReferences release token)
                wanted
        fmap (Map.keysSet . fst) found `shouldBe` Right wanted
        reads' <- readIORef logRef
        length (filter ("CarryingReferenceScript" `T.isPrefixOf`) reads')
            `shouldBe` 2
    it
        "refuses the first role no source carries, naming its hash and the remedy"
        $ do
            let wanted = Set.fromList [RoleWitnessAbsent, RoleWitnessTerminal]
            found <- searchOn honestChain [] [] wanted
            let expected = expectedReferences release token
            found
                `shouldBe` Left
                    ( ReferenceMissing
                        RoleWitnessAbsent
                        (expected Map.! RoleWitnessAbsent)
                    )
            let rendered =
                    renderReferenceRefusal
                        (ReferenceMissing RoleWitnessAbsent (expected Map.! RoleWitnessAbsent))
            rendered
                `shouldSatisfy` T.isPrefixOf
                    ( "reference-missing witness-absent "
                        <> hashHex (expected Map.! RoleWitnessAbsent)
                        <> ": not found by this provider, hints or wallet"
                    )
            rendered
                `shouldSatisfy` T.isInfixOf "singular registry publish-references"
    it "warns for a hint by naming it" $ do
        let hint = refOf (T.replicate 64 "e" <> "#0")
        renderHintWarning hint
            `shouldBe` ("reference-hint-invalid " <> T.replicate 64 "e" <> "#0")

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

resolveOn
    :: Chain
    -> LP.Asset
    -> IO (Either IdentityRefusal ResolvedRegistry, [Text])
resolveOn chain asked = do
    logRef <- newIORef []
    result <- resolveRegistry release asked (chainSession logRef chain)
    reads' <- readIORef logRef
    pure (result, reads')

searchOn
    :: Chain
    -> [TxIn]
    -> LP.Outputs
    -> Set.Set ReferenceRole
    -> IO
        ( Either
            ReferenceRefusal
            (Map.Map ReferenceRole (TxIn, TxOut ConwayEra), [TxIn])
        )
searchOn chain hints wallet wanted = do
    logRef <- newIORef []
    findReferences
        (chainSession logRef chain)
        hints
        wallet
        (expectedReferences release token)
        wanted

-- | The role and the script the boot published for it.
needed :: ReferenceRole -> (ReferenceRole, Script ConwayEra)
needed role =
    case [script | (name, script) <- bootScripts, parseRole name == Just role] of
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
