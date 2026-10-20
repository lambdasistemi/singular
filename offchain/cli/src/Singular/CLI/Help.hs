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
    , switch'
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
        , programNodes = [registryGroup, walletGroup, submitLeaf]
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
        [ "The registry commands name a registry by its state token, which \
          \create prints; every command but create takes it from --state-token \
          \or from SINGULAR_STATE_TOKEN."
        ]
        [ createLeaf
        , foldLeaf
        , rejectLeaf
        , reclaimLeaf
        , inspectLeaf
        , describeLeaf
        ]

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
-- registry

createLeaf :: Node
createLeaf =
    Runs
        Leaf
            { leafName = "create"
            , leafSummary = "Boot a registry, or preview its identity"
            , leafDescription =
                [ "Boots one registry from a seed output of your wallet and prints its \
                  \state token, which every other command names the registry by. The \
                  \processing window and the retract window are fixed here for the life \
                  \of the registry."
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
                        [ writeShape
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
                    , Needs stateToken
                    , nodeShape
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
                , "    --state-token <policy>.<name> \\"
                , "    " <> preprodExample <> " \\"
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
                    , Needs stateToken
                    , nodeShape
                    , writeShape
                    , spendingShape
                    , tracingShape
                    ]
            , leafWord = Nothing
            , leafEnvironment =
                [environmentLog, environmentState, environmentPassphrase]
            , leafExamples =
                [ "singular registry reject --blueprint plutus.json \\"
                , "    --state-token <policy>.<name> \\"
                , "    " <> preprodExample <> " \\"
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
                    , Needs stateToken
                    , Needs reclaimRequest
                    , nodeShape
                    , writeShape
                    , spendingShape
                    , tracingShape
                    ]
            , leafWord = Nothing
            , leafEnvironment =
                [environmentLog, environmentState, environmentPassphrase]
            , leafExamples =
                [ "singular registry reclaim --blueprint plutus.json \\"
                , "    --state-token <policy>.<name> --request <txid>#<ix> \\"
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
                    , Needs stateToken
                    , keyShape
                    , nodeShape
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

describeLeaf :: Node
describeLeaf =
    Runs
        Leaf
            { leafName = "describe"
            , leafSummary = "Print the registry page"
            , leafDescription =
                [ "Reads the registry page from the chain alone: which registry this \
                  \is, which release it runs, what its rules are and what it holds \
                  \now. It takes no wallet, key, state directory or other actor file: \
                  \each such setting is refused by name before anything is read."
                , "The version label comes from the version file beside the \
                  \blueprint; it is refused by name when missing, unreadable or \
                  \malformed."
                , "The page is printed as indented JSON, which a JSON parser \
                  \reads. --json is accepted and changes nothing: the page is \
                  \JSON either way."
                ]
            , leafShape =
                Each
                    [ Needs blueprint
                    , Needs stateToken
                    , nodeShape
                    , Takes json
                    , tracingShape
                    ]
            , leafWord = Nothing
            , leafEnvironment = [environmentLog]
            , leafExamples =
                [ "singular registry describe --blueprint plutus.json \\"
                , "    --state-token <policy>.<name> " <> preprodExample
                ]
            , leafNotes =
                "Prints the page alone, as indented JSON with or without --json, and writes no file."
                    : drop 1 exitStatuses
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
                    , Takes receipt
                    , tracingShape
                    ]
            , leafWord = Just ("BUNDLE", "The bundle of unsigned transactions.")
            , leafEnvironment = [environmentLog]
            , leafExamples =
                [ "singular submit bundle.json --witnesses witnesses \\"
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

foldRequest :: Flag
foldRequest =
    valued
        "--request"
        "TXID#IX"
        "Expect this pending request to be folded; refused if it is not among those settled."

reclaimRequest :: Flag
reclaimRequest =
    valued "--request" "TXID#IX" "The pending request to take back."

json :: Flag
json =
    switch'
        "--json"
        "Accepted and changes nothing: the page is printed as indented JSON either way."

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
