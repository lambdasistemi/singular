import Singular.Economics.FoldRouting

/-! Fee funding is read from ordinary outputs of the unspent set. Addresses
do not establish wallet ownership: funding and change may use other addresses.
The request's own value remains protected by its full refund floor. -/

namespace Singular

def retractionFunding (u : EconomicUtxo) (tx : EconomicTransaction)
    (request : RegistrationRequest) : List EconomicOutput :=
  (u.filter fun entry => inputsContainReference tx.transaction.inputs entry.1 &&
    entry.1 != request.reference).map Prod.snd

def retractionFundingRefusal (u : EconomicUtxo) (tx : EconomicTransaction)
    (request : RegistrationRequest) : Option String :=
  (retractionFunding u tx request).findSome? fun output =>
    if output.output.stateTokens > 0 || output.output.role == .state then
      some "retract-state-spent"
    else if !output.contents.trieReadyTags.isEmpty then some "retract-funding-trie-ready-tag"
    else if !output.contents.applicationTags.isEmpty then some "retract-funding-application-tag"
    else if !output.singularTags.isEmpty then some "retract-funding-singular-tag"
    else if output.output.role == .request then some "retract-funding-request-address"
    else if output.request.isSome then some "retract-funding-request"
    else none

def retractionFundingLovelace (u : EconomicUtxo) (tx : EconomicTransaction)
    (request : RegistrationRequest) : Nat :=
  foldOrdinaryLovelace (retractionFunding u tx request)

end Singular
