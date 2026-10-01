{- |
Module      : Conformance.EvidencePage
Description : The published evidence page, computed from receipts
License     : Apache-2.0

Not rendered yet: the types the page is computed from, and a renderer
that refuses every snapshot.
-}
module Conformance.EvidencePage
    ( -- * Snapshot
      Snapshot (..)
    , Source (..)
    , ContractResult (..)
    , ContractEvidence (..)
    , ContractOutcome (..)

      -- * Rendering
    , RenderedPage (..)
    , renderEvidencePage
    ) where

import Data.Aeson (FromJSON (..))
import Data.ByteString.Lazy qualified as BSL
import Data.Text (Text)

import Conformance.Receipt (Receipt)
import Conformance.Rows (Row)

data Source = Source
    { sourceWorkflow :: !Text
    , sourceRun :: !Text
    , sourceArtifact :: !Text
    }
    deriving stock (Show, Eq)

data ContractEvidence = ContractTestAdapter | ContractDevNet
    deriving stock (Show, Eq, Ord)

data ContractOutcome
    = ContractPassed
    | ContractFailed !Text
    | ContractNotSupported !Text
    deriving stock (Show, Eq)

data ContractResult = ContractResult
    { crBase :: !Text
    , crDirty :: !Bool
    , crAdapter :: !Text
    , crEvidence :: !ContractEvidence
    , crCase :: !Text
    , crKind :: !Text
    , crRequirement :: !Text
    , crOutcome :: !ContractOutcome
    }
    deriving stock (Show, Eq)

instance FromJSON ContractResult where
    parseJSON _ = fail "contract results are not read yet"

data Snapshot = Snapshot
    { snapBase :: !Text
    , snapSources :: ![Source]
    , snapReceipts :: ![Receipt]
    , snapReceiptFiles :: ![FilePath]
    , snapContract :: ![ContractResult]
    , snapContractFiles :: ![FilePath]
    }
    deriving stock (Show, Eq)

data RenderedPage = RenderedPage
    { renderedPage :: !Text
    , renderedSpeech :: !BSL.ByteString
    }

renderEvidencePage
    :: Text -> [Row] -> Snapshot -> Either String RenderedPage
renderEvidencePage _ _ _ = Left "the evidence page is not rendered yet"
