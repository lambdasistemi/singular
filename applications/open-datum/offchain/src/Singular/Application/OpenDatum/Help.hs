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
    ( blueprint
    , environmentLog
    , environmentPassphrase
    , environmentState
    , exitStatuses
    , holding
    , keyShape
    , nodeShape
    , payloadSchema
    , preprodExample
    , preprodUrlExample
    , processTime
    , registryNodeShape
    , registryShape
    , seed
    , signerParagraph
    , stateDir
    , tracingShape
    , writeShape
    )
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
            "Keep payloads under keys in a registry on Cardano: create a registry, \
            \book registrations, update and terminate holdings, fold pending requests and inspect keys."
        , programVersion = version
        , programNodes =
            [ stateCreateLeaf
            , stateFoldLeaf
            , bookLeaf
            , reclaimLeaf
            , cleanupLeaf
            , holdingLeaf False
            , holdingLeaf True
            , inspectLeaf
            ]
        , programFooter =
            [ ""
            , "Every command takes --trace, --trace-to and --trace-format to narrate"
            , "what it does; standard output carries only the command's result."
            ]
        }

-- ---------------------------------------------------------------------------
-- state

holdingLeaf :: Bool -> Node
holdingLeaf terminating =
    Runs
        Leaf
            { leafName = if terminating then "terminate" else "update"
            , leafSummary =
                if terminating
                    then "Book permanent termination of a live holding"
                    else "Replace the payload of a live holding"
            , leafDescription =
                [ if terminating
                    then
                        "Spends the chosen holding, donates exactly its protected deposit to the treasury, and creates a datumless request holding the active token and one termination approval. The active token remains until fold burns both tokens. The folder receives the whole request value; its wallet may be different from the controller's. This booking is permanent and has no reclaim window."
                    else
                        "Spends the chosen holding and recreates it at the same address with the new payload, the same protected control and the complete token value, keeping at least its protected deposit. No registry state is spent. Only the controller can sign this update."
                , "The named registry must be the registry in the holding's protected control. The signing wallet must control the holding; a missing holding or another controller is refused before signing."
                , "An interrupted send keeps its transaction identity in the journal. The next write checks that transaction on the chain and refuses while it remains unresolved. No command resubmits it automatically."
                , signerParagraph
                ]
            , leafShape =
                Each
                    ( [Takes stateDir, Needs blueprint, registryShape, Needs holding]
                        <> (if terminating then [] else [Needs payload, Takes payloadSchema])
                        <> [registryNodeShape, writeShape, tracingShape]
                    )
            , leafWord = Nothing
            , leafEnvironment =
                [environmentLog, environmentState, environmentPassphrase]
            , leafExamples =
                [ "open-datum "
                    <> (if terminating then "terminate" else "update")
                    <> " --blueprint plutus.json \\"
                , "    --state-token POLICY.NAME --holding TXID#IX \\"
                , "    " <> preprodExample <> " \\"
                , "    --vault alice.vault"
                    <> (if terminating then "" else " --payload new.json")
                ]
            , leafNotes = exitStatuses
            }

stateCreateLeaf :: Node
stateCreateLeaf =
    Runs
        Leaf
            { leafName = "create"
            , leafSummary = "Create a registry"
            , leafDescription =
                [ "Creates one registry by spending a seed output of your wallet and \
                  \prints its address, its state token and the transactions it sent. \
                  \The registry's five parameters are fixed here for its life: the \
                  \processing time and the reclaim time of a booked registration, the \
                  \width of a booking's validity interval, and the registration cost \
                  \and the minimum tip, which are carried and enforce nothing. The \
                  \first registry of open datum publishes the state validator and the \
                  \request validator as reference scripts, each in its own transaction, \
                  \waiting for both before creating the registry. A rerun publishes \
                  \only what is missing; a later registry finds the live copies and sends one \
                  \transaction."
                , signerParagraph
                ]
            , leafShape =
                Each
                    [ Takes stateDir
                    , Needs blueprint
                    , Takes seed
                    , Takes processTime
                    , Takes reclaimTime
                    , Takes bookingWidth
                    , Takes registrationCost
                    , Takes minimumTip
                    , nodeShape
                    , writeShape
                    , tracingShape
                    ]
            , leafWord = Nothing
            , leafEnvironment =
                [environmentLog, environmentState, environmentPassphrase]
            , leafExamples =
                [ "open-datum create --blueprint plutus.json \\"
                , "    " <> preprodExample <> " \\"
                , "    --vault alice.vault"
                ]
            , leafNotes = exitStatuses
            }

stateFoldLeaf :: Node
stateFoldLeaf =
    Runs
        Leaf
            { leafName = "fold"
            , leafSummary =
                "Fold requests found from public approvals"
            , leafDescription =
                [ "Finds pending registrations and terminations from the application's public approval holders. Requests are ordered by the folder's take, greatest first, with output references breaking ties. Individually unfoldable requests are skipped with reasons: an already registered key, an inactive termination key, a deposit below the holding's minimum or a closed processing window. The first foldable request for each key is kept; later ones are skipped as duplicates."
                , "The greatest prefix of foldable requests fitting transaction size, memory and steps is built; --limit caps its request count. Skipped requests are never counted as left. If none can fold, the command refuses with nothing to fold and still lists the skipped requests. Failed reads and other construction failures stop the fold with their own reason."
                , "A registration keeps its committed holding and deposit; its remaining value is the folder's. A termination burns its approval and active token and pays its whole held value to the folder. The folder pays the transaction fee. The receipt lists folded keys, kinds and pending references, skipped holders with reasons, and how many requests remain."
                , "Repeat --pending to name an explicit batch in its given order. It is built whole or refused, even with --limit. The transaction is built from public chain data and signed by the wallet running the command; no controller file, key or local record is needed."
                , signerParagraph
                ]
            , leafShape =
                Each
                    [ Takes stateDir
                    , Needs blueprint
                    , registryShape
                    , Takes foldPending
                    , Takes batchLimit
                    , registryNodeShape
                    , writeShape
                    , tracingShape
                    ]
            , leafWord = Nothing
            , leafEnvironment =
                [environmentLog, environmentState, environmentPassphrase]
            , leafExamples =
                [ "open-datum fold --blueprint plutus.json \\"
                , "    --registry <address> --pending <txid>#<ix> \\"
                , "    " <> preprodUrlExample <> " \\"
                , "    --vault bob.vault"
                ]
            , leafNotes = exitStatuses
            }

bookLeaf :: Node
bookLeaf =
    Runs
        Leaf
            { leafName = "insert"
            , leafSummary = "Book the registration of a key"
            , leafDescription =
                [ "Books the registration of a key with its payload and a deposit: \
                  \a pending registration holding its approval is put at the \
                  \request address, its deadlines fixed by the registry's \
                  \configuration. The receipt names the pending registration and the \
                  \times of its phases. Whoever folds it, or you reclaiming it, names \
                  \it with --pending. A key the registry already holds as \
                  \registered, or as terminated, is refused before anything is \
                  \signed."
                , signerParagraph
                ]
            , leafShape =
                Each
                    [ Takes stateDir
                    , Needs blueprint
                    , registryShape
                    , keyShape
                    , Needs payload
                    , Takes payloadSchema
                    , Takes deposit
                    , Takes tip
                    , Takes refundAddress
                    , registryNodeShape
                    , writeShape
                    , tracingShape
                    ]
            , leafWord = Nothing
            , leafEnvironment =
                [environmentLog, environmentState, environmentPassphrase]
            , leafExamples =
                [ "open-datum insert --blueprint plutus.json \\"
                , "    --registry <address> --key my-key --payload payload.json \\"
                , "    " <> preprodUrlExample <> " \\"
                , "    --vault alice.vault"
                ]
            , leafNotes = exitStatuses
            }

reclaimLeaf :: Node
reclaimLeaf =
    Runs
        Leaf
            { leafName = "reclaim"
            , leafSummary = "Take back a registration you booked"
            , leafDescription =
                [ "Takes the named pending registration back inside its reclaim \
                  \window: everything it holds returns to its refund address, which \
                  \must be the wallet that runs the command, and its approval is \
                  \burned. Before the window opens or after it closes the command is \
                  \refused, saying when."
                , signerParagraph
                ]
            , leafShape =
                Each
                    [ Takes stateDir
                    , Needs blueprint
                    , registryShape
                    , Needs pending
                    , registryNodeShape
                    , writeShape
                    , tracingShape
                    ]
            , leafWord = Nothing
            , leafEnvironment =
                [environmentLog, environmentState, environmentPassphrase]
            , leafExamples =
                [ "open-datum reclaim --blueprint plutus.json \\"
                , "    --registry <address> --pending <txid>#<ix> \\"
                , "    " <> preprodUrlExample <> " \\"
                , "    --vault alice.vault"
                ]
            , leafNotes = exitStatuses
            }

cleanupLeaf :: Node
cleanupLeaf =
    Runs
        Leaf
            { leafName = "cleanup"
            , leafSummary = "Clean up an expired registration"
            , leafDescription =
                [ "Cleans up the named pending registration once its reclaim window \
                  \has ended: its deposit returns to its refund address, the wallet \
                  \that runs the command keeps what the request holds above the \
                  \deposit, and the approval is burned. Anyone may run it."
                , signerParagraph
                ]
            , leafShape =
                Each
                    [ Takes stateDir
                    , Needs blueprint
                    , registryShape
                    , Needs pending
                    , registryNodeShape
                    , writeShape
                    , tracingShape
                    ]
            , leafWord = Nothing
            , leafEnvironment =
                [environmentLog, environmentState, environmentPassphrase]
            , leafExamples =
                [ "open-datum cleanup --blueprint plutus.json \\"
                , "    --registry <address> --pending <txid>#<ix> \\"
                , "    " <> preprodUrlExample <> " \\"
                , "    --vault bob.vault"
                ]
            , leafNotes = exitStatuses
            }

payload :: Flag
payload =
    valued
        "--payload"
        "FILE"
        "The key's payload: a JSON file, stored as plain JSON unless --payload-schema says otherwise."

deposit :: Flag
deposit =
    ( valued
        "--deposit"
        "LOVELACE"
        "The deposit the key's envelope protects, in whole lovelace; not below the minimum."
    )
        { flagDefault = Just "2000000, the minimum"
        }

pending :: Flag
pending =
    valued
        "--pending"
        "TXID#IX"
        "The pending request to act on, as the booking printed it; none is chosen for you."

foldPending :: Flag
foldPending =
    valued
        "--pending"
        "TXID#IX"
        "An explicit request to fold; repeat for the whole named batch. Omit it to discover public requests."

batchLimit :: Flag
batchLimit =
    valued
        "--limit"
        "N"
        "At most N requests from automatic discovery. Omit it to try the whole pending set; an explicit batch is never trimmed."

reclaimTime :: Flag
reclaimTime =
    ( valued
        "--reclaim-time"
        "MS"
        "How long the refund address may reclaim a registration after its processing deadline, in milliseconds; fixed for the life of the registry."
    )
        { flagDefault = Just "300000, five minutes"
        }

bookingWidth :: Flag
bookingWidth =
    ( valued
        "--booking-width"
        "MS"
        "The widest validity interval a booking may declare, in milliseconds; fixed for the life of the registry."
    )
        { flagDefault = Just "300000, five minutes"
        }

registrationCost :: Flag
registrationCost =
    ( valued
        "--registration-cost"
        "LOVELACE"
        "The registration cost the registry carries; it enforces nothing; fixed for the life of the registry."
    )
        { flagDefault = Just "0"
        }

minimumTip :: Flag
minimumTip =
    ( valued
        "--minimum-tip"
        "LOVELACE"
        "The minimum tip the registry carries; it enforces nothing; fixed for the life of the registry."
    )
        { flagDefault = Just "0"
        }

tip :: Flag
tip =
    ( valued
        "--tip"
        "LOVELACE"
        "What the request holds above the deposit for the wallet that folds it, in whole lovelace."
    )
        { flagDefault = Just "0"
        }

refundAddress :: Flag
refundAddress =
    ( valued
        "--refund-address"
        "ADDR"
        "Where a reclaim or a cleanup returns the value: a bech32 address."
    )
        { flagDefault = Just "your own address"
        }

inspectLeaf :: Node
inspectLeaf =
    Runs
        Leaf
            { leafName = "inspect"
            , leafSummary =
                "Read a key's holding, termination or authenticated absence"
            , leafDescription =
                [ "Reads the registry address and a key without a signer, blueprint or local state. The neutral reader identifies the application and active custody; open datum refines active into a live holding with its control, protected deposit and payload, or pending termination. Terminal, never registered, unavailable and every neutral refusal retain their meanings."
                , "Active custody needs one asset lookup. With no active token the reader authenticates the state and replays its public history to read the key's leaf. An empty or failed read never proves absence."
                ]
            , leafShape =
                Each
                    [ registryShape
                    , keyShape
                    , registryNodeShape
                    , Takes
                        (switch' "--json" "Print the answer as JSON instead of human text.")
                    , Takes
                        ( switch'
                            "--query-work"
                            "Report provider calls, rows and bytes per read and in total."
                        )
                    , tracingShape
                    ]
            , leafWord = Nothing
            , leafEnvironment = [environmentLog]
            , leafExamples =
                [ "open-datum inspect --registry <address> --key my-key --koios-url https://preprod.koios.rest/api/v1"
                ]
            , leafNotes =
                [ "Human text by default; --json prints one object. Exit 0: an answer (live, pending termination, terminal or never registered). Exit 1: unavailable read. Exit 2: refused evidence or invalid command line. See docs/singular-node.md#reading-a-key."
                ]
            }
