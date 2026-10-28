import Lake
open Lake DSL

package «singular-application-held» where
  srcDir := "lean"

require singular from "../.."

@[default_target]
lean_lib SingularApplicationHeld where
