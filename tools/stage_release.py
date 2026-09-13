"""Materialize a release tree without symlinks or shared file inodes."""
import argparse
import hashlib
import io
import os
import tarfile
from pathlib import Path
import stat
import tempfile


def _directory_key(path: Path) -> tuple[int, int]:
    metadata = path.stat()
    return metadata.st_dev, metadata.st_ino


def _copy_directory(source: Path, destination: Path, active: frozenset[tuple[int, int]]) -> None:
    resolved = source.resolve(strict=True)
    key = _directory_key(resolved)
    if key in active:
        raise ValueError(f"directory symlink cycle: {source}")
    destination.mkdir()
    active = active | {key}
    for entry in sorted(resolved.iterdir(), key=lambda path: path.name):
        target = destination / entry.name
        try:
            metadata = entry.stat()
        except FileNotFoundError as error:
            raise ValueError(f"dangling release symlink: {entry}") from error
        if stat.S_ISDIR(metadata.st_mode):
            _copy_directory(entry, target, active)
        elif stat.S_ISREG(metadata.st_mode):
            # Reading and writing the bytes makes both symbolic links and Nix
            # store hard links independent regular files in the staging tree.
            target.write_bytes(entry.read_bytes())
            target.chmod(stat.S_IMODE(metadata.st_mode))
        else:
            raise ValueError(f"unsupported release entry: {entry}")


def assert_regular_tree(root: Path) -> None:
    file_inodes: dict[tuple[int, int], Path] = {}
    for path in sorted(root.rglob("*")):
        if path.is_symlink():
            raise AssertionError(f"staged release contains symlink: {path}")
        metadata = path.stat()
        if stat.S_ISDIR(metadata.st_mode):
            continue
        if not stat.S_ISREG(metadata.st_mode):
            raise AssertionError(f"staged release contains special entry: {path}")
        key = metadata.st_dev, metadata.st_ino
        if key in file_inodes:
            raise AssertionError(f"staged release contains hard link: {path} -> {file_inodes[key]}")
        file_inodes[key] = path


def stage_release(source: Path, destination: Path) -> None:
    if destination.exists() or destination.is_symlink():
        raise FileExistsError(f"release destination already exists: {destination}")
    _copy_directory(source, destination, frozenset())
    assert_regular_tree(destination)


def read_all_forward(bundle: tarfile.TarFile, wanted: set[str]) -> dict[str, bytes]:
    """Read every wanted regular file in ONE forward pass.

    Archive members are stored sorted (`tar --sort=name` at assembly), so
    `getmembers()` order is already forward-only: extracting in that order
    never seeks backward in the gzip stream (the old per-name `extractfile`
    loop over a 221 MB archive seeks repeatedly and costs ~29 minutes of
    CPU). Returns name-without-`./`-prefix to bytes for exactly the wanted
    regular files; callers keep every completeness assertion (missing,
    extra, drifted and corrupted members all still fail — only the
    traversal changed)."""
    found: dict[str, bytes] = {}
    for member in bundle.getmembers():
        key = member.name.removeprefix("./")
        if key in wanted and member.isfile():
            extracted = bundle.extractfile(member)
            assert extracted is not None, f"unreadable archive member: {key}"
            found[key] = extracted.read()
    return found


def selftest() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        source = root / "source"
        source.mkdir()
        real = source / "real"
        real.mkdir()
        (real / "payload.txt").write_text("materialized\n", encoding="utf-8")
        os.link(real / "payload.txt", source / "hard-linked.txt")
        (source / "file-link.txt").symlink_to(real / "payload.txt")
        (source / "directory-link").symlink_to(real, target_is_directory=True)

        destination = root / "staged"
        stage_release(source, destination)
        assert_regular_tree(destination)
        assert (destination / "file-link.txt").read_text(encoding="utf-8") == "materialized\n"
        assert (destination / "directory-link/payload.txt").read_text(encoding="utf-8") == "materialized\n"

        cyclic = root / "cyclic"
        cyclic.mkdir()
        (cyclic / "again").symlink_to(cyclic, target_is_directory=True)
        try:
            stage_release(cyclic, root / "cycle-output")
        except ValueError as error:
            assert "cycle" in str(error)
        else:
            raise AssertionError("directory symlink cycle was accepted")

        # Forward-reader fidelity (NOTE-001 item 3): exact bytes back for
        # every wanted file in one pass; tampered bytes come back tampered
        # (the reader masks nothing — downstream hash comparisons reject).
        bundle_path = root / "control.tar.gz"
        with tarfile.open(bundle_path, "w:gz") as bundle:
            for name, payload in (
                ("a.txt", b"alpha\n"),
                ("sub/b.txt", b"beta\n"),
                ("sub/c.txt", b"gamma\n"),
            ):
                info = tarfile.TarInfo(name)
                info.size = len(payload)
                info.mtime = 1
                bundle.addfile(info, io.BytesIO(payload))
        with tarfile.open(bundle_path) as bundle:
            got = read_all_forward(bundle, {"a.txt", "sub/b.txt", "sub/c.txt"})
        assert got == {
            "a.txt": b"alpha\n",
            "sub/b.txt": b"beta\n",
            "sub/c.txt": b"gamma\n",
        }, "forward reader returned wrong bytes"
        with tarfile.open(bundle_path) as bundle:
            partial = read_all_forward(bundle, {"a.txt", "missing.txt"})
        assert set(partial) == {"a.txt"}, "forward reader must omit absent members"
        tampered = root / "tampered.tar.gz"
        with tarfile.open(bundle_path) as source:
            with tarfile.open(tampered, "w:gz") as target:
                for member in source.getmembers():
                    if member.name == "sub/b.txt":
                        payload = b"BETA-CORRUPT\n"
                        member.size = len(payload)
                        target.addfile(member, io.BytesIO(payload))
                    else:
                        extracted = source.extractfile(member)
                        assert extracted is not None
                        target.addfile(member, extracted)
        with tarfile.open(tampered) as bundle:
            got2 = read_all_forward(bundle, {"a.txt", "sub/b.txt", "sub/c.txt"})
        assert got2["sub/b.txt"] == b"BETA-CORRUPT\n", "reader hid corruption"
        assert hashlib.sha256(got2["sub/b.txt"]).hexdigest() != hashlib.sha256(
            b"beta\n"
        ).hexdigest(), "corrupted bytes hash identically"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path, nargs="?")
    parser.add_argument("destination", type=Path, nargs="?")
    parser.add_argument("--selftest", action="store_true")
    args = parser.parse_args()
    if args.selftest:
        if args.source is not None or args.destination is not None:
            parser.error("--selftest takes no paths")
        selftest()
        print("release staging selftest: PASS")
        return
    if args.source is None or args.destination is None:
        parser.error("source and destination are required")
    stage_release(args.source, args.destination)
    print(f"release staging: PASS ({args.destination})")


if __name__ == "__main__":
    main()
