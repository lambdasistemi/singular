"""Stage and check the model source artifacts linked by the documentation."""

from pathlib import Path
import os
import re
import shutil
import tempfile
from urllib.parse import urlsplit


def source_roots(root: Path) -> list[Path]:
    candidates = [root / "lean", *sorted((root / "models").glob("*/lean"))]
    return [path for path in candidates if path.is_dir()]


def artifact_path(root: Path, source: Path) -> Path:
    source = source.resolve()
    for directory in source_roots(root):
        if source.is_relative_to(directory):
            return (
                source.relative_to(directory)
                if directory == root / "lean"
                else source.relative_to(root)
            )
    raise RuntimeError(f"model source is outside the published source roots: {source}")


def source_path(root: Path, artifact: Path) -> Path:
    source = (
        root / artifact
        if artifact.parts and artifact.parts[0] == "models"
        else root / "lean" / artifact
    ).resolve()
    if artifact_path(root, source) != artifact:
        raise RuntimeError(f"model artifact has no source mapping: {artifact}")
    return source


def restage_hrefs(root: Path, stage: Path) -> int:
    """Resolve authored model links to this build's shipped source files."""
    rewritten = 0
    for md in sorted(stage.glob("docs/**/*.md")) + sorted(stage.glob("specs/**/*.md")):
        text = md.read_text(encoding="utf-8")

        def target(href: str) -> str:
            parts = urlsplit(href)
            source = (root / md.relative_to(stage).parent / parts.path).resolve()
            if not source.is_file():
                raise RuntimeError(f"model source link has no file: {md}: {href}")
            served = stage / "model" / artifact_path(root, source)
            result = os.path.relpath(served, md.parent / md.stem)
            if parts.query:
                result += "?" + parts.query
            if parts.fragment:
                result += "#" + parts.fragment
            return result

        # Rewrite authored raw links first so newly produced anchors are not
        # processed again when their artifact path itself contains lean/.
        new = re.sub(
            r'href="((?:\.\./)*(?:[\w.-]+/)*lean/[^\"]*)"',
            lambda match: f'href="{target(match.group(1))}"',
            text,
        )
        new = re.sub(
            r"\[([^\]]+)\]\(((?:\.\./)*(?:[\w.-]+/)*lean/[^)]*)\)",
            lambda match: f'<a href="{target(match.group(2))}">{match.group(1)}</a>',
            new,
        )
        if new != text:
            md.write_text(new, encoding="utf-8")
            rewritten += 1
    if not rewritten:
        raise RuntimeError("no model source links reached the staged artifacts")
    return rewritten


def stage_sources(root: Path, stage: Path) -> None:
    for directory in source_roots(root):
        destination = (
            stage / "model"
            if directory == root / "lean"
            else stage / "model" / directory.relative_to(root)
        )
        shutil.copytree(
            directory,
            destination,
            dirs_exist_ok=True,
            ignore=shutil.ignore_patterns(
                ".lake",
                "node_modules",
                "__pycache__",
                "*.olean",
                "*.ilean",
                "*.c",
                "*.o",
            ),
        )


def check_artifacts(root: Path, site: Path, artifacts: list[Path]) -> None:
    if not artifacts:
        raise RuntimeError("no shipped model source artifacts were reached")
    for relative in artifacts:
        served = site / relative
        source = source_path(root, relative.relative_to("model"))
        if not served.is_file() or not source.is_file():
            raise RuntimeError(f"MODEL_SOURCE_MISSING: {relative}")
        if served.read_bytes() != source.read_bytes():
            raise RuntimeError(f"MODEL_SOURCE_STALE: {relative}")


def controls(root: Path, site: Path, artifacts: list[Path]) -> int:
    """Every discovered source link must reject altered and missing bytes."""
    count = 0
    with tempfile.TemporaryDirectory(prefix="singular-model-reference-") as temporary:
        fixture = Path(temporary)
        for relative in artifacts:
            target = fixture / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(site / relative, target)
        check_artifacts(root, fixture, artifacts)
        for relative in artifacts:
            target = fixture / relative
            original = target.read_bytes()
            for missing in (False, True):
                expected = "MODEL_SOURCE_MISSING" if missing else "MODEL_SOURCE_STALE"
                if missing:
                    target.unlink()
                    assert not target.exists()
                else:
                    target.write_bytes(
                        original + b"\n-- changed documentation artifact\n"
                    )
                    assert target.read_bytes() != original
                try:
                    check_artifacts(root, fixture, artifacts)
                except RuntimeError as error:
                    if not str(error).startswith(expected + ":"):
                        raise
                else:
                    raise RuntimeError(
                        f"model source control was not detected: {relative}"
                    )
                target.write_bytes(original)
                count += 1
        check_artifacts(root, fixture, artifacts)
    return count
