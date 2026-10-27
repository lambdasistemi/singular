{- |
Module      : Singular.CLI.Help
Description : The @singular@ program, declared once for its help and completion
License     : Apache-2.0

Every command of @singular@, what it does, which settings it takes and one
example for each command that writes. The overview, each command's help page,
the usage line a refusal shows and the shell completion are generated from
this declaration by "Singular.CLI.Options".
-}
module Singular.CLI.Help
    ( singularProgram
    , singularHelp
    , singularUsageLine
    ) where

import Data.Version (Version)

import Singular.CLI.Declared
import Singular.CLI.Options
    ( Flag (..)
    , Leaf (..)
    , Node (..)
    , Program (..)
    , Shape (..)
    , helpText
    , standing
    , usageText
    , valued
    )

-- | The program, at the version it was built as.
singularProgram :: Version -> Program
singularProgram version =
    Program
        { programName = "singular"
        , programSummary =
            "Create a Singular registry on Cardano, fold requests into it, reject or \
            \reclaim requests, read it back, and sign and submit transaction bundles."
        , programVersion = version
        , programNodes = [registryGroup, stateGroup, walletGroup, submitLeaf]
        , programFooter =
            [ ""
            , "Every command takes --trace, --trace-to and --trace-format to narrate"
            , "what it does; standard output carries the receipt alone."
            ]
        }

-- | The help page of a command (the overview for none).
singularHelp :: Version -> [(String, String)] -> [String] -> String
singularHelp version = helpText (singularProgram version)

-- | The usage line of a command.
singularUsageLine :: Version -> [String] -> [String]
singularUsageLine version = usageText (singularProgram version)

registryGroup :: Node
registryGroup =
    Group
        "registry"
        "Create a registry and act on it"
        [ "The registry commands name a registry by its address, which create \
          \prints: one word that holds the registry's state token and its network, \
          \so a command given it needs nothing else to find the registry. Every \
          \command but create takes it from --registry or from SINGULAR_REGISTRY. \
          \A registry may still be named by its state token (--state-token or \
          \SINGULAR_STATE_TOKEN) with the network (--network-magic); given both, \
          \they must agree."
        ]
        [ createLeaf
        , foldLeaf
        , rejectLeaf
        , reclaimLeaf
        , inspectLeaf
        ]

stateGroup :: Node
stateGroup =
    Group
        "state"
        "Create a registry on the proved design"
        [ "The state commands make the registry of an application: its state, a single \
          \output that holds the registry's token and the root of its keys. The \
          \registry is named by its seed, an output of your wallet, and by the \
          \application whose policy the state validator is made for. The commands \
          \take the compiled validators of the release (--blueprint) and a single \
          \signer."
        ]
        [stateCreateLeaf]

walletGroup :: Node
walletGroup =
    Group
        "wallet"
        "Keep a signing key in an encrypted vault"
        [ "The wallet commands are local: they take no provider, blueprint or \
          \registry setting, and refuse each by name. The passphrase is read from \
          \the terminal with the echo off, as one line from --passphrase-fd, or on a \
          \development network from the variable SINGULAR_PASSPHRASE; it is never \
          \an argument or a key of the config file, and no output, refusal or trace \
          \names it."
        ]
        [walletCreateLeaf, walletAddressLeaf, walletSignLeaf]

-- ---------------------------------------------------------------------------
-- state

stateCreateLeaf :: Node
stateCreateLeaf =
    Runs
        Leaf
            { leafName = "create"
            , leafSummary = "Create the registry of an application"
            , leafDescription =
                [ "Creates one registry of the application whose policy is given, by \
                  \spending a seed output of your wallet, and prints the registry's \
                  \address, its state token and the transactions it sent. The first \
                  \registry of an application publishes the state validator as a \
                  \reference script, in a transaction of its own, before it creates \
                  \the registry; a later registry finds the live copy and sends one \
                  \transaction."
                , "The seed fixes the registry's identity. The wallet funds the \
                  \transactions and keeps their change."
                , signerParagraph
                ]
            , leafShape =
                Each
                    [ Takes stateDir
                    , Needs blueprint
                    , Needs stateApplicationPolicy
                    , Takes seed
                    , nodeShape
                    , writeShape
                    , tracingShape
                    ]
            , leafWord = Nothing
            , leafEnvironment =
                [environmentLog, environmentState, environmentPassphrase]
            , leafExamples =
                [ "singular state create --blueprint plutus.json \\"
                , "    --application-policy <policy> \\"
                , "    " <> preprodExample <> " \\"
                , "    --vault alice.vault"
                ]
            , leafNotes = exitStatuses
            }

-- ---------------------------------------------------------------------------
-- registry

createLeaf :: Node
createLeaf =
    Runs
        Leaf
            { leafName = "create"
            , leafSummary = "Boot a registry, or preview its identity"
            , leafDescription =
                [ "Boots one registry from a seed output of your wallet and prints its \
                  \address, which every other command names the registry by, with its \
                  \state token and its fingerprint. The processing window and the \
                  \retract window are fixed here for the life of the registry."
                , signerParagraph
                , previewParagraph
                ]
            , leafShape =
                Each
                    [ Takes stateDir
                    , Needs blueprint
                    , Takes seed
                    , Takes applicationPolicy
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
                [ "singular registry create --blueprint plutus.json \\"
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
                [ "Folds the pending requests the registry can settle into it, \
                  \signed and funded by the wallet that runs it, and names every \
                  \request it leaves out. With --request, the command is refused \
                  \unless that request is among those folded."
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
                [ "singular registry fold --blueprint plutus.json \\"
                , "    --registry <address> \\"
                , "    " <> preprodUrlExample <> " \\"
                , "    --vault alice.vault"
                ]
            , leafNotes = exitStatuses
            }

rejectLeaf :: Node
rejectLeaf =
    Runs
        Leaf
            { leafName = "reject"
            , leafSummary = "Reject all pending requests past their windows"
            , leafDescription =
                [ "Clears the registry's pending requests, all or none: it is built \
                  \only once every pending request is past both its windows, the \
                  \processing window and the retract window after it. Until then it \
                  \is refused, naming each request and when its retract window \
                  \closes. Each owner is refunded the request's value less the tip; \
                  \the wallet that runs it keeps the tip."
                , signerParagraph
                ]
            , leafShape =
                Each
                    [ Takes stateDir
                    , Needs blueprint
                    , registryShape
                    , registryNodeShape
                    , writeShape
                    , spendingShape
                    , tracingShape
                    ]
            , leafWord = Nothing
            , leafEnvironment =
                [environmentLog, environmentState, environmentPassphrase]
            , leafExamples =
                [ "singular registry reject --blueprint plutus.json \\"
                , "    --registry <address> \\"
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
            , leafSummary = "Take back your own pending request"
            , leafDescription =
                [ "Takes back the named pending insertion or terminal-witness \
                  \request of this wallet, inside its retract window. The locked \
                  \lovelace returns to the owner in one output; the registry's root \
                  \does not move. An early refusal names when the window opens; \
                  \once closed, registry reject clears the request."
                , signerParagraph
                ]
            , leafShape =
                Each
                    [ Takes stateDir
                    , Needs blueprint
                    , registryShape
                    , Needs reclaimRequest
                    , registryNodeShape
                    , writeShape
                    , spendingShape
                    , tracingShape
                    ]
            , leafWord = Nothing
            , leafEnvironment =
                [environmentLog, environmentState, environmentPassphrase]
            , leafExamples =
                [ "singular registry reclaim --blueprint plutus.json \\"
                , "    --registry <address> --request <txid>#<ix> \\"
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
            , leafSummary = "Read the registry and a key back"
            , leafDescription =
                [ "Reads the registry and one key back: the key's state, the pending \
                  \requests with what each actually locks, and the registry's root. \
                  \It reads only: it takes no signing key and submits nothing."
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
            , leafEnvironment =
                [environmentLog, environmentState]
            , leafExamples = []
            , leafNotes = exitStatuses
            }

-- ---------------------------------------------------------------------------
-- wallet and submit

walletCreateLeaf :: Node
walletCreateLeaf =
    Runs
        Leaf
            { leafName = "create"
            , leafSummary = "Create a vault with a fresh key"
            , leafDescription =
                [ "Draws a fresh payment signing key from the operating system's \
                  \entropy, seals it into a new vault file under the passphrase, \
                  \and prints the key's enterprise address for the network. It \
                  \refuses a path that exists and leaves its bytes untouched; a \
                  \failed write removes what it made. The passphrase is asked twice at the terminal, or read from \
                  \--passphrase-fd or, on a development network, from \
                  \SINGULAR_PASSPHRASE."
                ]
            , leafShape =
                Each
                    [ Needs vaultToCreate
                    , Needs networkMagicOfAddress
                    , Takes passphraseFd
                    , tracingShape
                    ]
            , leafWord = Nothing
            , leafEnvironment = [environmentLog, environmentPassphrase]
            , leafExamples =
                ["singular wallet create --vault alice.vault --network-magic 1"]
            , leafNotes =
                [ "Prints the address on one line of standard output."
                , "Exit status 0 on success, 1 when the vault could not be made, 2 for a command line it refused."
                ]
            }

walletAddressLeaf :: Node
walletAddressLeaf =
    Runs
        Leaf
            { leafName = "address"
            , leafSummary = "Print the address of a vault's key"
            , leafDescription =
                [ "Opens the vault and prints the same address wallet create \
                  \printed for the same network. The passphrase is asked once at the terminal, or read from \
                  \--passphrase-fd or, on a development network, from \
                  \SINGULAR_PASSPHRASE."
                ]
            , leafShape =
                Each
                    [ Needs vaultToOpen
                    , Needs networkMagicOfAddress
                    , Takes passphraseFd
                    , tracingShape
                    ]
            , leafWord = Nothing
            , leafEnvironment = [environmentLog, environmentPassphrase]
            , leafExamples =
                ["singular wallet address --vault alice.vault --network-magic 1"]
            , leafNotes =
                [ "Prints the address on one line of standard output."
                , "Exit status 0 on success, 1 when the vault could not be opened, 2 for a command line it refused."
                ]
            }

walletSignLeaf :: Node
walletSignLeaf =
    Runs
        Leaf
            { leafName = "sign"
            , leafSummary = "Sign a bundle of transactions offline"
            , leafDescription =
                [ "Witnesses a bundle of unsigned transactions from the vault, \
                  \offline: one witness file per transaction, named by the \
                  \transaction's identity and created exclusively. The network \
                  \comes from the bundle. A bundle whose identities, deadlines or \
                  \signers disagree with its transactions, or whose signers do not \
                  \include this vault's address, is refused by name and nothing is \
                  \written. No provider setting is read."
                ]
            , leafShape =
                Each
                    [ Needs vaultToOpen
                    , Takes passphraseFd
                    , Takes witnessDirectory
                    , tracingShape
                    ]
            , leafWord =
                Just
                    ( "BUNDLE"
                    , "The bundle of unsigned transactions a write with --bundle wrote."
                    )
            , leafEnvironment = [environmentLog, environmentPassphrase]
            , leafExamples =
                [ "singular wallet sign bundle.json --vault alice.vault --out witnesses"
                ]
            , leafNotes =
                [ "Writes one .witness file per transaction; prints nothing on standard output."
                , "Exit status 0 on success, 1 when the bundle was refused, 2 for a command line it refused."
                ]
            }

submitLeaf :: Node
submitLeaf =
    Runs
        Leaf
            { leafName = "submit"
            , leafSummary = "Send a signed bundle, print its receipt"
            , leafDescription =
                [ "Sends a bundle its signers witnessed. Each witness file, or each \
                  \.witness file of a directory, is matched to a transaction by its \
                  \signature, and every check runs before the first send: a witness \
                  \for no transaction or for a key no transaction needs, a missing \
                  \witness, an input found nowhere and a body the tip has expired \
                  \(rebuild the bundle) are refused by name."
                , "A bundle that names a registry is checked against it before the \
                  \first send: give the release it was created under with --blueprint, \
                  \and the registry's pinned policies must be the ones that release \
                  \derives, or the bundle is refused naming the policy that differs. \
                  \A bundle that names no registry is refused, unless it is a create \
                  \bundle, which needs no release. The registry name in a bundle is its \
                  \writer's statement: this checks the registry it names, not that the \
                  \transactions act on it."
                , "The transactions the chain does not hold are sent in the bundle's \
                  \order, each confirmed before the next; an uncertain answer stops \
                  \the run as partial and nothing is sent again, so running it again \
                  \sends only the rest. It takes no wallet key and no vault, and \
                  \keeps no state."
                ]
            , leafShape =
                Each
                    [ Needs witnesses
                    , nodeShape
                    , Takes blueprint
                    , Takes receipt
                    , tracingShape
                    ]
            , leafWord = Just ("BUNDLE", "The bundle of unsigned transactions.")
            , leafEnvironment = [environmentLog]
            , leafExamples =
                [ "singular submit bundle.json --witnesses witnesses \\"
                , "    --blueprint plutus.json \\"
                , "    " <> preprodExample
                ]
            , leafNotes =
                "The receipt is read back from the chain and printed as JSON on standard output."
                    : drop 1 exitStatuses
            }

-- ---------------------------------------------------------------------------
-- flags only this program reads, or reads with its own words

applicationPolicy :: Flag
applicationPolicy =
    valued
        "--application-policy"
        "HEX"
        "Pin an application policy at creation: 56 hex characters, a 28-byte hash."

stateApplicationPolicy :: Flag
stateApplicationPolicy =
    valued
        "--application-policy"
        "HEX"
        "The policy of the application the registry is for: 56 hex characters, a 28-byte hash. It is the one parameter of the state validator."

foldRequest :: Flag
foldRequest =
    valued
        "--request"
        "TXID#IX"
        "Expect this pending request to be folded; refused if it is not among those settled."

reclaimRequest :: Flag
reclaimRequest =
    valued "--request" "TXID#IX" "The pending request to take back."

vaultToCreate :: Flag
vaultToCreate =
    standing
        ( valued
            "--vault"
            "FILE"
            "The new vault file to create; an existing path is refused."
        )

vaultToOpen :: Flag
vaultToOpen = standing (valued "--vault" "FILE" "The vault to open.")

networkMagicOfAddress :: Flag
networkMagicOfAddress =
    valued "--network-magic" "N" "The network the address is built for."

witnessDirectory :: Flag
witnessDirectory =
    (valued "--out" "DIR" "Directory the witness files are written to.")
        { flagDefault = Just "the bundle's directory"
        }

witnesses :: Flag
witnesses =
    valued
        "--witnesses"
        "FILE"
        "A witness file from wallet sign, or a directory of them; give it once for each."
