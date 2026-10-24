#!/usr/bin/env python3
# Tool, not a guarantee: replay the frozen investigation; no hosted job runs it.
"""Compile complete violating histories after isolated guard/premise changes.

The substitutions are made in temporary namespaces. The candidate sources are
never rewritten. A negative certificate must compile without sorryAx; then the
exact bound consequence must fail at the named behavioral obligation.
"""

import hashlib
import json
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent
MODULES = [
    "Core",
    "Application",
    "Client",
    "History",
    "Fixtures",
    "HistoryClaims",
    "HistoryFixtures",
]
NS = "NoPin.HistoryControl"


def instance(label, theorem, arguments, premise, proof, claim, negative, assertion):
    return (
        f"""
abbrev control_premise_{label} := {premise}
abbrev control_claim_{label} := {claim}
theorem control_witness_{label} : control_premise_{label} := {proof}
theorem control_negative_{label} : ¬ control_claim_{label} := {negative}
#bind_history_instance HistoryStatements.{theorem}
  [hash, code, commit, release, {arguments}] control_witness_{label} control_claim_{label}
""",
        f"\ntheorem obligation_{label} : control_claim_{label} := {assertion}\n",
    )


def supply_instance(label, world, registry, key, reachable):
    return instance(
        label,
        "supply_in_step",
        f"{world}, {registry}, {key}",
        f"HistoryPremises hash code commit release {world} {registry} {key}",
        f"by refine ⟨{reachable}, by decide, ?_, ?_⟩; "
        "all_goals first | (unfold FiniteEncoding; decide) | (unfold FiniteCollisionFree; decide)",
        f"SupplyAt hash code {world} {registry} {key}",
        f"by unfold control_claim_{label} SupplyAt; decide",
        f"by unfold control_claim_{label} SupplyAt; decide",
    )


def main():
    sources = {
        m: (ROOT / "lean/NoPin/ApplicationRequests" / f"{m}.lean").read_text()
        for m in MODULES
    }
    # Mutation controls test the frozen statements and explicit instances, rather
    # than attempting to transport production proof terms across changed laws.
    sources["HistoryClaims"] = re.sub(
        r":= by.*?(?=\n/--|\nend HistoryStatements)",
        ":= by sorry\n",
        sources["HistoryClaims"],
        flags=re.S,
    )
    prefix = (
        "\nnamespace NoPin.HistoryControl.HistoryEvidence\nopen Singular Fixtures\n"
    )
    prefix += "local instance (priority := 10000) {α : Type} [DecidableEq α] (a : α) (xs : List α) : Decidable (a ∈ xs) := memberDecidable a xs\n"
    finite = "all_goals first | (unfold FiniteEncoding; decide) | (unfold FiniteCollisionFree; decide)"
    duplicated = """
theorem control_duplicate_history : CandidateReachable hash code commit release duplicated := by
  exact .fold booked_reachable duplicate duplicate_ledger (by decide) (by decide) rfl rfl
theorem control_foreign_burn_history : CandidateReachable hash code commit release foreignBurned := by
  exact .fold booked_reachable foreignBurn foreign_burn_ledger (by decide) (by decide) rfl rfl
"""
    pairs = [
        supply_instance(
            "supply", "duplicated", "duplicate.after", 8, "control_duplicate_history"
        )
    ]
    pairs.append(
        instance(
            "one_live",
            "one_live_token",
            "duplicated, duplicate.after, 8",
            "HistoryPremises hash code commit release duplicated duplicate.after 8",
            "by refine ⟨control_duplicate_history, by decide, ?_, ?_⟩; " + finite,
            "liveActiveCount hash code duplicate.after.identity 8 duplicated.unspent ≤ 1",
            "by unfold control_claim_one_live; decide",
            "by unfold control_claim_one_live; decide",
        )
    )
    pairs.append(
        instance(
            "burn",
            "burn_only_terminating_fold",
            "booked, foreignBurned, foreignBurn.assets, some foreignBurn, registerFirst.after, 8",
            """HistoryTransaction hash code commit release booked foreignBurned foreignBurn.assets (some foreignBurn) ∧
  HistoryPremises hash code commit release booked registerFirst.after 8 ∧
  FiniteEncoding code (foreignBurned.domain ++ [.active registerFirst.after.identity 8]) ∧
  FiniteCollisionFree hash code (foreignBurned.domain ++ [.active registerFirst.after.identity 8]) ∧
  NoPin.mintQty foreignBurn.assets (activeAsset hash code registerFirst.after.identity 8) < 0""",
            """by
  refine ⟨⟨booked_reachable, rfl, ⟨booked_reachable, foreign_burn_ledger, by decide, by decide, rfl, rfl⟩⟩,
    active_history_premise, ?_, ?_, by decide⟩
  """
            + finite,
            """∃ o, some foreignBurn = some o ∧ registerFirst.after.identity = o.before.identity ∧
  (∃ reference, Change.terminate reference 8 ∈ o.changes) ∧ trieGet o.after.trie 8 = .known .terminal""",
            """by
  rintro ⟨o, equal, _, ⟨reference, member⟩, _⟩
  have same : foreignBurn = o := Option.some.inj equal
  subst o
  change Change.terminate reference 8 ∈ [Change.terminate pending.reference 7] at member
  simpa using member""",
            """by
  refine ⟨foreignBurn, rfl, rfl, ⟨pending.reference, ?_⟩, ?_⟩ <;> decide""",
        )
    )
    remint = """
theorem control_remint_history : CandidateReachable hash code commit release reminted := by
  exact .fold terminated_reachable remint remint_ledger (by decide) (by decide) rfl rfl
"""
    permanent = instance(
        "permanence",
        "no_remint_after_terminal",
        "terminated, reminted, remint, terminate.after, 7",
        """HistoryFoldPremises hash code commit release terminated reminted remint ∧
  HistoryPremises hash code commit release terminated terminate.after 7 ∧
  FiniteEncoding code (reminted.domain ++ [.active terminate.after.identity 7]) ∧
  FiniteCollisionFree hash code (reminted.domain ++ [.active terminate.after.identity 7]) ∧
  trieGet terminate.after.trie 7 = .known .terminal""",
        """by
  refine ⟨⟨terminated_reachable, remint_ledger, by decide, by decide, rfl, rfl⟩,
    terminal_history_premise, ?_, ?_, by decide⟩
  """
        + finite,
        """NoPin.mintQty remint.assets (activeAsset hash code terminate.after.identity 7) ≤ 0 ∧
  ∀ successor ∈ reminted.registries, successor.identity = terminate.after.identity →
    trieGet successor.trie 7 = .known .terminal""",
        """by
  intro claim
  have impossible : ¬ (NoPin.mintQty remint.assets (activeAsset hash code terminate.after.identity 7) ≤ 0) := by decide
  exact impossible claim.1""",
        "by constructor <;> decide",
    )
    removal = """
def control_removal_view : NoPin.TxView := ⟨[active8.reference], [], MINT, []⟩
def control_removed : CandidateWorld := successor booked booked.registries booked.domain control_removal_view []
theorem control_removal_ledger : LedgerObservationCorrespondence booked control_removed control_removal_view
    [active8] [] 0 0 := by constructor <;> decide
theorem control_removal_history : CandidateReachable hash code commit release control_removed := by
  exact .neutral booked_reachable control_removal_view [active8] [] 0 0 control_removal_ledger
    (by decide) (by decide) rfl rfl
"""
    removed = supply_instance(
        "premise_supply",
        "control_removed",
        "registerFirst.after",
        8,
        "control_removal_history",
    )
    mutations = [
        (
            "whole-policy-guard",
            "Core",
            "applyGuard mutation .foldWholePolicy (wholePolicyDelta hash code observation)",
            "applyGuard (if observation.before.state.reference.tx == 102 && observation.assets.mint.length == 3 then .flip .foldWholePolicy else mutation) .foldWholePolicy (wholePolicyDelta hash code observation)",
            duplicated,
            pairs,
            "foldWholePolicy",
        ),
        (
            "terminal-leaf-guard",
            "Core",
            "applyGuard mutation .changeLeaf (trieGet trie key == .unknown)",
            "applyGuard (if trieGet trie key == .known .terminal then .flip .changeLeaf else mutation) .changeLeaf (trieGet trie key == .unknown)",
            remint,
            [permanent],
            "changeLeaf",
        ),
        (
            "neutral-own-mint-premise",
            "History",
            "(noOwnMint : policyDelta view release.statePolicy [] = true)",
            "(noOwnMint : True)",
            removal.replace("MINT", "[(activeAsset hash code first.identity 8, -1)]"),
            [removed],
            "noOwnMint",
        ),
        (
            "asset-conservation-premise",
            "History",
            "assetsConserved : tokenConserved before.unspent after.unspent view = true",
            "assetsConserved : True",
            removal.replace("MINT", "[]"),
            [removed],
            "assetsConserved",
        ),
    ]
    axiom_check = """
end NoPin.HistoryControl.HistoryEvidence
open Lean Elab Command in
elab "#control_axioms" : command => do
  for (name, info) in (← getEnv).constants.toList do
    if name.toString.startsWith "NoPin.HistoryControl.HistoryEvidence." then
      if let .thmInfo _ := info then
        let axioms ← collectAxioms name
        unless axioms.all (fun a => a == `propext || a == `Classical.choice || a == `Quot.sound) do
          throwError "unproved history counterexample: {name}"
#control_axioms
"""
    results = []
    evidence = Path(
        tempfile.mkdtemp(prefix="history-control-evidence-", dir=ROOT / ".lake")
    )
    with tempfile.TemporaryDirectory(
        prefix="history-controls-", dir=ROOT / ".lake"
    ) as temporary:
        for label, module, needle, replacement, extra, bindings, selector in mutations:
            current = dict(sources)
            if current[module].count(needle) != 1:
                raise ValueError("source substitution not unique: " + label)
            current[module] = current[module].replace(needle, replacement, 1)
            if needle in current[module] or current[module].count(replacement) != 1:
                raise ValueError("source substitution did not apply: " + label)
            text = "import NoPin.ApplicationRequests.HistoryEvidence\nimport NoPin.ApplicationRequests.HistoryBindings\n"
            for name in MODULES:
                text += (
                    "\n"
                    + re.sub(r"^import .*$", "", current[name], flags=re.M).replace(
                        "NoPin.ApplicationRequests", NS
                    )
                    + "\n"
                )
            text += (
                prefix + extra + "\n" + "\n".join(p[0] for p in bindings) + axiom_check
            )
            target = Path(temporary) / (label + ".lean")
            target.write_text(text)
            command = [
                "timeout",
                "180",
                "lake",
                "-d",
                str(ROOT),
                "--keep-toolchain",
                "env",
                "lean",
                str(target),
            ]
            certificate = subprocess.run(command, capture_output=True, text=True)
            output = certificate.stdout + certificate.stderr
            log = evidence / (label + "-certificate.log")
            log.write_text(output)
            if certificate.returncode != 0:
                raise ValueError(
                    "counterexample certificate failed: "
                    + label
                    + "\n"
                    + output[-7000:]
                )
            assertions = "\nnamespace NoPin.HistoryControl.HistoryEvidence\nopen Singular Fixtures\n"
            assertions += "local instance (priority := 10000) {α : Type} [DecidableEq α] (a : α) (xs : List α) : Decidable (a ∈ xs) := memberDecidable a xs\n"
            assertions += (
                "\n".join(p[1] for p in bindings)
                + "\nend NoPin.HistoryControl.HistoryEvidence\n"
            )
            target.write_text(text + assertions)
            rejected = subprocess.run(command, capture_output=True, text=True)
            output = rejected.stdout + rejected.stderr
            failure_log = evidence / (label + "-red.log")
            failure_log.write_text(output)
            lines = (text + assertions).splitlines()
            failed = set()
            errors = list(re.finditer(r":(\d+):\d+: error:", output))
            for error in errors:
                declarations = re.findall(
                    r"^theorem (obligation_\w+)",
                    "\n".join(lines[: int(error[1])]),
                    re.M,
                )
                if not declarations:
                    raise ValueError("setup failure in negative run: " + label)
                failed.add(declarations[-1])
            expected = {
                re.search(r"theorem (obligation_\w+)", pair[1])[1] for pair in bindings
            }
            if (
                rejected.returncode != 1
                or failed != expected
                or "proved that the proposition" not in output
            ):
                raise ValueError(
                    "wrong negative result: " + label + "\n" + output[-7000:]
                )
            results.append(
                {
                    "control": label,
                    "selector": selector,
                    "siteCount": 1,
                    "sourceModule": module,
                    "needle": needle,
                    "replacement": replacement,
                    "sourceSha256": hashlib.sha256(
                        sources[module].encode()
                    ).hexdigest(),
                    "mutatedSha256": hashlib.sha256(
                        current[module].encode()
                    ).hexdigest(),
                    "certificateExit": certificate.returncode,
                    "rejectedClaimExit": rejected.returncode,
                    "failedObligations": sorted(failed),
                    "certificateLog": str(log),
                    "redLog": str(failure_log),
                    "certificateSha256": hashlib.sha256(log.read_bytes()).hexdigest(),
                    "redSha256": hashlib.sha256(failure_log.read_bytes()).hexdigest(),
                }
            )
    print(
        json.dumps(
            {
                "status": "CANDIDATE-HISTORY-CONTROLS",
                "acceptedLaw": False,
                "controls": results,
                "directSubprocesses": 2 * len(results),
            }
        )
    )


if __name__ == "__main__":
    main()
