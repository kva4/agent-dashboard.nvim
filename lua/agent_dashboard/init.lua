local M = {}
local tmux = require("agent_dashboard.tmux")
local session_source = require("agent_dashboard.sessions")

local slots = {}
local terminals = {}
local states = {}
local recent = {}
local rows = {}
local recent_cwd
local refresh_at, refresh_pending, refresh_generation = 0, false, 0
local next_id = 100
local selected, list_buf, list_win, terminal_win, origin_win, timer, state_dir
local changing = false
local config = {
    recent_limit = 10,
    height = 0.78,
    tmux = true,
    notifications = { enabled = true, macos = false },
    keys = { list = "<C-h>", next = "<M-j>", previous = "<M-k>", hide = "<C-q>", escape = "jk" },
}

local function valid(win)
    return win and vim.api.nvim_win_is_valid(win)
end

local function list_visible()
    return valid(list_win)
end

local function selected_index()
    for index, id in ipairs(slots) do
        if id == selected then return index end
    end
    return 1
end

local function geometry()
    local columns, lines = vim.o.columns, vim.o.lines
    if columns < 70 or lines < 14 then return nil end
    local width = math.min(columns - 4, math.floor(columns * 0.94))
    local sidebar = math.min(27, math.max(22, math.floor(width * 0.3)))
    local height = math.max(10, math.floor((lines - 2) * config.height))
    return {
        row = math.max(0, math.floor((lines - height - 2) / 2)),
        col = math.floor((columns - width - 2) / 2),
        height = height,
        sidebar = sidebar,
        terminal = width - sidebar - 2,
    }
end

local function session_title(session)
    local title = type(session.title) == "string" and session.title:gsub("%s+", " "):gsub("^%s+", "") or ""
    return title ~= "" and title or session.id
end

local function fit_title(title, width)
    title = vim.fn.strcharpart(title, 0, math.max(1, width))
    while vim.fn.strdisplaywidth(title) > width do
        title = vim.fn.strcharpart(title, 0, vim.fn.strchars(title) - 1)
    end
    return title
end

local function active_title(id)
    local term = terminals[id]
    if not term or term.exited then return nil end
    local entry = states[id]
    local session_id = entry and entry.session or term.session_id
    if not session_id then return nil end
    for _, session in ipairs(recent) do
        if session.id == session_id and (not entry or entry.agent == session.harness) then
            term.title = session_title(session)
            return term.title
        end
    end
    return term.title
end

local function terminal_title(width)
    local title = active_title(selected)
    return title and " " .. fit_title(title, width - 4) .. " " or " Agent " .. selected_index() .. " "
end

local function terminal_config()
    local rect = geometry()
    if not rect then return nil end
    local width = list_visible() and rect.terminal or math.floor(vim.o.columns * 0.9)
    local height = list_visible() and rect.height or math.floor((vim.o.lines - 2) * config.height)
    local row = list_visible() and rect.row or math.max(0, math.floor((vim.o.lines - height - 2) / 2))
    local col = list_visible() and rect.col + rect.sidebar + 2
        or math.max(0, math.floor((vim.o.columns - width - 2) / 2))
    return {
        relative = "editor", style = "minimal", border = "rounded",
        width = width, height = height, row = row, col = col,
        title = terminal_title(width), title_pos = "center",
    }
end

local function process_alive(pid)
    if type(pid) ~= "number" or pid <= 0 then return true end
    local ok, result = pcall(vim.uv.kill, pid, 0)
    return ok and result ~= nil and result ~= false
end

local function report_stale(report)
    return report.heartbeat == true and math.abs(os.time() - report.time) > 10
end

local function slot_owns_report(term, pid)
    if type(pid) ~= "number" or not vim.api.nvim_get_proc then return true end
    local ok, shell_pid = pcall(vim.fn.jobpid, term.job_id)
    if not ok or type(shell_pid) ~= "number" or shell_pid <= 0 then return true end
    local current = pid
    for _ = 1, 10 do
        if current == shell_pid then return true end
        local got_proc, process = pcall(vim.api.nvim_get_proc, current)
        if not got_proc or type(process) ~= "table" or type(process.ppid) ~= "number" then return true end
        if process.ppid == shell_pid then return true end
        if process.ppid <= 1 then return false end
        current = process.ppid
    end
    return false
end

local function status(id)
    local term = terminals[id]
    if not term or not term.bufnr or not vim.api.nvim_buf_is_valid(term.bufnr) then return "empty" end
    if term.exited then return "exited" end
    local entry = states[id]
    if not entry then return "shell" end
    if entry.stale then return "unknown" end
    -- A running agent with no session selected (e.g. the OpenCode home screen) is idle, not unknown.
    if entry.session == "none" then return "idle" end
    if entry.state == "idle" and not entry.seen then return "done" end
    return entry.state
end

local status_symbols = {
    blocked = "!",
    done = "✓",
    working = "●",
    idle = "○",
    unknown = "?",
}

local function badge()
    local present = {}
    for _, id in ipairs(slots) do present[status(id)] = true end
    for _, state in ipairs({ "blocked", "working", "unknown", "idle", "done" }) do
        if present[state] then return status_symbols[state] end
    end
    return ""
end

local function render()
    tmux.publish(badge())
    if valid(terminal_win) then
        vim.api.nvim_win_set_config(terminal_win, {
            title = terminal_title(vim.api.nvim_win_get_width(terminal_win)), title_pos = "center",
        })
    end

    if not list_visible() or not list_buf or not vim.api.nvim_buf_is_valid(list_buf) then return end
    local lines = { " AGENTS", "" }
    rows = {}
    for index, id in ipairs(slots) do
        local entry = states[id]
        local agent = entry and entry.agent or "terminal"
        local state = status(id)
        local symbol = status_symbols[state] or state
        local title = active_title(id)
        if title then
            local prefix = " " .. index .. " "
            local width = vim.api.nvim_win_get_width(list_win) - vim.fn.strdisplaywidth(prefix)
                - vim.fn.strdisplaywidth(symbol) - 1
            lines[#lines + 1] = prefix .. fit_title(title, width) .. " " .. symbol
        else
            lines[#lines + 1] = string.format(" %d %-8s %s", index, agent, symbol)
        end
        rows[#lines] = { slot = id }
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = " RECENT"
    local height = vim.api.nvim_win_get_height(list_win)
    local available = math.max(0, height - #lines - 3)
    for index = 1, math.min(#recent, available, config.recent_limit) do
        local session = recent[index]
        local label = session.harness == "claude" and "CC" or "OC"
        local max_title = math.max(1, vim.api.nvim_win_get_width(list_win) - 6)
        lines[#lines + 1] = string.format(" %s %s", label, fit_title(session_title(session), max_title))
        rows[#lines] = { session = session }
    end
    lines[#lines + 1] = " " .. string.rep("─", vim.api.nvim_win_get_width(list_win) - 2)
    local divider_row = #lines - 1
    lines[#lines + 1] = " a add   x remove   ? help"
    lines[#lines + 1] = " Enter open   q close"

    vim.bo[list_buf].modifiable = true
    vim.api.nvim_buf_set_lines(list_buf, 0, -1, false, lines)
    vim.bo[list_buf].modifiable = false
    vim.api.nvim_buf_clear_namespace(list_buf, M.ns, 0, -1)
    local function highlight(row, group, start_col, end_col)
        vim.api.nvim_buf_set_extmark(list_buf, M.ns, row, start_col or 0, {
            end_col = end_col or #lines[row + 1], hl_group = group,
        })
    end
    highlight(0, "AgentDashboardTitle")
    highlight(selected_index() + 1, "Visual")
    highlight(#slots + 3, "AgentDashboardTitle")
    highlight(divider_row, "Comment")
    for index, id in ipairs(slots) do
        local group = ({
            blocked = "AgentDashboardBlocked", done = "AgentDashboardDone",
            working = "AgentDashboardWorking", unknown = "AgentDashboardUnknown",
        })[status(id)]
        if group then
            local symbol = status_symbols[status(id)]
            local line = lines[index + 2]
            highlight(index + 1, group, #line - #symbol)
        end
    end
end

local function refresh_sessions()
    if refresh_pending or not list_visible() then return end
    refresh_pending = true
    refresh_at = os.time()
    refresh_generation = refresh_generation + 1
    local generation = refresh_generation
    local cwd = vim.fn.getcwd()
    if recent_cwd ~= cwd then
        recent, recent_cwd = {}, cwd
        render()
    end
    session_source.refresh(cwd, function(sessions)
        if generation ~= refresh_generation then return end
        refresh_pending = false
        if cwd ~= vim.fn.getcwd() then refresh_at = 0; return end
        recent = sessions
        render()
    end, config)
end

local function mark_seen(id)
    local entry = states[id]
    if entry and entry.state == "idle" and not entry.seen then
        entry.seen = true
        render()
    end
end

local function create_slot()
    next_id = next_id + 1
    local id = next_id
    slots[#slots + 1] = id
    terminals[id] = {}
    selected = id
    render()
    return id
end

local function close_window(win)
    if valid(win) then vim.api.nvim_win_close(win, true) end
end

local function hide()
    changing = true
    close_window(list_win)
    close_window(terminal_win)
    list_win, terminal_win = nil, nil
    changing = false
    if valid(origin_win) then vim.api.nvim_set_current_win(origin_win) end
end

local function start_terminal(id, command)
    local term = terminals[id]
    local buf = term.bufnr
    term.exited = false
    vim.bo[buf].bufhidden = "hide"
    vim.bo[buf].buflisted = false
    vim.bo[buf].swapfile = false

    local function map(key, modes, callback, desc)
        if type(key) == "string" and key ~= "" then
            vim.keymap.set(modes, key, callback, { buffer = buf, desc = desc })
        end
    end
    map(config.keys.list, { "n", "t" }, function() M.focus_list() end, "Focus agent list")
    map(config.keys.next, { "n", "t" }, function() M.cycle_slot(1) end, "Next agent terminal")
    map(config.keys.previous, { "n", "t" }, function() M.cycle_slot(-1) end, "Previous agent terminal")
    map(config.keys.escape, "t", [[<C-\><C-n>]], "Leave terminal mode")
    map(config.keys.hide, { "n", "t" }, hide, "Hide agent dashboard")

    vim.api.nvim_buf_call(buf, function()
        local opts = {
            cwd = vim.fn.getcwd(),
            env = { NVIM_AGENT_DASHBOARD_DIR = state_dir, NVIM_AGENT_SLOT = tostring(id) },
            on_exit = function()
                vim.schedule(function()
                    if terminals[id] ~= term or term.bufnr ~= buf then return end
                    term.exited = true
                    states[id] = nil
                    vim.fn.delete(state_dir .. "/" .. id .. ".json")
                    render()
                end)
            end,
        }
        local open_terminal = vim.fn.has("nvim-0.11") == 1 and function(command, options)
            return vim.fn.jobstart(command, vim.tbl_extend("force", options, { term = true }))
        end or vim.fn.termopen
        local ok, job = pcall(open_terminal, vim.o.shell, opts)
        term.job_id = ok and job or -1
    end)
    if term.job_id <= 0 then
        term.exited = true
        vim.notify("Could not start agent shell " .. selected_index(), vim.log.levels.ERROR)
    elseif command then
        vim.api.nvim_chan_send(term.job_id, command .. "\n")
    end
end

local function open_slot(id, command, session)
    if not terminals[id] then return end
    if not terminal_config() then
        vim.notify("Agent dashboard needs at least 70 columns and 14 lines", vim.log.levels.WARN)
        return
    end
    changing = true
    selected = id
    local term = terminals[id]
    local spawn = not term.bufnr or not vim.api.nvim_buf_is_valid(term.bufnr) or term.exited
        or (term.job_id and vim.fn.jobwait({ term.job_id }, 0)[1] ~= -1)
    if spawn then
        term.claimed = command ~= nil
        term.session_id, term.agent, term.title = nil, nil, nil
        states[id] = nil
        vim.fn.delete(state_dir .. "/" .. id .. ".json")
        if term.bufnr and vim.api.nvim_buf_is_valid(term.bufnr) then
            vim.api.nvim_buf_delete(term.bufnr, { force = true })
        end
        term.bufnr = vim.api.nvim_create_buf(false, false)
    end
    if session then
        term.session_id, term.agent, term.title = session.id, session.harness, session_title(session)
    end
    if valid(terminal_win) then
        vim.api.nvim_win_set_buf(terminal_win, term.bufnr)
        vim.api.nvim_win_set_config(terminal_win, terminal_config())
        vim.api.nvim_set_current_win(terminal_win)
    else
        origin_win = vim.api.nvim_get_current_win()
        terminal_win = vim.api.nvim_open_win(term.bufnr, true, terminal_config())
    end
    if spawn then
        start_terminal(id, command)
    elseif command then
        term.claimed = true
        vim.api.nvim_chan_send(term.job_id, command .. "\n")
    end
    changing = false
    mark_seen(id)
    render()
    vim.cmd("startinsert")
end

function M.cycle_slot(delta)
    if #slots < 2 then return end
    local index = (selected_index() - 1 + delta) % #slots + 1
    open_slot(slots[index])
end

local function open_session(session)
    for _, id in ipairs(slots) do
        local entry = states[id]
        local term = terminals[id]
        if ((entry and entry.session == session.id and entry.agent == session.harness)
            or (term and term.session_id == session.id and term.agent == session.harness))
            and status(id) ~= "exited" then
            open_slot(id)
            return
        end
    end
    if vim.fn.executable(session.harness) == 0 then
        vim.notify(session.harness .. " is not available on PATH", vim.log.levels.WARN)
        return
    end
    local function shell_busy(term)
        if not term or not term.job_id or term.job_id <= 0 then return false end
        local ok, pid = pcall(vim.fn.jobpid, term.job_id)
        if not ok or type(pid) ~= "number" or pid <= 0 then return false end
        if not vim.api.nvim_get_proc_children then return false end
        local got_children, children = pcall(vim.api.nvim_get_proc_children, pid)
        return got_children and type(children) == "table" and #children > 0
    end
    local function available(id)
        local term = terminals[id]
        return term and not term.claimed and not shell_busy(term)
            and (status(id) == "shell" or status(id) == "empty")
    end
    local target
    if available(selected) then
        target = selected
    else
        for _, id in ipairs(slots) do
            if available(id) then
                target = id
                break
            end
        end
    end
    if not target and next_id >= 9999 then
        vim.notify("Agent dashboard slot limit reached", vim.log.levels.WARN)
        return
    end
    local command = ({ claude = "claude --resume ", opencode = "opencode --session " })[session.harness]
    if not command then
        vim.notify("No resume command configured for " .. tostring(session.harness), vim.log.levels.WARN)
        return
    end
    open_slot(target or create_slot(), command .. vim.fn.shellescape(session.id), session)
end

function M.focus_list()
    if not list_visible() then M.toggle() end
    if not list_visible() then return end
    vim.cmd("stopinsert")
    vim.api.nvim_set_current_win(list_win)
    vim.api.nvim_win_set_cursor(list_win, { selected_index() + 2, 0 })
end

local function add_slot()
    if next_id >= 9999 then
        vim.notify("Agent dashboard slot limit reached", vim.log.levels.WARN)
        return
    end
    open_slot(create_slot())
end

function M.status()
    return badge()
end

function M.send_context(kind, line_range)
    kind = kind or "selection"
    local text
    if line_range then
        text = table.concat(vim.api.nvim_buf_get_lines(0, line_range[1] - 1, line_range[2], false), "\n")
    elseif kind == "selection" then
        local visual_mode = vim.fn.mode(1)
        local active_visual = visual_mode == "v" or visual_mode == "V" or visual_mode == "\22"
        local start_pos = vim.fn.getpos(active_visual and "v" or "'<")
        local end_pos = vim.fn.getpos(active_visual and "." or "'>")
        if start_pos[2] == 0 or end_pos[2] == 0 then
            vim.notify("No previous visual selection", vim.log.levels.WARN)
            return false
        end
        local selection_type = active_visual and visual_mode or vim.fn.visualmode()
        local region = vim.fn.getregion(start_pos, end_pos, { type = selection_type })
        text = table.concat(region, "\n")
    elseif kind == "file" or kind == "location" then
        local path = vim.api.nvim_buf_get_name(0)
        if path == "" then
            vim.notify("Current buffer has no file name", vim.log.levels.WARN)
            return false
        end
        path = vim.fn.fnamemodify(path, ":.")
        text = "@" .. path .. (kind == "location" and ":" .. vim.api.nvim_win_get_cursor(0)[1] or "") .. " "
    else
        vim.notify("Use send with selection, file, or location", vim.log.levels.WARN)
        return false
    end
    local term = terminals[selected]
    if not term or not term.job_id or term.job_id <= 0 or term.exited
        or vim.fn.jobwait({ term.job_id }, 0)[1] ~= -1 then
        vim.notify("Selected agent terminal is not running", vim.log.levels.WARN)
        return false
    end
    vim.api.nvim_chan_send(term.job_id, "\27[200~" .. text .. "\27[201~")
    if not valid(terminal_win) or vim.api.nvim_get_current_win() ~= terminal_win then
        vim.notify("Sent context to agent slot " .. selected_index(), vim.log.levels.INFO)
    end
    return true
end

function M.claude_hook_path()
    local source = debug.getinfo(1, "S").source:sub(2)
    local root = source:gsub("/lua/agent_dashboard/init%.lua$", "")
    return root .. "/extras/claude/agent-dashboard-report.sh"
end

function M.hooks()
    local command = "bash " .. vim.fn.shellescape(M.claude_hook_path())
    local hooks = { hooks = {
        SessionStart = { { hooks = { { type = "command", command = command .. " start" } } } },
        UserPromptSubmit = { { hooks = { { type = "command", command = command .. " working" } } } },
        Stop = { { hooks = { { type = "command", command = command .. " idle" } } } },
        Notification = { { matcher = "permission_prompt", hooks = {
            { type = "command", command = command .. " blocked" },
        } } },
        SessionEnd = { { hooks = { { type = "command", command = command .. " end" } } } },
    } }
    return vim.json.encode(hooks)
end

local function show_help()
    local help_buf = vim.api.nvim_create_buf(false, true)
    local help_lines = {
        "Agent Dashboard keys", "", "Sidebar",
        "  j / k       Move between rows",
        "  Enter       Open selected slot or session",
        "  1-9         Open a slot (create the next slot)",
        "  a / x       Add / remove a slot",
        "  y           Copy the session id of the row",
        "  D           Delete the selected recent session",
        "  ?           Show this help",
        "  q / Esc     Hide the dashboard", "", "Agent terminal",
        "  " .. (config.keys.list or "") .. "       Focus the sidebar",
        "  " .. (config.keys.next or "") .. " / " .. (config.keys.previous or "") .. "   Cycle slots",
        "  " .. (config.keys.hide or "") .. "       Hide the dashboard",
        "", "Press q or Esc to close",
    }
    vim.api.nvim_buf_set_lines(help_buf, 0, -1, false, help_lines)
    vim.bo[help_buf].modifiable = false
    local width = math.min(44, vim.o.columns - 4)
    local height = math.min(#help_lines, vim.o.lines - 4)
    local win = vim.api.nvim_open_win(help_buf, true, {
        relative = "editor", style = "minimal", border = "rounded", width = width, height = height,
        row = math.max(0, math.floor((vim.o.lines - height - 2) / 2)),
        col = math.max(0, math.floor((vim.o.columns - width - 2) / 2)),
    })
    local function close()
        if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
        if vim.api.nvim_buf_is_valid(help_buf) then vim.api.nvim_buf_delete(help_buf, { force = true }) end
    end
    vim.keymap.set("n", "q", close, { buffer = help_buf, nowait = true })
    vim.keymap.set("n", "<Esc>", close, { buffer = help_buf, nowait = true })
end

local function remove_slot()
    local row = rows[vim.api.nvim_win_get_cursor(list_win)[1]]
    if not row or not row.slot then return end
    if #slots == 1 then
        vim.notify("Keep at least one agent terminal", vim.log.levels.INFO)
        return
    end
    local id = row.slot
    local index = selected_index()
    for i, slot in ipairs(slots) do if slot == id then index = i; break end end
    if vim.fn.confirm("Stop and remove agent terminal " .. index .. "?", "&Yes\n&No", 2) ~= 1 then return end
    local term = terminals[id]
    changing = true
    terminals[id], states[id] = nil, nil
    vim.fn.delete(state_dir .. "/" .. id .. ".json")
    if term.job_id and term.job_id > 0 and not term.exited then vim.fn.jobstop(term.job_id) end
    if term.bufnr and vim.api.nvim_buf_is_valid(term.bufnr) then
        vim.api.nvim_buf_delete(term.bufnr, { force = true })
    end
    table.remove(slots, index)
    if selected == id then selected = slots[math.min(index, #slots)] end
    open_slot(selected)
    M.focus_list()
end

local function copy_session_id()
    local row = rows[vim.api.nvim_win_get_cursor(list_win)[1]]
    local session_id = row and (row.session and row.session.id
        or row.slot and states[row.slot] and states[row.slot].session)
    if type(session_id) ~= "string" or session_id == "none" or session_id == "unknown" then
        vim.notify("No session id on this row", vim.log.levels.INFO)
        return
    end
    vim.fn.setreg("+", session_id)
    vim.fn.setreg('"', session_id)
    vim.notify("Copied session id " .. session_id, vim.log.levels.INFO)
end

local function delete_recent_session()
    local row = rows[vim.api.nvim_win_get_cursor(list_win)[1]]
    local session = row and row.session
    if not session then
        vim.notify("Select a recent session to delete", vim.log.levels.INFO)
        return
    end
    for _, id in ipairs(slots) do
        local term, entry = terminals[id], states[id]
        local open_id = entry and entry.session or term and term.session_id
        if term and not term.exited and open_id == session.id then
            vim.notify("Close the agent terminal before deleting its session", vim.log.levels.WARN)
            return
        end
    end
    local label = session.harness == "claude" and "Claude" or "OpenCode"
    if vim.fn.confirm("Delete " .. label .. " session \"" .. session_title(session) .. "\"? This can't be undone.",
        "&Yes\n&No", 2) ~= 1 then return end
    session_source.delete(session, vim.fn.getcwd(), function(ok, err)
        vim.schedule(function()
            if not ok then
                vim.notify("Could not delete session: " .. (err ~= "" and err or "unknown error"), vim.log.levels.ERROR)
                return
            end
            vim.notify("Deleted session " .. session.id, vim.log.levels.INFO)
            refresh_at = 0
            refresh_sessions()
        end)
    end, config)
end

local function list_keymaps()
    local opts = { buffer = list_buf, silent = true }
    vim.keymap.set("n", "y", copy_session_id, opts)
    vim.keymap.set("n", "D", delete_recent_session, opts)
    vim.keymap.set("n", "q", hide, opts)
    vim.keymap.set("n", "<Esc>", hide, opts)
    vim.keymap.set("n", "a", add_slot, opts)
    vim.keymap.set("n", "x", remove_slot, opts)
    vim.keymap.set("n", "?", show_help, opts)
    vim.keymap.set("n", "<CR>", function()
        local row = rows[vim.api.nvim_win_get_cursor(list_win)[1]]
        if row and row.session then open_session(row.session)
        elseif row and row.slot then open_slot(row.slot) end
    end, opts)
    vim.keymap.set("n", "<C-l>", function() open_slot(selected) end, opts)
    for index = 1, 9 do
        local slot_index = index
        vim.keymap.set("n", tostring(slot_index), function()
            if slots[slot_index] then open_slot(slots[slot_index])
            elseif slot_index == #slots + 1 then add_slot() end
        end, opts)
    end
    for key, delta in pairs({ j = 1, k = -1 }) do
        vim.keymap.set("n", key, function()
            local row = vim.api.nvim_win_get_cursor(list_win)[1]
            repeat
                row = row + delta
            until rows[row] or row < 1 or row > vim.api.nvim_buf_line_count(list_buf)
            if rows[row] then vim.api.nvim_win_set_cursor(list_win, { row, 0 }) end
        end, opts)
    end
end

function M.toggle()
    if list_visible() then hide(); return end
    local rect = geometry()
    if not rect then
        vim.notify("Agent dashboard needs at least 70 columns and 14 lines", vim.log.levels.WARN)
        return
    end
    if #slots == 0 then create_slot() end
    if not valid(terminal_win) then origin_win = vim.api.nvim_get_current_win() end
    if not list_buf or not vim.api.nvim_buf_is_valid(list_buf) then
        list_buf = vim.api.nvim_create_buf(false, true)
        vim.bo[list_buf].bufhidden = "hide"
        vim.bo[list_buf].modifiable = false
        list_keymaps()
    end
    changing = true
    list_win = vim.api.nvim_open_win(list_buf, false, {
        relative = "editor", style = "minimal", border = "rounded",
        row = rect.row, col = rect.col, width = rect.sidebar, height = rect.height,
        title = " Agents ", title_pos = "center",
    })
    vim.wo[list_win].cursorline = true
    vim.wo[list_win].number = false
    vim.wo[list_win].relativenumber = false
    vim.wo[list_win].wrap = false
    changing = false
    open_slot(selected)
    refresh_sessions()
end

function M.toggle_slot(index)
    if not terminal_config() then
        vim.notify("Agent dashboard needs at least 70 columns and 14 lines", vim.log.levels.WARN)
        return
    end
    if index > #slots then
        for _ = #slots + 1, index do create_slot() end
        open_slot(slots[index])
        return
    end
    local id = slots[index]
    if id == selected and valid(terminal_win) and vim.api.nvim_get_current_win() == terminal_win then
        hide()
    else
        open_slot(id)
    end
end

local function poll()
    if list_visible() and os.time() - refresh_at >= 30 then refresh_sessions() end
    for _, id in ipairs(slots) do
        local term, entry = terminals[id], states[id]
        if term and term.bufnr and vim.api.nvim_buf_is_valid(term.bufnr) and not term.exited then
            local file = state_dir .. "/" .. id .. ".json"
            local raw = vim.fn.filereadable(file) == 1 and vim.fn.readfile(file) or nil
            local ok, report = pcall(vim.json.decode, raw and table.concat(raw, "\n") or "")
            local valid_report = ok and type(report) == "table" and report.slot == id
                and type(report.time) == "number" and type(report.session) == "string"
                and type(report.turn) == "number"
                and (report.pid == nil or (type(report.pid) == "number" and report.pid > 0))
                and (report.heartbeat == nil or type(report.heartbeat) == "boolean")
                and (report.state == "idle" or report.state == "working"
                    or report.state == "blocked" or report.state == "unknown")
            local dead_report = valid_report and type(report.pid) == "number" and not process_alive(report.pid)
            if dead_report then
                vim.fn.delete(file)
                valid_report = false
            end
            local ignored_report = valid_report and not slot_owns_report(term, report.pid)
            if valid_report and not ignored_report then
                term.claimed = true
                local stale = report_stale(report)
                if not entry or entry.session ~= report.session then
                    if term.session_id ~= report.session then term.title = nil end
                    term.session_id = report.session
                    entry = { session = report.session, seen = report.turn == 0, turn = 0 }
                    states[id] = entry
                end
                if entry.state ~= report.state or entry.stale ~= stale
                    or entry.turn ~= report.turn or entry.pid ~= report.pid then
                    local previous_state, previous_turn = entry.state, entry.turn
                    if report.state == "working" then entry.seen = false end
                    if report.state == "idle" and report.turn > entry.turn then
                        entry.seen = valid(terminal_win) and vim.api.nvim_get_current_win() == terminal_win and selected == id
                    end
                    entry.state, entry.stale, entry.turn = report.state, stale, report.turn
                    entry.agent = type(report.agent) == "string" and report.agent or "opencode"
                    entry.pid = report.pid
                    term.agent = entry.agent
                    if selected ~= id or not valid(terminal_win) then
                        local message
                        if report.state == "blocked" and previous_state ~= "blocked" then
                            message = (entry.agent == "claude" and "Claude" or "OpenCode") .. " is waiting for permission"
                        elseif report.state == "idle" and report.turn > previous_turn then
                            message = (entry.agent == "claude" and "Claude" or "OpenCode") .. " finished a turn"
                        end
                        local notifications = type(config.notifications) == "table"
                            and config.notifications or { enabled = config.notifications ~= false }
                        if message and notifications.enabled ~= false and not stale then
                            vim.notify(message, vim.log.levels.INFO, { title = "Agent Dashboard" })
                            if notifications.macos and vim.fn.executable("osascript") == 1 then
                                vim.system({ "osascript", "-e",
                                    'display notification "' .. message .. '" with title "Agent Dashboard"' })
                            end
                        end
                    end
                    render()
                end
            elseif dead_report or (entry and not ignored_report) then
                states[id] = nil
                term.title, term.session_id, term.agent = nil, nil, nil
                term.claimed = false
                render()
            end
        elseif entry then
            states[id] = nil
            term.title, term.session_id, term.agent = nil, nil, nil
            render()
        end
    end
end

function M.setup(opts)
    if timer then return end
    config = vim.tbl_deep_extend("force", config, opts or {})
    M.ns = vim.api.nvim_create_namespace("agent_dashboard")
    for group, target in pairs({
        AgentDashboardBlocked = "DiagnosticError", AgentDashboardWorking = "DiagnosticInfo",
        AgentDashboardDone = "DiagnosticWarn", AgentDashboardUnknown = "DiagnosticHint",
        AgentDashboardTitle = "Title",
    }) do
        vim.api.nvim_set_hl(0, group, { default = true, link = target })
    end
    state_dir = vim.fn.stdpath("state") .. "/agent-dashboard/" .. vim.fn.getpid() .. "-"
        .. string.format("%d", vim.uv.hrtime())
    vim.fn.mkdir(state_dir, "p", 448)
    if config.tmux then tmux.setup(state_dir) end
    timer = vim.uv.new_timer()
    timer:start(0, 1000, vim.schedule_wrap(poll))
    vim.api.nvim_create_autocmd("DirChanged", {
        callback = function()
            refresh_generation = refresh_generation + 1
            refresh_pending = false
            refresh_at = 0
            refresh_sessions()
        end,
    })
    vim.api.nvim_create_user_command("AgentDashboard", function(command)
        local args = vim.split(command.args, "%s+", { trimempty = true })
        local action = args[1] or "toggle"
        if action == "toggle" then
            M.toggle()
        elseif action == "open" then
            local index = tonumber(args[2])
            if not index or index < 1 then
                vim.notify("Usage: AgentDashboard open N", vim.log.levels.WARN)
            else
                M.toggle_slot(index)
            end
        elseif action == "add" then
            add_slot()
        elseif action == "send" then
            local line_range = command.range > 0 and { command.line1, command.line2 } or nil
            M.send_context(args[2] or "selection", line_range)
        elseif action == "hooks" then
            vim.api.nvim_echo({ { M.hooks() } }, true, {})
        else
            vim.notify("Usage: AgentDashboard [toggle|open N|add|send [selection|file|location]|hooks]",
                vim.log.levels.WARN)
        end
    end, { nargs = "*", range = true, desc = "Control the agent dashboard" })
    vim.api.nvim_create_autocmd("WinEnter", {
        callback = function()
            if not changing and list_visible() then
                local current = vim.api.nvim_get_current_win()
                if current ~= list_win and current ~= terminal_win then hide() end
            end
            if valid(terminal_win) and vim.api.nvim_get_current_win() == terminal_win then mark_seen(selected) end
        end,
    })
    vim.api.nvim_create_autocmd("WinClosed", {
        callback = function(event)
            if changing then return end
            local closed = tonumber(event.match)
            if closed == list_win then list_win = nil end
            if closed == terminal_win then terminal_win = nil end
        end,
    })
    vim.api.nvim_create_autocmd("VimResized", {
        callback = function()
            if not valid(terminal_win) and not list_visible() then return end
            local rect = geometry()
            if not rect then hide(); return end
            if list_visible() then
                vim.api.nvim_win_set_config(list_win, {
                    relative = "editor", row = rect.row, col = rect.col,
                    width = rect.sidebar, height = rect.height,
                })
                render()
            end
            if valid(terminal_win) then vim.api.nvim_win_set_config(terminal_win, terminal_config()) end
        end,
    })
    vim.api.nvim_create_autocmd("VimLeavePre", {
        callback = function()
            timer:stop()
            timer:close()
            tmux.teardown()
            vim.fn.delete(state_dir, "rf")
        end,
    })
end

return M
