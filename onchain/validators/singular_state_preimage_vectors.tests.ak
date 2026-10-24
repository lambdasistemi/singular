//// The byte vectors of the hashed-name preimages, as Aiken tests.
////
//// Generated from offchain/test/fixtures/preimage-vectors.json by tools/preimage_vectors.py; do not edit.
//// Every test builds a role's inputs, serialises them with the on-chain
//// functions and compares the bytes and the name with the vector.

use aiken/cbor
use aiken/collection/list
use cardano/address.{Address, Inline, Script, VerificationKey}
use cardano/transaction.{OutputReference}
use singular_state/preimage.{
  Active, RegistryIdentity, State, active_token_name, approval_name,
  registration_preimage, state_token_name,
}

test vector_state_output_index_zero() {
  let seed =
    OutputReference {
      transaction_id: #"000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f",
      output_index: 0,
    }
  and {
    cbor.serialise(State { seed }) == #"d8799fd8799f5820000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f00ffff",
    state_token_name(seed) == #"f89522d53ec5d471859825a00c59836263130e8cc4a59015a944371049139daf",
  }
}

test vector_active_key_32_bytes() {
  let registry =
    RegistryIdentity {
      policy: #"70757a7f84898e93989da2a7acb1b6bbc0c5cacfd4d9dee3e8edf2f7",
      name: #"f89522d53ec5d471859825a00c59836263130e8cc4a59015a944371049139daf",
    }
  let key = #"0104070a0d101316191c1f2225282b2e3134373a3d404346494c4f5255585b5e"
  and {
    cbor.serialise(Active { registry, key }) == #"d87a9fd8799f581c70757a7f84898e93989da2a7acb1b6bbc0c5cacfd4d9dee3e8edf2f75820f89522d53ec5d471859825a00c59836263130e8cc4a59015a944371049139dafff58200104070a0d101316191c1f2225282b2e3134373a3d404346494c4f5255585b5eff",
    active_token_name(registry, key) == #"7bb99a3ed884c2143636542734ff8987649b8deb960ba4b787bf1ab40f35fecb",
  }
}

test vector_approval_script_payment_key_stake() {
  let registry =
    RegistryIdentity {
      policy: #"70757a7f84898e93989da2a7acb1b6bbc0c5cacfd4d9dee3e8edf2f7",
      name: #"f89522d53ec5d471859825a00c59836263130e8cc4a59015a944371049139daf",
    }
  let key = #"0104070a0d101316191c1f2225282b2e3134373a3d404346494c4f5255585b5e"
  let holding_address =
    Address {
      payment_credential: Script(
        #"20272e353c434a51585f666d747b828990979ea5acb3bac1c8cfd6dd",
      ),
      stake_credential: Some(
        Inline(
          VerificationKey(
            #"3039424b545d666f78818a939ca5aeb7c0c9d2dbe4edf6ff08111a23",
          ),
        ),
      ),
    }
  let datum_hash =
    #"404b56616c77828d98a3aeb9c4cfdae5f0fb06111c27323d48535e69747f8a95"
  let preimage =
    registration_preimage(key, registry, holding_address, datum_hash, 2000000)
  and {
    preimage == #"d87c9fd8799f581c70757a7f84898e93989da2a7acb1b6bbc0c5cacfd4d9dee3e8edf2f75820f89522d53ec5d471859825a00c59836263130e8cc4a59015a944371049139dafff58200104070a0d101316191c1f2225282b2e3134373a3d404346494c4f5255585b5ed8799fd87a9f581c20272e353c434a51585f666d747b828990979ea5acb3bac1c8cfd6ddffd8799fd8799fd8799f581c3039424b545d666f78818a939ca5aeb7c0c9d2dbe4edf6ff08111a23ffffffff5820404b56616c77828d98a3aeb9c4cfdae5f0fb06111c27323d48535e69747f8a951a001e8480ff",
    approval_name(preimage) == #"7650779196dc13c7237489239331d09eda883fbfa15c8768f3e284228e8fdaa1",
  }
}

test the_preimages_of_the_vectors_are_pairwise_distinct() {
  let preimages =
    [
      #"d8799fd8799f5820000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f00ffff",
      #"d87a9fd8799f581c70757a7f84898e93989da2a7acb1b6bbc0c5cacfd4d9dee3e8edf2f75820f89522d53ec5d471859825a00c59836263130e8cc4a59015a944371049139dafff58200104070a0d101316191c1f2225282b2e3134373a3d404346494c4f5255585b5eff",
      #"d87c9fd8799f581c70757a7f84898e93989da2a7acb1b6bbc0c5cacfd4d9dee3e8edf2f75820f89522d53ec5d471859825a00c59836263130e8cc4a59015a944371049139dafff58200104070a0d101316191c1f2225282b2e3134373a3d404346494c4f5255585b5ed8799fd87a9f581c20272e353c434a51585f666d747b828990979ea5acb3bac1c8cfd6ddffd8799fd8799fd8799f581c3039424b545d666f78818a939ca5aeb7c0c9d2dbe4edf6ff08111a23ffffffff5820404b56616c77828d98a3aeb9c4cfdae5f0fb06111c27323d48535e69747f8a951a001e8480ff",
    ]
  list.length(list.unique(preimages)) == list.length(preimages)
}

test the_names_of_the_vectors_are_pairwise_distinct() {
  let names =
    [
      #"f89522d53ec5d471859825a00c59836263130e8cc4a59015a944371049139daf",
      #"7bb99a3ed884c2143636542734ff8987649b8deb960ba4b787bf1ab40f35fecb",
      #"7650779196dc13c7237489239331d09eda883fbfa15c8768f3e284228e8fdaa1",
    ]
  list.length(list.unique(names)) == list.length(names)
}
