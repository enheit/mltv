# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.1.0] - 2026-07-19

### Added

- Empty folders now show an italic *Empty* placeholder line when opened, so an
  empty folder is clearly distinguishable from a collapsed one. The new
  `TreeViewerEmpty` highlight group borrows the active colorscheme's `Comment`
  color and follows theme changes.
- Headless test suite (`tests/mltv_spec.lua`) covering listing, navigation,
  file operations, and window lifecycle.

### Changed

- All directory listing and file operations now use libuv (`vim.uv`) instead of
  shelling out to `ls`, `cp`, `mv`, `rm`, `mkdir`, and `touch`. Every action is
  faster — expanding a folder no longer spawns one process per expanded
  directory.
- Symbolic links to directories are now treated as directories and can be
  expanded; symlinks to files open their target.
- Highlights are applied with extmarks instead of the deprecated
  `nvim_buf_add_highlight` API.
- Changing the colorscheme re-links the highlight groups without re-reading the
  filesystem, and the tree only re-renders when its expansion state actually
  changed.

### Fixed

- The cursor no longer jumps to the wrong entry when two folders or files share
  a name — positioning now matches by full path everywhere, including dive-mode
  back-navigation.
- Symlinks are listed by their real name instead of `name -> target`, so
  opening and file operations on them work.
- Files with `" . "` in their name are no longer silently hidden from the tree.
- Renaming a dotfile with `r` keeps the leading dot in the basename
  (`.bashrc` no longer splits into an empty name).
- Charwise (`v`) and blockwise (`Ctrl-V`) visual selections now apply to all
  selected entries for copy, cut, and delete — previously only linewise `V`
  selections did.
- Moving a directory into a sibling whose name shares a prefix
  (`/a/foo` into `/a/foobar`) is no longer refused as "moving into itself".
- Closing the tree while it is the last window no longer raises `E444`;
  reopening after closing the window with `:q` no longer raises `E95` and no
  longer leaks stale clipboard, fold, or history state.
- The *Empty* placeholder line can no longer be yanked, cut, deleted, or
  renamed.
- Unreadable directories now report a warning instead of silently rendering as
  an empty tree.

### Security

- File names are no longer interpolated into shell command strings. Previously
  a name containing `$`, backticks, or `$(...)` could expand — or execute —
  when the file was listed, copied, moved, or deleted (an ordinary name like
  `foo$bar` could delete the wrong file). All filesystem access now goes
  through libuv APIs that take the path verbatim.

## [1.0.0] - 2025-09-05

### Added

- Initial release.

[Unreleased]: https://github.com/enheit/mltv/compare/v1.1.0...HEAD
[1.1.0]: https://github.com/enheit/mltv/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/enheit/mltv/releases/tag/v1.0.0
