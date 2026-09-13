# Consumer registration gate v3 manifest

- contract SHA-256:
  `7a64520ad99fbf8038dde48712cbe70ed0bd573288e0506f94a42c7fcd0b4c26`;
- shell gate SHA-256:
  `eb008076ee64162a1411d89e3e15f0ee739bcb13aa3021758d8b7e0fb180b6de`;
- parent verifier SHA-256:
  `2aa90ce1e9ee0e59c991f6d9a9b09aa189e0066a982d8d2844ee17f233118ab6`;
- executable modes: shell gate and verifier `0755`;
- historical base:
  `0100012b1afa318df3bae6cf40d6d9ee3507110e`;
- consumer source:
  `14a64a4681d3e429fab5877062b5c476c2a4bfe2`;
- current state: `BLOCKED-PRE-SEAL`; no candidate execution and no E0/E1/E4
  credit are possible until a final accepted producer/integration seal is
  supplied as a new immutable artifact;
- baseline RED: exit `1`, exact reason `missing parent producer seal
  (BLOCKED-PRE-SEAL; zero candidate execution)`, log SHA-256
  `dc3200663a37e25abc72186525d92c4657a7becb78c0d1890086e5728e56c9a4`;
- root report-only false-green receipt SHA-256:
  `01dde92a4531bf5eca2c751566480c772c0a10695d5f5f69e0b7f786b2dd2009`;
- root valid-labels false-green receipt SHA-256:
  `c6008b632db3b5d694dc299a46fa544997991175ce6c6c08aeb35de28e6ffc66`;
- fabricated candidate fixture generator SHA-256:
  `c43ebc4534dc9b0d24ea21ca82923837b4cd90eb40a2bbf196b748977372eead`;
- fabricated candidate runner SHA-256:
  `6a2f66d0ddf23be6faefbe68b5929390d7e740e143f3848e69961cb80aad15d4`;
- fabricated control wrapper SHA-256:
  `8484bd435eb2f4d03fd42ab95b2a4f99b42e18f71d8ef07d26c9ef6bd27cf807`;
- latest fabricated candidate exact commit:
  `25f4dae7e8cafff31491f297b7e1333eca3d71f3`;
- fabricated candidate seal SHA-256:
  `14a3ed6cdd05f76b7206a71655e4f3363ee1bcfba4295bc9426f8fe41d35cfe2`;
- fabricated control result: sealed parent-only preflight passed, candidate
  runner executed, parent verifier executed and rejected parent-rebuilt
  `producer-state` bytes against the fabricated all-zero digest before CEK or
  ledger credit; exit `1`;
- fabricated structured receipt SHA-256:
  `be0602b7d3e7739dca38e3c67b1b8f17cc84535efee79d96a0e6ef886902b8bb`;
- fabricated raw log SHA-256:
  `b8d6f7f257eb385aa2134f85bc41085a72246182f2c2e1deae17a3a68ae4101f`;
- fabricated control retained root:
  `/tmp/e18-v3-valid-preflight-control.XirZF3dT` (parent preflight and execution
  command streams plus structured failure retained);
- Variant-C false-green tool SHA-256:
  `602f48765695d9b606b71648685b370c59f99110a1e051c520f75fb715f62f36`;
- Variant-C false-green control SHA-256:
  `e1d46e546e510a42c8aac99f120d7a7ac7cdafeacc050c1dee0c5ece88c25a10`;
- Variant-C control result: a fake earlier-semantics evaluator accepted byte
  256 as `#00`; the parent verifier rejected it with exit `1`; control wrapper
  passed and retained `/tmp/e18-variant-c-false-green.p1oCQn26`;
- Variant-C control log SHA-256:
  `17378be5277bc0e181d3f8f22c3bfcf5c5e2905f7965ba1ac35617e0bde86e17`;
- static verification: Python compile and Ruff clean for verifier/fixture;
  `bash -n` and ShellCheck clean for the shell gate and all controls.

These controls establish fail-closed authority, source/compiled identity and
executed-semantics boundaries only. They are not a real registration positive,
ledger result, mutation result, audit or epic acceptance.
