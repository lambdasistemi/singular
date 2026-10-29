import Lake
open Lake DSL

/-! Reference definitions imported by the aligned open-datum model.
The aligned model's recipe checks the compiler against the root toolchain pin. -/

package «open-datum» where
  srcDir := "lean"

require singular from "../.."

@[default_target]
lean_lib OpenDatumApplication where
  globs := #[.submodules `OpenDatumApplication]
