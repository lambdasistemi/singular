//// Registration proofs and roots computed from an independent trie model.
//// Honest proofs of absence insert the key and produce the expected root;
//// honest proofs of presence are accepted by the library.

use aiken/collection/list
use aiken/crypto.{blake2b_256}
use aiken/fuzz
use aiken/merkle_patricia_forestry.{
  Branch, Fork, Leaf, MerklePatriciaForestry, Neighbor, Proof, ProofStep,
}
use aiken/merkle_patricia_forestry as mpf
use aiken/merkle_patricia_forestry/helpers.{combine, nibble, nibbles, suffix}
use aiken/merkle_patricia_forestry/merkling.{null_hash}
use aiken/primitive/bytearray
use singular_state/fold.{change_leaf, leaf_active}
use singular_state_fold_fixtures.{key_a, key_c, key_d, trie_of}

/// A node of the trie: a leaf holds a whole path; a node with a prefix of
/// nibbles holds its children by the slot, the nibble that follows the prefix.
type Node {
  Tip { path: ByteArray }
  Fan { prefix: ByteArray, children: List<Pair<Int, Node>> }
}

/// The digest the trie binds to a key: the hash of the active leaf.
fn value_digest() -> ByteArray {
  blake2b_256(leaf_active)
}

/// The number of nibbles two paths share from `cursor` on.
fn shared_from(left: ByteArray, right: ByteArray, cursor: Int) -> Int {
  if cursor >= 64 {
    0
  } else if nibble(left, cursor) == nibble(right, cursor) {
    1 + shared_from(left, right, cursor + 1)
  } else {
    0
  }
}

fn shared_by_all(paths: List<ByteArray>, first: ByteArray, cursor: Int) -> Int {
  if cursor >= 64 {
    0
  } else if list.all(
    paths,
    fn(path) { nibble(path, cursor) == nibble(first, cursor) },
  ) {
    1 + shared_by_all(paths, first, cursor + 1)
  } else {
    0
  }
}

/// The node that holds `paths`, standing at `cursor`. The paths are distinct.
fn build(paths: List<ByteArray>, cursor: Int) -> Node {
  when paths is {
    [] -> fail @"a node holds a path"
    [only] -> Tip { path: only }
    [first, ..] -> {
      let at = cursor + shared_by_all(paths, first, cursor)
      Fan {
        prefix: nibbles(first, cursor, at),
        children: list.filter_map(
          list.range(0, 15),
          fn(slot) {
            when list.filter(paths, fn(path) { nibble(path, at) == slot }) is {
              [] -> None
              held -> Some(Pair(slot, build(held, at + 1)))
            }
          },
        ),
      }
    }
  }
}

fn child_at(children: List<Pair<Int, Node>>, slot: Int) -> Option<Node> {
  when list.find(children, fn(Pair(held, _)) { held == slot }) is {
    Some(Pair(_, child)) -> Some(child)
    None -> None
  }
}

fn slot_digests(children: List<Pair<Int, Node>>, cursor: Int) -> List<ByteArray> {
  list.map(
    list.range(0, 15),
    fn(slot) {
      when child_at(children, slot) is {
        Some(child) -> digest(child, cursor)
        None -> null_hash
      }
    },
  )
}

fn pair_up(digests: List<ByteArray>) -> List<ByteArray> {
  when digests is {
    [left, right, ..rest] -> [combine(left, right), ..pair_up(rest)]
    _ -> []
  }
}

fn only_one(digests: List<ByteArray>) -> ByteArray {
  expect [one] = digests
  one
}

/// The digest of the sixteen slots of a node: what a `Fork` step names as the
/// root of its neighbour and the fold of a `Branch` step ends in.
fn children_root(
  prefix: ByteArray,
  children: List<Pair<Int, Node>>,
  cursor: Int,
) -> ByteArray {
  only_one(
    pair_up(
      pair_up(
        pair_up(
          pair_up(slot_digests(children, cursor + bytearray.length(prefix) + 1)),
        ),
      ),
    ),
  )
}

/// The digest of a node standing at `cursor`.
fn digest(node: Node, cursor: Int) -> ByteArray {
  when node is {
    Tip { path } -> combine(suffix(path, cursor), value_digest())
    Fan { prefix, children } ->
      combine(prefix, children_root(prefix, children, cursor))
  }
}

/// The root of the trie that holds exactly `paths`.
fn root_of_paths(paths: List<ByteArray>) -> ByteArray {
  when paths is {
    [] -> null_hash
    _ -> digest(build(paths, 0), 0)
  }
}

fn at_level(digests: List<ByteArray>, index: Int) -> ByteArray {
  expect Some(digest) = list.at(digests, index)
  digest
}

fn sibling(index: Int) -> Int {
  if index % 2 == 0 {
    index + 1
  } else {
    index - 1
  }
}

/// The four digests of a `Branch` step: the siblings of `slot` in the binary
/// tree over the sixteen slots, in the order the library reads them.
fn siblings(digests: List<ByteArray>, slot: Int) -> ByteArray {
  let level1 = pair_up(digests)
  let level2 = pair_up(level1)
  let level3 = pair_up(level2)
  at_level(level3, sibling(slot / 8))
    |> bytearray.concat(at_level(level2, sibling(slot / 4)))
    |> bytearray.concat(at_level(level1, sibling(slot / 2)))
    |> bytearray.concat(at_level(digests, sibling(slot)))
}

fn shared_with_prefix(path: ByteArray, prefix: ByteArray, cursor: Int) -> Int {
  shared_prefix_from(path, prefix, cursor, 0)
}

fn shared_prefix_from(
  path: ByteArray,
  prefix: ByteArray,
  cursor: Int,
  at: Int,
) -> Int {
  if at >= bytearray.length(prefix) {
    at
  } else if nibble(path, cursor + at) == bytearray.at(prefix, at) {
    shared_prefix_from(path, prefix, cursor, at + 1)
  } else {
    at
  }
}

fn step_past(
  skip: Int,
  children: List<Pair<Int, Node>>,
  slot: Int,
  below: Int,
) -> ProofStep {
  when list.filter(children, fn(Pair(held, _)) { held != slot }) is {
    [Pair(_, Tip { path })] -> Leaf { skip, key: path, value: value_digest() }
    [Pair(number, Fan { prefix, children: inner })] ->
      Fork {
        skip,
        neighbor: Neighbor {
          nibble: number,
          prefix,
          root: children_root(prefix, inner, below),
        },
      }
    _ ->
      Branch { skip, neighbors: siblings(slot_digests(children, below), slot) }
  }
}

/// The proof of `path` in the node standing at `cursor`: the proof that the
/// trie holds it when the trie does, and the proof of its absence otherwise.
fn prove(node: Node, cursor: Int, path: ByteArray) -> Proof {
  when node is {
    Tip { path: held } ->
      if held == path {
        []
      } else {
        [
          Leaf {
            skip: shared_from(path, held, cursor),
            key: held,
            value: value_digest(),
          },
        ]
      }
    Fan { prefix, children } -> {
      let length = bytearray.length(prefix)
      let shared = shared_with_prefix(path, prefix, cursor)
      if shared < length {
        [
          Fork {
            skip: shared,
            neighbor: Neighbor {
              nibble: bytearray.at(prefix, shared),
              prefix: bytearray.drop(prefix, shared + 1),
              root: children_root(prefix, children, cursor),
            },
          },
        ]
      } else {
        let slot = nibble(path, cursor + length)
        let below = cursor + length + 1
        when child_at(children, slot) is {
          None -> [branch_closing(length, children, slot, below)]
          Some(child) ->
            [
              step_past(length, children, slot, below),
              ..prove(child, below, path)
            ]
        }
      }
    }
  }
}

/// The proof of `path` against the trie that holds exactly `paths`.
fn proof_of(paths: List<ByteArray>, path: ByteArray) -> Proof {
  when paths is {
    [] -> []
    _ -> prove(build(paths, 0), 0, path)
  }
}

/// The path with the nibble at `index` set to `value`.
fn with_nibble(path: ByteArray, index: Int, value: Int) -> ByteArray {
  let byte = bytearray.at(path, index / 2)
  let replaced =
    if index % 2 == 0 {
      value % 16 * 16 + byte % 16
    } else {
      byte / 16 * 16 + value % 16
    }
  bytearray.concat(
    bytearray.take(path, index / 2),
    bytearray.push(bytearray.drop(path, index / 2 + 1), replaced),
  )
}

fn branch_closing(
  skip: Int,
  children: List<Pair<Int, Node>>,
  slot: Int,
  below: Int,
) -> ProofStep {
  Branch { skip, neighbors: siblings(slot_digests(children, below), slot) }
}

const keys: List<ByteArray> = [key_a, key_c, key_d]

fn path_of(key: ByteArray) -> ByteArray {
  blake2b_256(key)
}

fn trie_of_paths(paths: List<ByteArray>) -> MerklePatriciaForestry {
  mpf.from_root(root_of_paths(paths))
}

/// The paths that differ from `path` at the nibble of each spec, the nibble
/// raised by the spec's amount, and by one nibble more further down where the
/// spec names one.
fn others_of(path: ByteArray, specs: List<(Int, Int, Int)>) -> List<ByteArray> {
  list.unique(
    list.filter(
      list.map(
        specs,
        fn(spec) {
          let (index, raise, further) = spec
          let near =
            with_nibble(path, index, ( nibble(path, index) + raise ) % 16)
          if further > index && further < 64 {
            with_nibble(near, further, ( nibble(near, further) + raise ) % 16)
          } else {
            near
          }
        },
      ),
      fn(other) { other != path },
    ),
  )
}

fn index_fuzzer() -> Fuzzer<Int> {
  fuzz.one_of([0, 0, 1, 1, 2, 3, 4, 5, 31, 61, 62, 62, 63, 63])
}

fn spec_fuzzer() -> Fuzzer<(Int, Int, Int)> {
  fuzz.tuple3(
    index_fuzzer(),
    fuzz.one_of([1, 1, 1, 2, 3, 7]),
    fuzz.one_of([0, 0, 5, 9, 17, 40, 63]),
  )
}

/// A key, and the paths of a trie around the key's: zero to four paths that
/// share a prefix of any length with it.
fn around_fuzzer() -> Fuzzer<(ByteArray, List<ByteArray>)> {
  fuzz.map2(
    fuzz.one_of(keys),
    fuzz.list_between(spec_fuzzer(), 0, 4),
    fn(key, specs) { (key, others_of(path_of(key), specs)) },
  )
}

/// Shapes of tries around a key: alone; one neighbour that parts from the key at
/// each of the first nibbles and at the last ones; three that part at one
/// nibble; a neighbour with a neighbour; two that share a prefix the key does
/// not, so the key leaves a node's prefix, alone and beside a leaf.
fn shapes() -> List<List<(Int, Int, Int)>> {
  [
    [], [(0, 1, 0)], [(1, 1, 0)], [(2, 1, 0)], [(3, 1, 0)], [(61, 1, 0)],
    [(62, 1, 0)], [(63, 1, 0)], [(0, 1, 0), (0, 2, 0), (0, 3, 0)],
    [(1, 1, 0), (1, 2, 0), (0, 5, 0)], [(0, 1, 2), (0, 2, 0)],
    [(2, 4, 3), (1, 2, 0), (1, 3, 0)], [(62, 1, 0), (63, 1, 0), (62, 2, 0)],
    [(0, 1, 5), (0, 1, 0)], [(1, 1, 6), (1, 1, 0)],
    [(1, 1, 0), (0, 1, 4), (0, 1, 0)], [(0, 1, 40), (0, 1, 0)],
    [(61, 1, 63), (61, 1, 0)],
  ]
}

fn around_all() -> List<(ByteArray, List<ByteArray>)> {
  list.flat_map(
    keys,
    fn(key) {
      list.map(shapes(), fn(shape) { (key, others_of(path_of(key), shape)) })
    },
  )
}

test the_model_roots_are_the_library_roots() {
  list.all(
    [[key_a], [key_a, key_c], [key_a, key_c, key_d]],
    fn(held) {
      root_of_paths(list.map(held, path_of)) == mpf.root(trie_of(held))
    },
  )
}

test the_model_proof_of_absence_inserts_the_root_of_the_trie_with_the_key(
  case via around_fuzzer(),
) {
  let (key, others) = case
  let path = path_of(key)
  mpf.root(
    mpf.insert(trie_of_paths(others), key, leaf_active, proof_of(others, path)),
  ) == root_of_paths([path, ..others])
}

test the_model_proof_of_presence_is_a_proof_the_library_accepts(
  case via around_fuzzer(),
) {
  let (key, others) = case
  let path = path_of(key)
  mpf.has(
    trie_of_paths([path, ..others]),
    key,
    leaf_active,
    proof_of([path, ..others], path),
  )
}

/// The root a fold writes for the key, when the check accepts the proof.
fn written(
  trie: MerklePatriciaForestry,
  key: ByteArray,
  proof: Proof,
) -> Option<ByteArray> {
  if change_leaf(trie, key, proof) {
    Some(mpf.root(mpf.insert(trie, key, leaf_active, proof)))
  } else {
    None
  }
}

fn honest_is_accepted(case: (ByteArray, List<ByteArray>)) -> Bool {
  let (key, others) = case
  let path = path_of(key)
  written(trie_of_paths(others), key, proof_of(others, path)) == Some(
    root_of_paths([path, ..others]),
  )
}

test prop_an_honest_proof_of_absence_is_accepted_and_writes_the_honest_root(
  case via around_fuzzer(),
) {
  honest_is_accepted(case)
}

test an_honest_proof_of_absence_is_accepted_in_every_shape() {
  list.all(around_all(), honest_is_accepted)
}

/// "keyK": the hash begins with nibble 6, as "keyA"'s does, and parts from it at
/// nibble 1.
const key_k: ByteArray = #"6b65794b"

test an_honest_proof_for_a_key_sharing_a_first_nibble_with_a_held_key_is_accepted() {
  // the registry holds "keyA" (first nibble 6) and "keyC" (2); the proof for
  // "keyK" names the leaf of "keyC" at the root and then the leaf of "keyA" below
  let proof =
    [
      Leaf { skip: 0, key: path_of(key_c), value: value_digest() },
      Leaf { skip: 0, key: path_of(key_a), value: value_digest() },
    ]
  proof == proof_of([path_of(key_a), path_of(key_c)], path_of(key_k)) && written(
    trie_of([key_a, key_c]),
    key_k,
    proof,
  ) == Some(root_of_paths(list.map([key_a, key_c, key_k], path_of)))
}
