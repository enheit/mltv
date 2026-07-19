---
name: verify
description: Runtime verification recipe for the mltv Neovim tree-viewer plugin — how to launch, drive, and capture evidence.
---

# Verifying mltv at runtime

mltv is a Neovim TUI plugin; the surface is a live nvim instance driven by keystrokes.

## Launch (remote-driven, no tmux needed)

```bash
nvim --headless --clean --cmd "set rtp+=<repo>" --listen /tmp/mltv.sock <some-file> &
nvim --server /tmp/mltv.sock --remote-send ':lua require("mltv").setup({})<CR>'
nvim --server /tmp/mltv.sock --remote-send ':MLTVToggle<CR>'
```

- `--remote-send` injects through the real input/mapping machinery — equivalent to typing.
- **Gotcha:** `MLTVToggle` errors ("Invalid 'src'") unless `setup()` ran first — under `--clean` you must call it yourself.
- `vim.ui.input` prompts (rename/add/delete confirm) work headless: answer with a follow-up `--remote-send`, e.g. `'y<CR>'` or `'<C-u>newname<CR>'` (C-u clears the prompt default).

## Capture evidence

```bash
nvim --server /tmp/mltv.sock --remote-expr 'join(getline(1,"$"),"\n")'   # tree buffer
nvim --server /tmp/mltv.sock --remote-expr 'line(".") . " " . getline(".")'  # cursor
nvim --server /tmp/mltv.sock --remote-expr 'execute("messages")'          # cmdline msgs
nvim --server /tmp/mltv.sock --remote-expr 'luaeval("vim.inspect(vim.api.nvim_get_hl(0,{name=\"TreeViewerEmpty\"}))")'
```

`v:errmsg` is sticky — clear or compare text before attributing an error to the step you just ran.

## Flows worth driving

- Tree open positions cursor on the current file (keep mode auto-expands its path).
- Duplicate names: expand two same-named subtrees, press `W W` — cursor must return to the *current file's* copy, not the first name match.
- Empty folder: `<CR>` on an empty dir shows italic `| | Empty`; `<CR>` on it collapses.
- Hostile filenames: create `file$dollar.txt` + decoy `file.txt`, delete the former (`d`, answer `y`) — decoy must survive.
- Symlinks: link-to-dir must list as `name/` (no ` -> target`) and expand.
- Lifecycle: `:only` then `q` (last window must not E444); reopen with `:MLTVToggle`.

## Batch suite

A fuller scripted suite pattern (stubs `vim.ui.input`, drives buffer-local keymaps
via `feedkeys(keys, 'x')`) runs as:
`nvim --headless --clean --cmd "set rtp+=<repo>" -l test.lua`
Assert on `nvim_buf_get_lines` + filesystem state; end with `os.exit(failed > 0 and 1 or 0)`.
