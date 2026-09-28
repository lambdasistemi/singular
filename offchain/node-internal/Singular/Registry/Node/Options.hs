{- |
Module      : Singular.Registry.Node.Options
Description : How a process decides which chain it runs against
License     : Apache-2.0

The one place a runner's node mode comes from: the command line and
the environment, read once per process.

Two modes:

* __devnet__ (the default, unchanged behaviour): spawn a private
  @cardano-node@ over the checked-in genesis, magic 42, and fund every
  actor from the genesis UTxO key.
* __external__ (@--node-socket@, @--network-magic@, @--wallet-skey@, or
  the @SINGULAR_NODE_SOCKET@, @SINGULAR_NETWORK_MAGIC@,
  @SINGULAR_WALLET_SKEY@ environment variables): connect to a node the
  joiner already runs and fund every actor from the joiner's own
  signing key.

This module owns no connection, wallet or follower state; the mode it
resolves is the input every other node module reads.
-}
module Singular.Registry.Node.Options
    ( -- * Mode
      NodeMode (..)
    , ExternalNode (..)
    , nodeModeFromArgs
    , nodeModeFromEnvironment
    , runMode
    , nodeIsExternal
    , echoKoios

      -- * Diagnostics
    , die
    , mainnetMagic
    ) where

import Control.Applicative ((<|>))
import Control.Exception
    ( ErrorCall (..)
    , SomeException
    , displayException
    , throwIO
    , try
    )
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.List (isPrefixOf)
import Data.Maybe (catMaybes)
import Data.Word (Word32)
import System.Directory (createDirectoryIfMissing)
import System.Environment (getArgs, getEnvironment)
import System.FilePath ((</>))
import System.IO.Unsafe (unsafePerformIO)
import System.Process (readProcess)
import Text.Read (readMaybe)

-- | A node the joiner already runs, with the key that funds the run.
data ExternalNode = ExternalNode
    { extSocket :: FilePath
    -- ^ Path of the node's node-to-client socket
    , extMagic :: Word32
    -- ^ Network magic the joiner asserts the node carries
    , extSkeyFile :: FilePath
    -- ^ Payment signing key file funding every actor
    }
    deriving (Eq, Show)

-- | How this process reaches a chain.
data NodeMode
    = -- | Spawn a private devnet and use its genesis key (the default)
      Devnet
    | -- | Connect to the joiner's node and use the joiner's key
      External ExternalNode
    deriving (Eq, Show)

-- | Mainnet's network magic — the one value external mode refuses.
mainnetMagic :: Word32
mainnetMagic = 764824073

{- | Resolve the mode from a command line and an environment.

Pure, so precedence and the partial-configuration diagnostic are
testable without a process: flags win over environment variables,
unknown arguments are ignored (runners take their own), and naming any
one of the three settings selects external mode and requires the other
two.
-}
nodeModeFromArgs
    :: [String]
    -> [(String, String)]
    -> Either String NodeMode
nodeModeFromArgs args env
    | null (catMaybes [mSock, mMagic, mSkey]) = Right Devnet
    | otherwise = do
        sock <- need "--node-socket" "SINGULAR_NODE_SOCKET" mSock
        magicS <- need "--network-magic" "SINGULAR_NETWORK_MAGIC" mMagic
        skey <- need "--wallet-skey" "SINGULAR_WALLET_SKEY" mSkey
        magic <- case readMaybe magicS of
            Just n -> Right n
            Nothing -> Left ("network magic is not a number: " <> magicS)
        if magic == mainnetMagic
            then
                Left
                    "external-node mode refuses network magic 764824073 \
                    \(mainnet): these runners submit live transactions and \
                    \are for test networks only"
            else
                Right . External $
                    ExternalNode
                        { extSocket = sock
                        , extMagic = magic
                        , extSkeyFile = skey
                        }
  where
    mSock = flag "--node-socket" `orElse` lookup "SINGULAR_NODE_SOCKET" env
    mMagic = flag "--network-magic" `orElse` lookup "SINGULAR_NETWORK_MAGIC" env
    mSkey = flag "--wallet-skey" `orElse` lookup "SINGULAR_WALLET_SKEY" env
    orElse a b = a <|> b
    need f e = maybe (Left (missing f e)) Right
    missing f e =
        "external-node mode is partially configured: "
            <> f
            <> " (or "
            <> e
            <> ") is missing. All three of --node-socket, --network-magic \
               \and --wallet-skey are required together; give none of them \
               \to run the factory devnet."
    flag name = go args
      where
        go (a : rest)
            | a == name = case rest of
                (v : _) -> Just v
                [] -> Nothing
            | (name <> "=") `isPrefixOf` a = Just (drop (length name + 1) a)
            | otherwise = go rest
        go [] = Nothing

-- | 'nodeModeFromArgs' applied to this process.
nodeModeFromEnvironment :: IO NodeMode
nodeModeFromEnvironment = do
    args <- getArgs
    env <- getEnvironment
    either die pure (nodeModeFromArgs args env)

{- | This process's mode, resolved once.

A process-level constant: it depends only on the command line and the
environment, both fixed for the lifetime of the process, so no ordering
between this and any other action can change what it reads.
-}
runMode :: NodeMode
runMode = unsafePerformIO nodeModeFromEnvironment
{-# NOINLINE runMode #-}

{- | Whether this process runs against an external (public) node.
Diagnostics that only make sense off the factory devnet gate on it.
-}
nodeIsExternal :: Bool
nodeIsExternal = case runMode of
    Devnet -> False
    External _ -> True

{- | Preprod diagnostic: POST the same transaction bytes to Koios's
public submittx endpoint and write its verbatim answer next to the
transaction's retained evidence. The node this process talks to
remains the only verdict; a Koios refusal, a transport error or a
missing curl is recorded and never raised. Devnet runs keep no Koios
echo — the factory devnet has no public endpoint.
-}
echoKoios :: FilePath -> String -> ByteString -> IO ()
echoKoios evDir tag raw = case runMode of
    Devnet -> pure ()
    External _ -> do
        let cborPath = evDir </> ("tx-" <> tag <> ".cbor")
            koiosPath = evDir </> ("tx-" <> tag <> ".koios.txt")
        createDirectoryIfMissing True evDir
        BS.writeFile cborPath raw
        r <-
            try
                ( readProcess
                    "curl"
                    [ "-sS"
                    , "--max-time"
                    , "30"
                    , "-X"
                    , "POST"
                    , "-H"
                    , "Content-Type: application/cbor"
                    , "--data-binary"
                    , "@" <> cborPath
                    , "https://preprod.koios.rest/api/v1/submittx"
                    ]
                    ""
                )
                :: IO (Either SomeException String)
        case r of
            Right body -> writeFile koiosPath body
            Left err -> writeFile koiosPath (displayException err)

-- | Fail with a named diagnostic, never a bare exception.
die :: String -> IO a
die = throwIO . ErrorCall
