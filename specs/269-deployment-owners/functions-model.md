# Deployment function surface

As a caller, I need the same functions and signatures through `Singular.Registry.Deployment` after their owners move.

## Ownership and signatures

| ID | Owner | Names and arguments/results |
| --- | --- | --- |
| F269-M | Manifest | `readDeployment path :: FilePath -> IO Deployment`; `writeDeployment path deployment :: FilePath -> Deployment -> IO ()`; `deploymentPathFromArgs args :: [String] -> Maybe FilePath`; `deploymentPathFromEnvironment :: IO (Maybe FilePath)`; `renderOutRef input :: TxIn -> Text`; `parseOutRef text :: Text -> Either String TxIn`; `renderAddrBytes address :: Addr -> Text`. |
| F269-P | Mirror | `mirrorPathFor manifestPath :: FilePath -> FilePath`; `loadMirror manifestPath :: FilePath -> IO (Map TokenId MPFInMemoryDB)`; `saveMirror manifestPath tries :: FilePath -> Map TokenId MPFInMemoryDB -> IO ()`. |
| F269-A | Attach | `cageConfigFor deployment parts :: Deployment -> CageParts -> Either String CageConfig`; `verifyDeployment provider deployment parts :: Provider IO -> Deployment -> CageParts -> IO [String]`; `attach provider deployment parts :: Provider IO -> Deployment -> CageParts -> IO Attached`. |

Private helper signatures may move with their owner. The public facade preserves its existing explicit export list. No new caller API is required.

`verifyDeployment` performs `cageConfigFor`, `tokenFor`, reference resolution, state resolution, then live datum active-policy and process/retract checks before returning claims. `attach` performs the first four and returns `Attached`. `loadMirror` only reads and decodes; retained callers perform the subsequent root comparison. Preserve those effects and refusal points independently.
