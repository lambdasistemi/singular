{- |
Module      : InsertActive.Scenario
Description : The @insert-active@ story, in the order it runs
License     : Apache-2.0

'insertActive' is the whole command below its outer failure handler:
read the blueprint, open one node session, boot, book and fold the
story's key, read the wallet, run the accepting control and then the
duplicate refusal, write the observation, and end with the verdict the
observation already states — exactly one active token at the named
wallet, or a named failure.
-}
module InsertActive.Scenario (
    insertActive,
) where

import Data.ByteString.Short qualified as SBS
import Data.Text qualified as T

import InsertActive.Controls (duplicateRefusal, freshKeyControl)
import InsertActive.Narration (die, hex, say)
import InsertActive.Observation (Observed (..), observation, writeObservation)
import InsertActive.Options (StoryInputs (..), readStoryInputs)
import InsertActive.Steps (
    Story (..),
    activeHeldAt,
    book,
    bootStory,
    foldOnce,
    storyKey,
    txIdOf,
 )
import Singular.Registry.Config (CageConfig (..))
import Singular.Registry.Node (withNode)
import Singular.Registry.Types (OnChainTokenState (..))

-- | Run the story; write the observation to the path when one is given.
insertActive :: Maybe FilePath -> IO ()
insertActive observedPath = do
    inputs <- readStoryInputs
    withNode $ \sess -> do
        story <- bootStory sess inputs
        let cfg = storyConfig story

        book story storyKey
        foldTx <- foldOnce story storyKey
        let foldTxid = hex (txIdOf foldTx)
        say ("folded insertActive tx=" <> T.unpack foldTxid)

        held <- activeHeldAt story storyKey
        say ("active tokens at the named wallet: " <> show held)

        controlTxid <- freshKeyControl story
        dupRefusal <- duplicateRefusal story

        writeObservation observedPath $
            observation
                Observed
                    { obsOpenPolicy = hex (SBS.fromShort (cfgApplicationPolicy cfg))
                    , obsOpenParams = inputOpenParams inputs
                    , obsActivePolicy = hex (SBS.fromShort (cfgActivePolicy cfg))
                    , obsRegistryToken = hex (storyTokenBytes story)
                    , obsMaxFee = stateMaxFee (storyBootState story)
                    , obsFoldTxid = foldTxid
                    , obsHeld = held
                    , obsDuplicateRefusal = dupRefusal
                    , obsControlTxid = controlTxid
                    }
        if held == 1
            then say "OK — one active token at the named wallet, duplicate refused"
            else
                die
                    ( "the named wallet holds "
                        <> show held
                        <> " active tokens for this key, not exactly one"
                    )
