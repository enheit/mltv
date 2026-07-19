local M = {}

local uv = vim.uv or vim.loop

-- Default configuration
local default_config = {
  split_command = "sp",
  buf_name = "[My Lovely Tree Viewer]",
  mode = "keep"
}

local config = {}

-- Global state
local treeviewer_buf = nil
local treeviewer_win = nil
local original_win = nil
local current_path = nil
local current_items = nil
local navigation_history = {}
local expanded_folders = {}
local saved_expanded_folders = nil
local clipboard = nil
local clipboard_mode = nil

-- Reset all per-session tree state
local function reset_state()
  treeviewer_win, treeviewer_buf, original_win = nil, nil, nil
  navigation_history = {}
  expanded_folders = {}
  saved_expanded_folders = nil
  clipboard = nil
  clipboard_mode = nil
end

-- Setup highlights
local function setup_highlights()
  -- Remove 'default' to ensure links update when themes change
  vim.cmd("highlight link TreeViewerFolder Function")
  vim.cmd("highlight link TreeViewerSlash Delimiter")
  -- Use Visual highlight for selections
  vim.cmd("highlight link TreeViewerSelection Visual")
  -- Italic marker for empty folders; borrow Comment's color but force italic
  local comment = vim.api.nvim_get_hl(0, { name = "Comment", link = false })
  vim.api.nvim_set_hl(0, "TreeViewerEmpty", { italic = true, fg = comment and comment.fg or nil })
end

-- Highlight a byte range on one line (nvim_buf_add_highlight is deprecated)
local function add_hl(buf, ns_id, group, row, start_col, end_col)
  vim.api.nvim_buf_set_extmark(buf, ns_id, row, start_col, {
    end_col = end_col,
    hl_group = group,
    strict = false
  })
end

-- List one directory level via libuv (no shell); returns sorted items, or nil if unreadable
local function list_directory(path, depth)
  local scanner = uv.fs_scandir(path)
  if not scanner then
    return nil
  end
  local items = {}
  while true do
    local name, entry_type = uv.fs_scandir_next(scanner)
    if not name then
      break
    end
    local full_path = path .. "/" .. name
    local is_dir
    if entry_type == "directory" then
      is_dir = true
    elseif entry_type == "file" then
      is_dir = false
    else
      -- Symlinks and unknown types: follow to decide file vs directory
      local stat = uv.fs_stat(full_path)
      is_dir = stat ~= nil and stat.type == "directory"
    end
    table.insert(items, {
      name = name,
      is_directory = is_dir,
      full_path = full_path,
      depth = depth or 0
    })
  end
  table.sort(items, function(a, b)
    if a.is_directory ~= b.is_directory then
      return a.is_directory
    end
    return a.name:lower() < b.name:lower()
  end)
  return items
end

-- Build the virtual placeholder item shown inside an expanded empty folder
local function make_empty_placeholder(base_path, depth)
  return {
    name = "",
    is_directory = false,
    is_placeholder = true,
    full_path = base_path .. "/.",
    depth = depth
  }
end

-- Check if an item is the virtual placeholder for an empty folder
local function is_empty_placeholder(item)
  return item.is_placeholder == true
end

-- True when child equals parent or lies underneath it
local function path_within(child, parent)
  return child == parent or child:sub(1, #parent + 1) == parent .. "/"
end

-- Function to get expanded tree structure for "keep" mode
local function get_expanded_tree(base_path, depth)
  depth = depth or 0
  local current_level_items = list_directory(base_path, depth)
  if not current_level_items then
    return nil
  end
  local items = {}
  for _, item in ipairs(current_level_items) do
    table.insert(items, item)
    if item.is_directory and expanded_folders[item.full_path] then
      local sub_items = get_expanded_tree(item.full_path, depth + 1) or {}
      if #sub_items == 0 then
        table.insert(items, make_empty_placeholder(item.full_path, depth + 1))
      else
        vim.list_extend(items, sub_items)
      end
    end
  end
  return items
end

-- Function to populate buffer with directory contents
local function populate_buffer(buf, path)
  local items
  if config.mode == "keep" then
    items = get_expanded_tree(path)
  else
    items = list_directory(path)
  end
  if not items then
    vim.notify("TreeViewer: cannot read directory: " .. path, vim.log.levels.WARN)
    items = {}
  end
  current_items = items
  current_path = path
  local lines = {}
  -- Add root folder as the first line
  local root_name = vim.fn.fnamemodify(path, ":t")
  root_name = root_name == "" and path or root_name
  table.insert(lines, root_name .. "/")
  -- Check if directory is empty and add placeholder in both modes
  if #items == 0 then
    table.insert(items, make_empty_placeholder(path, 0))
  end
  -- Shift existing items by depth +1
  for i, item in ipairs(items) do
    local indent = string.rep("| ", item.depth + 1)
    local display_name
    if is_empty_placeholder(item) then
      display_name = "Empty"
    else
      display_name = item.is_directory and (item.name .. "/") or item.name
    end
    table.insert(lines, indent .. display_name)
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  local ns_id = vim.api.nvim_create_namespace("treeviewer_highlights")
  vim.api.nvim_buf_clear_namespace(buf, ns_id, 0, -1)
  -- Highlight root folder
  add_hl(buf, ns_id, "TreeViewerFolder", 0, 0, #root_name)
  add_hl(buf, ns_id, "TreeViewerSlash", 0, #root_name, #root_name + 1)
  -- Highlight all other items
  for i, item in ipairs(items) do
    local start_col = (item.depth + 1) * 2
    if is_empty_placeholder(item) then
      add_hl(buf, ns_id, "TreeViewerEmpty", i, start_col, start_col + #"Empty")
    elseif item.is_directory then
      local end_col = start_col + #item.name
      add_hl(buf, ns_id, "TreeViewerFolder", i, start_col, end_col)
      add_hl(buf, ns_id, "TreeViewerSlash", i, end_col, end_col + 1)
    end
  end
end

-- Position the cursor on the item with the given full path
local function position_cursor_on_item(full_path)
  if not current_items then
    return false
  end
  for i, item in ipairs(current_items) do
    if item.full_path == full_path then
      vim.api.nvim_win_set_cursor(treeviewer_win, { i + 1, 0 })
      return true
    end
  end
  return false
end

-- Function to expand path to current file; returns true if new folders were expanded
local function expand_path_to_current_file()
  if not original_win or not vim.api.nvim_win_is_valid(original_win) then
    return false
  end
  local current_file_path = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(original_win))
  if current_file_path == "" then
    return false
  end
  local file_dir = vim.fn.fnamemodify(current_file_path, ":h")
  local path_parts = {}
  local temp_path = file_dir
  while temp_path ~= current_path do
    local parent = vim.fn.fnamemodify(temp_path, ":h")
    if parent == temp_path then
      break
    end
    if path_within(temp_path, current_path) then
      table.insert(path_parts, 1, temp_path)
    end
    temp_path = parent
  end
  local changed = false
  for _, path in ipairs(path_parts) do
    if not expanded_folders[path] then
      expanded_folders[path] = true
      changed = true
    end
  end
  return changed
end

-- Function to highlight current file
local function highlight_current_file()
  if not original_win or not vim.api.nvim_win_is_valid(original_win) then
    return
  end
  local current_file_path = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(original_win))
  if current_file_path == "" then
    return
  end
  if config.mode == "keep" then
    -- Repopulate only when new folders had to be expanded to reveal the file
    if expand_path_to_current_file() then
      vim.bo[treeviewer_buf].modifiable = true
      populate_buffer(treeviewer_buf, current_path)
      vim.bo[treeviewer_buf].modifiable = false
    end
  end
  position_cursor_on_item(current_file_path)
end

-- Function to get unique filename
local function get_unique_filename(target_dir, original_name)
  local full_path = target_dir .. "/" .. original_name
  if vim.fn.filereadable(full_path) == 0 and vim.fn.isdirectory(full_path) == 0 then
    return original_name
  end
  local name_without_ext = vim.fn.fnamemodify(original_name, ":r")
  local extension = vim.fn.fnamemodify(original_name, ":e")
  local counter = 2
  local new_name
  repeat
    if extension ~= "" then
      new_name = name_without_ext .. counter .. "." .. extension
    else
      new_name = name_without_ext .. counter
    end
    full_path = target_dir .. "/" .. new_name
    counter = counter + 1
  until vim.fn.filereadable(full_path) == 0 and vim.fn.isdirectory(full_path) == 0
  return new_name
end

-- Function to delete item (recursive for directories)
local function delete_item(path, is_directory)
  if is_directory then
    return vim.fn.delete(path, "rf") == 0
  end
  return vim.fn.delete(path) == 0
end

-- Recursively copy a file, directory, or symlink via libuv (no shell)
local function copy_item(source, target)
  local stat = uv.fs_lstat(source)
  if not stat then
    return false
  end
  if stat.type == "directory" then
    if not uv.fs_mkdir(target, 493) then
      return false
    end
    local scanner = uv.fs_scandir(source)
    if not scanner then
      return false
    end
    while true do
      local name = uv.fs_scandir_next(scanner)
      if not name then
        break
      end
      if not copy_item(source .. "/" .. name, target .. "/" .. name) then
        return false
      end
    end
    return true
  elseif stat.type == "link" then
    local link_target = uv.fs_readlink(source)
    return link_target ~= nil and uv.fs_symlink(link_target, target) == true
  else
    -- excl: never silently overwrite an existing target
    return uv.fs_copyfile(source, target, { excl = true }) == true
  end
end

-- Function to move item
local function move_item(source, target)
  local ok, _, err_name = uv.fs_rename(source, target)
  if ok then
    return true
  end
  if err_name == "EXDEV" then
    -- Cross-filesystem move: copy then delete
    local stat = uv.fs_lstat(source)
    if not stat then
      return false
    end
    return copy_item(source, target) and delete_item(source, stat.type == "directory")
  end
  return false
end

-- Collect items covered by the cursor or any visual selection (placeholders excluded)
local function get_selected_items(cursor_pos)
  local selected_items = {}
  local mode_char = vim.api.nvim_get_mode().mode:sub(1, 1)
  if mode_char == 'v' or mode_char == 'V' or mode_char == '\22' then
    local start_line = vim.fn.line("v")
    local end_line = cursor_pos[1]
    if start_line > end_line then
      start_line, end_line = end_line, start_line
    end
    for i = math.max(1, start_line - 1), end_line - 1 do
      if current_items and current_items[i] and not is_empty_placeholder(current_items[i]) then
        table.insert(selected_items, current_items[i])
      end
    end
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<Esc>', true, false, true), 'x', false)
  else
    local cursor_line = cursor_pos[1]
    if cursor_line > 1 and current_items and cursor_line - 1 <= #current_items then
      local item = current_items[cursor_line - 1]
      if not is_empty_placeholder(item) then
        table.insert(selected_items, item)
      end
    end
  end
  return selected_items
end

-- Function to highlight selected items
local function highlight_selected_items(items, highlight_group)
  local ns_id = vim.api.nvim_create_namespace("treeviewer_selection")
  vim.api.nvim_buf_clear_namespace(treeviewer_buf, ns_id, 0, -1)
  local index_by_path = {}
  for i, current_item in ipairs(current_items) do
    index_by_path[current_item.full_path] = i
  end
  for _, item in ipairs(items) do
    local i = index_by_path[item.full_path]
    if i then
      vim.api.nvim_buf_set_extmark(treeviewer_buf, ns_id, i, 0, {
        end_row = i + 1,
        end_col = 0,
        hl_eol = true,
        hl_group = highlight_group,
        strict = false
      })
    end
  end
end

-- Function to clear all selection highlighting
local function clear_selection_highlighting()
  local ns_id = vim.api.nvim_create_namespace("treeviewer_selection")
  vim.api.nvim_buf_clear_namespace(treeviewer_buf, ns_id, 0, -1)
end

-- Split filename into basename + extension (a dotfile's leading dot stays in the basename)
local function split_filename(name)
  local idx = name:match("^.+()%.")
  if idx and idx > 1 then
    return name:sub(1, idx - 1), name:sub(idx)
  else
    return name, ""
  end
end

-- Handle rename
local function handle_rename(include_extension)
  local cursor_line = vim.api.nvim_win_get_cursor(treeviewer_win)[1]
  if cursor_line <= 1 or not current_items or cursor_line - 1 > #current_items then
    return
  end
  local selected_item = current_items[cursor_line - 1]
  if is_empty_placeholder(selected_item) then
    return
  end
  local target_dir = vim.fn.fnamemodify(selected_item.full_path, ":h")
  local basename, extension = split_filename(selected_item.name)
  local default_input = include_extension and (basename .. extension) or basename
  vim.ui.input({
    prompt = "Rename: ",
    default = default_input,
  }, function(input)
    if not input or vim.trim(input) == "" then
      print("Rename cancelled")
      return
    end
    input = vim.trim(input)
    if not include_extension then
      input = input .. extension
    end
    if input == selected_item.name then
      print("Name unchanged")
      return
    end
    if input:match("[/\\<>:\"|?*]") then
      print("Invalid characters in name")
      return
    end
    local new_path = target_dir .. "/" .. input
    if vim.fn.filereadable(new_path) == 1 or vim.fn.isdirectory(new_path) == 1 then
      print("A file or folder with that name already exists")
      return
    end
    if move_item(selected_item.full_path, new_path) then
      print("Renamed to: " .. input)
      vim.bo[treeviewer_buf].modifiable = true
      populate_buffer(treeviewer_buf, current_path)
      vim.bo[treeviewer_buf].modifiable = false
      position_cursor_on_item(new_path)
    else
      print("Failed to rename " .. selected_item.name)
    end
    if treeviewer_win and vim.api.nvim_win_is_valid(treeviewer_win) then
      vim.api.nvim_set_current_win(treeviewer_win)
    end
  end)
end

-- Handle copy (y)
local function handle_copy()
  local cursor_pos = vim.api.nvim_win_get_cursor(treeviewer_win)
  local selected_items = get_selected_items(cursor_pos)
  vim.api.nvim_win_set_cursor(treeviewer_win, cursor_pos)
  if #selected_items == 0 then
    print("No items selected")
    return
  end
  clipboard = selected_items
  clipboard_mode = "copy"
  clear_selection_highlighting()
  if #selected_items == 1 then
    local item_type = selected_items[1].is_directory and "folder" or "file"
    print("Copied " .. item_type .. ": " .. selected_items[1].name)
  else
    print("Copied " .. #selected_items .. " items")
  end
end

-- Handle cut (x)
local function handle_cut()
  local cursor_pos = vim.api.nvim_win_get_cursor(treeviewer_win)
  local selected_items = get_selected_items(cursor_pos)
  vim.api.nvim_win_set_cursor(treeviewer_win, cursor_pos)
  if #selected_items == 0 then
    print("No items selected")
    return
  end
  clipboard = selected_items
  clipboard_mode = "cut"
  highlight_selected_items(selected_items, "TreeViewerSelection")
  if #selected_items == 1 then
    local item_type = selected_items[1].is_directory and "folder" or "file"
    print("Cut " .. item_type .. ": " .. selected_items[1].name)
  else
    print("Cut " .. #selected_items .. " items")
  end
end

-- Handle paste (p)
local function handle_paste()
  if not clipboard or not clipboard_mode or #clipboard == 0 then
    print("Nothing to paste")
    return
  end
  local cursor_line = vim.api.nvim_win_get_cursor(treeviewer_win)[1]
  if cursor_line <= 1 or not current_items or cursor_line - 1 > #current_items then
    return
  end
  local selected_item = current_items[cursor_line - 1]
  local target_dir
  if selected_item.is_directory then
    target_dir = selected_item.full_path
  else
    target_dir = vim.fn.fnamemodify(selected_item.full_path, ":h")
  end
  local successful_operations = 0
  local failed_operations = 0
  for _, clipboard_item in ipairs(clipboard) do
    if clipboard_mode == "cut" then
      local current_dir = vim.fn.fnamemodify(clipboard_item.full_path, ":h")
      if current_dir == target_dir then
        print("Cannot move " .. clipboard_item.name .. " to same location")
        failed_operations = failed_operations + 1
        goto continue
      end
      if clipboard_item.is_directory and path_within(target_dir, clipboard_item.full_path) then
        print("Cannot move directory " .. clipboard_item.name .. " into itself")
        failed_operations = failed_operations + 1
        goto continue
      end
    end
    local new_name = get_unique_filename(target_dir, clipboard_item.name)
    local target_path = target_dir .. "/" .. new_name
    local success = false
    if clipboard_mode == "copy" then
      success = copy_item(clipboard_item.full_path, target_path)
    else
      success = move_item(clipboard_item.full_path, target_path)
    end
    if success then
      successful_operations = successful_operations + 1
    else
      failed_operations = failed_operations + 1
    end
    ::continue::
  end
  if successful_operations > 0 then
    local action = clipboard_mode == "copy" and "Pasted" or "Moved"
    print(action .. " " .. successful_operations .. " items")
  end
  if failed_operations > 0 then
    print("Failed: " .. failed_operations .. " items")
  end
  clipboard = nil
  clipboard_mode = nil
  clear_selection_highlighting()
  vim.bo[treeviewer_buf].modifiable = true
  if config.mode == "keep" and selected_item.is_directory then
    expanded_folders[selected_item.full_path] = true
  end
  populate_buffer(treeviewer_buf, current_path)
  vim.bo[treeviewer_buf].modifiable = false
end

-- Handle add
local function handle_add()
  local cursor_line = vim.api.nvim_win_get_cursor(treeviewer_win)[1]
  local target_dir
  if cursor_line <= 1 or not current_items or cursor_line - 1 > #current_items then
    target_dir = current_path
  else
    local selected_item = current_items[cursor_line - 1]
    if selected_item.is_directory then
      target_dir = selected_item.full_path
    else
      target_dir = vim.fn.fnamemodify(selected_item.full_path, ":h")
    end
  end
  local prompt = "Enter name (end with / for directory): "
  vim.ui.input({
    prompt = prompt
  }, function(input)
    if not input or input:gsub("%s+", "") == "" then
      print("Creation cancelled")
      return
    end
    input = vim.trim(input)
    local is_directory = input:sub(-1) == "/"
    local item_name = is_directory and input:sub(1, -2) or input
    if item_name == "" then
      print("Invalid name")
      return
    end
    if item_name:match("[/\\<>:\"|?*]") then
      print("Invalid characters in name")
      return
    end
    local target_path = target_dir .. "/" .. item_name
    local success = false
    local item_type = is_directory and "directory" or "file"
    if vim.fn.filereadable(target_path) == 1 or vim.fn.isdirectory(target_path) == 1 then
      print(item_type:gsub("^%l", string.upper) .. " already exists: " .. item_name)
      return
    end
    if is_directory then
      success = uv.fs_mkdir(target_path, 493) == true
    else
      local fd = uv.fs_open(target_path, "a", 420)
      if fd then
        uv.fs_close(fd)
        success = true
      end
    end
    if success then
      print("Created " .. item_type .. ": " .. item_name)
      vim.bo[treeviewer_buf].modifiable = true
      if config.mode == "keep" then
        if cursor_line > 1 and current_items and cursor_line - 1 <= #current_items then
          local selected_item = current_items[cursor_line - 1]
          if selected_item.is_directory then
            expanded_folders[selected_item.full_path] = true
          end
        end
        if is_directory then
          expanded_folders[target_path] = nil
        end
      end
      populate_buffer(treeviewer_buf, current_path)
      vim.bo[treeviewer_buf].modifiable = false
      position_cursor_on_item(target_path)
    else
      print("Failed to create " .. item_type .. ": " .. item_name)
    end
    if treeviewer_win and vim.api.nvim_win_is_valid(treeviewer_win) then
      vim.api.nvim_set_current_win(treeviewer_win)
    end
  end)
end

local function collapse_if_empty(folder_path)
  if not expanded_folders[folder_path] then
    return
  end
  local scanner = uv.fs_scandir(folder_path)
  if not scanner then
    -- Folder is gone or unreadable; drop its expanded state
    expanded_folders[folder_path] = nil
    return
  end
  if not uv.fs_scandir_next(scanner) then
    expanded_folders[folder_path] = nil
  end
end

-- Perform deletion function
local function perform_deletion(selected_items, cursor_pos)
  if #selected_items == 0 then
    print("No items selected")
    return
  end
  clear_selection_highlighting()
  local prompt
  if #selected_items == 1 then
    local item_type = selected_items[1].is_directory and "folder" or "file"
    prompt = string.format("Remove %s '%s'? [y/N]: ", item_type, selected_items[1].name)
  else
    prompt = string.format("Remove %d selected items? [y/N]: ", #selected_items)
  end
  vim.ui.input({ prompt = prompt }, function(input)
    if not input then
      print("Deletion cancelled")
      if treeviewer_win and vim.api.nvim_win_is_valid(treeviewer_win) then
        vim.api.nvim_set_current_win(treeviewer_win)
      end
      return
    end
    input = input:lower():gsub("%s+", "")
    if input == "y" or input == "yes" then
      local successful_deletions = 0
      local failed_deletions = 0
      local parent_folders_to_check = {}
      for _, item in ipairs(selected_items) do
        if delete_item(item.full_path, item.is_directory) then
          successful_deletions = successful_deletions + 1
          local parent_dir = vim.fn.fnamemodify(item.full_path, ":h")
          parent_folders_to_check[parent_dir] = true
        else
          failed_deletions = failed_deletions + 1
          print("Failed to remove: " .. item.name)
        end
      end
      for parent_dir, _ in pairs(parent_folders_to_check) do
        collapse_if_empty(parent_dir)
      end
      if successful_deletions > 0 then
        if #selected_items == 1 then
          local item_type = selected_items[1].is_directory and "folder" or "file"
          print("Removed " .. item_type .. ": " .. selected_items[1].name)
        else
          print("Removed " .. successful_deletions .. " items")
        end
      end
      if failed_deletions > 0 then
        print("Failed to remove " .. failed_deletions .. " items")
      end
      if treeviewer_buf and vim.api.nvim_buf_is_valid(treeviewer_buf) then
        vim.bo[treeviewer_buf].modifiable = true
        populate_buffer(treeviewer_buf, current_path)
        vim.bo[treeviewer_buf].modifiable = false
        if cursor_pos and current_items then
          local new_cursor_line = math.min(cursor_pos[1], #current_items + 1)
          if new_cursor_line > 1 and treeviewer_win and vim.api.nvim_win_is_valid(treeviewer_win) then
            vim.api.nvim_win_set_cursor(treeviewer_win, { new_cursor_line, 0 })
          end
        end
      end
    else
      print("Deletion cancelled")
    end
    if treeviewer_win and vim.api.nvim_win_is_valid(treeviewer_win) then
      vim.api.nvim_set_current_win(treeviewer_win)
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<Esc>', true, false, true), 'n', true)
    end
  end)
end

local function handle_delete()
  local cursor_pos = vim.api.nvim_win_get_cursor(treeviewer_win)
  local selected_items = get_selected_items(cursor_pos)
  perform_deletion(selected_items, cursor_pos)
end

local function handle_enter()
  local cursor_line = vim.api.nvim_win_get_cursor(treeviewer_win)[1]
  if cursor_line <= 1 then
    return
  end
  if not current_items or cursor_line - 1 > #current_items then
    return
  end
  local selected_item = current_items[cursor_line - 1]
  -- Handle empty folder dummy item
  if is_empty_placeholder(selected_item) then
    if config.mode == "dive" then
      if not current_path then
        return
      end
      local parent_path = vim.fn.fnamemodify(current_path, ":h")
      if parent_path == current_path then
        return
      end
      vim.bo[treeviewer_buf].modifiable = true
      populate_buffer(treeviewer_buf, parent_path)
      vim.bo[treeviewer_buf].modifiable = false
      if #navigation_history > 0 then
        local last_location = table.remove(navigation_history)
        if last_location.path == parent_path then
          position_cursor_on_item(last_location.focus_item)
        else
          highlight_current_file()
        end
      else
        highlight_current_file()
      end
    else
      local parent_path = selected_item.full_path:gsub("/%.$", "")
      expanded_folders[parent_path] = nil
      vim.bo[treeviewer_buf].modifiable = true
      populate_buffer(treeviewer_buf, current_path)
      vim.bo[treeviewer_buf].modifiable = false
      position_cursor_on_item(parent_path)
    end
    return
  end
  if selected_item.is_directory then
    if config.mode == "dive" then
      table.insert(navigation_history, {
        path = current_path,
        focus_item = selected_item.full_path
      })
      vim.bo[treeviewer_buf].modifiable = true
      populate_buffer(treeviewer_buf, selected_item.full_path)
      vim.bo[treeviewer_buf].modifiable = false
    else
      if expanded_folders[selected_item.full_path] then
        expanded_folders[selected_item.full_path] = nil
      else
        expanded_folders[selected_item.full_path] = true
      end
      vim.bo[treeviewer_buf].modifiable = true
      populate_buffer(treeviewer_buf, current_path)
      vim.bo[treeviewer_buf].modifiable = false
      position_cursor_on_item(selected_item.full_path)
    end
  else
    if original_win and vim.api.nvim_win_is_valid(original_win) then
      vim.api.nvim_set_current_win(original_win)
      vim.cmd("edit " .. vim.fn.fnameescape(selected_item.full_path))
      if treeviewer_win and vim.api.nvim_win_is_valid(treeviewer_win) then
        pcall(vim.api.nvim_win_close, treeviewer_win, true)
      end
    elseif treeviewer_win and vim.api.nvim_win_is_valid(treeviewer_win) then
      -- No other window to open into: open the file in the tree window itself,
      -- restoring the window-local options the tree overrode
      vim.api.nvim_set_current_win(treeviewer_win)
      vim.wo[treeviewer_win].cursorline = vim.o.cursorline
      vim.wo[treeviewer_win].number = vim.o.number
      vim.wo[treeviewer_win].relativenumber = vim.o.relativenumber
      vim.cmd("edit " .. vim.fn.fnameescape(selected_item.full_path))
    end
    reset_state()
  end
end

local function handle_l()
  handle_enter()
end

local function handle_h()
  if config.mode == "dive" then
    if not current_path then
      return
    end
    local parent_path = vim.fn.fnamemodify(current_path, ":h")
    if parent_path == current_path then
      return
    end
    vim.bo[treeviewer_buf].modifiable = true
    populate_buffer(treeviewer_buf, parent_path)
    vim.bo[treeviewer_buf].modifiable = false
    if #navigation_history > 0 then
      local last_location = table.remove(navigation_history)
      if last_location.path == parent_path then
        position_cursor_on_item(last_location.focus_item)
      else
        highlight_current_file()
      end
    else
      highlight_current_file()
    end
  else
    local cursor_line = vim.api.nvim_win_get_cursor(treeviewer_win)[1]
    if cursor_line <= 1 or not current_items or cursor_line - 1 > #current_items then
      return
    end
    local selected_item = current_items[cursor_line - 1]
    if selected_item.is_directory and expanded_folders[selected_item.full_path] then
      expanded_folders[selected_item.full_path] = nil
      vim.bo[treeviewer_buf].modifiable = true
      populate_buffer(treeviewer_buf, current_path)
      vim.bo[treeviewer_buf].modifiable = false
      position_cursor_on_item(selected_item.full_path)
    end
  end
end

function M.toggle_mode()
  config.mode = config.mode == "dive" and "keep" or "dive"
  navigation_history = {}
  expanded_folders = {}
  saved_expanded_folders = nil
  if treeviewer_buf and vim.api.nvim_buf_is_valid(treeviewer_buf) then
    vim.bo[treeviewer_buf].modifiable = true
    populate_buffer(treeviewer_buf, current_path)
    vim.bo[treeviewer_buf].modifiable = false
    highlight_current_file()
  end
  print("TreeViewer mode: " .. config.mode)
end

function M.toggle_collapse_all()
  if not treeviewer_buf or not vim.api.nvim_buf_is_valid(treeviewer_buf) then
    return
  end

  if saved_expanded_folders then
    -- Restore previously expanded folders
    expanded_folders = saved_expanded_folders
    saved_expanded_folders = nil
    print("Expanded all folders")
  else
    -- Save current state and collapse all
    saved_expanded_folders = vim.deepcopy(expanded_folders)
    expanded_folders = {}
    print("Collapsed all folders")
  end

  -- Refresh the buffer
  vim.bo[treeviewer_buf].modifiable = true
  populate_buffer(treeviewer_buf, current_path)
  vim.bo[treeviewer_buf].modifiable = false
  highlight_current_file()
end

local function setup_keymaps(buf)
  vim.keymap.set('n', '<CR>', handle_enter, { buffer = buf, silent = true })
  vim.keymap.set('n', 'l', handle_l, { buffer = buf, silent = true })
  vim.keymap.set('n', 'h', handle_h, { buffer = buf, silent = true })
  vim.keymap.set('n', 'm', function()
    M.toggle_mode()
  end, { buffer = buf, silent = true })
  vim.keymap.set('n', 'W', function()
    M.toggle_collapse_all()
  end, { buffer = buf, silent = true })
  vim.keymap.set({ 'n', 'v' }, 'y', handle_copy, { buffer = buf, silent = true })
  vim.keymap.set({ 'n', 'v' }, 'x', handle_cut, { buffer = buf, silent = true })
  vim.keymap.set('n', 'p', handle_paste, { buffer = buf, silent = true })
  vim.keymap.set({ 'n', 'v' }, 'd', handle_delete, { buffer = buf, silent = true })
  vim.keymap.set('n', 'a', handle_add, { buffer = buf, silent = true })
  vim.keymap.set('n', 'r', function() handle_rename(false) end, { buffer = buf, silent = true })
  vim.keymap.set('n', 'R', function() handle_rename(true) end, { buffer = buf, silent = true })
  vim.keymap.set('n', 'q', function() M.toggle() end, { buffer = buf, silent = true })
  vim.keymap.set('n', '<Esc>', function()
    clipboard = nil
    clipboard_mode = nil
    clear_selection_highlighting()
    print("Selection cleared")
  end, { buffer = buf, silent = true })
end

local function create_treeviewer()
  -- Refresh highlights to pick up current theme
  setup_highlights()
  -- Clear any state left behind by an external close (:q on the tree window)
  reset_state()
  original_win = vim.api.nvim_get_current_win()
  local cwd = vim.fn.getcwd()
  treeviewer_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[treeviewer_buf].modifiable = false
  vim.bo[treeviewer_buf].buftype = 'nofile'
  vim.bo[treeviewer_buf].bufhidden = 'wipe'
  -- A stale buffer may still own this name (e.g. tree split into two windows); don't error
  pcall(vim.api.nvim_buf_set_name, treeviewer_buf, config.buf_name)
  vim.cmd(config.split_command)
  treeviewer_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(treeviewer_win, treeviewer_buf)
  vim.bo[treeviewer_buf].modifiable = true
  populate_buffer(treeviewer_buf, cwd)
  expanded_folders[cwd] = true
  vim.bo[treeviewer_buf].modifiable = false
  vim.wo[treeviewer_win].cursorline = true
  vim.wo[treeviewer_win].number = false
  vim.wo[treeviewer_win].relativenumber = false
  setup_keymaps(treeviewer_buf)
  highlight_current_file()
end

function M.toggle()
  if treeviewer_win and vim.api.nvim_win_is_valid(treeviewer_win) then
    if not pcall(vim.api.nvim_win_close, treeviewer_win, true) then
      -- Last window on the tabpage: replace the tree with an empty buffer instead
      vim.api.nvim_win_call(treeviewer_win, function()
        vim.cmd("enew")
      end)
    end
    reset_state()
  else
    create_treeviewer()
  end
end

function M.setup(user_config)
  config = vim.tbl_deep_extend("force", default_config, user_config or {})
  setup_highlights()

  -- Refresh highlights when colorscheme changes; existing extmarks reference the
  -- groups by name, so re-linking alone recolors the open tree — no repopulate needed
  vim.api.nvim_create_autocmd("ColorScheme", {
    pattern = "*",
    callback = setup_highlights,
    desc = "Update MLTV highlights when colorscheme changes"
  })
end

return M
