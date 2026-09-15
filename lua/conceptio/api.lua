--- Conceptio API transport for Neovim — via the shared `conceptio` CLI.
---
--- The plugin shells out to the public `conceptio` CLI instead of talking to
--- the REST API directly, so auth, retries, rate-limit handling, and the
--- Dev-gate upgrade hints all live in ONE core shared with the terminal.
--- Arguments are passed as a LIST (never a shell string), so a query with
--- odd characters cannot inject shell syntax. Machine mode (`--json`) keeps
--- stdout JSON-clean: human messages come back on stderr and surface through
--- the callback as a plain string.

local M = {}

local function bin()
  return require("conceptio").config.bin or "conceptio"
end

--- Inherit the parent environment and overlay the configured credentials, so
--- the CLI resolves them without the user having to run `conceptio auth`
--- first (setup()/CONCEPTIO_API_KEY keep working as before).
local function child_env()
  local env = {}
  for k, v in pairs(vim.env) do
    env[k] = v
  end
  local cfg = require("conceptio").config
  if cfg.api_key and cfg.api_key ~= "" then
    env.CONCEPTIO_API_KEY = cfg.api_key
  end
  if cfg.license_key and cfg.license_key ~= "" then
    env.CONCEPTIO_LICENSE_KEY = cfg.license_key
  end
  if cfg.api_base and cfg.api_base ~= "" and cfg.api_base ~= "https://www.conceptio.app" then
    env.CONCEPTIO_API_BASE = cfg.api_base
  end
  return env
end

--- Run one CLI command. opts.raw = true hands the caller the trimmed stdout
--- text instead of a decoded JSON table.
--- @param args table  argument list (no shell interpolation)
--- @param opts table|nil  { raw = bool }
--- @param cb function(data, err)  data = decoded JSON table or raw text; err = human string
local function run(args, opts, cb)
  opts = opts or {}
  vim.system(args, { text = true, env = child_env() }, function(out)
    -- vim.system callbacks fire in a fast-event context; the UI-touching
    -- work our callers do (setqflist, copen, notify, setreg, open_win) must
    -- run on the main loop. Without the schedule, :ConceptioSearch crashed
    -- with E5560 on the first quickfix fill (caught live 2026-09-09).
    vim.schedule(function()
      if out.code ~= 0 then
        local err = (out.stderr or ""):gsub("%s+$", "")
        if err == "" then
          err = (out.stdout or ""):gsub("%s+$", "")
        end
        if err == "" then
          err = "conceptio failed (exit " .. out.code .. ")"
        end
        cb(nil, err)
        return
      end
      if opts.raw then
        cb((out.stdout or ""):gsub("%s+$", ""), nil)
        return
      end
      local ok, data = pcall(vim.json.decode, out.stdout or "")
      if not ok then
        cb(nil, "Non-JSON response: " .. (out.stdout or ""):sub(1, 200))
        return
      end
      if type(data) == "table" and (data.error or data.detail) then
        cb(nil, tostring(data.error or data.detail))
        return
      end
      cb(data, nil)
    end)
  end)
end

--- Search the archive; the CLI parses source:/lang:/category: directives.
--- @param query string
--- @param opts table|nil  { limit, sources = {..}, category, language, license }
--- @param cb function(data, err)
function M.search(query, opts, cb)
  opts = opts or {}
  local args = { bin(), "search", query, "--json", "-l", tostring(opts.limit or 20) }
  if opts.category and opts.category ~= "" then
    args[#args + 1] = "-c"
    args[#args + 1] = opts.category
  end
  if opts.language and opts.language ~= "" then
    args[#args + 1] = "--lang"
    args[#args + 1] = opts.language
  end
  if opts.license then
    args[#args + 1] = "--license"
    args[#args + 1] = opts.license
  end
  if opts.sources and #opts.sources > 0 then
    -- The CLI reads source filters from source: directives in the query text.
    args[2] = args[2] .. " source:" .. table.concat(opts.sources, ",")
  end
  run(args, {}, cb)
end

--- Resolve a known identifier (RFC, DOI, arXiv, case citation...) to results.
--- @param identifier string
--- @param limit number|nil
--- @param cb function(data, err)
function M.resolve(identifier, limit, cb)
  run({ bin(), "resolve", identifier, "--json", "-l", tostring(limit or 20) }, {}, cb)
end

--- Fetch a citation string (one of the 11 formats).
--- `conceptio cite` prints the citation itself to stdout (it is already a
--- plain-text payload, so the CLI defines no --json for it); errors exit
--- non-zero and are surfaced by run().
--- @param id number
--- @param format string|nil
--- @param cb function(text, err)
function M.cite(id, format, cb)
  run({ bin(), "cite", tostring(id), "-f", format or "apa" }, { raw = true }, cb)
end

--- Full document metadata (for the floating preview).
--- @param id number
--- @param cb function(data, err)
function M.info(id, cb)
  run({ bin(), "info", tostring(id), "--json" }, {}, cb)
end

--- Current tier/identity as granted by the API (human text).
--- @param cb function(text, err)
function M.quota(cb)
  run({ bin(), "quota" }, { raw = true }, cb)
end

return M