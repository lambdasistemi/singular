# Occupied-name lookup is a presence sentinel, not the stored value

The installed CLI's first live-record adapter test exposed a wrong assumption:
accepted `Singular.Registry.Trie.Pure.pureLookup` (f558d0e base, lines177-193)
returns `hash(key)` whenever a proof exists, NOT the original stored value.
The interface comment says value, but prior runners use it only for occupancy.
The persisted MPF mirror carries hashed key/value material, not raw preimages.

Concrete evidence: evidence/write-devnet-2/setup.log confirms cli-write-check
folded Active with representative
526570ba06fabdc8924fb4e62fa127afed61b800acc920181f3acd794364c200.
The archive CLI's before.json reads a matching root but reports representative
0d60c2f08eb9e93c6b5e9b5c645074f091845671d89b9857ae0e07c7df486bd6,
which is the key sentinel. Both wrong-key and correct-key maintenance refuse
record-unavailable; this is NOT an authorization control. No mutation was
submitted by the CLI. Evidence under evidence/write-devnet-2; archive66067e9.

I am fixing our wrapper's misuse without touching Trie, Deployment or follower.
For an active entry, available representative assets are candidate preimages:
in a speculative trie, delete the selected key and insert the candidate; accept
the candidate only if the recomputed root equals the authenticated current root.
That consumes existing builders and a live node query, not an indexer or a new
checkpoint. Unknown occupied values must refuse rather than claim Pending.

For final #110 semantics, representativeName(name) and overMarkerFor(rep) give
two deterministic candidates, so exact root verification can distinguish Active
from Over without recovering arbitrary values or changing #107 checkpoint data.
Until accepted #110 lands, final retired-value observation remains held. Please
confirm that this wrapper-level authenticated candidate lookup is the intended
seam, or route an existing value-verification API through the owning lane. The
updated #107 interface has been read: loadMirror/saveMirror remain unchanged,
checkpoint still follower-owned. No broader raw-value/indexer scope is requested.
