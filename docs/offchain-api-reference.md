# Off-chain API reference

A contributor reading the builder and blueprint guide wants to click a
module name and land on the real interface — signatures, documentation,
and the highlighted source — for exactly the code this repository ships.
This page is the entry point of that reference for the off-chain registry
library: a generated Haddock reference, rebuilt with the documentation
site from this same source tree, so what you read here is what you would
compile against.

## What this reference contains

Every module of the off-chain registry library is listed below. Each entry
links two pages of the generated reference: the module page — exports,
types, and documented declarations — and the hyperlinked source page with
the rendered, highlighted Haskell this candidate was built from. On this
site the links open the generated pages; read from the repository, the
same links open the source files themselves at the revision you are
viewing.

The module extent is the library stanza of the off-chain Cabal file —
every exposed module and every internal module across all declared source
directories. The library currently declares no internal modules, so the
extent below is the public module surface; if one is added, this list and
the generated reference grow with it, and the site check fails until they
agree.

- <a href="../offchain/naming/src/Naming/Datum.hs" data-api="module">Naming.Datum</a> — <a href="../offchain/naming/src/Naming/Datum.hs" data-api="source">source</a>
- <a href="../offchain/naming/src/Naming/Register.hs" data-api="module">Naming.Register</a> — <a href="../offchain/naming/src/Naming/Register.hs" data-api="source">source</a>
- <a href="../offchain/naming/src/Naming/Request.hs" data-api="module">Naming.Request</a> — <a href="../offchain/naming/src/Naming/Request.hs" data-api="source">source</a>
- <a href="../offchain/naming/src/Naming/Verify.hs" data-api="module">Naming.Verify</a> — <a href="../offchain/naming/src/Naming/Verify.hs" data-api="source">source</a>
- <a href="../offchain/naming/src/Naming/Wire.hs" data-api="module">Naming.Wire</a> — <a href="../offchain/naming/src/Naming/Wire.hs" data-api="source">source</a>
- <a href="../offchain/naming/src/Naming/Wire/Vectors.hs" data-api="module">Naming.Wire.Vectors</a> — <a href="../offchain/naming/src/Naming/Wire/Vectors.hs" data-api="source">source</a>
- <a href="../offchain/lib/Singular/Registry/AssetName.hs" data-api="module">Singular.Registry.AssetName</a> — <a href="../offchain/lib/Singular/Registry/AssetName.hs" data-api="source">source</a>
- <a href="../offchain/lib/Singular/Registry/Blueprint.hs" data-api="module">Singular.Registry.Blueprint</a> — <a href="../offchain/lib/Singular/Registry/Blueprint.hs" data-api="source">source</a>
- <a href="../offchain/lib/Singular/Registry/Blueprint/Load.hs" data-api="module">Singular.Registry.Blueprint.Load</a> — <a href="../offchain/lib/Singular/Registry/Blueprint/Load.hs" data-api="source">source</a>
- <a href="../offchain/lib/Singular/Registry/Blueprint/Params.hs" data-api="module">Singular.Registry.Blueprint.Params</a> — <a href="../offchain/lib/Singular/Registry/Blueprint/Params.hs" data-api="source">source</a>
- <a href="../offchain/lib/Singular/Registry/Blueprint/Schema.hs" data-api="module">Singular.Registry.Blueprint.Schema</a> — <a href="../offchain/lib/Singular/Registry/Blueprint/Schema.hs" data-api="source">source</a>
- <a href="../offchain/lib/Singular/Registry/Candidate.hs" data-api="module">Singular.Registry.Candidate</a> — <a href="../offchain/lib/Singular/Registry/Candidate.hs" data-api="source">source</a>
- <a href="../offchain/lib/Singular/Registry/Config.hs" data-api="module">Singular.Registry.Config</a> — <a href="../offchain/lib/Singular/Registry/Config.hs" data-api="source">source</a>
- <a href="../offchain/lib/Singular/Registry/Deployment.hs" data-api="module">Singular.Registry.Deployment</a> — <a href="../offchain/lib/Singular/Registry/Deployment.hs" data-api="source">source</a>
- <a href="../offchain/lib/Singular/Registry/Driver.hs" data-api="module">Singular.Registry.Driver</a> — <a href="../offchain/lib/Singular/Registry/Driver.hs" data-api="source">source</a>
- <a href="../offchain/lib/Singular/Registry/Ledger.hs" data-api="module">Singular.Registry.Ledger</a> — <a href="../offchain/lib/Singular/Registry/Ledger.hs" data-api="source">source</a>
- <a href="../offchain/lib/Singular/Registry/Lifecycle.hs" data-api="module">Singular.Registry.Lifecycle</a> — <a href="../offchain/lib/Singular/Registry/Lifecycle.hs" data-api="source">source</a>
- <a href="../offchain/lib/Singular/Registry/Node.hs" data-api="module">Singular.Registry.Node</a> — <a href="../offchain/lib/Singular/Registry/Node.hs" data-api="source">source</a>
- <a href="../offchain/lib/Singular/Registry/Proof.hs" data-api="module">Singular.Registry.Proof</a> — <a href="../offchain/lib/Singular/Registry/Proof.hs" data-api="source">source</a>
- <a href="../offchain/lib/Singular/Registry/Provider.hs" data-api="module">Singular.Registry.Provider</a> — <a href="../offchain/lib/Singular/Registry/Provider.hs" data-api="source">source</a>
- <a href="../offchain/lib/Singular/Registry/Trie.hs" data-api="module">Singular.Registry.Trie</a> — <a href="../offchain/lib/Singular/Registry/Trie.hs" data-api="source">source</a>
- <a href="../offchain/lib/Singular/Registry/Trie/Pure.hs" data-api="module">Singular.Registry.Trie.Pure</a> — <a href="../offchain/lib/Singular/Registry/Trie/Pure.hs" data-api="source">source</a>
- <a href="../offchain/lib/Singular/Registry/Trie/PureManager.hs" data-api="module">Singular.Registry.Trie.PureManager</a> — <a href="../offchain/lib/Singular/Registry/Trie/PureManager.hs" data-api="source">source</a>
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
- <a href="../offchain/lib/Singular/Registry/Types.hs" data-api="module">Singular.Registry.Types</a> — <a href="../offchain/lib/Singular/Registry/Types.hs" data-api="source">source</a>

The facades and owners of the registry builder and blueprint extraction
are described module by module in the
[builder and blueprint modules](offchain-builder-blueprint.md) guide.

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

The release archive check extends the same discipline to what gets
shipped: the staged documentation archive must carry the generated
reference member for member and byte for byte before the ordinary release
checks run.

## What the reference does not claim

This reference covers the off-chain registry library only. It is not a
repository-wide API claim: the conformance suite's own library is
documented separately, and a generated reference for every library in
this repository is a later, independently checked extension. Nothing on
this page is a publication or release claim — the reference ships with
the candidate site and its future archives, and no version is tagged or
published by existing here. The behavioral evidence for the moved builder
and blueprint code lives in the check commands the off-chain development
guide records, not in the existence of these pages.
