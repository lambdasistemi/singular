//// Proofs of absence in the registration fold of the new Singular line: a
//// proof has one reading, and every field of every step is in its canonical
//// domain for the key's path before the trie library is asked anything.
////
//// The constructions that broke the absence check are named rows here; the
//// scans and the properties draw proofs over every step kind and every field,
//// for tries that hold the key, and require the check to refuse them.

use aiken/collection/list
use aiken/crypto.{blake2b_256}
use aiken/fuzz
use aiken/merkle_patricia_forestry.{
  Branch, Fork, Leaf, Neighbor, Proof, ProofStep,
}
use aiken/merkle_patricia_forestry as mpf
use aiken/merkle_patricia_forestry/helpers.{nibble}
use aiken/primitive/bytearray
use registry_fixtures.{branchStep, slotOf}
use singular_state/fold.{apart_from, change_leaf, leaf_active}
use singular_state_fold_fixtures.{key_a, key_b, key_c, key_d, trie_of}

fn path() -> ByteArray {
  blake2b_256(key_d)
}

fn value_digest() -> ByteArray {
  blake2b_256(leaf_active)
}

/// The hash of a key with the nibble at `index` changed.
fn with_nibble_changed(hash: ByteArray, index: Int) -> ByteArray {
  let at = index / 2
  let byte = bytearray.at(hash, at)
  let changed =
    if index % 2 == 0 {
      ( byte + 16 ) % 256
    } else {
      byte - byte % 16 + ( byte % 16 + 1 ) % 16
    }
  bytearray.concat(
    bytearray.take(hash, at),
    bytearray.push(bytearray.drop(hash, at + 1), changed),
  )
}

fn zeros(length: Int) -> ByteArray {
  if length <= 0 {
    #""
  } else {
    bytearray.push(zeros(length - 1), 0)
  }
}

fn repeated(length: Int, byte: Int) -> ByteArray {
  if length <= 0 {
    #""
  } else {
    bytearray.push(repeated(length - 1, byte), byte)
  }
}

// ---------------------------------------------------------------------------
// The two constructions that broke the check, and a scan around each
// ---------------------------------------------------------------------------

test a_later_step_with_a_negative_skip_hides_no_bound_key() {
  // trie of key_d and key_a; honest siblings of key_d's branch; a last leaf whose
  // key differs from key_d's hash in nibble 0 only, with skip -1
  let trie = trie_of([key_d, key_a])
  let siblings =
    branchStep(list.map([key_a], fn(held) { slotOf(held, leaf_active) }), key_d)
  let proof =
    [
      siblings,
      Leaf {
        skip: -1,
        key: with_nibble_changed(path(), 0),
        value: value_digest(),
      },
    ]
  mpf.miss(trie, key_d, proof) && !change_leaf(trie, key_d, proof)
}

test a_fork_with_a_branch_number_outside_the_alphabet_hides_no_bound_key() {
  // the trie holds only key_d: a final fork whose neighbour carries the leaf
  // marker byte as its branch number and the key's hash as its prefix
  // reconstructs the occupied leaf, so the library's `miss` is true
  let trie = trie_of([key_d])
  let proof =
    [
      Fork {
        skip: 0,
        neighbor: Neighbor { nibble: 255, prefix: path(), root: value_digest() },
      },
    ]
  mpf.miss(trie, key_d, proof) && !change_leaf(trie, key_d, proof)
}

fn forks_over_branch_numbers() -> List<Proof> {
  list.map(
    list.range(0, 255),
    fn(number) {
      [
        Fork {
          skip: 0,
          neighbor: Neighbor {
            nibble: number,
            prefix: path(),
            root: value_digest(),
          },
        },
      ]
    },
  )
}

test no_fork_over_any_branch_number_hides_a_bound_key() {
  // every branch number from 0 to 255 as the neighbour of a final fork; some of
  // them are accepted by the library as proof of absence, none by the check
  let trie = trie_of([key_d])
  let forged =
    list.filter(
      forks_over_branch_numbers(),
      fn(proof) { mpf.miss(trie, key_d, proof) },
    )
  forged != [] && list.all(
    forged,
    fn(proof) { !change_leaf(trie, key_d, proof) },
  )
}

fn leaves_over_skips() -> List<Proof> {
  list.flat_map(
    list.range(-2, 66),
    fn(skip) {
      list.map(
        [
          path(),
          with_nibble_changed(path(), 0),
          with_nibble_changed(path(), 1),
          with_nibble_changed(path(), 3),
        ],
        fn(key) { [Leaf { skip, key, value: value_digest() }] },
      )
    },
  )
}

test no_leaf_over_any_skip_hides_a_bound_key() {
  let trie = trie_of([key_d])
  let forged =
    list.filter(leaves_over_skips(), fn(proof) { mpf.miss(trie, key_d, proof) })
  forged != [] && list.all(
    forged,
    fn(proof) { !change_leaf(trie, key_d, proof) },
  )
}

// ---------------------------------------------------------------------------
// The canonical domain, stated apart from the check
// ---------------------------------------------------------------------------

fn common_prefix(left: ByteArray, right: ByteArray, index: Int) -> Int {
  if index >= 64 {
    64
  } else if nibble(left, index) == nibble(right, index) {
    common_prefix(left, right, index + 1)
  } else {
    index
  }
}

fn all_nibbles(bytes: ByteArray) -> Bool {
  all_nibbles_from(bytes, 0)
}

fn all_nibbles_from(bytes: ByteArray, at: Int) -> Bool {
  if at >= bytearray.length(bytes) {
    True
  } else {
    bytearray.at(bytes, at) <= 15 && all_nibbles_from(bytes, at + 1)
  }
}

/// Whether every field of every step is in its domain for `hash`, the walk
/// standing at `cursor`: skips not negative and inside the hash; a branch
/// carrying four digests; a fork whose branch number is a nibble other than the
/// key's, whose prefix is a list of nibbles that fits below it and whose root is
/// a digest; a leaf that closes the proof, carries a hash and a digest and shares
/// exactly `skip` nibbles with the key beyond the cursor.
fn canonical(hash: ByteArray, cursor: Int, proof: Proof) -> Bool {
  when proof is {
    [] -> True
    [Branch { skip, neighbors }, ..rest] ->
      skip >= 0 && cursor + skip <= 63 && bytearray.length(neighbors) == 128 && canonical(
        hash,
        cursor + skip + 1,
        rest,
      )
    [Fork { skip, neighbor }, ..rest] ->
      skip >= 0 && cursor + skip <= 63 && neighbor.nibble >= 0 && neighbor.nibble <= 15 && neighbor.nibble != nibble(
        hash,
        cursor + skip,
      ) && all_nibbles(neighbor.prefix) && bytearray.length(neighbor.prefix) <= 63 - (
        cursor + skip
      ) && bytearray.length(neighbor.root) == 32 && canonical(
        hash,
        cursor + skip + 1,
        rest,
      )
    [Leaf { skip, key, value }, ..rest] ->
      skip >= 0 && cursor + skip <= 63 && rest == [] && bytearray.length(key) == 32 && bytearray.length(
        value,
      ) == 32 && common_prefix(hash, key, 0) == cursor + skip
  }
}

// ---------------------------------------------------------------------------
// Generated proofs
// ---------------------------------------------------------------------------

fn skip_fuzzer() -> Fuzzer<Int> {
  fuzz.one_of([0, 0, 0, 0, 1, 1, 2, 3, 5, -1, -2, 62, 63, 64, 100])
}

fn digest_fuzzer() -> Fuzzer<ByteArray> {
  fuzz.map(
    fuzz.one_of([32, 32, 32, 32, 32, 31, 33, 0, 64]),
    fn(length) { repeated(length, 7) },
  )
}

fn branch_fuzzer() -> Fuzzer<ProofStep> {
  fuzz.map2(
    skip_fuzzer(),
    fuzz.one_of([128, 128, 128, 128, 127, 129, 0, 32, 256]),
    fn(skip, length) { Branch { skip, neighbors: zeros(length) } },
  )
}

fn fork_fuzzer() -> Fuzzer<ProofStep> {
  fuzz.map4(
    skip_fuzzer(),
    fuzz.one_of(
      [0, 1, 2, 3, 4, 5, 8, 10, 11, 12, 13, 14, 15, 16, 17, 255, 256, -1, 1000],
    ),
    fuzz.map2(
      fuzz.one_of([0, 0, 1, 2, 5, 30, 62, 63, 64, 70]),
      fuzz.one_of([0, 3, 15, 15, 16, 255]),
      fn(length, byte) { repeated(length, byte) },
    ),
    digest_fuzzer(),
    fn(skip, number, prefix, root) {
      Fork { skip, neighbor: Neighbor { nibble: number, prefix, root } }
    },
  )
}

fn leaf_fuzzer() -> Fuzzer<ProofStep> {
  fuzz.map5(
    skip_fuzzer(),
    fuzz.one_of([0, 0, 1, 1, 2, 3, 4, 5]),
    fuzz.one_of([0, 0, 0, 1, 2, 3, 4]),
    digest_fuzzer(),
    fuzz.one_of([32, 32, 32, 32, 31, 33, 0]),
    fn(skip, changed, second, value, key_length) {
      let near = with_nibble_changed(path(), changed)
      let key =
        if second == 0 {
          near
        } else if second == 1 {
          path()
        } else if second == 2 {
          blake2b_256(key_a)
        } else {
          with_nibble_changed(near, changed + second)
        }
      Leaf { skip, key: bytearray.take(key, key_length), value }
    },
  )
}

fn step_fuzzer() -> Fuzzer<ProofStep> {
  fuzz.either3(branch_fuzzer(), fork_fuzzer(), leaf_fuzzer())
}

fn proof_fuzzer() -> Fuzzer<Proof> {
  fuzz.list_between(step_fuzzer(), 1, 3)
}

test prop_the_check_accepts_exactly_the_canonical_proofs(
  proof via proof_fuzzer(),
) {
  apart_from(key_d, proof) == canonical(path(), 0, proof)
}

fn tries() -> List<List<ByteArray>> {
  [[key_d], [key_d, key_a], [key_a, key_d, key_b], [key_a, key_b, key_c, key_d]]
}

test prop_no_proof_outside_the_domain_hides_a_bound_key(
  case via fuzz.tuple(fuzz.one_of(tries()), proof_fuzzer()),
) {
  let (held, proof) = case
  canonical(path(), 0, proof) || !change_leaf(trie_of(held), key_d, proof)
}

// ---------------------------------------------------------------------------
// The boundary of every field of every step, one change at a time
// ---------------------------------------------------------------------------

fn branch_step(skip: Int, neighbors: ByteArray) -> ProofStep {
  Branch { skip, neighbors }
}

fn fork_step(
  skip: Int,
  number: Int,
  prefix: ByteArray,
  root: ByteArray,
) -> ProofStep {
  Fork { skip, neighbor: Neighbor { nibble: number, prefix, root } }
}

fn leaf_step(skip: Int, key: ByteArray, value: ByteArray) -> ProofStep {
  Leaf { skip, key, value }
}

// a branch number other than key_d's at nibble 0, and at nibble 1
fn other_at_0() -> Int {
  ( nibble(path(), 0) + 1 ) % 16
}

fn other_at_1() -> Int {
  ( nibble(path(), 1) + 1 ) % 16
}

test a_proof_inside_the_domain_is_accepted_at_the_edge_of_every_field() {
  list.all(
    [
      [branch_step(0, zeros(128))],
      [branch_step(63, zeros(128))],
      [fork_step(0, other_at_0(), #"", value_digest())],
      [fork_step(0, other_at_0(), repeated(63, 15), value_digest())],
      [
        branch_step(0, zeros(128)),
        fork_step(0, other_at_1(), repeated(62, 0), value_digest()),
      ],
      [leaf_step(0, with_nibble_changed(path(), 0), value_digest())],
      [
        branch_step(0, zeros(128)),
        leaf_step(2, with_nibble_changed(path(), 3), value_digest()),
      ],
      [
        fork_step(1, other_at_1(), #"", value_digest()),
        leaf_step(0, with_nibble_changed(path(), 2), value_digest()),
      ],
    ],
    fn(proof) { apart_from(key_d, proof) },
  )
}

test a_proof_with_one_field_outside_its_domain_is_refused() {
  list.all(
    [
      // a branch carries four digests
      [branch_step(0, zeros(127))],
      [branch_step(0, zeros(129))],
      [branch_step(0, zeros(256))],
      [branch_step(0, #"")],
      // skips: negative, beyond the hash, landing outside it after a step
      [branch_step(-1, zeros(128))],
      [branch_step(64, zeros(128))],
      [branch_step(63, zeros(128)), branch_step(0, zeros(128))],
      [fork_step(-1, other_at_0(), #"", value_digest())],
      [fork_step(64, other_at_0(), #"", value_digest())],
      // a fork's branch number is a nibble, and not the key's
      [fork_step(0, -1, #"", value_digest())],
      [fork_step(0, 16, #"", value_digest())],
      [fork_step(0, 17, #"", value_digest())],
      [fork_step(0, 255, #"", value_digest())],
      [fork_step(0, 256, #"", value_digest())],
      [fork_step(0, 1000, #"", value_digest())],
      [fork_step(0, nibble(path(), 0), #"", value_digest())],
      [
        branch_step(0, zeros(128)),
        fork_step(0, nibble(path(), 1), #"", value_digest()),
      ],
      // a fork's prefix is a list of nibbles that fits below it
      [fork_step(0, other_at_0(), repeated(1, 16), value_digest())],
      [fork_step(0, other_at_0(), repeated(1, 255), value_digest())],
      [fork_step(0, other_at_0(), repeated(63, 16), value_digest())],
      [fork_step(0, other_at_0(), repeated(64, 0), value_digest())],
      [
        branch_step(0, zeros(128)),
        fork_step(0, other_at_1(), repeated(63, 0), value_digest()),
      ],
      // a fork's root is a digest
      [fork_step(0, other_at_0(), #"", zeros(31))],
      [fork_step(0, other_at_0(), #"", zeros(33))],
      [fork_step(0, other_at_0(), #"", #"")],
      // a leaf closes the proof
      [
        leaf_step(0, with_nibble_changed(path(), 0), value_digest()),
        branch_step(0, zeros(128)),
      ],
      [
        leaf_step(0, with_nibble_changed(path(), 0), value_digest()),
        leaf_step(0, with_nibble_changed(path(), 1), value_digest()),
      ],
      // a leaf carries a hash and a digest
      [
        leaf_step(
          0,
          bytearray.take(with_nibble_changed(path(), 0), 31),
          value_digest(),
        ),
      ],
      [
        leaf_step(
          0,
          bytearray.push(with_nibble_changed(path(), 0), 0),
          value_digest(),
        ),
      ],
      [leaf_step(0, #"", value_digest())],
      [leaf_step(0, with_nibble_changed(path(), 0), zeros(31))],
      [leaf_step(0, with_nibble_changed(path(), 0), zeros(33))],
      [leaf_step(0, with_nibble_changed(path(), 0), #"")],
      // a leaf's skip is the prefix it shares with the key
      [leaf_step(1, with_nibble_changed(path(), 0), value_digest())],
      [leaf_step(0, with_nibble_changed(path(), 1), value_digest())],
      [leaf_step(0, path(), value_digest())],
      [leaf_step(63, path(), value_digest())],
    ],
    fn(proof) { !apart_from(key_d, proof) },
  )
}
