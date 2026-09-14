---
marp: true
theme: default
size: 16:9
paginate: true
title: Singular — a registry explained through naming
description: Ten slides on uniqueness, recovery and permanent retirement; preprod demonstration pending.
style: |
  section { background: #f7f5ef; color: #182b3a; font-family: Arial, sans-serif; padding: 64px 76px; font-size: 32px; }
  h1 { color: #123f48; font-size: 48px; line-height: 1.12; letter-spacing: -1px; margin-bottom: 40px; }
  strong { color: #087b78; }
  p { line-height: 1.45; }
  pre { background: #e9eeea; border: 0; border-radius: 10px; padding: 22px; }
  pre code { font-size: 23px; line-height: 1.4; color: #123f48; }
  table { font-size: 25px; margin: 20px 0 32px; }
  th { background: #e9eeea; color: #123f48; }
  th, td { padding: 16px 20px; }
  section::after { color: #678078; font-size: 18px; }
---

# A name needs shared rules

Two tokens can both say **alice**.

Singular gives applications a registry where a name has **one active identity**.

<!--
Open with the question a payer would ask: which alice counts? Token text alone cannot answer it. A minting policy can enforce uniqueness; Singular offers a reusable registry with its own authenticated namespace. Another registry can still have its own alice.

The argument of this talk: a small naming application already needs this shared identity boundary. It gives us a concrete reason for the registry before introducing the larger KERI consumer.

Read: [Naming walkthrough](https://github.com/lambdasistemi/singular/blob/d840559a04848675c70eae4febae51c48c619257/docs/naming-demo.md). The competing-claim example accepts the first valid fold and refuses the second with occupied-key.

Source and Lean revision for the technical claims throughout these slides: d840559a04848675c70eae4febae51c48c619257. Preprod demonstration identities remain to be filled on slide 9.
-->

---

# One root makes registration checkable

The registry commits its map to **one on-chain root**.

Anyone can submit a fold.
The validator checks its proofs and the resulting root.

<!--
An MPF trie is an authenticated map: its root commits to the entries, and a proof lets the validator check an entry or its absence. A fold applies pending requests to that map. The application certifies a proposal; the fold checks that its key can actually be inserted.

Requests may wait while the registry changes. Approval does not reserve a spelling. Uniqueness is settled against the root being spent by the successful fold.

There is no privileged folder. Permissionless access still requires a valid transaction and a fee payer; it makes no promise that someone will submit the transaction promptly.

Read: [Requests and folding](https://github.com/lambdasistemi/singular/blob/d840559a04848675c70eae4febae51c48c619257/docs/lifecycle.md) and [Registry/application diagram](https://github.com/lambdasistemi/singular/blob/d840559a04848675c70eae4febae51c48c619257/README.md). These describe the design; they do not supply throughput measurements.
-->

---

# Share identity. Keep application state local.

| Singular registry | Successful fold | Naming application output |
| :--- | :---: | :--- |
| **alice → Active** | **mint →** | **Representative NFT** |
| Authenticated root | | Controller + recovery commitment |
| | | Quorum + payment destination |

The application can change its data while keeping the same NFT.

<!--
The arrow is the successful registration fold: the registry advances and the representative is minted into the certified application output. While the name is active, that output carries the NFT and the naming datum. During retirement the NFT moves into request custody; completion burns it.

Ordinary payment-destination maintenance spends the application's output and creates its successor without changing the registry root. The controller must sign. Control, next-control commitment and retirement quorum are preserved.

Read: [Architecture](https://github.com/lambdasistemi/singular/blob/d840559a04848675c70eae4febae51c48c619257/README.md); [application.ak, maintain](https://github.com/lambdasistemi/singular/blob/d840559a04848675c70eae4febae51c48c619257/naming-onchain/validators/application.ak). In the source, maintain explicitly compares the successor's control_address, next_control_commitment and retirement_quorum with the consumed record.

The diagram uses the model's Active label. The concrete implementation stores the representative value in its authenticated map.
-->

---

# Naming gives the registry a small, useful job

**alice** has a controller and an optional payment destination.

Keep routing current. Recover control. End the name permanently.

That lifecycle makes Singular understandable before KERI.

<!--
Introduce the four fields only as needed: control address, next-control commitment, retirement quorum and payment destination. The destination is routing data, distinct from the authority that controls the record.

KERI introduces identifiers, key-event logs, witnesses and watchers. Naming lets the audience see the registry/application boundary through familiar actions first. This is a teaching choice, not evidence of completed KERI integration.

Read: [Naming fields and finite-model limits](https://github.com/lambdasistemi/singular/blob/d840559a04848675c70eae4febae51c48c619257/docs/naming-demo.md); [Naming market evaluation](https://gist.github.com/paolino/b99b73135efea14befe687029418f2c1). The comparison recommends keeping naming as a maintained reference application. It does not establish demand for a separate naming business.

The value lies in the combination of rules. Permissionless registration, precommitted recovery and permanent retirement each have precedents; we need not claim invention to demonstrate usefulness.
-->

---

# Anyone can fold an approved claim

**Claim → pending request → fold → representative NFT**

The first valid fold gets the name.
A competing claim cannot take it.

<!--
Use alice twice: both claims can wait, but after the first valid absent-key fold, the competing insertion is refused. The controller's claim approval does not create a registrar role or reserve the name in advance. Successful folding creates the representative in the application output.

The model also lets the claimant cancel an unfulfilled claim with separate authorization, copying the refund address stored in its Insert commitment. Original Insert approval alone cannot cancel it. This model story does not itself establish the entire connected Insert-to-Withdraw ledger path; the retained LC ledger fixtures are narrower evidence.

Read: [Claim and cancellation lifecycle](https://github.com/lambdasistemi/singular/blob/d840559a04848675c70eae4febae51c48c619257/docs/naming-lifecycle.md); [application.ak, fold](https://github.com/lambdasistemi/singular/blob/d840559a04848675c70eae4febae51c48c619257/naming-onchain/validators/application.ak); [representative.ak, MintRepresentative](https://github.com/lambdasistemi/singular/blob/d840559a04848675c70eae4febae51c48c619257/naming-onchain/validators/representative.ak).

Optional model walkthrough: [Simulator](https://lambdasistemi.github.io/singular/simulator/), choose m1-naming, queue two claims and fold each. The presentation's ledger demo is the preprod sequence on slide 9.
-->

---

# Recover without the old key

Commit to the next controller **before** losing the current key.

Reveal that controller. Sign with its key.
Keep the name and representative NFT.

<!--
The backup key must survive. Recovery checks the revealed canonical Cardano address against the stored, domain-separated commitment. It requires the revealed address's payment-key signer, installs that controller, and stores a fresh next commitment. The old controller need not sign; its former authority no longer permits maintenance after recovery.

The validator checks:
expect computed == record.next_control_commitment
expect has(extra_signatories, revealed_hash)

Read: [application.ak, recover](https://github.com/lambdasistemi/singular/blob/d840559a04848675c70eae4febae51c48c619257/naming-onchain/validators/application.ak); [Recovery runner and observations](https://github.com/lambdasistemi/singular/blob/d840559a04848675c70eae4febae51c48c619257/docs/recovery-retirement.md). The runner describes both successful handover and refusal of wrong reveals, wrong signers, replay and old-key maintenance.

Proved in the model: recovery_accepts_without_old_controller and old_controller_dead_after_recovery in [NamingLifecycleStatements.lean](https://github.com/lambdasistemi/singular/blob/d840559a04848675c70eae4febae51c48c619257/lean/Singular/NamingLifecycleStatements.lean). These statements prove concrete model cases; they are not a universal correctness proof of the compiled validator or hash implementation.
-->

---

# A quorum can retire, never take over

The controller **or** the fixed quorum can end the name.

Quorum authority permits retirement only.
It cannot redirect payments or recover control.

<!--
The quorum and threshold are fixed at registration. Retirement counts distinct signed members:
threshold > 0 && naming.distinct_count(signed) >= threshold

The quorum is trusted with a consequential power: it can retire a name even against the controller's wishes. It cannot use its quorum role to redirect the destination or change the controller. It is not a death oracle, and it does not supply social recovery. A member who independently holds a controller key has that separate authority.

Read: [application.ak, retire / quorum_authorized / maintain](https://github.com/lambdasistemi/singular/blob/d840559a04848675c70eae4febae51c48c619257/naming-onchain/validators/application.ak); [Retirement runner](https://github.com/lambdasistemi/singular/blob/d840559a04848675c70eae4febae51c48c619257/docs/recovery-retirement.md). The documented rows distinguish controller-alone from quorum-alone authorization and test insufficient quorum and attempted takeover/redirection.

Model examples: controller_and_quorum_retirement_accept, quorum_only_control_takeover_refused and quorum_only_payment_redirection_refused in [NamingLifecycleStatements.lean](https://github.com/lambdasistemi/singular/blob/d840559a04848675c70eae4febae51c48c619257/lean/Singular/NamingLifecycleStatements.lean). The market review found the separate retirement-only quorum to be the strongest specific distinction; that search is not proof that no equivalent exists.
-->

---

# Over means the name stays retired

**Active → completion-only custody → Over**

Anyone may complete the retirement and burn the NFT.
The spelling remains occupied permanently.

<!--
Initiation and completion are separate transactions. Pending retirement holds the representative in custody; it is not yet Over. Completion spends the paired request and authenticated registry state, applies the retirement update, and burns the exact representative. No controller or quorum approval is required for completion; a fee input still needs its owner's witness.

The custody validator checks:
expect held_burned_exactly_once(claim, tx)
expect request_binds_burn(claim, stateIn, requestIn)

Read: [retirement_custody.ak](https://github.com/lambdasistemi/singular/blob/d840559a04848675c70eae4febae51c48c619257/naming-onchain/validators/retirement_custody.ak); [Completion and refusal evidence](https://github.com/lambdasistemi/singular/blob/d840559a04848675c70eae4febae51c48c619257/onchain-release/README.md).

Model: [over_terminal](https://github.com/lambdasistemi/singular/blob/d840559a04848675c70eae4febae51c48c619257/docs/theorems.md) and [retirement_pending_then_over / re_registration_after_over_refused](https://github.com/lambdasistemi/singular/blob/d840559a04848675c70eae4febae51c48c619257/lean/Singular/NamingLifecycleStatements.lean). The manifest retains a missing general custody-escape theorem; the concrete custody examples do not fill that proof gap.

Naming forbids Delete, although the generic registry has a Delete operation. Permanent occupation applies within this registry. Retirement cannot stop payments sent directly to an already saved raw address.
-->

---

# Follow one name on preprod

**preprod run pending (#78)**

Claim → fold + NFT → recover → retire → complete to Over.

Each step will link to its preprod transaction.

<!--
Use one connected name lifecycle on preprod. Fill each transaction id from the real run; retain the pending label until that run exists.

| Step | Transaction id / link | Observable result |
| --- | --- | --- |
| Claim | PENDING | Claim and pending request |
| Fold | PENDING | Active registry entry; representative in application output |
| Recover | PENDING | Same representative; new controller and fresh commitment |
| Retire | PENDING | Representative in completion-only custody; record consumed |
| Complete to Over | PENDING | Paired update; exact burn; permanently occupied key |

Run identity: name PENDING; registry identity PENDING; representative policy/name PENDING; release/archive identity PENDING; implementation and Lean revisions PENDING. State which retirement route the displayed transaction uses. Keep the alternative route and relevant refusal evidence separately identified.

Delivery dependency: [#78](https://github.com/lambdasistemi/singular/issues/78). At the 14 September 2026 readback, its body covers external-node capability and explicitly excludes deployment and the naming journey. Closing that ticket alone is not evidence of this preprod sequence.

Supporting devnet evidence only: [v0.4.0](https://github.com/lambdasistemi/singular/releases/tag/v0.4.0) ships finite lifecycle rows. [#91](https://github.com/lambdasistemi/singular/issues/91) records three archive runners passing with CANDIDATE_SHA=d840559a04848675c70eae4febae51c48c619257; archive-only replay without that override remains a reported defect. [Archive runbook](https://github.com/lambdasistemi/singular/blob/d840559a04848675c70eae4febae51c48c619257/onchain-release/README.md). No new ledger run was performed to prepare these slides.

Wallet integration, an authenticated resolver service and mainnet deployment remain outside the demonstrated product.
-->

---

# The next consumer can reuse this lifecycle

Preserve **control, recovery and permanent retirement**.
Let a consumer script validate the data.

Payment naming first. **cardano-keri key-state next.**

<!--
Close on the argument: a simple name already needs unique identity, independent state, recovery and a permanent ending. That is enough to give the registry a useful job. The next consumer can build on the same boundary.

Planned direction: [Programmable naming, #97](https://github.com/lambdasistemi/singular/issues/97). Replace the payment destination with a consumer-defined value. Require the consumer's value validator to execute at registration and maintenance through a pinned script withdrawal, following the registry's existing consumer mechanism.

This is future work. The issue leaves the validator's placement open: a record field or an application parameter. Lean must be generalized before dependent implementation is accepted. The second instance does not yet establish KERI conformance.

The preprod demonstration on slide 9 is a delivery requirement in its own right; it must not be deferred to this future abstraction.
-->
