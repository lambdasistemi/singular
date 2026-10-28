import Lake
open Lake DSL

package «singular-application-held» where
  srcDir := "lean"

require singular from "../.."

@[default_target]
lean_lib SingularApplicationHeld where

@[default_target]
lean_lib ReaderAuditSupport where
  roots := #[`ReaderAuditCore]

lean_exe reader where
  root := `ReaderMain
