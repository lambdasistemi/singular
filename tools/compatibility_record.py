#!/usr/bin/env python3
"""Render the compatibility record from the packaged release table.

Obligation: the check and the controls are run by docs-check in the documentation
job. Every row of the record is computed from the packaged release table and from
the packaged deployment blueprint, never typed. The rows are kept in one file the
page is rendered from and the off-chain tests read, so the page and the library's
serving answer are compared on the same rows.

The record names no release of its own: the package's own contract is the applied
state policy of the table row whose application policy is the request validator of
the packaged blueprint, so the record stays valid when the release pull request
changes the version.
"""

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path

TABLE = "offchain/data/contracts/state-contracts.json"
ROWS = "docs/compatibility.rows.json"
PAGE = "docs/compatibility.md"
REQUEST_VALIDATOR = "open_datum_requests.open_datum_requests.spend"
RELEASE_PAGE = "https://github.com/lambdasistemi/singular/releases/tag/"
BUNDLE_RULES = "tools/release_bundles.sh"
WITHOUT_TABLE = re.compile(r'^LAST_WITHOUT_CONTRACT_TABLE="(\d+\.\d+\.\d+)"$', re.M)
HASH = re.compile(r"[0-9a-f]{56}")
TAG = re.compile(r"v(\d+)\.(\d+)\.(\d+)")


class Refusal(Exception):
    """The table, the blueprint, the rows or the page do not meet the rule."""


def require(condition, message):
    if not condition:
        raise Refusal(message)


def version(tag):
    found = TAG.fullmatch(tag)
    require(found, f"{tag} is not a release tag of the form v1.2.3")
    return tuple(int(part) for part in found.groups())


def read_file(path, what):
    path = Path(path)
    require(path.is_file(), f"{what} is missing: {path}")
    return path.read_bytes()


def read_table(root):
    raw = read_file(Path(root) / TABLE, "the release table")
    try:
        table = json.loads(raw)
    except ValueError as error:
        raise Refusal(f"the release table is not JSON: {error}")
    for key in ("rows", "applications", "left-out"):
        require(isinstance(table.get(key), list), f"the release table has no {key}")
    return raw, table


def read_last_release_without_the_table(root):
    """The last release whose bundles carry no release table, as the bundle rules state it."""
    raw = read_file(Path(root) / BUNDLE_RULES, "the bundle rules").decode()
    found = WITHOUT_TABLE.findall(raw)
    require(
        len(found) == 1,
        f"{BUNDLE_RULES} states {len(found)} limits LAST_WITHOUT_CONTRACT_TABLE, not one",
    )
    return "v" + found[0]


def read_packaged_policy(blueprint):
    """The policy of the request validator the packaged blueprint carries."""
    raw = read_file(blueprint, "the packaged blueprint")
    try:
        document = json.loads(raw)
    except ValueError as error:
        raise Refusal(f"the packaged blueprint is not JSON: {error}")
    found = [
        validator
        for validator in document.get("validators", [])
        if validator.get("title") == REQUEST_VALIDATOR
    ]
    require(
        len(found) == 1,
        f"the packaged blueprint carries {len(found)} validators titled {REQUEST_VALIDATOR}, not one",
    )
    policy = found[0].get("hash", "")
    require(
        HASH.fullmatch(policy),
        "the request validator of the packaged blueprint has no hash",
    )
    return policy


def this_release_contract(table, packaged_policy):
    """The applied state policy the commands of this package derive, or None.

    The commands apply the packaged state program to the request validator of the
    packaged blueprint. The row that names that validator as its application is
    the one they derive; the off-chain tests recompute its state policy with the
    library's own derivation.
    """
    named = [
        row
        for row in table["applications"]
        if row["application-policy"] == packaged_policy
    ]
    require(
        len(named) <= 1,
        "several applied state policies name the packaged application; the record "
        "cannot tell which one the commands derive",
    )
    return named[0]["state-policy"] if named else None


def served_by(table, own, contract):
    """Who serves a registry of this contract: the library's answer, in three kinds.

    The answer of the library for an installed release that is not itself one of
    the releases a row names; the off-chain tests show it is the same whatever the
    installed release is.
    """
    if contract == own:
        return {"kind": "this-release"}
    for row in table["applications"]:
        if row["state-policy"] == contract:
            return earlier(row["singular-releases"])
    for row in table["rows"]:
        if row["state-contract"] == contract:
            return earlier(row["releases"])
    return {"kind": "no-release", "why": "no row holds the contract"}


def earlier(releases):
    if not releases:
        return {"kind": "no-release", "why": "the contract is not released yet"}
    return {"kind": "earlier-release", "release": releases[-1]}


def compute_rows(root, blueprint):
    raw, table = read_table(root)
    packaged = read_packaged_policy(blueprint)
    own = this_release_contract(table, packaged)
    without_table = read_last_release_without_the_table(root)
    carried = {}
    for row in table["rows"]:
        for release in row["releases"]:
            carried.setdefault(release, []).append(row["state-contract"])
    for row in table["applications"]:
        for release in row["singular-releases"]:
            carried.setdefault(release, []).append(row["state-policy"])
    for entry in table["left-out"]:
        carried.setdefault(entry["release"], [])
    for release, contracts in carried.items():
        require(len(contracts) <= 1, f"the release {release} is in more than one row")
    releases = []
    for release in sorted(carried, key=version):
        if carried[release]:
            contract = carried[release][0]
            releases.append(
                {
                    "release": release,
                    "state-contract": contract,
                    "served-by": served_by(table, own, contract),
                }
            )
        else:
            why = next(
                e["reason"] for e in table["left-out"] if e["release"] == release
            )
            releases.append(
                {
                    "release": release,
                    "state-contract": None,
                    "served-by": {"kind": "no-release", "why": why},
                }
            )
    return {
        "table": {"file": TABLE, "sha256": hashlib.sha256(raw).hexdigest()},
        "last-release-without-the-table": without_table,
        "packaged-application-policy": packaged,
        "this-release-contract": own,
        "releases": releases,
        "contracts-without-release": [
            {
                "state-contract": row["state-contract"],
                "served-by": served_by(table, own, row["state-contract"]),
            }
            for row in table["rows"]
            if not row["releases"]
        ],
        "applications": [
            {
                "state-policy": row["state-policy"],
                "application-policy": row["application-policy"],
                "singular-releases": row["singular-releases"],
                "application-releases": row["application-releases"],
                "served-by": served_by(table, own, row["state-policy"]),
            }
            for row in table["applications"]
        ],
    }


def render_rows(rows):
    return json.dumps(rows, indent=2) + "\n"


def release_link(release):
    return f"[{release}]({RELEASE_PAGE}{release})"


def served_cell(served):
    if served["kind"] == "this-release":
        return "this release"
    if served["kind"] == "earlier-release":
        return f"the release {release_link(served['release'])}"
    return "no release is known"


def contract_cell(contract):
    return f"`{contract}`" if contract else "not recorded"


def plural(number, word):
    return f"{number} {word}" + ("" if number == 1 else "s")


def render_page(rows):
    releases = rows["releases"]
    own = rows["this-release-contract"]
    contracts = {r["state-contract"] for r in releases if r["state-contract"]}
    contracts |= {r["state-contract"] for r in rows["contracts-without-release"]}
    here = [r["release"] for r in releases if r["served-by"]["kind"] == "this-release"]
    if own:
        derived = (
            "The commands of this release derive their state contract from the blueprint "
            "they carry. The request validator of that blueprint has an application "
            "policy, and the release table holds the applied state policy for it. That "
            "applied state policy is the contract these commands derive, and it is the "
            "state contract of every row marked as this release."
        )
    else:
        derived = (
            "The release table holds no applied state policy for the application policy "
            "of the blueprint this release carries yet, so no row below reads this "
            "release. The row for this release is added to the table after the release "
            "is published."
        )
    lines = [
        "# Which release serves my registry",
        "",
        "As a person with a registry made by some earlier release, you find on this page "
        "which release serves it: this release, an earlier one, or none that is known.",
        "",
        "```mermaid",
        "flowchart TB",
        "    registry[Your registry's state contract] --> derived{The contract these commands derive from their blueprint?}",
        "    derived -->|yes| here[This release serves it]",
        "    derived -->|no| held{A release in the table carries it?}",
        "    held -->|yes| earlier[The newest such release serves it]",
        "    held -->|no| none[No release is known]",
        "```",
        "",
        "The diagram shows the question the rows below answer. A registry is made by "
        "one version of the on-chain code, and its state contract is the hash of that "
        "version's state validator. The commands of this release change the registries "
        "of one state contract, the one they derive from the blueprint they carry. "
        "Given a registry of another contract, a command of this release that changes "
        "it refuses before anything is built and names the release that serves it, or "
        "says that no release is known.",
        "",
        "## How the answer is found",
        "",
        derived,
        "",
        f"Every row is computed from the release table, which the releases after "
        f"{rows['last-release-without-the-table']} carry, and from the blueprint this "
        f"release carries. The releases up to {rows['last-release-without-the-table']} "
        "carry no table, so their commands cannot name a serving release. Registries "
        "made by a release whose contract is recorded are served by the newest "
        "release in the table that carries that contract, unless the contract is the "
        "one these commands derive, which this release serves. A contract that the "
        "table holds with no release has no release that serves it. The record names "
        "no version of its own, so it needs no edit when the version changes.",
        "",
        "| Where the rows come from | Value |",
        "|---|---|",
        f"| The release table, `{rows['table']['file']}`, SHA-256 | `{rows['table']['sha256']}` |",
        f"| Application policy of the request validator in the blueprint this release carries | `{rows['packaged-application-policy']}` |",
        f"| State contract these commands derive | {contract_cell(own) if own else 'not in the table yet'} |",
        "",
        "The commands of this release print the same answer. The off-chain test suite "
        "compares each row that has a contract with the answer of the library "
        "function these commands call, and the documentation check refuses a page "
        "that differs from the table.",
        "",
        "## Release by release",
        "",
        f"The table names {plural(len(releases), 'release')} and "
        f"{plural(len(contracts), 'state contract')}. Each release has one row, "
        "oldest first. A release the table leaves out is listed with its reason: "
        "its contract is not recorded, so no release is known to serve its registries.",
        "",
        "| Release | State contract | Registries made by it are served by |",
        "|---|---|---|",
    ]
    for row in releases:
        cell = contract_cell(row["state-contract"])
        if row["state-contract"] is None:
            cell += f": {row['served-by']['why']}"
        lines.append(f"| {row['release']} | {cell} | {served_cell(row['served-by'])} |")
    lines += [
        "",
        f"This release serves the registries of {plural(len(here), 'release')} listed "
        "above."
        if here
        else "No release listed above is read as this release.",
        "",
        "## Contracts with no release",
        "",
    ]
    if rows["contracts-without-release"]:
        lines += [
            "The table also holds state contracts that no release carries. A registry "
            "of one of them was made by code that no release in the table carries, and "
            "no release is known to serve it.",
            "",
            "| State contract | Registries made by it are served by |",
            "|---|---|",
        ]
        for row in rows["contracts-without-release"]:
            lines.append(
                f"| `{row['state-contract']}` | {served_cell(row['served-by'])} |"
            )
    else:
        lines.append("The table holds no state contract without a release.")
    lines += [
        "",
        "## Applications",
        "",
        "A registry made for an application has a state policy that applies the state "
        "program to the application's policy. The table holds one row for each, with "
        "the Singular releases and the application releases that carry it.",
        "",
        "| Applied state policy | Application policy | Singular releases | Application releases | Registries made by it are served by |",
        "|---|---|---|---|---|",
    ]
    for row in rows["applications"]:
        lines.append(
            f"| `{row['state-policy']}` | `{row['application-policy']}` | "
            f"{', '.join(row['singular-releases']) or 'none'} | "
            f"{', '.join(row['application-releases']) or 'none'} | "
            f"{served_cell(row['served-by'])} |"
        )
    lines += [
        "",
        "## Regenerate this page",
        "",
        "Build the packaged blueprint with "
        "`nix build ./applications/open-datum/onchain#open-datum-blueprint -o blueprint`, "
        "run `python3 tools/compatibility_record.py --write --blueprint blueprint` to "
        "regenerate the page and its rows, then regenerate its speech and changed "
        "narration. The documentation check runs "
        "`python3 tools/compatibility_record.py --check` with the packaged blueprint.",
        "",
    ]
    return "\n".join(lines)


def differences(expected, found, key, what):
    """Name the first way two lists of rows differ, by release or contract."""
    expected_keys = [row.get(key) for row in expected]
    found_keys = [row.get(key) for row in found]
    for name in expected_keys:
        require(
            name in found_keys,
            f"{what}: the table names {name} and the committed rows do not",
        )
    for name in found_keys:
        require(
            name in expected_keys,
            f"{what}: the committed rows name {name} and the table does not",
        )
    for left, right in zip(expected, found):
        require(
            left == right,
            f"{what}: the row of {left.get(key)} differs from what the table gives",
        )


def check(root, blueprint):
    root = Path(root)
    computed = compute_rows(root, blueprint)
    committed_raw = read_file(root / ROWS, "the committed rows")
    try:
        committed = json.loads(committed_raw)
    except ValueError as error:
        raise Refusal(f"the committed rows are not JSON: {error}")
    stated = committed.get("last-release-without-the-table")
    require(
        stated == computed["last-release-without-the-table"],
        f"the committed rows state {stated} as the last release without the table, "
        f"and {BUNDLE_RULES} states {computed['last-release-without-the-table']}",
    )
    differences(
        computed["releases"], committed.get("releases", []), "release", "releases"
    )
    differences(
        computed["contracts-without-release"],
        committed.get("contracts-without-release", []),
        "state-contract",
        "contracts without a release",
    )
    differences(
        computed["applications"],
        committed.get("applications", []),
        "state-policy",
        "applications",
    )
    require(
        committed.get("table", {}).get("sha256") == computed["table"]["sha256"],
        "the committed rows were not generated from this release table",
    )
    require(
        committed.get("packaged-application-policy")
        == computed["packaged-application-policy"],
        "the committed rows were not generated from the packaged blueprint",
    )
    require(
        committed.get("this-release-contract") == computed["this-release-contract"],
        "the committed rows name another contract for this release than the packaged blueprint gives",
    )
    require(
        committed_raw.decode() == render_rows(computed),
        "the committed rows differ from what the table gives",
    )
    page = read_file(root / PAGE, "the page").decode()
    require(
        page == render_page(committed),
        "the page differs from the rows it is rendered from",
    )
    return computed


def write(root, blueprint):
    root = Path(root)
    rows = compute_rows(root, blueprint)
    (root / ROWS).write_text(render_rows(rows))
    (root / PAGE).write_text(render_page(rows))
    return rows


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--check", action="store_true")
    mode.add_argument("--write", action="store_true")
    parser.add_argument("--root", default=".")
    parser.add_argument("--blueprint", required=True)
    arguments = parser.parse_args(argv)
    try:
        rows = (write if arguments.write else check)(
            arguments.root, arguments.blueprint
        )
    except Refusal as refusal:
        print(f"compatibility record: {refusal}", file=sys.stderr)
        return 1
    here = sum(1 for r in rows["releases"] if r["served-by"]["kind"] == "this-release")
    print(
        f"compatibility record: {len(rows['releases'])} releases, "
        f"{len(rows['applications'])} applications, {here} read as this release"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
