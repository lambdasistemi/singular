# Consumer registration gate v2 manifest

- contract SHA-256:
  `15cb215823c873c813966ddf1f15c574bdeae791d5faf0bf33e88f52b18b6026`;
- executable SHA-256:
  `4fa874f79911ea056dc82dbdb2af5735ac462b0f6aec9b02f47a6b26a75743c8`;
- executable mode: `0755`;
- historical base:
  `0100012b1afa318df3bae6cf40d6d9ee3507110e`;
- consumer source:
  `14a64a4681d3e429fab5877062b5c476c2a4bfe2`;
- state: `BLOCKED-PRE-SEAL`, not an acceptance basis and not audited;
- missing immutable companion: accepted epic-17 producer/integration-base seal
  plus the seal-hashed parent verifier. Adding those later requires a new sealed
  manifest and root inspection; this manifest is not edited in place;
- clean baseline `0100012` exit: `1`, missing candidate runner; receipt SHA-256:
  `55d0d6f468cef0805c5831a32278ddd97ae294dc6ae1e8eeb539cd034a109638`;
- frozen v1 executable retained unchanged at SHA-256
  `e73d96749930acbb98abe70e67c01f2dfc13b284a4e8a1cd901aadf72aeb9eb0`
  and explicitly `NOT ACCEPTABLE` after root falsification;
- root report-only receipt SHA-256:
  `01dde92a4531bf5eca2c751566480c772c0a10695d5f5f69e0b7f786b2dd2009`;
- root valid-labels receipt SHA-256:
  `c6008b632db3b5d694dc299a46fa544997991175ce6c6c08aeb35de28e6ffc66`;
- v2 report-only control: exact commit
  `a51cfd4fa53055b66269cd8ced96249f6d440a51`, exit `1` after its fake runner
  executed, because `does-not-exist.log` was absent;
- v2 valid-labels control: exact commit
  `f5ee22a30b032e603f7472e540fb10157f6c459d`, exit `1` for the identical
  missing raw evidence despite valid-looking labels;
- each retained v2 control log SHA-256:
  `0c80d810e8952078fb78f6a115e231d5f3e87d6a3f4822bd1691e80dcc695d8e`;
- structured v2 control receipt SHA-256:
  `c21237c2ad02b0e1c7a292efbcfd41f22a4e94b2532cdae03d5ff52bf62364bd`;
- original root clone and evidence retained under
  `/tmp/singular-root-registration-gate-falsification-6JjHGA`;
- owner control clones and complete run-receipt logs retained under
  `/tmp/singular-owner-registration-gate-v2-controls.eBjRUtWH`.

The two v2 rejections prove the v1 report-writer counterexamples cannot pass the
v2 preparation boundary. They do not prove E0/E1/E4 behavior. A real parent-run
positive, exact negative purposes, mutation controls, accepted producer seal and
root inspection remain mandatory.
