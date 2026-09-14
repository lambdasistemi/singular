---
marp: true
theme: default
size: 16:9
paginate: true
title: Singular — one name, through its life
description: Eleven visual user stories about claiming, maintaining, recovering and retiring a name; preprod demonstration pending.
style: |
  section { background: #f7f5ef; color: #182f3b; font-family: Arial, sans-serif; padding: 40px 70px; justify-content: flex-start; }
  .eyebrow { color: #087f78; font-size: 18px; font-weight: 700; letter-spacing: 2px; margin: 0 0 16px; }
  h1 { color: #182f3b; font-size: 31px; line-height: 1.25; letter-spacing: -1px; margin: 0 0 18px; }
  svg { display: block; width: 100%; height: auto; max-height: 410px; }
  section::after { color: #647780; font-size: 17px; }
---

<div class="eyebrow">THE REAL DIRECTION: REGISTRY → KERI</div>

# As a KERI builder, I want a shared registry<br>so that I can build on a reusable identity layer.

<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1120 460" role="img" aria-label="The Singular registry is the foundation for the target KERI consumer. Naming is a simpler surrogate application used to demonstrate the registry boundary and lifecycle; KERI integration remains planned." style="font-family:Arial,sans-serif"><title>The Singular registry is the foundation for the target KERI consumer. Naming is a simpler surrogate application used to demonstrate the registry boundary and lifecycle; KERI integration remains planned.</title><rect x="30" y="47" width="353" height="173" rx="22" fill="#dceee7" stroke="none" stroke-width="2"/><text x="206" y="100" font-size="32" fill="#182f3b" font-weight="700" text-anchor="middle">Singular registry</text><text x="206" y="158" font-size="21" fill="#087f78" font-weight="600" text-anchor="middle">Shared identity foundation</text><path d="M406 130 L709 130" fill="none" stroke="#087f78" stroke-width="4" stroke-linecap="round" stroke-dasharray="9 9"/><path d="M697 122 L709 130 L697 138" fill="none" stroke="#087f78" stroke-width="4" stroke-linecap="round" stroke-linejoin="round"/><text x="557" y="93" font-size="23" fill="#087f78" font-weight="600" text-anchor="middle">Product direction</text><rect x="736" y="47" width="353" height="173" rx="22" fill="#ffffff" stroke="#087f78" stroke-width="2"/><text x="913" y="100" font-size="32" fill="#182f3b" font-weight="700" text-anchor="middle">cardano-keri</text><text x="913" y="147" font-size="24" fill="#087f78" font-weight="600" text-anchor="middle">Target consumer</text><text x="913" y="191" font-size="20" fill="#647780" font-weight="400" text-anchor="middle">Integration planned</text><path d="M206 221 L206 330" fill="none" stroke="#087f78" stroke-width="4" stroke-linecap="round"/><path d="M206 330 L410 330" fill="none" stroke="#087f78" stroke-width="4" stroke-linecap="round"/><path d="M398 322 L410 330 L398 338" fill="none" stroke="#087f78" stroke-width="4" stroke-linecap="round" stroke-linejoin="round"/><rect x="435" y="257" width="654" height="163" rx="22" fill="#ffffff" stroke="none" stroke-width="2"/><text x="762" y="305" font-size="28" fill="#182f3b" font-weight="600" text-anchor="middle">Naming: the surrogate application</text><text x="762" y="351" font-size="24" fill="#087f78" font-weight="600" text-anchor="middle">Claim · Update · Recover · Retire</text><text x="762" y="390" font-size="21" fill="#647780" font-weight="400" text-anchor="middle">A smaller story to demonstrate the foundation</text></svg>

<!--
Open with the actual product direction: Singular provides a registry foundation for on-chain support of cardano-keri. Naming is the surrogate application chosen to make the registry boundary and lifecycle understandable through a small familiar story. It is not the ultimate product objective, a naming-business pitch, or evidence that KERI has been integrated. The branch shows two consumers of a shared foundation, not a naming-to-KERI migration pipeline.

The naming stories demonstrate useful registry and consumer responsibilities. They do not assert that KERI inherits every naming authorization rule unchanged. KERI-specific values, rules and conformance still require their own consumer model and implementation.

Close on the argument: a simple name already needs unique identity, independent state, recovery and a permanent ending. That is enough to give the registry a useful job. The next consumer can build on the same boundary.

Planned direction: [Programmable naming, #97](https://github.com/lambdasistemi/singular/issues/97). Replace the payment destination with a consumer-defined value. Require the consumer's value validator to execute at registration and maintenance through a pinned script withdrawal, following the registry's existing consumer mechanism.

This is future work. The issue leaves the validator's placement open: a record field or an application parameter. Lean must be generalized before dependent implementation is accepted. The second instance does not yet establish KERI conformance.

The preprod demonstration on slide 10 is a delivery requirement in its own right; it must not be deferred to this future abstraction.
-->

---

<div class="eyebrow">PAYING SOMEONE</div>

# As a payer, I want to identify the right alice<br>so that I can choose the intended recipient.

<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1120 460" role="img" aria-label="A payer sees two tokens called alice. One active identity within a chosen registry distinguishes the name." style="font-family:Arial,sans-serif"><title>A payer sees two tokens called alice. One active identity within a chosen registry distinguishes the name.</title><circle cx="95" cy="194" r="19" fill="#087f78"/><path d="M60 250 Q60 221 95 221 Q130 221 130 250" fill="#087f78"/><text x="95" y="303" font-size="24" fill="#182f3b" font-weight="400" text-anchor="middle">Payer</text><path d="M145 220 L274 220" fill="none" stroke="#087f78" stroke-width="4" stroke-linecap="round"/><path d="M262 212 L274 220 L262 228" fill="none" stroke="#087f78" stroke-width="4" stroke-linecap="round" stroke-linejoin="round"/><rect x="300" y="44" width="310" height="160" rx="22" fill="#ffffff" stroke="none" stroke-width="2"/><text x="455" y="86" font-size="20" fill="#647780" font-weight="400" text-anchor="middle">Token label</text><text x="455" y="150" font-size="48" fill="#182f3b" font-weight="700" text-anchor="middle">alice</text><rect x="300" y="238" width="310" height="160" rx="22" fill="#ffffff" stroke="none" stroke-width="2"/><text x="455" y="280" font-size="20" fill="#647780" font-weight="400" text-anchor="middle">Another token label</text><text x="455" y="344" font-size="48" fill="#182f3b" font-weight="700" text-anchor="middle">alice</text><text x="665" y="235" font-size="72" fill="#946313" font-weight="700" text-anchor="middle">?</text><rect x="745" y="128" width="345" height="176" rx="22" fill="#dceee7" stroke="none" stroke-width="2"/><text x="773" y="170" font-size="20" fill="#647780" font-weight="400" text-anchor="start">Within one registry</text><text x="773" y="229" font-size="47" fill="#182f3b" font-weight="700" text-anchor="start">alice</text><text x="773" y="271" font-size="19" fill="#087f78" font-weight="600" text-anchor="start">Singular registry</text><circle cx="1055" cy="271" r="23" fill="#087f78"/><path d="M1044 271 L1052 279 L1067 261" fill="none" stroke="white" stroke-width="4" stroke-linecap="round"/><rect x="774.5" y="345" width="285" height="44" rx="22" fill="#dceee7" stroke="none" stroke-width="2"/><text x="917" y="375" font-size="20" fill="#087f78" font-weight="600" text-anchor="middle">One active identity</text></svg>

<!--
Open with the question a payer would ask: which alice counts? Token text alone cannot answer it. A minting policy can enforce uniqueness; Singular offers a reusable registry with its own authenticated namespace. Another registry can still have its own alice.

The argument of this talk: a small naming application already needs this shared identity boundary. It gives us a concrete reason for the registry before introducing the larger KERI consumer.

Read: [Naming walkthrough](https://github.com/lambdasistemi/singular/blob/d840559a04848675c70eae4febae51c48c619257/docs/naming-demo.md). The competing-claim example accepts the first valid fold and refuses the second with occupied-key.

Source and Lean revision for the technical claims throughout these slides: d840559a04848675c70eae4febae51c48c619257. Preprod demonstration identities remain to be filled on slide 10.
-->

---

<div class="eyebrow">CLAIMING A NAME</div>

# As a claimant, I want to register an available name<br>so that nobody else can claim it in this registry.

<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1120 460" role="img" aria-label="Two approved claims compete for alice. The first valid fold registers the name; the later competing fold is refused." style="font-family:Arial,sans-serif"><title>Two approved claims compete for alice. The first valid fold registers the name; the later competing fold is refused.</title><circle cx="78" cy="99" r="19" fill="#087f78"/><path d="M43 155 Q43 126 78 126 Q113 126 113 155" fill="#087f78"/><text x="78" y="206" font-size="24" fill="#182f3b" font-weight="400" text-anchor="middle">Alice</text><circle cx="78" cy="297" r="19" fill="#647780"/><path d="M43 353 Q43 324 78 324 Q113 324 113 353" fill="#647780"/><text x="78" y="405" font-size="22" fill="#182f3b" font-weight="400" text-anchor="middle">Rival</text><rect x="170" y="48" width="265" height="138" rx="22" fill="#ffffff" stroke="none" stroke-width="2"/><text x="302" y="92" font-size="38" fill="#182f3b" font-weight="700" text-anchor="middle">alice</text><text x="302" y="145" font-size="21" fill="#647780" font-weight="400" text-anchor="middle">Approved claim</text><rect x="170" y="245" width="265" height="138" rx="22" fill="#ffffff" stroke="none" stroke-width="2"/><text x="302" y="289" font-size="38" fill="#182f3b" font-weight="700" text-anchor="middle">alice</text><text x="302" y="342" font-size="21" fill="#647780" font-weight="400" text-anchor="middle">Approved claim</text><path d="M458 116 L702 116" fill="none" stroke="#087f78" stroke-width="4" stroke-linecap="round"/><path d="M690 108 L702 116 L690 124" fill="none" stroke="#087f78" stroke-width="4" stroke-linecap="round" stroke-linejoin="round"/><text x="580" y="78" font-size="19" fill="#087f78" font-weight="600" text-anchor="middle">First valid registration</text><rect x="728" y="38" width="350" height="176" rx="22" fill="#dceee7" stroke="none" stroke-width="2"/><text x="756" y="80" font-size="20" fill="#647780" font-weight="400" text-anchor="start">Registered to Alice</text><text x="756" y="139" font-size="47" fill="#182f3b" font-weight="700" text-anchor="start">alice</text><text x="756" y="181" font-size="19" fill="#087f78" font-weight="600" text-anchor="start">Singular registry</text><path d="M458 315 L702 315" fill="none" stroke="#b54c3a" stroke-width="4" stroke-linecap="round"/><path d="M690 307 L702 315 L690 323" fill="none" stroke="#b54c3a" stroke-width="4" stroke-linecap="round" stroke-linejoin="round"/><circle cx="753" cy="315" r="23" fill="#f5e1d9"/><path d="M745 307 L761 323" fill="none" stroke="#b54c3a" stroke-width="4" stroke-linecap="round"/><path d="M745 323 L761 307" fill="none" stroke="#b54c3a" stroke-width="4" stroke-linecap="round"/><text x="907" y="324" font-size="25" fill="#b54c3a" font-weight="600" text-anchor="middle">Already occupied</text><rect x="409" y="400" width="344" height="44" rx="22" fill="#dceee7" stroke="none" stroke-width="2"/><text x="581" y="430" font-size="20" fill="#087f78" font-weight="600" text-anchor="middle">Anyone can finalize it</text></svg>

<!--
Use alice twice: both claims can wait, but after the first valid absent-key fold, the competing insertion is refused. The controller's claim approval does not create a registrar role or reserve the name in advance. Successful folding creates the representative in the application output.

The model also lets the claimant cancel an unfulfilled claim with separate authorization, copying the refund address stored in its Insert commitment. Original Insert approval alone cannot cancel it. This model story does not itself establish the entire connected Insert-to-Withdraw ledger path; the retained LC ledger fixtures are narrower evidence.

Read: [Claim and cancellation lifecycle](https://github.com/lambdasistemi/singular/blob/d840559a04848675c70eae4febae51c48c619257/docs/naming-lifecycle.md); [application.ak, fold](https://github.com/lambdasistemi/singular/blob/d840559a04848675c70eae4febae51c48c619257/naming-onchain/validators/application.ak); [representative.ak, MintRepresentative](https://github.com/lambdasistemi/singular/blob/d840559a04848675c70eae4febae51c48c619257/naming-onchain/validators/representative.ak).

Optional model walkthrough: [Simulator](https://lambdasistemi.github.io/singular/simulator/), choose m1-naming, queue two claims and fold each. The presentation's ledger demo is the preprod sequence on slide 10.

An MPF trie is an authenticated map: its root commits to the entries, and a proof lets the validator check an entry or its absence. A fold applies pending requests to that map. The application certifies a proposal; the fold checks that its key can actually be inserted.

Requests may wait while the registry changes. Approval does not reserve a spelling. Uniqueness is settled against the root being spent by the successful fold.

There is no privileged folder. Permissionless access still requires a valid transaction and a fee payer; it makes no promise that someone will submit the transaction promptly.

Read: [Requests and folding](https://github.com/lambdasistemi/singular/blob/d840559a04848675c70eae4febae51c48c619257/docs/lifecycle.md) and [Registry/application diagram](https://github.com/lambdasistemi/singular/blob/d840559a04848675c70eae4febae51c48c619257/README.md). These describe the design; they do not supply throughput measurements.
-->

---

<div class="eyebrow">CHANGING A PAYMENT ADDRESS</div>

# As a name owner, I want to update my payment address<br>so that I can change wallets and keep my name.

<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1120 460" role="img" aria-label="Alice changes her payment destination with her controller key. Her registered name and representative stay the same." style="font-family:Arial,sans-serif"><title>Alice changes her payment destination with her controller key. Her registered name and representative stay the same.</title><rect x="34" y="139" width="288" height="176" rx="22" fill="#dceee7" stroke="none" stroke-width="2"/><text x="62" y="181" font-size="20" fill="#647780" font-weight="400" text-anchor="start">Same name</text><text x="62" y="240" font-size="47" fill="#182f3b" font-weight="700" text-anchor="start">alice</text><text x="62" y="282" font-size="19" fill="#087f78" font-weight="600" text-anchor="start">Singular registry</text><circle cx="153" cy="375" r="17" fill="none" stroke="#087f78" stroke-width="7"/><path d="M170 375 L214 375" fill="none" stroke="#087f78" stroke-width="4" stroke-linecap="round"/><path d="M199 375 L199 389" fill="none" stroke="#087f78" stroke-width="4" stroke-linecap="round"/><path d="M214 375 L214 389" fill="none" stroke="#087f78" stroke-width="4" stroke-linecap="round"/><text x="175" y="433" font-size="22" fill="#087f78" font-weight="600" text-anchor="middle">Alice signs</text><path d="M349 229 L494 229" fill="none" stroke="#087f78" stroke-width="4" stroke-linecap="round"/><path d="M482 221 L494 229 L482 237" fill="none" stroke="#087f78" stroke-width="4" stroke-linecap="round" stroke-linejoin="round"/><rect x="560" y="101" width="96" height="64" rx="10" fill="none" stroke="#647780" stroke-width="2"/><rect x="620" y="119" width="46" height="29" rx="6" fill="#f7f5ef" stroke="#647780" stroke-width="2"/><circle cx="635" cy="133" r="4" fill="#647780"/><text x="608" y="204" font-size="23" fill="#647780" font-weight="600" text-anchor="middle">Old destination</text><rect x="888" y="101" width="96" height="64" rx="10" fill="none" stroke="#087f78" stroke-width="2"/><rect x="948" y="119" width="46" height="29" rx="6" fill="#f7f5ef" stroke="#087f78" stroke-width="2"/><circle cx="963" cy="133" r="4" fill="#087f78"/><text x="936" y="204" font-size="23" fill="#087f78" font-weight="600" text-anchor="middle">New destination</text><path d="M707 132 L837 132" fill="none" stroke="#087f78" stroke-width="4" stroke-linecap="round"/><path d="M825 124 L837 132 L825 140" fill="none" stroke="#087f78" stroke-width="4" stroke-linecap="round" stroke-linejoin="round"/><text x="772" y="100" font-size="22" fill="#087f78" font-weight="600" text-anchor="middle">Update</text><path d="M608 210 L608 288" fill="none" stroke="#647780" stroke-width="4" stroke-linecap="round"/><path d="M936 210 L936 288" fill="none" stroke="#087f78" stroke-width="4" stroke-linecap="round"/><rect x="479" y="288" width="580" height="89" rx="22" fill="#ffffff" stroke="none" stroke-width="2"/><text x="769" y="325" font-size="23" fill="#182f3b" font-weight="400" text-anchor="middle">Same control · Same recovery</text><text x="769" y="359" font-size="23" fill="#182f3b" font-weight="400" text-anchor="middle">Same retirement group</text></svg>

<!--
The arrow is the successful registration fold: the registry advances and the representative is minted into the certified application output. While the name is active, that output carries the NFT and the naming datum. During retirement the NFT moves into request custody; completion burns it.

Ordinary payment-destination maintenance spends the application's output and creates its successor without changing the registry root. The controller must sign. Control, next-control commitment and retirement quorum are preserved.

Read: [Architecture](https://github.com/lambdasistemi/singular/blob/d840559a04848675c70eae4febae51c48c619257/README.md); [application.ak, maintain](https://github.com/lambdasistemi/singular/blob/d840559a04848675c70eae4febae51c48c619257/naming-onchain/validators/application.ak). In the source, maintain explicitly compares the successor's control_address, next_control_commitment and retirement_quorum with the consumed record.

The diagram uses the model's Active label. The concrete implementation stores the representative value in its authenticated map.

Introduce the four fields only as needed: control address, next-control commitment, retirement quorum and payment destination. The destination is routing data, distinct from the authority that controls the record.

KERI introduces identifiers, key-event logs, witnesses and watchers. Naming lets the audience see the registry/application boundary through familiar actions first. This is a teaching choice, not evidence of completed KERI integration.

Read: [Naming fields and finite-model limits](https://github.com/lambdasistemi/singular/blob/d840559a04848675c70eae4febae51c48c619257/docs/naming-demo.md); [Naming market evaluation](https://gist.github.com/paolino/b99b73135efea14befe687029418f2c1). The comparison recommends keeping naming as a maintained reference application. It does not establish demand for a separate naming business.

The value lies in the combination of rules. Permissionless registration, precommitted recovery and permanent retirement each have precedents; we need not claim invention to demonstrate usefulness.

The wallet icons represent stored routing data, not a delivered wallet or resolver integration. Destination maintenance is separate from the five-step preprod sequence.
-->

---

<div class="eyebrow">PREPARING FOR KEY LOSS</div>

# As a name owner, I want to prepare a recovery key<br>so that losing my current key does not lock me out.

<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1120 460" role="img" aria-label="Before losing her key, Alice commits to a next controller and keeps its key safe." style="font-family:Arial,sans-serif"><title>Before losing her key, Alice commits to a next controller and keeps its key safe.</title><rect x="38" y="65" width="430" height="317" rx="22" fill="#ffffff" stroke="none" stroke-width="2"/><text x="253" y="109" font-size="24" fill="#647780" font-weight="400" text-anchor="middle">Before key loss</text><circle cx="231" cy="174" r="17" fill="none" stroke="#087f78" stroke-width="7"/><path d="M248 174 L292 174" fill="none" stroke="#087f78" stroke-width="4" stroke-linecap="round"/><path d="M277 174 L277 188" fill="none" stroke="#087f78" stroke-width="4" stroke-linecap="round"/><path d="M292 174 L292 188" fill="none" stroke="#087f78" stroke-width="4" stroke-linecap="round"/><text x="253" y="237" font-size="30" fill="#182f3b" font-weight="600" text-anchor="middle">Next controller key</text><rect x="140.5" y="297" width="225" height="44" rx="22" fill="#dceee7" stroke="none" stroke-width="2"/><text x="253" y="327" font-size="20" fill="#087f78" font-weight="600" text-anchor="middle">Keep it safe</text><path d="M489 219 L656 219" fill="none" stroke="#087f78" stroke-width="4" stroke-linecap="round"/><path d="M644 211 L656 219 L644 227" fill="none" stroke="#087f78" stroke-width="4" stroke-linecap="round" stroke-linejoin="round"/><text x="572" y="180" font-size="24" fill="#087f78" font-weight="600" text-anchor="middle">Commit</text><rect x="681" y="65" width="398" height="176" rx="22" fill="#dceee7" stroke="none" stroke-width="2"/><text x="709" y="107" font-size="20" fill="#647780" font-weight="400" text-anchor="start">alice’s record</text><text x="709" y="166" font-size="47" fill="#182f3b" font-weight="700" text-anchor="start">alice</text><text x="709" y="208" font-size="19" fill="#087f78" font-weight="600" text-anchor="start">Singular registry</text><rect x="706" y="267" width="348" height="90" rx="22" fill="#ffffff" stroke="none" stroke-width="2"/><text x="880" y="305" font-size="23" fill="#182f3b" font-weight="600" text-anchor="middle">Recovery set up</text><text x="880" y="338" font-size="20" fill="#647780" font-weight="400" text-anchor="middle">Bound to the next controller</text></svg>

<!--
Set up the story before showing the loss: the next-control commitment is installed before the current key disappears, including at registration. This is not recovery from an arbitrary new key after the fact. The next payment key must remain available.

The backup key must survive. Recovery checks the revealed canonical Cardano address against the stored, domain-separated commitment. It requires the revealed address's payment-key signer, installs that controller, and stores a fresh next commitment. The old controller need not sign; its former authority no longer permits maintenance after recovery.

The validator checks:
expect computed == record.next_control_commitment
expect has(extra_signatories, revealed_hash)

Read: [application.ak, recover](https://github.com/lambdasistemi/singular/blob/d840559a04848675c70eae4febae51c48c619257/naming-onchain/validators/application.ak); [Recovery runner and observations](https://github.com/lambdasistemi/singular/blob/d840559a04848675c70eae4febae51c48c619257/docs/recovery-retirement.md). The runner describes both successful handover and refusal of wrong reveals, wrong signers, replay and old-key maintenance.

Proved in the model: recovery_accepts_without_old_controller and old_controller_dead_after_recovery in [NamingLifecycleStatements.lean](https://github.com/lambdasistemi/singular/blob/d840559a04848675c70eae4febae51c48c619257/lean/Singular/NamingLifecycleStatements.lean). These statements prove concrete model cases; they are not a universal correctness proof of the compiled validator or hash implementation.
-->

---

<div class="eyebrow">RECOVERING CONTROL</div>

# As a name owner, I want to recover with my backup key<br>so that I regain control of the same name.

<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1120 460" role="img" aria-label="Alice loses the old controller key, reveals her precommitted next controller, and signs with its key. The same name continues under new control." style="font-family:Arial,sans-serif"><title>Alice loses the old controller key, reveals her precommitted next controller, and signs with its key. The same name continues under new control.</title><circle cx="84" cy="120" r="17" fill="none" stroke="#647780" stroke-width="7"/><path d="M101 120 L145 120" fill="none" stroke="#647780" stroke-width="4" stroke-linecap="round"/><path d="M130 120 L130 134" fill="none" stroke="#647780" stroke-width="4" stroke-linecap="round"/><path d="M145 120 L145 134" fill="none" stroke="#647780" stroke-width="4" stroke-linecap="round"/><path d="M56 74 L152 170" fill="none" stroke="#b54c3a" stroke-width="4" stroke-linecap="round"/><text x="106" y="215" font-size="22" fill="#b54c3a" font-weight="600" text-anchor="middle">Old key lost</text><circle cx="84" cy="304" r="17" fill="none" stroke="#087f78" stroke-width="7"/><path d="M101 304 L145 304" fill="none" stroke="#087f78" stroke-width="4" stroke-linecap="round"/><path d="M130 304 L130 318" fill="none" stroke="#087f78" stroke-width="4" stroke-linecap="round"/><path d="M145 304 L145 318" fill="none" stroke="#087f78" stroke-width="4" stroke-linecap="round"/><text x="106" y="389" font-size="22" fill="#087f78" font-weight="600" text-anchor="middle">Backup key</text><path d="M173 303 L386 303" fill="none" stroke="#087f78" stroke-width="4" stroke-linecap="round"/><path d="M374 295 L386 303 L374 311" fill="none" stroke="#087f78" stroke-width="4" stroke-linecap="round" stroke-linejoin="round"/><text x="280" y="260" font-size="22" fill="#087f78" font-weight="600" text-anchor="middle">Reveal + sign</text><rect x="415" y="104" width="332" height="176" rx="22" fill="#dceee7" stroke="none" stroke-width="2"/><text x="443" y="146" font-size="20" fill="#647780" font-weight="400" text-anchor="start">Same identity</text><text x="443" y="205" font-size="47" fill="#182f3b" font-weight="700" text-anchor="start">alice</text><text x="443" y="247" font-size="19" fill="#087f78" font-weight="600" text-anchor="start">Singular registry</text><path d="M770 194 L902 194" fill="none" stroke="#087f78" stroke-width="4" stroke-linecap="round"/><path d="M890 186 L902 194 L890 202" fill="none" stroke="#087f78" stroke-width="4" stroke-linecap="round" stroke-linejoin="round"/><circle cx="1000" cy="155" r="19" fill="#087f78"/><path d="M965 211 Q965 182 1000 182 Q1035 182 1035 211" fill="#087f78"/><text x="1000" y="264" font-size="23" fill="#087f78" font-weight="600" text-anchor="middle">New controller</text><rect x="404" y="334" width="360" height="44" rx="22" fill="#dceee7" stroke="none" stroke-width="2"/><text x="584" y="364" font-size="20" fill="#087f78" font-weight="600" text-anchor="middle">Set up the next recovery</text></svg>

<!--
The backup key must survive. Recovery checks the revealed canonical Cardano address against the stored, domain-separated commitment. It requires the revealed address's payment-key signer, installs that controller, and stores a fresh next commitment. The old controller need not sign; its former authority no longer permits maintenance after recovery.

The validator checks:
expect computed == record.next_control_commitment
expect has(extra_signatories, revealed_hash)

Read: [application.ak, recover](https://github.com/lambdasistemi/singular/blob/d840559a04848675c70eae4febae51c48c619257/naming-onchain/validators/application.ak); [Recovery runner and observations](https://github.com/lambdasistemi/singular/blob/d840559a04848675c70eae4febae51c48c619257/docs/recovery-retirement.md). The runner describes both successful handover and refusal of wrong reveals, wrong signers, replay and old-key maintenance.

Proved in the model: recovery_accepts_without_old_controller and old_controller_dead_after_recovery in [NamingLifecycleStatements.lean](https://github.com/lambdasistemi/singular/blob/d840559a04848675c70eae4febae51c48c619257/lean/Singular/NamingLifecycleStatements.lean). These statements prove concrete model cases; they are not a universal correctness proof of the compiled validator or hash implementation.
-->

---

<div class="eyebrow">ASKING TRUSTED PEOPLE TO END IT</div>

# As a name owner, I want my group to have retirement power<br>so that they can end my name without taking it over.

<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1120 460" role="img" aria-label="A fixed threshold of trusted people can initiate retirement. Their quorum authority cannot take over the name or redirect its payments. The controller can also retire independently." style="font-family:Arial,sans-serif"><title>A fixed threshold of trusted people can initiate retirement. Their quorum authority cannot take over the name or redirect its payments. The controller can also retire independently.</title><circle cx="85" cy="154" r="19" fill="#087f78"/><path d="M50 210 Q50 181 85 181 Q120 181 120 210" fill="#087f78"/><circle cx="171" cy="154" r="19" fill="#087f78"/><path d="M136 210 Q136 181 171 181 Q206 181 206 210" fill="#087f78"/><circle cx="257" cy="154" r="19" fill="#647780"/><path d="M222 210 Q222 181 257 181 Q292 181 292 210" fill="#647780"/><text x="171" y="273" font-size="23" fill="#182f3b" font-weight="600" text-anchor="middle">Fixed group + threshold</text><path d="M304 173 L552 173" fill="none" stroke="#087f78" stroke-width="4" stroke-linecap="round"/><path d="M540 165 L552 173 L540 181" fill="none" stroke="#087f78" stroke-width="4" stroke-linecap="round" stroke-linejoin="round"/><text x="429" y="131" font-size="27" fill="#087f78" font-weight="600" text-anchor="middle">Retire</text><rect x="578" y="73" width="496" height="190" rx="22" fill="#dceee7" stroke="none" stroke-width="2"/><text x="826" y="131" font-size="45" fill="#182f3b" font-weight="700" text-anchor="middle">alice</text><text x="826" y="199" font-size="25" fill="#087f78" font-weight="600" text-anchor="middle">Awaiting completion</text><circle cx="419" cy="337" r="23" fill="#f5e1d9"/><path d="M411 329 L427 345" fill="none" stroke="#b54c3a" stroke-width="4" stroke-linecap="round"/><path d="M411 345 L427 329" fill="none" stroke="#b54c3a" stroke-width="4" stroke-linecap="round"/><text x="592" y="345" font-size="26" fill="#b54c3a" font-weight="600" text-anchor="middle">Take control</text><circle cx="764" cy="337" r="23" fill="#f5e1d9"/><path d="M756 329 L772 345" fill="none" stroke="#b54c3a" stroke-width="4" stroke-linecap="round"/><path d="M756 345 L772 329" fill="none" stroke="#b54c3a" stroke-width="4" stroke-linecap="round"/><text x="952" y="345" font-size="24" fill="#b54c3a" font-weight="600" text-anchor="middle">Redirect payments</text><text x="558" y="433" font-size="23" fill="#647780" font-weight="400" text-anchor="middle">Alice can also retire it herself.</text></svg>

<!--
The quorum and threshold are fixed at registration. Retirement counts distinct signed members:
threshold > 0 && naming.distinct_count(signed) >= threshold

The quorum is trusted with a consequential power: it can retire a name even against the controller's wishes. It cannot use its quorum role to redirect the destination or change the controller. It is not a death oracle, and it does not supply social recovery. A member who independently holds a controller key has that separate authority.

Read: [application.ak, retire / quorum_authorized / maintain](https://github.com/lambdasistemi/singular/blob/d840559a04848675c70eae4febae51c48c619257/naming-onchain/validators/application.ak); [Retirement runner](https://github.com/lambdasistemi/singular/blob/d840559a04848675c70eae4febae51c48c619257/docs/recovery-retirement.md). The documented rows distinguish controller-alone from quorum-alone authorization and test insufficient quorum and attempted takeover/redirection.

Model examples: controller_and_quorum_retirement_accept, quorum_only_control_takeover_refused and quorum_only_payment_redirection_refused in [NamingLifecycleStatements.lean](https://github.com/lambdasistemi/singular/blob/d840559a04848675c70eae4febae51c48c619257/lean/Singular/NamingLifecycleStatements.lean). The market review found the separate retirement-only quorum to be the strongest specific distinction; that search is not proof that no equivalent exists.

Three people are a visual example only, not a fixed protocol group size. The configured threshold counts distinct members.
-->

---

<div class="eyebrow">FINISHING THE RETIREMENT</div>

# As a name owner, I want anyone to finish my retirement<br>so that completion needs no further approval from me.

<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1120 460" role="img" aria-label="Alice or her quorum initiates retirement. The representative waits in completion-only custody. Anyone can submit valid completion, burning it and making the name Over." style="font-family:Arial,sans-serif"><title>Alice or her quorum initiates retirement. The representative waits in completion-only custody. Anyone can submit valid completion, burning it and making the name Over.</title><rect x="18" y="96" width="278" height="176" rx="22" fill="#ffffff" stroke="none" stroke-width="2"/><text x="46" y="138" font-size="20" fill="#647780" font-weight="400" text-anchor="start">Active</text><text x="46" y="197" font-size="47" fill="#182f3b" font-weight="700" text-anchor="start">alice</text><text x="46" y="239" font-size="19" fill="#087f78" font-weight="600" text-anchor="start">Singular registry</text><path d="M316 187 L393 187" fill="none" stroke="#087f78" stroke-width="4" stroke-linecap="round"/><path d="M381 179 L393 187 L381 195" fill="none" stroke="#087f78" stroke-width="4" stroke-linecap="round" stroke-linejoin="round"/><rect x="414" y="96" width="290" height="229" rx="22" fill="#f3e8c8" stroke="none" stroke-width="2"/><text x="559" y="142" font-size="43" fill="#182f3b" font-weight="700" text-anchor="middle">alice</text><text x="559" y="206" font-size="23" fill="#946313" font-weight="600" text-anchor="middle">Retirement pending</text><text x="559" y="258" font-size="20" fill="#946313" font-weight="400" text-anchor="middle">Held for completion</text><path d="M725 187 L802 187" fill="none" stroke="#087f78" stroke-width="4" stroke-linecap="round"/><path d="M790 179 L802 187 L790 195" fill="none" stroke="#087f78" stroke-width="4" stroke-linecap="round" stroke-linejoin="round"/><rect x="823" y="96" width="276" height="229" rx="22" fill="#182f3b" stroke="none" stroke-width="2"/><text x="961" y="142" font-size="43" fill="#f7f5ef" font-weight="700" text-anchor="middle">alice</text><text x="961" y="210" font-size="37" fill="#a9ded0" font-weight="700" text-anchor="middle">Over</text><text x="961" y="263" font-size="19" fill="#f7f5ef" font-weight="400" text-anchor="middle">Permanently retired</text><text x="355" y="363" font-size="20" fill="#647780" font-weight="400" text-anchor="middle">Alice or quorum</text><text x="764" y="363" font-size="20" fill="#087f78" font-weight="600" text-anchor="middle">Anyone completes</text></svg>

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

<div class="eyebrow">PREVENTING REUSE</div>

# As a name owner, I want my retired name to stay occupied<br>so that nobody can reuse it in this registry.

<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1120 460" role="img" aria-label="Once retirement is complete, alice remains occupied in this registry and a new claim cannot reuse it." style="font-family:Arial,sans-serif"><title>Once retirement is complete, alice remains occupied in this registry and a new claim cannot reuse it.</title><rect x="58" y="88" width="380" height="279" rx="22" fill="#182f3b" stroke="none" stroke-width="2"/><text x="248" y="164" font-size="64" fill="#f7f5ef" font-weight="700" text-anchor="middle">alice</text><text x="248" y="229" font-size="34" fill="#a9ded0" font-weight="600" text-anchor="middle">Over</text><text x="248" y="320" font-size="24" fill="#f7f5ef" font-weight="400" text-anchor="middle">Permanently occupied</text><circle cx="966" cy="101" r="19" fill="#647780"/><path d="M931 157 Q931 128 966 128 Q1001 128 1001 157" fill="#647780"/><text x="966" y="210" font-size="23" fill="#647780" font-weight="400" text-anchor="middle">New claimant</text><rect x="776" y="260" width="316" height="105" rx="22" fill="#ffffff" stroke="none" stroke-width="2"/><text x="934" y="303" font-size="30" fill="#182f3b" font-weight="600" text-anchor="middle">Claim alice</text><text x="934" y="338" font-size="19" fill="#647780" font-weight="400" text-anchor="middle">Same registry</text><path d="M776 310 L513 310" fill="none" stroke="#b54c3a" stroke-width="4" stroke-linecap="round"/><circle cx="559" cy="310" r="23" fill="#f5e1d9"/><path d="M551 302 L567 318" fill="none" stroke="#b54c3a" stroke-width="4" stroke-linecap="round"/><path d="M551 318 L567 302" fill="none" stroke="#b54c3a" stroke-width="4" stroke-linecap="round"/><text x="607" y="253" font-size="27" fill="#b54c3a" font-weight="600" text-anchor="middle">Refused</text></svg>

<!--
Initiation and completion are separate transactions. Pending retirement holds the representative in custody; it is not yet Over. Completion spends the paired request and authenticated registry state, applies the retirement update, and burns the exact representative. No controller or quorum approval is required for completion; a fee input still needs its owner's witness.

The custody validator checks:
expect held_burned_exactly_once(claim, tx)
expect request_binds_burn(claim, stateIn, requestIn)

Read: [retirement_custody.ak](https://github.com/lambdasistemi/singular/blob/d840559a04848675c70eae4febae51c48c619257/naming-onchain/validators/retirement_custody.ak); [Completion and refusal evidence](https://github.com/lambdasistemi/singular/blob/d840559a04848675c70eae4febae51c48c619257/onchain-release/README.md).

Model: [over_terminal](https://github.com/lambdasistemi/singular/blob/d840559a04848675c70eae4febae51c48c619257/docs/theorems.md) and [retirement_pending_then_over / re_registration_after_over_refused](https://github.com/lambdasistemi/singular/blob/d840559a04848675c70eae4febae51c48c619257/lean/Singular/NamingLifecycleStatements.lean). The manifest retains a missing general custody-escape theorem; the concrete custody examples do not fill that proof gap.

Naming forbids Delete, although the generic registry has a Delete operation. Permanent occupation applies within this registry. Retirement cannot stop payments sent directly to an already saved raw address.

Keep the boundary explicit when speaking: another registry could still have its own alice, and a saved raw payment address still works independently of the retired name.
-->

---

<div class="eyebrow">THE PREPROD DEMO</div>

# As a reviewer, I want one connected preprod journey<br>so that I can inspect every transition on the ledger.

<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1120 460" role="img" aria-label="A planned connected preprod demonstration: claim, activate by fold, recover, retire, and complete retirement. Every transaction is still pending." style="font-family:Arial,sans-serif"><title>A planned connected preprod demonstration: claim, activate by fold, recover, retire, and complete retirement. Every transaction is still pending.</title><rect x="340" y="26" width="440" height="44" rx="22" fill="#f3e8c8" stroke="none" stroke-width="2"/><text x="560" y="56" font-size="20" fill="#946313" font-weight="600" text-anchor="middle">preprod run pending (#78)</text><rect x="12" y="135" width="208" height="220" rx="22" fill="#ffffff" stroke="none" stroke-width="2"/><circle cx="116" cy="184" r="24" fill="#f3e8c8"/><text x="116" y="193" font-size="25" fill="#946313" font-weight="600" text-anchor="middle">1</text><text x="116" y="247" font-size="28" fill="#182f3b" font-weight="600" text-anchor="middle">Claim</text><text x="116" y="291" font-size="17" fill="#647780" font-weight="400" text-anchor="middle">Pending request</text><text x="116" y="332" font-size="18" fill="#946313" font-weight="400" text-anchor="middle">TX pending</text><path d="M221 240 L234 240" fill="none" stroke="#647780" stroke-width="4" stroke-linecap="round" stroke-dasharray="9 9"/><path d="M222 232 L234 240 L222 248" fill="none" stroke="#647780" stroke-width="4" stroke-linecap="round" stroke-linejoin="round"/><rect x="234" y="135" width="208" height="220" rx="22" fill="#ffffff" stroke="none" stroke-width="2"/><circle cx="338" cy="184" r="24" fill="#f3e8c8"/><text x="338" y="193" font-size="25" fill="#946313" font-weight="600" text-anchor="middle">2</text><text x="338" y="247" font-size="28" fill="#182f3b" font-weight="600" text-anchor="middle">Activate</text><text x="338" y="291" font-size="17" fill="#647780" font-weight="400" text-anchor="middle">Name registered</text><text x="338" y="332" font-size="18" fill="#946313" font-weight="400" text-anchor="middle">TX pending</text><path d="M443 240 L456 240" fill="none" stroke="#647780" stroke-width="4" stroke-linecap="round" stroke-dasharray="9 9"/><path d="M444 232 L456 240 L444 248" fill="none" stroke="#647780" stroke-width="4" stroke-linecap="round" stroke-linejoin="round"/><rect x="456" y="135" width="208" height="220" rx="22" fill="#ffffff" stroke="none" stroke-width="2"/><circle cx="560" cy="184" r="24" fill="#f3e8c8"/><text x="560" y="193" font-size="25" fill="#946313" font-weight="600" text-anchor="middle">3</text><text x="560" y="247" font-size="28" fill="#182f3b" font-weight="600" text-anchor="middle">Recover</text><text x="560" y="291" font-size="17" fill="#647780" font-weight="400" text-anchor="middle">New controller</text><text x="560" y="332" font-size="18" fill="#946313" font-weight="400" text-anchor="middle">TX pending</text><path d="M665 240 L678 240" fill="none" stroke="#647780" stroke-width="4" stroke-linecap="round" stroke-dasharray="9 9"/><path d="M666 232 L678 240 L666 248" fill="none" stroke="#647780" stroke-width="4" stroke-linecap="round" stroke-linejoin="round"/><rect x="678" y="135" width="208" height="220" rx="22" fill="#ffffff" stroke="none" stroke-width="2"/><circle cx="782" cy="184" r="24" fill="#f3e8c8"/><text x="782" y="193" font-size="25" fill="#946313" font-weight="600" text-anchor="middle">4</text><text x="782" y="247" font-size="28" fill="#182f3b" font-weight="600" text-anchor="middle">Retire</text><text x="782" y="291" font-size="17" fill="#647780" font-weight="400" text-anchor="middle">Held for completion</text><text x="782" y="332" font-size="18" fill="#946313" font-weight="400" text-anchor="middle">TX pending</text><path d="M887 240 L900 240" fill="none" stroke="#647780" stroke-width="4" stroke-linecap="round" stroke-dasharray="9 9"/><path d="M888 232 L900 240 L888 248" fill="none" stroke="#647780" stroke-width="4" stroke-linecap="round" stroke-linejoin="round"/><rect x="900" y="135" width="208" height="220" rx="22" fill="#ffffff" stroke="none" stroke-width="2"/><circle cx="1004" cy="184" r="24" fill="#f3e8c8"/><text x="1004" y="193" font-size="25" fill="#946313" font-weight="600" text-anchor="middle">5</text><text x="1004" y="247" font-size="28" fill="#182f3b" font-weight="600" text-anchor="middle">Complete</text><text x="1004" y="291" font-size="17" fill="#647780" font-weight="400" text-anchor="middle">Permanently retired</text><text x="1004" y="332" font-size="18" fill="#946313" font-weight="400" text-anchor="middle">TX pending</text><text x="560" y="420" font-size="25" fill="#647780" font-weight="400" text-anchor="middle">One name · One registry · Five real transactions</text></svg>

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

<div class="eyebrow">BUILDING THE NEXT APPLICATION</div>

# As a KERI builder, I want to reuse this foundation<br>so that I can focus on KERI-specific rules.

<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1120 460" role="img" aria-label="A builder can see the naming lifecycle as a reusable registry boundary. Payment naming is the reference application; KERI key-state is planned future work." style="font-family:Arial,sans-serif"><title>A builder can see the naming lifecycle as a reusable registry boundary. Payment naming is the reference application; KERI key-state is planned future work.</title><rect x="50" y="67" width="1020" height="82" rx="22" fill="#dceee7" stroke="none" stroke-width="2"/><text x="220" y="117" font-size="25" fill="#087f78" font-weight="600" text-anchor="middle">One identity</text><text x="555" y="117" font-size="25" fill="#087f78" font-weight="600" text-anchor="middle">Recover control</text><text x="890" y="117" font-size="25" fill="#087f78" font-weight="600" text-anchor="middle">Retire permanently</text><path d="M314 151 L314 208" fill="none" stroke="#087f78" stroke-width="4" stroke-linecap="round"/><path d="M813 151 L813 208" fill="none" stroke="#647780" stroke-width="4" stroke-linecap="round" stroke-dasharray="9 9"/><rect x="76" y="211" width="474" height="201" rx="22" fill="#ffffff" stroke="none" stroke-width="2"/><rect x="113" y="246" width="96" height="64" rx="10" fill="none" stroke="#087f78" stroke-width="2"/><rect x="173" y="264" width="46" height="29" rx="6" fill="#f7f5ef" stroke="#087f78" stroke-width="2"/><circle cx="188" cy="278" r="4" fill="#087f78"/><text x="161" y="349" font-size="23" fill="#087f78" font-weight="600" text-anchor="middle"></text><text x="362" y="276" font-size="29" fill="#182f3b" font-weight="600" text-anchor="middle">Payment naming</text><text x="362" y="326" font-size="20" fill="#087f78" font-weight="600" text-anchor="middle">Surrogate application</text><rect x="578" y="211" width="474" height="201" rx="22" fill="#ffffff" stroke="#647780" stroke-width="2"/><circle cx="656" cy="251" r="19" fill="#647780"/><path d="M621 307 Q621 278 656 278 Q691 278 691 307" fill="#647780"/><text x="857" y="276" font-size="29" fill="#182f3b" font-weight="600" text-anchor="middle">KERI key-state</text><rect x="770.5" y="306" width="173" height="44" rx="22" fill="#edf0ee" stroke="none" stroke-width="2"/><text x="857" y="336" font-size="20" fill="#647780" font-weight="600" text-anchor="middle">Planned</text></svg>

<!--
Close on the argument: a simple name already needs unique identity, independent state, recovery and a permanent ending. That is enough to give the registry a useful job. The next consumer can build on the same boundary.

Planned direction: [Programmable naming, #97](https://github.com/lambdasistemi/singular/issues/97). Replace the payment destination with a consumer-defined value. Require the consumer's value validator to execute at registration and maintenance through a pinned script withdrawal, following the registry's existing consumer mechanism.

This is future work. The issue leaves the validator's placement open: a record field or an application parameter. Lean must be generalized before dependent implementation is accepted. The second instance does not yet establish KERI conformance.

The preprod demonstration on slide 10 is a delivery requirement in its own right; it must not be deferred to this future abstraction.
-->
