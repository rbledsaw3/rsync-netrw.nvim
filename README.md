# rsync-netrw.nvim

Mark files in **netrw** and upload them with **rsync over SSH**.
Pure Lua. Minimal UI. No netrw internals poked.

## Features
- `mm` toggle mark on the current netrw entry (shows a green dot at EOL)
- `mu` / `:RsyncUpload` uploads all marked files with `rsync`
- `mU` / `:RsyncUploadRemove` uploads all marked files with `rsync --remove-source-files`
- `mC` / `:RsyncClearMarks` clears all marks
- `:RsyncSetDestination user@host:/path` sets the remote destination for this session
- Floating terminal shows `rsync` progress

## Requirements
- Neovim 0.8+
- `rsync` and `ssh` in PATH

## Install (lazy.nvim / LazyVim)

```lua
{
  "yourname/rsync-netrw.nvim",
  ft = "netrw",
  opts = {
    dest = "destination_user@destination_ip:/path/to/destination", -- placeholder
    rsync_flags = { "-avhP", "--progress" },
    -- ssh = { "-i", "~/.ssh/id_ed25519" }, -- set only if you need custom ssh args; otherwise rsync uses ssh by default
    use_relative = false,
    extra = {},
    keymaps = true,
  },
  keys = {
    { "mm", function() require("rsync_netrw").toggle_mark() end, ft = "netrw", desc = "Rsync: toggle mark" },
    { "mC", function() require("rsync_netrw").clear_marks() end,  ft = "netrw", desc = "Rsync: clear marks" },
    { "mu", function() require("rsync_netrw").upload_marked() end, ft = "netrw", desc = "Rsync: upload marked" },
    { "mU", function() require("rsync_netrw").upload_marked_remove() end, ft = "netrw", desc = "Rsync: Upload and remove source files" },
  },
}
```
If you use LazyVim, drop that spec in `~/.config/nvim/lua/plugins/rsync_netrw.lua`.

## Usage

1. `:Ex` to open netrw.
2. `mm` to mark entries.
3. `:RsyncSetDestination user@host:/path` once per session.
4. `mu` (or `:RsyncUpload`) to send the marked files.
5. `mU` (or `:RsyncUploadRemove`) to send the marked files and delete from source afterwards.

If the destination is still the placeholder, the plugin will error and prompt you to run `:RsyncSetDestination`.

## Options

- `dest` - remote target, e.g. `user@host:/srv/backup` (required; can be set at runtime)
- `rsync_flags` - defaults `{ "-avhP", "--progress" }`
- `ssh` - optional list of extra ssh args; if set, we pass `-e 'ssh ...'`
- `use_relative` - if `true`, adds `--relative` to preserve path portions
- `extra` - additional rsync args, e.g. `{ "--delete-after" }`
- `keymaps` - install the default netrw keymaps (`mm`/`mC`/`mu`/`mU`)

## License

MIT
