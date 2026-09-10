# Data

Inventory row, one per discovered href/src:

- `source`: built page or `README.md`
- `href`: raw attribute
- `bases`: GitHub README, GitHub blob of the source file, docs
  directory URL with trailing slash, docs URL without trailing slash
- `resolved`: absolute URL per base
- `final_status`: HTTP or built-file existence after redirects
- `kind`: internal-site, github-source, external, fragment, asset
- `result`: pass, fail, blocked
- `evidence`: title/snippet or error

Canonical playable identity: HTTP 200 HTML whose title contains
`Singular · A name and its custody` (or the current playable
`<title>`), not a GitHub tree/blob document.

Counts: total, checked, pass, fail, blocked.
