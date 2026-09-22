# conceptio.nvim

**Search the [Conceptio Open Knowledge Archive](https://conceptio.app) from Neovim** — open-access papers, standards, case law, regulations, and technical documents — and yank a citation without leaving your editor.

A thin Lua wrapper over the public [`conceptio`](https://github.com/0x923041-dotcom/conceptio-cli) CLI (`pip install conceptio-search`). The CLI owns auth, retries, rate-limit handling, and upgrade hints, so this plugin, the terminal, the MCP server, and the other Conceptio extensions share **one core** — there is no duplicated search or citation logic. No credentials are embedded: the CLI resolves them from `conceptio auth`, `$CONCEPTIO_API_KEY`, or the plugin's setup table, and requests go only to the configured `api_base`.

## Requirements

- Neovim **0.10+** (uses `vim.system` and `vim.json`)
- The **`conceptio` CLI** on `PATH` — `pip install conceptio-search`.
  **0.3.0 or newer**: every call this plugin makes is accepted by 0.3.0
  (0.1.1 has neither `--license` on `search` nor `--json` on `info`). The
  current release is 0.3.6.

## Install

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "0x923041-dotcom/conceptio.nvim",
  opts = {},  -- auth via `conceptio auth` or $CONCEPTIO_API_KEY
  cmd = {
    "ConceptioSearch", "ConceptioResolve", "ConceptioCite",
    "ConceptioOpen", "ConceptioPreview", "ConceptioStatus",
  },
}
```

Or with packer: `use { "0x923041-dotcom/conceptio.nvim", config = function() require("conceptio").setup {} end }`

## Setup

```lua
require("conceptio").setup {
  api_base = "https://www.conceptio.app", -- override for a self-hosted deployment
  api_key = "ckey_live_...",              -- optional; $CONCEPTIO_API_KEY also works
  license_key = nil,                      -- optional; passed through as CONCEPTIO_LICENSE_KEY
  bin = "conceptio",                      -- CLI executable (path when it isn't on PATH)
  limit = 20,                             -- default result count per search
}
```

Credentials are optional here: if the CLI already has one saved (`conceptio auth ckey_live_...`), the plugin uses it. Anything configured in `setup()` is handed to the CLI through the environment for that one call.

Get a key on your [Conceptio profile](https://conceptio.app). The **Dev plan is the agent tier** for programmatic surfaces (the CLI, MCP server, and this plugin); free keys are for the browser pool and cannot call the API.

## Commands

| Command | What it does |
| ------- | ------------ |
| `:ConceptioSearch <query>` | Search the archive; results fill the quickfix list (`:copen` opens automatically). Supports `source:` / `category:` / `lang:` directives inside the query, plus `--sources=a,b`, `--license=commercial-ok` and `--limit=N` flags. |
| `:ConceptioResolve <identifier>` | Resolve a known identifier — `RFC 2119`, `doi:10.1145/3290605.3300333`, `2604.08499` (arXiv), `410 U.S. 113` (case citation) — into the quickfix list. |
| `:ConceptioCite <doc-id> [format]` | Yank a citation for a document id into the `+` register. Formats: `bibtex`, `apa` (default), `mla`, `chicago`, `ieee`, `harvard`, `ris`, `bluebook`, `oscola`, `iso690`, `ansiz39`. |
| `:ConceptioOpen <doc-id>` | Open the document's public page in your default browser. |
| `:ConceptioPreview <doc-id>` | Show a document's metadata (author, source, year, license, language, abstract, url) in a floating window; `q` closes it. |
| `:ConceptioStatus` | Report the current tier and quota the API grants this credential. |

Quickfix entries are `[id] author — title (year)` and the list is **interactive**: press `<CR>` on an entry to open the document in your browser, `c` to yank its APA citation, or `p` to preview its metadata — no need to copy the id by hand. You can still run `:ConceptioCite <id> [format]` explicitly.

Errors are surfaced verbatim from the CLI — a rate-limit message, an auth hint, or the upgrade prompt — never a generic client-side guess.

## Examples

```vim
:ConceptioSearch source:nist zero trust
:ConceptioSearch "attention is all you need" --license=commercial-ok
:ConceptioResolve RFC 2119
:ConceptioCite 7288 bibtex
:ConceptioPreview 7288
:ConceptioStatus
:ConceptioOpen 7288
```

## API

```lua
local conceptio = require("conceptio")
conceptio.setup {}                       -- or { api_key = "ckey_live_..." }
conceptio.search("transformer", { limit = 10 })
conceptio.resolve("doi:10.1145/3290605.3300333")
conceptio.cite(7288, "ieee")
conceptio.preview(7288)
conceptio.status()
conceptio.open(7288)
```

## Notes

- Results are served access-aware: metadata-only sources carry metadata + the official link, full text is served only where the source's license permits.
- `--license=commercial-ok` fails closed — only sources whose catalog license explicitly permits commercial use are admitted.
- This plugin rides the same shared core as the Raycast and Alfred extensions: the CLI is the single implementation of search, resolve, and citation, and each surface is a thin presenter over it.

## Development

The plugin has no build step — `lua/conceptio/` is the whole source. The whole headless suite is one command:

```bash
bash test/run.sh               # the suite against the loopback stub — no account, no credits
bash test/run.sh --keyless     # just the honest auth-gate path
bash test/run.sh --live <key>  # the same suite against the real archive
```

`test/run.sh` resolves a Neovim (`$NVIM`, then `PATH`, then a portable tree under `../tmp/nvim-portable`), resolves the `conceptio` CLI (`$CONCEPTIO_CLI`, then the sibling checkout's venv, then `PATH`), starts `test/stub_api.py` on loopback, runs `test/run.lua`, and stops the stub again. It exits with the suite's own status, and **2** when this box cannot run it at all — so "could not check" is never confused with "checked and fine".

With a key it exercises search → quickfix → cite → resolve → preview → status end-to-end against the live API (respecting the tier's 1 req/s burst limiter); without one it asserts the honest auth-gate path (the CLI refuses keyless runs client-side, so no credential may be saved to `~/.conceptio/config.json` for that run).

No account and no credits are needed for the default path — `test/stub_api.py` serves the API shapes on loopback, which the CLI accepts over plain HTTP for local hosts. The runner is `run.lua` plus three resolved preconditions; to drive it by hand:

```bash
python3 test/stub_api.py &          # 127.0.0.1:8799, canned responses only
CONCEPTIO_API_BASE=http://127.0.0.1:8799 \
  nvim --clean -u test/init.lua -l test/run.lua ckey_live_local_stub $(which conceptio)
```

The placeholder key only satisfies the CLI's client-side auth gate; the stub does not check credentials. This path verifies the plugin's transport, argument contract, and response handling — not the live archive's data.

The stub is the shared one: it also serves the **write** surface by POST
(`/api/search/batch`, `/api/search/jobs` and their poll, `/api/connectors/*`),
which is what the CLI's live harness (`conceptio-cli/tests/live_check.py`) and
the Obsidian plugin's runtime check drive. `CONCEPTIO_STUB_JOB_MODE=running`
makes a queued job never finish and `expired` reports one the server gave up
on, so a poll budget can be exercised without waiting for one; the default
`done` completes on the first poll.

A Telescope picker slot is a natural community contribution (the quickfix list is the core surface).

## License

MIT — see [LICENSE](LICENSE).
