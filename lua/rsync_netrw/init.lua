local M = {}

-- ===== State =====
local ns = vim.api.nvim_create_namespace("RsyncNetrwMarks")
local marks = {}            -- set of absolute paths: marks[path] = true
local marks_by_buf = {}     -- buf -> { [line]=extmark_id }
local cfg = {
    dest = "destination_user@destination_host:/path/to/destination/",   -- REQUIRED: change me
    ssh = {},                                   -- ssh args for rsync -e 'ssh <args...>'
    rsync_flags = { "-avhP", "--progress" },    -- default rsync flags
    use_relative = false,                       -- if true, pass --relative to rsync
    extra = {},                                 -- extra rsync flags
    keymaps = true,                             -- whether to set keymaps
}

-- ===== Utils =====
local function shell_quote(str)
    if not str or str == "" then return "" end
    return "'" .. tostring(str):gsub("'", [["'"']]) .. "'"
end

local function has_flag(flags, want)
    for _, f in ipairs(flags or {}) do
        if f == want then return true end
    end
    return false
end

local function normalize_path(path)
    if not path or path == "" then return nil end
    if vim.fn.isdirectory(path) == 1 then
        return (path:gsub("/+$", ""))
    end
    return path
end

local function is_dir_empty(path)
    local fs = vim.loop
    local req = fs.fs_scandir(path)
    if not req then return true end
    while true do
        local name, _ = fs.fs_scandir_next(req)
        if not name then break end
        if name ~= "." and name ~= ".." then return false end
    end
    return true
end

local function cleanup_empty_dirs(dirs)
    if not dirs or #dirs == 0 then return end
    table.sort(dirs, function(a, b) return #a > #b end)
    local removed = {}
    for _, d in ipairs(dirs) do
        if vim.fn.isdirectory(d) == 1 and is_dir_empty(d) then
            local ok = pcall(vim.loop.fs_rmdir, d)
            if ok then table.insert(removed, d) end
        end
    end
    if #removed > 0 then
        vim.notify("Removed empty directories:\n" .. table.concat(removed, "\n"), vim.log.levels.INFO)
    end
end

local function in_netrw()
    return vim.bo.filetype == "netrw" and vim.b.netrw_curdir ~= nil
end

local function current_path()
    if not in_netrw() then return nil end
    local dir = vim.b.netrw_curdir or ""
    local saved = vim.o.isfname
    vim.o.isfname = saved .. ",32,38,40,41,44,59,61,91,93,123,125"
    local ok, name = pcall(vim.fn.expand, "<cfile>")
    vim.o.isfname = saved
    if not ok or not name or name == "" or name == "." or name == ".." then return nil end
    return vim.fn.fnamemodify(dir .. "/" .. name, ":p")
end

local function ensure_buf_table(buf)
    if not marks_by_buf[buf] then marks_by_buf[buf] = {} end
    return marks_by_buf[buf]
end

local function add_mark_visual(buf, line_nr)
    local ok = pcall(vim.api.nvim_get_hl, 0, { name = "DiagnosticOk", link = false })
    local group = ok and "DiagnosticOk" or "DiffAdded"
    local vt = { { " ●", group } } -- eol dot (green)
    return vim.api.nvim_buf_set_extmark(buf, ns, line_nr - 1, -1, {
        virt_text = vt,
        virt_text_pos = "eol",
        hl_mode = "combine",
    })
end

local function ensure_dest()
    if not cfg.dest
        or cfg.dest == ""
        or cfg.dest == "destination_user@destination_host:/path/to/destination/" then
        vim.notify("Rsync destination not set! Use :RsyncSetDestination", vim.log.levels.ERROR)
        return false
    end
    return true
end

local function clear_all_visual(buf)
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    marks_by_buf[buf] = {}
end

-- ===== Public actions =====

local function build_cmd(paths)
    if vim.fn.executable("rsync") ~= 1 then
        vim.notify("rsync executable not found in PATH", vim.log.levels.ERROR)
        return ""
    end
    local parts = { "rsync" }
    local norm_flags = {}
    for _, f in ipairs(cfg.rsync_flags or {}) do
        if f ~= nil and f ~= "" then
            if f:sub(1,1) ~= "-" then f = "-" .. f end
            table.insert(norm_flags, f)
        end
    end

    local needs_r = false
    for _, p in ipairs(paths) do
        if vim.fn.isdirectory(p) == 1 then needs_r = true; break end
    end
    if needs_r and not (has_flag(norm_flags, "-a") or has_flag(norm_flags, "-r")) then
        table.insert(norm_flags, "-r")
    end

    for _, f in ipairs(norm_flags) do table.insert(parts, f) end
    if cfg.use_relative then table.insert(parts, "--relative") end
    for _, x in ipairs(cfg.extra or {}) do
        if x ~= nil and x ~= "" then
            if x:sub(1,1) == "-" then table.insert(parts, x) else table.insert(parts, shell_quote(x)) end
        end
    end

    if cfg.ssh and #cfg.ssh > 0 then
        local ssh_join = "ssh"
        for _, s in ipairs(cfg.ssh) do
            ssh_join = ssh_join .. " " .. vim.fn.shellescape(s)
        end
        table.insert(parts, "-e")
        table.insert(parts, shell_quote(ssh_join))
    end

    for _, p in ipairs(paths) do
        p = normalize_path(p)
        if p and p ~= "" then
            table.insert(parts, shell_quote(p))
        end
    end
    table.insert(parts, shell_quote(cfg.dest))
    return table.concat(parts, " ")
end

local function open_float_term(cmd, on_success)
    if not cmd or cmd == "" then
        vim.notify("No command to run", vim.log.levels.ERROR)
        return
    end
    local width = math.floor(vim.o.columns * 0.9)
    local height = math.floor(vim.o.lines * 0.8)
    local row = math.floor((vim.o.lines - height) / 2)
    local col = math.floor((vim.o.columns - width) / 2)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_open_win(buf, true, {
        relative = "editor",
        row = row, col = col, width = width, height = height,
        style = "minimal", border = "rounded",
        title = " rsync upload ", title_pos = "center",
    })
    vim.fn.termopen({ "bash", "-lc", cmd }, {
        on_exit = function(_, code)
            vim.schedule(function()
                local ok = (code == 0)
                local level = ok and vim.log.levels.INFO or vim.log.levels.ERROR
                local msg = ok and "rsync upload completed successfully" or ("rsync exited with code " .. code)
                vim.notify(msg, level)
                if ok and type(on_success) == "function" then pcall(on_success) end
            end)
        end,
    })
    vim.cmd.startinsert()
end

function M.toggle_mark()
    if not in_netrw() then
        vim.notify("Not in a netrw buffer", vim.log.levels.WARN)
        return
    end
    local path = current_path()
    if not path then
        vim.notify("No file under cursor", vim.log.levels.WARN)
        return
    end
    local buf = vim.api.nvim_get_current_buf()
    local row = vim.api.nvim_win_get_cursor(0)[1]
    local buf_marks = ensure_buf_table(buf)

    if marks[path] then
        marks[path] = nil
        if buf_marks[row] then
            pcall(vim.api.nvim_buf_del_extmark, buf, ns, buf_marks[row])
            buf_marks[row] = nil
        end
        vim.notify("Unmarked: " .. path, vim.log.levels.INFO)
    else
        marks[path] = true
        if buf_marks[row] then
            pcall(vim.api.nvim_buf_del_extmark, buf, ns, buf_marks[row])
        end
        buf_marks[row] = add_mark_visual(buf, row)
        vim.notify("Marked: " .. path, vim.log.levels.INFO)
    end
end

function M.clear_marks()
    marks = {}
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(b) and vim.bo[b].filetype == "netrw" then
            clear_all_visual(b)
        end
    end
    vim.notify("Cleared all marks", vim.log.levels.INFO)
end

function M.upload_marked()
    if not ensure_dest() then return end
    local paths = {}
    for p, on in pairs(marks) do if on then table.insert(paths, p) end end
    if #paths == 0 then
        vim.notify("No marked files to upload", vim.log.levels.WARN)
        return
    end
    table.sort(paths)
    local cmd = build_cmd(paths)
    open_float_term(cmd)
end

function M.upload_marked_remove()
    if not ensure_dest() then return end
    local paths, dirs = {}, {}
    for p, on in pairs(marks) do
        if on then
            table.insert(paths, p)
            if vim.fn.isdirectory(p) == 1 then
                table.insert(dirs, normalize_path(p))
            end
        end
    end
    if #paths == 0 then
        vim.notify("No marked files to upload", vim.log.levels.WARN)
        return
    end
    table.sort(paths)
    local old_extra = cfg.extra
    cfg.extra = vim.deepcopy(cfg.extra or {})
    table.insert(cfg.extra, "--remove-source-files")
    local cmd = build_cmd(paths)
    open_float_term(cmd, function()
        cleanup_empty_dirs(dirs)
        M.clear_marks()
    end)
    cfg.extra = old_extra
end

-- ===== Commands =====
function M.set_destination(dest)
    if not dest or dest == "" then
        vim.notify("Usage: :RsyncSetDestination user@host:/path/to/destination/", vim.log.levels.INFO)
        return
    end
    cfg.dest = dest
    vim.notify("Rsync destination set to: " .. cfg.dest, vim.log.levels.INFO)
end

-- ===== Setup =====
function M.setup(opts)
    if opts then for k, v in pairs(opts) do cfg[k] = v end end

    if cfg.keymaps then
        vim.api.nvim_create_autocmd("FileType", {
            pattern = "netrw",
            callback = function(args)
                local buf = args.buf
                vim.keymap.set("n", "mm", M.toggle_mark,    { buffer = buf, desc = "Rsync: Toggle mark under cursor" })
                vim.keymap.set("n", "mu", M.upload_marked,  { buffer = buf, desc = "Rsync: Upload marked files" })
                vim.keymap.set("n", "mC", M.clear_marks,    { buffer = buf, desc = "Rsync: Clear all marks" })
                vim.keymap.set("n", "mU", M.upload_marked_remove, { buffer = buf, desc = "Rsync: Upload and remove source files" })
            end,
        })
    end

    -- reset visuals when netrw buffers open/reload
    vim.api.nvim_create_autocmd({ "BufWinEnter", "BufReadPost" }, {
        callback = function(args)
            if vim.api.nvim_buf_is_loaded(args.buf) and vim.bo[args.buf].filetype == "netrw" then
                clear_all_visual(args.buf)
            end
        end,
    })

    -- user commands
    vim.api.nvim_create_user_command("RsyncSetDestination", function(p) M.set_destination(p.args) end, { nargs = 1 })
    vim.api.nvim_create_user_command("RsyncUpload", function() M.upload_marked() end, {})
    vim.api.nvim_create_user_command("RsyncClearMarks", function() M.clear_marks() end, {})
    vim.api.nvim_create_user_command("RsyncUploadRemove", function() M.upload_marked_remove() end, {})
end

return M
