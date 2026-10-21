# Functions for the pin gate

Names, argument names and result types only. No bodies.

## State token module of the registry library

- `resolveRegistry(application, release, token, session)`: changed. Compares the application pin for every pin form except the one taken from the datum; the result carries the application pin standing.
- `resolveRegistryAmong(candidates, token, session)`: new. Candidates are non-empty pairs of an application and its release; the result is the resolved registry and the candidate the datum's application pin selects, or the refusal.
- `pinsDifference(config, datum, fields)`: new, pure. The first field whose datum pin differs from the configuration's pin, or none.

## Live module of the command line library

- `resolveSaved(application, directory, release, access, roles, wallet, session)`: unchanged signature; the saved registry also carries the application pin standing.
- `resolveSavedAmong(candidates, directory, access, roles, wallet, session)`: new, for a program with several applications.

## Command modules

- `runDescribe`, `runInspect`, `runCreate`, `submitBundle`: changed behaviour as the command table says; `submitBundle` gains a release argument for a bundle that names a registry.
- open-datum `registryMode`: removed. Its place is a function that returns the mode and the saved registry from the gate, with the refusal as the command's own.
- `receipt` helpers: gain the application pin field where a registry was resolved.

## Library reference

- The worked example calls `resolveRegistry` with an application and a release and shows the refusal for a forged pin.
