# Tasks

Retroactive record, written 2026-09-15 from PR #106 merged at
`f558d0e8fc916eef494fffcef09cfe2ac5582b8e`.

The tasks are the PR's commits in order, each done with its sha.

- [x] deployment-manifest-deploy-verify-commands `c86bd3f2b4134aa78977addf8be67411d13540ab` feat: a
  deployment manifest, and the deploy and verify commands.
- [x] naming-runners-attach-recorded-deployment `85bed5ae0a02ce79380de1d404d868089f30bbc3` feat: the
  naming runners attach to a recorded deployment.
- [x] devnet-check-that-attach-path-boots-publishes `7ab2e5665106d064cf3380283899504ed02af06d` feat: a
  devnet check that the attach path boots and publishes nothing.
- [x] what-deployment-what-has-travel-its-manifest `6bf33d2692617b280331884ab5eaaf8ffdebf557` docs: what a
  deployment is, and what has to travel with its manifest.
- [x] create-trie-attaching-run-needs-give-check `be2280efa32faec02dabdb5c9398502ad01950f0` fix: create
  the trie an attaching run needs, and give the check its own
  chain.
- [x] retract-window-staking-credential-picking-big-utxo `b53bff75a3bd5176add2663a4dfac47feb70c2f5` fix: the
  retract window, the staking credential, and picking a big UTxO.
- [x] wait-end-retract-window-not-start `d07296e52e09b8f9a640631e35e7a13fc4246cf5` fix: wait to
  the end of the retract window, not the start.
- [x] carry-deployment-work-across-registry-rename `0d124a8801c67e02a31921415c6763ee748ea466` chore: carry
  the deployment work across the registry rename.
- [x] preserve-exact-spellings-attaching-deployment `df655eacbf73390617b2fe4c59849b8621469da7` fix: preserve
  exact spellings when attaching to a deployment.
- [x] observe-confirmations-reuse-registered-credentials `f0c65061cbd7ad33c45242e73368a1b2b0442a17` fix: observe
  confirmations and reuse registered credentials.
- [x] count-reference-scripts-at-journey-publisher `acd3ab8cf132c60beb51a3322ff273e57d59dd6c` fix: count
  reference scripts at every journey publisher.

## Slice

Persistent deployment with attached runners. Gate as shipped:
`just ci` green, packaged builds pass, shared-devnet attach gate
exit 0 with stable and fresh-control counts, both support retracts
accepted.
