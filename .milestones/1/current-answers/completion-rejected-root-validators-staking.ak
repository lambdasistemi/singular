use cardano/address.{Credential}
use cardano/transaction.{Transaction}

validator staking {
  withdraw(_redeemer: Data, _account: Credential, _tx: Transaction) {
    True
  }

  else(_) {
    fail
  }
}
