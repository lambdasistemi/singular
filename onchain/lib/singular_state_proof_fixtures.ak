//// Shared synthetic proof fixtures for retained validator tests.

use aiken/collection/list
use aiken/crypto.{blake2b_256}
use aiken/merkle_patricia_forestry.{Branch, Leaf, ProofStep}
use aiken/merkle_patricia_forestry/helpers.{combine, nibble, suffix}
use aiken/merkle_patricia_forestry/merkling.{null_hash}
use aiken/primitive/bytearray

/// The synthetic absence encoding used by the tests.
pub const absentLeaf: ByteArray = #"00"

/// The synthetic terminal encoding used by the tests.
pub const terminalLeaf: ByteArray = #"02"

fn commonPrefix(left: ByteArray, right: ByteArray, cursor: Int) -> Int {
  if nibble(left, cursor) == nibble(right, cursor) {
    commonPrefix(left, right, cursor + 1)
  } else {
    cursor
  }
}

/// Construct a test step from the explicit keys and value.
pub fn leafStep(
  otherKey: ByteArray,
  otherValue: ByteArray,
  myKey: ByteArray,
) -> ProofStep {
  Leaf {
    skip: commonPrefix(blake2b_256(myKey), blake2b_256(otherKey), 0),
    key: blake2b_256(otherKey),
    value: blake2b_256(otherValue),
  }
}

fn leafDigest(key: ByteArray, value: ByteArray) -> ByteArray {
  combine(suffix(blake2b_256(key), 1), blake2b_256(value))
}

fn slotsOf(entries: List<(Int, ByteArray)>) -> List<ByteArray> {
  list.map(
    list.range(0, 15),
    fn(slot) {
      when list.find(entries, fn(entry) { entry.1st == slot }) is {
        Some(entry) -> entry.2nd
        None -> null_hash
      }
    },
  )
}

fn pairUp(digests: List<ByteArray>) -> List<ByteArray> {
  when digests is {
    [left, right, ..rest] -> [combine(left, right), ..pairUp(rest)]
    _ -> []
  }
}

fn sibling(index: Int) -> Int {
  if index % 2 == 0 {
    index + 1
  } else {
    index - 1
  }
}

fn nth(digests: List<ByteArray>, index: Int) -> ByteArray {
  expect Some(digest) = list.at(digests, index)
  digest
}

/// Construct a test branch step from explicit slot digests.
pub fn branchStep(
  entries: List<(Int, ByteArray)>,
  myKey: ByteArray,
) -> ProofStep {
  let level0 = slotsOf(entries)
  let level1 = pairUp(level0)
  let level2 = pairUp(level1)
  let level3 = pairUp(level2)
  let branch = nibble(blake2b_256(myKey), 0)
  Branch {
    skip: 0,
    neighbors: nth(level3, sibling(branch / 8))
      |> bytearray.concat(nth(level2, sibling(branch / 4)))
      |> bytearray.concat(nth(level1, sibling(branch / 2)))
      |> bytearray.concat(nth(level0, sibling(branch))),
  }
}

/// Derive a test slot entry from an explicit key and value.
pub fn slotOf(key: ByteArray, value: ByteArray) -> (Int, ByteArray) {
  (nibble(blake2b_256(key), 0), leafDigest(key, value))
}
