{- |
Module      : Naming.CLI.Options
Description : Explicit registry selection and action parsing
License     : Apache-2.0

Parsing performs no IO. Help never reads keys, opens a node connection or
selects a registry on the user's behalf.
-}
module Naming.CLI.Options (
    Connection (..),
    Command (..),
    Options (..),
    parserInfo,
) where

import Data.Word (Word32)
import Options.Applicative (
    Parser,
    ParserInfo,
    ReadM,
    command,
    eitherReader,
    fullDesc,
    header,
    help,
    helper,
    hsubparser,
    info,
    long,
    metavar,
    option,
    progDesc,
    strOption,
    (<**>),
 )
import Text.Read (readMaybe)

-- | The deployment and node selected explicitly by the user.
data Connection = Connection
    { deploymentFile :: FilePath
    , nodeSocket :: FilePath
    , networkMagic :: Word32
    }
    deriving stock (Eq, Show)

-- | One action performed by one invocation.
data Command = Attach | Inspect String
    deriving stock (Eq, Show)

-- | Parsed connection and action. No implicit defaults select a network.
data Options = Options
    { connection :: Connection
    , command :: Command
    }
    deriving stock (Eq, Show)

-- | Help and options for the public executable and parser tests.
parserInfo :: ParserInfo Options
parserInfo =
    info (options <**> helper) $
        fullDesc
            <> header "singular-naming — manage a selected naming registry"
            <> progDesc "Use an existing deployment; no implicit registry creation"
  where
    options = Options <$> connectionParser <*> actionParser

connectionParser :: Parser Connection
connectionParser =
    Connection
        <$> strOption (long "deployment" <> metavar "FILE" <> help "Deployment manifest")
        <*> strOption (long "node-socket" <> metavar "SOCKET" <> help "Existing node-to-client socket")
        <*> option magicReader (long "network-magic" <> metavar "N" <> help "Network magic negotiated with the node")

magicReader :: ReadM Word32
magicReader = eitherReader $ \raw ->
    case readMaybe raw :: Maybe Integer of
        Just n | n >= 0 && n <= toInteger (maxBound :: Word32) -> Right (fromInteger n)
        _ -> Left "network magic must be an integer from 0 to 4294967295"

actionParser :: Parser Command
actionParser =
    hsubparser $
        Options.Applicative.command
            "attach"
            (info (pure Attach <**> helper) (progDesc "Verify the selected deployment without submitting a transaction"))
            <> Options.Applicative.command
                "inspect"
                ( info
                    (Inspect <$> option nameReader (long "name" <> metavar "NAME" <> help "Exact name spelling (UTF-8, no normalization)") <**> helper)
                    (progDesc "Inspect a name against the authenticated registry state")
                )
  where
    nameReader = eitherReader $ \name ->
        if null name then Left "name must not be empty" else Right name
