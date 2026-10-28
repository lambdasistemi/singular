# Conformance API reference

As a contributor changing the evidence reader, I can open each module's
interface and highlighted source at the same revision as this site.
The generated Haddock reference covers the receipt validation, replay
classification, requirement inventory and computed evidence page.

## What this reference contains

Every module declared by the public Conformance library is listed below.
The site derives the extent from its Cabal manifest and checks both each
module page and its source page against that extent. The reference's own
<a href="../conformance/" data-api="index">full-page index</a> and
<a href="../conformance/" data-api="symbols">symbol index</a> provide the
same entry points across the complete library.

- <a href="../conformance/lib/Conformance/EvidencePage.hs" data-api="module">Conformance.EvidencePage</a> — <a href="../conformance/lib/Conformance/EvidencePage.hs" data-api="source">source</a>
- <a href="../conformance/lib/Conformance/Receipt.hs" data-api="module">Conformance.Receipt</a> — <a href="../conformance/lib/Conformance/Receipt.hs" data-api="source">source</a>
- <a href="../conformance/lib/Conformance/Replay.hs" data-api="module">Conformance.Replay</a> — <a href="../conformance/lib/Conformance/Replay.hs" data-api="source">source</a>
- <a href="../conformance/lib/Conformance/Rows.hs" data-api="module">Conformance.Rows</a> — <a href="../conformance/lib/Conformance/Rows.hs" data-api="source">source</a>

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

API documentation does not establish product conformance. The seven
application-held comparison requirements remain uncovered in
[the consumer record](consumer-conformance.md) and
[the generated evidence page](conformance-evidence.md). The appendix tests
check the reader; development-network journeys are a separate evidence
boundary and do not establish model agreement.
