# Functions

Retroactive record, written 2026-09-15 from PR #106 merged at
`f558d0e8fc916eef494fffcef09cfe2ac5582b8e`.

## Deployment commands

No bodies here.

| Function | Arguments | Result | Constraint |
| --- | --- | --- | --- |
| `deploy` | joiner wallet, blueprints | manifest | Publishes reference scripts and boots the registry once; refuses a second run against the same manifest. |
| `verify` | manifest, node | accept or refuse | Reference outputs exist with pinned hashes; the state output carries the cage token. |
| attached register | manifest, spelling | journey result | Exact spelling bytes; held spelling submits the duplicate, requires the phase-2 refusal, checks unchanged root and counts, and stops. |
| attached recovery | manifest | journey result | Explicit fixture spelling; recovered controller maintained. |
| attached retirement | manifest | journey result | Explicit fixture spelling through permissionless Over completion. |

## Library behaviour

| Function | Arguments | Result | Constraint |
| --- | --- | --- | --- |
| registry token derivation | seed outRef | token identity | Matches the deployed state credential. |
| compiled identity comparison | blueprints, manifest | accept or refuse | Rejects substituted policies. |
| reference resolution | recorded hashes, chain | live outputs | Resolves by hash; counts every publisher address. |
| state location | cage token, chain | state output | Quantity-one token output. |
| mirror check | mirror root, live state | accept or error | Compared before funding; never rewrites the root. |
| retract at tip | request window, chain tip | validity bounds | Lower bound from a fresh tip each attempt; closing bound preserved, never widened. |
| confirmation observation | submitted transaction | confirmation | Polls for the output; no fixed sleep. |

## Attach gate

Deploy once on a shared devnet; count; run all three attached
journeys; repeat the explicit spelling for the duplicate refusal;
run one fresh register without the manifest and require both
counters to increase.
