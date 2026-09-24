# Function signatures

As a contributor, I keep every Haskell callable interface unchanged while the
lint command gains source coverage.

## Interface boundary

No function is added, removed, moved, or given a new signature in this ticket.
The existing lint app keeps its command name and exit-status contract. Its
source discovery is configuration, not a new exported function.
