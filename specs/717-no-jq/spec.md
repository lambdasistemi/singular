# Specification: the Demo 1 steps need no jq

## The story

Alice follows the Demo 1 tutorial on a private chain. She types each command and reads what it returned. Today the step pages ask her to learn `jq` as well: to build the settings file from the devnet's line, to copy the registry's name out of the create receipt, to carry a booking's request into a reclaim, and to pick a few fields out of every receipt. After this ticket she types only the programs. The commands write the settings file, remember the registry's name, take an earlier receipt as input and print a short summary of what they did. When it works she sees the summary and the next command runs with no copying. When she gives a receipt that does not hold what is asked, she sees one sentence naming the option, the file and what is missing.

The tutorial lives in a separate repository and is not changed here. Each part ends with a note for the tutorial's owner naming the lines that lose their `jq` and what replaces them.

## The four parts

The parts are separate pull requests, each merged before the next starts.

| Merge order | Part of the issue | Part | What the reader gets |
|---|---|---|---|
| first | part 2 | The registry's name recorded by create | `create` writes the new registry's state token into the settings file |
| second | part 1 | The settings file written from the devnet | one command turns the devnet's settings line into the settings file |
| third | part 3 | A receipt file given in place of a value | `--request` and `--state-token` accept an earlier receipt |
| fourth | part 4 | A readable summary of a receipt | every command that prints a receipt can print a short summary instead |

The order is the one the desk ruled. Intake found one dependency that agrees with it: the settings file writer is introduced by the registry's name part and used again by the settings part, and the receipt part makes the state token option of the settings command accept a receipt. No dependency changes the order. The notes for the tutorial's owner are named after the issue's part numbers.

## Rules for every part

- Nothing that works on version 0.14.0 changes. Every option, every receipt and every exit status keeps its output. New behaviour is a new option, a new command or a value accepted where it was refused.
- A default receipt stays the full JSON. The summary is selected by an explicit option.
- The settings rules of the earlier settings tickets apply. A standing setting has three forms: the flag, the variable `SINGULAR_<NAME>` and the key of the settings file. The new options below are not standing settings: each is an action of one command, so each has the flag form only.
- A path means what it means on the command line: relative to where the command runs.
- No passphrase, token file content or key is written to the settings file or printed in a summary.

## The registry's name recorded by create

`create`, of both programs, takes the switch `--save-state-token`.

- It is judged before anything else is read or spent. It is refused, with one sentence and exit status 2, when it comes with `--preview` (nothing is created) or with `--wallet-address` and `--bundle` (the registry does not exist until the bundle is submitted, so there is no name to keep yet). It is refused, naming the file and the cause, when the settings file in use exists and cannot be written, or when it does not exist and its folder cannot be written.
- The settings file in use is the one named by `--config`, else by `SINGULAR_CONFIG`, else `singular.json` in the working directory. When none of the three exists as a file, `create` makes the working directory's `singular.json` holding the one key.
- When the create receipt's outcome is `success`, the file gets the key `state-token` with the receipt's `stateToken`. Any other outcome writes nothing: the receipt names whatever state there is.
- The other keys keep their values and their kind, text or number. An existing `state-token` is replaced. The file is rewritten as one indented JSON object, so its key order and spacing may change. The new file replaces the old one in a single step, keeping the old file's permissions.
- On success one line of narration says which file now holds the name. If the write fails after the registry exists, one sentence on standard error says so, names the file and the cause, and says the name is in the receipt. The exit status is the receipt's.
- The receipt is the same as without the option.

## The settings file written from the devnet

`singular` gains the command `settings save`. It writes settings into the settings file, so a reader never edits JSON by hand.

| Option | Meaning |
|---|---|
| `--from-devnet FILE` | take `koios-url`, `network-time` and `network-magic` from the first line of FILE that is the devnet's settings line |
| `--wait SECONDS` | how long to wait for that line to appear in FILE; default 60, and 0 reads once |
| `--config FILE` | the file to write; else `SINGULAR_CONFIG`; else `singular.json` in the working directory |
| the eleven standing settings as flags | `--koios-url`, `--network-time`, `--network-magic`, `--blueprint`, `--state-dir`, `--state-token`, `--koios-token-file`, `--vault`, `--trace`, `--trace-to`, `--trace-format` |

- It writes exactly what is on its command line and in the devnet's line. It does not copy variables or the old file's values into themselves: the standing settings are plain flags here, with no variable and no key.
- A flag wins over the devnet's line. The devnet's `networkMagic` is written as text like every value written by the command. A devnet line whose `networkTimeDirectory` is null leaves `network-time` out.
- The devnet's line is the first line of FILE that is a JSON object holding `providerUrl` and `networkMagic`. The devnet writes it a few seconds after it starts, so the command waits for it. Other lines of FILE are ignored.
- An existing file is merged into with the same rules as the registry's name above: other keys kept, a key given replaced, the file replaced in a single step. A file that exists and is not a usable settings file is refused with the sentence the other commands give. A named file that does not exist is created.
- It prints the settings file as it is after the write: one indented JSON object on standard output.
- It is refused, with one sentence on standard error, nothing written and exit status 1, when it is given nothing to save, when the line does not appear within the wait (naming the file and saying to check the devnet is running), or when the file cannot be written.

## A receipt file given in place of a value

An `@` before a path says the value is in a receipt: `@receipts/03-insert-alice.json`. A request has the form `txid#index` and a state token the form `policy.name`, and neither starts with `@`, so the two cannot be confused.

| Option | Read from the receipt |
|---|---|
| `--request` | the receipt's `request`; when it has none, `expected.request`, which is where a receipt waiting for signatures keeps it |
| `--state-token` | the receipt's `stateToken` |

- The form works wherever the value comes from: the flag, the variable `SINGULAR_STATE_TOKEN` or the key `state-token` of the settings file. A path in the file or the variable is relative to where the command runs.
- It works in every command that takes the option, in both programs, and in `settings save`.
- It is refused, with exit status 2 and one sentence naming the option and the file, when the file does not exist, cannot be read, is not JSON, or holds no such field. The last case names the receipt's outcome, because a refused command's receipt holds none.
- The help of each of the two options says that `@FILE` is accepted.
- No other option takes a receipt. No command of the programs takes a transaction identity, so the tutorial's lookup of a submission by its identity stays with the tutorial's own web calls.

## A readable summary of a receipt

Every command that prints a receipt or a reading takes the switch `--summary`: `create`, `fold`, `insert`, `update`, `terminate` and `inspect` of `open-datum`, and `registry create`, `registry fold`, `registry reject`, `registry reclaim`, `registry inspect` and `submit` of `singular`.

- With the switch, standard output carries the summary and not the JSON. The JSON receipt still goes to the file named by `--receipt`, so one command can show the summary and keep the receipt for the next step.
- The exit status, the journal and the receipt file are the same as without the switch.
- A summary is plain lines `name: value`, in a fixed order, with the names the receipt uses. A field that is null or absent has no line. An identifier, a slot or an amount is printed whole, never shortened, because the next step may need to type it. A list prints a line with its name and one indented line per item.
- Every summary starts with `outcome` and, when there is one, `reason`. The other fields are the ones the tutorial picked out of each receipt:

| Command | Fields after the outcome and the reason |
|---|---|
| `create` | seed, stateToken |
| `insert`, `update`, `terminate` | request, foldDeadline, and for `terminate` also released and deposit; for `update` also payload and root |
| `fold` | what the fold will settle (key and edge of each) and the time left, or what it settled and the root |
| `registry reject` | the pending requests with their retractEndsSlot, the tip slot, or the rejected requests with their keys |
| `registry reclaim` | request, returned |
| `submit` | for each submission: identity, slot, block hash and confirmations |
| `inspect` | key, state, payload, deposit, root |

- The help of each command says that the switch exists and that the JSON stays available through `--receipt`.
- The summary never contains a secret: it holds only fields the receipt holds.

## Evidence

Each part is proved on its own, in unit and parser tests and in a hosted check on a devnet that runs the form without `jq` and fails when the form is broken.

| Part | The hosted check |
|---|---|
| Registry's name recorded | a Demo 1 journey creates with the switch, then runs the next commands with no state token on the line and reads the name only from the file; a control gives it an unusable file and sees the refusal before any wallet or chain is touched |
| Settings from the devnet | a journey starts the devnet, runs the settings command on its output file and runs the first command with the written file alone; a control gives it an empty file and a file with no line and sees the refusals |
| Receipt as input | a journey books a request and takes it back with the receipt in place of the request; a control names a receipt of a refused command and sees the refusal |
| Summary | a journey runs a command with the switch and the receipt file and checks that the summary lines match the file's fields and the exit status is unchanged |

## What is not changed

- Nothing in `lean/`, the validators or the script hashes changes.
- The readable summary does not replace the receipt: scripts keep the JSON.
- The glue the issue names as remaining with the tutorial stays there: waiting for a slot and listing a wallet's outputs through the devnet's web API.
- The registry's name is not a secret and is written in the clear.
