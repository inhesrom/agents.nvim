if vim.g.loaded_agents_nvim == 1 then
  return
end

vim.g.loaded_agents_nvim = 1

require("agents").setup()
