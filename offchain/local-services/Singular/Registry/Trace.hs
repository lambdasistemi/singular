{- |
Module      : Singular.Registry.Trace
Description : The typed events a command's reads report: views, queries, evaluations, waits and body builds
License     : Apache-2.0

The mechanics below the protocol, in the vocabulary of the provider and the
local services: a view opened and released, a query answered or failed, a
script evaluation and its units, a horizon wait, a validity selection, a
transaction body built. Each is one typed value; how it is shown (indented
narration, a JSON line, the @SINGULAR_LOG@ phase log) is a renderer at the
command's entry point, never decided here.

No event carries key material, a credential or the text of an error. A
failure carries the type of what was thrown ('ErrorClass'), as the phase log
always has, and nothing an error message could embed.
-}
module Singular.Registry.Trace
    ( -- * Events
      ReadEvent (..)
    , BackendEvent (..)
    , Query (..)
    , QueryEnd (..)
    , ViewOpening (..)
    , ViewRelease (..)
    , Evaluation (..)
    , HorizonWait (..)
    , HorizonEnd (..)
    , ValiditySelection (..)
    , BodyBuild (..)
    , BodyEnd (..)

      -- * Failures
    , ErrorClass (..)
    ) where

import Data.Data (Data)
import Data.Text (Text)
import Data.Word (Word64)

{- | The type of what an operation threw, as @show (typeOf e)@ names it: never
its message.
-}
newtype ErrorClass = ErrorClass Text
    deriving stock (Eq, Show, Data)

-- | One event of the reads a command makes.
data ReadEvent
    = -- | One read through a view or a session
      Queried Query
    | -- | A view or session acquired
      ViewOpened ViewOpening
    | -- | A view or session given back
      ViewReleased ViewRelease
    | -- | One local script evaluation, summed over its redeemers
      Evaluated Evaluation
    | -- | A node session opened, in milliseconds
      SessionOpened Double
    | -- | A bounded wait for the conversion horizon to move
      HorizonWaited HorizonWait
    | -- | The validity interval a build selected
      ValiditySelected ValiditySelection
    | -- | One transaction body built by a builder
      BodyBuilt BodyBuild
    deriving stock (Eq, Show, Data)

{- | One step of a backend's own mechanics, below the provider boundary: an
exchange with its service, a session or view it holds. These carry no protocol
context, and never a credential or a raw body.
-}
data BackendEvent
    = -- | One exchange: an HTTP call, a node query
      Exchanged Query
    | BackendViewOpened ViewOpening
    | BackendViewReleased ViewRelease
    deriving stock (Eq, Show, Data)

-- | A read: its name, the session it ran in, how long it took and its end.
data Query = Query
    { queryName :: Text
    , querySource :: Text
    -- ^ What answered it: a backend (@Koios@, @node@) or the local services
    , querySession :: Maybe Text
    , queryElapsed :: Double
    -- ^ Milliseconds
    , queryEnd :: QueryEnd
    }
    deriving stock (Eq, Show, Data)

-- | How a read ended.
data QueryEnd
    = -- | Answered, with the size of the answer where it is counted
      Answered (Maybe Int)
    | -- | The index had not yet reached the view's point
      Lagged
    | -- | It threw
      QueryFailed ErrorClass
    deriving stock (Eq, Show, Data)

-- | A view acquired.
data ViewOpening
    = -- | A node view at its chain point, after this many milliseconds
      NodeViewOpened
        { openedElapsed :: Double
        , openedSlot :: Word64
        , openedHash :: Text
        -- ^ Base16
        , openedEra :: Text
        }
    | -- | A node view that could not be acquired
      NodeViewFailed Double ErrorClass
    | -- | A provider session opened, and how it is bound to the chain
      SessionViewOpened
        { openedSession :: Text
        , openedBinding :: Text
        }
    deriving stock (Eq, Show, Data)

-- | A view given back.
data ViewRelease
    = -- | A node view, held this many milliseconds
      NodeViewHeld Double
    | -- | A provider session closed
      SessionViewClosed Text
    deriving stock (Eq, Show, Data)

-- | One evaluation: redeemers evaluated, failed, and the units of those that ran.
data Evaluation = Evaluation
    { evalRedeemers :: Int
    , evalFailed :: Int
    , evalMemory :: Integer
    , evalSteps :: Integer
    }
    deriving stock (Eq, Show, Data)

-- | A bounded wait for the horizon past which slots convert.
data HorizonWait = HorizonWait
    { waitTip :: Word64
    , waitHorizon :: Word64
    , waitLower :: Maybe Word64
    , waitWindowUpper :: Word64
    , waitMinimumSlots :: Integer
    , waitSlotLimit :: Integer
    , waitWallLimitMs :: Integer
    , waitElapsed :: Double
    , waitEnd :: HorizonEnd
    }
    deriving stock (Eq, Show, Data)

-- | How a horizon wait ended.
data HorizonEnd
    = -- | The horizon moved: the tip and horizon observed then
      HorizonMoved Word64 Word64
    | HorizonFailed ErrorClass
    deriving stock (Eq, Show, Data)

-- | The validity interval a build selected under the observed horizon.
data ValiditySelection = ValiditySelection
    { selectedTip :: Word64
    , selectedHorizon :: Word64
    , selectedLower :: Maybe Word64
    , selectedEffectiveLower :: Integer
    , selectedWindowUpper :: Word64
    , selectedUpper :: Word64
    , selectedMinimumSlots :: Integer
    }
    deriving stock (Eq, Show, Data)

-- | One body built by a named builder.
data BodyBuild = BodyBuild
    { bodyBuilder :: Text
    , bodyElapsed :: Double
    , bodyEnd :: BodyEnd
    }
    deriving stock (Eq, Show, Data)

-- | How a body build ended.
data BodyEnd
    = BodyReady
    | -- | The builder refused, naming no text
      BodyRefused
    | BodyFailed ErrorClass
    deriving stock (Eq, Show, Data)
