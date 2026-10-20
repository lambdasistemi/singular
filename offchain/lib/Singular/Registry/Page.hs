{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.Registry.Page
Description : The registry page: one value from explicit inputs, rendered as JSON
License     : Apache-2.0

The page says which registry this is, which release it runs, what its
rules are and what it holds now, from explicit inputs alone: the state
token, the release, the rules from the state datum and the replayed
facts. It reads no chain, file, clock, tip or session, so identical
inputs give identical bytes. Pending requests render in one fixed
order, by request output reference.

The page is printed as JSON, the one rendering. The provenance field states what
the page does not prove: the facts are state fields read from a replay
checked from create, the indexer's answers are unverified claims, the
release label is the archive's own claim, and the page is unsigned.
-}
module Singular.Registry.Page
    ( -- * Release
      ReleaseInfo (..)
    , ReleaseLinks (..)
    , releaseLinks
    , blueprintSha
    , parseVersionLabel
    , PageRefusal (..)
    , renderPageRefusal

      -- * Page
    , PageInputs (..)
    , Page
    , describeRegistry
    , renderPageJson
    ) where

import Crypto.Hash (Digest, SHA256, hash)
import Data.Aeson (Value (..), object, toJSON, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteArray (convert)
import Data.ByteString (ByteString)
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Lazy qualified as BL
import Data.Char (isDigit)
import Data.List qualified as List
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Text.Read (readMaybe)

-- ---------------------------------------------------------
-- Release
-- ---------------------------------------------------------

-- | The release the page names: the archive's own claims.
data ReleaseInfo = ReleaseInfo
    { releaseVersion :: Text
    -- ^ The label from @version.txt@ beside the blueprint
    , releaseBlueprintTitle :: Text
    -- ^ The blueprint preamble title
    , releaseBlueprintSha :: Text
    -- ^ Hex SHA-256 over the blueprint file bytes
    , releaseApplicationHash :: Text
    -- ^ The applied application script hash the registry runs
    }
    deriving stock (Eq, Show)

-- | Where the claimed version lives: never fetched, only computed.
data ReleaseLinks = ReleaseLinks
    { linkRelease :: Text
    -- ^ The GitHub release page for tag @v\<version\>@
    , linkDocs :: Text
    -- ^ The documentation asset of that release
    }
    deriving stock (Eq, Show)

-- | The links for a release label, computed and never fetched.
releaseLinks :: ReleaseInfo -> ReleaseLinks
releaseLinks info =
    ReleaseLinks
        { linkRelease =
            "https://github.com/lambdasistemi/singular/releases/tag/v"
                <> releaseVersion info
        , linkDocs =
            "https://github.com/lambdasistemi/singular/releases/download/v"
                <> releaseVersion info
                <> "/singular-docs-"
                <> releaseVersion info
                <> ".tar.gz"
        }

-- | Hex SHA-256 over blueprint file bytes.
blueprintSha :: ByteString -> Text
blueprintSha bytes = TE.decodeUtf8 (B16.encode (convert digest))
  where
    digest :: Digest SHA256
    digest = hash bytes

-- | Why no release label is printed.
data PageRefusal
    = -- | No @version.txt@ beside the blueprint
      VersionMissing
    | -- | @version.txt@ cannot be read; the detail says why
      VersionUnreadable Text
    | -- | @version.txt@ is not a version label; the detail shows it
      VersionMalformed Text
    deriving stock (Eq, Show)

-- | A refusal by name.
renderPageRefusal :: PageRefusal -> Text
renderPageRefusal = \case
    VersionMissing -> "version-missing: no version.txt beside the blueprint"
    VersionUnreadable why -> "version-unreadable: " <> why
    VersionMalformed raw -> "version-malformed: not a version label: " <> raw

-- | A version label to its stripped self, or why it is none.
parseVersionLabel :: Text -> Either PageRefusal Text
parseVersionLabel raw =
    let label = T.strip raw
    in  if T.null label
            || not (T.all (\c -> c == '.' || isDigit c) label)
            || T.head label == '.'
            || T.last label == '.'
            || ".." `T.isInfixOf` label
            then Left (VersionMalformed raw)
            else Right label

-- ---------------------------------------------------------
-- Page
-- ---------------------------------------------------------

-- | Every fact the page renders, supplied by the caller.
data PageInputs = PageInputs
    { pageStateToken :: Text
    -- ^ The registry, @POLICY.NAME@
    , pageStateOutput :: Text
    -- ^ The live state output holding the token
    , pageStateScript :: Text
    -- ^ The five script hashes the release derives, hex
    , pageApplicationScript :: Text
    , pageActiveScript :: Text
    , pageAbsentScript :: Text
    , pageTerminalScript :: Text
    , pageRelease :: ReleaseInfo
    , pageProcessTime :: Integer
    -- ^ The processing window in milliseconds, from the state datum
    , pageRetractTime :: Integer
    -- ^ The retract window in milliseconds, from the state datum
    , pageTip :: Integer
    -- ^ Lovelace per request, from the state datum
    , pageMaxKeyBytes :: Int
    -- ^ The longest key in bytes, the release's own limit
    , pageRoot :: Text
    -- ^ The replayed root, hex
    , pageActiveKeys :: Int
    -- ^ Keys whose replayed leaf is active
    , pageTerminalKeys :: Int
    -- ^ Keys whose replayed leaf is terminal
    , pageFoldsSinceCreate :: Int
    , pageCreateTransaction :: Text
    -- ^ The transaction that minted the state token, hex
    , pageLastFold :: Maybe Text
    -- ^ The last fold transaction, hex, absent when no fold ran
    , pagePendingRequests :: [Value]
    -- ^ The objects @inspect@ prints for pending requests, any order
    }
    deriving stock (Eq, Show)

-- | A page: its inputs with pending requests in one fixed order, and its links.
data Page = Page PageInputs ReleaseLinks
    deriving stock (Eq, Show)

-- | The page value for explicit inputs: total, sorting pending by request reference.
describeRegistry :: PageInputs -> Page
describeRegistry inputs =
    Page
        (inputs{pagePendingRequests = sortPending (pagePendingRequests inputs)})
        (releaseLinks (pageRelease inputs))

{- | Pending requests in one fixed order: by request output reference,
the transaction then the index, as the ledger orders outputs. Entries
without one sort by their bytes.
-}
sortPending :: [Value] -> [Value]
sortPending = List.sortOn pendingOrder

{- | What an entry sorts by: its request output reference, or its bytes
when it has none.
-}
pendingOrder :: Value -> (Text, Integer)
pendingOrder = \case
    Object o -> case KeyMap.lookup "request" o of
        Just (String ref) -> splitRef ref
        _ -> (encoded o, -1)
    v -> (encoded v, -1)
  where
    encoded w = TE.decodeUtf8 (BL.toStrict (Aeson.encode w))
    splitRef ref = case T.splitOn "#" ref of
        [txid, index] -> case readMaybe (T.unpack index) of
            Just n -> (txid, n)
            _ -> (ref, -1)
        _ -> (ref, -1)

-- | The JSON rendering: a receipt-shaped object with the page sections.
renderPageJson :: Page -> Value
renderPageJson (Page inputs links) =
    object
        [ "command" .= ("describe" :: Text)
        , "outcome" .= ("success" :: Text)
        , "registry"
            .= object
                [ "stateToken" .= pageStateToken inputs
                , "stateOutput" .= pageStateOutput inputs
                , "stateScript" .= pageStateScript inputs
                , "applicationScript" .= pageApplicationScript inputs
                , "activeScript" .= pageActiveScript inputs
                , "absentScript" .= pageAbsentScript inputs
                , "terminalScript" .= pageTerminalScript inputs
                ]
        , "release"
            .= object
                [ "version" .= releaseVersion (pageRelease inputs)
                , "blueprintTitle" .= releaseBlueprintTitle (pageRelease inputs)
                , "blueprintSha" .= releaseBlueprintSha (pageRelease inputs)
                , "applicationHash" .= releaseApplicationHash (pageRelease inputs)
                , "releaseUrl" .= linkRelease links
                , "docsUrl" .= linkDocs links
                ]
        , "rules"
            .= object
                [ "processTime" .= pageProcessTime inputs
                , "retractTime" .= pageRetractTime inputs
                , "tip" .= pageTip inputs
                , "maxKeyBytes" .= pageMaxKeyBytes inputs
                , "publicFold" .= publicFoldText
                ]
        , "state"
            .= object
                [ "root" .= pageRoot inputs
                , "activeKeys" .= pageActiveKeys inputs
                , "terminalKeys" .= pageTerminalKeys inputs
                , "foldsSinceCreate" .= pageFoldsSinceCreate inputs
                , "createTransaction" .= pageCreateTransaction inputs
                , "lastFold" .= maybe Aeson.Null toJSON (pageLastFold inputs)
                , "stateOutput" .= pageStateOutput inputs
                , "pendingRequests" .= toJSON (pagePendingRequests inputs)
                ]
        , "provenance" .= provenanceText
        ]

-- | Anyone may build a fold from the public view.
publicFoldText :: Text
publicFoldText =
    "anyone may build a fold from the public view (Singular.Statements.fold_inputs_public)"

{- | What the page does not prove, in fixed text: what was replayed, from
which provider, that its answers are unverified, and whose claims the
label and the page are.
-}
provenanceText :: Text
provenanceText =
    "the page shows the public history of the state token from create to the live \
    \state output, each fold's rebuilt root checked against the root recorded in that \
    \fold's state datum, and nothing beyond it. The history was read from Koios. \
    \The provider's answers are unverified: it supplies raw facts and untrusted \
    \reconstruction material, no ledger proofs and no anchor. The release label is \
    \the archive's own claim. The page is unsigned."
