# Consumer registration gate v1 manifest

- contract SHA-256:
  `5bde0566fbc1c40adf52dd5ed7e474cce440852a640e7833631749276b471866`
- executable SHA-256:
  `e73d96749930acbb98abe70e67c01f2dfc13b284a4e8a1cd901aadf72aeb9eb0`
- executable mode: `0755`
- pre-slice base:
  `0100012b1afa318df3bae6cf40d6d9ee3507110e`
- consumer source:
  `14a64a4681d3e429fab5877062b5c476c2a4bfe2`
- baseline RED receipt SHA-256:
  `e536fc628041b2f351d01893586445a7cb6a11944671df96310a69cc83ee6aa1`
- baseline outcome: exit `1`, `gate: no candidate changes from 0100012...`;
  this proves only the missing-candidate/fence entry path can fail. The
  per-class falsification controls in the contract have not run and earn no
  evidence yet.
- audit state: `UNAUDITED`; implementation may not claim gate acceptance until
  a blind existing seat audits this frozen version before taking compositor
  implementation context. One adjudicated repair at most.
