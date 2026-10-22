#!/usr/bin/env bash
# tagged-law-consumers-check: the consumers of the booking law that no
# in-process suite runs (the statement bindings of the conformance stories, the
# hash-comparison report, the negative host's mutant hygiene and part
# expectations, the Demo 1 journeys, the rehearsal, the two-actors journey and
# the published pages) read the tagged-request law: a registration or a
# termination is booked as a tagged request, the fold donates what it holds
# beyond the tip, no state-spending reject succeeds, and a custody is not
# released to its controller.
#
# Every row says what it is. A row of kind `behavioral` runs a command or a
# function of this repository over real data and judges its result; a row of
# kind `inspection` reads source text and counts what it finds. Neither kind
# establishes that a hosted journey passes: only the hosted job that runs the
# journey does. An inspection is no evidence of behaviour; it makes the
# consumers' retelling checkable until the hosted run reports.
#
# A row of status RESIDUAL is neither a pass nor a failure. It lists a consumer
# that still books through the legacy edge builder or builds the untagged
# request and that belongs to the hosted lanes on the tagged law, the
# checkpoint after this one: the devnet end-to-end lanes, the release archive's
# insert-active control, the live journey, the library's driver and the
# conformance rows. The list is that checkpoint's starting census; it does not
# say any lane passes or fails.
#
# A line that keeps a retired construct on purpose carries the marker
# `tagged-law: retired` (a refusal control: the retired action attempted and
# refused) or `tagged-law: history` (an explanation of what was retired) on
# the line or the line above it. Nothing else is excused.
#
# The instrument is checked first: every predicate is run on fixtures that
# must pass and on fixtures that must fail, and a predicate that cannot fail
# stops the run with status 2 before any row is judged.
#
# usage: tagged_law_consumers_check.sh [REPO-ROOT]
# exit 0: no row fails (residual rows do not count); 1: a row fails; 2: the instrument or a setup step
# failed (never a verdict on the consumers).
set -uo pipefail

root="${1:-$PWD}"
root="$(realpath -m "$root")"

rows=0
failing=0
work="$(mktemp -d)" || {
  echo "tagged-law-consumers: SETUP: no scratch directory" >&2
  exit 2
}
trap 'rm -rf "$work"' EXIT

residuals=0
residual() { # SECTION LABEL DETAIL
  residuals=$((residuals + 1))
  printf 'TAGGED-LAW: [inspection] %s: %s: RESIDUAL — %s\n' "$1" "$2" "$3"
}

row() { # SECTION KIND LABEL PASS|FAIL [DETAIL]
  rows=$((rows + 1))
  if [ "$4" = PASS ]; then
    printf 'TAGGED-LAW: [%s] %s: %s: PASS%s\n' "$2" "$1" "$3" "${5:+ — $5}"
  else
    failing=$((failing + 1))
    printf 'TAGGED-LAW: [%s] %s: %s: FAIL%s\n' "$2" "$1" "$3" "${5:+ — $5}"
  fi
}

instrument_fail() {
  echo "tagged-law-consumers: INSTRUMENT: $*" >&2
  exit 2
}

# ------------------------------------------------------------------
# Predicates (each takes its inputs as arguments so the controls can feed it
# fixtures; the rows feed it the tree).
# ------------------------------------------------------------------

# The lines of FILE matching the extended regex that are not comments of the
# file's language and are not excused by a marker on the line or the line
# above it: prints `line:text`, one per line.
unmarked_hits() { # FILE ERE
  local hits
  hits="$(grep -nE -e "$2" "$1" | cut -d: -f1 | tr '\n' ' ' || true)"
  [ -n "$hits" ] || return 0
  awk -v hits="$hits" '
    BEGIN { n = split(hits, H, " "); for (i = 1; i <= n; i++) want[H[i]] = 1 }
    { lines[NR] = $0 }
    END {
      for (i = 1; i <= NR; i++) {
        if (!(i in want)) continue
        t = lines[i]
        s = t; sub(/^[ \t]+/, "", s)
        if (s ~ /^(#|--|\/\/)/) continue
        if (t ~ /tagged-law: (retired|history)/) continue
        if (i > 1) { p = lines[i - 1]; sub(/^[ \t]+/, "", p); if (p ~ /^(#|--|\/\/)/ && p ~ /tagged-law: (retired|history)/) continue }
        printf "%d:%s\n", i, substr(t, 1, 120)
      }
    }' "$1"
}

hit_count() { # FILE ERE
  unmarked_hits "$1" "$2" | grep -c . || true
}

# The (statement, digest) pairs a Haskell module binds: `bound "name" "hex64"`
# and `mkBoundObligation "OpenDatumApplication.Statements.name" "hex64"`.
bound_pairs() { # FILE
  tr '\n' ' ' <"$1" \
    | grep -oE '(bound|mkBoundObligation)[[:space:]]+"[A-Za-z_.0-9]+"[[:space:]]+"[0-9a-f]{64}"' \
    | sed -E 's/^(bound|mkBoundObligation)[[:space:]]+"(OpenDatumApplication\.Statements\.)?([A-Za-z_0-9]+)"[[:space:]]+"([0-9a-f]{64})"$/\3 \4/'
}

# The module variable of each bound statement: prints `name variable`, the
# variable being the last `x :: Theorem T` declared before the binding.
statement_variables() { # FILE
  awk '
    /^[a-z][A-Za-z0-9_'"'"']*$/ { ident = $1 }
    /^[a-z][A-Za-z0-9_'"'"']* :: Theorem/ { v = $1; age = 0; armed = 0; next }
    /^[[:space:]]+:: Theorem/ { v = ident; age = 0; armed = 0; next }
    { age++ }
    v != "" && age < 8 && (/(^|[[:space:]])bound[[:space:]]*$/ || /(^|[[:space:]])bound[[:space:]]+"/ || /mkBoundObligation/) { armed = 1 }
    armed && match($0, /"(OpenDatumApplication\.Statements\.)?[A-Za-z_0-9]+"/) {
      n = substr($0, RSTART + 1, RLENGTH - 2)
      sub(/^OpenDatumApplication\.Statements\./, "", n)
      if (n !~ /^[0-9a-f]{64}$/) { print n, v; armed = 0; v = "" }
    }' "$1"
}

# Whether the ledger carries the statement under the digest, proved: prints
# `ok` or the reason.
ledger_verdict() { # LEDGER NAME DIGEST
  jq -r --arg n "OpenDatumApplication.Statements.$2" --arg d "$3" '
    [.theorems[] | select(.statement == $n)] as $r
    | if ($r | length) == 0 then "the accepted ledger has no statement of this name"
      elif ($r | length) > 1 then "the accepted ledger lists it more than once"
      elif $r[0].statementSha256 != $d then "the ledger digest is " + ($r[0].statementSha256[0:12]) + "…, not the bound " + ($d[0:12]) + "…"
      elif $r[0].status != "PROVED" then "the ledger says " + $r[0].status
      else "ok" end' "$1"
}

# The lines of FILE that describe a reject, a deposit release or an approval
# return as current behaviour: prints `count|first line`.
retired_mechanic_lines() { # FILE
  awk '
    { t = tolower($0) }
    t ~ /registry reject|deposit (is |are )?(released|returned|refunded)|releases the (protected )?deposit|approval return|return(s)? the deposit|released to the controller/ {
      if (t ~ /retired|no longer|refused|history/) next
      c++
      if (c == 1) first = substr($0, 1, 90)
    }
    END { printf "%d|%s", c + 0, first }' "$1"
}

# The arm of a part script that sets what the pair expects: the
# `short-fold-of-a-booked-termination)` arm whose body sets `expect_role=`
# (the script has another arm of that name that runs the commands).
short_fold_arm() { # FILE
  awk '
    /^ *short-fold-of-a-booked-termination\)/ { f = 1; buf = "" }
    f { buf = buf $0 "\n" }
    f && /;;/ { if (buf ~ /expect_role=/) { printf "%s", buf; exit } f = 0 }' "$1" | head -n 8
}

# Whether an arm expects the state validator, by its role and its hash field.
arm_expects_state_validator() { # ARM
  grep -q 'expect_role="state-validator"' <<<"$1" && grep -q 'expect_hash_field="stateHash"' <<<"$1"
}

# Whether a row of the retained-command table says the command is not retold
# on the tagged-request law.
retained_row_ok() { # ROW
  grep -qiE 'not retold' <<<"$1" && grep -qi 'tagged-request law' <<<"$1"
}

# Whether some line of the files naming the topic also says it is uncovered.
published_uncovered() { # ERE FILE...
  local re="$1"
  shift
  cat "$@" | grep -iE -- "$re" | grep -qi 'uncovered'
}

# Whether the Limits section of the pull-request text states a limit.
limit_stated() { # FILE ERE
  sed -n '/^## Limits/,$p' "$1" | grep -qiE -- "$2"
}

# The job id (in backquotes) a page names on a line that names the suite;
# prints it, or nothing.
mapped_job() { # SUITE PAGE JOBS
  local suite="$1" page="$2" jobs="$3" line j found=""
  while IFS= read -r line; do
    for j in $jobs; do
      case "$line" in *"\`$j\`"*) found="$j" ;; esac
    done
  done < <(grep -F -- "$suite" "$page")
  [ -z "$found" ] || printf '%s\n' "$found"
}

# The numbers a hash-comparison report line states against the labels that
# name them: prints `base-changed earlier-changed base-unchanged` or nothing.
report_numbers() { # LINE
  local a b c
  a="$(grep -oE '[0-9]+ base titles? changed' <<<"$1" | grep -oE '^[0-9]+' | head -n1 || true)"
  b="$(grep -oE '[0-9]+ earlier-added titles? changed' <<<"$1" | grep -oE '^[0-9]+' | head -n1 || true)"
  c="$(grep -oE '[0-9]+ base titles? unchanged' <<<"$1" | grep -oE '^[0-9]+' | head -n1 || true)"
  [ -n "$a" ] && [ -n "$b" ] && [ -n "$c" ] && printf '%s %s %s\n' "$a" "$b" "$c"
}

# ------------------------------------------------------------------
# The instrument's own controls
# ------------------------------------------------------------------

controls() {
  local d="$work/controls"
  mkdir -p "$d" || instrument_fail "no control directory"

  # unmarked_hits: a retired read, a marked one, a comment and a clean file.
  cat >"$d/consumer.sh" <<'EOF'
# a comment naming .released is not a read
x="$(field step .released)"
# tagged-law: retired
y="$(field step .released)"
z="$(field step .released)" # tagged-law: history
w="$(field step .released)"
EOF
  [ "$(hit_count "$d/consumer.sh" '\.released')" = 2 ] \
    || instrument_fail "unmarked_hits: expected the two unmarked reads of a four-read fixture"
  printf 'nothing retired here\n' >"$d/clean.sh"
  [ "$(hit_count "$d/clean.sh" '\.released')" = 0 ] \
    || instrument_fail "unmarked_hits: a clean fixture reported a read"

  # bound_pairs: both syntaxes, and neither a non-statement obligation nor a
  # name bound to something that is no digest.
  cat >"$d/Controls.hs" <<'EOF'
alpha =
    bindTheorem $
        mkBoundObligation
            "OpenDatumApplication.Statements.alpha_statement"
            "1111111111111111111111111111111111111111111111111111111111111111"
            modelRevision
beta =
    bound
        "beta_statement"
        "2222222222222222222222222222222222222222222222222222222222222222"
gamma = bindTheorem (mkBoundObligation "client-policy-booking-refused" "no-theorem-claimed" "client-policy")
delta = obligationRow "R299-05" "3333333333333333333333333333333333333333333333333333333333333333"
EOF
  [ "$(bound_pairs "$d/Controls.hs" | sort | tr '\n' ';')" = "alpha_statement 1111111111111111111111111111111111111111111111111111111111111111;beta_statement 2222222222222222222222222222222222222222222222222222222222222222;" ] \
    || instrument_fail "bound_pairs: wrong pairs read from the fixture"

  # statement_variables: the variable declared before each binding, in both
  # syntaxes, and not the obligation that binds no statement.
  cat >"$d/Variables.hs" <<'EOF'
alphaVar :: Theorem Alpha
alphaVar =
    bindTheorem $
        mkBoundObligation
            "OpenDatumApplication.Statements.alpha_statement"
            "1111111111111111111111111111111111111111111111111111111111111111"
            modelRevision

betaVar :: Theorem Beta
betaVar =
    bound
        "beta_statement"
        "2222222222222222222222222222222222222222222222222222222222222222"

policyVar :: Theorem Policy
policyVar = bindTheorem (mkBoundObligation "client-policy-booking-refused" "no-theorem-claimed" "client-policy")
EOF
  [ "$(statement_variables "$d/Variables.hs" | sort | tr '\n' ';')" = "alpha_statement alphaVar;beta_statement betaVar;" ] \
    || instrument_fail "statement_variables: wrong variables read from the fixture: $(statement_variables "$d/Variables.hs" | tr '\n' ';')"

  # ledger_verdict: ok, missing, wrong digest, not proved.
  cat >"$d/ledgers.json" <<'EOF'
{"theorems": [
  {"statement": "OpenDatumApplication.Statements.alpha_statement", "statementSha256": "1111111111111111111111111111111111111111111111111111111111111111", "status": "PROVED"},
  {"statement": "OpenDatumApplication.Statements.open_statement", "statementSha256": "4444444444444444444444444444444444444444444444444444444444444444", "status": "ASSUMED"}
]}
EOF
  [ "$(ledger_verdict "$d/ledgers.json" alpha_statement 1111111111111111111111111111111111111111111111111111111111111111)" = ok ] \
    || instrument_fail "ledger_verdict: a bound statement under its digest was not ok"
  [ "$(ledger_verdict "$d/ledgers.json" alpha_statement 2222222222222222222222222222222222222222222222222222222222222222)" != ok ] \
    || instrument_fail "ledger_verdict: a wrong digest passed"
  [ "$(ledger_verdict "$d/ledgers.json" missing_statement 1111111111111111111111111111111111111111111111111111111111111111)" != ok ] \
    || instrument_fail "ledger_verdict: a missing statement passed"
  [ "$(ledger_verdict "$d/ledgers.json" open_statement 4444444444444444444444444444444444444444444444444444444444444444)" != ok ] \
    || instrument_fail "ledger_verdict: a statement that is not proved passed"

  # report_numbers: a line stating the three counts, and the line that
  # states only a base-wide qualifier.
  [ "$(report_numbers 'OK — 18 union validators (base 14: 12 base titles changed, 2 base titles unchanged; 1 earlier-added title changed)')" = "12 1 2" ] \
    || instrument_fail "report_numbers: the labelled counts were not read"
  [ -z "$(report_numbers 'OK — 18 union validators equal the expected set (base 14, of which 13 declared changed and the rest at their base hash)')" ] \
    || instrument_fail "report_numbers: an unlabelled count was read"

  # retired_receipt_keys: the retired reads are found and the live keys are not.
  cat >"$d/retired-reads.sh" <<'EOF'
x="$(field step .released)"
jq -e 'has("released")' r.json
y=.settled[0].settlement.deposit
z=$r.rejected[0]
w=.rejector
EOF
  [ "$(hit_count "$d/retired-reads.sh" "$retired_receipt_keys")" = 5 ] \
    || instrument_fail "retired_receipt_keys: not every retired read of the fixture was found"
  cat >"$d/live-reads.sh" <<'EOF'
a=.released_at
b=.depositor
c=.transfer
e=.donation
f=.settled[0].settlement.liveOutput
EOF
  [ "$(hit_count "$d/live-reads.sh" "$retired_receipt_keys")" = 0 ] \
    || instrument_fail "retired_receipt_keys: a live key was reported as retired"

  # reject_success_step: the step that runs the reject and requires success,
  # not the inspections named after it and not the refused attempt.
  cat >"$d/reject-steps.sh" <<'EOF'
run reject success -- registry reject "${common[@]}"
srun carol-reject success -- registry reject "${carol[@]}"
EOF
  cat >"$d/other-steps.sh" <<'EOF'
run inspect-before-reject success -- inspect --key keyD
refused reject-early client-refusal -- registry reject "${common[@]}"
EOF
  [ "$(hit_count "$d/reject-steps.sh" "$reject_success_step")" = 2 ] \
    || instrument_fail "reject_success_step: a step that runs the reject and requires success was missed"
  [ "$(hit_count "$d/other-steps.sh" "$reject_success_step")" = 0 ] \
    || instrument_fail "reject_success_step: an inspection or a refused attempt was counted"

  # retired_mechanic_lines: a page that says the deposit is released, a page
  # that says it no longer is, and a clean page.
  printf '%s\n' 'The fold releases the deposit to the controller.' >"$d/page-bad.md"
  printf '%s\n' 'The fold no longer releases the deposit; it is donated.' >"$d/page-ok.md"
  printf '%s\n' 'The fold donates what the request holds beyond the tip.' >"$d/page-clean.md"
  [ "$(retired_mechanic_lines "$d/page-bad.md" | cut -d'|' -f1)" = 1 ] \
    || instrument_fail "retired_mechanic_lines: the retired mechanic was not found"
  [ "$(retired_mechanic_lines "$d/page-ok.md" | cut -d'|' -f1)" = 0 ] \
    || instrument_fail "retired_mechanic_lines: a line that says it is retired was counted"
  [ "$(retired_mechanic_lines "$d/page-clean.md" | cut -d'|' -f1)" = 0 ] \
    || instrument_fail "retired_mechanic_lines: a clean page was counted"

  # The patterns of the consumer rows, each on a line it must find and on a
  # line it must leave alone.
  printf '%s\n' '  ( insertApproval' '    , terminateDestination' 'import Singular.Application.OpenDatum.Release' >"$d/removed-yes.hs"
  printf '%s\n' '  ( insertEnvelope' 'import Singular.Application.OpenDatum.Book' >"$d/removed-no.hs"
  [ "$(hit_count "$d/removed-yes.hs" "$removed_producer_api")" = 3 ] \
    || instrument_fail "removed_producer_api: a removed entry point was missed"
  [ "$(hit_count "$d/removed-no.hs" "$removed_producer_api")" = 0 ] \
    || instrument_fail "removed_producer_api: a live name was counted"
  printf '%s\n' 'x <- requestEdgeImpl cfg' 'datum = RequestDatum r' >"$d/legacy-yes.hs"
  printf '%s\n' 'x <- bookRegistrationImpl cfg' 'datum = RegistrationDatum r' >"$d/legacy-no.hs"
  [ "$(hit_count "$d/legacy-yes.hs" "$legacy_request")" = 2 ] \
    || instrument_fail "legacy_request: an untagged request builder was missed"
  [ "$(hit_count "$d/legacy-no.hs" "$legacy_request")" = 0 ] \
    || instrument_fail "legacy_request: a tagged builder was counted"
  printf '%s\n' 'tid <- Edges.bookEdge cfg codes' 'bookEdgeWith cfg' >"$d/edge-yes.hs"
  printf '%s\n' 'bookEdges cfg' 'abookEdge' >"$d/edge-no.hs"
  [ "$(hit_count "$d/edge-yes.hs" "$legacy_booking")" = 2 ] \
    || instrument_fail "legacy_booking: the legacy edge builder was missed"
  [ "$(hit_count "$d/edge-no.hs" "$legacy_booking")" = 0 ] \
    || instrument_fail "legacy_booking: a neighbouring name was counted"
  printf '%s\n' '    , bookEdge' '    , bookEdgeTx' >"$d/export-yes.hs"
  printf '%s\n' '    , bookRegistrationImpl' >"$d/export-no.hs"
  [ "$(hit_count "$d/export-yes.hs" "$legacy_export")" = 2 ] \
    || instrument_fail "legacy_export: an exported legacy booking was missed"
  [ "$(hit_count "$d/export-no.hs" "$legacy_export")" = 0 ] \
    || instrument_fail "legacy_export: a live export was counted"

  # The arm of a part script that sets the expectation, and its verdict.
  cat >"$d/part-good.sh" <<'EOF'
case "$part" in
  short-fold-of-a-booked-termination)
    # the commands arm
    run_ok setup
    ;;
esac
case "$part" in
  short-fold-of-a-booked-termination)
    expect_hash_field="stateHash"
    expect_pin="$pin_state"
    expect_role="state-validator"
    ;;
esac
EOF
  sed -e 's/stateHash/applicationHash/; s/state-validator/application-at-fold/' "$d/part-good.sh" >"$d/part-bad.sh"
  arm_expects_state_validator "$(short_fold_arm "$d/part-good.sh")" \
    || instrument_fail "short_fold_arm: the state validator arm was not accepted"
  ! arm_expects_state_validator "$(short_fold_arm "$d/part-bad.sh")" \
    || instrument_fail "short_fold_arm: the application arm was accepted"
  ! arm_expects_state_validator "$(printf 'short-fold-of-a-booked-termination)\n  run_ok x\n  ;;\n' | head -n 3)" \
    || instrument_fail "arm_expects_state_validator: the commands arm alone was accepted"

  # A row of the retained-command table.
  retained_row_ok "| \`nix run .#li01\` | unavailable: not retold, built or verified on the tagged-request law | #172 |" \
    || instrument_fail "retained_row_ok: a row that says it was accepted wrongly refused"
  ! retained_row_ok "| \`nix run .#li01\` | unavailable: unverified, no passing build evidence | #172 |" \
    || instrument_fail "retained_row_ok: a row without the statement was accepted"

  # Publication as uncovered, and the Limits section.
  printf '%s\n' 'The sweep is uncovered.' >"$d/pub-yes.md"
  printf '%s\n' 'The sweep is covered by a row.' >"$d/pub-no.md"
  published_uncovered 'sweep' "$d/pub-yes.md" || instrument_fail "published_uncovered: an uncovered topic was missed"
  ! published_uncovered 'sweep' "$d/pub-no.md" || instrument_fail "published_uncovered: a covered topic was accepted"
  printf '%s\n' '## How to verify' 'The BadInputsUTxO case is not claimed above.' '## Limits' 'MissingVKeyWitnessesUTXOW is left to the signer.' >"$d/pr.md"
  limit_stated "$d/pr.md" 'MissingVKeyWitnessesUTXOW' || instrument_fail "limit_stated: a stated limit was missed"
  ! limit_stated "$d/pr.md" 'BadInputsUTxO' || instrument_fail "limit_stated: a mention above the Limits section was accepted"

  # The hosted job a page names for a suite.
  printf '%s\n' "The \`cage-tests\` suite runs in \`registry-cage-tests\`." "The keri-stub-tests suite has no job named." >"$d/selection.md"
  [ "$(mapped_job cage-tests "$d/selection.md" 'registry-cage-tests other-job')" = registry-cage-tests ] \
    || instrument_fail "mapped_job: a named job was not found"
  [ -z "$(mapped_job keri-stub-tests "$d/selection.md" 'registry-cage-tests other-job')" ] \
    || instrument_fail "mapped_job: a job was invented for a suite that names none"

  # The registry hygiene function, taken from the tool: it must accept a patch
  # that removes exactly its two anchored statements inside applyEdge and
  # refuse one that removes only one.
  local fn
  fn="$(sed -n '/^registry_patch_hygiene_ok() {$/,/^}$/p' "$root/tools/negative_host_mutants.sh")"
  [ -n "$fn" ] || instrument_fail "the registry hygiene function is not in tools/negative_host_mutants.sh"
  (
    cd "$d" || exit 1
    rm -rf hyg && mkdir -p hyg/onchain/lib/registry && cd hyg || exit 1
    git init -q . && git config user.email t@t && git config user.name t
    cat >onchain/lib/registry/fold.ak <<'EOF'
use x

fn applyEdge(acc, key) {
  let p1 = 1
  let p2 = 2
  let p3 = 3
  let a = lib.occupiedRefusal()
  let b = mpf.insert(acc.trie, key, leafActive, proof)
  let q1 = 4
  let q2 = 5
  let q3 = 6
  b
}

fn other() {
  1
}
EOF
    git add -A && git commit -q -m base
    grep -v 'lib.occupiedRefusal()\|mpf.insert(acc.trie, key, leafActive, proof)' onchain/lib/registry/fold.ak >fold.new
    cp onchain/lib/registry/fold.ak fold.old
    cp fold.new onchain/lib/registry/fold.ak
    git diff >../good.patch
    cp fold.old onchain/lib/registry/fold.ak
    grep -v 'lib.occupiedRefusal()' onchain/lib/registry/fold.ak >fold.new
    cp fold.new onchain/lib/registry/fold.ak
    git diff >../one.patch
    cp fold.old onchain/lib/registry/fold.ak
  ) >/dev/null 2>&1 || instrument_fail "could not build the hygiene fixtures"
  (
    eval "$fn"
    registry_patch_hygiene_ok "$d/good.patch" onchain/lib/registry/fold.ak "$d/hyg/onchain/lib/registry/fold.ak" || exit 1
    registry_patch_hygiene_ok "$d/one.patch" onchain/lib/registry/fold.ak "$d/hyg/onchain/lib/registry/fold.ak" && exit 1
    exit 0
  ) >/dev/null 2>&1 || instrument_fail "registry_patch_hygiene_ok: the good patch was refused or the one-anchor patch accepted"

  echo "tagged-law-consumers: instrument controls held"
}

# ------------------------------------------------------------------
# Section 1: the statement bindings (behavioral: the ledger is read at run time)
# ------------------------------------------------------------------

# The statements the stories bind, by the frozen disposition of the fifteen
# bindings under the accepted model: twelve restated, three retired in favour
# of four new ones.
frozen_statements="
duplicate_refused_by_registry
resurrection_refused_by_registry
insertion_holding_inline
update_keeps_registry
update_payload_free
update_requires_controller
update_preserves_custody
bookInsert_inversion
insertion_requires_registry_identity
bookTerminate_inversion
fold_inversion
update_inversion
termination_fold_burns_atomically
only_termination_booking_transfers_custody
fold_routes_economics
termination_fold_donates_held_minus_tip
"

section_bindings() {
  local s="statement bindings"
  local controls_hs="$root/conformance/lib/Conformance/Cli/Controls.hs"
  local ledger="$root/applications/open-datum/ledgers.json"
  [ -f "$controls_hs" ] && [ -f "$ledger" ] || instrument_fail "no controls module or no ledger under $root"
  local name digest verdict bound_names frozen_sorted extra
  bound_names=""
  while read -r name digest; do
    [ -n "$name" ] || continue
    bound_names="$bound_names$name"$'\n'
    verdict="$(ledger_verdict "$ledger" "$name" "$digest")"
    if [ "$verdict" = ok ]; then
      row "$s" behavioral "bound statement $name resolves in the accepted ledger under its bound digest" PASS
    else
      row "$s" behavioral "bound statement $name resolves in the accepted ledger under its bound digest" FAIL "$verdict"
    fi
  done < <(bound_pairs "$controls_hs")
  # A statement is bound only where a story tells it: the module's variable
  # for the statement is the subject of a `theorem` clause.
  local variable
  while read -r name variable; do
    [ -n "$name" ] || continue
    if grep -qE "theorem[[:space:]]+$variable([[:space:]]|\$)" "$controls_hs"; then
      row "$s" inspection "bound statement $name is told by a story ($variable)" PASS
    else
      row "$s" inspection "bound statement $name is told by a story ($variable)" FAIL "no 'theorem $variable' clause in the controls module"
    fi
  done < <(statement_variables "$controls_hs")
  frozen_sorted="$(printf '%s\n' "$frozen_statements" | sed '/^$/d' | sort)"
  bound_names="$(printf '%s' "$bound_names" | sort)"
  # No statement the accepted model dropped stays bound.
  extra="$(comm -13 <(printf '%s\n' "$frozen_sorted") <(printf '%s\n' "$bound_names") | tr '\n' ' ')"
  if [ -z "$extra" ]; then
    row "$s" inspection "no statement the accepted model dropped is still bound" PASS
  else
    row "$s" inspection "no statement the accepted model dropped is still bound" FAIL "still bound: $extra"
  fi
  # Each statement of the frozen disposition is bound under its accepted digest
  # (a telling exists) or is published as uncovered; none is disabled and none
  # is shown as passing without a telling.
  for name in $frozen_statements; do
    if grep -qx "$name" <<<"$bound_names"; then
      continue
    fi
    if published_uncovered "$name" "$root/docs/consumer-conformance.md" "$root/docs/conformance-evidence.md" "$root/conformance/BOOK.md"; then
      row "$s" inspection "statement $name, not bound, is published as uncovered" PASS
    else
      row "$s" inspection "statement $name is bound under its accepted digest or published as uncovered" FAIL "neither bound nor named with the word uncovered in docs/consumer-conformance.md, docs/conformance-evidence.md or conformance/BOOK.md"
    fi
  done
  for name in $frozen_statements; do
    verdict="$(jq -r --arg n "OpenDatumApplication.Statements.$name" '[.theorems[] | select(.statement == $n)] | if length == 1 then .[0].status else "absent" end' "$ledger")"
    if [ "$verdict" = PROVED ]; then
      row "$s" behavioral "the accepted ledger carries $name, proved" PASS
    else
      row "$s" behavioral "the accepted ledger carries $name, proved" FAIL "ledger says $verdict"
    fi
  done
  # The model revision the evidence reads names the commit that carries the
  # accepted ledger.
  local rev_file="$root/conformance/model-revision" rev
  rev="$(head -n1 "$rev_file" 2>/dev/null || true)"
  if [ -z "$rev" ] || ! git -C "$root" cat-file -e "$rev^{commit}" 2>/dev/null; then
    row "$s" behavioral "conformance/model-revision names a commit of this history" FAIL "revision '${rev:-none}'"
  elif git -C "$root" show "$rev:applications/open-datum/ledgers.json" 2>/dev/null | cmp -s - "$ledger"; then
    row "$s" behavioral "conformance/model-revision names a commit whose ledger is the accepted one" PASS "$rev"
  else
    row "$s" behavioral "conformance/model-revision names a commit whose ledger is the accepted one" FAIL "the ledger at $rev is not the ledger of the tree"
  fi
}

# ------------------------------------------------------------------
# Section 2: the hash-comparison report (behavioral: the command runs)
# ------------------------------------------------------------------

section_report() {
  local s="hash-comparison report"
  local base="$root/specs/528-registry-cli-split/evidence/base-hashes.json"
  local rec1="$root/specs/529-request-tag/evidence/declared-changes.json"
  local rec2="$root/specs/529-request-tag/evidence/declared-changes-fold.json"
  local out line want got
  [ -f "$base" ] && [ -f "$rec1" ] && [ -f "$rec2" ] || instrument_fail "no base or declared-change records under $root"
  want="$(jq -r -n --slurpfile b "$base" --slurpfile r1 "$rec1" --slurpfile r2 "$rec2" '
      ($b[0].validators | map(.title)) as $bt
      | ([$r1[0].changed[], $r2[0].changed[]] | unique) as $ch
      | "\([$ch[] | select(. as $t | $bt | index($t))] | length) \([$ch[] | select(. as $t | $bt | index($t) | not)] | length) \([$bt[] | select(. as $t | $ch | index($t) | not)] | length)"')" \
    || instrument_fail "cannot compute the sets the report states"
  out="$(cd "$root" && nix run --quiet .#script-hash-comparison 2>&1)" \
    || {
      row "$s" behavioral "the command reports success" FAIL "script-hash-comparison exited non-zero"
      return
    }
  line="$(grep -m1 '^script-hash-comparison: OK — ' <<<"$out" || true)"
  if [ -z "$line" ]; then
    row "$s" behavioral "the command prints its summary line" FAIL "no summary line"
    return
  fi
  row "$s" behavioral "the command prints its summary line" PASS
  got="$(report_numbers "$line")"
  if [ -z "$got" ]; then
    row "$s" behavioral "the summary line names the changed base titles, the changed earlier-added titles and the unchanged base titles" FAIL "no '<n> base titles changed', '<n> earlier-added titles changed' and '<n> base titles unchanged' in: $line"
  elif [ "$got" = "$want" ]; then
    row "$s" behavioral "the summary line states the sets as computed from the records ($want)" PASS
  else
    row "$s" behavioral "the summary line states the sets as computed from the records" FAIL "states '$got', the records give '$want'"
  fi
  if grep -qE 'base [0-9]+, of which [0-9]+ declared changed' <<<"$line"; then
    row "$s" behavioral "the summary line does not call every declared change a change of the base" FAIL "$line"
  else
    row "$s" behavioral "the summary line does not call every declared change a change of the base" PASS
  fi
}

# ------------------------------------------------------------------
# Section 3: the negative host
# ------------------------------------------------------------------

section_negative_host() {
  local s="negative host"
  local tool="$root/tools/negative_host_mutants.sh"
  local part="$root/tools/negative_host_part.sh"
  local rules="$root/applications/open-datum/negative/mutants/rules.json"
  local mdir="$root/applications/open-datum/negative/mutants"
  local fn name file patch
  fn="$(sed -n '/^registry_patch_hygiene_ok() {$/,/^}$/p' "$tool")"
  # The registry-source mutants pass the tool's own hygiene function against
  # the sources they patch.
  while IFS=$'\t' read -r name file patch; do
    [ -n "$name" ] || continue
    if (
      eval "$fn"
      registry_patch_hygiene_ok "$mdir/$patch" "$file" "$root/$file"
    ) >/dev/null 2>&1; then
      row "$s" behavioral "registry-source mutant $name passes the tool's patch hygiene against $file" PASS
    else
      row "$s" behavioral "registry-source mutant $name passes the tool's patch hygiene against $file" FAIL "the hygiene function refuses it (anchors or file)"
    fi
  done < <(jq -r '.mutants[] | select(.registry_source // false) | [.name, .file, .patch] | @tsv' "$rules")
  # Every mutant patch applies to the tree it patches.
  while IFS=$'\t' read -r name patch; do
    [ -n "$name" ] || continue
    if git -C "$root" apply --check "$mdir/$patch" >/dev/null 2>&1; then
      row "$s" behavioral "mutant $name patch applies to the tree" PASS
    else
      row "$s" behavioral "mutant $name patch applies to the tree" FAIL "git apply --check refuses it"
    fi
  done < <(jq -r '.mutants[] | [.name, .patch] | @tsv' "$rules")
  # The tool lists every mutant of the table (the hosted matrix is discovered
  # from this list) and the page that documents the host names each of them.
  local listed in_table
  listed="$(bash "$tool" "$root" --list 2>/dev/null | jq -r '.mutant | length' 2>/dev/null || true)"
  in_table="$(jq -r '.mutants | length' "$rules")"
  if [ -n "$listed" ] && [ "$listed" = "$in_table" ]; then
    row "$s" behavioral "the tool lists all $in_table mutants of the table for the hosted matrix" PASS
  else
    row "$s" behavioral "the tool lists all $in_table mutants of the table for the hosted matrix" FAIL "lists '${listed:-none}'"
  fi
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    if grep -q -- "$name" "$root/docs/negative-host.md"; then
      row "$s" inspection "docs/negative-host.md names mutant $name" PASS
    else
      row "$s" inspection "docs/negative-host.md names mutant $name" FAIL "the page does not name it"
    fi
  done < <(jq -r '.mutants[].name' "$rules")
  # Every pair a mutant refers to is a part of the host table, and every part
  # is referred to: the matrix has no orphan on either side.
  local orphan_ref orphan_part
  orphan_ref="$(comm -23 <(jq -r '[.mutants[] | ((.flip // [])[] | .pair), ((.side_flips // [])[] | .pair), .control] | unique | .[]' "$rules" | sort -u) <(jq -r '.part[]' "$root/applications/open-datum/negative/pairs.json" | sort -u) | tr '\n' ' ')"
  orphan_part="$(comm -13 <(jq -r '[.mutants[] | ((.flip // [])[] | .pair), ((.side_flips // [])[] | .pair), .control] | unique | .[]' "$rules" | sort -u) <(jq -r '.part[]' "$root/applications/open-datum/negative/pairs.json" | sort -u) | tr '\n' ' ')"
  if [ -z "$orphan_ref" ] && [ -z "$orphan_part" ]; then
    row "$s" inspection "every pair of the matrix is a part of the host table and every part is in the matrix" PASS
  else
    row "$s" inspection "every pair of the matrix is a part of the host table and every part is in the matrix" FAIL "referred but not parts: ${orphan_ref:-none}; parts no mutant refers to: ${orphan_part:-none}"
  fi
  # The short-donation pair is judged where the law refuses it: the state
  # validator, by its pin, reading its own hash field.
  local arm
  arm="$(short_fold_arm "$part")"
  if arm_expects_state_validator "$arm"; then
    row "$s" inspection "the short-fold pair expects the state validator's role and hash" PASS
  else
    row "$s" inspection "the short-fold pair expects the state validator's role and hash" FAIL "its arm reads: $(tr -s ' \n' ' ' <<<"$arm" | cut -c1-200)"
  fi
  # The owed amount is the donation, not the old request-deposit arithmetic.
  local fnbody
  fnbody="$(sed -n '/^settles_and_pays() {$/,/^}$/p' "$part")"
  if grep -qE "fields\[0\]\.fields\[4\]\.int|envelope\.fields\[0\]\.fields\[5\]\.int" <<<"$fnbody"; then
    row "$s" inspection "the settlement check does not read the retired request-deposit and envelope-deposit fields" FAIL "settles_and_pays reads the legacy request datum's deposit field"
  else
    row "$s" inspection "the settlement check does not read the retired request-deposit and envelope-deposit fields" PASS
  fi
  if grep -qiE 'donat' <<<"$fnbody"; then
    row "$s" inspection "the settlement check states the donation (held minus the tip)" PASS
  else
    row "$s" inspection "the settlement check states the donation (held minus the tip)" FAIL "settles_and_pays names no donation"
  fi
  local n
  n="$(hit_count "$part" 'validRelease|release-additive|releasedTo|settlesOf')"
  if [ "$n" = 0 ]; then
    row "$s" inspection "the part script names no retired release arithmetic" PASS
  else
    row "$s" inspection "the part script names no retired release arithmetic" FAIL "$n unmarked lines name validRelease, release-additive, releasedTo or settlesOf"
  fi
}

# ------------------------------------------------------------------
# Section 4: the journeys, the rehearsal and the two-actors journey
# ------------------------------------------------------------------

# A receipt key the retired commands printed: the live output a fold
# released, the settlement's deposit, the retired reject's receipt.
# Entry points the producers removed, the untagged request the legacy edge
# builder makes, and the legacy edge builder itself.
removed_producer_api='insertApproval|terminateApproval|terminateDestination|OpenDatum\.Release'
legacy_request='requestEdgeImpl|RequestDatum|requestLockedAda|rejectRequestsImpl|rejectRequestsWithRefs'
legacy_booking='\bbookEdge(To|With|Tx|Measured)?\b'
legacy_export='^[[:space:]]*, bookEdge(To|With|Tx|Measured)?[[:space:]]*$'

# A journey step that runs the retired reject and requires it to succeed.
reject_success_step='(^|[[:space:]])(run|srun)[[:space:]]+[A-Za-z0-9-]+[[:space:]]+success[[:space:]]+--[[:space:]]+registry reject'

retired_receipt_keys='(\.|has\(")released\b|settlement\.(released|deposit)\b|\.rejected\b|\.rejector\b'

section_consumers() {
  local s="journeys and rows" f n reads
  # The tree produces none of the retired keys: the CLI and the applications
  # print the booking's transfer and the fold's donation.
  local produced
  produced="$(grep -rhoE '"(released|rejector)"' "$root/offchain/cli/src" "$root/applications/open-datum/offchain/src" "$root/applications/keri-stub/offchain/src" 2>/dev/null | sort -u | tr '\n' ' ')"
  if [ -z "$produced" ]; then
    row "$s" inspection "the producers print no released or rejector receipt key" PASS
  else
    row "$s" inspection "the producers print no released or rejector receipt key" FAIL "still printed: $produced"
  fi
  for f in tools/demo1_cli_journey.sh tools/demo1_closed_journey.sh tools/keri_stub_journey.sh tools/demo1_cli_prepare_funding.sh demo1/rehearsal/scene-4-permanent.sh demo1/rehearsal/verify.sh; do
    n="$(hit_count "$root/$f" "$retired_receipt_keys")"
    if [ "$n" = 0 ]; then
      row "$s" inspection "$f reads none of the retired receipt keys" PASS
    else
      reads="$(unmarked_hits "$root/$f" "$retired_receipt_keys" | head -n 2 | tr '\n' ' ' | cut -c1-200)"
      row "$s" inspection "$f reads none of the retired receipt keys" FAIL "$n unmarked reads; first: $reads"
    fi
  done
  # No journey runs the retired reject and expects it to succeed.
  for f in tools/demo1_cli_journey.sh tools/demo1_cli_prepare_funding.sh; do
    n="$(hit_count "$root/$f" "$reject_success_step")"
    if [ "$n" = 0 ]; then
      row "$s" inspection "$f expects no registry reject to succeed" PASS
    else
      row "$s" inspection "$f expects no registry reject to succeed" FAIL "$n steps run a reject and require success"
    fi
  done
  # Where the retired action is still attempted, the attempt is refused and
  # says it is retired.
  if grep -qE 'refused[[:space:]]+[A-Za-z0-9-]*reject[A-Za-z0-9-]*[[:space:]]+client-refusal' "$root/tools/demo1_cli_journey.sh" \
    && grep -q 'rejected-retired\|is retired\|retired' <(grep -n 'reject' "$root/tools/demo1_cli_journey.sh" | grep -E 'refused|\.reason'); then
    row "$s" inspection "the Demo 1 journey keeps the retired reject as a refused attempt that names it retired" PASS
  else
    row "$s" inspection "the Demo 1 journey keeps the retired reject as a refused attempt that names it retired" FAIL "no refused reject step whose reason is checked for 'retired'"
  fi
  # The funding script builds its token-only wallet without a reject, by a
  # labelled harness mint.
  if grep -qiE '(setup|harness)[^#]*mint|mint[^#]*(setup|harness)' "$root/tools/demo1_cli_prepare_funding.sh"; then
    row "$s" inspection "the funding script obtains its non-ada outputs by a mint labelled as setup" PASS
  else
    row "$s" inspection "the funding script obtains its non-ada outputs by a mint labelled as setup" FAIL "no line labels a mint as setup or harness"
  fi
  # The two-actors journey no longer lists the succeeding reject as a row.
  n="$(grep -c "Bob rejects Alice's expired request" "$root/tools/registry_two_actors.py" "$root/tools/registry_two_actors_status.test.py" 2>/dev/null | awk -F: '{s += $2} END {print s + 0}')"
  if [ "$n" = 0 ]; then
    row "$s" inspection "the two-actors journey lists no row in which a reject succeeds" PASS
  else
    row "$s" inspection "the two-actors journey lists no row in which a reject succeeds" FAIL "the row 'Bob rejects Alice's expired request' occurs $n times in the harness and its tests"
  fi
  # No hosted consumer builds a request in the retired untagged shape or
  # imports an entry point the producers removed.
  for f in conformance/app-cli/Conformance/Cli/Backend.hs conformance/app-cli/Conformance/Cli/Admission.hs conformance/app-cli/Conformance/Cli/Attach.hs; do
    n="$(hit_count "$root/$f" "$removed_producer_api")"
    if [ "$n" = 0 ]; then
      row "$s" inspection "$f names no removed producer entry point" PASS
    else
      row "$s" inspection "$f names no removed producer entry point" FAIL "$n unmarked lines"
    fi
  done
  # The hosted lanes on the tagged law are the next checkpoint's: the devnet
  # lanes, the release archive's insert-active control, the live journey, the
  # library's driver and the conformance rows still book through the legacy edge
  # builder or build the untagged request. They are listed here as residual, in
  # the order they will be retold; a residual row is neither a pass nor a
  # failure of this check, and its presence shows nothing about any lane.
  for f in conformance/app-cli/Conformance/Cli/Backend.hs conformance/app-cli/Conformance/Cli/Admission.hs conformance/app-cli/Conformance/Cli/Attach.hs conformance/app/Conformance/Run/Book.hs conformance/app/Conformance/Run/CsRows.hs conformance/app/Conformance/Run/Fold.hs conformance/app/Conformance/Run/Live.hs conformance/app/Conformance/Run/Replay.hs offchain/journey/Journey/Steps.hs offchain/journey/Journey/Controls.hs offchain/journey/Journey/Proofs.hs offchain/journey/Main.hs; do
    n="$(hit_count "$root/$f" "$legacy_request")"
    [ "$n" = 0 ] || residual "$s" "$f builds no untagged request and runs no retired reject" "$n unmarked lines"
  done
  local legacy
  while IFS= read -r f; do
    f="${f#"$root"/}"
    n="$(hit_count "$root/$f" "$legacy_booking")"
    [ "$n" = 0 ] || residual "$s" "$f books through no legacy edge builder" "$n unmarked lines name bookEdge, bookEdgeTo, bookEdgeWith, bookEdgeTx or bookEdgeMeasured"
  done < <(grep -rlE "$legacy_booking" --include='*.hs' "$root/offchain/e2e-test" "$root/offchain/insert-active" "$root/offchain/journey" "$root/offchain/lib/Singular/Registry/Driver.hs" "$root/conformance/app" "$root/conformance/app-cli" 2>/dev/null | sort)
  legacy="$(hit_count "$root/offchain/lib/Singular/Registry/TxBuilder/Edges.hs" "$legacy_export")"
  [ "$legacy" = 0 ] || residual "$s" "the library's Edges module exports no legacy edge booking" "the exports leave only when no current consumer remains"
}

# ------------------------------------------------------------------
# Section 4b: the nine retained entrypoints, not retold
# ------------------------------------------------------------------

# Nine entrypoints keep their source and their owning ticket and are not
# retold on the tagged law. What is owed is the reader-facing notice: the
# archive's table of retained commands says, for each, that it is not
# retold, built or verified on the tagged-request law, and the journey and
# archive pages say plainly what the legacy law was.
section_retained() {
  local s="retained entrypoints" name archive journey line section
  archive="$root/onchain-release/README.md"
  journey="$root/offchain/journey/README.md"
  for name in li01 li-refusals naming-rows register-rows recovery-rows retirement-rows retirement-verify repair-rows connected-verifier; do
    line="$(grep -E "^\| \`(nix run \.#)?$name\`" "$archive" | head -n1 || true)"
    if [ -z "$line" ]; then
      row "$s" inspection "the archive README's table of retained commands has a row for $name" FAIL "no row"
    elif retained_row_ok "$line"; then
      row "$s" inspection "the archive README says $name is not retold, built or verified on the tagged-request law" PASS
    else
      row "$s" inspection "the archive README says $name is not retold, built or verified on the tagged-request law" FAIL "its row does not say it is not retold on the tagged-request law"
    fi
  done
  section="$(sed -n '/^### The retained legacy commands/,/^## /p' "$archive")"
  if grep -qi 'reject' <<<"$section" && grep -qi 'approval' <<<"$section" && grep -qi 'untagged request' <<<"$section" && grep -qi 'retired' <<<"$section"; then
    row "$s" inspection "the archive README names the retired reject, the untagged request and the approval these entrypoints still use" PASS
  else
    row "$s" inspection "the archive README names the retired reject, the untagged request and the approval these entrypoints still use" FAIL "the section on the retained legacy commands names not all of reject, approval, untagged request and retired"
  fi
  if grep -qi 'retained' "$journey" && grep -qi 'unverified' "$journey" && grep -qi 'tagged-request law' "$journey"; then
    row "$s" inspection "the journey README tells the runnable journey from the retained, unverified entrypoints of the earlier law" PASS
  else
    row "$s" inspection "the journey README tells the runnable journey from the retained, unverified entrypoints of the earlier law" FAIL "it does not say 'retained', 'unverified' and 'tagged-request law'"
  fi
  if grep -qi 'untagged request' "$journey" && grep -qi 'approval' "$journey" && grep -qiE 'reject[^.]*retired|retired[^.]*reject' "$journey"; then
    row "$s" inspection "the journey README names the retired reject, the untagged request and the approval" PASS
  else
    row "$s" inspection "the journey README names the retired reject, the untagged request and the approval" FAIL "it does not name the retired reject, the untagged request and the approval"
  fi
}

# ------------------------------------------------------------------
# Section 5: the pages and the verification limits
# ------------------------------------------------------------------

section_pages() {
  local s="pages and limits"
  local doc="$root/docs/test-selection.md" n suites missing name
  # The test-selection page names every Hspec suite the Cabal files declare.
  suites="$(grep -rn --include='*.cabal' -E '^test-suite[[:space:]]+' "$root" 2>/dev/null | grep -v dist-newstyle | sed -E 's/.*:test-suite[[:space:]]+//' | awk '{print $1}' | sort -u)"
  missing=""
  for name in $suites; do
    grep -q "$name" "$doc" || missing="$missing$name "
  done
  if [ -z "$missing" ]; then
    row "$s" inspection "docs/test-selection.md names every test suite the Cabal files declare" PASS
  else
    row "$s" inspection "docs/test-selection.md names every test suite the Cabal files declare" FAIL "not named: $missing"
  fi
  # Each Hspec suite has a hosted run line in a workflow.
  for name in cage-tests open-datum-tests keri-stub-tests record-value-tests contract-tests; do
    if grep -rqE "nix run[^#]*#$name\b" "$root/.github/workflows"; then
      row "$s" inspection "a workflow step runs $name" PASS
    else
      row "$s" inspection "a workflow step runs $name" FAIL "no 'nix run … #$name' in .github/workflows"
    fi
  done
  # This check is itself hosted.
  if grep -rq 'tagged-law-consumers-check' "$root/.github/workflows"; then
    row "$s" inspection "a workflow step runs the tagged-law consumers check" PASS
  else
    row "$s" inspection "a workflow step runs the tagged-law consumers check" FAIL "no workflow step runs it"
  fi
  # The verification limits of the pull request are written down.
  local pr="$root/specs/529-request-tag/pull-request.md"
  if [ ! -f "$pr" ]; then
    row "$s" inspection "the pull-request text exists with the repository template's sections" FAIL "specs/529-request-tag/pull-request.md does not exist"
    for name in BadInputsUTxO OutsideValidityIntervalUTxO OutsideForecast MissingVKeyWitnessesUTXOW InvalidWitnessesUTXOW "all inputs spent" "forgeable" "cached" "11 pending" 'Constr 0 \[\]'; do
      row "$s" inspection "the limits state: $name" FAIL "no pull-request text"
    done
    row "$s" inspection "the pull-request text states the exact model revision the conformance evidence reads" FAIL "no pull-request text"
  else
    local sec ok=1
    for sec in "What changed" "Why" "How to verify" "Lean correspondence and constitution" "Limits"; do
      grep -q "^## $sec" "$pr" || ok=0
    done
    if [ "$ok" = 1 ]; then
      row "$s" inspection "the pull-request text exists with the repository template's sections" PASS
    else
      row "$s" inspection "the pull-request text exists with the repository template's sections" FAIL "a template section is missing"
    fi
    for name in BadInputsUTxO OutsideValidityIntervalUTxO OutsideForecast MissingVKeyWitnessesUTXOW InvalidWitnessesUTXOW "all inputs spent" "forgeable" "cached" "11 pending" 'Constr 0 \[\]'; do
      if limit_stated "$pr" "$name"; then
        row "$s" inspection "the limits state: $name" PASS
      else
        row "$s" inspection "the limits state: $name" FAIL "the Limits section does not mention it"
      fi
    done
    if grep -q "$(head -n1 "$root/conformance/model-revision")" "$pr"; then
      row "$s" inspection "the pull-request text states the exact model revision the conformance evidence reads" PASS
    else
      row "$s" inspection "the pull-request text states the exact model revision the conformance evidence reads" FAIL "the text does not contain $(head -n1 "$root/conformance/model-revision")"
    fi
  fi
  # The rows the law leaves uncovered are published as uncovered, never
  # disabled and never shown as passing.
  local topic pattern
  for topic in "reference-state rejection:reference.state" "retraction:retraction" "the sweep:the sweep|sweep" "production node discovery:node discovery" "generic open custody:generic.open" "keri-stub custody:keri-stub"; do
    name="${topic%%:*}"
    pattern="${topic#*:}"
    if published_uncovered "$pattern" "$root/docs/consumer-conformance.md" "$root/docs/conformance-evidence.md" "$root/conformance/BOOK.md"; then
      row "$s" inspection "the conformance pages publish $name as uncovered" PASS
    else
      row "$s" inspection "the conformance pages publish $name as uncovered" FAIL "no line of docs/consumer-conformance.md, docs/conformance-evidence.md or conformance/BOOK.md names it with the word uncovered"
    fi
  done
  # Pages that state the retired mechanics as current behaviour: every page of
  # the documentation, the release archive's guides and the README is read; a
  # line that describes a reject, a deposit release or an approval return
  # without saying it is retired, refused or history counts against its page.
  local page clean=0 checked=0
  while IFS= read -r page; do
    page="${page#"$root"/}"
    checked=$((checked + 1))
    n="$(retired_mechanic_lines "$root/$page")"
    if [ "${n%%|*}" = 0 ]; then
      clean=$((clean + 1))
    else
      row "$s" inspection "$page states no retired mechanic as current" FAIL "${n%%|*} lines describe a reject, a deposit release or an approval return without saying it is retired; first: ${n#*|}"
    fi
  done < <(
    find "$root/docs" "$root/onchain-release" -name '*.md' 2>/dev/null | sort
    printf '%s\n' "$root/README.md"
  )
  row "$s" inspection "$clean of the $checked pages read state no retired mechanic as current" PASS
  # The test-selection page maps each test suite to the hosted job that runs it.
  local jobs
  jobs="$(awk 'FNR == 1 { injobs = 0 } /^jobs:/ { injobs = 1; next } injobs && /^  [A-Za-z0-9_-]+:[[:space:]]*$/ { sub(/^  /, ""); sub(/:.*/, ""); print }' "$root"/.github/workflows/*.yml | sort -u)"
  for name in $suites; do
    local named_job
    named_job="$(mapped_job "$name" "$doc" "$jobs")"
    if [ -n "$named_job" ]; then
      row "$s" inspection "docs/test-selection.md maps $name to a hosted job ($named_job)" PASS
    else
      row "$s" inspection "docs/test-selection.md maps $name to a hosted job" FAIL "no line naming the suite also names, in backquotes, a job id of the workflows"
    fi
  done
}

# ------------------------------------------------------------------

controls
section_bindings
section_report
section_negative_host
section_consumers
section_retained
section_pages

echo "tagged-law-consumers: $rows rows, $failing failing, $residuals residual (listed for the hosted lanes on the tagged law)"
if [ "$failing" -eq 0 ]; then
  exit 0
fi
exit 1
