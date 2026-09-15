-- Minimal init for running conceptio.nvim's headless test suite.
-- Used from the plugin root: nvim --clean -u test/init.lua -l test/run.lua [api_key]
vim.opt.runtimepath:prepend(vim.fn.getcwd())