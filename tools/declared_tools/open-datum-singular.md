Tool, not a guarantee: the registry command line as built inside the open-datum application tree, for local use against an application deployment.

Marks the `singular` app of the applications/open-datum/offchain flake. The
marker lives in this declared tools location rather than in the flake that
defines the app because that flake wraps a Haskell executable; the
declaration stays with the census's declared-not-hosted list, which names
this file, and the census fails if this file loses the marker line or the
app is cited as evidence anywhere in the published text.
