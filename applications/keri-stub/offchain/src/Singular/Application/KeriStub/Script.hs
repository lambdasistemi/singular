{- |
Module      : Singular.Application.KeriStub.Script
Description : The stub's always-succeeding Plutus V3 script, as a constant
License     : Apache-2.0

One always-succeeding Plutus V3 script, built by the stub itself: the
serialised always-true mint program below, no Aiken project of the
stub's own, no blueprint. It is both the approval minting policy and
the spending script of the holdings the stub creates; its hash is the
pin. Its shape is Conway's: the ledger hands a Plutus V3 script its
purpose as a constructor the script dispatches on, and a flat chain
of lambdas over a constant is refused by the ledger as an invalid
return value whatever its arity — proven on the devnet for two, three
and four arguments and for unit and boolean results alike.
-}
module Singular.Application.KeriStub.Script
    ( -- * The script
      keriStubScriptBytes
    , keriStubScript
    , keriStubPolicy
    ) where

import Data.ByteString (ByteString)
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Short qualified as SBS

import Cardano.Ledger.Core (Script)

import Singular.Registry.Ledger (ConwayEra)
import Singular.Registry.TxBuilder.Internal
    ( computeScriptHash
    , scriptFromBytes
    , scriptHashBytes
    )

{- | The always-succeeding program, as the pinned Aiken compiler builds
it for a Plutus V3 script serving both of the stub's purposes: a spend
handler and a mint handler, each returning true, with a failing
fallback for the purposes the stub never runs. The ledger hands a V3
script one argument, the script context, whose script-info constructor
names the purpose, and the program dispatches on that constructor — so
a flat chain of lambdas over a constant is refused as an invalid
return value at any arity (proven on the devnet for two, three and
four arguments and unit and boolean results alike), and a program with
a mint handler alone would pass the booking and refuse the spend that
releases the holding it strands (the same evaluation shows both
verdicts; see the purposes spec).

The program below is
@validator always {
  spend(_, _, _, _) { True }
  mint(_, _, _) { True }
  else(_) { fail }
}@ compiled by this repository's own Aiken pin (v1.1.21); its bytes
are the constant, the record check holds the stub to them, and the
purposes spec holds them to both purposes they are pinned for.
-}
keriStubScriptBytes :: SBS.ShortByteString
keriStubScriptBytes =
    SBS.toShort
        . either (error "keriStubScriptBytes: bad hex") id
        . B16.decode
        $ "587601010029800aba2aba1aab9eaab9dab9a4888896600264646530013005375"
            <> "4003300700398038012444b30013370e9001001c4c8cc89289805800980598"
            <> "0600098049baa0048acc004cdc3a40000071324a26eb8c028c024dd50024590"
            <> "07200e18031803800980300098019baa0068a4d13656400401"

-- | The script, from its bytes.
keriStubScript :: Script ConwayEra
keriStubScript =
    scriptFromBytes "keri-stub" keriStubScriptBytes

-- | Its hash: the approval policy and the holdings' script hash.
keriStubPolicy :: ByteString
keriStubPolicy =
    scriptHashBytes (computeScriptHash keriStubScriptBytes)
