{- |
Module      : Singular.CLI.Declared
Description : The settings both programs share, declared once
License     : Apache-2.0

Every flag the programs built on "Singular.CLI.Options" read in common, with its metavariable, its
description and its default, and the groups they travel in: the node, the
signer, the tracing controls. A program's declaration uses these so the same
flag reads the same in every command's help, and its words change in one
place.
-}
module Singular.CLI.Declared
    ( -- * Shared flags
      stateDir
    , blueprint
    , holding
    , stateToken
    , registry
    , stateTokenVariable
    , koiosUrl
    , networkMagic
    , koiosTokenFile
    , networkTime
    , vault
    , passphraseFd
    , walletAddress
    , bundle
    , walletSkey
    , payloadSchema
    , receipt
    , confirmTimeout
    , fundInput
    , maxOutlay
    , seed
    , preview
    , saveStateToken
    , processTime
    , retractTime
    , keyText
    , keyHex
    , outputsAt
    , reconcileAddress
    , previewAddress
    , traceLevel
    , traceTo
    , traceFormat

      -- * Groups
    , nodeShape
    , registryNodeShape
    , registryShape
    , signerShape
    , tracingShape
    , keyShape
    , writeShape
    , spendingShape

      -- * Words shared by the commands
    , signerParagraph
    , previewParagraph
    , exitStatuses
    , preprodExample
    , preprodUrlExample
    , environmentLog
    , environmentState
    , environmentPassphrase
    ) where

import Data.List (intercalate)

import Singular.CLI.Options
    ( Flag (..)
    , Shape (..)
    , standing
    , switch'
    , valued
    )
import Singular.CLI.Passphrase (passphraseVariable, publicNetworks)

-- | The variable that names the registry when @--state-token@ is absent.
stateTokenVariable :: String
stateTokenVariable = "SINGULAR_STATE_TOKEN"

stateDir :: Flag
stateDir =
    standing
        ( valued
            "--state-dir"
            "DIR"
            "Keep the journal and submissions under DIR."
        )
            { flagDefault = Just "the per-user state directory"
            }

blueprint :: Flag
blueprint =
    standing
        ( valued
            "--blueprint"
            "FILE"
            "The compiled validators (plutus.json) of the release."
        )

-- | The live holding a controller chooses to spend.
holding :: Flag
holding =
    valued
        "--holding"
        "TXID#IX"
        "The live holding to update or terminate, as its transaction printed it; none is chosen for you."

stateToken :: Flag
stateToken =
    standing
        ( valued
            "--state-token"
            "POLICY.NAME"
            "The registry to act on: its state token, policy and name in hex, as create prints it."
        )

registry :: Flag
registry =
    standing
        ( valued
            "--registry"
            "ADDRESS"
            "The registry to act on: its address, as create prints it. The address holds the state token and the network, so a command given it needs neither."
        )

koiosUrl :: Flag
koiosUrl =
    standing
        ( valued
            "--koios-url"
            "URL"
            "Base URL of the Koios API used to read the chain and to submit."
        )

networkMagic :: Flag
networkMagic =
    standing
        ( valued
            "--network-magic"
            "N"
            "The network: 1 for preprod, 42 for the generated development network."
        )

koiosTokenFile :: Flag
koiosTokenFile =
    standing
        ( valued
            "--koios-token-file"
            "FILE"
            "File holding a Koios bearer token; its contents are never printed."
        )

networkTime :: Flag
networkTime =
    standing
        ( valued
            "--network-time"
            "DIR"
            "Directory with the pinned time-manifest.json, shelley-genesis.json and era-history.cbor."
        )
            { flagDefault = Just "the preprod recording packaged with the program"
            }

vault :: Flag
vault =
    standing
        ( valued
            "--vault"
            "FILE"
            "Signer, normal route: sign from this encrypted wallet vault."
        )

passphraseFd :: Flag
passphraseFd =
    ( valued
        "--passphrase-fd"
        "N"
        "Read the vault passphrase, one line, from this inherited file descriptor; it wins over SINGULAR_PASSPHRASE."
    )
        { flagDefault =
            Just
                "SINGULAR_PASSPHRASE on a development network, else ask on the terminal with the echo off"
        }

walletAddress :: Flag
walletAddress =
    valued
        "--wallet-address"
        "ADDR"
        "Signer, external route: stage the run for a signer at this address; goes with --bundle."

bundle :: Flag
bundle =
    valued
        "--bundle"
        "FILE"
        "Signer, external route: the new file the unsigned transactions are written to; goes with --wallet-address."

walletSkey :: Flag
walletSkey =
    valued
        "--wallet-skey"
        "FILE"
        "Signer, legacy route: sign with this payment key file. Prefer the vault."

payloadSchema :: Flag
payloadSchema =
    ( valued
        "--payload-schema"
        "plain|detailed"
        "The form the payload file is written in. plain: ordinary JSON, mapped to Plutus data by the table in the documentation. detailed: the schema that writes any Plutus data exactly."
    )
        { flagDefault = Just "plain"
        }

receipt :: Flag
receipt =
    valued "--receipt" "FILE" "Also write the JSON receipt to FILE."

confirmTimeout :: Flag
confirmTimeout =
    ( valued
        "--confirm-timeout"
        "SECONDS"
        "How long each submission may take to confirm; past it the command stops, journalled, and never resubmits."
    )
        { flagDefault = Just "600"
        }

fundInput :: Flag
fundInput =
    valued
        "--fund-input"
        "TXID#IX"
        "The wallet output that funds and collateralises the transaction."

maxOutlay :: Flag
maxOutlay =
    valued
        "--max-outlay"
        "LOVELACE"
        "The most the command may spend from the wallet; past it nothing is signed."

seed :: Flag
seed =
    ( valued
        "--seed"
        "TXID#IX"
        "The wallet output the registry is booted from; it fixes the registry's identity."
    )
        { flagDefault = Just "your largest ada-only output"
        }

preview :: Flag
preview =
    switch'
        "--preview"
        "Build and measure what would be submitted and print it; sign, submit and journal nothing."

-- | The switch that has create keep the registry's name in the settings file.
saveStateToken :: Flag
saveStateToken =
    switch'
        "--save-state-token"
        "After a create that succeeds, keep the new registry's state token as the key state-token of the settings file (--config, SINGULAR_CONFIG, else singular.json in the working directory), so the commands after it need no --state-token. Refused with --preview and with --wallet-address and --bundle."

processTime :: Flag
processTime =
    ( valued
        "--process-time"
        "MS"
        "How long a booked request may wait for its fold, in milliseconds; fixed for the life of the registry."
    )
        { flagDefault = Just "600000, ten minutes"
        }

retractTime :: Flag
retractTime =
    ( valued
        "--retract-time"
        "MS"
        "How long the owner may reclaim a request after its processing deadline, in milliseconds; fixed for the life of the registry."
    )
        { flagDefault = Just "300000, five minutes"
        }

keyText :: Flag
keyText =
    valued
        "--key"
        "KEY"
        "The registry key as text, its UTF-8 bytes (1 to 32); give this or --key-hex."

keyHex :: Flag
keyHex =
    valued
        "--key-hex"
        "HEX"
        "The registry key as base16 bytes (1 to 32), for a key that is not text; give this or --key."

outputsAt :: Flag
outputsAt =
    valued
        "--outputs-at"
        "ADDR"
        "Also list the outputs at this public address, read from the provider."

reconcileAddress :: Flag
reconcileAddress =
    valued
        "--wallet-address"
        "ADDR"
        "Your public address: reconcile that wallet's journal as a write would. Without it the read is stateless."

previewAddress :: Flag
previewAddress =
    valued
        "--wallet-address"
        "ADDR"
        "Your public address, in place of a signing key, for the preview."

traceLevel :: Flag
traceLevel =
    standing
        ( valued
            "--trace"
            "LEVEL"
            "How much to narrate: off, what (protocol steps) or how (also their mechanics)."
        )
            { flagDefault = Just "what on a terminal, otherwise off"
            }

traceTo :: Flag
traceTo =
    standing
        ( valued
            "--trace-to"
            "SINK"
            "Where the narration goes: stderr or file:PATH; repeat for several."
        )
            { flagDefault = Just "stderr"
            }

traceFormat :: Flag
traceFormat =
    standing
        ( valued
            "--trace-format"
            "FORMAT"
            "The format of the narration: text for a person, json for a program."
        )
            { flagDefault = Just "text on standard error, json in a file"
            }

-- | The Koios node every chain-reading command names.
nodeShape :: Shape
nodeShape =
    Each
        [ Needs koiosUrl
        , Needs networkMagic
        , Takes koiosTokenFile
        , Takes networkTime
        ]

{- | What names the registry a command acts on: its address, or its state token
with the network. A line may give both, and they must agree.
-}
registryShape :: Shape
registryShape = Each [Takes registry, Takes stateToken]

{- | The Koios node a command that takes a registry names: the network may be
left to the registry's address.
-}
registryNodeShape :: Shape
registryNodeShape =
    Each
        [ Needs koiosUrl
        , Takes networkMagic
        , Takes koiosTokenFile
        , Takes networkTime
        ]

{- | The signers of a write, the normal route first and the key file, which
is legacy, last.
-}
signerShape :: Shape
signerShape =
    OneOf
        [ Each [Needs vault, Takes passphraseFd]
        , Each [Needs walletAddress, Needs bundle]
        , Needs walletSkey
        ]

-- | The tracing controls every command takes.
tracingShape :: Shape
tracingShape =
    Each [Takes traceLevel, Takes traceTo, Takes traceFormat]

-- | A registry key, named once, as text or as hex.
keyShape :: Shape
keyShape = OneOf [Needs keyText, Needs keyHex]

-- | What a write names to sign and to leave a receipt: one signer, how long to wait, where to write the receipt.
writeShape :: Shape
writeShape =
    Each [signerShape, Takes confirmTimeout, Takes receipt]

-- | The spending limits of a write.
spendingShape :: Shape
spendingShape = Each [Takes fundInput, Takes maxOutlay]

signerParagraph :: String
signerParagraph =
    "A write is signed by exactly one signer: --vault (the normal route), \
    \--wallet-address with --bundle (written for an external signer, ending \
    \as waiting-for-signatures), or --wallet-skey (a key file, legacy). \
    \Naming two is refused."

previewParagraph :: String
previewParagraph =
    "With --preview it names the caller by --wallet-address instead of a \
    \signing key, builds and measures what it would submit, prints it, and \
    \signs, submits and journals nothing."

-- | How a command that runs ends.
exitStatuses :: [String]
exitStatuses =
    [ "Prints one JSON receipt on standard output (--receipt also writes it)."
    , "Exit status 0 on success, 2 for a command line it refused, otherwise the"
    , "outcome class the receipt names: 10 refused before anything was sent,"
    , "11 refused by the ledger, 12 node unavailable, 13 timeout, 14 stale state,"
    , "15 partial, 16 another writer, 17 proof missing, 18 proof inconsistent,"
    , "19 waiting for signatures."
    ]

-- | The Koios URL and network the examples use.
preprodExample :: String
preprodExample =
    "--koios-url https://preprod.koios.rest/api/v1 --network-magic 1"

-- | The Koios URL the examples of a command given a registry address use: the address names the network.
preprodUrlExample :: String
preprodUrlExample = "--koios-url https://preprod.koios.rest/api/v1"

environmentLog :: (String, String)
environmentLog =
    ( "SINGULAR_LOG"
    , "A file the protocol phases are appended to, one line each."
    )

environmentState :: (String, String)
environmentState =
    ( "XDG_STATE_HOME"
    , "Where the per-user state directory lives (else $HOME/.local/state), under singular/."
    )

{- | The variable a vault's passphrase may come from, with the networks that
refuse it, listed from the code that refuses them.
-}
environmentPassphrase :: (String, String)
environmentPassphrase =
    ( passphraseVariable
    , "The vault passphrase, for a development network only: a command on "
        <> named
        <> " refuses it. --passphrase-fd wins over it, and a value that is empty is refused."
    )
  where
    named = case reverse
        [name <> " (" <> show magic <> ")" | (name, magic) <- publicNetworks] of
        [] -> "no public network"
        [one] -> one
        final : before -> intercalate ", " (reverse before) <> " or " <> final
