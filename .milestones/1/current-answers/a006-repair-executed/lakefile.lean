import Lake
open Lake DSL
package rootrepair where
@[default_target]
lean_lib Root where
  roots := #[`Singular.Model, `Grading, `RejectedFold, `RejectedFoldGate, `RootRepair]
