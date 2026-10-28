{-# LANGUAGE OverloadedStrings #-}

-- | Generic application pinning assertions retained after the old builders leave.
module Singular.Application.OpenDatum.BuildersSpec (spec) where

import Cardano.Ledger.BaseTypes (Network (Testnet))
import Data.ByteString.Short qualified as SBS
import Data.Text qualified as T
import Singular.Registry.Application (ApplicationPin (..))
import Singular.Registry.Blueprint (NamingCodes (..), applyBytesParam)
import Singular.Registry.Config (CageConfig (..))
import Singular.Registry.Config.Application
import Singular.Registry.Deployment (parseOutRef)
import Singular.Registry.Ledger (Coin (..), TxIn)
import Singular.Registry.SyntheticLedger (unitProgram)
import Singular.Registry.TxBuilder.Internal
    ( computeScriptHash
    , scriptHashBytes
    , txInToRef
    )
import Test.Hspec

spec :: Spec
spec = pinning

program :: SBS.ShortByteString
program = unitProgram 2

codes :: NamingCodes
codes = NamingCodes{ncApplication = program, ncWitness = program}

ref :: Char -> Int -> TxIn
ref c i =
    either
        error
        id
        (parseOutRef (T.pack (replicate 64 c <> "#" <> show i)))

stateBytes, requestBytes :: SBS.ShortByteString
stateBytes = program
requestBytes = program

seedRef :: TxIn
seedRef = ref '9' 0

economics :: RegistryEconomics
economics = RegistryEconomics 30_000 30_000 (Coin 1_000_000)

bootWith :: ApplicationPin -> TxIn -> (CageConfig, NamingCodes)
bootWith pin seed =
    configForApplication
        pin
        codes
        stateBytes
        requestBytes
        economics
        Testnet
        (txInToRef seed)

pinning :: Spec
pinning = describe "pinning the application at boot" $ do
    it
        "pins the application script applied to the identity the seed determines"
        $ let (cfg, pinned) =
                bootWith (PinByScript "parameterized application") seedRef
              identity = registryIdentity stateBytes (txInToRef seedRef)
          in  do
                ncApplication pinned `shouldBe` applyBytesParam identity program
                SBS.fromShort (cfgApplicationPolicy cfg)
                    `shouldBe` scriptHashBytes (computeScriptHash (ncApplication pinned))
    it "pins the unapplied application as compiled, whatever the seed" $
        cfgApplicationPolicy
            ( fst
                (bootWith (PinAsCompiled "compiled application") seedRef)
            )
            `shouldBe` cfgApplicationPolicy
                ( fst
                    ( bootWith
                        (PinAsCompiled "compiled application")
                        (ref '8' 0)
                    )
                )
    it "pins another application policy for another seed" $
        cfgApplicationPolicy
            ( fst
                (bootWith (PinByScript "parameterized application") seedRef)
            )
            `shouldNotBe` cfgApplicationPolicy
                ( fst
                    ( bootWith
                        (PinByScript "parameterized application")
                        (ref '8' 0)
                    )
                )
