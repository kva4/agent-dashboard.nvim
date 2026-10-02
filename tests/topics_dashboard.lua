vim.opt.runtimepath:prepend(vim.fn.getcwd())
package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path

local topic_source = require("agent_dashboard.topics")
local topic_dir = vim.fn.tempname() .. "/topics"
topic_source.setup({ dir = topic_dir })
assert(topic_source.create("dashboard-notes", { title = "Dashboard notes" }))

local dashboard = require("agent_dashboard")
local has, termopen = vim.fn.has, vim.fn.termopen
local terminal_options
vim.fn.has = function(feature)
    if feature == "nvim-0.11" then return 0 end
    return has(feature)
end
vim.fn.termopen = function(command, options)
    terminal_options = options
    return termopen(command, options)
end
dashboard.setup({ tmux = false, capture_dir = topic_dir .. "/capture-journal", topics = {
    dir = topic_dir,
    prompts = { distill = "Distill {{title}} into {{note_path}}. Metadata:\n{{source_frontmatter}}" },
} })
dashboard.toggle()
local shell_buffer = vim.api.nvim_get_current_buf()
assert(dashboard.attach_topic(1, "dashboard-notes"))
assert(vim.api.nvim_get_current_buf() == shell_buffer) -- Attach preserves shell state.
local attachment = terminal_options.env.NVIM_AGENT_DASHBOARD_DIR .. "/101.topic"
assert(vim.fn.readfile(attachment)[2] == topic_source.get("dashboard-notes").dir)
dashboard.toggle_slot(2)
assert(topic_source.attach(2, "dashboard-notes"))
vim.fn.has, vim.fn.termopen = has, termopen
dashboard.toggle_slot(1)
dashboard.focus_list()
local buffer = vim.api.nvim_get_current_buf()
local original_chan_send = vim.api.nvim_chan_send
local sends = 0
vim.api.nvim_chan_send = function() sends = sends + 1; return true end
dashboard.distill("dashboard-notes")
assert(sends == 0, "capture never sends a terminal prompt")
local report_file = terminal_options.env.NVIM_AGENT_DASHBOARD_DIR .. "/101.json"
vim.fn.writefile({ vim.json.encode({ slot = 101, time = os.time(), session = "test-session",
    turn = 0, state = "idle", agent = "claude" }) }, report_file)
assert(vim.wait(1600, function() return dashboard.status() == "○" end))
local capture_ui = require("agent_dashboard.capture_ui")
local function dialog_key(key)
    local active = assert(capture_ui._dialog())
    for _, map in ipairs(vim.api.nvim_buf_get_keymap(active.buf, "n")) do
        if map.lhs == key then return map.callback() end
    end
    error("Missing capture key " .. key)
end
dashboard.distill("dashboard-notes")
local dialog = capture_ui._dialog()
assert(dialog and dialog.request.source.session == "test-session")
assert(dialog.request.source.harness == "claude" and dialog.request.source.project)
assert(sends == 0, "idle capture still does not send to terminal")
dialog_key("q")
dashboard.distill("dashboard-notes", "permission checks only")
dialog = capture_ui._dialog()
assert(dialog and dialog.focus == "permission checks only")
assert(dialog.request.source.session == "test-session")
assert(sends == 0, "focused capture does not paste to terminal")
dialog_key("q")
dashboard.focus_list()
-- Exercise the dashboard action on a slot row, then the actual buffer-local
-- terminal shortcut and submission focus restoration without a model request.
vim.api.nvim_win_set_cursor(0, { 3, 0 })
vim.api.nvim_feedkeys("c", "xt", false)
assert(capture_ui._dialog().request.source.slot_id == 101)
dialog_key("q")
assert(vim.api.nvim_get_current_buf() == shell_buffer, "expected source buffer " .. shell_buffer .. ", got " .. vim.api.nvim_get_current_buf() .. ": " .. vim.api.nvim_buf_get_name(0))
local terminal_map = vim.fn.maparg("<M-c>", "t", false, true)
assert(type(terminal_map.callback) == "function", "terminal capture shortcut is buffer-local")
local before_buffers = #vim.api.nvim_list_bufs()
terminal_map.callback()
assert(capture_ui._dialog() and vim.bo.buftype == "nofile")
local capture = require("agent_dashboard.capture")
local original_start, submitted = capture.start
capture.start = function(request) submitted = request; return { state = "capturing", request = request } end
dialog_key("s")
capture.start = original_start
assert(submitted and submitted.source.session == "test-session")
assert(vim.api.nvim_get_current_buf() == shell_buffer, "submission restores the source terminal buffer")
assert(#vim.api.nvim_list_bufs() == before_buffers, "capture does not create another terminal")
assert(sends == 0, "dashboard and terminal capture actions never send to source")
dashboard.focus_list()
vim.api.nvim_chan_send = original_chan_send
local content = table.concat(vim.api.nvim_buf_get_lines(buffer, 0, -1, false), "\n")
assert(content:find("TOPICS", 1, true))
assert(content:find("dashboard-notes", 1, true))

vim.cmd("AgentDashboard topic detach")
assert(#vim.fn.readfile(attachment) == 0)
local slot_line = vim.api.nvim_buf_get_lines(buffer, 2, 3, false)[1]
assert(not slot_line:find("dashboard-notes", 1, true))
vim.cmd("AgentDashboard topic attach dashboard-notes")
local topic_line = vim.api.nvim_buf_get_lines(buffer, 3, 4, false)[1]
assert(topic_line:find("dashboard-notes", 1, true), topic_line)
vim.cmd("1AgentDashboard note dashboard-notes")
assert(#topic_source.notes("dashboard-notes") == 1)
local lines = vim.api.nvim_buf_get_lines(buffer, 0, -1, false)
local topic_row
for index, line in ipairs(lines) do
    if line == " TOPICS" then topic_row = index + 1; break end
end
assert(topic_row and lines[topic_row]:find("dashboard-notes", 1, true))
vim.api.nvim_win_set_cursor(0, { topic_row, 0 })
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "xt", false)
local opened = vim.api.nvim_buf_get_name(0)
assert(vim.fn.fnamemodify(opened, ":t") == "brief.md")
assert(vim.fn.fnamemodify(vim.fn.fnamemodify(opened, ":h"), ":t") == "dashboard-notes")
dashboard.note("dashboard-notes", { 1, 1 })
local notes = topic_source.notes("dashboard-notes")
assert(#notes == 2)
assert(notes[2].source.session == nil and notes[2].source.harness == nil)
assert(table.concat(vim.fn.readfile(notes[2].path), "\n"):find("brief.md:1-1", 1, true))

vim.api.nvim_create_autocmd("VimLeavePre", {
    once = true,
    callback = function() vim.fn.delete(topic_dir, "rf") end,
})
vim.cmd("qa!")
