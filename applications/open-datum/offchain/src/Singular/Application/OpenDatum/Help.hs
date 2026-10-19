{- |
Module      : Singular.Application.OpenDatum.Help
Description : The @open-datum@ program, declared once for its help and completion
License     : Apache-2.0

Every command of @open-datum@, what it does, which settings it takes and one
example for each command that writes. The overview, each command's help page,
the usage line a refusal shows and the shell completion are generated from
this declaration by "Singular.CLI.Options".
-}
module Singular.Application.OpenDatum.Help
    ( openDatumProgram
    ) where

import Data.Version (Version)

import Singular.CLI.Declared
import Singular.CLI.Options
    ( Flag (..)
    , Leaf (..)
    , Node (..)
    , Program (..)
    , Shape (..)
    , switch'
    , valued
    )

-- | The program, at the version it was built as.
openDatumProgram :: Version -> Program
openDatumProgram version =
    Program
        { programName = "open-datum"
        , programSummary =
            "Keep payloads under keys in a registry on Cardano: create the registry, \
            \insert, update and terminate keys, fold the pending requests, and read \
            \a key back."
        , programVersion = version
        , programNodes =
            [ createLeaf
            , insertLeaf
            , updateLeaf
            , terminateLeaf
            , foldLeaf
            , inspectLeaf
            ]
        , programFooter =
            [ ""
            , "Every command takes --trace, --trace-to and --trace-format to narrate"
            , "what it does; standard output carries the receipt alone."
            ]
        }

createLeaf :: Node
createLeaf =
    Runs
        Leaf
            { leafName = "create"
            , leafSummary = "Boot a registry, or preview its identity"
            , leafDescription =
                [ "Boots one registry from a seed output of your wallet and prints \
                  \its state token, which every other command names the registry \
                  \by. The processing window and the retract window are fixed here \
                  \for the life of the registry."
                , "With --closed the registry is a closed-datum registry whose \
                  \payload is written once; every later command follows the \
                  \registry's mode with no further flag, and an update on a closed \
                  \registry stops before anything is built or signed."
                , signerParagraph
                , previewParagraph
                ]
            , leafShape =
                Each
                    [ Takes closed
                    , Takes stateDir
                    , Needs blueprint
                    , Takes seed
                    , Takes processTime
                    , Takes retractTime
                    , nodeShape
                    , OneOf
                        [ writeShape
                        , Each [Needs preview, Needs previewAddress]
                        ]
                    , tracingShape
                    ]
            , leafWord = Nothing
            , leafEnvironment = [environmentLog, environmentState]
            , leafExamples =
                [ "open-datum create --blueprint plutus.json \\"
                , "    " <> preprodExample <> " \\"
                , "    --vault alice.vault"
                ]
            , leafNotes = exitStatuses
            }

insertLeaf :: Node
insertLeaf =
    Runs
        Leaf
            { leafName = "insert"
            , leafSummary = "Book a new key with its payload"
            , leafDescription =
                [ "Books one insertion of a key with its payload and a deposit and \
                  \stops: its request waits at the registry for the fold, which is \
                  \its own command, open-datum fold, run by whichever wallet folds \
                  \before the processing deadline the booking's receipt names. With \
                  \--fold the command also folds, once its booking confirms."
                , signerParagraph
                , previewParagraph
                ]
            , leafShape =
                Each
                    [ Takes stateDir
                    , Needs blueprint
                    , Needs stateToken
                    , keyShape
                    , Needs payload
                    , Takes deposit
                    , nodeShape
                    , OneOf
                        [ Each
                            [ writeShape
                            , spendingShape
                            , Takes foldAlso
                            ]
                        , Each
                            [ Needs preview
                            , Needs previewAddress
                            , spendingShape
                            ]
                        ]
                    , tracingShape
                    ]
            , leafWord = Nothing
            , leafEnvironment = [environmentLog, environmentState]
            , leafExamples =
                [ "open-datum insert --blueprint plutus.json \\"
                , "    --state-token <policy>.<name> --key my-key --payload payload.json \\"
                , "    " <> preprodExample <> " \\"
                , "    --vault alice.vault"
                ]
            , leafNotes = exitStatuses
            }

updateLeaf :: Node
updateLeaf =
    Runs
        Leaf
            { leafName = "update"
            , leafSummary = "Replace the payload of a key"
            , leafDescription =
                [ "Replaces only the payload of an active key; the protected control \
                  \stays as it was. On a closed registry it stops before anything is \
                  \built or signed, saying the registry is closed."
                , signerParagraph
                , previewParagraph
                ]
            , leafShape =
                Each
                    [ Takes stateDir
                    , Needs blueprint
                    , Needs stateToken
                    , keyShape
                    , Needs payload
                    , nodeShape
                    , OneOf
                        [ Each [writeShape, spendingShape]
                        , Each
                            [ Needs preview
                            , Needs previewAddress
                            , spendingShape
                            ]
                        ]
                    , tracingShape
                    ]
            , leafWord = Nothing
            , leafEnvironment = [environmentLog, environmentState]
            , leafExamples =
                [ "open-datum update --blueprint plutus.json \\"
                , "    --state-token <policy>.<name> --key my-key --payload payload.json \\"
                , "    " <> preprodExample <> " \\"
                , "    --vault alice.vault"
                ]
            , leafNotes = exitStatuses
            }

terminateLeaf :: Node
terminateLeaf =
    Runs
        Leaf
            { leafName = "terminate"
            , leafSummary = "Book the termination of a key"
            , leafDescription =
                [ "Books the termination of an active key and stops: its request \
                  \waits at the registry for the fold. With --fold the command also \
                  \folds, once its booking confirms, and the protected deposit is paid \
                  \back to the controller."
                , signerParagraph
                , previewParagraph
                ]
            , leafShape =
                Each
                    [ Takes stateDir
                    , Needs blueprint
                    , Needs stateToken
                    , keyShape
                    , nodeShape
                    , OneOf
                        [ Each
                            [ writeShape
                            , spendingShape
                            , Takes foldAlso
                            ]
                        , Each
                            [ Needs preview
                            , Needs previewAddress
                            , spendingShape
                            ]
                        ]
                    , tracingShape
                    ]
            , leafWord = Nothing
            , leafEnvironment = [environmentLog, environmentState]
            , leafExamples =
                [ "open-datum terminate --blueprint plutus.json \\"
                , "    --state-token <policy>.<name> --key my-key \\"
                , "    " <> preprodExample <> " \\"
                , "    --vault alice.vault"
                ]
            , leafNotes = exitStatuses
            }

foldLeaf :: Node
foldLeaf =
    Runs
        Leaf
            { leafName = "fold"
            , leafSummary = "Fold the pending requests into the registry"
            , leafDescription =
                [ "Folds the pending requests the registry can settle, up to the \
                  \capacity of one transaction, signed and funded by the wallet that \
                  \runs it, which need not be the wallet that booked them. It names \
                  \every request it leaves out. With --request, the command is \
                  \refused unless that request is among those folded."
                , signerParagraph
                ]
            , leafShape =
                Each
                    [ Takes stateDir
                    , Needs blueprint
                    , Needs stateToken
                    , nodeShape
                    , writeShape
                    , Takes foldRequest
                    , spendingShape
                    , tracingShape
                    ]
            , leafWord = Nothing
            , leafEnvironment = [environmentLog, environmentState]
            , leafExamples =
                [ "open-datum fold --blueprint plutus.json \\"
                , "    --state-token <policy>.<name> \\"
                , "    " <> preprodExample <> " \\"
                , "    --vault alice.vault"
                ]
            , leafNotes = exitStatuses
            }

inspectLeaf :: Node
inspectLeaf =
    Runs
        Leaf
            { leafName = "inspect"
            , leafSummary = "Read a key back, with its payload"
            , leafDescription =
                [ "Reads the registry and one key back from the chain: whether the \
                  \key is active or terminal, its holding, its envelope and payload, \
                  \the pending requests with what each actually locks, and the \
                  \registry's root. It reads only: it takes no signing key and \
                  \submits nothing."
                , "With --wallet-address it reconciles that wallet's managed journal \
                  \as a write would; without it the read is stateless and creates no \
                  \state."
                ]
            , leafShape =
                Each
                    [ Takes stateDir
                    , Needs blueprint
                    , Needs stateToken
                    , keyShape
                    , nodeShape
                    , Takes outputsAt
                    , Takes reconcileAddress
                    , Takes receipt
                    , tracingShape
                    ]
            , leafWord = Nothing
            , leafEnvironment = [environmentLog, environmentState]
            , leafExamples = []
            , leafNotes = exitStatuses
            }

-- ---------------------------------------------------------------------------
-- settings only this program reads

closed :: Flag
closed =
    switch'
        "--closed"
        "Boot a closed-datum registry whose payload is written once."

payload :: Flag
payload =
    valued
        "--payload"
        "FILE"
        "The key's payload, a datum in detailed-schema JSON."

deposit :: Flag
deposit =
    ( valued
        "--deposit"
        "LOVELACE"
        "The deposit the key's envelope protects, in whole lovelace; not below the minimum."
    )
        { flagDefault = Just "2000000, the minimum"
        }

foldAlso :: Flag
foldAlso =
    switch'
        "--fold"
        "Also fold pending requests, this one included, once the booking confirms."

foldRequest :: Flag
foldRequest =
    valued
        "--request"
        "TXID#IX"
        "Expect this pending request to be folded; refused if it is not among those settled."
