--- conceptio.nvim — command entrypoint.
--- Loaded once by Neovim at startup; commands defer to the lua module.

if vim.g.loaded_conceptio then
  return
end
vim.g.loaded_conceptio = 1

local conceptio = require("conceptio")

local function search_cmd(opts)
  local parts = {}
  local extra = { sources = {} }
  for _, arg in ipairs(opts.fargs) do
    local srcs = arg:match("^%-%-sources=(.+)$")
    local lic = arg:match("^%-%-license=(.+)$")
    local lim = arg:match("^%-%-limit=(%d+)$")
    if srcs then
      for part in srcs:gmatch("[^,]+") do
        extra.sources[#extra.sources + 1] = part
      end
    elseif lic then
      extra.license = lic
    elseif lim then
      extra.limit = tonumber(lim)
    else
      parts[#parts + 1] = arg
    end
  end
  local query = table.concat(parts, " ")
  if query == "" then
    vim.notify(
      "Usage: :ConceptioSearch <query> [--sources=a,b] [--license=commercial-ok] [--limit=N]",
      vim.log.levels.WARN
    )
    return
  end
  conceptio.search(query, extra)
end

vim.api.nvim_create_user_command("ConceptioSearch", search_cmd, {
  nargs = "*",
  desc = "Search Conceptio and fill the quickfix list",
})

vim.api.nvim_create_user_command("ConceptioResolve", function(opts)
  local identifier = table.concat(opts.fargs, " ")
  if identifier == "" then
    vim.notify("Usage: :ConceptioResolve <identifier>", vim.log.levels.WARN)
    return
  end
  conceptio.resolve(identifier)
end, {
  nargs = "+",
  desc = "Resolve an identifier (RFC, DOI, arXiv, citation...) into the quickfix list",
})

vim.api.nvim_create_user_command("ConceptioCite", function(opts)
  local id = tonumber(opts.fargs[1])
  local format = opts.fargs[2] or "apa"
  if not id then
    vim.notify("Usage: :ConceptioCite <doc-id> [format]", vim.log.levels.WARN)
    return
  end
  conceptio.cite(id, format)
end, {
  nargs = "+",
  desc = "Yank a citation for a document id (11 formats)",
})

vim.api.nvim_create_user_command("ConceptioOpen", function(opts)
  local id = tonumber(opts.fargs[1])
  if not id then
    vim.notify("Usage: :ConceptioOpen <doc-id>", vim.log.levels.WARN)
    return
  end
  conceptio.open(id)
end, {
  nargs = 1,
  desc = "Open a document page in the default browser",
})

vim.api.nvim_create_user_command("ConceptioPreview", function(opts)
  local id = tonumber(opts.fargs[1])
  if not id then
    vim.notify("Usage: :ConceptioPreview <doc-id>", vim.log.levels.WARN)
    return
  end
  conceptio.preview(id)
end, {
  nargs = 1,
  desc = "Preview a document's metadata in a floating window",
})

vim.api.nvim_create_user_command("ConceptioStatus", function()
  conceptio.status()
end, {
  nargs = 0,
  desc = "Show the current tier / quota via the conceptio CLI",
})