# MLTV - My Lovely Tree Viewer

A simple and elegant file tree viewer for Neovim, built with love and simplicity in mind.

## Installation

### Using vim-pack
```lua
vim.pack.add({
  -- ... Your other plugins
  { src = "https://github.com/enheit/mltv" },
})

require("mltv").setup()

vim.keymap.set('n', '<leader>e', ':MLTVToggle<CR>', { noremap = true, silent = true })
```

### Using lazy.nvim
```lua
{
  'enheit/mltv',
  config = function()
    require('mltv').setup()
  end
}
```

### Using packer.nvim

```lua
use {
  'yourusername/mltv',
  config = function()
    require('mltv').setup()
  end
}
```


### Using vim-plug

```
Plug 'enheit/mltv'
```
Then add to your `init.lua`:

```lua
require('mltv').setup()
```

## Configuration

```lua
require('mltv').setup({
  split_command = "sp",        -- "sp" for horizontal, "vsp" for vertical split
  buf_name = "[My Lovely Tree Viewer]",
  mode = "dive",               -- "dive" or "keep" mode
})
```

Mode Configuration
- Dive Mode (default): Navigate into directories. Shows one directory at a time. Use `h` to go back to parent directory. Great for focused navigation.  
- Keep Mode: Folders expand/collapse in place. See full tree structure. Navigate with `h`/`l` to collapse/expand. Better for overview.

## Usage
### Commands

| Key         | Action                                           |
|-------------|--------------------------------------------------|
| `Enter` / `l` | Enter directory / Open file                      |
| `h`         | Go back (dive mode) / Collapse folder (keep mode) |
| `q`         | Close tree viewer                                |
| `y`         | Copy file/folder (works with visual selection)  |
| `x`         | Cut file/folder (works with visual selection)   |
| `p`         | Paste                                            |
| `d`         | Delete file/folder (works with visual selection) |
| `a`         | Create new file/folder (end name with / for folder) |
| `r`         | Rename (basename only)                           |
| `R`         | Rename (including extension)                     |
| `Esc`       | Clear selection/clipboard                        |

:MLTVToggle - Open/close the tree viewer

### Visual Selection

1. Enter visual line mode with V
2. Select multiple files/folders
3. Use y (copy), x (cut), or d (delete) on selection


### Example setup
```lua
-- Basic setup
require('mltv').setup()

-- Custom setup
require('mltv').setup({
  split_command = "vsp",  -- Vertical split
  mode = "keep",          -- Start in keep mode
  buf_name = "[Files]",   -- Custom buffer name
})

-- Optional: Add a keymap to toggle
vim.keymap.set('n', '<leader>e', '<cmd>MLTVToggle<cr>', { desc = 'Toggle file tree' })
```

## Tips

- Use visual mode (V) to select multiple files for batch operations
- Files ending with / in the create prompt will be created as directories
- Empty directories show a | indicator
- Cut files are highlighted until pasted or cleared with Esc
- In dive mode, press `Enter` or `l` on the | indicator to go back
- In keep mode, press `Enter` or `l` on the | indicator to collapse the folder

## Motivation
I wanted the simplicity of Neovim's built-in `netrw` but with intuitive commands that actually make sense. Instead of memorizing obscure keybindings, MLTV uses familiar vim motions (h/l for navigation) and standard operations (y/x/p/d for copy/cut/paste/delete).

## License
MIT License
