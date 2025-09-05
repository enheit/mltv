-- Prevent loading the plugin twice
if vim.g.loaded_mltv == 1 then
  return
end
vim.g.loaded_mltv = 1

-- Create user commands
vim.api.nvim_create_user_command('MLTVToggle', function()
  require('mltv').toggle()
end, { desc = 'Toggle My Lovely Tree Viewer' })

