import Lake
open Lake DSL

package «no-pin-investigation» where
  srcDir := "lean"

require singular from "../.."
require «open-datum» from "../../applications/open-datum"

@[default_target]
lean_lib NoPin where

@[default_target]
lean_exe «no-pin-oracle» where
  root := `Main
