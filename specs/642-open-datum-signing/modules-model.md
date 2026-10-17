# Modules model for open-datum signing

No new module. Responsibilities change in place; the dependency direction is unchanged: the open-datum application depends on the registry's command-line library, never the reverse.

## open-datum command line

The open-datum parser keeps its own refusals and reads the signer only through the shared flag group's write reader (issue 641), which owns the mixture refusals and the address check. Its address refusal applies only where a write does not accept the external signer. Its preview reader refuses the bundle file, as the registry's does. Its inspect reader refuses the bundle file and the vault. Its usage text names every signer each write accepts. See the data model for the signer and the functions model for the changed readers.

## open-datum entry commands

insert, update, terminate and the fold reach the shared submission routine, which stages or signs according to the signer (issue 641). They gain no signing or staging code of their own. Their own receipt fields and their own narration events state a staged transaction as staged; the mechanism is issue 641's where it is generic, and this module's only where a field or event exists in open-datum alone.

## Command reference and guides

The settings table of the command reference names, per flag, the open-datum writes that take it; the documented-flags check binds it to each command's help. The run pages and harnesses move in pull requests 2 and 3; the devnet harness gains address funding in pull request 2.
