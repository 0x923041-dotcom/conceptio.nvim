#!/usr/bin/env bash
#
# conceptio.nvim headless regression suite — one command, no account, no credits.
#
#   test/run.sh                  # the whole suite against the loopback stub
#   test/run.sh --keyless        # only the honest auth-gate path (no credential)
#   test/run.sh --live <key>     # the same suite against the real API
#
# The README used to document this as a four-step recipe: fetch a portable nvim,
# start `test/stub_api.py` in another shell, export `CONCEPTIO_API_BASE`, then
# invoke `nvim --clean -u test/init.lua -l test/run.lua`. Every step is correct
# and the recipe still had to be re-derived from scratch each time — the zip was
# unpacked into a scratch dir and deleted afterwards, so "the suite is green" was
# a claim about a previous session rather than a command anyone could repeat. A
# recipe is a story; this is the check.
#
# The suite drives the real `conceptio` CLI through the loopback stub, so it
# proves the plugin's transport, argument contract and response handling with no
# account and no production credits. `test/run.lua` remains the suite itself —
# this script only supplies the three things it needs (a Neovim, a CLI binary,
# and an API answering on loopback) and then gets out of the way.
#
# Preconditions it resolves for you, in order:
#   nvim   $NVIM, else `nvim` on PATH, else a portable tree under
#          ../tmp/nvim-portable (see the acquisition note it prints when it
#          finds none)
#   CLI    $CONCEPTIO_CLI, else the sibling `conceptio-cli` venv, else PATH
#   stub   $CONCEPTIO_STUB, else test/stub_api.py next to this script
#
# Exits with the suite's own status: 0 all green, 1 a failed check. It exits 2
# when this box cannot run it at all — a distinct status on purpose, so "could
# not check" never gets read as "checked and fine".

set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
STUB_PORT="${CONCEPTIO_STUB_PORT:-8799}"
STUB_BASE="http://127.0.0.1:${STUB_PORT}"
# Satisfies the CLI's client-side auth gate; the stub does not check keys.
PLACEHOLDER_KEY="ckey_live_local_stub"
STUB_PID=""

case "$(uname -s 2>/dev/null)" in
  MINGW*|MSYS*|CYGWIN*) IS_WINDOWS=1 ;;
  *) IS_WINDOWS=0 ;;
esac
PYTHON="${PYTHON:-$( [ "$IS_WINDOWS" = 1 ] && echo python || echo python3 )}"

cleanup() {
  if [ -n "$STUB_PID" ] && kill -0 "$STUB_PID" 2>/dev/null; then
    kill "$STUB_PID" 2>/dev/null
    wait "$STUB_PID" 2>/dev/null
  fi
}
trap cleanup EXIT INT TERM

cannot_run() {
  printf '\nCANNOT RUN: %s\n' "$1" >&2
  exit 2
}

# ── a Neovim ─────────────────────────────────────────────────────────────────
find_nvim() {
  if [ -n "${NVIM:-}" ] && [ -x "${NVIM:-}" ]; then printf '%s' "$NVIM"; return; fi
  if command -v nvim >/dev/null 2>&1; then command -v nvim; return; fi
  # A portable tree, wherever it was unpacked. `nvim-win64/bin/nvim.exe` and
  # `nvim-linux-x86_64/bin/nvim` are both one or two levels down.
  local candidate
  for candidate in \
    "$REPO/../tmp/nvim-portable/bin/nvim.exe" \
    "$REPO/../tmp/nvim-portable/bin/nvim" \
    "$REPO/../tmp/nvim-portable"/*/bin/nvim.exe \
    "$REPO/../tmp/nvim-portable"/*/bin/nvim
  do
    if [ -x "$candidate" ]; then printf '%s' "$candidate"; return; fi
  done
}

NVIM_BIN="$(find_nvim)"
if [ -z "$NVIM_BIN" ]; then
  cannot_run "no Neovim found. Any of these works:
    · nvim on PATH (or point \$NVIM at one)
    · a portable tree, nothing installed system-wide:
        curl -L -o ../tmp/nvim-portable/nvim.zip \\
          https://github.com/neovim/neovim/releases/download/stable/nvim-win64.zip
        unzip -q ../tmp/nvim-portable/nvim.zip -d ../tmp/nvim-portable"
fi

# ── the shared CLI ───────────────────────────────────────────────────────────
find_cli() {
  if [ -n "${CONCEPTIO_CLI:-}" ]; then printf '%s' "$CONCEPTIO_CLI"; return; fi
  local candidate
  for candidate in \
    "$REPO/../conceptio-cli/.venv/Scripts/conceptio.exe" \
    "$REPO/../conceptio-cli/.venv/bin/conceptio"
  do
    if [ -x "$candidate" ]; then printf '%s' "$candidate"; return; fi
  done
  if command -v conceptio >/dev/null 2>&1; then command -v conceptio; return; fi
}

CLI_BIN="$(find_cli)"
if [ -z "$CLI_BIN" ]; then
  cannot_run "no conceptio CLI found. Install it (\`pip install conceptio-search\`) or point \$CONCEPTIO_CLI at one — a sibling conceptio-cli checkout's venv is looked for automatically."
fi

# ── mode ─────────────────────────────────────────────────────────────────────
MODE="stub"
KEY="$PLACEHOLDER_KEY"
case "${1:-}" in
  --keyless)
    MODE="keyless"; KEY="" ;;
  --live)
    if [ -z "${2:-}" ]; then cannot_run "--live needs an API key: test/run.sh --live <key>"; fi
    MODE="live"; KEY="$2" ;;
  "")
    ;;
  *)
    cannot_run "unknown argument '$1' (expected nothing, --keyless, or --live <key>)" ;;
esac

printf '\nconceptio.nvim suite\n  nvim    %s\n  CLI     %s\n  mode    %s\n\n' "$NVIM_BIN" "$CLI_BIN" "$MODE"

# ── the API the suite talks to ───────────────────────────────────────────────
if [ "$MODE" = "stub" ]; then
  STUB="${CONCEPTIO_STUB:-$REPO/test/stub_api.py}"
  [ -f "$STUB" ] || cannot_run "the loopback stub is missing ($STUB)"
  if curl -s -o /dev/null --max-time 2 "$STUB_BASE/api/me"; then
    cannot_run "something is already listening on $STUB_BASE — stop it, or set CONCEPTIO_STUB_PORT"
  fi
  "$PYTHON" "$STUB" "$STUB_PORT" >/dev/null 2>&1 &
  STUB_PID=$!
  ready=0
  for _ in $(seq 1 40); do
    if curl -s -o /dev/null --max-time 2 "$STUB_BASE/api/me"; then ready=1; break; fi
    kill -0 "$STUB_PID" 2>/dev/null || break
    sleep 0.25
  done
  if [ "$ready" != 1 ]; then
    cannot_run "the stub never answered on $STUB_BASE (start it by hand to see why: $PYTHON $STUB $STUB_PORT)"
  fi
  export CONCEPTIO_API_BASE="$STUB_BASE"
fi

# ── run ──────────────────────────────────────────────────────────────────────
# From the plugin root: test/init.lua prepends the CWD to runtimepath, so the
# suite only sees this checkout when it is the working directory.
cd "$REPO" || cannot_run "could not cd to $REPO"
"$NVIM_BIN" --clean -u test/init.lua -l test/run.lua "$KEY" "$CLI_BIN"
STATUS=$?

if [ "$STATUS" = 0 ]; then
  printf '\nsuite green (%s)\n' "$MODE"
else
  printf '\nsuite FAILED (exit %s, %s)\n' "$STATUS" "$MODE" >&2
fi
exit "$STATUS"
