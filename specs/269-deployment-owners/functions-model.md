# Deployment function surface

As a caller, I need the same functions and signatures through `Singular.Registry.Deployment` after their owners move.

## Ownership and signatures

| ID | Owner | Names and arguments/results |
| --- | --- | --- |
| manifest | Manifest | `readDeployment path :: FilePath -> IO Deployment`; `writeDeployment path deployment :: FilePath -> Deployment -> IO ()`; `deploymentPathFromArgs args :: [String] -> Maybe FilePath`; `deploymentPathFromEnvironment :: IO (Maybe FilePath)`; `mirrorPathFor manifestPath :: FilePath -> FilePath`; `renderOutRef input :: TxIn -> Text`; `parseOutRef text :: Text -> Either String TxIn`; `renderAddrBytes address :: Addr -> Text`. |
| mirror | Mirror | `loadMirror manifestPath :: FilePath -> IO (Map TokenId MPFInMemoryDB)`; `saveMirror manifestPath tries :: FilePath -> Map TokenId MPFInMemoryDB -> IO ()`. |
| attach | Attach | `cageConfigFor deployment parts :: Deployment -> CageParts -> Either String CageConfig`; `verifyDeployment provider deployment parts :: Provider IO -> Deployment -> CageParts -> IO [String]`; `attach provider deployment parts :: Provider IO -> Deployment -> CageParts -> IO Attached`. |

The original private helpers have one owner each: Manifest has `die message :: String -> IO a` and `hex bytes :: ByteString -> String`; Attach has `decodeAddrText text :: Text -> Maybe Addr`, `tokenFor deployment :: Deployment -> Either String TokenId`, `resolveReferenceScripts provider deployment :: Provider IO -> Deployment -> IO [(ReferenceScript, (TxIn, TxOut ConwayEra))]`, and `resolveStateUtxo provider config token :: Provider IO -> CageConfig -> TokenId -> IO (TxIn, TxOut ConwayEra)`. Manifest may expose `die` and `hex` to package-internal siblings; the facade keeps only its original export list. No new caller API is required.

`verifyDeployment` performs `cageConfigFor`, `tokenFor`, reference resolution, state resolution, then live datum active-policy and process/retract checks before returning claims. `attach` performs the first four and returns `Attached`. `loadMirror` only reads and decodes; retained callers perform the subsequent root comparison. Preserve those effects and refusal points independently.
