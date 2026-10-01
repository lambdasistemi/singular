# #324 data model

- D1 Indexed point: slot and block hash of the last block the index applied; none before the first block. Network identity comes from the follower configuration.
- D2 Gated index: a pinned `IndexerHandle` whose mutations and view holds exclude each other, plus its indexed point (D1), its coverage (followed from origin or from a tip; interest set all or filtered) and a readiness source (processed slot, tip slot, upstream status).
- D3 Indexer view failure: one named class per R3 case — lag (node point, indexed point, bound), fork (slot, both hashes), coverage incomplete (start, filter), restoring (processed slot, tip slot), disconnected (upstream status), unsupported (capability name). An exception distinct from #323's `ViewFailure`.
- D4 Backend selection (S2): node or indexer, resolved once at startup from CLI configuration.

Relationships: one view → one node view point = one indexed point; an address read in that view → the gated index at that point.
