//// The proof of a key in a trie of any shape, built from the leaves.
////
//// The proof builders of `registry_fixtures` describe a root with one leaf per
//// first nibble. This builder follows the structure of the Merkle Patricia
//// Forestry: a node is a leaf, or a branch that shares a prefix of nibbles and
//// splits on the next one. It computes the digest of every sibling subtree from
//// the leaves, so it describes tries whose nodes share prefixes, hold two
//// children whose neighbour is a leaf or a branch, or hold more.
////
//// It does not replace the library as the oracle. A proof built here is checked
//// against a root the library produced from earlier proofs, and the digest it
//// computes for a whole trie is compared with the library's root.

use aiken/collection/list
use aiken/crypto.{blake2b_256}
use aiken/merkle_patricia_forestry.{
  Branch, Fork, Leaf, Neighbor, Proof, ProofStep,
}
use aiken/merkle_patricia_forestry/helpers.{combine, nibble, nibbles, suffix}
use aiken/merkle_patricia_forestry/merkling.{null_hash}
use aiken/primitive/bytearray

/// A leaf of a trie: the hash of its key, which is its path, and the digest of
/// the value it binds.
pub type Entry {
  path: ByteArray,
  value: ByteArray,
}

/// The entry of `key` bound to `leaf`.
pub fn entry_of(key: ByteArray, leaf: ByteArray) -> Entry {
  Entry { path: blake2b_256(key), value: blake2b_256(leaf) }
}

fn agree_at(entries: List<Entry>, index: Int, number: Int) -> Bool {
  list.all(entries, fn(each) { nibble(each.path, index) == number })
}

/// The number of nibbles, from `index`, that every entry's path shares with the
/// first one's.
fn shared(entries: List<Entry>, index: Int) -> Int {
  when entries is {
    [first, ..] ->
      if index >= 64 {
        0
      } else if agree_at(entries, index, nibble(first.path, index)) {
        1 + shared(entries, index + 1)
      } else {
        0
      }
    [] -> 0
  }
}

fn in_slot(entries: List<Entry>, index: Int, slot: Int) -> List<Entry> {
  list.filter(entries, fn(each) { nibble(each.path, index) == slot })
}

/// The sixteen digests of the children of a node that splits at `index`; a slot
/// with no entry holds the null digest.
fn slot_digests(entries: List<Entry>, index: Int) -> List<ByteArray> {
  list.map(
    list.range(0, 15),
    fn(slot) {
      when in_slot(entries, index, slot) is {
        [] -> null_hash
        group -> digest_of(group, index + 1)
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

fn tree_root(digests: List<ByteArray>) -> ByteArray {
  expect [root] = pair_up(pair_up(pair_up(pair_up(digests))))
  root
}

/// The digest of the subtree that holds `entries`, whose paths agree up to
/// `depth`.
pub fn digest_of(entries: List<Entry>, depth: Int) -> ByteArray {
  when entries is {
    [only] -> combine(suffix(only.path, depth), only.value)
    [first, ..] -> {
      let skip = shared(entries, depth)
      combine(
        nibbles(first.path, depth, depth + skip),
        tree_root(slot_digests(entries, depth + skip)),
      )
    }
    [] -> null_hash
  }
}

/// The root of the trie that holds `entries`.
pub fn root_of_entries(entries: List<Entry>) -> ByteArray {
  digest_of(entries, 0)
}

fn nth(digests: List<ByteArray>, index: Int) -> ByteArray {
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

/// The four sibling digests on the path of slot `branch` through the node's
/// binary tree, in the order the library reads them.
fn neighbors_of(digests: List<ByteArray>, branch: Int) -> ByteArray {
  let level1 = pair_up(digests)
  let level2 = pair_up(level1)
  let level3 = pair_up(level2)
  nth(level3, sibling(branch / 8))
    |> bytearray.concat(nth(level2, sibling(branch / 4)))
    |> bytearray.concat(nth(level1, sibling(branch / 2)))
    |> bytearray.concat(nth(digests, sibling(branch)))
}

/// The steps from the node that holds `entries`, whose paths agree up to
/// `depth`, to the leaf of `path`, which `entries` holds.
pub fn proof_in(entries: List<Entry>, depth: Int, path: ByteArray) -> Proof {
  when entries is {
    [] -> []
    [_] -> []
    _ -> {
      let skip = shared(entries, depth)
      let index = depth + skip
      let mine = nibble(path, index)
      let digests = slot_digests(entries, index)
      let others =
        list.filter(
          list.range(0, 15),
          fn(slot) { slot != mine && nth(digests, slot) != null_hash },
        )
      let step =
        when others is {
          [neighbour] -> neighbour_step(entries, skip, index, neighbour)
          _ -> Branch { skip, neighbors: neighbors_of(digests, mine) }
        }
      [step, ..proof_in(in_slot(entries, index, mine), index + 1, path)]
    }
  }
}

/// The step at a node of two children when the neighbour of the path is the
/// child in slot `neighbour`: a leaf, or a branch described by its prefix and
/// the root of its children.
fn neighbour_step(
  entries: List<Entry>,
  skip: Int,
  index: Int,
  neighbour: Int,
) -> ProofStep {
  let group = in_slot(entries, index, neighbour)
  expect [first, ..] = group
  when group is {
    [one] -> Leaf { skip, key: one.path, value: one.value }
    _ -> {
      let below = shared(group, index + 1)
      Fork {
        skip,
        neighbor: Neighbor {
          nibble: neighbour,
          prefix: nibbles(first.path, index + 1, index + 1 + below),
          root: tree_root(slot_digests(group, index + 1 + below)),
        },
      }
    }
  }
}
