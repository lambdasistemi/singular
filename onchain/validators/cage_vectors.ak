// Auto-generated cage test vectors
// Do not edit
//   run 'just generate-vectors'
//   to regenerate

use aiken/merkle_patricia_forestry.{Branch, Fork, Leaf, Neighbor, Proof}
use aiken/merkle_patricia_forestry as mpf
use cardano/transaction.{OutputReference}
use lib.{assetName}

test vec_insert_into_empty_trie() {
  let proof: Proof = []
  let trie = mpf.insert(mpf.empty, #"6162", #"6364", proof)
  mpf.root(trie) == #"5774710a4457e50a5a2ff1fe6149398617c895dd3fbd3bd8cac51ecc571f9319"
}

test vec_insert_creating_fork() {
  let proof: Proof =
    [
      Leaf {
        skip: 0,
        key: #"30e612d85865aaf22de5c95a43c5cbc1907323d74edcc3f2e122c385044dac2b",
        value: #"ae11692325525e82337167fcfab34d45d1904ff786e2d4bf4be2d1c4878cd34c",
      },
    ]
  let trie =
    mpf.insert(
      mpf.from_root(
        #"51142f22ba3576be090b2dca505687be816e7829352ef97d3671bf974bc43719",
      ),
      #"6b32",
      #"7632",
      proof,
    )
  mpf.root(trie) == #"5a72ccdd24fe693d6c10aaacd4635f5daa94dbd881f3340a985634e7aaed3c7f"
}

test vec_insert_with_shared_prefix() {
  let proof: Proof =
    [
      Leaf {
        skip: 0,
        key: #"9e3330d3dd6f271cf17f48426f651f7b4e9cd347561c9617110a8bf998eb4930",
        value: #"ac5370259669ccdf4639f09317bbb2adaa740a300a5dc98fd51912b1173155b0",
      },
    ]
  let trie =
    mpf.insert(
      mpf.from_root(
        #"220c9554d22d2e9f39ab34516bf6c69a11455689cc1acb55c5d4e880d06ec5c5",
      ),
      #"6b62",
      #"7662",
      proof,
    )
  mpf.root(trie) == #"8ba3fb9d4d56aa4d03e3d5481e9e23ea0c87d4e9dee6debd9cf268b462b61f74"
}

test vec_inclusion_proof_for_middle_key() {
  let proof: Proof =
    [
      Branch {
        skip: 0,
        neighbors: #"9c7a465e42fff5f33d830117491d1754e12a901d4f0a6ce156f0d1da2a69b66996137bd9a8bdc4452f60cb31222fb2742a3f0b5ef9189188d06221c8153f7dc40eb923b0cbd24df54401d998531feead35a47a99f4deed205de4af81120f97610000000000000000000000000000000000000000000000000000000000000000",
      },
    ]
  mpf.has(
    mpf.from_root(
      #"91db563fdb311ea17481d01600e08179f6393a9c0e0c8cec41ffb9d8eaba9327",
    ),
    #"79",
    #"32",
    proof,
  )
}

test vec_asset_name_from_txoutref_index_0() {
  let ref =
    OutputReference {
      transaction_id: #"0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20",
      output_index: 0,
    }
  assetName(ref) == #"0e60b5bc267eb614324cc605869b377bd4f4770615f2c9dede78611a52f530e9"
}

test vec_asset_name_from_txoutref_index_1() {
  let ref =
    OutputReference {
      transaction_id: #"0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20",
      output_index: 1,
    }
  assetName(ref) == #"cbfb2fcbfefd664cb8bf2e3b6e02cbe123b43555fc20f297e235a24d4c96e4e3"
}

test vec_asset_name_from_zero_txid_index_255() {
  let ref =
    OutputReference {
      transaction_id: #"0000000000000000000000000000000000000000000000000000000000000000",
      output_index: 255,
    }
  assetName(ref) == #"23d8b3fbfc92dcda6c7975d70d25d325d162101b40a613c59c750d6b889b288a"
}
