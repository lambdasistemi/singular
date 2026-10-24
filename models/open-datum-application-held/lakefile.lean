import Lake
open Lake DSL

package «open-datum-application-held» where
  srcDir := "lean"

require singular from "../.."
require «singular-application-held» from "../singular-application-held"

@[default_target]
lean_lib OpenDatumApplicationHeld where
