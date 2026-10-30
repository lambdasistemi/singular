#!/usr/bin/env python3
"""Exercise the compatibility record check, including deliberate drift.

Each control alters one thing in a scratch copy of the release table, the packaged
blueprint, the rows or the page and requires the check to refuse it. The unaltered
copy is required to pass first, so a refusal is not a broken copy.

usage: compatibility-record.py ROOT BLUEPRINT
"""

import copy
import importlib.util
import json
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


def load(root):
    spec = importlib.util.spec_from_file_location(
        "compatibility_record", root / "tools" / "compatibility_record.py"
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main():
    root = Path(sys.argv[1]).resolve()
    real_blueprint = Path(sys.argv[2]).resolve()
    tool = load(root)
    controls = 0

    with tempfile.TemporaryDirectory(
        prefix="compatibility-record-control-"
    ) as directory:
        scratch = Path(directory)
        blueprint = scratch / "blueprint.json"

        def restore():
            for name in (tool.TABLE, tool.ROWS, tool.PAGE, tool.BUNDLE_RULES):
                target = scratch / name
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(root / name, target)
            shutil.copyfile(real_blueprint, blueprint)

        def table():
            return json.loads((scratch / tool.TABLE).read_text())

        def put_table(value):
            (scratch / tool.TABLE).write_text(json.dumps(value, indent=2) + "\n")

        def refuses(message):
            nonlocal controls
            try:
                tool.check(scratch, blueprint)
            except tool.Refusal as error:
                assert message in str(error), f"refused for another reason: {error}"
            else:
                raise AssertionError(f"the check accepted: {message}")
            controls += 1

        def named_releases(value):
            names = {r for row in value["rows"] for r in row["releases"]}
            names |= {
                r for row in value["applications"] for r in row["singular-releases"]
            }
            names |= {entry["release"] for entry in value["left-out"]}
            return sorted(names, key=tool.version)

        restore()
        passed = tool.check(scratch, blueprint)
        releases = named_releases(table())
        assert len(releases) > 1 and len(passed["releases"]) == len(releases)
        assert passed["this-release-contract"] is not None, (
            "the real record reads no release as this one"
        )

        # A release removed from the table, wherever the table names it: the rows
        # and the page still name it, and the check names it.
        for release in releases:
            value = table()
            for row in value["rows"]:
                row["releases"] = [r for r in row["releases"] if r != release]
            for row in value["applications"]:
                row["singular-releases"] = [
                    r for r in row["singular-releases"] if r != release
                ]
            value["left-out"] = [
                e for e in value["left-out"] if e["release"] != release
            ]
            put_table(value)
            refuses(f"the committed rows name {release} and the table does not")
            restore()

        # A release added to the table that the rows do not name.
        value = table()
        value["rows"][-2]["releases"].append("v99.0.0")
        put_table(value)
        refuses("the table names v99.0.0 and the committed rows do not")
        restore()

        # A table the rows were not generated from, with every release and
        # contract the same: any other byte of it is refused.
        value = table()
        value["note"] += " Edited."
        put_table(value)
        refuses("the committed rows were not generated from this release table")
        restore()

        # A contract moved from one release to another changes that release's row.
        value = table()
        value["rows"][1]["state-contract"] = "0" * 56
        put_table(value)
        refuses("differs from what the table gives")
        restore()

        # A row of the rows file edited: its contract, who serves it, the release
        # that serves it, and the reason a release has none.
        rows = json.loads((scratch / tool.ROWS).read_text())
        for index, row in enumerate(rows["releases"]):
            edits = []
            changed = copy.deepcopy(rows)
            changed["releases"][index]["state-contract"] = "f" * 56
            edits.append(changed)
            changed = copy.deepcopy(rows)
            kind = row["served-by"]["kind"]
            changed["releases"][index]["served-by"] = (
                {"kind": "no-release", "why": "edited"}
                if kind != "no-release"
                else {"kind": "this-release"}
            )
            edits.append(changed)
            if kind == "earlier-release":
                changed = copy.deepcopy(rows)
                changed["releases"][index]["served-by"]["release"] = "v99.0.0"
                edits.append(changed)
            for edit in edits:
                (scratch / tool.ROWS).write_text(json.dumps(edit, indent=2) + "\n")
                refuses(
                    f"the row of {row['release']} differs from what the table gives"
                )
        for key in ("contracts-without-release", "applications"):
            for index in range(len(rows[key])):
                changed = copy.deepcopy(rows)
                changed[key][index]["served-by"] = {"kind": "this-release"}
                if rows[key][index]["served-by"] == {"kind": "this-release"}:
                    changed[key][index]["served-by"] = {
                        "kind": "no-release",
                        "why": "edited",
                    }
                (scratch / tool.ROWS).write_text(json.dumps(changed, indent=2) + "\n")
                refuses("differs from what the table gives")
        restore()

        # The rows file with its own contract, table hash or blueprint policy edited.
        for key, edited, message in (
            ("this-release-contract", None, "name another contract for this release"),
            (
                "this-release-contract",
                "e" * 56,
                "name another contract for this release",
            ),
            (
                "packaged-application-policy",
                "e" * 56,
                "not generated from the packaged blueprint",
            ),
        ):
            changed = copy.deepcopy(rows)
            changed[key] = edited
            (scratch / tool.ROWS).write_text(json.dumps(changed, indent=2) + "\n")
            refuses(message)
        changed = copy.deepcopy(rows)
        changed["table"]["sha256"] = "0" * 64
        (scratch / tool.ROWS).write_text(json.dumps(changed, indent=2) + "\n")
        refuses("not generated from this release table")
        (scratch / tool.ROWS).write_text(json.dumps(rows))
        refuses("the committed rows differ from what the table gives")
        restore()

        # The page edited: every line of its tables in turn, and the prose around them.
        page = (scratch / tool.PAGE).read_text()
        lines = page.splitlines(keepends=True)
        for index, line in enumerate(lines):
            if line.startswith("| v") or (line.startswith("| `") and index > 20):
                (scratch / tool.PAGE).write_text(
                    "".join(lines[:index] + lines[index + 1 :])
                )
                refuses("the page differs from the rows it is rendered from")
        for index, line in enumerate(lines):
            if line.startswith("| v") and "this release" in line:
                changed = line.replace("this release", "no release is known")
            elif line.startswith("| v") and "no release is known" in line:
                changed = line.replace("no release is known", "this release")
            elif line.startswith("| v"):
                changed = re.sub(r"v\d+\.\d+\.\d+\]", "v0.0.1]", line, count=1)
            else:
                continue
            (scratch / tool.PAGE).write_text(
                "".join(lines[:index] + [changed] + lines[index + 1 :])
            )
            refuses("the page differs from the rows it is rendered from")
        (scratch / tool.PAGE).write_text(page + "\nA release is served by none.\n")
        refuses("the page differs from the rows it is rendered from")
        (scratch / tool.PAGE).unlink()
        refuses("the page is missing")
        restore()

        # The packaged blueprint: another application, no request validator, none.
        document = json.loads(blueprint.read_text())
        titled = [
            v for v in document["validators"] if v["title"] == tool.REQUEST_VALIDATOR
        ]
        assert len(titled) == 1
        titled[0]["hash"] = "0" * 56
        blueprint.write_text(json.dumps(document))
        refuses("differs from what the table gives")
        restore()
        document = json.loads(blueprint.read_text())
        document["validators"] = [
            v for v in document["validators"] if v["title"] != tool.REQUEST_VALIDATOR
        ]
        blueprint.write_text(json.dumps(document))
        refuses("carries 0 validators titled")
        restore()
        blueprint.unlink()
        refuses("the packaged blueprint is missing")
        restore()
        (scratch / tool.TABLE).unlink()
        refuses("the release table is missing")
        restore()

        # The release the table first appears in comes from the bundle rules and
        # nowhere else: the rules changed, the rows and the page changed to say
        # something else while the rules did not, and the rules missing or unclear.
        rules = (scratch / tool.BUNDLE_RULES).read_text()
        limit = tool.read_last_release_without_the_table(scratch)
        assert limit == "v0.15.0", f"the real limit is {limit}"
        (scratch / tool.BUNDLE_RULES).write_text(
            rules.replace(
                'LAST_WITHOUT_CONTRACT_TABLE="0.15.0"',
                'LAST_WITHOUT_CONTRACT_TABLE="0.14.0"',
            )
        )
        refuses("and tools/release_bundles.sh states v0.14.0")
        restore()
        changed = copy.deepcopy(rows)
        changed["last-release-without-the-table"] = "v0.14.0"
        (scratch / tool.ROWS).write_text(json.dumps(changed, indent=2) + "\n")
        (scratch / tool.PAGE).write_text(tool.render_page(changed))
        refuses("state v0.14.0 as the last release without the table")
        restore()
        for broken, message in (
            (rules + 'LAST_WITHOUT_CONTRACT_TABLE="0.1.0"\n', "states 2 limits"),
            (
                rules.replace("LAST_WITHOUT_CONTRACT_TABLE", "LAST_WITHOUT_TABLE"),
                "states 0 limits",
            ),
        ):
            (scratch / tool.BUNDLE_RULES).write_text(broken)
            refuses(message)
        restore()
        (scratch / tool.BUNDLE_RULES).unlink()
        refuses("the bundle rules is missing")
        restore()

        # The sentence about where the table comes from says what is true: it
        # names the limit and not "every release", and the untrue sentence is
        # refused wherever it comes back.
        page = (scratch / tool.PAGE).read_text()
        true_sentence = f"which the releases after {limit} carry"
        assert page.count(true_sentence) == 1, "the page does not state the limit"
        for untrue in (
            "that every release carries",
            "that every release since the first carries",
            f"which every release after {limit} carries, including {limit}",
        ):
            (scratch / tool.PAGE).write_text(page.replace(true_sentence, untrue))
            refuses("the page differs from the rows it is rendered from")
        (scratch / tool.PAGE).write_text(
            page.replace(
                f"The releases up to {limit} carry no table, so their commands cannot name a serving release. ",
                "",
            )
        )
        refuses("the page differs from the rows it is rendered from")
        restore()
        assert "every release" not in tool.render_page(rows).lower().replace(
            "for every release in", ""
        ), "the page says every release again"
        controls += 1

        # An applied state policy that names the packaged application twice: the
        # record cannot tell which one the commands derive, and says so.
        value = table()
        twin = copy.deepcopy(value["applications"][0])
        twin["state-policy"] = "d" * 56
        twin["singular-releases"] = []
        twin["application-releases"] = []
        value["applications"].append(twin)
        put_table(value)
        refuses("several applied state policies name the packaged application")
        restore()

        # No applied state policy for the packaged application: nothing reads as
        # this release, and the committed rows no longer agree.
        value = table()
        value["applications"] = []
        put_table(value)
        refuses("the committed rows name v0.17.0 and the table does not")
        restore()

        # The record does not depend on the version: a scratch copy whose version
        # and changelog heading are bumped, as the release pull request does,
        # passes with the same rows.
        (scratch / "version.txt").write_text("99.0.0\n")
        (scratch / "CHANGELOG.md").write_text(
            "# Changelog\n\n## [99.0.0](https://example.invalid/compare/v98.0.0...v99.0.0)\n"
        )
        again = tool.check(scratch, blueprint)
        assert again == passed, "bumping the version changed the record"
        controls += 1
        restore()

        # The command itself fails on an altered page, and on a missing blueprint.
        (scratch / tool.PAGE).write_text(page.replace("# Which", "# Whose", 1))
        for arguments in (
            ["--check", "--root", str(scratch), "--blueprint", str(blueprint)],
        ):
            result = subprocess.run(
                [
                    sys.executable,
                    str(root / "tools" / "compatibility_record.py"),
                    *arguments,
                ],
                text=True,
                capture_output=True,
                check=False,
            )
            assert result.returncode == 1 and "differs" in result.stderr, (
                f"the command accepted an altered page: {result}"
            )
            controls += 1
        restore()
        result = subprocess.run(
            [
                sys.executable,
                str(root / "tools" / "compatibility_record.py"),
                "--check",
                "--root",
                str(scratch),
                "--blueprint",
                str(scratch / "absent.json"),
            ],
            text=True,
            capture_output=True,
            check=False,
        )
        assert (
            result.returncode == 1
            and "the packaged blueprint is missing" in result.stderr
        ), f"the command accepted a missing blueprint: {result}"
        controls += 1
    print(
        f"compatibility record: the committed rows and page match the table and the "
        f"packaged blueprint; {controls} removed releases, edited rows, edited pages and "
        "missing sources refused, and a bumped version leaves the record unchanged"
    )


if __name__ == "__main__":
    main()
