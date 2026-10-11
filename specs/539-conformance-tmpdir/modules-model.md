# Responsibilities

Conformance.Run.Temporary owns an explicit environment capability and temporary
root lifetime, with no hidden global mutable value. Environment re-exports that
boundary. Run and ForkProbe use the capability supplied by their executable roots.
Appendix tests exercise the actual boundary. See data-model.md and functions-model.md.
