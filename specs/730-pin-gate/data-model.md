# Data for the pin gate

## Application pin standing

What the gate knows of the application pin after resolving a registry. Exactly one of:

- compared: the application derived its pin and the datum's pin equals it.
- not checked against any blueprint: the pin was taken from the datum because the program cannot derive it.

A resolved registry carries it. A pin form that carries a script, a compiled script or a hash is always compared; only a pin taken from the datum is not.

## Where the standing is printed

- Every receipt of a command that resolved a registry carries the standing in a field named `applicationPin` with the text `compared` or `not-checked-against-any-blueprint`, once.
- The describe page carries it beside the application policy among the registry's pinned policies, and its release block no longer holds an application hash.

## Refusals

- The existing refusal registry-pin-mismatch FIELD keeps its name and its field spellings. For a program with several candidate applications and a datum matching none, the field is application and the text says the datum's policy differs from every application policy the program derives.
- A create whose read-back datum differs from what it built is the partial outcome and names the field, with the words of the existing refusal.
- A submit refusal for a bundle that names no registry, and one for a bundle that names a registry when no release is given, each with its own name.

## Unchanged

The bundle (its registry name stays an optional text), the state datum, the configuration, the receipts' other fields, exit statuses for honest registries.
