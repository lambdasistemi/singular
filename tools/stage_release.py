"""Materialize a release tree without symlinks or shared file inodes."""
import argparse
import os
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
