# Conformance API reference

A contributor changing the conformance library — a story program, a model
binding, a comparison, a receipt check, a rendering — wants to click a
module and land on its real interface: signatures, documentation, and the
highlighted source, for exactly the code this repository ships. This page
is the entry point of that reference for the Conformance library: a
generated Haddock reference, rebuilt with the documentation site from this
same source tree, so what you read here documents exactly the code this
candidate was built from. One boundary on that promise is named below:
identifiers and modules that belong to other packages are visible in the
generated pages but are not clickable, because their documentation is not
bundled with this site.

## What this reference contains

Every module of the Conformance library is listed below. Each entry links
two pages of the generated reference: the module page — exports, types,
and documented declarations — and the hyperlinked source page with the
rendered, highlighted Haskell this candidate was built from. The
reference's own <a href="../conformance/" data-api="index">full-page
index</a> and <a href="../conformance/" data-api="symbols">symbol
index</a> are linked here too. On this site the links open the generated
pages; read from the repository, the module links open the source files
themselves at the revision you are viewing.

The module extent is the public library of the Conformance Cabal file —
every exposed module and the one package-internal owner. That complete
extent is 31 modules. The 30 exposed modules are what a caller imports:
the story programs, the registry rows as programs with their
classification, the stories' binding and identity, the ordinary CLI's
refusal controls and their receipt-computed verdicts, the model transport
and the Lean oracle, the registration and perturbation comparisons, the
receipt record and its validation, the refusal attribution, the row
inventory, the purpose-unit arithmetic, the node-refusal rendering, the payment
observation, the traced replay's classification of a live refusal and the
extent of a run's refusals against the model. The one package-internal module,
`Conformance.Evidence.Asset`, owns the asset-movement shape of edge
evidence — one movement named by its policy, asset name and quantity,
with the JSON encoding that carries those three fields. It is documented
here for the contributor reading the facade's implementation;
`Conformance.Receipt` re-exports its type, so no caller import path
changes. The extent below is the complete documented module surface, and
the site check fails until it and this list agree.

- <a href="../conformance/lib/Conformance/Authenticate.hs" data-api="module">Conformance.Authenticate</a> — <a href="../conformance/lib/Conformance/Authenticate.hs" data-api="source">source</a>
- <a href="../conformance/lib/Conformance/Book.hs" data-api="module">Conformance.Book</a> — <a href="../conformance/lib/Conformance/Book.hs" data-api="source">source</a>
- <a href="../conformance/lib/Conformance/Cli/Controls.hs" data-api="module">Conformance.Cli.Controls</a> — <a href="../conformance/lib/Conformance/Cli/Controls.hs" data-api="source">source</a>
- <a href="../conformance/lib/Conformance/Compare/Perturbation.hs" data-api="module">Conformance.Compare.Perturbation</a> — <a href="../conformance/lib/Conformance/Compare/Perturbation.hs" data-api="source">source</a>
- <a href="../conformance/lib/Conformance/Compare/Registration.hs" data-api="module">Conformance.Compare.Registration</a> — <a href="../conformance/lib/Conformance/Compare/Registration.hs" data-api="source">source</a>
- <a href="../conformance/lib/Conformance/Edge/EarlyReject.hs" data-api="module">Conformance.Edge.EarlyReject</a> — <a href="../conformance/lib/Conformance/Edge/EarlyReject.hs" data-api="source">source</a>
- <a href="../conformance/lib/Conformance/Edge/Exit.hs" data-api="module">Conformance.Edge.Exit</a> — <a href="../conformance/lib/Conformance/Edge/Exit.hs" data-api="source">source</a>
- <a href="../conformance/lib/Conformance/Edge/Occupied.hs" data-api="module">Conformance.Edge.Occupied</a> — <a href="../conformance/lib/Conformance/Edge/Occupied.hs" data-api="source">source</a>
- <a href="../conformance/lib/Conformance/Edge/Programs.hs" data-api="module">Conformance.Edge.Programs</a> — <a href="../conformance/lib/Conformance/Edge/Programs.hs" data-api="source">source</a>
- <a href="../conformance/lib/Conformance/Edge/Register.hs" data-api="module">Conformance.Edge.Register</a> — <a href="../conformance/lib/Conformance/Edge/Register.hs" data-api="source">source</a>
- <a href="../conformance/lib/Conformance/Edge/Retire.hs" data-api="module">Conformance.Edge.Retire</a> — <a href="../conformance/lib/Conformance/Edge/Retire.hs" data-api="source">source</a>
- <a href="../conformance/lib/Conformance/Edge/RetractionWindow.hs" data-api="module">Conformance.Edge.RetractionWindow</a> — <a href="../conformance/lib/Conformance/Edge/RetractionWindow.hs" data-api="source">source</a>
- <a href="../conformance/lib/Conformance/Edge/Sequence.hs" data-api="module">Conformance.Edge.Sequence</a> — <a href="../conformance/lib/Conformance/Edge/Sequence.hs" data-api="source">source</a>
- <a href="../conformance/lib/Conformance/Evidence/Asset.hs" data-api="module">Conformance.Evidence.Asset</a> — <a href="../conformance/lib/Conformance/Evidence/Asset.hs" data-api="source">source</a>
- <a href="../conformance/lib/Conformance/EvidencePage.hs" data-api="module">Conformance.EvidencePage</a> — <a href="../conformance/lib/Conformance/EvidencePage.hs" data-api="source">source</a>
- <a href="../conformance/lib/Conformance/Extent.hs" data-api="module">Conformance.Extent</a> — <a href="../conformance/lib/Conformance/Extent.hs" data-api="source">source</a>
- <a href="../conformance/lib/Conformance/Fold/KeyedMint.hs" data-api="module">Conformance.Fold.KeyedMint</a> — <a href="../conformance/lib/Conformance/Fold/KeyedMint.hs" data-api="source">source</a>
- <a href="../conformance/lib/Conformance/Lean/Oracle.hs" data-api="module">Conformance.Lean.Oracle</a> — <a href="../conformance/lib/Conformance/Lean/Oracle.hs" data-api="source">source</a>
- <a href="../conformance/lib/Conformance/Lean/Registration.hs" data-api="module">Conformance.Lean.Registration</a> — <a href="../conformance/lib/Conformance/Lean/Registration.hs" data-api="source">source</a>
- <a href="../conformance/lib/Conformance/Lean/Retirement.hs" data-api="module">Conformance.Lean.Retirement</a> — <a href="../conformance/lib/Conformance/Lean/Retirement.hs" data-api="source">source</a>
- <a href="../conformance/lib/Conformance/NodeRejection.hs" data-api="module">Conformance.NodeRejection</a> — <a href="../conformance/lib/Conformance/NodeRejection.hs" data-api="source">source</a>
- <a href="../conformance/lib/Conformance/Observe/Payments.hs" data-api="module">Conformance.Observe.Payments</a> — <a href="../conformance/lib/Conformance/Observe/Payments.hs" data-api="source">source</a>
- <a href="../conformance/lib/Conformance/PurposeUnits.hs" data-api="module">Conformance.PurposeUnits</a> — <a href="../conformance/lib/Conformance/PurposeUnits.hs" data-api="source">source</a>
- <a href="../conformance/lib/Conformance/Receipt.hs" data-api="module">Conformance.Receipt</a> — <a href="../conformance/lib/Conformance/Receipt.hs" data-api="source">source</a>
- <a href="../conformance/lib/Conformance/Refusal.hs" data-api="module">Conformance.Refusal</a> — <a href="../conformance/lib/Conformance/Refusal.hs" data-api="source">source</a>
- <a href="../conformance/lib/Conformance/Replay.hs" data-api="module">Conformance.Replay</a> — <a href="../conformance/lib/Conformance/Replay.hs" data-api="source">source</a>
- <a href="../conformance/lib/Conformance/Rows.hs" data-api="module">Conformance.Rows</a> — <a href="../conformance/lib/Conformance/Rows.hs" data-api="source">source</a>
- <a href="../conformance/lib/Conformance/Story/Binding.hs" data-api="module">Conformance.Story.Binding</a> — <a href="../conformance/lib/Conformance/Story/Binding.hs" data-api="source">source</a>
- <a href="../conformance/lib/Conformance/Story/Identity.hs" data-api="module">Conformance.Story.Identity</a> — <a href="../conformance/lib/Conformance/Story/Identity.hs" data-api="source">source</a>
- <a href="../conformance/lib/Conformance/Story/Live.hs" data-api="module">Conformance.Story.Live</a> — <a href="../conformance/lib/Conformance/Story/Live.hs" data-api="source">source</a>
- <a href="../conformance/lib/Conformance/Story/Specification.hs" data-api="module">Conformance.Story.Specification</a> — <a href="../conformance/lib/Conformance/Story/Specification.hs" data-api="source">source</a>

## How the reference stays honest

The reference cannot drift from the code it claims to document. The site
build derives a manifest from the same Conformance source input Haddock
ran on: for every module it records the digest of the Haskell source file
and the digests of the actual generated module page and source page. The
site check then redoes both halves independently from this repository's
own source tree — the manifest's module extent must equal the Cabal
library extent, each recorded source digest must match the repository's
file, and each generated page in the shipped site must match its recorded
digest. A reference generated from any other source, however its label
reads, fails that comparison; a page edited after generation fails its
own digest.

Every link inside the generated pages is inspected too. A reference from
one module of this library to another — a type, a function, a module,
however the tool that generated it spelled it — must resolve to a page of
this reference and, where it names an anchor, to an anchor that exists.
The check prints how many same-library links it resolved, and this page's
links to the generated pages are checked by the site's ordinary link
inventory.

Dependency documentation is a different matter. The library is built
against a JSON, container and text dependency closure, and none of those
packages' Haddock pages are bundled into this site: a type such as an
aeson value or a strict text appears in the generated pages as a visible
label, but it is not a link — following it would leave this site for
documentation that is not shipped with it. Neutralizing those labels is
decided from the build's own package database, which positively names
every module each dependency owns, so a label is only unlinked when it
provably belongs to a dependency; a dead or store-path link that
reappears fails the site check, and a same-library reference may never be
treated as a dependency label to hide a broken link.

One further generator class is unlinked by structure. Haddock renders
instance method names in each instance's Methods list as same-page links,
but emits no matching anchors for them — every instance of a class lists
the same method names, so the anchor would have to be duplicated. Those
method labels stay visible as plain text inside the instance lists, and
the site check both counts them separately and still requires every
fragment link outside that exact structure to resolve.

The release archive check extends the same discipline to what gets
shipped: the staged documentation archive must carry this library's
generated reference member for member and byte for byte, alongside the
off-chain registry library's, before the ordinary release checks run.

## What the reference does not claim

This reference covers the Conformance library only. The live runner that
executes rows against a devnet is an executable, not a library module:
its application modules — the run control, the row runners, the wallet,
the cage and the observation code — are outside this reference, and the
evidence they produce is the published
[consumer conformance](consumer-conformance.md) record, not an API claim.
Nothing on this page is a publication or release claim — the reference
ships with the candidate site and its future archives, and no version is
tagged or published by existing here. The behavioral evidence for the
library lives in the check commands the documentation records, not in the
existence of these pages.
