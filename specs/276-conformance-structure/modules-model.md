# Responsibility ownership

Conformance.Evidence.Asset owns the asset-movement data shape and JSON instances. It depends only on the existing aeson and text library dependencies. Conformance.Receipt retains its public exports and imports that owner; it continues to own receipt validation and storage. Conformance.Run.Live continues importing AssetEntry from Conformance.Receipt without change.

The existing producer and checker boundary remains independent. No definition of comparison, observation, validation, receipt state or story instruction moves. API generation is a distinct build responsibility and cannot change product evidence.
