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
    recent_limit = 5,
    height = 0.78,
    tmux = true,
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

local function status(id)
    local term = terminals[id]
    if not term or not term.bufnr or not vim.api.nvim_buf_is_valid(term.bufnr) then return "empty" end
    if term.exited then return "exited" end
    local entry = states[id]
    if not entry then return "shell" end
    if entry.stale then return "unknown" end
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

local function render()
    local present = {}
    for _, id in ipairs(slots) do present[status(id)] = true end
    local badge = ""
    for _, state in ipairs({ "blocked", "working", "unknown", "idle", "done" }) do
        if present[state] then badge = status_symbols[state]; break end
    end
    tmux.publish(badge)
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
    lines[#lines + 1] = " a add   x remove"
    lines[#lines + 1] = " Enter open q close"

    vim.bo[list_buf].modifiable = true
    vim.api.nvim_buf_set_lines(list_buf, 0, -1, false, lines)
    vim.bo[list_buf].modifiable = false
    vim.api.nvim_buf_clear_namespace(list_buf, M.ns, 0, -1)
    vim.api.nvim_buf_add_highlight(list_buf, M.ns, "Title", 0, 0, -1)
    vim.api.nvim_buf_add_highlight(list_buf, M.ns, "Visual", selected_index() + 1, 0, -1)
    vim.api.nvim_buf_add_highlight(list_buf, M.ns, "Title", #slots + 3, 0, -1)
    vim.api.nvim_buf_add_highlight(list_buf, M.ns, "Comment", divider_row, 0, -1)
    for index, id in ipairs(slots) do
        local group = ({ blocked = "DiagnosticError", done = "DiagnosticWarn", working = "DiagnosticInfo" })[status(id)]
        if group then
            local symbol = status_symbols[status(id)]
            local line = lines[index + 2]
            vim.api.nvim_buf_add_highlight(list_buf, M.ns, group, index + 1, #line - #symbol, -1)
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

    vim.keymap.set({ "n", "t" }, config.keys.list, function() M.focus_list() end,
        { buffer = buf, desc = "Focus agent list" })
    vim.keymap.set({ "n", "t" }, config.keys.next, function() M.cycle_slot(1) end,
        { buffer = buf, desc = "Next agent terminal" })
    vim.keymap.set({ "n", "t" }, config.keys.previous, function() M.cycle_slot(-1) end,
        { buffer = buf, desc = "Previous agent terminal" })
    vim.keymap.set("t", config.keys.escape, [[<C-\><C-n>]], { buffer = buf, desc = "Leave terminal mode" })
    vim.keymap.set({ "n", "t" }, config.keys.hide, function() hide() end,
        { buffer = buf, desc = "Hide agent dashboard" })

    vim.api.nvim_buf_call(buf, function()
        local ok, job = pcall(vim.fn.termopen, vim.o.shell, {
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
        })
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
    changing = true
    selected = id
    local term = terminals[id]
    local spawn = not term.bufnr or not vim.api.nvim_buf_is_valid(term.bufnr) or term.exited
        or (term.job_id and vim.fn.jobwait({ term.job_id }, 0)[1] ~= -1)
    if spawn then
        term.claimed = command ~= nil
        term.session_id, term.title = nil, nil
        states[id] = nil
        vim.fn.delete(state_dir .. "/" .. id .. ".json")
        if term.bufnr and vim.api.nvim_buf_is_valid(term.bufnr) then
            vim.api.nvim_buf_delete(term.bufnr, { force = true })
        end
        term.bufnr = vim.api.nvim_create_buf(false, false)
    end
    if session then
        term.session_id, term.title = session.id, session_title(session)
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
        if entry and entry.session == session.id and entry.agent == session.harness
            and status(id) ~= "exited" then
            open_slot(id)
            return
        end
    end
    if vim.fn.executable(session.harness) == 0 then
        vim.notify(session.harness .. " is not available on PATH", vim.log.levels.WARN)
        return
    end
    local target
    if terminals[selected] and not terminals[selected].claimed
        and (status(selected) == "shell" or status(selected) == "empty") then
        target = selected
    else
        for _, id in ipairs(slots) do
            if not terminals[id].claimed and (status(id) == "shell" or status(id) == "empty") then
                target = id
                break
            end
        end
    end
    if not target and next_id >= 9999 then
        vim.notify("Agent dashboard slot limit reached", vim.log.levels.WARN)
        return
    end
    local command = session.harness == "claude" and "claude --resume " or "opencode --session "
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

local function list_keymaps()
    local opts = { buffer = list_buf, silent = true }
    vim.keymap.set("n", "q", hide, opts)
    vim.keymap.set("n", "<Esc>", hide, opts)
    vim.keymap.set("n", "a", add_slot, opts)
    vim.keymap.set("n", "x", remove_slot, opts)
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
            if ok and type(report) == "table" and report.slot == id
                and type(report.time) == "number" and type(report.session) == "string"
                and type(report.turn) == "number"
                and (report.state == "idle" or report.state == "working"
                    or report.state == "blocked" or report.state == "unknown") then
                term.claimed = true
                local stale = math.abs(os.time() - report.time) > 10
                if not entry or entry.session ~= report.session then
                    if term.session_id ~= report.session then term.title = nil end
                    term.session_id = report.session
                    entry = { session = report.session, seen = report.turn == 0, turn = 0 }
                    states[id] = entry
                end
                if entry.state ~= report.state or entry.stale ~= stale or entry.turn ~= report.turn then
                    if report.state == "working" then entry.seen = false end
                    if report.state == "idle" and report.turn > entry.turn then
                        entry.seen = valid(terminal_win) and vim.api.nvim_get_current_win() == terminal_win and selected == id
                    end
                    entry.state, entry.stale, entry.turn = report.state, stale, report.turn
                    entry.agent = type(report.agent) == "string" and report.agent or "opencode"
                    render()
                end
            elseif entry then
                states[id] = nil
                term.title, term.session_id = nil, nil
                render()
            end
        elseif entry then
            states[id] = nil
            term.title, term.session_id = nil, nil
            render()
        end
    end
end

function M.setup(opts)
    if timer then return end
    config = vim.tbl_deep_extend("force", config, opts or {})
    M.ns = vim.api.nvim_create_namespace("agent_dashboard")
    state_dir = vim.fn.stdpath("state") .. "/agent-dashboard/" .. vim.fn.getpid() .. "-" .. vim.uv.hrtime()
    vim.fn.mkdir(state_dir, "p", 448)
    if config.tmux then tmux.setup(state_dir) end
    timer = vim.uv.new_timer()
    timer:start(0, 1000, vim.schedule_wrap(poll))
    vim.api.nvim_create_autocmd("DirChanged", {
        callback = function()
            refresh_at = 0
            refresh_sessions()
        end,
    })
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
