import SingularApplicationHeld.Reader
import SingularApplicationHeld.Query

namespace SingularApplicationHeld
open Singular Lean

/-- One generic reader scenario, with explicit finite interpretations. -/
structure ReaderQuery where
  request : ReaderRequest
  observation : ReaderObservation
  codes : List CodeEntry
  hashes : List SingularApplicationHeld.Assets.HashEntry
  roots : List RootEntry
  decoding : List (Nat × ApplicationDatum)
  deriving ToJson, FromJson

/-- The supplied tables define total interpretations; unlisted encodings,
hashes and roots denote [] or zero, and unlisted datums fail decoding. -/
def runReaderQuery (query : ReaderQuery) : ReaderAnswer :=
  let code : Codec := fun preimage =>
    ((query.codes.find? fun entry => entry.preimage == preimage).map (·.encoded)).getD []
  let hash : Hash := fun bytes =>
    ((query.hashes.find? fun entry => entry.input == bytes).map (·.output)).getD 0
  let commit : TrieCommit := fun trie =>
    ((query.roots.find? fun entry => entry.trie == trie).map (·.commitment)).getD 0
  let decode : DecodeApplication := fun datum =>
    (query.decoding.find? fun entry => entry.1 == datum).map (·.2)
  readKey hash code commit decode query.request query.observation

/-- The neutral reader uses the same finite evidence interpretation and never
consults the application-decoding table. -/
def runNeutralReaderQuery (query : ReaderQuery) : NeutralReaderAnswer :=
  let code : Codec := fun preimage =>
    ((query.codes.find? fun entry => entry.preimage == preimage).map (·.encoded)).getD []
  let hash : Hash := fun bytes =>
    ((query.hashes.find? fun entry => entry.input == bytes).map (·.output)).getD 0
  let commit : TrieCommit := fun trie =>
    ((query.roots.find? fun entry => entry.trie == trie).map (·.commitment)).getD 0
  readNeutralKey hash code commit query.request query.observation

end SingularApplicationHeld
