"""Every build the release verifier runs is rooted (#659).

tools/verify_release.sh builds the archive's executables and runs them until
the journey ends. A build that leaves no link (`nix build --no-link`) returns
a store path nothing holds alive, and a collection between the build and the
last use removes it: the hosted journey failed with the program missing six
minutes after its version was read. Every `nix build` the verifier runs
therefore carries `--out-link`, and none carries `--no-link`.

usage: check_verifier_roots.py FILE     check the verifier at FILE
       check_verifier_roots.py --selftest FILE
"""

import re
import sys
from pathlib import Path

# a build in command position: after `$(`, at the start of a line, or after
# a command separator. A refusal message that names the build is not one.
BUILD = re.compile(r"(?:\$\(|^[ \t]*|[;&|][ \t]*)nix build\b([^)\n]*)", re.M)
ROOTING = re.compile(r"(?:^|\s)(?:--out-link|-o)(?:\s|=)")
UNROOTED = re.compile(r"(?:^|\s)--no-link(?:\s|$)")


def violations(text: str) -> tuple[int, list[str]]:
    """The number of builds read, and one line for each that is not rooted."""
    lines = text.splitlines()
    builds = 0
    found = []
    for match in BUILD.finditer(text):
        line = text.count("\n", 0, match.start()) + 1
        if lines[line - 1].lstrip().startswith("#"):
            continue
        builds += 1
        arguments = match.group(1)
        if UNROOTED.search(arguments):
            found.append(f"line {line}: nix build --no-link leaves its output unrooted")
        elif not ROOTING.search(arguments):
            found.append(f"line {line}: nix build has no --out-link")
    return builds, found


def selftest(path: Path) -> None:
    text = path.read_text()
    builds, found = violations(text)
    assert not found, found
    assert builds == 3, f"the verifier runs {builds} builds, the control reads 3"
    print(f"check-verifier-roots: the committed verifier passes, {builds} builds read")
    # the old line of each build, planted back into the committed text
    for name in ("singular", "devnet", "open-datum"):
        rooted = f'--out-link "$work/root-{name}"'
        assert text.count(rooted) == 1, (name, text.count(rooted))
        planted = text.replace(rooted, "--no-link")
        assert planted != text
        read, found = violations(planted)
        assert read == builds and len(found) == 1, (name, read, found)
        assert "--no-link" in found[0], found
        print(f"check-verifier-roots: {name} build unrooted refused: {found[0]}")
        bare = text.replace(f" {rooted}", "")
        assert bare != text
        read, found = violations(bare)
        assert read == builds and len(found) == 1, (name, read, found)
        assert "no --out-link" in found[0], found
        print(
            f"check-verifier-roots: {name} build with no link option refused: {found[0]}"
        )
    # the reading itself: a file with no build is not a pass, a comment and a
    # refusal message that name the build are not builds, a continued line is
    # read where it starts
    assert violations("echo nothing\n") == (0, [])
    assert violations('# nix build --no-link\nrefuse x "nix build --no-link"\n') == (
        0,
        [],
    )
    read, found = violations('p="$(nix build --no-link .#p)" \\\n  || exit 1\n')
    assert read == 1 and len(found) == 1, (read, found)
    print("check-verifier-roots: selftest PASS")


def main() -> None:
    arguments = sys.argv[1:]
    if len(arguments) == 2 and arguments[0] == "--selftest":
        selftest(Path(arguments[1]))
        return
    if len(arguments) != 1:
        raise SystemExit(__doc__)
    builds, found = violations(Path(arguments[0]).read_text())
    if builds == 0:
        found.append("no nix build read: the check would pass on any file")
    for line in found:
        print(f"check-verifier-roots: FAIL {line}")
    if found:
        raise SystemExit(1)
    print(f"check-verifier-roots: PASS {builds} builds, each rooted by --out-link")


if __name__ == "__main__":
    main()
