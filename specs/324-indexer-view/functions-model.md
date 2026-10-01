# #324 functions model

Shapes are binding; module placement and auxiliary names are the commit owner's within the modules model.

- F1 `indexerProvider :: <gated index> -> <readiness source> -> <bound> -> Provider IO -> Provider IO` — the node provider becomes an indexer-backed provider whose views satisfy I1–I3.
- F2 gated index construction from an `IndexerHandle` and its coverage (D2), and the handle the follower receives from it.
- F3 `followedProvider :: Provider IO -> Submitter IO -> IO (Provider IO)` — signature unchanged; on a followed-from-origin devnet it returns F1's provider.
- F4 (S2) backend selection at CLI startup (D4) feeding the existing composition.
