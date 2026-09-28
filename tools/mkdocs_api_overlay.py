"""MkDocs hook: add the staged generated API references to the built site.

``tools/prepare_docs.py --api-site SITE`` stages a packaged site build's
``api/`` tree at ``.docs-api/``; after every build — ``mkdocs build`` and
each live-reload rebuild of ``mkdocs serve`` — this hook copies it to the
built site's ``api/``, byte for byte, outside MkDocs' page processing. With
nothing staged (the packaged build, which generates ``api/`` after MkDocs)
it does nothing.
"""

import shutil
from pathlib import Path

OVERLAY = Path(__file__).resolve().parent.parent / ".docs-api"


def on_post_build(config, **kwargs):
    if not OVERLAY.is_dir():
        return
    target = Path(config["site_dir"]) / "api"
    if target.exists():
        shutil.rmtree(target)
    shutil.copytree(OVERLAY, target)
