import OpenDatumApplicationHeld.MoneyBaseFixtures
namespace OpenDatumApplicationHeld.FixtureQueries
open Singular Lean SingularApplicationHeld Fixtures


def codes : List CodeEntry :=
  ([Preimage.state seed] ++ mixed.changes.flatMap (changePreimages mixed)).map fun p => ⟨p, code p⟩

def hashes : List SingularApplicationHeld.Assets.HashEntry := codes.map fun e => ⟨e.encoded, hash e.encoded⟩

def roots : List RootEntry := [[], mixed.before.trie, mixed.after.trie].map fun trie => ⟨trie, commit trie⟩

def goodQuery (surface : Case) : Query :=
  { surface, codes, hashes, roots, release, seed,
    output := Fixtures.registry.state, transaction := genesisView,
    outputs := [{ Fixtures.registry.state with datum := .root (commit []) }],
    observation := mixed, trie := Fixtures.registry.trie,
    action := if surface == .termination then mixed.changes[1] else mixed.changes[0],
    requests := [registration, termination], funding,
    decoding := [(2007, .registration registrationData), (1007, .live (control 7) 123)] }


end OpenDatumApplicationHeld.FixtureQueries
