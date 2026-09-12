// Ticket #81 / CS07 regression: lone-Fork exclusion with skip > 0.
//
// The vendored aiken-lang/merkle-patricia-forestry v2.0.0 (+ the
// lone-fork-exclusion patch staged by flake.nix, see patches/README.md)
// must accept the real absence witness the builder produces for key
// "cs07-fork-C11" over {A, B}, and its including() must reconstruct the
// builder's committed post-insert root.
//
// Roots and witness bytes are retained producer evidence
// (ticket-81/commit-owner handoff fork-precondition-binding.md,
// evidence/e1-probe). On the UNPATCHED v2.0.0 the first two tests fail
// (retained RED evidence: commit-owner evidence/e2-v20-fixed.log).
use aiken/merkle_patricia_forestry.{Fork, Neighbor, Proof}
use aiken/merkle_patricia_forestry as mpf

const pre_root =
  #"fbef6b6d9a253acf2ecf645fd62e663535b828595b8ea38ae2118038d4f9c5a7"

const post_root =
  #"cd1f3928377ab7e6d67e05a217d73c6e63dc796fcb90b752fb554ac3049defcf"

const neighbor_root =
  #"651694f560326d4fc773d65daba52940d5ec0c3fb4b0603d4a095bc1b43c0b06"

fn cs07_witness() -> Proof {
  [Fork {
    skip: 1,
    neighbor: Neighbor {
      nibble: 11,
      prefix: #"0b",
      root: neighbor_root,
    },
  }]
}

// The validator's exact check (state.ak Insert arm): the witness must pass
// `expect excluding(key, proof) == self.root` AND the reconstructed root
// must equal the builder's committed post-insert root (state.ak's
// output-root check).
test lone_fork_insert_accepts_real_absence_witness() {
  mpf.root(
    mpf.insert(mpf.from_root(pre_root), #"637330372d666f726b2d433131", #"7663", cs07_witness()),
  )
  == post_root
}

// Including-side isolation: including(key, value, proof) alone must
// reproduce the builder's committed post-insert root.
test lone_fork_including_reproduces_builder_post_root() {
  mpf.has(mpf.from_root(post_root), #"637330372d666f726b2d433131", #"7663", cs07_witness())
}

// Occupied-key direction control: the absence witness must NOT verify
// inclusion of the key under the pre-root, which does not contain it —
// this is the discrimination edge that makes the tests above mean
// "absence" rather than "any proof accepted".
test lone_fork_control_has_fails_against_pre_root() {
  !mpf.has(mpf.from_root(pre_root), #"637330372d666f726b2d433131", #"7663", cs07_witness())
}
