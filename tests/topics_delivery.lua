vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.o.lines, vim.o.columns = 45, 120
local root = vim.fn.tempname()
local project = root .. "/other-project"
vim.fn.mkdir(project, "p")
-- Claude hook reports use the hook's source cwd, not the terminal's startup cwd.
local report_dir = root .. "/reports"
vim.fn.mkdir(report_dir, "p")
local old_dir, old_slot = vim.env.NVIM_AGENT_DASHBOARD_DIR, vim.env.NVIM_AGENT_SLOT
vim.env.NVIM_AGENT_DASHBOARD_DIR, vim.env.NVIM_AGENT_SLOT = report_dir, "109"
local reporter = vim.fn.getcwd() .. "/extras/claude/agent-dashboard-report.sh"
local report = vim.fn.system({ "bash", reporter, "start" }, vim.json.encode({
    session_id = "cwd-session", source = "startup", cwd = project,
}))
assert(vim.v.shell_error == 0, report)
local source_state = vim.json.decode(table.concat(vim.fn.readfile(report_dir .. "/109.json")))
assert(source_state.project == project)
vim.env.NVIM_AGENT_DASHBOARD_DIR, vim.env.NVIM_AGENT_SLOT = old_dir, old_slot
local topics = require("agent_dashboard.topics")
topics.setup({ dir = root .. "/topics" })
assert(topics.create("delivery"))
local sessions = {
    { harness = "opencode", id = "ses_first", title = "First" },
    { harness = "opencode", id = "ses_failed", title = "Failed" },
    { harness = "claude", id = "note-session", project = project, title = "Other project" },
    { harness = "claude", id = "regular-session", title = "Current project" },
}
package.loaded["agent_dashboard.sessions"] = {
    refresh = function(_, callback) callback(sessions) end,
}
local has, termopen, executable = vim.fn.has, vim.fn.termopen, vim.fn.executable
local children, chan_send = vim.api.nvim_get_proc_children, vim.api.nvim_chan_send
local options, sent = {}, {}
vim.fn.has = function(feature) return feature == "nvim-0.11" and 0 or has(feature) end
vim.fn.termopen = function(command, opts)
    options[tonumber(opts.env.NVIM_AGENT_SLOT)] = opts
    return termopen(command, opts)
end
vim.fn.executable = function(name)
    return (name == "claude" or name == "opencode") and 1 or executable(name)
end
vim.api.nvim_get_proc_children = function() return {} end
vim.api.nvim_chan_send = function(_, text) sent[#sent + 1] = text end
local dashboard = require("agent_dashboard")
dashboard.setup({ tmux = false, topics = { dir = topics.directory(), opencode_prompt_timeout_ms = 2200 },
    capture_dir = root .. "/capture" })
dashboard.toggle()
assert(dashboard.attach_topic(1, "delivery"))
local function open_recent(id)
    dashboard.focus_list()
    local buf = vim.api.nvim_get_current_buf()
    local label
    for _, session in ipairs(sessions) do if session.id == id then label = session.title end end
    for row, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
        if line:find(label, 1, true) and line:match("^ [OC][CC] ") then
            vim.api.nvim_win_set_cursor(0, { row, 0 })
            vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "xt", false)
            return
        end
    end
    error("Recent session row not found: " .. id)
end
local function report(slot, session, state, agent)
    vim.fn.writefile({ vim.json.encode({ slot = slot, time = os.time(), session = session,
        turn = 0, state = state, agent = agent or "opencode" }) },
        options[slot].env.NVIM_AGENT_DASHBOARD_DIR .. "/" .. slot .. ".json")
end
open_recent("ses_first")
assert(#sent == 1 and sent[1]:find("opencode --session", 1, true))
report(101, "ses_first", "working")
assert(not vim.wait(1200, function() return #sent > 1 end)) -- No delivery to a busy agent.
report(101, "ses_first", "idle")
assert(vim.wait(1600, function() return #sent == 2 end))
assert(sent[2]:sub(-6) == "\27[201~" and not sent[2]:find("`", 1, true))
open_recent("ses_first")
assert(not vim.wait(200, function() return #sent > 2 end)) -- Switching never redelivers.

dashboard.toggle_slot(2)
assert(dashboard.attach_topic(2, "delivery"))
open_recent("ses_failed")
local count = #sent
assert(not vim.wait(2600, function() return #sent > count end)) -- No report: leave the shell alone.
report(102, "ses_failed", "idle")
assert(not vim.wait(1200, function() return #sent > count end)) -- Late report cannot resurrect timeout.

-- A slot resumed into another project must return to the editor cwd for regular resumes.
dashboard.toggle_slot(3)
open_recent("note-session")
assert(vim.fn.fnamemodify(options[103].cwd, ":p") == vim.fn.fnamemodify(project, ":p"))
report(103, "note-session", "blocked", "claude")
assert(vim.wait(1600, function() return dashboard.status() == "!" end))
dashboard.focus_list()
local buf = vim.api.nvim_get_current_buf()
local expected_row
for row, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    if line:match("^ 3 ") then expected_row = row - 1 end
end
local correct_highlight = false
for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, dashboard.ns, 0, -1, { details = true })) do
    if mark[4].hl_group == "AgentDashboardBlocked" then correct_highlight = mark[2] == expected_row end
end
assert(correct_highlight)
vim.fn.delete(options[103].env.NVIM_AGENT_DASHBOARD_DIR .. "/103.json")
assert(vim.wait(1600, function() return dashboard.status() ~= "!" end))
open_recent("regular-session")
assert(vim.fn.fnamemodify(options[103].cwd, ":p") == vim.fn.fnamemodify(vim.fn.getcwd(), ":p"))

local readfile, reads = vim.fn.readfile, 0
vim.fn.readfile = function(path, ...)
    if path:find("/topics/", 1, true) then reads = reads + 1 end
    return readfile(path, ...)
end
dashboard.focus_list()
dashboard.attach_topic(3, "delivery") -- One metadata read for validation, no note scan on render.
reads = 0
dashboard.cycle_slot(1)
dashboard.focus_list()
assert(reads == 0)
vim.fn.readfile = readfile
dashboard.toggle_slot(1)
dashboard.distill("delivery")
local capture_ui = require("agent_dashboard.capture_ui")
local function check_capture(kind, focus)
    local dialog = capture_ui._dialog()
    assert(dialog and vim.api.nvim_win_is_valid(dialog.win))
    local text = table.concat(vim.api.nvim_buf_get_lines(dialog.buf, 0, -1, false), "\n")
    assert(text:find("Source: opencode / ses_first", 1, true))
    assert(text:find("Topic:.*delivery"))
    assert(dialog.request.topic_id == "delivery")
    if focus ~= nil then assert(dialog.focus == focus) end
    local before = #sent
    local close
    for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(dialog.buf, "n")) do
        if mapping.lhs == "q" then close = mapping.callback end
    end
    assert(type(close) == "function")
    close()
    dashboard.focus_list()
    return before
end
local before = check_capture("note", nil)
assert(#sent == before, "capture dialog must not send to source terminal")
vim.cmd("AgentDashboard brief delivery")
before = check_capture("brief", nil)
assert(#sent == before, "brief capture dialog must not send to source terminal")
vim.cmd("AgentDashboard distill delivery user state API responses and permissions")
check_capture("note", "user state API responses and permissions")
vim.cmd("AgentDashboard distill -- token creation and expiration")
check_capture("note", "token creation and expiration")
vim.cmd("AgentDashboard brief -- clarify transfer acceptance criteria")
check_capture("brief", "clarify transfer acceptance criteria")
vim.cmd("AgentDashboard brief topic delivery system responsibilities")
check_capture("brief", "system responsibilities")
dashboard.distill("delivery", "   ")
check_capture("note", nil)
vim.cmd("AgentDashboard consolidate delivery")
assert(sent[#sent]:match("^(.-)\27%[200~") ==
    "Please consolidate the topic notes using the pasted instructions. ")
assert(sent[#sent]:sub(-6) == "\27[201~")
vim.fn.has, vim.fn.termopen, vim.fn.executable = has, termopen, executable
vim.api.nvim_get_proc_children, vim.api.nvim_chan_send = children, chan_send
vim.fn.delete(root, "rf")
vim.cmd("qa!")
