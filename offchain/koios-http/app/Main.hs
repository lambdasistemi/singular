{-# LANGUAGE LambdaCase #-}

{- |
Module      : Main
Description : singular-koios — read-only Koios probe and fixture recorder
License     : Apache-2.0

@singular-koios probe@ runs read requests against a Koios URL and prints
the decoded facts of each, or the named failure. @singular-koios record@
runs the same requests and writes every raw answer they take — page by
page — as a fixture for the recorded transport. Neither can submit: a
request names a read call, and @submittx@ is not one.
-}
module Main (main) where

import Control.Monad (forM_, when, (>=>))
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as T
import Options.Applicative
import System.Exit (exitFailure)
import System.IO (stderr)

import Singular.Provider.Koios.Client
    ( ClientConfig (..)
    , Koios (..)
    , defaultClientConfig
    )
import Singular.Provider.Koios.Http
    ( HttpConfig (..)
    , defaultHttpConfig
    , newHttpTransport
    )
import Singular.Provider.Koios.Recorder
    ( ReadCall
    , ReadRequest
    , RecorderConfig (..)
    , parseReadRequest
    , probe
    , readCallName
    , recordFixtures
    )

data Command
    = Probe Common
    | Record Common FilePath

data Common = Common
    { commonUrl :: Text
    , commonTokenFile :: Maybe FilePath
    , commonPageSize :: Int
    , commonRequests :: [ReadRequest]
    }

main :: IO ()
main = do
    chosen <-
        execParser (info (commands <**> helper) (progDesc description))
    case chosen of
        Probe common -> do
            k <- client common
            failed <- newIORef False
            forM_ (commonRequests common) $
                probe k >=> \case
                    Right facts -> mapM_ T.putStrLn facts
                    Left failure -> do
                        T.hPutStrLn stderr (T.pack (show failure))
                        modifyIORef' failed (const True)
            readIORef failed >>= \f -> when f exitFailure
        Record common dir -> do
            written <-
                recordFixtures
                    RecorderConfig
                        { recorderHttp = http common
                        , recorderClient = clientConfig common
                        , recorderDirectory = dir
                        }
                    (commonRequests common)
            case written of
                Right files -> mapM_ putStrLn files
                Left failure -> do
                    T.hPutStrLn stderr (T.pack (show failure))
                    exitFailure
  where
    description =
        "Read-only Koios probe and fixture recorder. Read calls: "
            <> T.unpack
                ( T.intercalate
                    ", "
                    (map readCallName [minBound .. maxBound :: ReadCall])
                )

http :: Common -> HttpConfig
http common =
    (defaultHttpConfig (commonUrl common))
        { httpTokenFile = commonTokenFile common
        }

clientConfig :: Common -> ClientConfig
clientConfig common = defaultClientConfig{pageSize = commonPageSize common}

client :: Common -> IO (Koios IO)
client common =
    newHttpTransport (http common) >>= \case
        Right transport -> pure (Koios (clientConfig common) transport)
        Left failure -> do
            T.hPutStrLn stderr (T.pack (show failure))
            exitFailure

commands :: Parser Command
commands =
    hsubparser
        ( command
            "probe"
            ( info
                (Probe <$> commonOptions)
                (progDesc "Print the decoded facts of each read request")
            )
            <> command
                "record"
                ( info
                    ( Record
                        <$> commonOptions
                        <*> strOption (long "out" <> metavar "DIR" <> help "Fixture directory")
                    )
                    (progDesc "Record every answer the read requests take as fixtures")
                )
        )

commonOptions :: Parser Common
commonOptions =
    Common
        <$> strOption
            ( long "koios-url"
                <> metavar "URL"
                <> help "Koios base URL, such as https://preprod.koios.rest/api/v1"
            )
        <*> optional
            ( strOption
                ( long "koios-token-file"
                    <> metavar "FILE"
                    <> help "File holding a bearer token"
                )
            )
        <*> option
            auto
            ( long "page-size"
                <> metavar "ROWS"
                <> value 1000
                <> showDefault
                <> help "Rows per page"
            )
        <*> some
            ( argument
                ( eitherReader
                    (either (Left . T.unpack) Right . parseReadRequest . T.pack)
                )
                (metavar "REQUEST..." <> help "<call>[:<argument>[,<argument>]]")
            )
