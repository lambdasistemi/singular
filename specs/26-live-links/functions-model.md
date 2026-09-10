# Functions

`tools/check_site.py` keeps its current rendered-page walk.

Add, same module:

- `github_readme_url(href)` — absolute href unchanged; relative href
  becomes `https://github.com/lambdasistemi/singular/blob/main/` + href
- `github_blob_url(source_md, href)` — `urljoin` against
  `https://github.com/lambdasistemi/singular/blob/main/<source_md>`
- `docs_url(page_rel, href, trailing_slash)` — `urljoin` against
  `site_url` + page directory, with and without trailing slash
- `inventory_and_check(site_dir)` — discover every href/src from README
  and built HTML; resolve; classify; request or local-file check;
  print JSON counts; exit 1 on fail

No new packages. No Lean or simulator signatures.
