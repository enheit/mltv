-- Headless verification suite for mltv
-- Run from the repo root:
--   nvim --headless --clean --cmd "set rtp+=." -l tests/mltv_spec.lua
local uv = vim.uv or vim.loop
local results = {}
local failed = 0

local function check(name, cond, detail)
  if cond then
    table.insert(results, "PASS: " .. name)
  else
    failed = failed + 1
    table.insert(results, "FAIL: " .. name .. (detail and (" -- " .. tostring(detail)) or ""))
  end
end

local function feed(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), 'x', false)
end

local function buf_lines()
  return vim.api.nvim_buf_get_lines(0, 0, -1, false)
end

local function find_line(text)
  for i, l in ipairs(buf_lines()) do
    if l:find(text, 1, true) then
      return i, l
    end
  end
  return nil
end

-- Stub vim.ui.input
local input_answers = {}
local captured_defaults = {}
vim.ui.input = function(opts, cb)
  table.insert(captured_defaults, opts and opts.default or false)
  cb(table.remove(input_answers, 1))
end

local mltv = require('mltv')
mltv.setup({})


local root1 = vim.fn.tempname() .. "_mltv_env1"
local root2 = vim.fn.tempname() .. "_mltv_env2"
vim.fn.delete(root1, "rf")
vim.fn.delete(root2, "rf")

------------------------------------------------------------------
-- ENV 1: listing correctness, duplicate-name cursor, Empty, theme
------------------------------------------------------------------
vim.fn.mkdir(root1 .. "/a_dir/config", "p")
vim.fn.mkdir(root1 .. "/b_dir2/config", "p")
vim.fn.mkdir(root1 .. "/empty_dir", "p")
vim.fn.writefile({ "a" }, root1 .. "/a_dir/config/settings.lua")
vim.fn.writefile({ "b" }, root1 .. "/b_dir2/config/settings.lua")
vim.fn.writefile({ "x" }, root1 .. "/real.txt")
vim.fn.writefile({ "d" }, root1 .. "/file$dollar.txt")
vim.fn.writefile({ "s" }, root1 .. "/file with . dot.txt")
vim.fn.writefile({ "rc" }, root1 .. "/.bashrc")
uv.fs_symlink(root1 .. "/real.txt", root1 .. "/link_to_file")
uv.fs_symlink(root1 .. "/a_dir", root1 .. "/link_to_dir")

vim.cmd("cd " .. vim.fn.fnameescape(root1))
vim.cmd("edit " .. vim.fn.fnameescape(root1 .. "/b_dir2/config/settings.lua"))
mltv.toggle()

check("tree buffer opened", vim.bo.buftype == "nofile")
check("symlink name has no arrow", find_line("| link_to_file") ~= nil, vim.inspect(buf_lines()))
local _, ltd_line = find_line("link_to_dir")
check("symlink-to-dir shown as directory", ltd_line ~= nil and ltd_line:find("link_to_dir/", 1, true) ~= nil, ltd_line)
check("dollar filename listed", find_line("| file$dollar.txt") ~= nil)
check("space-dot-space filename listed", find_line("| file with . dot.txt") ~= nil)
check("dotfile listed", find_line("| .bashrc") ~= nil)

-- Expand the decoy path a_dir/config too, so TWO settings.lua are visible,
-- then trigger cursor repositioning via W (collapse-all) + W (restore) --
-- the exact sequence that used to jump to the first same-named entry.
local adir_line = find_line("| a_dir/")
vim.api.nvim_win_set_cursor(0, { adir_line, 0 })
feed("<CR>")
local aconfig_line = find_line("| | config/")
vim.api.nvim_win_set_cursor(0, { aconfig_line, 0 })
feed("<CR>")
feed("W")
feed("W")
local settings_lines = {}
for i, l in ipairs(buf_lines()) do
  if l:find("settings.lua", 1, true) then table.insert(settings_lines, i) end
end
check("both duplicate leaves visible", #settings_lines == 2, vim.inspect(settings_lines))
local cur = vim.api.nvim_win_get_cursor(0)[1]
check("cursor on second (b_dir2) duplicate", cur == settings_lines[2],
  "cursor=" .. cur .. " expected=" .. tostring(settings_lines[2]))

-- Empty folder placeholder
local empty_line = find_line("| empty_dir/")
vim.api.nvim_win_set_cursor(0, { empty_line, 0 })
feed("<CR>")
check("Empty placeholder shown", buf_lines()[empty_line + 1] == "| | Empty",
  vim.inspect(buf_lines()[empty_line + 1]))
vim.api.nvim_win_set_cursor(0, { empty_line + 1, 0 })
feed("<CR>")
check("Enter on placeholder collapses", buf_lines()[empty_line + 1] ~= "| | Empty")

-- Placeholder is not operable: y on it must not populate the clipboard
vim.api.nvim_win_set_cursor(0, { empty_line, 0 })
feed("<CR>") -- re-expand
vim.api.nvim_win_set_cursor(0, { empty_line + 1, 0 })
feed("y")
feed("p")   -- would paste onto placeholder; clipboard should be empty -> "Nothing to paste"
check("placeholder not copyable", vim.fn.filereadable(root1 .. "/empty_dir/2") == 0
  and vim.fn.isdirectory(root1 .. "/empty_dir/2") == 0)

-- ColorScheme change with tree open: no error, italic survives, buffer intact
local before_cs = buf_lines()
local ok_cs = pcall(vim.cmd, "colorscheme default")
check("colorscheme change ok", ok_cs)
local hl = vim.api.nvim_get_hl(0, { name = "TreeViewerEmpty" })
check("TreeViewerEmpty italic after colorscheme", hl.italic == true, vim.inspect(hl))
check("buffer unchanged by colorscheme", vim.deep_equal(before_cs, buf_lines()))

-- Unreadable directory: expanding must not crash
vim.fn.mkdir(root1 .. "/noperm")
uv.fs_chmod(root1 .. "/noperm", 0)
-- refresh the tree so noperm shows up
mltv.toggle()
vim.cmd("edit " .. vim.fn.fnameescape(root1 .. "/real.txt"))
mltv.toggle()
local noperm_line = find_line("| noperm/")
check("noperm dir listed", noperm_line ~= nil)
if noperm_line then
  vim.api.nvim_win_set_cursor(0, { noperm_line, 0 })
  local ok_exp = pcall(feed, "<CR>")
  check("expanding unreadable dir does not crash", ok_exp)
end
uv.fs_chmod(root1 .. "/noperm", 448)
mltv.toggle() -- close tree

------------------------------------------------------------------
-- ENV 2: file operations
------------------------------------------------------------------
vim.fn.mkdir(root2 .. "/foo", "p")
vim.fn.mkdir(root2 .. "/foobar", "p")
vim.fn.mkdir(root2 .. "/b_dir", "p")
vim.fn.writefile({ "i" }, root2 .. "/foo/inner.txt")
vim.fn.writefile({ "1" }, root2 .. "/one.txt")
vim.fn.writefile({ "2" }, root2 .. "/two.txt")
vim.fn.writefile({ "rc" }, root2 .. "/.bashrc")
vim.fn.writefile({ "x" }, root2 .. "/del$me.txt")
vim.fn.writefile({ "y" }, root2 .. "/del.txt")

vim.cmd("cd " .. vim.fn.fnameescape(root2))
vim.cmd("enew")
mltv.toggle()

-- Charwise visual copy of two adjacent files, paste into b_dir
local one_line = find_line("| one.txt")
vim.api.nvim_win_set_cursor(0, { one_line, 0 })
feed("vjy")
local bdir_line = find_line("| b_dir/")
vim.api.nvim_win_set_cursor(0, { bdir_line, 0 })
feed("p")
check("charwise visual copied both files",
  vim.fn.filereadable(root2 .. "/b_dir/one.txt") == 1 and vim.fn.filereadable(root2 .. "/b_dir/two.txt") == 1)

-- Cut foo, paste into sibling foobar (prefix false-positive fix)
local foo_line = find_line("| foo/")
vim.api.nvim_win_set_cursor(0, { foo_line, 0 })
feed("x")
local foobar_line = find_line("| foobar/")
vim.api.nvim_win_set_cursor(0, { foobar_line, 0 })
feed("p")
check("cut/paste into sibling with shared prefix works",
  vim.fn.filereadable(root2 .. "/foobar/foo/inner.txt") == 1 and vim.fn.isdirectory(root2 .. "/foo") == 0)

-- Recursive directory copy: y on foobar, p on b_dir
local fb_line = find_line("| foobar/")
vim.api.nvim_win_set_cursor(0, { fb_line, 0 })
feed("y")
local bd_line = find_line("| b_dir/")
vim.api.nvim_win_set_cursor(0, { bd_line, 0 })
feed("p")
check("recursive dir copy", vim.fn.filereadable(root2 .. "/b_dir/foobar/foo/inner.txt") == 1)

-- Move-into-itself is still blocked
local fb2_line = find_line("| foobar/")
vim.api.nvim_win_set_cursor(0, { fb2_line, 0 })
feed("x")
-- expand foobar to paste inside it
feed("<CR>")
local inner_target = find_line("| | foo/")
vim.api.nvim_win_set_cursor(0, { inner_target, 0 })
feed("p")
check("move dir into itself still blocked", vim.fn.isdirectory(root2 .. "/foobar") == 1
  and vim.fn.isdirectory(root2 .. "/foobar/foo/foobar") == 0)
feed("<Esc>")

-- Delete file with $ in name: right file goes, decoy stays
input_answers = { "y" }
local del_line = find_line("| del$me.txt")
vim.api.nvim_win_set_cursor(0, { del_line, 0 })
feed("d")
check("dollar file deleted (not shell-expanded)", vim.fn.filereadable(root2 .. "/del$me.txt") == 0)
check("decoy del.txt survived", vim.fn.filereadable(root2 .. "/del.txt") == 1)

-- Rename dotfile with r: default keeps full name, rename works
input_answers = { ".zshrc" }
captured_defaults = {}
local rc_line = find_line("| .bashrc")
vim.api.nvim_win_set_cursor(0, { rc_line, 0 })
feed("r")
check("dotfile rename default is full name", captured_defaults[1] == ".bashrc", vim.inspect(captured_defaults))
check("dotfile renamed", vim.fn.filereadable(root2 .. "/.zshrc") == 1 and vim.fn.filereadable(root2 .. "/.bashrc") == 0)

-- Cursor should be on the renamed file (full-path positioning)
local zsh_line = find_line("| .zshrc")
check("cursor on renamed file", zsh_line ~= nil and vim.api.nvim_win_get_cursor(0)[1] == zsh_line,
  "cursor=" .. vim.api.nvim_win_get_cursor(0)[1] .. " expected=" .. tostring(zsh_line))

-- Add a file inside a directory; cursor lands on it (full-path positioning)
input_answers = { "created.txt" }
local bd3_line = find_line("| b_dir/")
vim.api.nvim_win_set_cursor(0, { bd3_line, 0 })
feed("a")
check("file created via a", vim.fn.filereadable(root2 .. "/b_dir/created.txt") == 1)
local created_line = find_line("| | created.txt")
check("cursor on created file", created_line ~= nil and vim.api.nvim_win_get_cursor(0)[1] == created_line)

-- Add a directory
input_answers = { "newdir/" }
vim.api.nvim_win_set_cursor(0, { 1, 0 })
feed("j") -- off root line; target resolves to item's parent, root-level is fine either way
input_answers = { "newdir/" }
vim.api.nvim_win_set_cursor(0, { find_line("| del.txt"), 0 })
feed("a")
check("directory created via a", vim.fn.isdirectory(root2 .. "/newdir") == 1)

mltv.toggle() -- close tree

------------------------------------------------------------------
-- ENV 3: window lifecycle
------------------------------------------------------------------
-- q when the tree is the last window must not throw (E444)
vim.cmd("enew")
mltv.toggle()
vim.cmd("only") -- tree becomes the only window
local ok_q = pcall(feed, "q")
check("q on last window does not error", ok_q)
check("window survived with non-tree buffer", vim.bo.buftype ~= "nofile")

-- Reopen while a stale same-named buffer might exist (E95 guard):
mltv.toggle()
check("tree reopened", vim.bo.buftype == "nofile")
vim.cmd("split") -- second window onto tree buffer
feed("q")        -- toggle close: closes tree win, buffer stays visible in other window
local ok_reopen, err_reopen = pcall(mltv.toggle)
check("reopen with stale named buffer does not error", ok_reopen, err_reopen)
check("tree open after reopen", vim.bo.buftype == "nofile")
pcall(feed, "q")

------------------------------------------------------------------
-- ENV 4: dive-mode back-navigation focus (focus_item stores full_path)
------------------------------------------------------------------
vim.cmd("cd " .. vim.fn.fnameescape(root2))
vim.cmd("enew")
mltv.toggle()
feed("m") -- keep -> dive
local bdir = find_line("| b_dir/")
vim.api.nvim_win_set_cursor(0, { bdir, 0 })
feed("<CR>") -- dive into b_dir
check("dive entered b_dir", buf_lines()[1]:find("b_dir/", 1, true) ~= nil, vim.inspect(buf_lines()[1]))
feed("h") -- back to parent
local bdir_after = find_line("| b_dir/")
check("dive back focuses b_dir", bdir_after ~= nil and vim.api.nvim_win_get_cursor(0)[1] == bdir_after,
  "cursor=" .. vim.api.nvim_win_get_cursor(0)[1] .. " expected=" .. tostring(bdir_after))
feed("m") -- restore keep mode
mltv.toggle()

------------------------------------------------------------------
vim.fn.delete(root1, "rf")
vim.fn.delete(root2, "rf")

print(table.concat(results, "\n"))
print(string.format("\nSUMMARY: %d passed, %d failed", #results - failed, failed))
os.exit(failed > 0 and 1 or 0)
