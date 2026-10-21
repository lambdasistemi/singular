{- |
Module      : Singular.Registry.AddressVectors
Description : Fixed registry addresses, fingerprints and refusing words
License     : Apache-2.0

The addresses, fingerprints and words the registry address tests compare
against. The addresses and refusing words were made by an independent bech32
implementation (the reference algorithm of BIP-173, written from its
specification) after it reproduced two published BIP-173 vectors and the eight
published CIP-14 asset fingerprints; none is produced by the code under test.
The CIP-14 vectors are the ones the CIP prints, copied from its text.
-}
module Singular.Registry.AddressVectors
    ( Vector (..)
    , vectors
    , Cip14 (..)
    , cip14
    , refusalWord
    ) where

import Data.Word (Word32)

-- | One state token on one network, with its address and its fingerprint.
data Vector = Vector
    { vMagic :: Word32
    , vPrefix :: String
    , vPolicy :: String
    , vName :: String
    , vAddress :: String
    , vFingerprint :: String
    }
    deriving stock (Eq, Show)

vectors :: [Vector]
vectors =
    [ Vector
        764824073
        "singular"
        "68df9c42ebd4468be130e9cd5538a7af39cc31c146cda45f274cccc5"
        "1d5542bdf2b2c8c76728a5935edd71676d1df5f389c70863b6a4d15fe33bde26"
        "singular1dr0ecsht63rghcfsa8x42w984uuucvwpgmx6ghe8fnxv2824g27l9vkgcanj3fvntmwhzemdrh6l8zw8pp3mdfx3tl3nhh3xxd6lsg"
        "asset1gyxd24649xzsnlxnqyws8ryk2nrasdg4ahsrvx"
    , Vector
        764824073
        "singular"
        "7c58a200ab88798562d98e3223dff44d27e2be29b18387c1b1bd450c"
        "00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff"
        "singular103v2yq9t3puc2cke3cez8hl5f5n7903fkxpc0sd3h4zscq8lqrlsplcqluq07q8lqrlsplcqluq07q8lqrlsplcqluq07q8lvnn8zw"
        "asset1tjwcx64q9n0fhhqldghsfkylxl6qlpgg267462"
    , Vector
        764824073
        "singular"
        "00000000000000000000000000000000000000000000000000000000"
        "0000000000000000000000000000000000000000000000000000000000000000"
        "singular1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq6pkwd9"
        "asset1lxukcu2u4x5dgmw5fajyrdvghf77lk98uqwqft"
    , Vector
        764824073
        "singular"
        "ffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
        "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
        "singular1lllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllln0n2lu"
        "asset1a6aata5xsprcce5n60meffp7028enduwm2ryyc"
    , Vector
        1
        "singular_preprod"
        "68df9c42ebd4468be130e9cd5538a7af39cc31c146cda45f274cccc5"
        "1d5542bdf2b2c8c76728a5935edd71676d1df5f389c70863b6a4d15fe33bde26"
        "singular_preprod1dr0ecsht63rghcfsa8x42w984uuucvwpgmx6ghe8fnxv2824g27l9vkgcanj3fvntmwhzemdrh6l8zw8pp3mdfx3tl3nhh3xe8mmy4"
        "asset1gyxd24649xzsnlxnqyws8ryk2nrasdg4ahsrvx"
    , Vector
        1
        "singular_preprod"
        "7c58a200ab88798562d98e3223dff44d27e2be29b18387c1b1bd450c"
        "00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff"
        "singular_preprod103v2yq9t3puc2cke3cez8hl5f5n7903fkxpc0sd3h4zscq8lqrlsplcqluq07q8lqrlsplcqluq07q8lqrlsplcqluq07q8lnejrkn"
        "asset1tjwcx64q9n0fhhqldghsfkylxl6qlpgg267462"
    , Vector
        1
        "singular_preprod"
        "00000000000000000000000000000000000000000000000000000000"
        "0000000000000000000000000000000000000000000000000000000000000000"
        "singular_preprod1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq9th2ec"
        "asset1lxukcu2u4x5dgmw5fajyrdvghf77lk98uqwqft"
    , Vector
        1
        "singular_preprod"
        "ffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
        "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
        "singular_preprod1llllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllv9jwtp"
        "asset1a6aata5xsprcce5n60meffp7028enduwm2ryyc"
    , Vector
        2
        "singular_preview"
        "68df9c42ebd4468be130e9cd5538a7af39cc31c146cda45f274cccc5"
        "1d5542bdf2b2c8c76728a5935edd71676d1df5f389c70863b6a4d15fe33bde26"
        "singular_preview1dr0ecsht63rghcfsa8x42w984uuucvwpgmx6ghe8fnxv2824g27l9vkgcanj3fvntmwhzemdrh6l8zw8pp3mdfx3tl3nhh3x9c8avn"
        "asset1gyxd24649xzsnlxnqyws8ryk2nrasdg4ahsrvx"
    , Vector
        2
        "singular_preview"
        "7c58a200ab88798562d98e3223dff44d27e2be29b18387c1b1bd450c"
        "00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff"
        "singular_preview103v2yq9t3puc2cke3cez8hl5f5n7903fkxpc0sd3h4zscq8lqrlsplcqluq07q8lqrlsplcqluq07q8lqrlsplcqluq07q8l0xw974"
        "asset1tjwcx64q9n0fhhqldghsfkylxl6qlpgg267462"
    , Vector
        2
        "singular_preview"
        "00000000000000000000000000000000000000000000000000000000"
        "0000000000000000000000000000000000000000000000000000000000000000"
        "singular_preview1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqe5tv37"
        "asset1lxukcu2u4x5dgmw5fajyrdvghf77lk98uqwqft"
    , Vector
        2
        "singular_preview"
        "ffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
        "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
        "singular_preview1lllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllls6wgr8"
        "asset1a6aata5xsprcce5n60meffp7028enduwm2ryyc"
    , Vector
        42
        "singular_devnet"
        "68df9c42ebd4468be130e9cd5538a7af39cc31c146cda45f274cccc5"
        "1d5542bdf2b2c8c76728a5935edd71676d1df5f389c70863b6a4d15fe33bde26"
        "singular_devnet1dr0ecsht63rghcfsa8x42w984uuucvwpgmx6ghe8fnxv2824g27l9vkgcanj3fvntmwhzemdrh6l8zw8pp3mdfx3tl3nhh3x3ggs8q"
        "asset1gyxd24649xzsnlxnqyws8ryk2nrasdg4ahsrvx"
    , Vector
        42
        "singular_devnet"
        "7c58a200ab88798562d98e3223dff44d27e2be29b18387c1b1bd450c"
        "00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff"
        "singular_devnet103v2yq9t3puc2cke3cez8hl5f5n7903fkxpc0sd3h4zscq8lqrlsplcqluq07q8lqrlsplcqluq07q8lqrlsplcqluq07q8lmkpg4x"
        "asset1tjwcx64q9n0fhhqldghsfkylxl6qlpgg267462"
    , Vector
        42
        "singular_devnet"
        "00000000000000000000000000000000000000000000000000000000"
        "0000000000000000000000000000000000000000000000000000000000000000"
        "singular_devnet1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqdyyp6d"
        "asset1lxukcu2u4x5dgmw5fajyrdvghf77lk98uqwqft"
    , Vector
        42
        "singular_devnet"
        "ffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
        "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
        "singular_devnet1lllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllly2p9g5"
        "asset1a6aata5xsprcce5n60meffp7028enduwm2ryyc"
    ]

-- | A CIP-14 published vector: policy and name in hex, the fingerprint.
data Cip14 = Cip14 String String String
    deriving stock (Eq, Show)

-- | The eight vectors published in CIP-14 (fetched from the CIP's own text).
cip14 :: [Cip14]
cip14 =
    [ Cip14
        "7eae28af2208be856f7a119668ae52a49b73725e326dc16579dcc373"
        ""
        "asset1rjklcrnsdzqp65wjgrg55sy9723kw09mlgvlc3"
    , Cip14
        "7eae28af2208be856f7a119668ae52a49b73725e326dc16579dcc37e"
        ""
        "asset1nl0puwxmhas8fawxp8nx4e2q3wekg969n2auw3"
    , Cip14
        "1e349c9bdea19fd6c147626a5260bc44b71635f398b67c59881df209"
        ""
        "asset1uyuxku60yqe57nusqzjx38aan3f2wq6s93f6ea"
    , Cip14
        "7eae28af2208be856f7a119668ae52a49b73725e326dc16579dcc373"
        "504154415445"
        "asset13n25uv0yaf5kus35fm2k86cqy60z58d9xmde92"
    , Cip14
        "1e349c9bdea19fd6c147626a5260bc44b71635f398b67c59881df209"
        "504154415445"
        "asset1hv4p5tv2a837mzqrst04d0dcptdjmluqvdx9k3"
    , Cip14
        "1e349c9bdea19fd6c147626a5260bc44b71635f398b67c59881df209"
        "7eae28af2208be856f7a119668ae52a49b73725e326dc16579dcc373"
        "asset1aqrdypg669jgazruv5ah07nuyqe0wxjhe2el6f"
    , Cip14
        "7eae28af2208be856f7a119668ae52a49b73725e326dc16579dcc373"
        "1e349c9bdea19fd6c147626a5260bc44b71635f398b67c59881df209"
        "asset17jd78wukhtrnmjh3fngzasxm8rck0l2r4hhyyt"
    , Cip14
        "7eae28af2208be856f7a119668ae52a49b73725e326dc16579dcc373"
        "0000000000000000000000000000000000000000000000000000000000000000"
        "asset1pkpwyknlvul7az0xx8czhl60pyel45rpje4z8w"
    ]

-- | The words that each fail the reading check their name says, and no earlier one.
refusalWord :: String -> String
refusalWord name = case name of
    "good" ->
        "singular_preprod1dr0ecsht63rghcfsa8x42w984uuucvwpgmx6ghe8fnxv2824g27l9vkgcanj3fvntmwhzemdrh6l8zw8pp3mdfx3tl3nhh3xe8mmy4"
    "upper" ->
        "SINGULAR_PREPROD1DR0ECSHT63RGHCFSA8X42W984UUUCVWPGMX6GHE8FNXV2824G27L9VKGCANJ3FVNTMWHZEMDRH6L8ZW8PP3MDFX3TL3NHH3XE8MMY4"
    "mixed-case" ->
        "singular_preprod1dr0Ecsht63rghcfsa8x42w984uuucvwpgmx6ghe8fnxv2824g27l9vkgcanj3fvntmwhzemdrh6l8zw8pp3mdfx3tl3nhh3xe8mmy4"
    "invalid-character" ->
        "singular_preprod1dr0ecsht63rghbfsa8x42w984uuucvwpgmx6ghe8fnxv2824g27l9vkgcanj3fvntmwhzemdrh6l8zw8pp3mdfx3tl3nhh3xe8mmy4"
    "no-separator" -> "singularpreprodqqqq"
    "bad-checksum" ->
        "singular_preprod1dr0ecsht63rghcfsa8x42w984uuucvwpgmx6ghe8fnxv2824g27l9vkgcanj3fvntmwhzemdrh6l8zw8pp3mdfx3tl3nhh3xe8mmyq"
    "bad-checksum-and-unknown-prefix" ->
        "singular_mainnet1dr0ecsht63rghcfsa8x42w984uuucvwpgmx6ghe8fnxv2824g27l9vkgcanj3fvntmwhzemdrh6l8zw8pp3mdfx3tl3nhh3x5y22tq"
    "bad-checksum-and-short" ->
        "singular_devnet1dr0ecsht63rghcfsa8x42w984uuucvwpgmx6ghe8fnxv2824g27l9vkgcanj3fvntmwhzemdrh6l8zw8pp3mdfx3tl3nhhs20tpqq"
    "unknown-prefix" ->
        "singular_mainnet1dr0ecsht63rghcfsa8x42w984uuucvwpgmx6ghe8fnxv2824g27l9vkgcanj3fvntmwhzemdrh6l8zw8pp3mdfx3tl3nhh3x5y22tx"
    "unknown-prefix-and-short" ->
        "other1dr0ecsht63rghcfsa8x42w984uuucvwpgmx6ghe8fnxv2824g27l9vkgcanj3fvntmwhzemdrh6l8zw8pp3mdfx3tl3nhhslrr0ld"
    "short" ->
        "singular_devnet1dr0ecsht63rghcfsa8x42w984uuucvwpgmx6ghe8fnxv2824g27l9vkgcanj3fvntmwhzemdrh6l8zw8pp3mdfx3tl3nhhs20tpqu"
    "long" ->
        "singular_devnet1dr0ecsht63rghcfsa8x42w984uuucvwpgmx6ghe8fnxv2824g27l9vkgcanj3fvntmwhzemdrh6l8zw8pp3mdfx3tl3nhh3xqqlv2fpp"
    "empty-body" -> "singular_devnet1gzwr8r"
    _ -> error ("no such word: " <> name)
