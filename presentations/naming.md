---
marp: true
theme: default
size: 16:9
paginate: true
title: Singular — one name, through its life
description: Twelve visual slides about claiming, maintaining, recovering and retiring a name; preprod demonstration pending.
style: |
  section { background: #f7f5ef; color: #182f3b; font-family: Arial, sans-serif; padding: 40px 70px; justify-content: flex-start; }
  .eyebrow { color: #087f78; font-size: 18px; font-weight: 700; letter-spacing: 2px; margin: 0 0 16px; }
  h1 { color: #182f3b; font-size: 31px; line-height: 1.25; letter-spacing: -1px; margin: 0 0 18px; }
  svg { display: block; width: 100%; height: auto; max-height: 410px; }
  section::after { color: #647780; font-size: 17px; }
---

<div class="eyebrow">WHY CARDANO-KERI NEEDS A REGISTRY</div>

# Use KERI identities on Cardano<br>by reading their current keys through CIP-31.

<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1120 460" role="img" aria-label="A Cardano contract reads the unique current-key UTxO for an active KERI AID through CIP-31. Once duplicity is proved on Cardano, that AID must never authorize again." style="font-family:Arial,sans-serif"><title>Unique current-key reference and permanent rejection after duplicity</title><rect x="45" y="65" width="470" height="282" rx="20" fill="white"/><rect x="605" y="65" width="470" height="282" rx="20" fill="white"/><text x="280" y="116" font-size="27" fill="#182f3b" text-anchor="middle">One active AID, one key UTxO</text><rect x="74" y="168" width="180" height="75" rx="20" fill="#dceee7"/><text x="164" y="201" font-size="21" fill="#087f78" text-anchor="middle">Cardano</text><text x="164" y="226" font-size="21" fill="#087f78" text-anchor="middle">contract</text><rect x="340" y="168" width="147" height="75" rx="20" fill="#dceee7"/><text x="413" y="201" font-size="21" fill="#087f78" text-anchor="middle">Current</text><text x="413" y="226" font-size="21" fill="#087f78" text-anchor="middle">keys</text><path d="M268 205 H324 M313 197 L325 205 L313 213" fill="none" stroke="#087f78" stroke-width="4"/><text x="296" y="183" font-size="18" fill="#087f78" text-anchor="middle">reads</text><text x="280" y="304" font-size="24" fill="#647780" text-anchor="middle">No competing key records</text><text x="840" y="116" font-size="26" fill="#182f3b" text-anchor="middle">Convicted AID: never usable again</text><circle cx="840" cy="195" r="28" fill="#f5e1d9"/><path d="M830 185 L850 205 M850 185 L830 205" stroke="#b54c3a" stroke-width="5"/><text x="840" y="264" font-size="24" fill="#087f78" text-anchor="middle">Duplicity proved on Cardano</text><text x="840" y="304" font-size="23" fill="#647780" text-anchor="middle">No recovery or re-registration</text><text x="560" y="407" font-size="27" fill="#087f78" text-anchor="middle">Uniqueness now · Conviction forever</text></svg>

<!--
Read the current keys through a CIP 31 reference input.

Require one authoritative key UTxO for each active AID.

When duplicity is proved on Cardano, reject that AID permanently.

Conflicting histories can both carry valid signatures. The same AID must not recover or register again.
-->

---

<div class="eyebrow">WHY I AM PRESENTING NAMING</div>

# cardano-keri is complex. Today, focus on the registry.<br>Show its flexibility through a familiar naming application.

<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1120 460" role="img" aria-label="This talk isolates the registry from cardano-keri complexity. A naming application uses the familiar ADA Handle idea of a name for a payment address and demonstrates pluggable recovery and retirement rules. It is not an ADA Handle replacement." style="font-family:Arial,sans-serif"><title>A familiar naming application demonstrates a pluggable registry</title><rect x="20" y="62" width="490" height="286" rx="22" fill="white"/><text x="265" y="114" font-size="33" fill="#182f3b" text-anchor="middle">cardano-keri</text><text x="265" y="170" font-size="24" fill="#647780" text-anchor="middle">Key histories · Witnesses</text><text x="265" y="210" font-size="22" fill="#647780" text-anchor="middle">A separate presentation</text><rect x="60" y="252" width="410" height="65" rx="22" fill="#dceee7"/><text x="265" y="293" font-size="30" fill="#087f78" text-anchor="middle">The registry</text><path d="M526 284 H604 M591 275 L605 284 L591 293" fill="none" stroke="#087f78" stroke-width="4"/><rect x="622" y="62" width="478" height="286" rx="22" fill="#dceee7"/><text x="861" y="114" font-size="27" fill="#182f3b" text-anchor="middle">A handle-style application</text><text x="861" y="173" font-size="26" fill="#087f78" text-anchor="middle">name → payment address</text><text x="861" y="229" font-size="21" fill="#647780" text-anchor="middle">Our chosen rules</text><text x="861" y="274" font-size="26" fill="#087f78" text-anchor="middle">Recovery · Retirement</text><text x="861" y="319" font-size="20" fill="#087f78" text-anchor="middle">Different rules, same registry</text><text x="560" y="409" font-size="25" fill="#087f78" text-anchor="middle">Inspired by ADA Handle. Not a replacement for it.</text></svg>

<!--
Leave KERI's complexity for another presentation.

Show the registry through a familiar idea: a name pointing to a payment address, like ADA Handle.

Add our chosen recovery and retirement rules to demonstrate pluggable applications.

This is a demonstration, not a replacement for ADA Handle.
-->

---

<div class="eyebrow">WHAT SINGULAR OFFERS</div>

# Singular is a Cardano smart contract<br>for registering unique identifiers.

<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1120 460" role="img" aria-label="Singular gives applications a registry of unique identifiers and representative NFTs while applications keep their own state and rules. Other possible consumers include asset serial numbers, credential identifiers and device identifiers. A preprod deployment reference is awaiting verification." style="font-family:Arial,sans-serif"><title>Singular gives applications a registry of unique identifiers and representative NFTs while applications keep their own state and rules. Other possible consumers include asset serial numbers, credential identifiers and device identifiers. A preprod deployment reference is awaiting verification.</title><rect x="285" y="8" width="550" height="44" rx="22" fill="#f3e8c8" stroke="none" stroke-width="2"/><text x="560" y="38" font-size="20" fill="#946313" font-weight="600" text-anchor="middle">Preprod deployment: reference pending</text><rect x="28" y="107" width="440" height="163" rx="22" fill="#dceee7" stroke="none" stroke-width="2"/><text x="248" y="158" font-size="31" fill="#182f3b" font-weight="700" text-anchor="middle">The registry</text><text x="248" y="218" font-size="21" fill="#087f78" font-weight="600" text-anchor="middle">Unique identifier + representative NFT</text><path d="M491 188 L628 188" fill="none" stroke="#087f78" stroke-width="4" stroke-linecap="round"/><path d="M616 180 L628 188 L616 196" fill="none" stroke="#087f78" stroke-width="4" stroke-linecap="round" stroke-linejoin="round"/><text x="559" y="147" font-size="18" fill="#087f78" font-weight="600" text-anchor="middle">Registration proof</text><rect x="651" y="107" width="440" height="163" rx="22" fill="#ffffff" stroke="none" stroke-width="2"/><text x="871" y="158" font-size="31" fill="#182f3b" font-weight="700" text-anchor="middle">Your application</text><text x="871" y="218" font-size="25" fill="#087f78" font-weight="600" text-anchor="middle">Your data · Your rules</text><text x="560" y="332" font-size="22" fill="#647780" font-weight="400" text-anchor="middle">Other possible applications</text><rect x="31" y="372" width="326" height="44" rx="22" fill="#dceee7" stroke="none" stroke-width="2"/><text x="194" y="402" font-size="20" fill="#087f78" font-weight="600" text-anchor="middle">Asset serial numbers</text><rect x="396" y="372" width="326" height="44" rx="22" fill="#dceee7" stroke="none" stroke-width="2"/><text x="559" y="402" font-size="20" fill="#087f78" font-weight="600" text-anchor="middle">Credential IDs</text><rect x="761" y="372" width="326" height="44" rx="22" fill="#dceee7" stroke="none" stroke-width="2"/><text x="924" y="402" font-size="20" fill="#087f78" font-weight="600" text-anchor="middle">Device IDs</text></svg>

<!--
The registry gives each active identifier one representative token. The application keeps its own data and rules.

Other applications could register asset serial numbers, credential identifiers or device identifiers.

Mention preprod only with the deployment reference confirmed.
-->

---

<div class="eyebrow">PAYING SOMEONE</div>

# As a payer, I want to identify the right alice<br>so that I can choose the intended recipient.

<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1120 460" role="img" aria-label="A payer sees two tokens called alice. One active identity within a chosen registry distinguishes the name." style="font-family:Arial,sans-serif"><title>A payer sees two tokens called alice. One active identity within a chosen registry distinguishes the name.</title><circle cx="95" cy="194" r="19" fill="#087f78"/><path d="M60 250 Q60 221 95 221 Q130 221 130 250" fill="#087f78"/><text x="95" y="303" font-size="24" fill="#182f3b" font-weight="400" text-anchor="middle">Payer</text><path d="M145 220 L274 220" fill="none" stroke="#087f78" stroke-width="4" stroke-linecap="round"/><path d="M262 212 L274 220 L262 228" fill="none" stroke="#087f78" stroke-width="4" stroke-linecap="round" stroke-linejoin="round"/><rect x="300" y="44" width="310" height="160" rx="22" fill="#ffffff" stroke="none" stroke-width="2"/><text x="455" y="86" font-size="20" fill="#647780" font-weight="400" text-anchor="middle">Token label</text><text x="455" y="150" font-size="48" fill="#182f3b" font-weight="700" text-anchor="middle">alice</text><rect x="300" y="238" width="310" height="160" rx="22" fill="#ffffff" stroke="none" stroke-width="2"/><text x="455" y="280" font-size="20" fill="#647780" font-weight="400" text-anchor="middle">Another token label</text><text x="455" y="344" font-size="48" fill="#182f3b" font-weight="700" text-anchor="middle">alice</text><text x="665" y="235" font-size="72" fill="#946313" font-weight="700" text-anchor="middle">?</text><rect x="745" y="128" width="345" height="176" rx="22" fill="#dceee7" stroke="none" stroke-width="2"/><text x="773" y="170" font-size="20" fill="#647780" font-weight="400" text-anchor="start">Within one registry</text><text x="773" y="229" font-size="47" fill="#182f3b" font-weight="700" text-anchor="start">alice</text><text x="773" y="271" font-size="19" fill="#087f78" font-weight="600" text-anchor="start">The registry</text><circle cx="1055" cy="271" r="23" fill="#087f78"/><path d="M1044 271 L1052 279 L1067 261" fill="none" stroke="white" stroke-width="4" stroke-linecap="round"/><rect x="774.5" y="345" width="285" height="44" rx="22" fill="#dceee7" stroke="none" stroke-width="2"/><text x="917" y="375" font-size="20" fill="#087f78" font-weight="600" text-anchor="middle">One active identity</text></svg>

<!--
Two tokens can both say alice. Their spelling alone does not tell a payer which one to trust.

The registry gives that name one active identity.

Keep the boundary clear. Another registry can still have its own alice.
-->

---

<div class="eyebrow">CLAIMING A NAME</div>

# As a claimant, I want to register an available name<br>so that nobody else can claim it in this registry.

<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1120 460" role="img" aria-label="Two approved claims compete for alice. The first valid fold registers the name; the later competing fold is refused." style="font-family:Arial,sans-serif"><title>Two approved claims compete for alice. The first valid fold registers the name; the later competing fold is refused.</title><circle cx="78" cy="99" r="19" fill="#087f78"/><path d="M43 155 Q43 126 78 126 Q113 126 113 155" fill="#087f78"/><text x="78" y="206" font-size="24" fill="#182f3b" font-weight="400" text-anchor="middle">Alice</text><circle cx="78" cy="297" r="19" fill="#647780"/><path d="M43 353 Q43 324 78 324 Q113 324 113 353" fill="#647780"/><text x="78" y="405" font-size="22" fill="#182f3b" font-weight="400" text-anchor="middle">Rival</text><rect x="170" y="48" width="265" height="138" rx="22" fill="#ffffff" stroke="none" stroke-width="2"/><text x="302" y="92" font-size="38" fill="#182f3b" font-weight="700" text-anchor="middle">alice</text><text x="302" y="145" font-size="21" fill="#647780" font-weight="400" text-anchor="middle">Approved claim</text><rect x="170" y="245" width="265" height="138" rx="22" fill="#ffffff" stroke="none" stroke-width="2"/><text x="302" y="289" font-size="38" fill="#182f3b" font-weight="700" text-anchor="middle">alice</text><text x="302" y="342" font-size="21" fill="#647780" font-weight="400" text-anchor="middle">Approved claim</text><path d="M458 116 L702 116" fill="none" stroke="#087f78" stroke-width="4" stroke-linecap="round"/><path d="M690 108 L702 116 L690 124" fill="none" stroke="#087f78" stroke-width="4" stroke-linecap="round" stroke-linejoin="round"/><text x="580" y="78" font-size="19" fill="#087f78" font-weight="600" text-anchor="middle">First valid registration</text><rect x="728" y="38" width="350" height="176" rx="22" fill="#dceee7" stroke="none" stroke-width="2"/><text x="756" y="80" font-size="20" fill="#647780" font-weight="400" text-anchor="start">Registered to Alice</text><text x="756" y="139" font-size="47" fill="#182f3b" font-weight="700" text-anchor="start">alice</text><text x="756" y="181" font-size="19" fill="#087f78" font-weight="600" text-anchor="start">The registry</text><path d="M458 315 L702 315" fill="none" stroke="#b54c3a" stroke-width="4" stroke-linecap="round"/><path d="M690 307 L702 315 L690 323" fill="none" stroke="#b54c3a" stroke-width="4" stroke-linecap="round" stroke-linejoin="round"/><circle cx="753" cy="315" r="23" fill="#f5e1d9"/><path d="M745 307 L761 323" fill="none" stroke="#b54c3a" stroke-width="4" stroke-linecap="round"/><path d="M745 323 L761 307" fill="none" stroke="#b54c3a" stroke-width="4" stroke-linecap="round"/><text x="907" y="324" font-size="25" fill="#b54c3a" font-weight="600" text-anchor="middle">Already occupied</text><rect x="409" y="400" width="344" height="44" rx="22" fill="#dceee7" stroke="none" stroke-width="2"/><text x="581" y="430" font-size="20" fill="#087f78" font-weight="600" text-anchor="middle">Anyone can finalize it</text></svg>

<!--
Alice and a rival can both submit a claim.

Approval does not reserve the name. The first valid registration gets it; the other claim is refused.

Anyone can finish the registration. There is no registrar choosing the winner.
-->

---

<div class="eyebrow">CHANGING A PAYMENT ADDRESS</div>

# As a name owner, I want to update my payment address<br>so that I can change wallets and keep my name.

<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1120 460" role="img" aria-label="Alice changes her payment destination with her controller key. Her registered name and representative stay the same." style="font-family:Arial,sans-serif"><title>Alice changes her payment destination with her controller key. Her registered name and representative stay the same.</title><rect x="34" y="139" width="288" height="176" rx="22" fill="#dceee7" stroke="none" stroke-width="2"/><text x="62" y="181" font-size="20" fill="#647780" font-weight="400" text-anchor="start">Same name</text><text x="62" y="240" font-size="47" fill="#182f3b" font-weight="700" text-anchor="start">alice</text><text x="62" y="282" font-size="19" fill="#087f78" font-weight="600" text-anchor="start">The registry</text><circle cx="153" cy="375" r="17" fill="none" stroke="#087f78" stroke-width="7"/><path d="M170 375 L214 375" fill="none" stroke="#087f78" stroke-width="4" stroke-linecap="round"/><path d="M199 375 L199 389" fill="none" stroke="#087f78" stroke-width="4" stroke-linecap="round"/><path d="M214 375 L214 389" fill="none" stroke="#087f78" stroke-width="4" stroke-linecap="round"/><text x="175" y="433" font-size="22" fill="#087f78" font-weight="600" text-anchor="middle">Alice signs</text><path d="M349 229 L494 229" fill="none" stroke="#087f78" stroke-width="4" stroke-linecap="round"/><path d="M482 221 L494 229 L482 237" fill="none" stroke="#087f78" stroke-width="4" stroke-linecap="round" stroke-linejoin="round"/><rect x="560" y="101" width="96" height="64" rx="10" fill="none" stroke="#647780" stroke-width="2"/><rect x="620" y="119" width="46" height="29" rx="6" fill="#f7f5ef" stroke="#647780" stroke-width="2"/><circle cx="635" cy="133" r="4" fill="#647780"/><text x="608" y="204" font-size="23" fill="#647780" font-weight="600" text-anchor="middle">Old destination</text><rect x="888" y="101" width="96" height="64" rx="10" fill="none" stroke="#087f78" stroke-width="2"/><rect x="948" y="119" width="46" height="29" rx="6" fill="#f7f5ef" stroke="#087f78" stroke-width="2"/><circle cx="963" cy="133" r="4" fill="#087f78"/><text x="936" y="204" font-size="23" fill="#087f78" font-weight="600" text-anchor="middle">New destination</text><path d="M707 132 L837 132" fill="none" stroke="#087f78" stroke-width="4" stroke-linecap="round"/><path d="M825 124 L837 132 L825 140" fill="none" stroke="#087f78" stroke-width="4" stroke-linecap="round" stroke-linejoin="round"/><text x="772" y="100" font-size="22" fill="#087f78" font-weight="600" text-anchor="middle">Update</text><path d="M608 210 L608 288" fill="none" stroke="#647780" stroke-width="4" stroke-linecap="round"/><path d="M936 210 L936 288" fill="none" stroke="#087f78" stroke-width="4" stroke-linecap="round"/><rect x="479" y="288" width="580" height="89" rx="22" fill="#ffffff" stroke="none" stroke-width="2"/><text x="769" y="325" font-size="23" fill="#182f3b" font-weight="400" text-anchor="middle">Same control · Same recovery</text><text x="769" y="359" font-size="23" fill="#182f3b" font-weight="400" text-anchor="middle">Same retirement group</text></svg>

<!--
Alice changes wallets and updates her payment address.

Her name stays the same. Her control, recovery commitment and retirement group stay the same too.

She signs the change. The registry does not need to change.
-->

---

<div class="eyebrow">PREPARING FOR KEY LOSS</div>

# As a name owner, I want to prepare a recovery key<br>so that losing my current key does not lock me out.

<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1120 460" role="img" aria-label="Before losing her key, Alice commits to a next controller and keeps its key safe." style="font-family:Arial,sans-serif"><title>Before losing her key, Alice commits to a next controller and keeps its key safe.</title><rect x="38" y="65" width="430" height="317" rx="22" fill="#ffffff" stroke="none" stroke-width="2"/><text x="253" y="109" font-size="24" fill="#647780" font-weight="400" text-anchor="middle">Before key loss</text><circle cx="231" cy="174" r="17" fill="none" stroke="#087f78" stroke-width="7"/><path d="M248 174 L292 174" fill="none" stroke="#087f78" stroke-width="4" stroke-linecap="round"/><path d="M277 174 L277 188" fill="none" stroke="#087f78" stroke-width="4" stroke-linecap="round"/><path d="M292 174 L292 188" fill="none" stroke="#087f78" stroke-width="4" stroke-linecap="round"/><text x="253" y="237" font-size="30" fill="#182f3b" font-weight="600" text-anchor="middle">Next controller key</text><rect x="140.5" y="297" width="225" height="44" rx="22" fill="#dceee7" stroke="none" stroke-width="2"/><text x="253" y="327" font-size="20" fill="#087f78" font-weight="600" text-anchor="middle">Keep it safe</text><path d="M489 219 L656 219" fill="none" stroke="#087f78" stroke-width="4" stroke-linecap="round"/><path d="M644 211 L656 219 L644 227" fill="none" stroke="#087f78" stroke-width="4" stroke-linecap="round" stroke-linejoin="round"/><text x="572" y="180" font-size="24" fill="#087f78" font-weight="600" text-anchor="middle">Commit</text><rect x="681" y="65" width="398" height="176" rx="22" fill="#dceee7" stroke="none" stroke-width="2"/><text x="709" y="107" font-size="20" fill="#647780" font-weight="400" text-anchor="start">alice’s record</text><text x="709" y="166" font-size="47" fill="#182f3b" font-weight="700" text-anchor="start">alice</text><text x="709" y="208" font-size="19" fill="#087f78" font-weight="600" text-anchor="start">The registry</text><rect x="706" y="267" width="348" height="90" rx="22" fill="#ffffff" stroke="none" stroke-width="2"/><text x="880" y="305" font-size="23" fill="#182f3b" font-weight="600" text-anchor="middle">Recovery set up</text><text x="880" y="338" font-size="20" fill="#647780" font-weight="400" text-anchor="middle">Bound to the next controller</text></svg>

<!--
Prepare recovery before losing the current key.

Commit to the next controller and keep its key safe.

This preparation is what makes recovery possible later. It cannot be invented after every key is lost.
-->

---

<div class="eyebrow">RECOVERING CONTROL</div>

# As a name owner, I want to recover with my backup key<br>so that I regain control of the same name.

<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1120 460" role="img" aria-label="Alice loses the old controller key, reveals her precommitted next controller, and signs with its key. The same name continues under new control." style="font-family:Arial,sans-serif"><title>Alice loses the old controller key, reveals her precommitted next controller, and signs with its key. The same name continues under new control.</title><circle cx="84" cy="120" r="17" fill="none" stroke="#647780" stroke-width="7"/><path d="M101 120 L145 120" fill="none" stroke="#647780" stroke-width="4" stroke-linecap="round"/><path d="M130 120 L130 134" fill="none" stroke="#647780" stroke-width="4" stroke-linecap="round"/><path d="M145 120 L145 134" fill="none" stroke="#647780" stroke-width="4" stroke-linecap="round"/><path d="M56 74 L152 170" fill="none" stroke="#b54c3a" stroke-width="4" stroke-linecap="round"/><text x="106" y="215" font-size="22" fill="#b54c3a" font-weight="600" text-anchor="middle">Old key lost</text><circle cx="84" cy="304" r="17" fill="none" stroke="#087f78" stroke-width="7"/><path d="M101 304 L145 304" fill="none" stroke="#087f78" stroke-width="4" stroke-linecap="round"/><path d="M130 304 L130 318" fill="none" stroke="#087f78" stroke-width="4" stroke-linecap="round"/><path d="M145 304 L145 318" fill="none" stroke="#087f78" stroke-width="4" stroke-linecap="round"/><text x="106" y="389" font-size="22" fill="#087f78" font-weight="600" text-anchor="middle">Backup key</text><path d="M173 303 L386 303" fill="none" stroke="#087f78" stroke-width="4" stroke-linecap="round"/><path d="M374 295 L386 303 L374 311" fill="none" stroke="#087f78" stroke-width="4" stroke-linecap="round" stroke-linejoin="round"/><text x="280" y="260" font-size="22" fill="#087f78" font-weight="600" text-anchor="middle">Reveal + sign</text><rect x="415" y="104" width="332" height="176" rx="22" fill="#dceee7" stroke="none" stroke-width="2"/><text x="443" y="146" font-size="20" fill="#647780" font-weight="400" text-anchor="start">Same identity</text><text x="443" y="205" font-size="47" fill="#182f3b" font-weight="700" text-anchor="start">alice</text><text x="443" y="247" font-size="19" fill="#087f78" font-weight="600" text-anchor="start">The registry</text><path d="M770 194 L902 194" fill="none" stroke="#087f78" stroke-width="4" stroke-linecap="round"/><path d="M890 186 L902 194 L890 202" fill="none" stroke="#087f78" stroke-width="4" stroke-linecap="round" stroke-linejoin="round"/><circle cx="1000" cy="155" r="19" fill="#087f78"/><path d="M965 211 Q965 182 1000 182 Q1035 182 1035 211" fill="#087f78"/><text x="1000" y="264" font-size="23" fill="#087f78" font-weight="600" text-anchor="middle">New controller</text><rect x="404" y="334" width="360" height="44" rx="22" fill="#dceee7" stroke="none" stroke-width="2"/><text x="584" y="364" font-size="20" fill="#087f78" font-weight="600" text-anchor="middle">Set up the next recovery</text></svg>

<!--
Use the backup key prepared earlier.

Reveal its controller and sign with that key. The old key is not needed.

Keep the same name, install the new controller and prepare the next recovery.

The old key no longer controls the name.
-->

---

<div class="eyebrow">ASKING TRUSTED PEOPLE TO END IT</div>

# As a name owner, I want my group to have retirement power<br>so that they can end my name without taking it over.

<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1120 460" role="img" aria-label="A fixed threshold of trusted people can initiate retirement. Their quorum authority cannot take over the name or redirect its payments. The controller can also retire independently." style="font-family:Arial,sans-serif"><title>A fixed threshold of trusted people can initiate retirement. Their quorum authority cannot take over the name or redirect its payments. The controller can also retire independently.</title><circle cx="85" cy="154" r="19" fill="#087f78"/><path d="M50 210 Q50 181 85 181 Q120 181 120 210" fill="#087f78"/><circle cx="171" cy="154" r="19" fill="#087f78"/><path d="M136 210 Q136 181 171 181 Q206 181 206 210" fill="#087f78"/><circle cx="257" cy="154" r="19" fill="#647780"/><path d="M222 210 Q222 181 257 181 Q292 181 292 210" fill="#647780"/><text x="171" y="273" font-size="23" fill="#182f3b" font-weight="600" text-anchor="middle">Fixed group + threshold</text><path d="M304 173 L552 173" fill="none" stroke="#087f78" stroke-width="4" stroke-linecap="round"/><path d="M540 165 L552 173 L540 181" fill="none" stroke="#087f78" stroke-width="4" stroke-linecap="round" stroke-linejoin="round"/><text x="429" y="131" font-size="27" fill="#087f78" font-weight="600" text-anchor="middle">Retire</text><rect x="578" y="73" width="496" height="190" rx="22" fill="#dceee7" stroke="none" stroke-width="2"/><text x="826" y="131" font-size="45" fill="#182f3b" font-weight="700" text-anchor="middle">alice</text><text x="826" y="199" font-size="25" fill="#087f78" font-weight="600" text-anchor="middle">Awaiting completion</text><circle cx="419" cy="337" r="23" fill="#f5e1d9"/><path d="M411 329 L427 345" fill="none" stroke="#b54c3a" stroke-width="4" stroke-linecap="round"/><path d="M411 345 L427 329" fill="none" stroke="#b54c3a" stroke-width="4" stroke-linecap="round"/><text x="592" y="345" font-size="26" fill="#b54c3a" font-weight="600" text-anchor="middle">Take control</text><circle cx="764" cy="337" r="23" fill="#f5e1d9"/><path d="M756 329 L772 345" fill="none" stroke="#b54c3a" stroke-width="4" stroke-linecap="round"/><path d="M756 345 L772 329" fill="none" stroke="#b54c3a" stroke-width="4" stroke-linecap="round"/><text x="952" y="345" font-size="24" fill="#b54c3a" font-weight="600" text-anchor="middle">Redirect payments</text><text x="558" y="433" font-size="23" fill="#647780" font-weight="400" text-anchor="middle">Alice can also retire it herself.</text></svg>

<!--
The trusted group can retire the name. It cannot take control or redirect payments.

Enough distinct members must sign.

Alice can also retire it herself.

Choose the group carefully. It can retire the name against her wishes.
-->

---

<div class="eyebrow">FINISHING THE RETIREMENT</div>

# As a name owner, I want anyone to finish my retirement<br>so that completion needs no further approval from me.

<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1120 460" role="img" aria-label="Alice or her quorum initiates retirement. The representative waits in completion-only custody. Anyone can submit valid completion, burning it and making the name Over." style="font-family:Arial,sans-serif"><title>Alice or her quorum initiates retirement. The representative waits in completion-only custody. Anyone can submit valid completion, burning it and making the name Over.</title><rect x="18" y="96" width="278" height="176" rx="22" fill="#ffffff" stroke="none" stroke-width="2"/><text x="46" y="138" font-size="20" fill="#647780" font-weight="400" text-anchor="start">Active</text><text x="46" y="197" font-size="47" fill="#182f3b" font-weight="700" text-anchor="start">alice</text><text x="46" y="239" font-size="19" fill="#087f78" font-weight="600" text-anchor="start">The registry</text><path d="M316 187 L393 187" fill="none" stroke="#087f78" stroke-width="4" stroke-linecap="round"/><path d="M381 179 L393 187 L381 195" fill="none" stroke="#087f78" stroke-width="4" stroke-linecap="round" stroke-linejoin="round"/><rect x="414" y="96" width="290" height="229" rx="22" fill="#f3e8c8" stroke="none" stroke-width="2"/><text x="559" y="142" font-size="43" fill="#182f3b" font-weight="700" text-anchor="middle">alice</text><text x="559" y="206" font-size="23" fill="#946313" font-weight="600" text-anchor="middle">Retirement pending</text><text x="559" y="258" font-size="20" fill="#946313" font-weight="400" text-anchor="middle">Held for completion</text><path d="M725 187 L802 187" fill="none" stroke="#087f78" stroke-width="4" stroke-linecap="round"/><path d="M790 179 L802 187 L790 195" fill="none" stroke="#087f78" stroke-width="4" stroke-linecap="round" stroke-linejoin="round"/><rect x="823" y="96" width="276" height="229" rx="22" fill="#182f3b" stroke="none" stroke-width="2"/><text x="961" y="142" font-size="43" fill="#f7f5ef" font-weight="700" text-anchor="middle">alice</text><text x="961" y="210" font-size="37" fill="#a9ded0" font-weight="700" text-anchor="middle">Over</text><text x="961" y="263" font-size="19" fill="#f7f5ef" font-weight="400" text-anchor="middle">Permanently retired</text><text x="355" y="363" font-size="20" fill="#647780" font-weight="400" text-anchor="middle">Alice or quorum</text><text x="764" y="363" font-size="20" fill="#087f78" font-weight="600" text-anchor="middle">Anyone completes</text></svg>

<!--
Retirement takes two steps.

Alice or the group starts it. The representative is held until completion.

Anyone can finish the valid retirement. Completion burns the representative and makes the name permanently retired.

Pending retirement is not yet complete.
-->

---

<div class="eyebrow">PREVENTING REUSE</div>

# As a name owner, I want my retired name to stay occupied<br>so that nobody can reuse it in this registry.

<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1120 460" role="img" aria-label="Once retirement is complete, alice remains occupied in this registry and a new claim cannot reuse it." style="font-family:Arial,sans-serif"><title>Once retirement is complete, alice remains occupied in this registry and a new claim cannot reuse it.</title><rect x="58" y="88" width="380" height="279" rx="22" fill="#182f3b" stroke="none" stroke-width="2"/><text x="248" y="164" font-size="64" fill="#f7f5ef" font-weight="700" text-anchor="middle">alice</text><text x="248" y="229" font-size="34" fill="#a9ded0" font-weight="600" text-anchor="middle">Over</text><text x="248" y="320" font-size="24" fill="#f7f5ef" font-weight="400" text-anchor="middle">Permanently occupied</text><circle cx="966" cy="101" r="19" fill="#647780"/><path d="M931 157 Q931 128 966 128 Q1001 128 1001 157" fill="#647780"/><text x="966" y="210" font-size="23" fill="#647780" font-weight="400" text-anchor="middle">New claimant</text><rect x="776" y="260" width="316" height="105" rx="22" fill="#ffffff" stroke="none" stroke-width="2"/><text x="934" y="303" font-size="30" fill="#182f3b" font-weight="600" text-anchor="middle">Claim alice</text><text x="934" y="338" font-size="19" fill="#647780" font-weight="400" text-anchor="middle">Same registry</text><path d="M776 310 L513 310" fill="none" stroke="#b54c3a" stroke-width="4" stroke-linecap="round"/><circle cx="559" cy="310" r="23" fill="#f5e1d9"/><path d="M551 302 L567 318" fill="none" stroke="#b54c3a" stroke-width="4" stroke-linecap="round"/><path d="M551 318 L567 302" fill="none" stroke="#b54c3a" stroke-width="4" stroke-linecap="round"/><text x="607" y="253" font-size="27" fill="#b54c3a" font-weight="600" text-anchor="middle">Refused</text></svg>

<!--
After completion, the same name cannot be claimed again in this registry.

Retirement is permanent. It does not transfer the name to somebody else.

It also cannot stop payments sent directly to a saved wallet address.
-->

---

<div class="eyebrow">THE PREPROD DEMO</div>

# As a reviewer, I want one connected preprod journey<br>so that I can inspect every transition on the ledger.

<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1120 460" role="img" aria-label="A planned connected preprod demonstration: claim, activate by fold, recover, retire, and complete retirement. Every transaction is still pending." style="font-family:Arial,sans-serif"><title>A planned connected preprod demonstration: claim, activate by fold, recover, retire, and complete retirement. Every transaction is still pending.</title><rect x="340" y="26" width="440" height="44" rx="22" fill="#f3e8c8" stroke="none" stroke-width="2"/><text x="560" y="56" font-size="20" fill="#946313" font-weight="600" text-anchor="middle">preprod run pending (#78)</text><rect x="12" y="135" width="208" height="220" rx="22" fill="#ffffff" stroke="none" stroke-width="2"/><circle cx="116" cy="184" r="24" fill="#f3e8c8"/><text x="116" y="193" font-size="25" fill="#946313" font-weight="600" text-anchor="middle">1</text><text x="116" y="247" font-size="28" fill="#182f3b" font-weight="600" text-anchor="middle">Claim</text><text x="116" y="291" font-size="17" fill="#647780" font-weight="400" text-anchor="middle">Pending request</text><text x="116" y="332" font-size="18" fill="#946313" font-weight="400" text-anchor="middle">TX pending</text><path d="M221 240 L234 240" fill="none" stroke="#647780" stroke-width="4" stroke-linecap="round" stroke-dasharray="9 9"/><path d="M222 232 L234 240 L222 248" fill="none" stroke="#647780" stroke-width="4" stroke-linecap="round" stroke-linejoin="round"/><rect x="234" y="135" width="208" height="220" rx="22" fill="#ffffff" stroke="none" stroke-width="2"/><circle cx="338" cy="184" r="24" fill="#f3e8c8"/><text x="338" y="193" font-size="25" fill="#946313" font-weight="600" text-anchor="middle">2</text><text x="338" y="247" font-size="28" fill="#182f3b" font-weight="600" text-anchor="middle">Activate</text><text x="338" y="291" font-size="17" fill="#647780" font-weight="400" text-anchor="middle">Name registered</text><text x="338" y="332" font-size="18" fill="#946313" font-weight="400" text-anchor="middle">TX pending</text><path d="M443 240 L456 240" fill="none" stroke="#647780" stroke-width="4" stroke-linecap="round" stroke-dasharray="9 9"/><path d="M444 232 L456 240 L444 248" fill="none" stroke="#647780" stroke-width="4" stroke-linecap="round" stroke-linejoin="round"/><rect x="456" y="135" width="208" height="220" rx="22" fill="#ffffff" stroke="none" stroke-width="2"/><circle cx="560" cy="184" r="24" fill="#f3e8c8"/><text x="560" y="193" font-size="25" fill="#946313" font-weight="600" text-anchor="middle">3</text><text x="560" y="247" font-size="28" fill="#182f3b" font-weight="600" text-anchor="middle">Recover</text><text x="560" y="291" font-size="17" fill="#647780" font-weight="400" text-anchor="middle">New controller</text><text x="560" y="332" font-size="18" fill="#946313" font-weight="400" text-anchor="middle">TX pending</text><path d="M665 240 L678 240" fill="none" stroke="#647780" stroke-width="4" stroke-linecap="round" stroke-dasharray="9 9"/><path d="M666 232 L678 240 L666 248" fill="none" stroke="#647780" stroke-width="4" stroke-linecap="round" stroke-linejoin="round"/><rect x="678" y="135" width="208" height="220" rx="22" fill="#ffffff" stroke="none" stroke-width="2"/><circle cx="782" cy="184" r="24" fill="#f3e8c8"/><text x="782" y="193" font-size="25" fill="#946313" font-weight="600" text-anchor="middle">4</text><text x="782" y="247" font-size="28" fill="#182f3b" font-weight="600" text-anchor="middle">Retire</text><text x="782" y="291" font-size="17" fill="#647780" font-weight="400" text-anchor="middle">Held for completion</text><text x="782" y="332" font-size="18" fill="#946313" font-weight="400" text-anchor="middle">TX pending</text><path d="M887 240 L900 240" fill="none" stroke="#647780" stroke-width="4" stroke-linecap="round" stroke-dasharray="9 9"/><path d="M888 232 L900 240 L888 248" fill="none" stroke="#647780" stroke-width="4" stroke-linecap="round" stroke-linejoin="round"/><rect x="900" y="135" width="208" height="220" rx="22" fill="#ffffff" stroke="none" stroke-width="2"/><circle cx="1004" cy="184" r="24" fill="#f3e8c8"/><text x="1004" y="193" font-size="25" fill="#946313" font-weight="600" text-anchor="middle">5</text><text x="1004" y="247" font-size="28" fill="#182f3b" font-weight="600" text-anchor="middle">Complete</text><text x="1004" y="291" font-size="17" fill="#647780" font-weight="400" text-anchor="middle">Permanently retired</text><text x="1004" y="332" font-size="18" fill="#946313" font-weight="400" text-anchor="middle">TX pending</text><text x="560" y="420" font-size="25" fill="#647780" font-weight="400" text-anchor="middle">One name · One registry · Five real transactions</text></svg>

<!--
Follow one name through claim, registration, recovery, retirement and completion.

Show the real transaction for each step.

The connected preprod run is still pending. Do not present the sequence as executed until those transactions exist.
-->
