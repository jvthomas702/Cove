# Architecture diagram

`cove-architecture.html` is an interactive map of how Cove fits together: agent hooks into the
loopback server, the island model, the notch panel, sports, the Mac monitors and the fn-key voice
path. Download it and open it in a browser. Every box links to the source lines it's based on, at
the commit pinned in the diagram.

It's made with [Archify](https://github.com/tt-a1i/archify) from `cove.architecture.json`. To
change it, edit the JSON, set `meta.repository.revision` to the commit you checked, then rebuild
from the repository root:

```sh
npx skills add tt-a1i/archify -g      # once; or ask your agent to "use Archify"
node <archify>/bin/archify.mjs finalize architecture docs/architecture/cove.architecture.json \
  docs/architecture/cove-architecture.html --repo-root . --quality showcase
```
