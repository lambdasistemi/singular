# Keep the existing observation interface

As a caller, I want the existing live interpreter to return the same transaction observation shape with accurate datum fields.

## Interface contract

The existing `observedStepTx` entry point remains the owner of the transaction observation. Preserve its argument/result types and the existing public exports unless inspection proves a signature change necessary; return that exact proposed change to the coordinating owner before implementation. Private helper names are implementation choices within the same responsibility and frozen file boundary. The comparator and Lean driver's interfaces stay unchanged.
