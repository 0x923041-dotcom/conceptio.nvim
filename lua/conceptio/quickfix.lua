--- Result rendering for the Conceptio plugin: quickfix list, browser open,
--- citation yank, and a floating metadata preview.

local M = {}

--- Fill the quickfix list from search/resolve results and open it.
--- @param results table  array of search-result objects from the API
function M.fill(results)
  local items = {}
  for _, r in ipairs(results or {}) do
    local author = ""
    if r.author and r.author ~= "" then
      author = r.author .. " \226\128\148 "
    end
    local year = ""
    if r.year and r.year ~= "" then
      year = " (" .. r.year .. ")"
    end
    items[#items + 1] = {
      text = string.format("[%d] %s%s%s", r.id, author, r.title, year),
      filename = r.url or "",
      lnum = 0,
    }
  end
  vim.fn.setqflist(items, "r")
  vim.cmd("botright copen 10")
  -- Make the quickfix list interactive (2026-09-09): <CR> opens the document
  -- under the cursor in the browser, `c` yanks its citation, `p` previews its
  -- metadata in a floating window. The id lives in the `[N] ` prefix of the
  -- entry text, so every action works without leaving the quickfix window.
  -- Buffer-local, set fresh on every fill.
  local qf_buf = vim.api.nvim_get_current_buf()
  local function id_under_cursor()
    local text = vim.fn.getline(".")
    return tonumber(text:match("%[(%d+)%]"))
  end
  vim.keymap.set("n", "<CR>", function()
    local id = id_under_cursor()
    if id then
      M.open_document(id)
    else
      vim.notify("No Conceptio document id on this line", vim.log.levels.WARN)
    end
  end, { buffer = qf_buf, silent = true, desc = "Conceptio: open document under cursor" })
  vim.keymap.set("n", "c", function()
    local id = id_under_cursor()
    if not id then
      vim.notify("No Conceptio document id on this line", vim.log.levels.WARN)
      return
    end
    M.yank_citation(id, "apa", function(err)
      if err then
        vim.notify(err, vim.log.levels.ERROR)
      end
    end)
  end, { buffer = qf_buf, silent = true, desc = "Conceptio: cite document under cursor" })
  vim.keymap.set("n", "p", function()
    local id = id_under_cursor()
    if not id then
      vim.notify("No Conceptio document id on this line", vim.log.levels.WARN)
      return
    end
    M.preview(id)
  end, { buffer = qf_buf, silent = true, desc = "Conceptio: preview document metadata" })
end

local function system_open(url)
  local cmd
  if vim.fn.has("win32") == 1 then
    cmd = { "cmd.exe", "/c", "start", "", url }
  elseif vim.fn.has("mac") == 1 then
    cmd = { "open", url }
  else
    cmd = { "xdg-open", url }
  end
  vim.fn.jobstart(cmd, { detach = true })
end

--- Open a document's public page in the default browser.
--- @param id number
function M.open_document(id)
  local cfg = require("conceptio").config
  local url = cfg.api_base:gsub("/$", "") .. "/document/" .. id
  system_open(url)
  vim.notify("Opening: " .. url, vim.log.levels.INFO)
end

--- Fetch a citation and yank it into the + and unnamed registers.
--- @param id number
--- @param format string  one of the 11 formats (default "apa")
--- @param cb function(err|nil)
function M.yank_citation(id, format, cb)
  local api = require("conceptio.api")
  api.cite(id, format, function(text, err)
    if err then
      cb(err)
      return
    end
    if text and text ~= "" then
      vim.fn.setreg("+", text)
      vim.fn.setreg('"', text)
      vim.notify("Conceptio cite " .. id .. " (" .. (format or "apa") .. ") yanked", vim.log.levels.INFO)
      cb(nil)
    else
      cb("No citation returned for document " .. id)
    end
  end)
end

--- Preview a document's metadata in a floating window (via `conceptio info`).
--- @param id number
function M.preview(id)
  local api = require("conceptio.api")
  api.info(id, function(data, err)
    if err then
      vim.notify(err, vim.log.levels.ERROR)
      return
    end
    if not data or not data.title then
      vim.notify("Conceptio: no metadata for document " .. id, vim.log.levels.WARN)
      return
    end
    local function first(...)
      for _, v in ipairs({ ... }) do
        if v and v ~= "" then
          return tostring(v)
        end
      end
      return ""
    end
    local meta = {
      { "Title", data.title },
      { "Author", first(data.author, "Unknown") },
      { "Source", first(data.source_label, data.source, "") },
      { "Year", first(data.year, "n.d.") },
      { "Category", first(data.category, "") },
      { "License", first(data.license, "") },
      { "Language", first(data.language, "en") },
      { "ID", tostring(data.id) },
    }
    local lines = {}
    for _, kv in ipairs(meta) do
      if kv[2] ~= "" then
        lines[#lines + 1] = kv[1] .. ": " .. kv[2]
      end
    end
    local desc = first(data.description, data.abstract, "")
    if desc ~= "" then
      lines[#lines + 1] = ""
      lines[#lines + 1] = desc:sub(1, 1400)
    end
    if data.url and data.url ~= "" then
      lines[#lines + 1] = ""
      lines[#lines + 1] = data.url
    end
    local width = math.min(90, math.max(40, vim.o.columns - 8))
    local height = math.min(#lines + 2, math.max(14, math.floor(vim.o.lines * 0.45)))
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    local win = vim.api.nvim_open_win(buf, true, {
      relative = "editor",
      width = width,
      height = height,
      col = math.max(0, math.floor((vim.o.columns - width) / 2)),
      row = math.max(0, math.floor((vim.o.lines - height) / 2)),
      style = "minimal",
      border = "rounded",
    })
    vim.api.nvim_buf_set_keymap(buf, "n", "q", "<cmd>close<CR>", { nowait = true, silent = true })
    vim.api.nvim_win_set_option(win, "wrap", true)
    vim.api.nvim_buf_set_name(buf, "conceptio-preview-" .. id)
  end)
end

return M