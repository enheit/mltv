-- Tree viewer highlight defaults
-- Loaded automatically by Neovim

if vim.g.loaded_mltv_tree_highlights then
  return
end
vim.g.loaded_mltv_tree_highlights = 1

local function setup_highlights()
  local pmenu_sel = vim.api.nvim_get_hl(0, { name = 'PmenuSel', link = true })
  if pmenu_sel and pmenu_sel.bg then
    vim.api.nvim_set_hl(0, 'TreeViewerSelection', { link = 'PmenuSel' })
    return
  end

  vim.api.nvim_set_hl(0, 'TreeViewerSelection', { link = 'Visual' })
end

setup_highlights()
vim.api.nvim_create_autocmd('ColorScheme', {
  pattern = '*',
  callback = setup_highlights,
  desc = 'Update MLTV selection highlight on colorscheme change',
})
