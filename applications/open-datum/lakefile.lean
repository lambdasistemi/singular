import Lake
open Lake DSL

/-! The open-datum application (#310): an isolated Lean project over the
unchanged root registry model, required from the repository root. It runs on
the root's pinned Lean toolchain; the root `application-model` recipe checks
the selected compiler against that pin. -/

package «open-datum» where
  srcDir := "lean"

require singular from "../.."

@[default_target]
lean_lib OpenDatumApplication where

@[default_target]
lean_exe «open-datum-application» where
  root := `ApplicationMain
