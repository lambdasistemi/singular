"""Compare separately built and merged validators with declared identity changes."""

import argparse
import copy
import json
from pathlib import Path


def read(path):
    return json.loads(Path(path).read_text())


def entries(document):
    rows = document["validators"]
    if not rows:
        raise ValueError("zero validators")
    titles = [row["title"] for row in rows]
    if len(set(titles)) != len(titles):
        raise ValueError("duplicate validator titles")
    normalized = [".".join(title.split(".")[-2:]) for title in titles]
    if len(set(normalized)) != len(titles):
        raise ValueError("ambiguous normalized titles (collision)")
    return {row["title"]: row["hash"] for row in rows}


def equal(expected, actual, label):
    problems = []
    for title in sorted(expected.keys() | actual.keys()):
        if title not in expected:
            problems.append(f"{title}: undeclared validator in {label}")
        elif title not in actual:
            problems.append(f"{title}: missing from {label}")
        elif expected[title] != actual[title]:
            problems.append(
                f"{title}: moved in {label}: expected {expected[title]}, got {actual[title]}"
            )
    if problems:
        raise ValueError("\n".join(problems))


def expected_from_records(base, records, manifests, built):
    original = entries(base)
    active = dict(original)
    introduced = set(original)
    changed = set()
    for record in records:
        if not isinstance(record, dict) or set(record) != {
            "added",
            "changed",
            "removed",
        }:
            raise ValueError(
                "record must contain exactly added, changed and removed lists"
            )
        seen = set()
        for kind in ("changed", "added", "removed"):
            titles = record[kind]
            if not isinstance(titles, list) or any(
                not isinstance(t, str) or not t for t in titles
            ):
                raise ValueError(f"{kind} must be a list of nonempty titles")
            if len(set(titles)) != len(titles):
                raise ValueError(f"{kind}: declared more than once")
            overlap = seen.intersection(titles)
            if overlap:
                raise ValueError(f"{sorted(overlap)}: declared in both lists")
            seen.update(titles)
        for title in record["changed"]:
            if title not in active:
                raise ValueError(
                    f"{title}: changed before introduction or after removal"
                )
            changed.add(title)
            active[title] = None
        for title in record["added"]:
            if title in introduced:
                raise ValueError(
                    f"{title}: added more than once or equals a base title"
                )
            introduced.add(title)
            active[title] = None
        for title in record["removed"]:
            if title not in active:
                raise ValueError(
                    f"{title}: removed before introduction or removed twice"
                )
            del active[title]
    if not active:
        raise ValueError("declarations leave zero validators")
    for title, value in active.items():
        if value is None:
            if title not in manifests:
                raise ValueError(f"{title}: no hash in the manifests")
            active[title] = manifests[title]
        if (
            title in changed
            and title in original
            and built.get(title) == original[title]
        ):
            raise ValueError(f"{title}: changed title is over-declared")
    return active


def verify(
    base, records, registry, application, registry_manifest, app_manifest, merged
):
    for blueprint in (registry, application, merged):
        if blueprint["preamble"]["compiler"]["version"] != base["compiler"]:
            raise ValueError("compiler moved")
    for blueprint, manifest in (
        (registry, registry_manifest),
        (application, app_manifest),
    ):
        if manifest["compiler"] != base["compiler"]:
            raise ValueError("manifest compiler moved")
        equal(entries(manifest), entries(blueprint), "manifest comparison")
    union = {"validators": registry["validators"] + application["validators"]}
    actual = entries(union)
    manifests = entries(
        {"validators": registry_manifest["validators"] + app_manifest["validators"]}
    )
    expected = expected_from_records(base, records, manifests, actual)
    equal(expected, actual, "separate builds")
    equal(expected, entries(merged), "merged blueprint")
    codes = {row["title"]: row["compiledCode"] for row in union["validators"]}
    merged_codes = {row["title"]: row["compiledCode"] for row in merged["validators"]}
    equal(codes, merged_codes, "merged compiledCode")
    return actual


def controls(inputs):
    base, records, registry, application, registry_manifest, app_manifest, merged = (
        inputs
    )
    current = verify(*inputs)
    if len(current) < 2:
        raise ValueError("controls require more than one retained entry")
    count = 0

    def refuse(name, mutate, reason):
        nonlocal count
        planted = copy.deepcopy(inputs)
        mutate(planted)
        try:
            verify(*planted)
        except ValueError as error:
            if reason not in str(error):
                raise ValueError(f"{name}: wrong refusal: {error}") from error
            print(f"control refused: {name}: {error}")
            count += 1
        else:
            raise ValueError(f"control missed: {name}")

    for index in (2, 3):
        for ordinal, row in enumerate(inputs[index]["validators"]):
            title = row["title"]

            def moved(xs, i=index, n=ordinal):
                before = xs[i]["validators"][n]["hash"]
                after = ("0" if before[0] != "0" else "1") + before[1:]
                xs[i]["validators"][n]["hash"] = after
                assert before != after

            refuse(f"moved {title}", moved, title)

    def changed_pair(xs):
        title = xs[2]["validators"][0]["title"]
        before = xs[2]["validators"][0]["hash"]
        after = ("0" if before[0] != "0" else "1") + before[1:]
        xs[2]["validators"][0]["hash"] = after
        for row in xs[4]["validators"]:
            if row["title"] == title:
                row["hash"] = after
        assert before != after

    refuse("build and manifest moved together", changed_pair, "moved")
    refuse("missing validator", lambda xs: xs[2]["validators"].pop(), "missing")
    refuse(
        "duplicate title",
        lambda xs: xs[2]["validators"].append(copy.deepcopy(xs[2]["validators"][0])),
        "duplicate",
    )

    def collision(xs):
        row = copy.deepcopy(xs[2]["validators"][0])
        row["title"] = "alternate." + ".".join(row["title"].split(".")[-2:])
        xs[2]["validators"].append(row)

    refuse("normalized collision", collision, "collision")
    refuse("empty blueprint", lambda xs: xs[2].update(validators=[]), "zero validators")
    refuse(
        "moved manifest",
        lambda xs: xs[4]["validators"][0].update(hash="0" * 56),
        "moved",
    )
    refuse(
        "merged hash", lambda xs: xs[6]["validators"][0].update(hash="0" * 56), "moved"
    )
    refuse(
        "merged bytes",
        lambda xs: xs[6]["validators"][0].update(compiledCode="00"),
        "compiledCode",
    )
    refuse(
        "compiler",
        lambda xs: xs[2]["preamble"]["compiler"].update(version="other"),
        "compiler",
    )
    title = next(iter(current))
    empty = {"added": [], "changed": [], "removed": []}
    for name, kind, value, reason in (
        ("unknown removal", "removed", ["unknown.unknown.mint"], "removed before"),
        ("duplicate removal", "removed", [title, title], "declared more than once"),
        ("unknown change", "changed", ["unknown.unknown.mint"], "changed before"),
        ("over-declared change", "changed", [title], "over-declared"),
        ("base added again", "added", [title], "equals a base"),
        ("undeclared addition", "added", ["unknown.unknown.mint"], "no hash"),
    ):
        record = {**empty, kind: value}
        refuse(name, lambda xs, r=record: xs[1].append(r), reason)
    removed = next(t for r in records for t in r["removed"])
    refuse(
        "removed twice",
        lambda xs: xs[1].append({**empty, "removed": [removed]}),
        "removed twice",
    )
    refuse("removed validator retained", lambda xs: xs[1].clear(), "missing")
    refuse(
        "conflicting lists",
        lambda xs: xs[1].append({**empty, "changed": [title], "removed": [title]}),
        "both lists",
    )
    print(f"script-hash-comparison: {count} negative controls refused")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in (
        "base",
        "registry",
        "application",
        "registry-manifest",
        "application-manifest",
        "merged",
    ):
        parser.add_argument("--" + name, required=True, type=Path)
    parser.add_argument("--record", required=True, action="append", type=Path)
    args = parser.parse_args()
    inputs = (
        read(args.base),
        [read(p) for p in args.record],
        read(args.registry),
        read(args.application),
        read(args.registry_manifest),
        read(args.application_manifest),
        read(args.merged),
    )
    try:
        actual = verify(*inputs)
        for title, value in sorted(actual.items()):
            print(f"{title} {value}")
        controls(inputs)
    except (ValueError, KeyError, TypeError) as error:
        raise SystemExit(f"script-hash-comparison: FAIL: {error}") from error
    print(
        f"script-hash-comparison: OK — {len(actual)} retained entries, merged bytes identical"
    )


if __name__ == "__main__":
    main()
