-- conceptio.nvim headless regression suite (CLI transport).
--
-- Run from the plugin root:
--   nvim --clean -u test/init.lua -l test/run.lua [api_key] [bin]
-- (api_key optional: without one the suite exercises the honest CLI auth-gate
--  path; with one it runs the full E2E against the live API THROUGH the
--  `conceptio` CLI. bin defaults to `conceptio` — pass a path to the CLI
--  executable when it isn't on PATH.)
-- Exits 0 on all green, 1 on failure, 2 on timeout.
--
-- The transport is the shared CLI: every request spawns `conceptio`, which
-- owns auth, retries, and rate-limit handling (the old plugin-level burst
-- test is gone — 429 surfacing is pinned in the CLI's own suite now).
--
-- NOTE: under `nvim -l`, deferred callbacks never run — the main chunk must
-- drive everything with vim.wait() (which pumps the loop and lets both
-- vim.system callbacks and vim.schedule tasks fire).
-- Run order matters for the keyless path: no credential may be saved to
-- ~/.conceptio/config.json before it runs (the CLI would pick it up).

local key = arg[1] or ""
local bin = arg[2] or "conceptio"

local notified = {}
local failures = {}
local checks = 0
local qf_window_buf = nil  -- quickfix window buffer, stashed at fill time

local function check(name, cond, detail)
  checks = checks + 1
  if cond then
    io.write(string.format("PASS %-46s %s\n", name, detail or ""))
  else
    io.write(string.format("FAIL %-46s %s\n", name, detail or ""))
    failures[#failures + 1] = name
  end
  io.flush()
end

vim.notify = function(msg, level, opts)
  notified[#notified + 1] = { msg = tostring(msg), level = level or vim.log.levels.INFO }
end

require("conceptio").setup { api_key = key, bin = bin }

local function wait_for(pred, timeout_ms)
  return vim.wait(timeout_ms or 15000, pred, 20)
end

-- The Pro/Dev tier enforces a 1 req/s token bucket; the suite must space
-- requests or IT becomes the rate limiter's subject. Call before every
-- request step.
local last_request_at = 0
local function space_requests()
  local now = vim.uv.hrtime()
  local elapsed = (now - last_request_at) / 1e9
  if elapsed < 1.2 then
    vim.wait(math.floor((1.2 - elapsed) * 1000))
    now = vim.uv.hrtime()
  end
  last_request_at = now
end

-- ── 1. Transport: honest auth gate without a key, live search with one ──────
local function test_transport()
  local api = require("conceptio.api")
  local done = false
  if key == "" then
    api.search("zero trust", { limit = 3 }, function(data, err)
      check("keyless search surfaces the CLI auth gate",
        err ~= nil and (err:match("Authentication") ~= nil or err:match("requires") ~= nil),
        err and err:sub(1, 70) or "no error")
      done = true
    end)
    wait_for(function() return done end)
    return
  end
  api.search("zero trust", { limit = 3 }, function(data, err)
    check("search returns results", data and data.total and data.total > 0, "total=" .. tostring(data and data.total))
    check("search total is a number", type(data and data.total) == "number", "")
    check("search results array", type(data and data.results) == "table" and #data.results > 0, #(data and data.results or {}) .. " rows")
    done = true
  end)
  wait_for(function() return done end)
end

-- ── 2. :ConceptioSearch fills the quickfix, notify uses total ────────────
local function test_search_command()
  if key == "" then return end
  space_requests()
  vim.cmd("ConceptioSearch zero trust --limit=3")
  local ok = wait_for(function() return #vim.fn.getqflist() > 0 end)
  check(":ConceptioSearch fills quickfix (no E5560)", ok and #vim.fn.getqflist() > 0, #vim.fn.getqflist() .. " entries")
  if ok then
    local qf = vim.fn.getqflist()
    check("quickfix entry has [id] text", qf[1] and qf[1].text:match("%[(%d+)%]") ~= nil, qf[1] and qf[1].text:sub(1, 60))
    qf_window_buf = vim.api.nvim_get_current_buf()
    local total_seen = false
    for _, n in ipairs(notified) do
      local m = n.msg:match("Conceptio: (%d+) result")
      if m and tonumber(m) > 3 then
        total_seen = true
      end
    end
    check("notify reports TOTAL (> page size 3)", total_seen, "")
  end
end

-- ── 3. :ConceptioCite yanks into the + register ──────────────────────────
local function test_cite()
  if key == "" then return end
  local qf = vim.fn.getqflist()
  local id = qf[1] and tonumber(qf[1].text:match("%[(%d+)%]"))
  if not id then
    check("cite: have an id to cite", false, "no quickfix id")
    return
  end
  space_requests()
  vim.fn.setreg("+", "")
  vim.cmd("ConceptioCite " .. id .. " bibtex")
  local ok = wait_for(function() return #vim.fn.getreg("+") > 0 end)
  check(":ConceptioCite yanks into +", ok and #vim.fn.getreg("+") > 0, vim.fn.getreg("+"):sub(1, 70))
end

-- ── 4. :ConceptioStatus + :ConceptioPreview ───────────────────────────────
local function test_status_and_preview()
  if key == "" then return end
  space_requests()
  vim.cmd("ConceptioStatus")
  local start_total = #notified
  local ok = wait_for(function() return #notified > start_total end)
  check(":ConceptioStatus completes without error", ok, "")

  local qf = vim.fn.getqflist()
  local id = qf[1] and tonumber(qf[1].text:match("%[(%d+)%]"))
  if not id then
    check("preview: have an id", false, "no quickfix id")
    return
  end
  space_requests()
  local wins_before = #vim.api.nvim_list_wins()
  vim.cmd("ConceptioPreview " .. id)
  local ok_preview = wait_for(function() return #vim.api.nvim_list_wins() > wins_before end, 15000)
  check(":ConceptioPreview opens a floating window", ok_preview, #vim.api.nvim_list_wins() .. " wins")
  if ok_preview then
    -- Plain substring search, not a Lua pattern: '-' is a lazy quantifier in
    -- patterns, so a pattern built from the literal name silently never
    -- matches (caught 2026-09-10 — the unescaped hyphen in "conceptio-preview").
    local target = "conceptio-preview-" .. id
    local named = false
    local names = {}
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      local n = vim.api.nvim_buf_get_name(b) or ""
      names[#names + 1] = n
      if n:find(target, 1, true) then
        named = true
      end
    end
    check("preview buffer is named conceptio-preview-<id>", named,
      table.concat(names, " | "))
  end
end

-- ── 5. Quickfix action keys + resolve entry point ────────────────────────
local function test_qf_keys()
  if key == "" then return end
  local qf_buf = qf_window_buf or vim.api.nvim_get_current_buf()
  local maps = vim.api.nvim_buf_get_keymap(qf_buf, "n")
  local has_cr, has_c, has_p = false, false, false
  for _, m in ipairs(maps) do
    if m.lhs == "<CR>" then has_cr = true end
    if m.lhs == "c" then has_c = true end
    if m.lhs == "p" then has_p = true end
  end
  check("quickfix <CR> mapping installed", has_cr, "")
  check("quickfix c mapping installed", has_c, "")
  check("quickfix p mapping installed", has_p, "")
  space_requests()
  vim.cmd("ConceptioResolve RFC 2119")
  local start_total = #notified
  local ok = wait_for(function()
    return #notified > start_total
  end)
  check(":ConceptioResolve completes without error", ok, "")
end

-- ── Driver: run each step synchronously ──────────────────────────────────
test_transport()
test_search_command()
test_cite()
test_status_and_preview()
test_qf_keys()

io.write(string.format("\n%d checks, %d failures\n", checks, #failures))
io.flush()
if #failures > 0 then
  io.write("FAILURES: " .. table.concat(failures, ", ") .. "\n")
  os.exit(1)
end
io.write("ALL GREEN\n")
os.exit(0)