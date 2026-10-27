{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.CLI.RegistryAddressSpec
Description : A registry named by one address, and the command that makes the address
License     : Apache-2.0

A registry has an address, one bech32 word that holds its state token and
names its network. These cases hold what a person is promised through the
command line alone, as the parser reads it ('parseInvocationFrom') and as the
packaged command runs it ('runSingular'):

* @singular registry address@ turns a state token and a network magic into the
  address, and an address back into what it holds, for the four networks and
  in lower case or upper case, with no chain and no provider;
* a word that is not the address of a registry is refused in one sentence that
  says which of four causes it is, in a fixed order, before anything else is
  read, with the exit status of a bad value;
* @--registry@ gives a command both the state token and the network magic, in
  each of the three forms of a standing setting, and a state token or a
  network magic beside it that disagrees is refused naming both;
* the old meaning of @--registry@, the state directory, is not refused as a
  rename any more.

Every address, fingerprint and refusing word compared against here was made by
an independent implementation of bech32 ("Singular.Registry.AddressVectors"), never
by the code under test. Every refusal is paired with the line that is read
when the one thing wrong is put right, so a refusal cannot be mistaken for a
line the program never understood.
-}
module Singular.CLI.RegistryAddressSpec (spec) where

import Control.Monad (forM_, when)
import Data.Aeson (Value (..), object, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Char (toUpper)
import Data.List (isInfixOf)
import Data.Text qualified as T
import Data.Word (Word32)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import Singular.CLI.Command
    ( Command (..)
    , FoldArgs (..)
    , InspectArgs (..)
    , ProviderSettings (..)
    , ReclaimArgs (..)
    , RegistryAccess (..)
    , RejectArgs (..)
    , WriteSettings (..)
    , parseInvocationFrom
    , renderCLIError
    , singularVersion
    )
import Singular.CLI.Help (singularHelp, singularProgram)
import Singular.CLI.Sources (Sources (..), configFromValue)
import Singular.Registry.AddressVectors
    ( Vector (..)
    , refusalWord
    , vectors
    )
import Singular.Registry.RunStreams (ran, said)
import Singular.Registry.StateToken (renderStateToken)

-- ---------------------------------------------------------------------------
-- The vectors

-- | The vector of this network and this position among the tokens made for it.
vectorAt :: Word32 -> Int -> Vector
vectorAt magic n =
    case drop n [v | v <- vectors, vMagic v == magic] of
        v : _ -> v
        [] -> error ("no vector for network " <> show magic)

tokenOf :: Vector -> String
tokenOf v = vPolicy v <> "." <> vName v

-- | The vectors a command that signs may name: mainnet is refused for a write.
writable :: [Vector]
writable = [v | v <- vectors, vMagic v /= 764824073]

-- ---------------------------------------------------------------------------
-- What a command line asks for

-- | The registry a command was told to act on: its state token and its network.
data Reading = Reading String Word32
    deriving stock (Eq, Show)

reading :: Command -> Maybe Reading
reading = \case
    Fold a ->
        named (foldAccess a) (providerMagic (writeProvider (foldWrite a)))
    Reject a ->
        named (rejectAccess a) (providerMagic (writeProvider (rejectWrite a)))
    Reclaim a ->
        named
            (reclaimAccess a)
            (providerMagic (writeProvider (reclaimWrite a)))
    Inspect a -> named (inspectAccess a) (providerMagic (inspectProvider a))
    _ -> Nothing
  where
    named access magic =
        Just
            (Reading (T.unpack (renderStateToken (accessToken access))) magic)

-- | What a person is told about a line: the reading, or the sentence.
told :: [String] -> Either String Reading
told = toldWith [] []

toldWith
    :: [(String, String)]
    -> [(String, String)]
    -> [String]
    -> Either String Reading
toldWith environment keys line =
    case parseInvocationFrom (Sources environment (Right keys)) line of
        Left err -> Left (renderCLIError err)
        Right (command, _) ->
            maybe (Left "not a registry command") Right (reading command)

-- | The line is read, whatever it asks for.
isRead :: Either String a -> Bool
isRead = either (const False) (const True)

refusedWith :: Either String a -> [String] -> Expectation
refusedWith result needles = case result of
    Left sentence -> forM_ needles $ \needle ->
        (needle, sentence) `shouldSatisfy` uncurry isInfixOf
    Right _ -> expectationFailure "the line was read, it should be refused"

refusedNot :: Either String a -> [String] -> Expectation
refusedNot result needles = case result of
    Left sentence -> forM_ needles $ \needle ->
        (needle, sentence) `shouldSatisfy` (not . uncurry isInfixOf)
    Right _ -> expectationFailure "the line was read, it should be refused"

-- ---------------------------------------------------------------------------
-- The commands that take a registry

node :: [String]
node =
    ["--blueprint", "plutus.json", "--koios-url", "http://koios.example"]

request :: String
request = replicate 64 'a' <> "#0"

-- | Each command that takes a state token, with everything else it needs.
commands :: [(String, [String])]
commands =
    [
        ( "registry fold"
        , ["registry", "fold"] <> node <> ["--vault", "alice.vault"]
        )
    ,
        ( "registry reject"
        , ["registry", "reject"] <> node <> ["--vault", "alice.vault"]
        )
    ,
        ( "registry reclaim"
        , ["registry", "reclaim"]
            <> node
            <> ["--vault", "alice.vault", "--request", request]
        )
    ,
        ( "registry inspect"
        , ["registry", "inspect"] <> node <> ["--key", "key"]
        )
    ]

inspectLine :: [String]
inspectLine = snd (commands !! 3)

-- | A command that signs, which no network without a signer may be named for.
writes :: String -> Bool
writes name =
    name `elem` ["registry fold", "registry reject", "registry reclaim"]

-- ---------------------------------------------------------------------------
-- The three forms of a standing setting

data Form = AsFlag | AsVariable | AsKey
    deriving stock (Eq, Show, Enum, Bounded)

data Setting = Setting
    { settingFlag :: String
    , settingVariable :: String
    , settingKey :: String
    }

registrySetting, tokenSetting, magicSetting :: Setting
registrySetting = Setting "--registry" "SINGULAR_REGISTRY" "registry"
tokenSetting = Setting "--state-token" "SINGULAR_STATE_TOKEN" "state-token"
magicSetting = Setting "--network-magic" "SINGULAR_NETWORK_MAGIC" "network-magic"

-- | Give a setting a value in a form: arguments, variables, keys.
given
    :: Form
    -> Setting
    -> String
    -> ([String], [(String, String)], [(String, String)])
given AsFlag s v = ([settingFlag s, v], [], [])
given AsVariable s v = ([], [(settingVariable s, v)], [])
given AsKey s v = ([], [], [(settingKey s, v)])

-- | A line with several settings, each in its own form.
toldPlaced
    :: [String] -> [(Form, Setting, String)] -> Either String Reading
toldPlaced base placed =
    toldWith
        (concat [e | (_, e, _) <- parts])
        (concat [k | (_, _, k) <- parts])
        (base <> concat [a | (a, _, _) <- parts])
  where
    parts = [given form s v | (form, s, v) <- placed]

-- ---------------------------------------------------------------------------

spec :: Spec
spec = describe "a registry has an address" $ do
    addressCommandRows
    readingRefusalRows
    registryGivenRows
    agreementRows
    existingFormsRows
    oldNameRows
    commandsThatTakeNoRegistryRows
    helpRows
    settingsFileRows

-- | @singular registry address@: from a state token and a network, and from an address.
addressCommandRows :: Spec
addressCommandRows = describe "the command registry address" $ do
    describe "from a state token and a network magic" $
        forM_ vectors $ \v ->
            it
                ( "makes the "
                    <> vPrefix v
                    <> " address of "
                    <> take 12 (vPolicy v)
                    <> "..."
                )
                $ do
                    (code, out, err) <-
                        ran
                            []
                            [ "registry"
                            , "address"
                            , "--state-token"
                            , tokenOf v
                            , "--network-magic"
                            , show (vMagic v)
                            ]
                    code `shouldBe` ExitSuccess
                    err `shouldBe` ""
                    receiptOf out `shouldBe` holding v
    describe "from an address" $
        forM_ vectors $ \v -> do
            it ("shows what the " <> vPrefix v <> " address holds") $ do
                (code, out, _) <-
                    ran [] ["registry", "address", "--registry", vAddress v]
                code `shouldBe` ExitSuccess
                receiptOf out `shouldBe` holding v
            it ("reads the same " <> vPrefix v <> " address in upper case") $ do
                (code, out, _) <-
                    ran
                        []
                        ["registry", "address", "--registry", map toUpper (vAddress v)]
                code `shouldBe` ExitSuccess
                receiptOf out `shouldBe` holding v
    describe "in each of the three forms of the registry" $ do
        let v = vectorAt 1 0
        it "the flag" $ do
            (code, out, _) <-
                ran [] ["registry", "address", "--registry", vAddress v]
            code `shouldBe` ExitSuccess
            receiptOf out `shouldBe` holding v
        it "the variable SINGULAR_REGISTRY" $ do
            (code, out, _) <-
                ran [("SINGULAR_REGISTRY", vAddress v)] ["registry", "address"]
            code `shouldBe` ExitSuccess
            receiptOf out `shouldBe` holding v
        it "the key registry of the settings file" $
            withSystemTempDirectory "registry-address" $ \dir -> do
                let file = dir </> "singular.json"
                writeFile file ("{\"registry\": \"" <> vAddress v <> "\"}")
                (code, out, _) <-
                    ran [] ["registry", "address", "--config", file]
                code `shouldBe` ExitSuccess
                receiptOf out `shouldBe` holding v
        it "a state token and a network magic from the variables" $ do
            (code, out, _) <-
                ran
                    [ ("SINGULAR_STATE_TOKEN", tokenOf v)
                    , ("SINGULAR_NETWORK_MAGIC", "1")
                    ]
                    ["registry", "address"]
            code `shouldBe` ExitSuccess
            receiptOf out `shouldBe` holding v
    describe "a network magic that has no prefix" $ do
        let v = vectorAt 42 0
        forM_ [0, 3, 100, 764824074 :: Word32] $ \magic ->
            it ("is refused for " <> show magic <> ", with no address printed") $ do
                (code, out, err) <-
                    ran
                        []
                        [ "registry"
                        , "address"
                        , "--state-token"
                        , tokenOf v
                        , "--network-magic"
                        , show magic
                        ]
                code `shouldBe` ExitFailure 2
                out `shouldBe` ""
                said err `shouldSatisfy` isInfixOf (show magic)
                said err `shouldSatisfy` isInfixOf "prefix"
        it "is no refusal on a network that has one" $ do
            (code, _, _) <-
                ran
                    []
                    [ "registry"
                    , "address"
                    , "--state-token"
                    , tokenOf v
                    , "--network-magic"
                    , "42"
                    ]
            code `shouldBe` ExitSuccess
    describe "input that cannot be turned into an address" $ do
        let v = vectorAt 1 0
        it "is a state token that is not one" $ do
            (code, out, err) <-
                ran
                    []
                    [ "registry"
                    , "address"
                    , "--state-token"
                    , "xyz"
                    , "--network-magic"
                    , "1"
                    ]
            code `shouldBe` ExitFailure 2
            out `shouldBe` ""
            said err `shouldSatisfy` isInfixOf "--state-token"
        it "is a state token with no network magic" $ do
            (code, out, err) <-
                ran [] ["registry", "address", "--state-token", tokenOf v]
            code `shouldBe` ExitFailure 2
            out `shouldBe` ""
            said err `shouldSatisfy` isInfixOf "--network-magic"
        it "is nothing at all" $ do
            (code, out, err) <- ran [] ["registry", "address"]
            code `shouldBe` ExitFailure 2
            out `shouldBe` ""
            said err `shouldSatisfy` isInfixOf "--registry"
        it "is a registry that is not an address" $ do
            (code, out, err) <-
                ran [] ["registry", "address", "--registry", "not-an-address"]
            code `shouldBe` ExitFailure 2
            out `shouldBe` ""
            said err `shouldSatisfy` isInfixOf "not an address"
  where
    holding v =
        [ ("registry", String (T.pack (vAddress v)))
        , ("stateToken", String (T.pack (tokenOf v)))
        , ("fingerprint", String (T.pack (vFingerprint v)))
        , ("networkMagic", Number (fromIntegral (vMagic v)))
        ]
    receiptOf out = case Aeson.decodeStrict out of
        Just (Object o) ->
            [ (Key.fromText k, v)
            | k <- ["registry", "stateToken", "fingerprint", "networkMagic"]
            , Just v <- [KeyMap.lookup (Key.fromText k) o]
            ]
        _ -> []

-- | Each word that is not a registry's address, told which cause it is.
readingRefusalRows :: Spec
readingRefusalRows = describe "an address is read before anything else" $ do
    let line word =
            ["registry", "fold", "--registry", word]
                <> node
                <> ["--vault", "alice.vault"]
        refusing name word keywords absent =
            it name $ do
                told (line word) `refusedWith` keywords
                told (line word) `refusedNot` absent
    it "reads a good address, which is the control of every row below" $
        told (line (refusalWord "good")) `shouldSatisfy` isRead
    describe "1: not a bech32 word, or upper and lower case mixed" $ do
        refusing
            "a mixture of cases"
            (refusalWord "mixed-case")
            ["not an address"]
            ["checksum", "prefix", "60"]
        refusing
            "a character no bech32 word has"
            (refusalWord "invalid-character")
            ["not an address"]
            ["checksum", "60"]
        refusing
            "no separator"
            (refusalWord "no-separator")
            ["not an address"]
            ["checksum", "60"]
        refusing
            "text that is not a word"
            "this is not an address"
            ["not an address"]
            ["checksum", "60"]
        refusing "an empty word" "" ["not an address"] ["checksum", "60"]
        it "says that --registry once named the state directory" $
            told (line "/srv/registry")
                `refusedWith` ["not an address", "--registry", "--state-dir"]
    describe "2: the checksum does not match" $ do
        refusing
            "one character changed"
            (refusalWord "bad-checksum")
            ["checksum"]
            ["not an address", "60", "--state-dir"]
        refusing
            "one character changed in a word whose prefix is unknown"
            (refusalWord "bad-checksum-and-unknown-prefix")
            ["checksum"]
            ["unknown", "singular_mainnet", "--state-dir"]
        refusing
            "one character changed in a word whose body is short"
            (refusalWord "bad-checksum-and-short")
            ["checksum"]
            ["59", "--state-dir"]
    describe "3: the prefix is not one of the four" $ do
        refusing
            "a prefix with a right checksum"
            (refusalWord "unknown-prefix")
            [ "prefix"
            , "singular_mainnet"
            , "singular_preprod"
            , "singular_preview"
            , "singular_devnet"
            ]
            ["checksum", "not an address", "--state-dir"]
        refusing
            "a prefix and a body length that are both wrong"
            (refusalWord "unknown-prefix-and-short")
            ["prefix", "other"]
            ["59", "checksum", "--state-dir"]
    describe "4: the body is not 60 bytes" $ do
        refusing
            "59 bytes"
            (refusalWord "short")
            ["59 bytes", "60"]
            ["checksum", "prefix", "--state-dir"]
        refusing
            "61 bytes"
            (refusalWord "long")
            ["61 bytes", "60"]
            ["checksum", "prefix", "--state-dir"]
        refusing
            "no bytes"
            (refusalWord "empty-body")
            ["0 bytes", "60"]
            ["checksum", "prefix", "--state-dir"]
    describe "through the packaged command"
        $ forM_
            [ ("mixed-case", "not an address")
            , ("bad-checksum", "checksum")
            , ("unknown-prefix", "prefix")
            , ("short", "59 bytes")
            ]
        $ \(name, cause) ->
            it
                ( "refuses the word "
                    <> name
                    <> " with status 2, before anything else is read"
                )
                $ do
                    -- none of these paths exists: any read of one would be another failure
                    (code, out, err) <-
                        ran
                            []
                            [ "registry"
                            , "fold"
                            , "--registry"
                            , refusalWord name
                            , "--blueprint"
                            , "/nonexistent/plutus.json"
                            , "--koios-url"
                            , "http://127.0.0.1:9"
                            , "--vault"
                            , "/nonexistent/alice.vault"
                            , "--state-dir"
                            , "/nonexistent/state"
                            ]
                    code `shouldBe` ExitFailure 2
                    out `shouldBe` ""
                    said err `shouldSatisfy` isInfixOf cause
                    said err `shouldSatisfy` (not . isInfixOf "alice.vault")
                    said err `shouldSatisfy` (not . isInfixOf "plutus.json")

-- | @--registry@ alone gives a command its state token and its network.
registryGivenRows :: Spec
registryGivenRows = describe "the registry given to a command" $ do
    forM_ commands $ \(name, base) ->
        describe name $ do
            forM_ (if writes name then writable else vectors) $ \v ->
                it
                    ( "is named by the "
                        <> vPrefix v
                        <> " address of "
                        <> take 12 (vPolicy v)
                        <> "... alone"
                    )
                    $ toldPlaced base [(AsFlag, registrySetting, vAddress v)]
                        `shouldBe` Right (Reading (tokenOf v) (vMagic v))
            let v = vectorAt 1 0
            it "is named by the variable SINGULAR_REGISTRY alone" $
                toldPlaced base [(AsVariable, registrySetting, vAddress v)]
                    `shouldBe` Right (Reading (tokenOf v) 1)
            it "is named by the key registry of the settings file alone" $
                toldPlaced base [(AsKey, registrySetting, vAddress v)]
                    `shouldBe` Right (Reading (tokenOf v) 1)
            it "is named by an address in upper case" $
                toldPlaced base [(AsFlag, registrySetting, map toUpper (vAddress v))]
                    `shouldBe` Right (Reading (tokenOf v) 1)
            it "is still refused with no registry and no state token, as before" $
                told (base <> ["--network-magic", "1"])
                    `shouldBe` Left "missing --state-token"
    describe "the three forms keep their precedence" $ do
        let a = vectorAt 1 0
            b = vectorAt 2 0
        it "the flag wins over the variable" $
            toldWith
                [("SINGULAR_REGISTRY", vAddress b)]
                []
                (inspectLine <> ["--registry", vAddress a])
                `shouldBe` Right (Reading (tokenOf a) 1)
        it "the variable wins over the key" $
            toldWith
                [("SINGULAR_REGISTRY", vAddress a)]
                [("registry", vAddress b)]
                inspectLine
                `shouldBe` Right (Reading (tokenOf a) 1)

-- | A state token or a network magic beside the registry must agree with it.
agreementRows :: Spec
agreementRows = describe "a state token and a network magic beside the registry" $ do
    let a = vectorAt 1 0
        other = vectorAt 1 1
        forms = [minBound .. maxBound] :: [Form]
    describe "agreeing, from any two forms, are accepted" $
        forM_ forms $ \registryForm -> forM_ forms $ \tokenForm ->
            it
                ( "the registry as "
                    <> show registryForm
                    <> " with its state token as "
                    <> show tokenForm
                )
                $ toldPlaced
                    inspectLine
                    [ (registryForm, registrySetting, vAddress a)
                    , (tokenForm, tokenSetting, tokenOf a)
                    ]
                    `shouldBe` Right (Reading (tokenOf a) 1)
    describe "agreeing network magics are accepted" $
        forM_ forms $ \registryForm -> forM_ forms $ \magicForm ->
            it
                ( "the registry as "
                    <> show registryForm
                    <> " with its network magic as "
                    <> show magicForm
                )
                $ toldPlaced
                    inspectLine
                    [ (registryForm, registrySetting, vAddress a)
                    , (magicForm, magicSetting, "1")
                    ]
                    `shouldBe` Right (Reading (tokenOf a) 1)
    describe
        "a state token that names another token is refused, naming both"
        $ forM_ forms
        $ \registryForm -> forM_ forms $ \tokenForm ->
            it
                ( "the registry as "
                    <> show registryForm
                    <> " against a state token as "
                    <> show tokenForm
                )
                $ toldPlaced
                    inspectLine
                    [ (registryForm, registrySetting, vAddress a)
                    , (tokenForm, tokenSetting, tokenOf other)
                    ]
                    `refusedWith` [tokenOf a, tokenOf other, "--state-token"]
    describe
        "a network magic that names another network is refused, naming both"
        $ forM_ forms
        $ \registryForm -> forM_ forms $ \magicForm ->
            it
                ( "the registry as "
                    <> show registryForm
                    <> " against a network magic as "
                    <> show magicForm
                )
                $ toldPlaced
                    inspectLine
                    [ (registryForm, registrySetting, vAddress a)
                    , (magicForm, magicSetting, "42")
                    ]
                    `refusedWith` ["42", "singular_preprod", "--network-magic"]
    it "refuses each of the four commands that takes a state token" $
        forM_ commands $ \(name, base) -> do
            toldPlaced
                base
                [ (AsFlag, registrySetting, vAddress a)
                , (AsFlag, tokenSetting, tokenOf other)
                ]
                `refusedWith` [tokenOf a, tokenOf other]
            toldPlaced
                base
                [ (AsFlag, registrySetting, vAddress a)
                , (AsFlag, tokenSetting, tokenOf a)
                ]
                `shouldBe` Right (Reading (tokenOf a) 1)
            when (writes name) $
                toldPlaced
                    base
                    [ (AsFlag, registrySetting, vAddress a)
                    , (AsFlag, magicSetting, "42")
                    ]
                    `refusedWith` ["42", "--network-magic"]
    it
        "refuses a stale state-token key beside a new registry key, saying what disagrees"
        $ toldPlaced
            inspectLine
            [ (AsKey, registrySetting, vAddress a)
            , (AsKey, tokenSetting, tokenOf other)
            ]
            `refusedWith` [tokenOf a, tokenOf other]

-- | Naming a registry by its state token and its network works as it always did.
existingFormsRows :: Spec
existingFormsRows = describe "the state token with the network magic" $ do
    forM_ commands $ \(name, base) ->
        it (name <> " reads them as it always did") $ do
            let v = vectorAt 1 0
            toldPlaced
                base
                [ (AsFlag, tokenSetting, tokenOf v)
                , (AsFlag, magicSetting, "1")
                ]
                `shouldBe` Right (Reading (tokenOf v) 1)
            toldPlaced
                base
                [ (AsVariable, tokenSetting, tokenOf v)
                , (AsKey, magicSetting, "1")
                ]
                `shouldBe` Right (Reading (tokenOf v) 1)
    it "refuses a state token with no network magic as it always did" $
        toldPlaced
            inspectLine
            [(AsFlag, tokenSetting, tokenOf (vectorAt 1 0))]
            `shouldBe` Left "missing --network-magic"

-- | @--registry@ is no longer a renamed flag.
oldNameRows :: Spec
oldNameRows = describe "the old name of --state-dir" $ do
    it "is not refused as renamed any more" $
        forM_ ["/srv/registry", "registry"] $ \word ->
            told (inspectLine <> ["--registry", word])
                `refusedNot` ["was renamed to"]
    it "is read in the spelling with an equals sign" $
        told (inspectLine <> ["--registry=" <> vAddress (vectorAt 1 0)])
            `shouldBe` Right (Reading (tokenOf (vectorAt 1 0)) 1)

-- | The commands that take no state token take no registry either.
commandsThatTakeNoRegistryRows :: Spec
commandsThatTakeNoRegistryRows =
    describe "a command that names no registry" $ do
        let a = vectorAt 1 0
        forM_
            [ ["wallet", "create", "--vault", "alice.vault", "--network-magic", "1"]
            ,
                [ "wallet"
                , "address"
                , "--vault"
                , "alice.vault"
                , "--network-magic"
                , "1"
                ]
            , ["wallet", "sign", "bundle.json", "--vault", "alice.vault"]
            ,
                [ "submit"
                , "bundle.json"
                , "--witnesses"
                , "w"
                , "--koios-url"
                , "http://k"
                , "--network-magic"
                , "1"
                ]
            ]
            $ \line -> do
                let name = unwords (take 2 line)
                it (name <> " reads its line") $
                    readable line `shouldBe` True
                it (name <> " refuses --registry by name, not as a rename") $ do
                    let result = refusal (line <> ["--registry", vAddress a])
                    result `refusedWith` ["--registry"]
                    result `refusedNot` ["was renamed to"]
        it "registry create refuses --registry by name, not as a rename" $ do
            let result =
                    refusal
                        ( ["registry", "create", "--registry", vAddress a]
                            <> node
                            <> ["--network-magic", "1", "--vault", "alice.vault"]
                        )
            result `refusedWith` ["--registry"]
            result `refusedNot` ["was renamed to"]
  where
    parsed = parseInvocationFrom (Sources [] (Right []))
    readable = either (const False) (const True) . parsed
    refusal line = either (Left . renderCLIError) (const (Right ())) (parsed line)

{- | The paragraph of a help page that describes one setting: its description, and the
lines that name its flag, its variable and its key.
-}
settingBlock :: String -> String -> String
settingBlock option page =
    case [ b | b <- paragraphs (lines page), ("option: " <> option) `isInfixOf` b
         ] of
        b : _ -> b
        [] -> ""
  where
    paragraphs ls = case break null ls of
        (block, rest) ->
            unlines block : case rest of
                [] -> []
                _ : more -> paragraphs more

-- | The help tells what the registry setting is and where it is read.
helpRows :: Spec
helpRows = describe "the help" $ do
    forM_ ["fold", "reject", "reclaim", "inspect"] $ \command ->
        describe ("of registry " <> command) $ do
            let page = singularHelp singularVersion [] ["registry", command]
            it "lists --registry, its variable and its key" $ do
                page `shouldSatisfy` isInfixOf "--registry"
                page `shouldSatisfy` isInfixOf "SINGULAR_REGISTRY"
            it "says the address gives the state token and the network" $
                forM_ ["address", "state token", "network"] $ \word ->
                    settingBlock "--registry" page `shouldSatisfy` isInfixOf word
    it "of registry create does not list --registry" $
        singularHelp singularVersion [] ["registry", "create"]
            `shouldSatisfy` (not . isInfixOf "--registry")
    it "of the overview lists the command that makes an address" $
        singularHelp singularVersion [] []
            `shouldSatisfy` isInfixOf "singular registry address"
    describe "of registry address" $ do
        let page = singularHelp singularVersion [] ["registry", "address"]
        it "lists the three settings that name a registry" $
            forM_ ["--registry", "--state-token", "--network-magic"] $ \flag ->
                page `shouldSatisfy` isInfixOf flag
        it "says it reads no chain" $
            page `shouldSatisfy` isInfixOf "chain"
        it "gives an example and says how it ends" $ do
            page `shouldSatisfy` isInfixOf "Example"
            page `shouldSatisfy` isInfixOf "Exit status"
    it "names the program's own prefixes" $
        singularHelp singularVersion [] ["registry", "address"]
            `shouldSatisfy` \page ->
                all
                    (`isInfixOf` page)
                    ["singular_preprod", "singular_preview", "singular_devnet"]

-- | The settings file may give the registry.
settingsFileRows :: Spec
settingsFileRows = describe "the settings file" $ do
    let a = vectorAt 1 0
    it "may hold the key registry" $
        configFromValue
            (singularProgram singularVersion)
            "singular.json"
            (object ["registry" .= String (T.pack (vAddress a))])
            `shouldSatisfy` isRight'
    it "still refuses a key no setting has" $
        configFromValue
            (singularProgram singularVersion)
            "singular.json"
            (object ["registre" .= String "x"])
            `shouldSatisfy` (not . isRight')
  where
    isRight' = either (const False) (const True)
