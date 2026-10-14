# Economic model rows: modules, data and functions of slices five to ten

This page owns the new or changed rows of the economic slices, in the same three layers as the [modules](modules-model.md), [data](data-model.md) and
[functions](functions-model.md) pages of the protected rejection rule, for the [economics plan](economics-plan.md) and the [design](economics-design.md).
It contains no bodies and no proofs. The rows here say what each slice owns; the exact signatures of a slice are added to this page by the ticket owner
before that slice is dispatched, so that no writer chooses a name that another slice, the transport or the paper depends on.

## Story

As the writer given an economic slice, I read the rows of that slice and nothing I have to guess, so that the model, the transport and the paper name every
amount, parameter and statement the same way.

```mermaid
flowchart LR
    Model[Singular.Model<br/>parameters, output references, interval,<br/>transaction record extended] --> Economics[Singular.Economics<br/>unspent set, balance, requests, pool,<br/>booking, exits' payments]
    Economics --> Statements[Singular.Statements<br/>the thirteen statements, supporting statements]
    Statements --> Register[theorem register and page]
    Economics --> Main[lean Main<br/>corpus rows]
    Main --> Corpus[exported corpora]
    Corpus --> Mirror[simulator mirror and application corpus]
```

## Modules

| Module | Responsibility | Slices | Dependency direction |
|---|---|---|---|
| `Singular.Model` | The configuration gains the three parameters; the vocabulary types `OutRef`, `Interval` and `TokenId` and the new fields of the transaction record live here, beside the record they extend | five | Reads nothing new |
| `Singular.Economics` (new) | The unspent set, the presence and balance judgements, the registration and termination requests, the exact-contents rule, the pending pool, booking steps, the world and its reachability, the payments of every exit; definitions only | five to ten | Reads Model |
| `Singular.Statements` | The thirteen statements, the supporting statements and the kept variants | five to ten | Reads Model and Economics |
| `lean/Main.lean`, `Driver.lean` | Corpus rows and, where a declared question changes, its wire form | five to ten | Reads Model, Statements |
| `tools/check_model.py` | The frozen source extent of the generic corpus lists the new module, so the corpus binds it | five | Mechanical consumer change |
| Generated copies | Corpora, register and digests, theorem page, simulator mirror, application corpus, coverage record, restatement table, constitution entry | five to ten | Produced by tools, never edited |

The new module is imported by the root module so the axiom gate and the audit report walk it. The model checker refuses a change to the imports of `Singular.Model`
beyond the naming layer's, which is why the vocabulary types sit in the model file and only functions over them sit in `Singular.Economics`.

## Data

| Entity | Field or shape | Meaning | Slice | Default and encoding |
|---|---|---|---|---|
| Registry configuration | `registrationCost`, `minimumTip`, `bookingWidth` | The three parameters, fixed at creation | five | Zero; written only when positive. The width is below the processing window |
| Output reference (`OutRef`) | The identity of the transaction that made the output and the output's position in it | What a transaction spends or reads | five | Required on a spent or read input |
| Transaction | `referenceInputs`, `validity`, `fee`, `donation` | Outputs read and not spent; the finite interval, lower end included and upper end excluded; the ledger fee; the treasury donation | five | Empty, none, zero, zero; a zero donation is not written |
| Registry state token | Policy and asset name | The exact identity a rejection checks on the output it reads | five | The existing registry identity names it |
| Registration request | Refund address, destination, booked time, registration cost, declared tip, carrier ada, approval, tag | What a registration holds and promises | six | The booked time is the upper end of the booking interval |
| Request pool | The pending requests of a world | Requests booked and neither folded, rejected nor retracted | six | Empty at genesis |
| Termination request | Active token, declared tip, carrier ada, approval, tag | What a termination holds; no refund address, no time | seven | |
| World | The registry state with the pool | What the statements quantify over | six | The registry state alone for every existing row |
| Treasury recipient | A recipient in the payment vocabulary | Owed the donation | ten | |

Validation and invariants. An old input without these fields reads as the defaults, so every existing question, scenario and corpus row means what it meant
and a fold's question is exactly what it was. Every step preserves the three parameters exactly as it preserves the pins. A request is pending only if a booking
produced it. The supply of a token kind counts the tokens held at the application's custody and the tokens held by pending requests until the fold burns them.

## Functions (named here, signed before dispatch)

| Name | Slice | Constraint |
|---|---|---|
| `applyTx` | five | Removes spent inputs from the unspent set, adds the outputs, leaves reference inputs in place; refuses a reference to an output not in the set |
| `balanced` | five | Inputs plus mint equal outputs plus donation plus fee, for native assets and lovelace |
| `exactContents` | six, seven | A request holds exactly the amounts its kind allows; a tip of at least the minimum is declared apart from the held value |
| `book` | six, seven | Registration: interval no wider than the maximum, booked time its upper end, exact contents, tag minted once. Termination: the token moves from custody into the request, exact contents, approval bound to terminate, key, destination |
| `rejectionAccepted` | eight | Over a transaction and the unspent set: state output referenced with the exact token, no state output spent, request inputs distinct, one interval, every member admitted by a current mismatch or by expiry, no termination |
| `refundObligations` | nine | Held minus tip to each refund address, summed per address, approval included; a retraction returns everything held |
| `foldObligations` | ten | The registration cost to the treasury, the tip to the processor, the carrier with the token; a termination burns the token and the approval and donates held minus tip |

A statement is declared where the plan puts it, never beside its definition in `Economics`, so the axiom gate and the register cover it.

## Slice five: signed rows

Names and shapes the writer keeps; anything not stated is the writer's to choose, and a name that another slice or the paper depends on is stated here.

| Where | Declaration | Shape and constraint |
|---|---|---|
| `Singular.Model` | `OutRef` | `tx : Nat`, `index : Nat`; serialized; equality decidable |
| `Singular.Model` | `Interval` | `lower upper : Nat`, the half-open interval from `lower` included to `upper` excluded; `Interval.width`, `Interval.valid` (`lower < upper`) and `Interval.contains` |
| `Singular.Model` | `TokenId` | `policy name : Nat`; `Config.stateToken` is the registry's state token identity, read off `registryId` |
| `Singular.Model` | `Config.registrationCost`, `Config.minimumTip`, `Config.bookingWidth` | `Nat`, default 0; omitted from the written form when 0, read as 0 when absent, so no existing row changes; `Config.bookingWidthSized` is `bookingWidth < processTime` and is a predicate, not a decoding rule |
| `Singular.Model` | `onlyRootChanged` | Extended with the three parameters |
| `Singular.Model` | `TxInput.ref`, `TxInput.stateToken` | The output the input spends, and the state token identity it presents; defaults none |
| `Singular.Model` | `TxOutput.stateToken` | The state token identity the output presents; the state output of every built fold names `Config.stateToken` |
| `Singular.Model` | `Tx.referenceInputs`, `Tx.validity`, `Tx.fee`, `Tx.donation` | Outputs read and not spent (default empty), the validity interval (default none), the ledger fee (default 0), the treasury donation (default 0); each omitted from the written form at its default, so a zero donation is never written |
| `Singular.Economics` | `Utxo` | A list of output references with the outputs they name |
| `Singular.Economics` | `inputsPresent` | `Utxo → Tx → Option String`; `none` when every spent input and every reference input names an output of the set; otherwise a reason that tells a missing spent input from a missing reference input |
| `Singular.Economics` | `applyTx` | `Utxo → Nat → Tx → Utxo`; the number is the new transaction's identity; removes the spent inputs, adds the outputs at that identity and their positions, leaves every reference input in place |
| `Singular.Economics` | `balanced` | `Utxo → Tx → Bool`; the values of the spent inputs are read from the set, never from the input's own claim; lovelace in equals lovelace out plus donation plus fee; assets in plus mint equal assets out; state tokens in equal state tokens out |
| `Singular.Statements` | `parameters_preserved_by_fold` | Statement 1, for a step and for a batch |
| `Singular.Statements` | `reference_inputs_not_consumed`, `spent_reference_refused`, `balanced_transaction_creates_no_value`, `zero_donation_omits_field` | The supporting statements of slice five, worded in the plan |

The driver protocol version moves only if a declared question's written form changes; with every new field omitted at its default none does, and the writer says so in the first checkpoint.
