{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.Registry.TxBuilder.TerminationBookingSpec
Description : The termination booking transaction, built from a genuine custody
License     : Apache-2.0

What a termination booking is, said in terms the model gives: the key's one
genuine custody output is spent, its whole value plus the requester's declared
ordinary addition goes into one request at the request address together with
the key's singular tag, and one trie-ready tag is minted under the request
policy; nothing returns to the controller, and the fee and the change come
from ordinary funding.

Every expected value is derived from the fixture's own numbers and from the
termination wire written out here field by field, never read from the
builder's output. The trie-ready tag name is the one a program computed by an
independent route (@evidence/cp3-red-dev/vectors@, hand-built CBOR hashed with
BLAKE2b-256).

These rows are the checkpoint's RED: they call the real builder, which is not
written, so each reaches its refusal or its missing transaction.
-}
module Singular.Registry.TxBuilder.TerminationBookingSpec (spec) where

import Control.Exception (SomeException, displayException)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Short qualified as SBS
import Data.Foldable (toList)
import Data.List (isInfixOf)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Word (Word32)
import Lens.Micro ((%~), (&), (.~), (^.))
import PlutusCore.Data (Data (..))
import PlutusTx.Builtins.Internal (BuiltinByteString (..))
import Test.Hspec

import Cardano.Ledger.Address (Addr (..))
import Cardano.Ledger.Alonzo.Plutus.Evaluate (evalTxExUnits)
import Cardano.Ledger.Alonzo.Scripts (AsIx (..))
import Cardano.Ledger.Api.Scripts.Data (Datum (..), binaryDataToData)
import Cardano.Ledger.Api.Tx (bodyTxL, witsTxL)
import Cardano.Ledger.Api.Tx.Body
    ( collateralInputsTxBodyL
    , feeTxBodyL
    , inputsTxBodyL
    , mintTxBodyL
    , outputsTxBodyL
    , referenceInputsTxBodyL
    , reqSignerHashesTxBodyL
    )
import Cardano.Ledger.Api.Tx.Out
    ( TxOut
    , addrTxOutL
    , coinTxOutL
    , datumTxOutL
    , mkBasicTxOut
    , valueTxOutL
    )
import Cardano.Ledger.Api.Tx.Wits
    ( Redeemers (..)
    , rdmrsTxWitsL
    , scriptTxWitsL
    )
import Cardano.Ledger.BaseTypes (Network (Testnet))
import Cardano.Ledger.Conway.Scripts (ConwayPlutusPurpose (..))
import Cardano.Ledger.Core (hashScript)
import Cardano.Ledger.Credential
    ( Credential (..)
    , StakeReference (..)
    )
import Cardano.Ledger.Hashes (ScriptHash)
import Cardano.Ledger.Mary.Value
    ( MaryValue (..)
    , MultiAsset (..)
    , PolicyID (..)
    )
import Cardano.Ledger.Plutus.Data (getPlutusData)
import Cardano.Ledger.Plutus.ExUnits (ExUnits (..))
import Cardano.Ledger.State (UTxO (..))
import Cardano.Ledger.TxIn (TxIn)
import Cardano.Tx.Ledger (ConwayTx)

import Singular.Registry.Blueprint (NamingCodes (..))
import Singular.Registry.Config (CageConfig (..))
import Singular.Registry.Deployment (parseOutRef)
import Singular.Registry.Evidence (NoWitness)
import Singular.Registry.Ledger
    ( AssetName (..)
    , Coin (..)
    , ConwayEra
    , PParams
    , TokenId (..)
    )
import Singular.Registry.LedgerProvider (Session)
import Singular.Registry.NetworkTime
    ( networkEpochInfo
    , networkSystemStart
    )
import Singular.Registry.StubSession
import Singular.Registry.SyntheticLedger
    ( unitProgram
    , withCostCoefficients
    )
import Singular.Registry.SyntheticTime (syntheticTime)
import Singular.Registry.TxBuilder.BookingFixture
    ( RetainedRegistry (..)
    , loadRetained
    )
import Singular.Registry.TxBuilder.BookingFixture qualified as Fixture
import Singular.Registry.TxBuilder.Internal
    ( addrFromKeyHashBytes
    , addrWitnessKeyHash
    , cageAddrFromCfg
    , computeScriptHash
    , mkInlineDatum
    , policyIdFromPin
    , requestAddrFromCfg
    , scriptFromBytes
    , scriptHashBytes
    , toPlcData
    )
import Singular.Registry.TxBuilder.TerminationBooking
    ( CustodyAuthority (..)
    , TerminationBooking (..)
    , bookTerminationImpl
    )
import Singular.Registry.Types
    ( CageDatum (..)
    , OnChainRoot (..)
    , OnChainTokenState (..)
    )

-- ---------------------------------------------------------
-- The world: one registry, one custody, one payer
-- ---------------------------------------------------------

cfg :: CageConfig
cfg = Fixture.cfg

tokenId :: TokenId
tokenId = Fixture.tokenId

payer :: Addr
payer = Fixture.payer

outRef :: Char -> Int -> TxIn
outRef c i =
    either
        (error . ("TerminationBookingSpec fixture: " <>))
        id
        (parseOutRef (T.pack (replicate 64 c <> "#" <> show i)))

stateRef, custodyRef, fundingIn, taggedFundingIn :: TxIn
stateRef = outRef '7' 0
custodyRef = outRef '5' 0
fundingIn = outRef '4' 0
taggedFundingIn = outRef '6' 0

-- | The key being terminated and the tag a program computed for its booking.
unhex :: ByteString -> ByteString
unhex = either (error . ("unhex: " <>)) id . B16.decode

bookedKey :: ByteString
bookedKey = unhex "6b657942"

bookedNonce :: Integer
bookedNonce = 1

{- | Written by @termination_tag_vectors.py@ (evidence/cp3-red-dev/vectors,
output sha256 @9ff8af7c…@) for the key, the empty destination and the nonce
above, not typed.
-}
bookedTag :: ByteString
bookedTag =
    unhex
        "054c1c37bccb9747e1b4e0b76a7ddd96daf15b06d109654eecab7cde86b02e8a"

activePolicy, requestPolicy :: PolicyID
activePolicy = policyIdFromPin (cfgActivePolicy cfg)
requestPolicy = policyIdFromPin Fixture.requestPin

-- | The custody's script and its address: the toy application script.
custodyScript :: SBS.ShortByteString
custodyScript = ncApplication Fixture.codes

-- | The redeemer the toy custody script is spent with.
custodyRedeemer :: Data
custodyRedeemer = Constr 2 [I 7]

custodyAddr :: Addr
custodyAddr =
    Addr
        Testnet
        (ScriptHashObj (hashScript Fixture.applicationScript))
        StakeRefNull

singular :: ByteString -> Integer -> MultiAsset
singular key q =
    MultiAsset (Map.singleton activePolicy (Map.singleton (nameOf key) q))

nameOf :: ByteString -> AssetName
nameOf = AssetName . SBS.toShort

-- | The custody a controller spends: lovelace and the key's one singular tag.
custodyOf :: Integer -> ByteString -> TxOut ConwayEra
custodyOf lovelace key =
    mkBasicTxOut custodyAddr (MaryValue (Coin lovelace) (singular key 1))

custodyLovelace :: Integer
custodyLovelace = 4_000_000

custodyOut :: TxOut ConwayEra
custodyOut = custodyOf custodyLovelace bookedKey

fundingOut :: TxOut ConwayEra
fundingOut = mkBasicTxOut payer (MaryValue (Coin 100_000_000) mempty)

{- | A larger output of the payer that also holds the key's singular tag: not
an ordinary funding output, and never to be spent as one.
-}
taggedFundingOut :: TxOut ConwayEra
taggedFundingOut =
    mkBasicTxOut
        payer
        (MaryValue (Coin 150_000_000) (singular bookedKey 1))

stateOutputFor :: CageConfig -> TxOut ConwayEra
stateOutputFor c =
    mkBasicTxOut
        (cageAddrFromCfg c Testnet)
        ( MaryValue
            (Coin 2_000_000)
            ( MultiAsset
                ( Map.singleton
                    (PolicyID (cfgScriptHash c))
                    (Map.singleton (unTokenId tokenId) 1)
                )
            )
        )
        & datumTxOutL .~ mkInlineDatum (toPlcData (StateDatum (pinnedBy c)))

-- | The state a registry booted under this configuration carries.
pinnedBy :: CageConfig -> OnChainTokenState
pinnedBy c =
    OnChainTokenState
        { stateRoot = OnChainRoot (BS.replicate 32 0)
        , stateMaxFee = let Coin t = defaultTip c in t
        , stateProcessTime = defaultProcessTime c
        , stateRetractTime = defaultRetractTime c
        , stateAppPolicy = bytes28 (cfgApplicationPolicy c)
        , stateActivePolicy = bytes28 (cfgActivePolicy c)
        , stateAbsentPolicy = bytes28 (cfgAbsentPolicy c)
        , stateTerminalPolicy = bytes28 (cfgTerminalPolicy c)
        , stateRegistrationCost = let Coin n = defaultRegistrationCost c in n
        , stateBookingWidth = defaultBookingWidth c
        , stateRequestPolicy = bytes28 (cfgRequestPolicy c)
        }
  where
    bytes28 = BuiltinByteString . SBS.fromShort

-- ---------------------------------------------------------
-- The view: what each address and reference answers
-- ---------------------------------------------------------

type Served = [(Addr, [(TxIn, TxOut ConwayEra)])]

ledgerParameters :: PParams ConwayEra
ledgerParameters =
    withCostCoefficients
        (ExUnits 500_000 200_000_000)
        10
        Fixture.preprodParams

viewServing :: Served -> Session NoWitness IO
viewServing served =
    withAddressOutputs
        (\a -> pure (concat [os | (x, os) <- served, x == a]))
        $ withParameters ledgerParameters
        $ withTime (pure syntheticTime)
        $ withResolvedOutputs
            ( \wanted ->
                pure [(r, o) | (r, o) <- concatMap snd served, r `Set.member` wanted]
            )
            stubSession

-- | The honest world: the payer's funding output, the state, the custody.
world :: Served
world = worldWith custodyOut

worldWith :: TxOut ConwayEra -> Served
worldWith custody =
    [ (payer, [(fundingIn, fundingOut)])
    , (cageAddrFromCfg cfg Testnet, [(stateRef, stateOutputFor cfg)])
    , (custodyAddr, [(custodyRef, custody)])
    ]

-- ---------------------------------------------------------
-- The booking and what it must state
-- ---------------------------------------------------------

tip :: Integer
tip = 1_500_000

-- | A termination of the key with nothing added: tip and carrier account for the custody.
booking :: TerminationBooking
booking = bookingAdding 0

-- | The same with an ordinary addition; the carrier takes up the whole of it.
bookingAdding :: Integer -> TerminationBooking
bookingAdding added =
    TerminationBooking
        { tbKey = bookedKey
        , tbDeclaredTip = Coin tip
        , tbCarrier = Coin (custodyLovelace + added - tip)
        , tbNonce = bookedNonce
        , tbCustody = (custodyRef, custodyOut)
        , tbOrdinaryAdded = Coin added
        , tbCustodyAuthority = ScriptGuarded custodyScript custodyRedeemer
        , tbRequiredSigners = []
        }

built :: TerminationBooking -> IO ConwayTx
built = builtIn world

builtIn :: Served -> TerminationBooking -> IO ConwayTx
builtIn served b =
    bookTerminationImpl cfg (viewServing served) tokenId stateRef b payer

refusesWith :: String -> IO a -> Expectation
refusesWith what action =
    action `shouldThrow` \e -> what `isInfixOf` displayException (e :: SomeException)

{- | The termination datum the request output must carry, written field by
field in the order of the on-chain type, without any codec.
-}
terminationWire :: Integer -> Data
terminationWire carrier =
    Constr
        4
        [ Constr
            0
            [ Constr 0 [B registryName]
            , B bookedKey
            , B BS.empty
            , I tip
            , I carrier
            , I bookedNonce
            ]
        ]

registryName :: ByteString
registryName = case unTokenId tokenId of
    AssetName n -> SBS.fromShort n

rawDatumOf :: TxOut ConwayEra -> Maybe Data
rawDatumOf o = case o ^. datumTxOutL of
    Datum bd -> Just (getPlutusData (binaryDataToData bd))
    _ -> Nothing

outputsAtRequest :: ConwayTx -> [TxOut ConwayEra]
outputsAtRequest tx =
    [ o
    | o <- toList (tx ^. bodyTxL . outputsTxBodyL)
    , o ^. addrTxOutL == requestAddrFromCfg cfg tokenId Testnet
    ]

-- | The value the request output must hold: the whole custody and the addition, the tag and the key's singular tag.
requestValue :: Integer -> MaryValue
requestValue added =
    MaryValue
        (Coin (custodyLovelace + added))
        ( singular bookedKey 1
            <> MultiAsset
                (Map.singleton requestPolicy (Map.singleton (nameOf bookedTag) 1))
        )

feeOf :: ConwayTx -> Integer
feeOf tx = let Coin f = tx ^. bodyTxL . feeTxBodyL in f

-- ---------------------------------------------------------
-- The rows
-- ---------------------------------------------------------

spec :: Spec
spec = describe "chunk3 offchain" $ do
    termination
    walletCustody
    retainedBytes

termination :: Spec
termination = describe "the termination booking" $ do
    it
        "pays the request address the whole custody value, the singular tag and the trie-ready tag, with the termination datum"
        $ do
            tx <- built booking
            case outputsAtRequest tx of
                [o] -> do
                    o ^. valueTxOutL `shouldBe` requestValue 0
                    rawDatumOf o
                        `shouldBe` Just (terminationWire (custodyLovelace - tip))
                other -> expectationFailure ("request outputs: " <> show (length other))
    it
        "takes an ordinary addition into the request beside the whole custody"
        $ do
            tx <- built (bookingAdding 750_000)
            case outputsAtRequest tx of
                [o] -> do
                    o ^. valueTxOutL `shouldBe` requestValue 750_000
                    rawDatumOf o
                        `shouldBe` Just
                            (terminationWire (custodyLovelace + 750_000 - tip))
                other -> expectationFailure ("request outputs: " <> show (length other))
    it "mints exactly the one trie-ready tag under the request policy" $ do
        tx <- built booking
        tx ^. bodyTxL . mintTxBodyL
            `shouldBe` MultiAsset
                (Map.singleton requestPolicy (Map.singleton (nameOf bookedTag) 1))
    it
        "spends exactly the custody and the payer's funding output, which is also its collateral"
        $ do
            tx <- built booking
            tx ^. bodyTxL . inputsTxBodyL
                `shouldBe` Set.fromList [custodyRef, fundingIn]
            tx ^. bodyTxL . collateralInputsTxBodyL
                `shouldBe` Set.singleton fundingIn
            tx ^. bodyTxL . referenceInputsTxBodyL
                `shouldBe` Set.singleton stateRef
    it
        "carries the custody's own spend witness and the request mint, with measured units"
        $ do
            tx <- built booking
            Map.keysSet (tx ^. witsTxL . scriptTxWitsL)
                `shouldBe` Set.fromList
                    [ hashScript Fixture.applicationScript
                    , policyHashOf requestPolicy
                    ]
            let Redeemers rs = tx ^. witsTxL . rdmrsTxWitsL
                inputsAscending = Set.toAscList (tx ^. bodyTxL . inputsTxBodyL)
                custodyIndex = fromIntegral (length (takeWhile (/= custodyRef) inputsAscending))
                spends =
                    [ (i, getPlutusData d, u)
                    | (ConwaySpending (AsIx i), (d, u)) <- Map.toList rs
                    ]
                mints =
                    [ (getPlutusData d, u)
                    | (ConwayMinting (AsIx _), (d, u)) <- Map.toList rs
                    ]
            map (\(i, d, _) -> (i, d)) spends
                `shouldBe` [(custodyIndex :: Word32, custodyRedeemer)]
            map fst mints `shouldBe` [Constr 0 []]
            all (\(_, _, ExUnits m s) -> m > 0 && s > 0) spends `shouldBe` True
            all (\(_, ExUnits m s) -> m > 0 && s > 0) mints `shouldBe` True
    it "preserves the spend redeemer it is given, whatever it is" $ do
        tx <-
            built
                booking
                    { tbCustodyAuthority =
                        ScriptGuarded
                            custodyScript
                            (Constr 5 [B "caller authorization", I 42])
                    }
        let Redeemers rs = tx ^. witsTxL . rdmrsTxWitsL
        [getPlutusData d | (ConwaySpending _, (d, _)) <- Map.toList rs]
            `shouldBe` [Constr 5 [B "caller authorization", I 42]]
    it
        "keeps ordinary funding, change and fee apart from the custody value"
        $ do
            tx <- built booking
            let outs = toList (tx ^. bodyTxL . outputsTxBodyL)
                total = sum [c | o <- outs, let Coin c = o ^. coinTxOutL]
                change = [o | o <- outs, o ^. addrTxOutL == payer]
            feeOf tx `shouldSatisfy` (> 0)
            -- the fee is paid from the payer's funding, not from the custody
            total + feeOf tx `shouldBe` custodyLovelace + 100_000_000
            map (^. coinTxOutL) change
                `shouldBe` [Coin (100_000_000 - feeOf tx)]
            length outs `shouldBe` 2
            case outputsAtRequest tx of
                [o] -> o ^. coinTxOutL `shouldBe` Coin custodyLovelace
                other -> expectationFailure ("request outputs: " <> show (length other))
    it "funds an ordinary addition from the payer, not from the custody" $ do
        tx <- built (bookingAdding 750_000)
        let outs = toList (tx ^. bodyTxL . outputsTxBodyL)
            change = [o | o <- outs, o ^. addrTxOutL == payer]
        map (^. coinTxOutL) change
            `shouldBe` [Coin (100_000_000 - 750_000 - feeOf tx)]
    it
        "pays nothing of the custody back to the controller or its custody address"
        $ do
            tx <- built booking
            let outs = toList (tx ^. bodyTxL . outputsTxBodyL)
            [o | o <- outs, o ^. addrTxOutL == custodyAddr] `shouldBe` []
            -- the singular tag is held by exactly one output: the request
            [ ()
              | o <- outs
              , MaryValue _ ma <- [o ^. valueTxOutL]
              , ma /= mempty
              , Just _ <- [Map.lookup activePolicy (unMultiAsset ma)]
              ]
                `shouldBe` [()]
    it
        "never spends a payer output that holds the key's singular tag as funding"
        $ do
            let served =
                    [
                        ( payer
                        , [(taggedFundingIn, taggedFundingOut), (fundingIn, fundingOut)]
                        )
                    , (cageAddrFromCfg cfg Testnet, [(stateRef, stateOutputFor cfg)])
                    , (custodyAddr, [(custodyRef, custodyOut)])
                    ]
            tx <- builtIn served booking
            tx ^. bodyTxL . inputsTxBodyL
                `shouldBe` Set.fromList [custodyRef, fundingIn]
    it
        "names the minted tag by the independent preimage of key, destination and nonce"
        $ do
            tx <- built booking
            let MultiAsset minted = tx ^. bodyTxL . mintTxBodyL
            fmap Map.keys (Map.lookup requestPolicy minted)
                `shouldBe` Just [nameOf bookedTag]
    describe "refuses before building" $ do
        it "a custody output that does not hold the key's singular tag" $
            refusesWith "does not hold the key's singular tag" $
                builtIn
                    ( worldWith
                        (mkBasicTxOut custodyAddr (MaryValue (Coin custodyLovelace) mempty))
                    )
                    booking
                        { tbCustody =
                            ( custodyRef
                            , mkBasicTxOut custodyAddr (MaryValue (Coin custodyLovelace) mempty)
                            )
                        }
        it "a custody output that holds another key's singular tag" $
            refusesWith "does not hold the key's singular tag" $
                builtIn
                    (worldWith (custodyOf custodyLovelace "another-key"))
                    booking
                        { tbCustody = (custodyRef, custodyOf custodyLovelace "another-key")
                        }
        it "a custody output that holds two of the key's singular tag" $
            refusesWith "more than one" $
                builtIn
                    (worldWith twoTags)
                    booking{tbCustody = (custodyRef, twoTags)}
        it
            "a custody output that holds more than the singular tag and lovelace"
            $ refusesWith "more than the singular tag and lovelace"
            $ builtIn
                (worldWith (withStranger custodyOut))
                booking{tbCustody = (custodyRef, withStranger custodyOut)}
        it "a custody output the ledger does not answer" $
            refusesWith "custody output not found" $
                builtIn
                    [ (payer, [(fundingIn, fundingOut)])
                    , (cageAddrFromCfg cfg Testnet, [(stateRef, stateOutputFor cfg)])
                    , (custodyAddr, [])
                    ]
                    booking
        it "a custody output the caller states differently from the ledger's" $
            refusesWith "differs from the live output" $
                builtIn
                    (worldWith (custodyOf (custodyLovelace + 1) bookedKey))
                    booking
        it "an application script that is not the custody's script" $
            refusesWith "not the custody's script" $
                built
                    booking
                        { tbCustodyAuthority =
                            ScriptGuarded Fixture.program custodyRedeemer
                        }
        it "a tip below the registry's minimum" $
            refusesWith "tip is below the registry's minimum tip" $
                built
                    booking
                        { tbDeclaredTip = Coin 999_999
                        , tbCarrier = Coin (custodyLovelace - 999_999)
                        }
        it "a negative carrier" $
            refusesWith "carrier is negative" $
                built
                    booking
                        { tbDeclaredTip = Coin (custodyLovelace + 1)
                        , tbCarrier = Coin (-1)
                        }
        it "a negative nonce" $
            refusesWith "nonce is negative" $
                built booking{tbNonce = -1}
        it "a negative ordinary addition" $
            refusesWith "ordinary addition is negative" $
                built
                    booking
                        { tbOrdinaryAdded = Coin (-1)
                        , tbCarrier = Coin (custodyLovelace - 1 - tip)
                        }
        it "a tip and carrier that leave part of the held value undeclared" $
            refusesWith "tip and carrier must add up to the held lovelace" $
                built booking{tbCarrier = Coin (custodyLovelace - tip - 1)}
        it "a tip and carrier that declare more than the held value" $
            refusesWith "tip and carrier must add up to the held lovelace" $
                built booking{tbCarrier = Coin (custodyLovelace - tip + 1)}
        it "a held value too small for the request output's own minimum ada" $
            refusesWith "below the minimum ada" $
                builtIn
                    (worldWith (custodyOf 1_200_000 bookedKey))
                    booking
                        { tbCustody = (custodyRef, custodyOf 1_200_000 bookedKey)
                        , tbDeclaredTip = Coin 1_000_000
                        , tbCarrier = Coin 200_000
                        }
        it "a state reference that no output at the state address answers" $
            refusesWith "state output not found" $
                bookTerminationImpl
                    cfg
                    (viewServing world)
                    tokenId
                    (outRef '8' 3)
                    booking
                    payer
        it "a state output that does not hold the registry's state token" $
            refusesWith "does not hold the registry's state token" $
                builtIn
                    [ (payer, [(fundingIn, fundingOut)])
                    ,
                        ( cageAddrFromCfg cfg Testnet
                        ,
                            [
                                ( stateRef
                                , stateOutputFor cfg & valueTxOutL .~ MaryValue (Coin 2_000_000) mempty
                                )
                            ]
                        )
                    , (custodyAddr, [(custodyRef, custodyOut)])
                    ]
                    booking
        it "a state output pinning other booking terms than the configuration" $
            refusesWith "does not carry this configuration's booking pins" $
                builtIn
                    [ (payer, [(fundingIn, fundingOut)])
                    ,
                        ( cageAddrFromCfg cfg Testnet
                        , [(stateRef, stateOutputFor cfg{defaultTip = Coin 1_000_001})]
                        )
                    , (custodyAddr, [(custodyRef, custodyOut)])
                    ]
                    booking
  where
    twoTags =
        mkBasicTxOut
            custodyAddr
            (MaryValue (Coin custodyLovelace) (singular bookedKey 2))
    withStranger o =
        o
            & valueTxOutL
                .~ MaryValue
                    (Coin custodyLovelace)
                    ( singular bookedKey 1
                        <> MultiAsset
                            ( Map.singleton
                                Fixture.applicationPolicy
                                (Map.singleton (nameOf "stranger") 1)
                            )
                    )

-- ---------------------------------------------------------
-- Small helpers
-- ---------------------------------------------------------

unMultiAsset
    :: MultiAsset -> Map.Map PolicyID (Map.Map AssetName Integer)
unMultiAsset (MultiAsset m) = m

-- | The script hash a policy id names.
policyHashOf :: PolicyID -> ScriptHash
policyHashOf (PolicyID h) = h

-- ---------------------------------------------------------
-- A wallet custody: the holder's signature is the spending condition
-- ---------------------------------------------------------

-- | The holder's payment key hash: one no other fixture uses.
holderBytes :: ByteString
holderBytes = BS.replicate 28 0x77

holderAddr :: Addr
holderAddr = addrFromKeyHashBytes Testnet holderBytes

-- | The key's one singular tag and lovelace, at a wallet address.
walletCustodyOut :: TxOut ConwayEra
walletCustodyOut =
    mkBasicTxOut
        holderAddr
        (MaryValue (Coin custodyLovelace) (singular bookedKey 1))

walletWorldWith :: TxOut ConwayEra -> Served
walletWorldWith custody =
    [ (payer, [(fundingIn, fundingOut)])
    , (cageAddrFromCfg cfg Testnet, [(stateRef, stateOutputFor cfg)])
    , (holderAddr, [(custodyRef, custody)])
    ]

-- | The termination of the key out of a wallet: the holder's signature is the authority.
walletBooking :: TerminationBooking
walletBooking =
    booking
        { tbCustody = (custodyRef, walletCustodyOut)
        , tbCustodyAuthority = WalletGuarded
        }

walletBuilt :: TerminationBooking -> IO ConwayTx
walletBuilt = builtIn (walletWorldWith walletCustodyOut)

walletCustody :: Spec
walletCustody = describe "a custody a wallet holds" $ do
    it
        "spends the custody with no script witness and no spend redeemer, only the request mint"
        $ do
            tx <- walletBuilt walletBooking
            Map.keysSet (tx ^. witsTxL . scriptTxWitsL)
                `shouldBe` Set.singleton (policyHashOf requestPolicy)
            let Redeemers rs = tx ^. witsTxL . rdmrsTxWitsL
            [() | (ConwaySpending _, _) <- Map.toList rs] `shouldBe` []
            [getPlutusData d | (ConwayMinting _, (d, _)) <- Map.toList rs]
                `shouldBe` [Constr 0 []]
            tx ^. bodyTxL . inputsTxBodyL
                `shouldBe` Set.fromList [custodyRef, fundingIn]
    it "names the holder's key hash as the required signer" $ do
        tx <- walletBuilt walletBooking
        tx ^. bodyTxL . reqSignerHashesTxBodyL
            `shouldBe` Set.singleton (addrWitnessKeyHash holderBytes)
    it "keeps the caller's required signers beside the holder's" $ do
        let other = BS.replicate 28 0x33
        tx <- walletBuilt walletBooking{tbRequiredSigners = [other]}
        tx ^. bodyTxL . reqSignerHashesTxBodyL
            `shouldBe` Set.fromList
                [addrWitnessKeyHash holderBytes, addrWitnessKeyHash other]
    it
        "pays the request address the whole custody value, the singular tag and the trie-ready tag, with the termination datum"
        $ do
            tx <- walletBuilt walletBooking
            case outputsAtRequest tx of
                [o] -> do
                    o ^. valueTxOutL `shouldBe` requestValue 0
                    rawDatumOf o
                        `shouldBe` Just (terminationWire (custodyLovelace - tip))
                other -> expectationFailure ("request outputs: " <> show (length other))
    it "mints exactly the one trie-ready tag under the request policy" $ do
        tx <- walletBuilt walletBooking
        tx ^. bodyTxL . mintTxBodyL
            `shouldBe` MultiAsset
                (Map.singleton requestPolicy (Map.singleton (nameOf bookedTag) 1))
    it
        "takes an ordinary addition into the request beside the whole custody"
        $ do
            tx <-
                walletBuilt
                    walletBooking
                        { tbOrdinaryAdded = Coin 750_000
                        , tbCarrier = Coin (custodyLovelace + 750_000 - tip)
                        }
            case outputsAtRequest tx of
                [o] -> o ^. valueTxOutL `shouldBe` requestValue 750_000
                other -> expectationFailure ("request outputs: " <> show (length other))
    it "pays the fee from the payer's funding, never from the custody" $ do
        tx <- walletBuilt walletBooking
        let outs = toList (tx ^. bodyTxL . outputsTxBodyL)
            total = sum [c | o <- outs, let Coin c = o ^. coinTxOutL]
        total + feeOf tx `shouldBe` custodyLovelace + 100_000_000
    describe "refuses before building" $ do
        it "a wallet authority over a custody a script guards" $
            refusesWith "guarded by a script" $
                built booking{tbCustodyAuthority = WalletGuarded}
        it "a script authority over a custody a wallet holds" $
            refusesWith "not the custody's script" $
                walletBuilt
                    walletBooking
                        { tbCustodyAuthority =
                            ScriptGuarded custodyScript custodyRedeemer
                        }
        it
            "a wallet custody that holds more than the singular tag and lovelace"
            $ refusesWith "more than the singular tag and lovelace"
            $ let stranger =
                    walletCustodyOut
                        & valueTxOutL
                            .~ MaryValue
                                (Coin custodyLovelace)
                                ( singular bookedKey 1
                                    <> MultiAsset
                                        ( Map.singleton
                                            Fixture.applicationPolicy
                                            (Map.singleton (nameOf "stranger") 1)
                                        )
                                )
              in  builtIn
                    (walletWorldWith stranger)
                    walletBooking{tbCustody = (custodyRef, stranger)}
        it "a wallet custody that does not hold the key's singular tag" $
            refusesWith "does not hold the key's singular tag" $
                let bare =
                        walletCustodyOut
                            & valueTxOutL .~ MaryValue (Coin custodyLovelace) mempty
                in  builtIn
                        (walletWorldWith bare)
                        walletBooking{tbCustody = (custodyRef, bare)}
        it "a wallet custody that holds two of the key's singular tag" $
            refusesWith "more than one of the key's singular tag" $
                let doubled =
                        walletCustodyOut
                            & valueTxOutL
                                .~ MaryValue
                                    (Coin custodyLovelace)
                                    (singular bookedKey 2)
                in  builtIn
                        (walletWorldWith doubled)
                        walletBooking{tbCustody = (custodyRef, doubled)}
        it "a wallet custody the ledger does not answer" $
            refusesWith "custody output not found" $
                builtIn
                    [ (payer, [(fundingIn, fundingOut)])
                    , (cageAddrFromCfg cfg Testnet, [(stateRef, stateOutputFor cfg)])
                    , (holderAddr, [])
                    ]
                    walletBooking
        it "a wallet custody stated differently from the ledger's" $
            refusesWith "differs from the live output" $
                builtIn
                    ( walletWorldWith
                        (walletCustodyOut & coinTxOutL .~ Coin (custodyLovelace + 1))
                    )
                    walletBooking

-- ---------------------------------------------------------
-- The retained compiled bytes
-- ---------------------------------------------------------

{- | The termination booking over the registry's actual compiled validators,
read from the retained blueprint: the booking the library builds is judged by
the real request policy through the ledger's evaluator, and the same body with
one number moved is refused by it. The custody's own spend script is a toy
here, because the application layer is not what this row is about; what it
establishes is the observed offline behavior of the request policy's
termination judgement under a stub chain view, not a deployment.
-}
retainedBytes :: Spec
retainedBytes = describe "over the retained compiled bytes" $
    beforeAll loadRetained $ do
        it "builds a booking the real request policy accepts" $ \r -> do
            tx <- realBuilt r (realStateOf r)
            let Redeemers declared = tx ^. witsTxL . rdmrsTxWitsL
            Map.size declared `shouldBe` 2
            all (\(_, ExUnits m s) -> m > 0 && s > 0) (Map.elems declared)
                `shouldBe` True
            [p | (p, Left _) <- Map.toList (judgedBy r tx)] `shouldBe` []
        it
            "has the real request policy refuse the body with its carrier raised by one lovelace"
            $ \r -> do
                tx <- realBuilt r (realStateOf r)
                [p | (p, Left _) <- Map.toList (judgedBy r tx)] `shouldBe` []
                [ ()
                  | (ConwayMinting _, Left _) <-
                        Map.toList (judgedBy r (carrierRaised tx))
                  ]
                    `shouldSatisfy` (not . null)
        it "builds a wallet-custody booking the real request policy accepts" $ \r -> do
            tx <- realWalletBuilt r (realStateOf r)
            let Redeemers declared = tx ^. witsTxL . rdmrsTxWitsL
            Map.size declared `shouldBe` 1
            all (\(_, ExUnits m s) -> m > 0 && s > 0) (Map.elems declared)
                `shouldBe` True
            [ p
              | (p, Left _) <- Map.toList (judgedByWith r (realWalletCustody r) tx)
              ]
                `shouldBe` []
        it
            "has the real request policy refuse the wallet-custody body with its carrier raised by one lovelace"
            $ \r -> do
                tx <- realWalletBuilt r (realStateOf r)
                [ ()
                  | (ConwayMinting _, Left _) <-
                        Map.toList
                            (judgedByWith r (realWalletCustody r) (carrierRaised tx))
                  ]
                    `shouldSatisfy` (not . null)
        it
            "has the real request policy refuse the wallet-custody body that no longer spends the custody"
            $ \r -> do
                tx <- realWalletBuilt r (realStateOf r)
                let unspent = tx & bodyTxL . inputsTxBodyL %~ Set.delete custodyRef
                [ ()
                  | (ConwayMinting _, Left _) <-
                        Map.toList (judgedByWith r (realWalletCustody r) unspent)
                  ]
                    `shouldSatisfy` (not . null)
        it "refuses a state that pins the unapplied request validator's hash" $ \r -> do
            let pinned = pinnedBy (rrConfig r)
                unapplied =
                    pinned
                        { stateRequestPolicy =
                            BuiltinByteString
                                (scriptHashBytes (computeScriptHash (rrRequestCode r)))
                        }
            refusesWith
                "does not carry this configuration's booking pins"
                (realBuilt r (stateOutputWith r unapplied))
  where
    realStateOf r = stateOutputWith r (pinnedBy (rrConfig r))

stateOutputWith
    :: RetainedRegistry -> OnChainTokenState -> TxOut ConwayEra
stateOutputWith r st =
    mkBasicTxOut
        (cageAddrFromCfg c Testnet)
        ( MaryValue
            (Coin 2_000_000)
            ( MultiAsset
                ( Map.singleton
                    (PolicyID (cfgScriptHash c))
                    (Map.singleton (unTokenId (rrToken r)) 1)
                )
            )
        )
        & datumTxOutL .~ mkInlineDatum (toPlcData (StateDatum st))
  where
    c = rrConfig r

-- | The custody under the real registry: its singular tag is a token of the real active policy.
realCustody :: RetainedRegistry -> TxOut ConwayEra
realCustody r =
    mkBasicTxOut
        realCustodyAddr
        ( MaryValue
            (Coin custodyLovelace)
            ( MultiAsset
                ( Map.singleton
                    (policyIdFromPin (cfgActivePolicy (rrConfig r)))
                    (Map.singleton (nameOf bookedKey) 1)
                )
            )
        )

{- | The custody's address and script: a toy program, so that the real request
policy is the only real script the spend and the mint run.
-}
realCustodyScript :: SBS.ShortByteString
realCustodyScript = unitProgram 1

realCustodyAddr :: Addr
realCustodyAddr =
    Addr
        Testnet
        ( ScriptHashObj
            (hashScript (scriptFromBytes "custody" realCustodyScript))
        )
        StakeRefNull

realBuilt :: RetainedRegistry -> TxOut ConwayEra -> IO ConwayTx
realBuilt r stateOut =
    bookTerminationImpl
        (rrConfig r)
        (viewServing (realServed r stateOut))
        (rrToken r)
        stateRef
        (realBooking r)
        payer

realBooking :: RetainedRegistry -> TerminationBooking
realBooking r =
    booking
        { tbCustody = (custodyRef, realCustody r)
        , tbCustodyAuthority = ScriptGuarded realCustodyScript custodyRedeemer
        }

-- | The key's singular tag under the real active policy, held at a wallet address.
realWalletCustody :: RetainedRegistry -> TxOut ConwayEra
realWalletCustody r = realCustody r & addrTxOutL .~ holderAddr

realWalletBooking :: RetainedRegistry -> TerminationBooking
realWalletBooking r =
    booking
        { tbCustody = (custodyRef, realWalletCustody r)
        , tbCustodyAuthority = WalletGuarded
        }

realWalletBuilt :: RetainedRegistry -> TxOut ConwayEra -> IO ConwayTx
realWalletBuilt r stateOut =
    bookTerminationImpl
        (rrConfig r)
        ( viewServing
            [ (payer, [(fundingIn, fundingOut)])
            , (cageAddrFromCfg (rrConfig r) Testnet, [(stateRef, stateOut)])
            , (holderAddr, [(custodyRef, realWalletCustody r)])
            ]
        )
        (rrToken r)
        stateRef
        (realWalletBooking r)
        payer

realServed :: RetainedRegistry -> TxOut ConwayEra -> Served
realServed r stateOut =
    [ (payer, [(fundingIn, fundingOut)])
    , (cageAddrFromCfg (rrConfig r) Testnet, [(stateRef, stateOut)])
    , (realCustodyAddr, [(custodyRef, realCustody r)])
    ]

-- | What the ledger's evaluator says of every script of a body over the real world.
judgedBy
    :: RetainedRegistry
    -> ConwayTx
    -> Map.Map (ConwayPlutusPurpose AsIx ConwayEra) (Either String ExUnits)
judgedBy r = judgedByWith r (realCustody r)

-- | The same, over a custody output the caller names: the one the body spends.
judgedByWith
    :: RetainedRegistry
    -> TxOut ConwayEra
    -> ConwayTx
    -> Map.Map (ConwayPlutusPurpose AsIx ConwayEra) (Either String ExUnits)
judgedByWith r custody tx =
    Map.map
        (either (Left . show) Right)
        ( evalTxExUnits
            ledgerParameters
            tx
            ( UTxO
                ( Map.fromList
                    [ (fundingIn, fundingOut)
                    , (stateRef, stateOutputWith r (pinnedBy (rrConfig r)))
                    , (custodyRef, custody)
                    ]
                )
            )
            (networkEpochInfo syntheticTime)
            (networkSystemStart syntheticTime)
        )

{- | The same body with the carrier its termination datum declares raised by
one lovelace, written on the raw datum, so that tip and carrier no longer
account for what the request holds.
-}
carrierRaised :: ConwayTx -> ConwayTx
carrierRaised tx =
    tx & bodyTxL . outputsTxBodyL %~ fmap bump
  where
    bump o = case rawDatumOf o of
        Just
            (Constr 4 [Constr 0 (registry : key : dest : t : I carrier : rest)]) ->
                o
                    & datumTxOutL
                        .~ mkInlineDatum
                            ( Constr
                                4
                                [Constr 0 (registry : key : dest : t : I (carrier + 1) : rest)]
                            )
        _ -> o
