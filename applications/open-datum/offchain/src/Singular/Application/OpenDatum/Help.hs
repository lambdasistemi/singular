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
            , stateGroup
            , registrationGroup
            , holdingGroup
            ]
        , programFooter =
            [ ""
            , "Every command takes --trace, --trace-to and --trace-format to narrate"
            , "what it does; standard output carries the receipt alone."
            ]
        }

-- ---------------------------------------------------------------------------
-- state

stateGroup :: Node
stateGroup =
    Group
        "state"
        "Create a registry on the proved design and fold into it"
        [ "A registry of open datum on the proved design is made by spending a \
          \seed output of your wallet: one state output that holds the registry's \
          \token and the root of its keys, and one configuration record that \
          \fixes the registry's five parameters for its life. Registrations are \
          \booked with the registration commands and folded into the registry \
          \here by whichever wallet runs the fold, from the chain alone."
        ]
        [stateCreateLeaf, stateFoldLeaf]

registrationGroup :: Node
registrationGroup =
    Group
        "registration"
        "Book a registration, take it back, or clean it up"
        [ "A registration is booked with a key, its payload and a deposit. Until \
          \its processing deadline only a fold spends it; in the window that \
          \follows, the refund address takes everything back; after the window \
          \anyone cleans it up, the deposit returning to the refund address."
        ]
        [bookLeaf, reclaimLeaf, cleanupLeaf]

-- | The controller's actions on a live holding.
holdingGroup :: Node
holdingGroup =
    Group
        "holding"
        "Update a live payload or book permanent termination"
        [ "The controller chooses one live holding by its output reference. An update replaces only its payload. Termination donates its protected deposit immediately and leaves a request for any wallet to fold; the termination cannot be reclaimed."
        ]
        [holdingLeaf False, holdingLeaf True]

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
                        "Spends the chosen holding, donates exactly its protected deposit to the treasury, and creates a datumless request holding the active token and one termination approval. The active token remains until state fold burns both tokens. The folder receives the whole request value; its wallet may be different from the controller's. This booking is permanent and has no reclaim window."
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
                [ "open-datum holding "
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
                [ "open-datum state create --blueprint plutus.json \\"
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
                "Fold the registrations and terminations you name"
            , leafDescription =
                [ "Folds the named pending registrations and terminations into the registry in one transaction. A registration burns its approval and creates its committed holding with the new active token and deposit. A termination burns its approval and active token, creates no holding, and pays its whole request value to the folder. Mixed batches use distinct keys. The transaction is built from public chain data and signed by the wallet running the command; no controller file, key or local record is needed. Name each request with --pending."
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
                [ "open-datum state fold --blueprint plutus.json \\"
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
            { leafName = "book"
            , leafSummary = "Book the registration of a key"
            , leafDescription =
                [ "Books the registration of a key with its payload and a deposit: \
                  \a pending registration holding its approval is put at the \
                  \request address, its deadlines fixed by the registry's \
                  \configuration. The receipt names the pending registration and the \
                  \times of its phases. Whoever folds it, or you reclaiming it, names \
                  \it with --pending."
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
                [ "open-datum registration book --blueprint plutus.json \\"
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
                [ "open-datum registration reclaim --blueprint plutus.json \\"
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
                [ "open-datum registration cleanup --blueprint plutus.json \\"
                , "    --registry <address> --pending <txid>#<ix> \\"
                , "    " <> preprodUrlExample <> " \\"
                , "    --vault bob.vault"
                ]
            , leafNotes = exitStatuses
            }

createLeaf :: Node
createLeaf =
    Runs
        Leaf
            { leafName = "create"
            , leafSummary = "Boot a registry, or preview its identity"
            , leafDescription =
                [ "Boots one registry from a seed output of your wallet and prints \
                  \its address, which every other command names the registry by, \
                  \with its state token and its fingerprint. The processing \
                  \window and the retract window are fixed here for the life of \
                  \the registry."
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
                        [ Each [writeShape, Takes saveStateToken]
                        , Each [Needs preview, Needs previewAddress]
                        ]
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
                    , registryShape
                    , keyShape
                    , Needs payload
                    , Takes payloadSchema
                    , Takes deposit
                    , registryNodeShape
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
                    , registryShape
                    , keyShape
                    , Needs payload
                    , Takes payloadSchema
                    , registryNodeShape
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
            , leafEnvironment =
                [environmentLog, environmentState, environmentPassphrase]
            , leafExamples =
                [ "open-datum update --blueprint plutus.json \\"
                , "    --registry <address> --key my-key --payload payload.json \\"
                , "    " <> preprodUrlExample <> " \\"
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
                    , registryShape
                    , keyShape
                    , registryNodeShape
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
            , leafEnvironment =
                [environmentLog, environmentState, environmentPassphrase]
            , leafExamples =
                [ "open-datum terminate --blueprint plutus.json \\"
                , "    --registry <address> --key my-key \\"
                , "    " <> preprodUrlExample <> " \\"
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
                    , registryShape
                    , registryNodeShape
                    , writeShape
                    , Takes foldRequest
                    , spendingShape
                    , tracingShape
                    ]
            , leafWord = Nothing
            , leafEnvironment =
                [environmentLog, environmentState, environmentPassphrase]
            , leafExamples =
                [ "open-datum fold --blueprint plutus.json \\"
                , "    --registry <address> \\"
                , "    " <> preprodUrlExample <> " \\"
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
                    , registryShape
                    , keyShape
                    , registryNodeShape
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
