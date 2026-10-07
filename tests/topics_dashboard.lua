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
local capture = require("agent_dashboard.capture")
local original_capture_setup = capture.setup
capture.setup = function(options)
    assert(options.models.claude == "claude-sonnet-5-5" and options.models.opencode == "openai/gpt-6.1-sol")
    assert(options.models.note.claude == "note-claude" and options.models.note.opencode == nil)
    assert(options.models.brief.opencode == "openai/brief-model" and options.models.brief.claude == nil)
    return original_capture_setup(options)
end
dashboard.setup({ tmux = false, capture_dir = topic_dir .. "/capture-journal", capture_models = {
    note = { claude = "note-claude" }, brief = { opencode = "openai/brief-model" },
}, topics = {
    dir = topic_dir,
    prompts = { distill = "Distill {{title}} into {{note_path}}. Metadata:\n{{source_frontmatter}}" },
} })
capture.setup = original_capture_setup
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
local original_input = vim.ui.input
vim.ui.input = function(options, callback)
    assert(options.prompt:find("New topic ID", 1, true))
    callback("new-capture-topic")
end
dialog_key("n")
vim.ui.input = original_input
dialog = capture_ui._dialog()
assert(dialog.topics[dialog.topic_index].id == "new-capture-topic")
assert(topic_source.get("new-capture-topic").projects[1] == dialog.request.source.project)
assert(vim.fn.filereadable(topic_source.brief_path("new-capture-topic")) == 1)
assert(dashboard.attached_topic(1) == "dashboard-notes", "creation does not change the slot attachment")
assert(vim.fn.readfile(attachment)[1] == "dashboard-notes")
assert(vim.api.nvim_get_current_buf() == dialog.buf, "creation keeps the capture popup focused")
assert(sends == 0, "topic creation does not send a prompt to the source")
assert(table.concat(vim.api.nvim_buf_get_lines(buffer, 0, -1, false), "\n"):find("new-capture-topic", 1, true),
    "new topics appear in the sidebar immediately")
assert(dialog.models.note == "note-claude" and dialog.models.brief == "claude-sonnet-5-5")
local original_select = vim.ui.select
local selected_model = "selected-note-claude"
vim.ui.select = function(items, _, callback)
    assert(items[1].model == dialog.models[selected_model == "selected-note-claude" and "note" or "brief"])
    callback(items[#items]) -- Enter another model ID.
end
vim.ui.input = function(options, callback)
    assert(options.prompt:find("model ID", 1, true))
    callback(selected_model)
end
dialog_key("m")
selected_model = "selected-brief-claude"
dialog_key("M")
vim.ui.select, vim.ui.input = original_select, original_input
assert(dialog.models.note == "selected-note-claude" and dialog.models.brief == "selected-brief-claude")
assert(vim.api.nvim_get_current_buf() == dialog.buf and sends == 0)
local original_start, submitted = capture.start
capture.start = function(request) submitted = request; return { state = "capturing", request = request } end
dialog_key("s")
capture.start = original_start
assert(submitted and submitted.source.session == "test-session")
assert(submitted.topic_id == "new-capture-topic")
assert(submitted.model == "selected-note-claude", "the submitted action uses its selected model")
assert(vim.api.nvim_get_current_buf() == shell_buffer, "submission restores the source terminal buffer")
assert(#vim.api.nvim_list_bufs() == before_buffers, "capture does not create another terminal")
assert(sends == 0, "dashboard and terminal capture actions never send to source")
dashboard.brief()
dialog = capture_ui._dialog()
local found_new_topic = false
for _, topic in ipairs(dialog.topics) do if topic.id == "new-capture-topic" then found_new_topic = true end end
assert(found_new_topic, "new topics remain available in later capture popups")
assert(dialog.topics[dialog.topic_index].id == "dashboard-notes", "the attached topic remains the default")
dialog_key("q")
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

-- Sidebar acceptance shares command behavior, including edited proposals and
-- stale-brief protection, without guessing from the attached/selected topic.
local original_current, original_dismiss = capture.current, capture.dismiss
local capture_result, dismissed = nil, 0
capture.current = function() return capture_result end
capture.dismiss = function()
    capture_result, dismissed = nil, dismissed + 1
    return original_dismiss()
end
local function brief_result(id, slot)
    capture_result = { state = "complete", request = { kind = "brief", topic_id = id,
        source = { harness = "claude", session = "test-session", slot_id = slot } } }
end
local function select_sidebar_row(pattern)
    dashboard.focus_list()
    assert(dashboard.attach_topic(1, "dashboard-notes")) -- Refresh the mocked capture rows.
    local sidebar = vim.api.nvim_get_current_buf()
    for row, line in ipairs(vim.api.nvim_buf_get_lines(sidebar, 0, -1, false)) do
        if line:find(pattern) then
            vim.api.nvim_win_set_cursor(0, { row, 0 })
            return sidebar, line
        end
    end
    error("Missing sidebar row " .. pattern)
end
local new_brief = topic_source.brief_path("new-capture-topic")
local proposal = assert(topic_source.propose_brief("new-capture-topic", "# Proposed brief"))
brief_result("new-capture-topic", 101)
select_sidebar_row("^ 2 ")
vim.api.nvim_feedkeys("A", "xt", false)
assert(vim.fn.filereadable(proposal) == 1 and dismissed == 0, "unrelated slot cannot accept the latest proposal")
local _, hint = select_sidebar_row("A accept")
assert(hint:find("r review", 1, true))
local proposal_buf = vim.fn.bufadd(proposal)
vim.fn.bufload(proposal_buf)
vim.api.nvim_buf_set_lines(proposal_buf, 0, -1, false, { "# Edited brief" })
assert(vim.bo[proposal_buf].modified)
vim.api.nvim_feedkeys("A", "xt", false)
assert(table.concat(vim.fn.readfile(new_brief), "\n") == "# Edited brief",
    "acceptance saves unsaved proposal edits: " .. table.concat(vim.fn.readfile(new_brief), "\n"))
assert(vim.fn.filereadable(proposal) == 0 and dismissed == 1 and capture_result == nil)
assert(vim.uv.fs_realpath(vim.api.nvim_buf_get_name(0)) == vim.uv.fs_realpath(new_brief),
    "acceptance opens the accepted brief")
assert(dashboard.attached_topic(1) == "dashboard-notes")

-- Topic-row acceptance also works without a matching brief capture result.
local topic_proposal = assert(topic_source.propose_brief("dashboard-notes", "# Accepted from topic row"))
capture_result = { state = "complete", request = { kind = "note", topic_id = "new-capture-topic",
    source = { session = "test-session", slot_id = 101 } } }
select_sidebar_row("^ %* dashboard%-notes")
vim.api.nvim_feedkeys("A", "xt", false)
assert(vim.fn.filereadable(topic_proposal) == 0 and dismissed == 1)
assert(capture_result and capture_result.request.kind == "note", "unrelated capture results are retained")
assert(table.concat(vim.fn.readfile(topic_source.brief_path("dashboard-notes")), "\n") == "# Accepted from topic row")
assert(not topic_source.notes("dashboard-notes")[1].consolidated)

-- Orphan action rows have the same accept mapping as source-slot results.
proposal = assert(topic_source.propose_brief("new-capture-topic", "# Accepted orphan proposal"))
brief_result("new-capture-topic", 999)
select_sidebar_row("^   Capture:.*A accept")
vim.api.nvim_feedkeys("A", "xt", false)
assert(vim.fn.filereadable(proposal) == 0 and dismissed == 2 and capture_result == nil)
assert(table.concat(vim.fn.readfile(new_brief), "\n") == "# Accepted orphan proposal")

-- A failed acceptance keeps the pending capture/proposal; the command uses the
-- same handler once the original brief is restored.
proposal = assert(topic_source.propose_brief("new-capture-topic", "# Accepted by command"))
brief_result("new-capture-topic", 101)
vim.fn.writefile({ "# Brief changed after proposal" }, new_brief)
select_sidebar_row("A accept")
vim.api.nvim_feedkeys("A", "xt", false)
assert(vim.fn.filereadable(proposal) == 1 and capture_result ~= nil and dismissed == 2)
assert(table.concat(vim.fn.readfile(new_brief), "\n") == "# Brief changed after proposal")
vim.fn.writefile({ "# Accepted orphan proposal" }, new_brief)
vim.cmd("AgentDashboard brief accept new-capture-topic")
assert(table.concat(vim.fn.readfile(new_brief), "\n") == "# Accepted by command")
assert(vim.api.nvim_buf_get_lines(0, 0, -1, false)[1] == "# Accepted by command", "loaded brief buffers refresh")
assert(capture_result == nil and dismissed == 3)
capture.current, capture.dismiss = original_current, original_dismiss

vim.api.nvim_create_autocmd("VimLeavePre", {
    once = true,
    callback = function() vim.fn.delete(topic_dir, "rf") end,
})
vim.cmd("qa!")
