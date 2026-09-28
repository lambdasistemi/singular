{- |
Module      : UpdateTerminal.Scenario
Description : The @update-terminal@ story, in the order it runs
License     : Apache-2.0

'updateTerminal' is the whole command below its outer failure handler.
In one node session it boots BOTH registries before any fold — a fold
returns its approval to the wallet, and a later boot would find no
ada-only output left to fund and collateralise from — then walks the
story (insert, retire), the Absent refusal in the story registry, and
the Unknown leg in the second registry; it writes the observation and
ends with the verdict the observation already states: the witness burned
from its holder and the committed leaf Terminal, or a named failure.
-}
module UpdateTerminal.Scenario (
    updateTerminal,
) where

import Data.ByteString.Short qualified as SBS
import Data.Text qualified as T

import Singular.Registry.Config (CageConfig (..))
import Singular.Registry.Ledger (Root (..))
import Singular.Registry.Node (withNode)
import Singular.Registry.Types (OnChainTokenState (..))
import UpdateTerminal.Controls (absentRefusal, unknownRefusal)
import UpdateTerminal.Narration (die, hex, say)
import UpdateTerminal.Observation (Observed (..), observation, writeObservation)
import UpdateTerminal.Options (StoryInputs (..), readStoryInputs)
import UpdateTerminal.Registry (
    Registry (..),
    bootRegistry,
    bootStateOf,
    openSession,
 )
import UpdateTerminal.Steps (
    Retirement (..),
    bootObservation,
    mintedActive,
    retireStoryKey,
 )

-- | Run the story; write the observation to the path when one is given.
updateTerminal :: Maybe FilePath -> IO ()
updateTerminal observedPath = do
    inputs <- readStoryInputs
    withNode $ \sess -> do
        session <- openSession sess inputs
        story <- bootRegistry session "story"
        unknownReg <- bootRegistry session "unknown-leg"
        let cfg = regCfg story
            openPolicy = hex (SBS.fromShort (cfgApplicationPolicy cfg))
            activePolicy = hex (SBS.fromShort (cfgActivePolicy cfg))
        say
            ( "open application policy "
                <> T.unpack openPolicy
                <> " (parameters: "
                <> show (inputOpenParams inputs)
                <> ")"
            )
        say ("active witness policy   " <> T.unpack activePolicy)
        bootState <- bootStateOf story

        r <- retireStoryKey story
        absentDetail <- absentRefusal story
        unknown <- unknownRefusal unknownReg

        writeObservation observedPath $
            observation
                Observed
                    { obsOpenPolicy = openPolicy
                    , obsOpenParams = inputOpenParams inputs
                    , obsActivePolicy = activePolicy
                    , obsRegistryToken = regTidBytes story
                    , obsMaxFee = stateMaxFee bootState
                    , obsBoot = bootObservation cfg (regBootTx story)
                    , obsMint = mintedActive (retRetireTx r) cfg
                    , obsRetirement = r
                    , obsAbsentDetail = absentDetail
                    , obsUnknown = unknown
                    }

        -- The exit code repeats what the observation already says, so a
        -- caller that does not read the JSON still fails on a broken run.
        let terminal = unRoot (retRootTerminal r)
        if retHeldBefore r == 1 && retHeldAfter r == 0 && retChainRoot r == terminal
            then say "OK — the witness was burned from its holder and the leaf is Terminal"
            else
                die
                    ( "the retirement did not complete: held "
                        <> show (retHeldBefore r)
                        <> " -> "
                        <> show (retHeldAfter r)
                        <> ", chain root "
                        <> T.unpack (hex (retChainRoot r))
                        <> " against the mirror's "
                        <> T.unpack (hex terminal)
                    )
