# Off-chain API reference

A contributor reading the builder and blueprint guide wants to click a
module of this library and land on its real interface — signatures,
documentation, and the highlighted source — for exactly the code this
repository ships. This page is the entry point of that reference for the
off-chain registry library: a generated Haddock reference, rebuilt with
the documentation site from this same source tree, so what you read here
documents exactly the code this candidate was built from — and, as the
extent below states, a few of its modules are documented for the
contributor without being importable by a caller. One boundary on that
promise is named below: identifiers and modules that belong to other
packages are visible in the generated pages but are not clickable,
because their documentation is not bundled with this site.

## What this reference contains

Every module of the off-chain registry library is listed below. Each entry
links two pages of the generated reference: the module page — exports,
types, and documented declarations — and the hyperlinked source page with
the rendered, highlighted Haskell this candidate was built from. On this
site the links open the generated pages; read from the repository, the
same links open the source files themselves at the revision you are
viewing.

The module extent is the public library of the off-chain Cabal file — every
exposed module, every internal module, and every module the library
re-exports under its own name. That complete extent is 63 modules in
three kinds: 48 explicitly exposed modules and two re-exported modules
are what a caller imports; the two trie capability owners behind the
`TrieState` facade (`Singular.Registry.TrieState.Core` and `.Types`),
the three fold owners behind the `Update`
facade — `Singular.Registry.TxBuilder.Update.Build`, `.Context` and
`.Duties` — the five wire owners behind the `Types` facade —
`Singular.Registry.Wire.Primitive`, `.Request`, `.State`, `.Proof` and
`.Redeemer` — and the three deployment owners behind the `Deployment`
facade — `Singular.Registry.Deployment.Manifest`, `.Mirror` and
`.Attach` — are package-internal `other-modules` with generated pages
here for the contributor reading the facades' implementations, but no
caller import path: a caller compiles against the facades' exports, not
against these modules. `Singular.Registry.Ledger` and
`Singular.Registry.Provider` are the re-exports: their implementations
are owned by the public `local-services` component
(`offchain/local-services/`) and the main library re-exports them, so
their import paths and their entries in this reference are unchanged.
The private node runtime owners are deliberately not
part of this reference — they are not importable from the public library
— and are documented with source links in
[Node module ownership](offchain-node-ownership.md). The extent below is
the complete documented module surface — exposed, re-exported and
package-internal alike; the site check fails until it and this list
agree.

- <a href="../offchain/lib/Singular/Application/OpenDatum/Book.hs" data-api="module">Singular.Application.OpenDatum.Book</a> — <a href="../offchain/lib/Singular/Application/OpenDatum/Book.hs" data-api="source">source</a>
- <a href="../offchain/lib/Singular/Application/OpenDatum/Build.hs" data-api="module">Singular.Application.OpenDatum.Build</a> — <a href="../offchain/lib/Singular/Application/OpenDatum/Build.hs" data-api="source">source</a>
- <a href="../offchain/lib/Singular/Application/OpenDatum/Envelope.hs" data-api="module">Singular.Application.OpenDatum.Envelope</a> — <a href="../offchain/lib/Singular/Application/OpenDatum/Envelope.hs" data-api="source">source</a>
- <a href="../offchain/lib/Singular/Application/OpenDatum/Release.hs" data-api="module">Singular.Application.OpenDatum.Release</a> — <a href="../offchain/lib/Singular/Application/OpenDatum/Release.hs" data-api="source">source</a>
- <a href="../offchain/lib/Singular/Application/OpenDatum/Script.hs" data-api="module">Singular.Application.OpenDatum.Script</a> — <a href="../offchain/lib/Singular/Application/OpenDatum/Script.hs" data-api="source">source</a>
- <a href="../offchain/lib/Singular/Application/OpenDatum/Update.hs" data-api="module">Singular.Application.OpenDatum.Update</a> — <a href="../offchain/lib/Singular/Application/OpenDatum/Update.hs" data-api="source">source</a>
- <a href="../offchain/naming/src/Naming/Datum.hs" data-api="module">Naming.Datum</a> — <a href="../offchain/naming/src/Naming/Datum.hs" data-api="source">source</a>
- <a href="../offchain/naming/src/Naming/Register.hs" data-api="module">Naming.Register</a> — <a href="../offchain/naming/src/Naming/Register.hs" data-api="source">source</a>
- <a href="../offchain/naming/src/Naming/Request.hs" data-api="module">Naming.Request</a> — <a href="../offchain/naming/src/Naming/Request.hs" data-api="source">source</a>
- <a href="../offchain/naming/src/Naming/Verify.hs" data-api="module">Naming.Verify</a> — <a href="../offchain/naming/src/Naming/Verify.hs" data-api="source">source</a>
- <a href="../offchain/naming/src/Naming/Wire.hs" data-api="module">Naming.Wire</a> — <a href="../offchain/naming/src/Naming/Wire.hs" data-api="source">source</a>
- <a href="../offchain/naming/src/Naming/Wire/Vectors.hs" data-api="module">Naming.Wire.Vectors</a> — <a href="../offchain/naming/src/Naming/Wire/Vectors.hs" data-api="source">source</a>
- <a href="../offchain/lib/Singular/Provider/Koios/Client.hs" data-api="module">Singular.Provider.Koios.Client</a> — <a href="../offchain/lib/Singular/Provider/Koios/Client.hs" data-api="source">source</a>
- <a href="../offchain/lib/Singular/Provider/Koios/Recorded.hs" data-api="module">Singular.Provider.Koios.Recorded</a> — <a href="../offchain/lib/Singular/Provider/Koios/Recorded.hs" data-api="source">source</a>
- <a href="../offchain/lib/Singular/Provider/Koios/Wire.hs" data-api="module">Singular.Provider.Koios.Wire</a> — <a href="../offchain/lib/Singular/Provider/Koios/Wire.hs" data-api="source">source</a>
- <a href="../offchain/lib/Singular/Registry/AssetName.hs" data-api="module">Singular.Registry.AssetName</a> — <a href="../offchain/lib/Singular/Registry/AssetName.hs" data-api="source">source</a>
- <a href="../offchain/lib/Singular/Registry/Blueprint.hs" data-api="module">Singular.Registry.Blueprint</a> — <a href="../offchain/lib/Singular/Registry/Blueprint.hs" data-api="source">source</a>
- <a href="../offchain/lib/Singular/Registry/Blueprint/Load.hs" data-api="module">Singular.Registry.Blueprint.Load</a> — <a href="../offchain/lib/Singular/Registry/Blueprint/Load.hs" data-api="source">source</a>
- <a href="../offchain/lib/Singular/Registry/Blueprint/Params.hs" data-api="module">Singular.Registry.Blueprint.Params</a> — <a href="../offchain/lib/Singular/Registry/Blueprint/Params.hs" data-api="source">source</a>
- <a href="../offchain/lib/Singular/Registry/Blueprint/Schema.hs" data-api="module">Singular.Registry.Blueprint.Schema</a> — <a href="../offchain/lib/Singular/Registry/Blueprint/Schema.hs" data-api="source">source</a>
- <a href="../offchain/lib/Singular/Registry/Candidate.hs" data-api="module">Singular.Registry.Candidate</a> — <a href="../offchain/lib/Singular/Registry/Candidate.hs" data-api="source">source</a>
- <a href="../offchain/lib/Singular/Registry/Config.hs" data-api="module">Singular.Registry.Config</a> — <a href="../offchain/lib/Singular/Registry/Config.hs" data-api="source">source</a>
- <a href="../offchain/lib/Singular/Registry/Config/Application.hs" data-api="module">Singular.Registry.Config.Application</a> — <a href="../offchain/lib/Singular/Registry/Config/Application.hs" data-api="source">source</a>
- <a href="../offchain/lib/Singular/Registry/Deployment.hs" data-api="module">Singular.Registry.Deployment</a> — <a href="../offchain/lib/Singular/Registry/Deployment.hs" data-api="source">source</a>
- <a href="../offchain/lib/Singular/Registry/Deployment/Attach.hs" data-api="module">Singular.Registry.Deployment.Attach</a> — <a href="../offchain/lib/Singular/Registry/Deployment/Attach.hs" data-api="source">source</a>
- <a href="../offchain/lib/Singular/Registry/Deployment/Manifest.hs" data-api="module">Singular.Registry.Deployment.Manifest</a> — <a href="../offchain/lib/Singular/Registry/Deployment/Manifest.hs" data-api="source">source</a>
- <a href="../offchain/lib/Singular/Registry/Deployment/Mirror.hs" data-api="module">Singular.Registry.Deployment.Mirror</a> — <a href="../offchain/lib/Singular/Registry/Deployment/Mirror.hs" data-api="source">source</a>
- <a href="../offchain/lib/Singular/Registry/Driver.hs" data-api="module">Singular.Registry.Driver</a> — <a href="../offchain/lib/Singular/Registry/Driver.hs" data-api="source">source</a>
- <a href="../offchain/local-services/Singular/Registry/Ledger.hs" data-api="module">Singular.Registry.Ledger</a> — <a href="../offchain/local-services/Singular/Registry/Ledger.hs" data-api="source">source</a>
- <a href="../offchain/lib/Singular/Registry/Lifecycle.hs" data-api="module">Singular.Registry.Lifecycle</a> — <a href="../offchain/lib/Singular/Registry/Lifecycle.hs" data-api="source">source</a>
- <a href="../offchain/lib/Singular/Registry/Node.hs" data-api="module">Singular.Registry.Node</a> — <a href="../offchain/lib/Singular/Registry/Node.hs" data-api="source">source</a>
- <a href="../offchain/lib/Singular/Registry/Proof.hs" data-api="module">Singular.Registry.Proof</a> — <a href="../offchain/lib/Singular/Registry/Proof.hs" data-api="source">source</a>
- <a href="../offchain/local-services/Singular/Registry/Provider.hs" data-api="module">Singular.Registry.Provider</a> — <a href="../offchain/local-services/Singular/Registry/Provider.hs" data-api="source">source</a>
- <a href="../offchain/lib/Singular/Registry/Replay.hs" data-api="module">Singular.Registry.Replay</a> — <a href="../offchain/lib/Singular/Registry/Replay.hs" data-api="source">source</a>
- <a href="../offchain/lib/Singular/Registry/Trie.hs" data-api="module">Singular.Registry.Trie</a> — <a href="../offchain/lib/Singular/Registry/Trie.hs" data-api="source">source</a>
- <a href="../offchain/lib/Singular/Registry/Trie/Pure.hs" data-api="module">Singular.Registry.Trie.Pure</a> — <a href="../offchain/lib/Singular/Registry/Trie/Pure.hs" data-api="source">source</a>
- <a href="../offchain/lib/Singular/Registry/Trie/PureManager.hs" data-api="module">Singular.Registry.Trie.PureManager</a> — <a href="../offchain/lib/Singular/Registry/Trie/PureManager.hs" data-api="source">source</a>
- <a href="../offchain/lib/Singular/Registry/TrieState.hs" data-api="module">Singular.Registry.TrieState</a> — <a href="../offchain/lib/Singular/Registry/TrieState.hs" data-api="source">source</a>
- <a href="../offchain/lib/Singular/Registry/TrieState/Core.hs" data-api="module">Singular.Registry.TrieState.Core</a> — <a href="../offchain/lib/Singular/Registry/TrieState/Core.hs" data-api="source">source</a>
- <a href="../offchain/lib/Singular/Registry/TrieState/Fixture.hs" data-api="module">Singular.Registry.TrieState.Fixture</a> — <a href="../offchain/lib/Singular/Registry/TrieState/Fixture.hs" data-api="source">source</a>
- <a href="../offchain/lib/Singular/Registry/TrieState/Mirror.hs" data-api="module">Singular.Registry.TrieState.Mirror</a> — <a href="../offchain/lib/Singular/Registry/TrieState/Mirror.hs" data-api="source">source</a>
- <a href="../offchain/lib/Singular/Registry/TrieState/Types.hs" data-api="module">Singular.Registry.TrieState.Types</a> — <a href="../offchain/lib/Singular/Registry/TrieState/Types.hs" data-api="source">source</a>
- <a href="../offchain/lib/Singular/Registry/TxBuilder/Boot.hs" data-api="module">Singular.Registry.TxBuilder.Boot</a> — <a href="../offchain/lib/Singular/Registry/TxBuilder/Boot.hs" data-api="source">source</a>
- <a href="../offchain/lib/Singular/Registry/TxBuilder/ConnectedFold.hs" data-api="module">Singular.Registry.TxBuilder.ConnectedFold</a> — <a href="../offchain/lib/Singular/Registry/TxBuilder/ConnectedFold.hs" data-api="source">source</a>
- <a href="../offchain/lib/Singular/Registry/TxBuilder/Edges.hs" data-api="module">Singular.Registry.TxBuilder.Edges</a> — <a href="../offchain/lib/Singular/Registry/TxBuilder/Edges.hs" data-api="source">source</a>
- <a href="../offchain/lib/Singular/Registry/TxBuilder/Internal.hs" data-api="module">Singular.Registry.TxBuilder.Internal</a> — <a href="../offchain/lib/Singular/Registry/TxBuilder/Internal.hs" data-api="source">source</a>
- <a href="../offchain/lib/Singular/Registry/TxBuilder/Internal/Edges.hs" data-api="module">Singular.Registry.TxBuilder.Internal.Edges</a> — <a href="../offchain/lib/Singular/Registry/TxBuilder/Internal/Edges.hs" data-api="source">source</a>
- <a href="../offchain/lib/Singular/Registry/TxBuilder/Internal/Identity.hs" data-api="module">Singular.Registry.TxBuilder.Internal.Identity</a> — <a href="../offchain/lib/Singular/Registry/TxBuilder/Internal/Identity.hs" data-api="source">source</a>
- <a href="../offchain/lib/Singular/Registry/TxBuilder/Internal/Lookup.hs" data-api="module">Singular.Registry.TxBuilder.Internal.Lookup</a> — <a href="../offchain/lib/Singular/Registry/TxBuilder/Internal/Lookup.hs" data-api="source">source</a>
- <a href="../offchain/lib/Singular/Registry/TxBuilder/Register.hs" data-api="module">Singular.Registry.TxBuilder.Register</a> — <a href="../offchain/lib/Singular/Registry/TxBuilder/Register.hs" data-api="source">source</a>
- <a href="../offchain/lib/Singular/Registry/TxBuilder/Reject.hs" data-api="module">Singular.Registry.TxBuilder.Reject</a> — <a href="../offchain/lib/Singular/Registry/TxBuilder/Reject.hs" data-api="source">source</a>
- <a href="../offchain/lib/Singular/Registry/TxBuilder/Request.hs" data-api="module">Singular.Registry.TxBuilder.Request</a> — <a href="../offchain/lib/Singular/Registry/TxBuilder/Request.hs" data-api="source">source</a>
- <a href="../offchain/lib/Singular/Registry/TxBuilder/Retract.hs" data-api="module">Singular.Registry.TxBuilder.Retract</a> — <a href="../offchain/lib/Singular/Registry/TxBuilder/Retract.hs" data-api="source">source</a>
- <a href="../offchain/lib/Singular/Registry/TxBuilder/Update.hs" data-api="module">Singular.Registry.TxBuilder.Update</a> — <a href="../offchain/lib/Singular/Registry/TxBuilder/Update.hs" data-api="source">source</a>
- <a href="../offchain/lib/Singular/Registry/TxBuilder/Update/Build.hs" data-api="module">Singular.Registry.TxBuilder.Update.Build</a> — <a href="../offchain/lib/Singular/Registry/TxBuilder/Update/Build.hs" data-api="source">source</a>
- <a href="../offchain/lib/Singular/Registry/TxBuilder/Update/Context.hs" data-api="module">Singular.Registry.TxBuilder.Update.Context</a> — <a href="../offchain/lib/Singular/Registry/TxBuilder/Update/Context.hs" data-api="source">source</a>
- <a href="../offchain/lib/Singular/Registry/TxBuilder/Update/Duties.hs" data-api="module">Singular.Registry.TxBuilder.Update.Duties</a> — <a href="../offchain/lib/Singular/Registry/TxBuilder/Update/Duties.hs" data-api="source">source</a>
- <a href="../offchain/lib/Singular/Registry/Types.hs" data-api="module">Singular.Registry.Types</a> — <a href="../offchain/lib/Singular/Registry/Types.hs" data-api="source">source</a>
- <a href="../offchain/lib/Singular/Registry/Wire/Primitive.hs" data-api="module">Singular.Registry.Wire.Primitive</a> — <a href="../offchain/lib/Singular/Registry/Wire/Primitive.hs" data-api="source">source</a>
- <a href="../offchain/lib/Singular/Registry/Wire/Proof.hs" data-api="module">Singular.Registry.Wire.Proof</a> — <a href="../offchain/lib/Singular/Registry/Wire/Proof.hs" data-api="source">source</a>
- <a href="../offchain/lib/Singular/Registry/Wire/Redeemer.hs" data-api="module">Singular.Registry.Wire.Redeemer</a> — <a href="../offchain/lib/Singular/Registry/Wire/Redeemer.hs" data-api="source">source</a>
- <a href="../offchain/lib/Singular/Registry/Wire/Request.hs" data-api="module">Singular.Registry.Wire.Request</a> — <a href="../offchain/lib/Singular/Registry/Wire/Request.hs" data-api="source">source</a>
- <a href="../offchain/lib/Singular/Registry/Wire/State.hs" data-api="module">Singular.Registry.Wire.State</a> — <a href="../offchain/lib/Singular/Registry/Wire/State.hs" data-api="source">source</a>

The facades and owners of the registry builder and blueprint extraction
are described module by module in the
[builder and blueprint modules](offchain-builder-blueprint.md) guide, and
the registry wire's five owners behind the `Types` facade in
[Who owns the registry wire](offchain-wire-types.md).

## How the reference stays honest

The reference cannot drift from the code it claims to document. The site
build derives a manifest from the same off-chain source input Haddock
ran on: for every module it records the digest of the Haskell source file
and the digest of the actual generated source page. The site check then
redoes both halves independently from this repository's own source tree —
the manifest's module extent must equal the Cabal library extent, each
recorded source digest must match the repository's file, and each
generated page in the shipped site must match its recorded digest. A
reference generated from any other source, however its label reads, fails
that comparison; a page edited after generation fails its own digest.

Every link inside the generated pages is inspected too. A reference from
one module of this library to another — a type, a function, a module,
however the tool that generated it spelled it — must resolve to a page of
this reference and, where it names an anchor, to an anchor that exists.
The check prints how many same-library links it resolved, and the
reference's own index and guide links are checked by the site's ordinary
link inventory.

Dependency documentation is a different matter. The library is built
against a large Cardano and Plutus dependency closure, and none of those
packages' Haddock pages are bundled into this site: a type such as a
ledger address or a Plutus core data value appears in the generated pages
as a visible label, but it is not a link — following it would leave this
site for documentation that is not shipped with it. Neutralizing those
labels is decided from the build's own package database, which positively
names every module each dependency owns, so a label is only unlinked when
it provably belongs to a dependency; a dead or store-path link that
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
shipped: the staged documentation archive must carry the generated
reference member for member and byte for byte before the ordinary release
checks run.

## What the reference does not claim

This reference covers the off-chain registry library only. The four
registry commands — the journey, `insert-active`, `update-terminal` and
`deployment` — are executables, not library modules: their
command-local modules are documented with source links in
[Who owns a registry command](offchain-command-entrypoints.md), and the
library interfaces they call are the ones listed above. The conformance
suite's own library now has its own generated reference — the
[Conformance API reference](conformance-api-reference.md) — generated
and checked by the same discipline from the Conformance tree. Together
the two references cover the documented module surfaces of the two
public libraries, no more: this reference's extent is the off-chain
main library's, with the private node runtime owners staying
outside it in [Node module ownership](offchain-node-ownership.md), and
the conformance reference's extent is the conformance library's. The
package-private node-internal library, the executables and the on-chain
Aiken validators remain outside the generated references. The public
`local-services` component also exposes `LocalEvaluation`, `NetworkTime`,
`PhaseLog`, `Services` and `TimeMaterial`; their sources live under
`offchain/local-services/Singular/Registry/`. Their generated pages are not
in this main-library reference. This coverage gap stays visible; wider
generated coverage is a separate decision for the epic's owner, not a
claim this page makes. Nothing on
this page is a publication or release claim — the reference ships with
the candidate site and its future archives, and no version is tagged or
published by existing here. The behavioral evidence for the moved builder,
blueprint and wire code lives in the check commands the off-chain
development guide records, not in the existence of these pages.
