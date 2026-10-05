{-# LANGUAGE LambdaCase #-}

{- |
Module      : Singular.Provider.Koios.HttpSpec
Description : The live Koios transport against a loopback fake server
License     : Apache-2.0

Each failure mode of the live transport produced on demand by a local
server: rate limiting, slow answers, cut-off and missing pages, server
errors, refused tokens and refused submissions. Every test asserts the
named failure the client returns and the attempts the server counted.
The timings are configuration values, so the suite runs in seconds.
-}
module Singular.Provider.Koios.HttpSpec (spec) where

import Control.Exception (bracket)
import Control.Monad (forM, forM_)
import Data.Aeson (Value (..), decodeStrict', encode)
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BSL
import Data.Char (ord)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (diffUTCTime, getCurrentTime)
import Network.Socket
    ( AddrInfo (..)
    , Family (..)
    , SocketType (..)
    , bind
    , close
    , defaultHints
    , getAddrInfo
    , socket
    , socketPort
    )
import Network.Wai (Response)
import Numeric (showHex)
import System.Directory (getTemporaryDirectory)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec
import Test.QuickCheck qualified as QC

import Singular.Provider.Koios.Client
import Singular.Provider.Koios.FakeServer
import Singular.Provider.Koios.Http
import Singular.Provider.Koios.Recorder
    ( ReadRequest (..)
    , RecorderConfig (..)
    , probe
    , recordFixtures
    )
import Singular.Provider.Koios.Scripted
    ( assetTxRow
    , pageAnswer
    , scriptHashOfByte
    , txIdOfByte
    )
import Singular.Provider.Koios.Wire (tipRequest)

import Cardano.Ledger.Mary.Value (AssetName (..), PolicyID (..))

-- | Fast bounds: three attempts, short delays, a short timeout.
fast :: Text -> HttpConfig
fast base =
    (defaultHttpConfig base)
        { httpTimeout = 0.3
        , httpAttempts = 3
        , httpBaseDelay = 0.02
        , httpMaxDelay = 0.2
        , httpRateLimitCeiling = 2
        , httpCallCeiling = 10
        }

-- | Build the transport, failing the test on a configuration failure.
transportFor :: HttpConfig -> IO (Transport IO)
transportFor cfg =
    newHttpTransport cfg >>= \case
        Right t -> pure t
        Left r -> fail ("transport: " <> show r)

clientFor :: HttpConfig -> IO (Koios IO)
clientFor cfg =
    Koios ClientConfig{pageSize = 2, pageCeiling = 10}
        <$> transportFor cfg

tipBody :: BS.ByteString
tipBody =
    "[{\"hash\":\"a276580588fa929d282d3466faccd85ea6f816d53f9cb6e9d57ac3cbd1935160\",\
    \\"epoch_no\":317,\"abs_slot\":135445500,\"epoch_slot\":143100,\
    \\"block_height\":5253272,\"block_no\":5253272,\"block_time\":1791128700}]"

reasonOf :: Either ClientFailure a -> Maybe (Int, FailureReason)
reasonOf =
    either
        (\f -> Just (failureAttempts f, failureReason f))
        (const Nothing)

spec :: Spec
spec = describe "Koios HTTP transport" $ do
    retrySpec
    pageSpec
    tokenSpec
    echoSpec
    tokenDomainSpec
    submitSpec

retrySpec :: Spec
retrySpec = describe "retries" $ do
    it "honours a 429's requested wait, then succeeds"
        $ withFakeKoios
            ( \_ n ->
                if n == 0
                    then respond 429 [("retry-after", "1")] "slow down"
                    else respond 200 [] tipBody
            )
        $ \base logOf -> do
            k <- clientFor (fast base)
            start <- getCurrentTime
            result <- tip k
            end <- getCurrentTime
            either (fail . show) (const (pure ())) result
            countAt "/tip" <$> logOf `shouldReturn` 2
            diffUTCTime end start `shouldSatisfy` (>= 1)

    it "is rate limited after the attempt bound when 429 never stops" $
        withFakeKoios (\_ _ -> respond 429 [] "slow down") $ \base logOf -> do
            k <- clientFor (fast base)
            reasonOf <$> tip k `shouldReturn` Just (3, RateLimited Nothing)
            countAt "/tip" <$> logOf `shouldReturn` 3

    it "stops at once when a 429 asks for a wait beyond the ceiling" $
        withFakeKoios (\_ _ -> respond 429 [("retry-after", "120")] "") $ \base logOf -> do
            k <- clientFor (fast base)
            reasonOf <$> tip k `shouldReturn` Just (1, RateLimited (Just 120))
            countAt "/tip" <$> logOf `shouldReturn` 1

    it
        "times out an answer slower than the timeout, after the attempt bound"
        $ withFakeKoios (\_ _ -> respondAfter 1.5 200 [] tipBody)
        $ \base logOf -> do
            k <- clientFor (fast base)
            reasonOf <$> tip k `shouldReturn` Just (3, TimedOut)
            countAt "/tip" <$> logOf `shouldReturn` 3

    it "retries a 503 and succeeds on the next answer"
        $ withFakeKoios
            ( \_ n ->
                if n == 0 then respond 503 [] "busy" else respond 200 [] tipBody
            )
        $ \base logOf -> do
            k <- clientFor (fast base)
            result <- tip k
            either (fail . show) (const (pure ())) result
            countAt "/tip" <$> logOf `shouldReturn` 2

    it
        "is server failing after the bound, with growing delays between attempts"
        $ withFakeKoios (\_ _ -> respond 503 [] "busy")
        $ \base logOf -> do
            k <-
                clientFor
                    (fast base){httpAttempts = 4, httpBaseDelay = 0.05, httpMaxDelay = 1}
            reasonOf <$> tip k `shouldReturn` Just (4, ServerFailing 503 "busy")
            seen <- logOf
            let times = map seenAt seen
                gaps = zipWith diffUTCTime (drop 1 times) times
            case gaps of
                [g1, _, g3] -> g3 `shouldSatisfy` (> g1)
                _ -> expectationFailure ("gaps: " <> show gaps)

    it
        "bounds the elapsed time of a call by its ceiling, attempts included"
        $ withFakeKoios (\_ _ -> respondAfter 3 200 [] tipBody)
        $ \base _ -> do
            k <-
                clientFor
                    (fast base)
                        { httpTimeout = 1
                        , httpAttempts = 5
                        , httpCallCeiling = 1.5
                        }
            start <- getCurrentTime
            result <- tip k
            end <- getCurrentTime
            reasonOf result
                `shouldSatisfy` (\case Just (_, TimedOut) -> True; _ -> False)
            diffUTCTime end start `shouldSatisfy` (< 1.8)

    it "starts no retry that would end past the per-call ceiling" $
        withFakeKoios (\_ _ -> respond 503 [] "busy") $ \base logOf -> do
            k <-
                clientFor
                    (fast base)
                        { httpAttempts = 10
                        , httpBaseDelay = 0.2
                        , httpMaxDelay = 0.2
                        , httpCallCeiling = 0.5
                        }
            Just (attempts, ServerFailing 503 _) <- reasonOf <$> tip k
            count <- countAt "/tip" <$> logOf
            count `shouldBe` attempts
            count `shouldSatisfy` (< 10)

    it "does not retry a 401 or a 400 on a read"
        $ withFakeKoios
            ( \s _ ->
                if seenPath s == "/tip"
                    then respond 401 [] "bad token"
                    else respond 400 [] "bad request"
            )
        $ \base logOf -> do
            k <- clientFor (fast base)
            reasonOf <$> tip k
                `shouldReturn` Just (1, RefusedByServer 401 "bad token")
            reasonOf <$> txStatus k [txIdOfByte 1]
                `shouldReturn` Just (1, RefusedByServer 400 "bad request")
            map seenPath <$> logOf `shouldReturn` ["/tip", "/tx_status"]

    it "is unreachable after the bound when nothing listens" $ do
        port <- freePort
        k <-
            clientFor
                (fast ("http://127.0.0.1:" <> T.pack (show port) <> "/api/v1"))
        result <- tip k
        case result of
            Left ClientFailure{failureAttempts = 3, failureReason = Unreachable _} -> pure ()
            other -> expectationFailure (show other)

pageSpec :: Spec
pageSpec = describe "pages over HTTP" $ do
    let rows =
            [ assetTxRow (T.justifyRight 64 '0' (T.pack (show i))) 317 i
            | i <- [1 .. 5]
            ]
        honest = pageResponse rows
        policy = PolicyID (scriptHashOfByte 3)
    it "reads every page of a paged answer" $
        withFakeKoios (\s _ -> honest s) $ \base logOf -> do
            k <- clientFor (fast base)
            result <- assetTxs k policy (AssetName "")
            fmap length result `shouldBe` Right 5
            countAt "/asset_txs" <$> logOf `shouldReturn` 3

    it "refuses a body cut off mid-array"
        $ withFakeKoios
            ( \s _ ->
                if offsetIn s == 2
                    then respond 206 [("content-range", "2-3/5")] "[{\"tx_hash\":\"00"
                    else honest s
            )
        $ \base _ -> do
            k <- clientFor (fast base)
            result <- assetTxs k policy (AssetName "")
            case result of
                Left ClientFailure{failureReason = IncompletePage (PageCutOff 2 _)} -> pure ()
                other -> expectationFailure (show other)

    it "refuses a missing middle page"
        $ withFakeKoios
            ( \s _ ->
                if offsetIn s == 2
                    then respond 200 [("content-range", "*/5")] "[]"
                    else honest s
            )
        $ \base _ -> do
            k <- clientFor (fast base)
            result <- assetTxs k policy (AssetName "")
            case result of
                Left ClientFailure{failureReason = IncompletePage (RowsMissing 5 2)} -> pure ()
                other -> expectationFailure (show other)

    it "answers an honestly empty history with an empty success" $
        withFakeKoios (\_ _ -> respond 200 [("content-range", "*/0")] "[]") $ \base _ -> do
            k <- clientFor (fast base)
            assetTxs k policy (AssetName "") `shouldReturn` Right []

tokenSpec :: Spec
tokenSpec = describe "bearer token" $ do
    let token = "koios-test-token-7f3a"
    it
        "a missing token file is a configuration failure before any request"
        $ withFakeKoios (\_ _ -> respond 200 [] tipBody)
        $ \base logOf -> do
            tmp <- getTemporaryDirectory
            let missing = tmp </> "singular-koios-no-such-token-file"
            result <- newHttpTransport (fast base){httpTokenFile = Just missing}
            case result of
                Left (TokenFileUnreadable path _) -> path `shouldBe` missing
                Left other -> expectationFailure (show other)
                Right _ -> expectationFailure "a transport was built without its token"
            length <$> logOf `shouldReturn` 0

    it "sends the token from the file as a bearer header" $
        withSystemTempDirectory "koios-token" $ \dir ->
            withFakeKoios (\_ _ -> respond 200 [] tipBody) $ \base logOf -> do
                let file = dir </> "token"
                writeFile file (T.unpack token <> "\n")
                k <- clientFor (fast base){httpTokenFile = Just file}
                _ <- tip k
                seen <- logOf
                map (lookup "authorization" . seenHeaders) seen
                    `shouldBe` [Just ("Bearer " <> token)]

    it "keeps the token out of every failure" $
        withSystemTempDirectory "koios-token" $ \dir -> do
            let file = dir </> "token"
            writeFile file (T.unpack token)
            refused <-
                withFakeKoios (\_ _ -> respond 401 [] "rejected") $ \base _ -> do
                    k <- clientFor (fast base){httpTokenFile = Just file}
                    tip k
            port <- freePort
            unreachable <- do
                k <-
                    clientFor
                        (fast ("http://127.0.0.1:" <> T.pack (show port) <> "/api/v1"))
                            { httpTokenFile = Just file
                            }
                tip k
            timedOut <-
                withFakeKoios (\_ _ -> respondAfter 1.5 200 [] tipBody) $ \base _ -> do
                    k <-
                        clientFor (fast base){httpTokenFile = Just file, httpAttempts = 1}
                    tip k
            let failures = [refused, unreachable, timedOut]
            map (either (const True) (const False)) failures
                `shouldBe` [True, True, True]
            filter (T.isInfixOf token . T.pack . show) failures `shouldBe` []

-- | A server that echoes the bearer value back in a header and in the body.
echoing :: Int -> Seen -> Int -> IO Response
echoing code s _ =
    let bearer = fromMaybe "" (lookup "authorization" (seenHeaders s))
        bare = fromMaybe bearer (T.stripPrefix "Bearer " bearer)
    in  respond
            code
            ( [("x-echo", bearer)]
                <> [(bare, "named-after-the-token") | not (T.null bare)]
            )
            ("[{\"echo\": \"" <> TE.encodeUtf8 bearer <> "\"}]")

echoSpec :: Spec
echoSpec = describe "a server echoing the token" $
    it "gets it into no failure, refusal or answer the transport returns" $
        withSystemTempDirectory "koios-token" $ \dir -> do
            let file = dir </> "token"
            writeFile file (T.unpack token)
            results <- forM [200, 401, 503, 400] $ \code ->
                withFakeKoios (echoing code) $ \base logOf -> do
                    k <-
                        clientFor (fast base){httpTokenFile = Just file, httpAttempts = 1}
                    a <- show <$> tip k
                    b <- show <$> submitTx k "tx"
                    c <- show <$> txStatus k [txIdOfByte 1]
                    -- the raw answer itself, header names and values and body
                    transport <-
                        newHttpTransport
                            (fast base){httpTokenFile = Just file, httpAttempts = 1}
                            >>= either (fail . show) pure
                    d <- show <$> exchange transport (rawRequest tipRequest)
                    seen <- logOf
                    -- the server did receive the token, so the echo is real
                    map (lookup "authorization" . seenHeaders) seen
                        `shouldSatisfy` all (== Just ("Bearer " <> token))
                    pure [a, b, c, d]
            let shown = concat results
            length shown `shouldBe` 16
            -- in any byte and in any letter case: header names arrive lower-cased
            filter (T.isInfixOf (T.toLower token) . T.toLower . T.pack) shown
                `shouldBe` []
  where
    token = "Echoed-Token-5d1E"

{- | Generate the entire chosen bearer alphabet, independently of readToken.
Adversarial branches extend marker, header and JSON-literal substrings;
invalid JSON syntax and escapes belong to the refused domain below.
-}
genAcceptedToken :: QC.Gen Text
genAcceptedToken = do
    stem <- QC.elements ["", "token", "authorization", "nulltruefalse"]
    size <- QC.chooseInt (32, 128)
    headerSafe <- QC.elements [True, False]
    let alphabet =
            if headerSafe then filter (/= '/') bearerAlphabet else bearerAlphabet
    chars <- QC.vectorOf size (QC.elements alphabet)
    padding <- if headerSafe then pure 0 else QC.chooseInt (0, 3)
    pure (stem <> T.pack chars <> T.replicate padding "=")

bearerAlphabet :: String
bearerAlphabet = ['a' .. 'z'] <> ['A' .. 'Z'] <> ['0' .. '9'] <> "-._~+/"

genRefusedToken :: QC.Gen Text
genRefusedToken =
    QC.oneof
        [ do
            start <- QC.chooseInt (0, 6)
            size <- QC.chooseInt (1, 7 - start)
            pure (T.take size (T.drop start "<token>"))
        , do
            size <- QC.chooseInt (0, 31)
            T.pack <$> QC.vectorOf size (QC.elements bearerAlphabet)
        , do
            token <- genAcceptedToken
            syntax <-
                QC.elements
                    ["<token>", "\"", "\\", "{", "}", ":", "\n", "\r", "\t", "é", "=x"]
            pure (T.take 16 token <> syntax <> T.drop 16 token)
        ]

tokenDomainSpec :: Spec
tokenDomainSpec = describe "token domain and absence properties" $ do
    it "refuses 31 characters and accepts 32 without exposing them" $ do
        assertRefusedToken (T.replicate 31 "x")
        assertAcceptedTokenAbsent (T.replicate 32 "x")
    it "refuses every marker substring before any request" $
        forM_ markerSubstrings assertRefusedToken
    it
        "refuses arbitrary short, syntax, escape and non-bearer tokens before any request"
        $ QC.forAll
            genRefusedToken
            (QC.ioProperty . fmap (const True) . assertRefusedToken)
    it
        "clears every accepted token from answers, failures, probe rendering and fixture bytes"
        $ QC.checkCoverage
        $ QC.forAll genAcceptedToken
        $ \token ->
            QC.cover 10 ("token" `T.isPrefixOf` token) "marker extension"
                $ QC.cover
                    10
                    ("authorization" `T.isPrefixOf` token)
                    "header-name extension"
                $ QC.cover
                    10
                    ("nulltruefalse" `T.isPrefixOf` token)
                    "JSON-literal extension"
                $ QC.cover 10 ("=" `T.isSuffixOf` token) "bearer padding"
                $ QC.cover 10 ("/" `T.isInfixOf` token) "JSON slash"
                $ QC.cover
                    10
                    (T.all (`notElem` ("/=" :: String)) token)
                    "token-named HTTP header"
                $ QC.ioProperty (assertAcceptedTokenAbsent token >> pure True)
  where
    markerSubstrings =
        [ T.take size (T.drop start "<token>")
        | start <- [0 .. 6]
        , size <- [1 .. 7 - start]
        ]

assertRefusedToken :: Text -> IO ()
assertRefusedToken token =
    withSystemTempDirectory "koios-domain" $ \dir ->
        withFakeKoios (\_ _ -> respond 200 [] tipBody) $ \base logOf -> do
            let file = dir </> "credential"
            BS.writeFile file (TE.encodeUtf8 token)
            result <- newHttpTransport (fast base){httpTokenFile = Just file}
            case result of
                Left failure ->
                    T.pack (show failure) `shouldSatisfy` T.isPrefixOf "TokenFileInvalid "
                Right transport -> do
                    _ <- exchange transport (rawRequest tipRequest)
                    length <$> logOf `shouldReturn` 0
                    expectationFailure "a refused token reached the transport"
            length <$> logOf `shouldReturn` 0
            recorded <-
                recordFixtures
                    RecorderConfig
                        { recorderHttp = (fast base){httpTokenFile = Just file}
                        , recorderClient = ClientConfig 2 10
                        , recorderDirectory = dir </> "fixtures"
                        }
                    [TipOf]
            case recorded of
                Left failure ->
                    T.pack (show failure)
                        `shouldSatisfy` T.isPrefixOf "RecordTransport (TokenFileInvalid "
                Right _ -> expectationFailure "a refused token reached the recorder"
            length <$> logOf `shouldReturn` 0

assertAcceptedTokenAbsent :: Text -> IO ()
assertAcceptedTokenAbsent token =
    withSystemTempDirectory "koios-absence" $ \dir -> do
        let file = dir </> "credential"
            cfg base = (fast base){httpTokenFile = Just file, httpAttempts = 1}
        BS.writeFile file (TE.encodeUtf8 token)
        forM_ [200, 401, 503, 400] $ \code ->
            withFakeKoios (adversarialEcho code) $ \base logOf -> do
                transport <- transportFor (cfg base)
                ex <- exchange transport (rawRequest tipRequest)
                case exchangeResult ex of
                    Left none -> expectationFailure (show none)
                    Right a -> do
                        answerStatus a `shouldBe` code
                        assertAbsent token (answerBody a)
                        forM_ (answerHeaders a) $ \(name, value) -> do
                            assertAbsent (T.toLower token) (TE.encodeUtf8 name)
                            assertAbsent token (TE.encodeUtf8 value)
                let k = Koios (ClientConfig 2 10) transport
                rendered <-
                    sequence
                        [ show <$> tip k
                        , show <$> submitTx k "synthetic"
                        , show <$> probe k TipOf
                        ]
                -- These are the failure and result renderings the CLI prints.
                forM_
                    (show ex : rendered)
                    (assertAbsent token . TE.encodeUtf8 . T.pack)
                seen <- logOf
                length seen `shouldBe` 4
                map (lookup "authorization" . seenHeaders) seen
                    `shouldBe` replicate 4 (Just ("Bearer " <> token))
        withFakeKoios (adversarialEcho 200) $ \base logOf -> do
            files <-
                recordFixtures
                    RecorderConfig
                        { recorderHttp = cfg base
                        , recorderClient = ClientConfig 2 10
                        , recorderDirectory = dir </> "fixtures"
                        }
                    [TipOf]
                    >>= either (fail . show) pure
            length files `shouldBe` 1
            forM_ files $ \path -> BS.readFile path >>= assertAbsent token
            seen <- logOf
            length seen `shouldBe` 2
            map (lookup "authorization" . seenHeaders) seen
                `shouldBe` replicate 2 (Just ("Bearer " <> token))

{- | Echo raw and JSON-unicode-escaped credentials, in values and object keys.
A bearer containing '/' or '=' cannot name a legal HTTP header; those
still reach header values and every body channel.
-}
adversarialEcho :: Int -> Scene
adversarialEcho code s _ = do
    let bearer = fromMaybe "" (lookup "authorization" (seenHeaders s))
        bare = fromMaybe bearer (T.stripPrefix "Bearer " bearer)
        names = [(bare, bare) | T.all (`notElem` ("/=" :: String)) bare]
        body =
            "[{\"raw\":"
                <> BSL.toStrict (encode bare)
                <> ",\"escaped\":\""
                <> unicodeEscaped bare
                <> "\",\""
                <> unicodeEscaped bare
                <> "\":\"echo\"}]"
    if seenPath s == "/koiosapi.yaml"
        then
            respond
                200
                [("x-echo", bearer)]
                "openapi: 3.1.0\ninfo:\n  version: synthetic\n"
        else
            respond
                code
                ( [ ("x-echo", bearer)
                  , ("x-escaped", TE.decodeUtf8 (unicodeEscaped bare))
                  ]
                    <> names
                )
                ( if code == 401
                    then "denied " <> unicodeEscaped bare <> TE.encodeUtf8 bare
                    else body
                )

unicodeEscaped :: Text -> BS.ByteString
unicodeEscaped =
    TE.encodeUtf8
        . T.concatMap
            (\c -> "\\u" <> T.justifyRight 4 '0' (T.pack (showHex (ord c) "")))

{- | Inspect bytes as carried, plus JSON strings after decoding each layer.
This reaches unicode escapes in a body and JSON-escaped body in a fixture.
-}
assertAbsent :: Text -> BS.ByteString -> IO ()
assertAbsent token = inspect (3 :: Int)
  where
    inspect depth bytes = do
        let needles =
                [ TE.encodeUtf8 token
                , unicodeEscaped token
                , BS.drop
                    1
                    ( BS.dropEnd
                        1
                        (BSL.toStrict (encode (TE.decodeUtf8 (unicodeEscaped token))))
                    )
                ]
        forM_ needles $ \needle ->
            T.toLower (TE.decodeUtf8 needle)
                `T.isInfixOf` T.toLower (TE.decodeUtf8Lenient bytes)
                `shouldBe` False
        if depth <= 0
            then pure ()
            else case decodeStrict' bytes of
                Nothing -> pure ()
                Just value -> forM_ (strings value) (inspect (depth - 1) . TE.encodeUtf8)
    strings = \case
        String t -> [t]
        Object pairs -> concat [Key.toText k : strings v | (k, v) <- KeyMap.toList pairs]
        Array values -> foldMap strings values
        _ -> []

submitSpec :: Spec
submitSpec = describe "submission" $ do
    it "returns a 400's refusal text after exactly one attempt" $
        withFakeKoios (\_ _ -> respond 400 [] "BadInputsUTxO") $ \base logOf -> do
            k <- clientFor (fast base)
            submitTx k "tx" `shouldReturn` Right (SubmitRefused "BadInputsUTxO")
            countAt "/submittx" <$> logOf `shouldReturn` 1

    it "does not retry a 503 or a 429 at submission"
        $ withFakeKoios
            ( \_ n ->
                if n == 0 then respond 503 [] "busy" else respond 429 [] "slow"
            )
        $ \base logOf -> do
            k <- clientFor (fast base)
            reasonOf <$> submitTx k "tx"
                `shouldReturn` Just (1, ServerFailing 503 "busy")
            reasonOf <$> submitTx k "tx"
                `shouldReturn` Just (1, RateLimited Nothing)
            countAt "/submittx" <$> logOf `shouldReturn` 2

    it "retries a submission that timed out, within the bound" $
        withFakeKoios (\_ _ -> respondAfter 1.5 202 [] "\"aa\"") $ \base logOf -> do
            k <- clientFor (fast base)
            reasonOf <$> submitTx k "tx" `shouldReturn` Just (3, TimedOut)
            countAt "/submittx" <$> logOf `shouldReturn` 3

    it "posts the raw bytes as CBOR"
        $ withFakeKoios
            ( \_ _ ->
                respond 202 [] (BSL.toStrict (encode (T.replicate 64 "a")))
            )
        $ \base logOf -> do
            k <- clientFor (fast base)
            submitTx k "\x84\x01\x02"
                `shouldReturn` Right (SubmitAccepted (txIdOfByte 0xaa))
            seen <- logOf
            map seenBody seen `shouldBe` ["\x84\x01\x02"]
            map (lookup "content-type" . seenHeaders) seen
                `shouldBe` [Just "application/cbor"]

-- | The honest Koios page of the rows at the request's offset and limit.
pageResponse :: [Value] -> Seen -> IO Response
pageResponse rows s =
    case exchangeResult (pageAnswer rows (offsetIn s) (limitIn s)) of
        Right a -> respond 200 (answerHeaders a) (answerBody a)
        Left _ -> respond 500 [] ""

limitIn :: Seen -> Int
limitIn = maybe 0 (read . T.unpack) . lookup "limit" . seenQuery

offsetIn :: Seen -> Int
offsetIn = maybe 0 (read . T.unpack) . lookup "offset" . seenQuery

-- | A loopback port nothing listens on.
freePort :: IO Int
freePort = do
    info : _ <-
        getAddrInfo
            (Just defaultHints{addrFamily = AF_INET, addrSocketType = Stream})
            (Just "127.0.0.1")
            (Just "0")
    bracket (socket AF_INET Stream 0) close $ \sock -> do
        bind sock (addrAddress info)
        fromIntegral <$> socketPort sock
