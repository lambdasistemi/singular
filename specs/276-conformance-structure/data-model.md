# Asset evidence compatibility

AssetEntry retains exactly aePolicy :: Text, aeName :: Text and aeQuantity :: Integer, strict fields, stock Show and Eq derivations. JSON fields remain policy, name and quantity, with the exact existing parser and encoder bodies. No new or removed field and no new expectation.
