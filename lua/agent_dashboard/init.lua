local M = {}
local tmux = require("agent_dashboard.tmux")
local session_source = require("agent_dashboard.sessions")
local topic_source = require("agent_dashboard.topics")
local capture = require("agent_dashboard.capture")
local capture_ui = require("agent_dashboard.capture_ui")

local slots = {}
local terminals = {}
local states = {}
local recent = {}
local rows = {}
local slot_lines = {}
local cached_topics = {}
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
    topics = {
        enabled = true,
        dir = vim.fn.stdpath("data") .. "/agent-dashboard/topics",
        brief_max_lines = 150,
        suggest_for_cwd = true,
        deliver = true,
        auto_distill = false,
    },
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
    local term = terminals[selected]
    local topic = term and term.topic_id and (" · " .. term.topic_id) or ""
    title = title and (title .. topic) or ("Agent " .. selected_index() .. topic)
    return " " .. fit_title(title, width - 4) .. " "
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

local function refresh_topics()
    cached_topics = config.topics.enabled and topic_source.list() or {}
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
    slot_lines = {}
    for index, id in ipairs(slots) do
        local entry = states[id]
        local agent = entry and entry.agent or "terminal"
        local state = status(id)
        local symbol = status_symbols[state] or state
        local title = active_title(id)
        local topic = terminals[id] and terminals[id].topic_id
        if title then
            local prefix = " " .. index .. " "
            local width = vim.api.nvim_win_get_width(list_win) - vim.fn.strdisplaywidth(prefix)
                - vim.fn.strdisplaywidth(symbol) - 1
            lines[#lines + 1] = prefix .. fit_title(title, width) .. " " .. symbol
        else
            lines[#lines + 1] = string.format(" %d %-8s %s", index, agent, symbol)
        end
        rows[#lines] = { slot = id }
        slot_lines[id] = #lines - 1
        local slot_capture = capture_ui.summary(id)
        if slot_capture then
            lines[#lines + 1] = fit_title("   " .. slot_capture, math.max(1, vim.api.nvim_win_get_width(list_win) - 2))
            rows[#lines] = { slot = id, capture = true }
            local actions = capture_ui.row_items()
            if #actions > 0 then
                local labels = { error = "e errors", open = "o open", review = "r review", retry = "R retry", cancel = "X cancel", dismiss = "d dismiss" }
                local hints = {}; for _, action in ipairs(actions) do hints[#hints + 1] = labels[action] or action end
                lines[#lines + 1] = "   c capture · " .. table.concat(hints, " · ")
                rows[#lines] = { slot = id, capture = true }
            end
        end
        if topic then
            lines[#lines + 1] = "   ↳ " .. fit_title(topic, vim.api.nvim_win_get_width(list_win) - 6)
            rows[#lines] = { slot = id }
        end
    end
    local capture_slot = capture_ui.source_slot()
    local source_term = capture_slot and terminals[capture_slot]
    local orphan_capture = capture_ui.summary(nil, source_term ~= nil and not source_term.exited)
    if orphan_capture then
        lines[#lines + 1] = ""
        lines[#lines + 1] = fit_title(orphan_capture, math.max(1, vim.api.nvim_win_get_width(list_win) - 2))
        rows[#lines] = { capture = true }
        local actions = capture_ui.row_items()
        if #actions > 0 then
            local labels = { error = "e errors", open = "o open", review = "r review", retry = "R retry", cancel = "X cancel", dismiss = "d dismiss" }
            local hints = {}; for _, action in ipairs(actions) do hints[#hints + 1] = labels[action] or action end
            lines[#lines + 1] = "   Capture: " .. table.concat(hints, " · ")
        end
    end
    local topic_list = {}
    if config.topics.enabled then
        topic_list = cached_topics
        if config.topics.suggest_for_cwd ~= false then
            local matching = {}
            for _, topic in ipairs(topic_source.for_cwd(vim.fn.getcwd(), topic_list)) do matching[topic.id] = true end
            for _, topic in ipairs(topic_list) do topic.project_match = matching[topic.id] == true end
        end
        if #topic_list > 0 then
            lines[#lines + 1] = ""
            lines[#lines + 1] = " TOPICS"
            local height = vim.api.nvim_win_get_height(list_win)
            local limit = math.min(#topic_list, math.max(1, math.floor(height / 4)))
            for index = 1, limit do
                local topic = topic_list[index]
                local marker = topic.project_match and "*" or " "
                local count = topic.new_notes > 0 and ("  " .. topic.new_notes .. " new") or ""
                local label = string.format(" %s %-18s", marker, topic.id)
                local width = math.max(1, vim.api.nvim_win_get_width(list_win) - 1)
                lines[#lines + 1] = fit_title(label .. count, width)
                rows[#lines] = { topic = topic }
            end
            if #topic_list > limit then
                lines[#lines + 1] = "   +" .. (#topic_list - limit) .. " more"
            end
        end
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = " RECENT"
    local height = vim.api.nvim_win_get_height(list_win)
    local available = math.max(0, height - #lines - 4)
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
    lines[#lines + 1] = " Enter open  Tab terminal"
    lines[#lines + 1] = " q close"

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
    highlight(slot_lines[selected] or selected_index() + 1, "Visual")
    highlight(divider_row, "Comment")
    for row, line in ipairs(lines) do
        if line == " TOPICS" or line == " RECENT" then highlight(row - 1, "AgentDashboardTitle") end
    end
    for index, id in ipairs(slots) do
        local group = ({
            blocked = "AgentDashboardBlocked", done = "AgentDashboardDone",
            working = "AgentDashboardWorking", unknown = "AgentDashboardUnknown",
        })[status(id)]
        if group then
            local symbol = status_symbols[status(id)]
            local row = slot_lines[id]
            local line = lines[row + 1]
            highlight(row, group, #line - #symbol)
        end
    end
end

local function refresh_sessions()
    if refresh_pending or not list_visible() then return end
    refresh_topics()
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
        recent = {}
        for _, session in ipairs(sessions) do
            if not capture.is_helper(session.harness, session.id) then recent[#recent + 1] = session end
        end
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

local function edit_in_editor(path)
    local current = vim.api.nvim_get_current_win()
    if (current == list_win or current == terminal_win) and valid(origin_win) then hide() end
    vim.cmd("edit " .. vim.fn.fnameescape(path))
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
    map("<Tab>", "n", function() M.focus_list() end, "Focus agent list")
    map("<C-w>h", "n", function() M.focus_list() end, "Focus agent list")
    map("<C-w><C-h>", "n", function() M.focus_list() end, "Focus agent list")
    map(config.keys.next, { "n", "t" }, function() M.cycle_slot(1) end, "Next agent terminal")
    map(config.keys.previous, { "n", "t" }, function() M.cycle_slot(-1) end, "Previous agent terminal")
    map(config.keys.escape, "t", [[<C-\><C-n>]], "Leave terminal mode")
    map(config.keys.hide, { "n", "t" }, hide, "Hide agent dashboard")
    map(config.keys.capture or "<M-c>", { "n", "t" }, function() M.distill() end, "Capture session findings")

    vim.api.nvim_buf_call(buf, function()
        local opts = {
            cwd = term.cwd or vim.fn.getcwd(),
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
    local old_cwd = term.cwd or vim.fn.getcwd()
    local requested_cwd = session and vim.fn.fnamemodify(vim.fn.expand(
        session.project and session.project ~= "" and session.project or vim.fn.getcwd()), ":p")
    local cwd_changed = requested_cwd and vim.fn.fnamemodify(requested_cwd, ":p")
        ~= vim.fn.fnamemodify(old_cwd, ":p")
    term.cwd = requested_cwd or old_cwd
    local spawn = not term.bufnr or not vim.api.nvim_buf_is_valid(term.bufnr) or term.exited
        or (term.job_id and vim.fn.jobwait({ term.job_id }, 0)[1] ~= -1)
        or cwd_changed
    if spawn then
        if cwd_changed
            and term.job_id and term.job_id > 0 and not term.exited then
            vim.fn.jobstop(term.job_id)
        end
        term.claimed = command ~= nil
        term.pending_topic, term.topic_delivered = nil, nil
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
        states[id] = nil
        vim.fn.delete(state_dir .. "/" .. id .. ".json")
        term.pending_topic, term.topic_delivered = nil, nil
        vim.api.nvim_chan_send(term.job_id, command .. "\n")
    end
    changing = false
    mark_seen(id)
    render()
    vim.cmd("startinsert")
end

local function deliver_opencode_topic(id, term)
    local topic = config.topics.enabled and config.topics.deliver ~= false and term.topic_id
        and topic_source.get(term.topic_id)
    if not topic then return end
    local brief = topic_source.brief_path(topic.id)
    term.pending_topic = {
        topic = topic.id, session = term.session_id,
        deadline = vim.uv.hrtime() + (config.topics.opencode_prompt_timeout_ms or 15000) * 1000000,
        prompt = 'Before we start, read "' .. brief .. '". Detailed notes are in "' .. topic.dir
            .. '/notes"; read them when useful.',
    }
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
    local id = target or create_slot()
    local term = terminals[id]
    open_slot(id, command .. vim.fn.shellescape(session.id), session)
    if session.harness == "opencode" then deliver_opencode_topic(id, term) end
end

function M.focus_list()
    if not list_visible() then M.toggle() end
    if not list_visible() then return end
    vim.cmd("stopinsert")
    vim.api.nvim_set_current_win(list_win)
    vim.api.nvim_win_set_cursor(list_win, { (slot_lines[selected] or selected_index() + 1) + 1, 0 })
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

local function selected_text(kind, line_range)
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
    return text
end

local function send_to_selected(text, request)
    if type(text) ~= "string" or text == "" then return false end
    local term = terminals[selected]
    if not term or not term.job_id or term.job_id <= 0 or term.exited
        or vim.fn.jobwait({ term.job_id }, 0)[1] ~= -1 then
        vim.notify("Selected agent terminal is not running", vim.log.levels.WARN)
        return false
    end
    -- Keep the explicit request outside the paste: harnesses may treat pasted
    -- instructions as quoted context. The request has no newline/Enter.
    vim.api.nvim_chan_send(term.job_id, (request or "") .. "\27[200~" .. text .. "\27[201~")
    if not valid(terminal_win) or vim.api.nvim_get_current_win() ~= terminal_win then
        vim.notify("Sent context to agent slot " .. selected_index(), vim.log.levels.INFO)
    end
    return true
end

function M.send_context(kind, line_range)
    local text = selected_text(kind, line_range)
    if not text then return false end
    return send_to_selected(text)
end

local function selected_source(slot_id)
    local id = slot_id or selected
    local term, entry = terminals[id], states[id]
    local project = entry and entry.project or term and term.cwd or vim.fn.getcwd()
    local source = { project = project }
    source.harness = entry and entry.agent or term and term.agent
    source.session = entry and entry.session or term and term.session_id
    if source.session == "none" or source.session == "unknown" then source.session = nil end
    return source
end

local function selected_capture_request(kind, slot_id)
    local id = slot_id or selected
    local source = selected_source(id)
    local entry = states[id]
    local term = terminals[id]
    if not term or not term.bufnr or term.exited then
        vim.notify("Open a source agent terminal before capturing findings", vim.log.levels.WARN)
        return nil
    end
    source.slot_id = id
    source.status = entry and entry.state or "unknown"
    source.reported = entry ~= nil and not entry.stale
    return { kind = kind, source = source, topic_id = term.topic_id }
end

local function choose_topic(callback)
    local choices = topic_source.list()
    if #choices == 0 then
        vim.notify("No topics yet; create one with :AgentDashboard topic new <id>", vim.log.levels.INFO)
        return
    end
    vim.ui.select(choices, { prompt = "Choose a topic", format_item = function(topic)
        return topic.title .. " (" .. topic.id .. ")"
    end }, function(topic)
        if topic then callback(topic.id) end
    end)
end

local function fill_prompt(template, values)
    if type(template) ~= "string" then return "" end
    return (template:gsub("{{([%w_]+)}}", function(key)
        return tostring(values[key] or "")
    end))
end

local function open_topic(id)
    local path, err = topic_source.brief_path(id)
    if not path then
        vim.notify(err, vim.log.levels.WARN)
        return
    end
    edit_in_editor(path)
end

local function pick_note(id)
    local notes, err = topic_source.notes(id)
    if not notes then vim.notify(err, vim.log.levels.WARN); return end
    if #notes == 0 then vim.notify("No notes for " .. id, vim.log.levels.INFO); return end
    vim.ui.select(notes, { prompt = "Notes: " .. id, format_item = function(note)
        return note.date .. "  " .. note.title
    end }, function(note)
        if not note then return end
        vim.ui.select({ "Open note", "Resume source session" }, { prompt = note.title }, function(action)
            if action == "Open note" then
                edit_in_editor(note.path)
            elseif action == "Resume source session" and note.source.session and note.source.harness then
                open_session({
                    id = note.source.session, harness = note.source.harness,
                    title = note.title, project = note.source.project,
                })
            end
        end)
    end)
end

local function save_note(id, text, source)
    local path, err = topic_source.note(id, text, source)
    if not path then vim.notify(err, vim.log.levels.ERROR); return end
    vim.notify("Saved topic note: " .. path, vim.log.levels.INFO)
    refresh_topics()
    render()
end

function M.note(id, line_range)
    local text = selected_text("selection", line_range)
    if not text then return false end
    if vim.bo.buftype == "" then
        local path = vim.api.nvim_buf_get_name(0)
        if path ~= "" then
            local first, last
            if line_range then
                first, last = line_range[1], line_range[2]
            else
                local start_pos, end_pos = vim.fn.getpos("'<"), vim.fn.getpos("'>")
                if start_pos[2] > 0 and end_pos[2] > 0 then
                    first, last = math.min(start_pos[2], end_pos[2]), math.max(start_pos[2], end_pos[2])
                end
            end
            if first and last then
                path = vim.fn.fnamemodify(path, ":.")
                text = text .. string.format("\n\nSource: `%s:%d-%d`", path, first, last)
            end
        end
    end
    local source = vim.bo.buftype == "terminal" and selected_source() or { project = vim.fn.getcwd() }
    local function save(topic_id) save_note(topic_id, text, source) end
    if id then return save(id) end
    local term = terminals[selected]
    if term and term.topic_id then return save(term.topic_id) end
    choose_topic(save)
end

function M.attach_topic(index, id)
    local slot = slots[index]
    if not slot then return nil, "No agent slot " .. tostring(index) end
    local topic = id and topic_source.get(id)
    if id and not topic then return nil, "Topic not found: " .. tostring(id) end
    local path = state_dir .. "/" .. slot .. ".topic"
    -- An empty file is an explicit detach, including for old shells with topic env vars.
    local content = topic and config.topics.enabled and config.topics.deliver ~= false
        and { id, topic.dir, tostring(config.topics.brief_max_lines) } or {}
    local temporary = path .. ".tmp"
    vim.fn.writefile(content, temporary)
    if vim.fn.rename(temporary, path) ~= 0 then return nil, "Could not update slot attachment" end
    terminals[slot].topic_id = id
    terminals[slot].pending_topic = nil
    render()
    return true
end

function M.attached_topic(index)
    local term = terminals[slots[index]]
    return term and term.topic_id
end

local function send_topic_prompt(id, prompt, request)
    local term, entry = terminals[selected], states[selected]
    if not entry or entry.stale or entry.session == "none" or entry.session == "unknown" then
        vim.notify("Selected slot has no reported running agent session", vim.log.levels.WARN)
        return false
    end
    if term and term.topic_id and term.topic_id ~= id then
        vim.notify("Selected slot is attached to a different topic: " .. term.topic_id, vim.log.levels.WARN)
        return false
    end
    return send_to_selected(prompt, request)
end

local function open_capture_dialog(request)
    local source_slot = request.source.slot_id
    local source_term = terminals[source_slot]
    local source_buffer = source_term and source_term.bufnr
    local function restore()
        if terminals[source_slot] == source_term and source_term and source_term.bufnr == source_buffer
            and valid(terminal_win) then
            open_slot(source_slot)
            vim.cmd("startinsert")
        end
    end
    capture_ui.open(request, cached_topics, render, restore, function(candidate)
        local entry = states[source_slot]
        if not entry or entry.stale or entry.state ~= "idle" or entry.session ~= candidate.source.session
            or entry.agent ~= candidate.source.harness then
            return nil, "Source session is no longer reported idle; capture was not started"
        end
        candidate.source.status, candidate.source.reported = "idle", true
        return capture.validate(candidate)
    end)
end

function M.distill(id, focus)
    local function send(topic_id)
        local request = selected_capture_request("note")
        if not request then return end
        request.topic_id, request.focus = topic_id, focus
        open_capture_dialog(request)
    end
    if id then return send(id) end
    local term = terminals[selected]
    if term and term.topic_id then return send(term.topic_id) end
    local request = selected_capture_request("note")
    if request then open_capture_dialog(request) end
end

function M.brief(id, focus)
    local function send(topic_id)
        local request = selected_capture_request("brief")
        if not request then return end
        request.topic_id, request.focus = topic_id, focus
        open_capture_dialog(request)
    end
    if id then return send(id) end
    local term = terminals[selected]
    if term and term.topic_id then return send(term.topic_id) end
    local request = selected_capture_request("brief")
    if request then open_capture_dialog(request) end
end

function M.consolidate(id)
    local function send(topic_id)
        local topic = topic_source.get(topic_id)
        if not topic then vim.notify("Topic not found: " .. tostring(topic_id), vim.log.levels.WARN); return end
        local default_prompt = "Consolidate the unconsolidated notes in {{notes_path}} into {{proposal_path}}. "
            .. "Read the current brief at {{brief_path}} first. Preserve accurate existing knowledge, remove stale "
            .. "or contradicted claims, and include an Updated date. Do not edit brief.md directly; the proposal "
            .. "will be reviewed before it replaces the brief."
        local prompt = fill_prompt(type(config.topics.prompts) == "table" and config.topics.prompts.consolidate
            or default_prompt, {
            title = topic.title, notes_path = topic.dir .. "/notes", brief_path = topic.dir .. "/brief.md",
            proposal_path = topic.dir .. "/brief.proposed.md",
        })
        if send_topic_prompt(topic_id, prompt,
            "Please consolidate the topic notes using the pasted instructions. ") then
            topic_source.begin_consolidation(topic_id)
            vim.notify("Consolidation prompt is pasted; press Enter to send it", vim.log.levels.INFO)
            return true
        end
        return false
    end
    if id then return send(id) end
    local term = terminals[selected]
    if term and term.topic_id then return send(term.topic_id) end
    choose_topic(send)
end

function M.review_consolidation(id)
    local brief, err = topic_source.brief_path(id)
    if not brief then vim.notify(err, vim.log.levels.WARN); return end
    local proposal = brief:gsub("brief%.md$", "brief.proposed.md")
    if vim.fn.filereadable(proposal) ~= 1 then
        vim.notify("No brief.proposed.md exists for " .. id, vim.log.levels.WARN)
        return
    end
    edit_in_editor(brief)
    vim.cmd("diffthis")
    vim.cmd("vsplit " .. vim.fn.fnameescape(proposal))
    vim.cmd("diffthis")
    vim.notify("Review the diff, then run :AgentDashboard consolidate accept " .. id
        .. " or :AgentDashboard consolidate reject " .. id, vim.log.levels.INFO)
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
        "  Enter       Open slot, session, or topic brief",
        "  1-9         Open a slot (create the next slot)",
        "  a           Add a slot",
        "  x           Remove slot / delete recent session",
        "  Tab / C-l   Return to the active terminal",
        "  l / Right   Return to the active terminal",
        "  C-w l       Return to the active terminal",
        "  t           Attach / detach topic on a slot",
        "  n           Browse notes on a topic",
        "  D / C       Topic row: distill / consolidate",
        "  c           Slot/topic row: capture findings from the named source",
        "  y           Copy the session id of the row",
        "  D           Recent row: delete the session",
        "  ?           Show this help",
        "  q / Esc     Hide the dashboard", "", "Agent terminal",
        "  " .. (config.keys.list or "") .. "       Focus the sidebar",
        "  Tab / C-w h Focus sidebar (normal mode)",
        "  " .. (config.keys.next or "") .. " / " .. (config.keys.previous or "") .. "   Cycle slots",
        "  " .. (config.keys.hide or "") .. "       Hide the dashboard",
        "  " .. (config.keys.capture or "<M-c>") .. "       Capture findings from this idle session",
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
    vim.fn.delete(state_dir .. "/" .. id .. ".topic")
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

local function row_slot_index(id)
    for index, slot in ipairs(slots) do if slot == id then return index end end
end

local function attach_row_topic()
    local row = rows[vim.api.nvim_win_get_cursor(list_win)[1]]
    if not row or not row.slot then return end
    local index = row_slot_index(row.slot)
    local term = terminals[row.slot]
    if term.topic_id then
        M.attach_topic(index, nil)
        vim.notify("Detached topic from slot " .. index, vim.log.levels.INFO)
    else
        choose_topic(function(id)
            local ok, err = M.attach_topic(index, id)
            if not ok then vim.notify(err, vim.log.levels.WARN) end
        end)
    end
end

local function browse_skills()
    local roots = {
        vim.fn.expand("~/.claude/skills"),
        vim.fn.getcwd() .. "/.claude/skills",
    }
    local files, seen = {}, {}
    for _, root in ipairs(roots) do
        for _, path in ipairs(vim.fn.globpath(root, "*/SKILL.md", false, true)) do
            if not seen[path] then seen[path] = true; files[#files + 1] = path end
        end
    end
    table.sort(files)
    if #files == 0 then vim.notify("No Claude skills found", vim.log.levels.INFO); return end
    vim.ui.select(files, { prompt = "Skills", format_item = function(path)
        return vim.fn.fnamemodify(vim.fn.fnamemodify(path, ":h"), ":t") .. " — " .. path
    end }, function(path)
        if path then edit_in_editor(path) end
    end)
end

local function list_keymaps()
    local opts = { buffer = list_buf, silent = true }
    vim.keymap.set("n", "y", copy_session_id, opts)
    vim.keymap.set("n", "D", delete_recent_session, opts)
    vim.keymap.set("n", "q", hide, opts)
    vim.keymap.set("n", "<Esc>", hide, opts)
    vim.keymap.set("n", "a", add_slot, opts)
    vim.keymap.set("n", "x", function()
        local row = rows[vim.api.nvim_win_get_cursor(list_win)[1]]
        if row and row.slot then remove_slot()
        elseif row and row.session then delete_recent_session()
        else vim.notify("Select a terminal slot or recent session to remove", vim.log.levels.INFO) end
    end, opts)
    vim.keymap.set("n", "?", show_help, opts)
    local function capture_action(action)
        local row = rows[vim.api.nvim_win_get_cursor(list_win)[1]]
        if row and (row.capture or row.slot) then
            local ok, err = capture_ui.action(action, render)
            if not ok then vim.notify(err, vim.log.levels.WARN) end
        else
            vim.notify("Select the capture result row first", vim.log.levels.INFO)
        end
    end
    vim.keymap.set("n", "o", function() capture_action("open") end, opts)
    vim.keymap.set("n", "e", function() capture_action("error") end, opts)
    vim.keymap.set("n", "r", function() capture_action("review") end, opts)
    vim.keymap.set("n", "R", function() capture_action("retry") end, opts)
    vim.keymap.set("n", "X", function() capture_action("cancel") end, opts)
    vim.keymap.set("n", "d", function() capture_action("dismiss") end, opts)
    vim.keymap.set("n", "t", attach_row_topic, opts)
    vim.keymap.set("n", "n", function()
        local row = rows[vim.api.nvim_win_get_cursor(list_win)[1]]
        if row and row.topic then pick_note(row.topic.id) end
    end, opts)
    vim.keymap.set("n", "D", function()
        local row = rows[vim.api.nvim_win_get_cursor(list_win)[1]]
        if row and row.topic then M.distill(row.topic.id)
        elseif row and row.session then delete_recent_session() end
    end, opts)
    vim.keymap.set("n", "c", function()
        local row = rows[vim.api.nvim_win_get_cursor(list_win)[1]]
        if row and row.slot then
            local request = selected_capture_request("note", row.slot)
            if request then open_capture_dialog(request) end
        elseif row and row.topic then
            M.distill(row.topic.id)
        end
    end, opts)
    vim.keymap.set("n", "C", function()
        local row = rows[vim.api.nvim_win_get_cursor(list_win)[1]]
        if row and row.topic then M.consolidate(row.topic.id) end
    end, opts)
    vim.keymap.set("n", "<CR>", function()
        local row = rows[vim.api.nvim_win_get_cursor(list_win)[1]]
        if row and row.session then open_session(row.session)
        elseif row and row.capture then capture_action("open")
        elseif row and row.slot then open_slot(row.slot)
        elseif row and row.topic then open_topic(row.topic.id) end
    end, opts)
    for _, key in ipairs({ "<Tab>", "<C-l>", "l", "<Right>", "<C-w>l", "<C-w><C-l>" }) do
        vim.keymap.set("n", key, function() open_slot(selected) end, opts)
    end
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
    refresh_topics()
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
        if term and term.pending_topic and vim.uv.hrtime() >= term.pending_topic.deadline then
            term.pending_topic = nil
        end
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
                local pending = term.pending_topic
                if pending and (report.agent == "opencode" or report.agent == nil)
                    and report.session == pending.session
                    and report.state == "idle" and not stale and term.topic_id == pending.topic then
                    term.pending_topic = nil
                    local sent = pcall(vim.api.nvim_chan_send, term.job_id,
                        "\27[200~" .. pending.prompt .. "\27[201~")
                    if sent then term.topic_delivered = pending.topic end
                end
                if not entry or entry.session ~= report.session then
                    if term.session_id ~= report.session then term.title = nil end
                    term.session_id = report.session
                    entry = { session = report.session, seen = report.turn == 0, turn = 0 }
                    states[id] = entry
                end
                if type(report.project) == "string" and report.project:sub(1, 1) == "/" then
                    entry.project = report.project
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
                    if report.state == "idle" and report.turn > previous_turn and term.topic_id
                        and config.topics.auto_distill == "remind" and not stale
                        and term.reminded_session ~= report.session then
                        term.reminded_session = report.session
                        vim.notify("Turn finished with topic " .. term.topic_id
                            .. " attached; run :AgentDashboard distill to capture findings",
                            vim.log.levels.INFO, { title = "Agent Dashboard" })
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

local function handle_topic_command(args)
    local action, id = args[2], args[3]
    if action == "new" then
        if not id then vim.notify("Usage: AgentDashboard topic new <id>", vim.log.levels.WARN); return end
        local topic, err = topic_source.create(id)
        if not topic then vim.notify(err, vim.log.levels.WARN); return end
        refresh_topics()
        render()
        open_topic(id)
    elseif action == "open" then
        if id then open_topic(id) else choose_topic(open_topic) end
    elseif action == "list" then
        choose_topic(open_topic)
    elseif action == "attach" then
        if not id then vim.notify("Usage: AgentDashboard topic attach <id>", vim.log.levels.WARN); return end
        local ok, err = M.attach_topic(selected_index(), id)
        if not ok then vim.notify(err, vim.log.levels.WARN) end
    elseif action == "detach" then
        local ok, err = M.attach_topic(selected_index(), nil)
        if not ok then vim.notify(err, vim.log.levels.WARN) end
    elseif action == "export-skill" then
        if not id then vim.notify("Usage: AgentDashboard topic export-skill <id>", vim.log.levels.WARN); return end
        local path, err = topic_source.export_skill(id)
        vim.notify(path or err, path and vim.log.levels.INFO or vim.log.levels.ERROR)
    else
        vim.notify("Usage: AgentDashboard topic [new|open|list|attach|detach|export-skill]", vim.log.levels.WARN)
    end
end

local function prompt_arguments(args, offset)
    local id = args[offset]
    if id == "--" then id = nil end
    return id, table.concat(args, " ", offset + 1)
end

local function handle_consolidate_command(args, brief_mode)
    local action, id = args[2], args[3]
    local generate = brief_mode and M.brief or M.consolidate
    if action == "topic" then
        if brief_mode then generate(prompt_arguments(args, 3)) else generate(id) end
    elseif action == "accept" or action == "reject" then
        if not id then
            local term = terminals[selected]
            id = term and term.topic_id
        end
        if not id then vim.notify("Specify a topic id", vim.log.levels.WARN); return end
        local ok, err
        if action == "accept" then
            local topic = topic_source.get(id)
            local proposal = topic and (topic.dir .. "/brief.proposed.md")
            if proposal then
                local expected = vim.fn.fnamemodify(proposal, ":p")
                for _, buffer in ipairs(vim.api.nvim_list_bufs()) do
                    if vim.api.nvim_buf_is_loaded(buffer)
                        and vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buffer), ":p") == expected
                        and vim.bo[buffer].modified then
                        local saved, save_error = pcall(vim.api.nvim_buf_call, buffer, function()
                            vim.cmd("write")
                        end)
                        if not saved then vim.notify(tostring(save_error), vim.log.levels.ERROR); return end
                    end
                end
            end
            ok, err = topic_source.accept_proposal(id)
        else
            ok, err = topic_source.reject_proposal(id)
        end
        if not ok then vim.notify(err, vim.log.levels.ERROR)
        else
            vim.notify(action == "accept" and "Accepted topic brief proposal" or "Rejected topic brief proposal",
                vim.log.levels.INFO)
            if err then vim.notify(err, vim.log.levels.INFO) end
            refresh_topics()
            render()
            if action == "accept" then
                local brief = topic_source.brief_path(id)
                if brief then
                    local expected = vim.fn.fnamemodify(brief, ":p")
                    for _, buffer in ipairs(vim.api.nvim_list_bufs()) do
                        if vim.api.nvim_buf_is_loaded(buffer)
                            and vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buffer), ":p") == expected then
                            pcall(vim.api.nvim_buf_call, buffer, function() vim.cmd("edit!") end)
                        end
                    end
                    edit_in_editor(brief)
                end
            end
        end
    elseif action == "review" then
        if not id then
            local term = terminals[selected]
            id = term and term.topic_id
        end
        if id then M.review_consolidation(id) else choose_topic(M.review_consolidation) end
    else
        if brief_mode then generate(prompt_arguments(args, 2)) else generate(action) end
    end
end

function M.setup(opts)
    if timer then return end
    config = vim.tbl_deep_extend("force", config, opts or {})
    if type(config.topics) ~= "table" then
        config.topics = {
            enabled = config.topics ~= false,
            dir = vim.fn.stdpath("data") .. "/agent-dashboard/topics",
            brief_max_lines = 150, suggest_for_cwd = true, deliver = true, auto_distill = false,
        }
    end
    topic_source.setup(config.topics)
    capture.setup({ dir = config.capture_dir or (vim.fn.stdpath("state") .. "/agent-dashboard/capture"),
        on_change = function()
            refresh_topics()
            render()
        end })
    capture_ui.setup(capture, {
        review_brief = function(id) M.review_consolidation(id) end,
        open_result = function(path) edit_in_editor(path) end,
        validate_retry = function(request)
            local source = request.source
            local term, entry = terminals[source.slot_id], states[source.slot_id]
            if not term or term.exited or not entry or entry.stale or entry.state ~= "idle"
                or entry.session ~= source.session or entry.agent ~= source.harness then
                return nil, "Resume the original source in an idle slot before retrying capture"
            end
            return capture.validate(request)
        end,
    })
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
        elseif action == "topic" then
            handle_topic_command(args)
        elseif action == "note" then
            local line_range = command.range > 0 and { command.line1, command.line2 } or nil
            M.note(args[2], line_range)
        elseif action == "distill" then
            M.distill(prompt_arguments(args, 2))
        elseif action == "brief" then
            handle_consolidate_command(args, true)
        elseif action == "consolidate" then
            handle_consolidate_command(args)
        elseif action == "skills" then
            browse_skills()
        elseif action == "hooks" then
            vim.api.nvim_echo({ { M.hooks() } }, true, {})
        else
            vim.notify("Usage: AgentDashboard [toggle|open N|add|send|topic|note|distill|brief|consolidate|skills|hooks]",
                vim.log.levels.WARN)
        end
    end, { nargs = "*", range = true, desc = "Control the agent dashboard" })
    vim.api.nvim_create_autocmd("WinEnter", {
        callback = function()
            if not changing and list_visible() then
                local current = vim.api.nvim_get_current_win()
                if current ~= list_win and current ~= terminal_win and not capture_ui.owns_window(current) then hide() end
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
