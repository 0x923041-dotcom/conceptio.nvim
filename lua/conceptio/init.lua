--- conceptio.nvim — search the Conceptio Open Knowledge Archive from Neovim.
---
--- Thin wrapper over the public `conceptio` CLI (the shared core: auth,
--- retries, rate-limit handling, and upgrade hints live in one place). No
--- credentials are embedded: the API key comes from setup(), the
--- CONCEPTIO_API_KEY environment variable, or a saved `conceptio auth` and
--- is sent only to the configured api_base.

local api = require("conceptio.api")
local quickfix = require("conceptio.quickfix")

local M = { config = {} }

local DEFAULTS = {
  api_base = "https://www.conceptio.app",
  api_key = nil, -- falls back to $CONCEPTIO_API_KEY, then the CLI's saved config
  license_key = nil,
  bin = "conceptio", -- the shared CLI binary (override in tests / for custom installs)
  limit = 20,
}

--- Configure the plugin.
--- @param opts table|nil { api_key, license_key, api_base, bin, limit }
function M.setup(opts)
  opts = opts or {}
  M.config = vim.tbl_deep_extend("force", DEFAULTS, opts)
  M.config.api_key = opts.api_key or vim.env.CONCEPTIO_API_KEY or ""
end

local function ensure_config()
  if M.config.api_base == nil then
    M.setup()
  end
end

local function fill_from(data, what)
  if data.error then
    vim.notify(tostring(data.error), vim.log.levels.ERROR)
    return
  end
  if data.detail then
    vim.notify(tostring(data.detail), vim.log.levels.ERROR)
    return
  end
  if type(data.results) ~= "table" then
    vim.notify("Unexpected " .. what .. " response shape", vim.log.levels.ERROR)
    return
  end
  if #data.results == 0 then
    vim.notify("Conceptio: no results", vim.log.levels.INFO)
    return
  end
  quickfix.fill(data.results)
  -- The search/resolve API reports the FULL match count as `total` (e.g. 418
  -- for "zero trust"), while `results` is just this page. Report the total so
  -- the notify is honest about corpus size, not just the page (fixed
  -- 2026-09-09: the old `data.count` was always nil → always said 3 result(s)).
  vim.notify(
    string.format("Conceptio: %d result(s)", data.total or #data.results),
    vim.log.levels.INFO
  )
end

--- Search the archive; results land in the quickfix list.
--- @param query string  supports source:/category:/lang: directives
--- @param extra table|nil { limit, sources = {..}, category, language, license }
function M.search(query, extra)
  ensure_config()
  extra = extra or {}
  api.search(query, {
    limit = extra.limit or M.config.limit,
    sources = extra.sources,
    category = extra.category,
    language = extra.language,
    license = extra.license,
  }, function(data, err)
    if err then
      vim.notify(err, vim.log.levels.ERROR)
      return
    end
    fill_from(data, "search")
  end)
end

--- Resolve a known identifier (RFC, DOI, arXiv, case citation...) to results.
--- @param identifier string
function M.resolve(identifier)
  ensure_config()
  api.resolve(identifier, M.config.limit, function(data, err)
    if err then
      vim.notify(err, vim.log.levels.ERROR)
      return
    end
    fill_from(data, "resolve")
  end)
end

--- Yank a citation for a document id.
--- @param id number
--- @param format string  default "apa"
function M.cite(id, format)
  ensure_config()
  quickfix.yank_citation(id, format or "apa", function(err)
    if err then
      vim.notify(err, vim.log.levels.ERROR)
    end
  end)
end

--- Open a document's public page in the browser.
--- @param id number
function M.open(id)
  ensure_config()
  quickfix.open_document(id)
end

--- Preview a document's metadata in a floating window.
--- @param id number
function M.preview(id)
  ensure_config()
  quickfix.preview(id)
end

--- Show the current tier / quota as granted by the API (`conceptio quota`).
function M.status()
  ensure_config()
  api.quota(function(text, err)
    if err then
      vim.notify(err, vim.log.levels.ERROR)
      return
    end
    vim.notify(text ~= "" and text or "Conceptio: unknown status", vim.log.levels.INFO)
  end)
end

return M