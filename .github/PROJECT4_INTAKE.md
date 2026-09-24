# Project 4 issue intake

Every issue in `lambdasistemi/singular` belongs in
[Lambda Sistemi Project 4](https://github.com/orgs/lambdasistemi/projects/4).
The board also inventories every `lambdasistemi/cardano-keri` issue. The
Singular repository constitution governs its own issue intake. Project
membership does not assign a review date or establish acceptance. The
[All issues](https://github.com/orgs/lambdasistemi/projects/4/views/1),
[Open issues](https://github.com/orgs/lambdasistemi/projects/4/views/2), and
[Past tickets](https://github.com/orgs/lambdasistemi/projects/4/views/3) views
separate inventory from state. Epics in both repositories carry the `epic`
label and appear in the [Epics view](https://github.com/orgs/lambdasistemi/projects/4/views/7).

Project admins enable automatic intake in Project 4's **Workflows** menu:
open **Auto-add to project**, choose the `lambdasistemi/singular` repository,
set the filter to `is:issue`, then **Save and turn on workflow**. Do not add an
`is:open` or label restriction: closed and otherwise unlabelled issues also
belong in the inventory. The existing **Auto-add sub-issues to project** rule
does not cover standalone issues. GitHub's auto-add rule handles newly created
or updated issues but does not backfill issues that already existed when the
rule was enabled.

As of 2026-09-24 the organization is on GitHub Free, which permits one
auto-add workflow per project. Reserve that rule for the Singular intake
required by its constitution. Cardano KERI issue creators must verify and add
their issue to Project 4 until a second authorized automation path exists.

On 2026-09-24, all 159 Singular and all 315 Cardano KERI issues were compared
individually with Project 4 through GitHub's issue-side GraphQL field. Eight
Singular issues newly missing since the prior sweep and 125 Cardano KERI issues
were added; both inventories then had zero missing memberships. Owners should
repeat that comparison after any intake failure. A project's view can lag or
hide an issue; query membership before calling an item missing.

The 19 `demo-path` cards have both `Demo window start` and `Target demo date`
set. [Demo tickets](https://github.com/orgs/lambdasistemi/projects/4/views/6)
shows both columns. The [Demo timeline](https://github.com/orgs/lambdasistemi/projects/4/views/5)
roadmap still needs those two fields selected in its **Date fields** menu by
an authenticated project editor before it plots the dates. Do not mistake
populated item fields for a configured roadmap.
