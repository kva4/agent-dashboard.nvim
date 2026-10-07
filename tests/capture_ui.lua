vim.opt.runtimepath:prepend(vim.fn.getcwd())
package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path
local ui = require("agent_dashboard.capture_ui")
local topic_source = require("agent_dashboard.topics")
local topic_dir = vim.fn.tempname() .. "/topics"
topic_source.setup({ dir = topic_dir })
assert(topic_source.create("alpha", { title = "Alpha" }))
assert(topic_source.create("beta", { title = "Beta" }))
vim.api.nvim_create_autocmd("VimLeavePre", {
    once = true,
    callback = function() vim.fn.delete(topic_dir, "rf") end,
})
local started, allow, restored = nil, false, 0
local creations, created_source, changes = 0, nil, 0
local accepted_topic, accept_calls, allow_accept = nil, 0, false
local model_history = require("agent_dashboard.capture_model_history")
model_history.setup(topic_dir .. "/model-history.json")
local model_defaults = { claude = { note = "sonnet", brief = "opus" },
    opencode = { note = "openai/note-default", brief = "openai/brief-default" } }
local job = { state = "failed", request = { kind = "note", topic_id = "alpha", source = { session = "session-a", slot_id = 1 } }, error = "deliberate" }
ui.setup({
    start = function(request)
        if not allow then return nil, "topic validation failed" end
        assert(model_history.remember(request.source.harness, request.kind, request.model))
        started = request; job.state = "capturing"; job.request = request; return job
    end,
    current = function() return job end,
    retry = function() return true end, cancel = function() return true end,
    dismiss = function() return true end,
    validate_model = model_history.validate,
    model_options = function(request)
        local defaults = model_defaults[request.source.harness]
        return { current = request.model or model_history.get(request.source.harness, request.kind) or defaults[request.kind],
            default = defaults[request.kind], choices = { defaults.note, defaults.brief } }
    end,
}, {
    accept_brief = function(id)
        accepted_topic, accept_calls = id, accept_calls + 1
        if not allow_accept then return nil, "brief.md changed since proposal" end
        return true
    end,
    create_topic = function(id, source)
        creations, created_source = creations + 1, source
        return topic_source.create(id, { projects = { source.project } })
    end,
})
local win, buf = ui.open({ kind = "note", source = { harness = "claude", session = "session-a", project = "/tmp", slot_id = 1 } },
    { { id = "alpha", title = "Alpha" }, { id = "beta", title = "Beta" } }, function() end, function() restored = restored + 1 end,
    function() return true end)
assert(vim.api.nvim_win_is_valid(win) and vim.api.nvim_buf_is_valid(buf))
assert(vim.api.nvim_get_current_win() == win, "popover takes focus while open")
local function text() return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n") end
assert(text():find("Source: claude / session%-a"))
assert(text():find("Topic:.*Alpha %[%alpha%]"))
assert(text():find("Save findings", 1, true) and text():find("Propose brief", 1, true))
assert(text():find("[n] New topic", 1, true))
assert(text():find("Notes model: sonnet [m]", 1, true) and text():find("Brief model: opus [M]", 1, true))
assert(vim.api.nvim_win_get_cursor(win)[1] == 3)
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Tab>", true, false, true), "xt", false)
assert(vim.api.nvim_win_get_cursor(win)[1] == 4)
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<S-Tab>", true, false, true), "xt", false)
assert(vim.api.nvim_win_get_cursor(win)[1] == 3)
-- Editing focus uses a real input UI and returns to the popover; no source terminal
-- command line or agent channel is involved.
local input_options
local old_input = vim.ui.input
vim.ui.input = function(options, callback)
    input_options = options
    callback("verify recovery")
end
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Tab>", true, false, true), "xt", false)
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "xt", false)
vim.ui.input = old_input
assert(input_options and input_options.prompt:find("Capture focus", 1, true))
assert(ui._dialog().focus == "verify recovery" and vim.api.nvim_get_current_win() == win)
vim.api.nvim_win_set_cursor(win, { 9, 0 })
vim.api.nvim_feedkeys("s", "xt", false)
assert(text():find("topic validation failed", 1, true) and vim.api.nvim_win_is_valid(win))
allow = true
vim.api.nvim_feedkeys("s", "xt", false)
assert(started and started.kind == "note" and started.topic_id == "alpha")
assert(started.model == "sonnet")
assert(not vim.api.nvim_win_is_valid(win) and restored == 1)
assert(vim.deep_equal(ui.row_items(), { "cancel" }))
assert(ui.action("cancel"))
assert(ui.summary(1):find("Capturing findings", 1, true))
job.state = "failed"
assert(vim.deep_equal(ui.row_items(), { "error", "open", "retry", "dismiss" }))
assert(ui.action("retry"))
job.state = "complete"
assert(vim.deep_equal(ui.row_items(), { "open", "dismiss" }))
local ok, err = ui.action("accept")
assert(not ok and err == "No completed brief proposal to accept" and accept_calls == 0)

-- Create a destination in-place without changing the source, focus, or attachment.
local request = { kind = "brief", topic_id = "alpha", focus = "keep this focus",
    source = { harness = "claude", session = "session-a", project = "/source-project", slot_id = 1 } }
win, buf = ui.open(request, topic_source.list(), function() changes = changes + 1 end,
    function() restored = restored + 1 end)
local function topic_input(value, key)
    vim.ui.input = function(options, callback)
        input_options = options
        callback(value)
    end
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(key or "n", true, false, true), "xt", false)
    vim.ui.input = old_input
end
topic_input(nil)
topic_input("   ")
assert(creations == 0 and #ui._dialog().topics == 2 and changes == 0)
topic_input("Invalid Topic")
assert(text():find("Topic IDs may contain", 1, true))
assert(ui._dialog().topics[ui._dialog().topic_index].id == "alpha")
topic_input("alpha")
assert(text():find("Topic already exists: alpha", 1, true))
assert(#ui._dialog().topics == 2 and changes == 0)
topic_input(" gamma ")
assert(input_options.prompt:find("New topic ID", 1, true))
assert(ui._dialog().topics[ui._dialog().topic_index].id == "gamma" and #ui._dialog().topics == 3)
assert(ui._dialog().focus == "keep this focus" and ui._dialog().error == nil)
assert(vim.deep_equal(ui._dialog().request, request), "topic creation leaves the source request untouched")
assert(vim.deep_equal(created_source, request.source))
assert(topic_source.get("gamma").projects[1] == "/source-project")
assert(changes == 1 and vim.api.nvim_get_current_win() == win)
vim.api.nvim_feedkeys("b", "xt", false)
assert(started.kind == "brief" and started.topic_id == "gamma" and started.focus == "keep this focus")
assert(not vim.api.nvim_win_is_valid(win) and restored == 2)
ok, err = ui.action("accept")
assert(not ok and err == "No completed brief proposal to accept" and accept_calls == 0)
job.state = "complete"
assert(vim.deep_equal(ui.row_items(), { "review", "accept", "dismiss" }))
job.cleanup_error = "cleanup pending"
assert(vim.deep_equal(ui.row_items(), { "review", "accept", "error", "dismiss" }))
local accepted_changes = 0
local function acceptance_changed() accepted_changes = accepted_changes + 1 end
ok, err = ui.action("accept", acceptance_changed)
assert(not ok and err == "brief.md changed since proposal" and accepted_changes == 0)
assert(accepted_topic == "gamma" and accept_calls == 1)
allow_accept = true
assert(ui.action("accept", acceptance_changed))
assert(accepted_topic == "gamma" and accept_calls == 2 and accepted_changes == 1)
job.cleanup_error = nil

-- The navigable New topic action works even before any topics exist in the popup.
win = ui.open({ kind = "brief", source = { harness = "opencode", session = "orphan-source", project = "/tmp" } }, {}, nil,
    function() restored = restored + 1 end)
buf = ui._dialog().buf
assert(ui.summary():find("Orphan capture", 1, true))
vim.api.nvim_feedkeys("s", "xt", false)
assert(text():find("Choose a topic first", 1, true))
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "xt", false)
assert(text():find("press n to create one", 1, true))
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Tab><Tab><Tab><Tab>", true, false, true), "xt", false)
assert(vim.api.nvim_win_get_cursor(win)[1] == 8)
topic_input("delta", "<CR>")
assert(ui._dialog().topics[ui._dialog().topic_index].id == "delta")
assert(ui._dialog().error == nil and vim.api.nvim_get_current_win() == win)
vim.api.nvim_feedkeys("s", "xt", false)
assert(started.kind == "note" and started.topic_id == "delta" and restored == 3)

-- An input callback from a closed popup must not create a topic in a later popup.
win = ui.open(request, {}, nil, function() restored = restored + 1 end)
local pending_input
vim.ui.input = function(_, callback) pending_input = callback end
vim.api.nvim_feedkeys("n", "xt", false)
vim.ui.input = old_input
assert(type(pending_input) == "function")
vim.api.nvim_feedkeys("q", "xt", false)
win = ui.open(request, {}, nil, function() restored = restored + 1 end)
pending_input("stale-topic")
assert(topic_source.get("stale-topic") == nil and #ui._dialog().topics == 0)
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "xt", false)
assert(restored == 5)

-- Selecting a model is scoped to the chosen action and remembered only on submit.
request = { kind = "note", topic_id = "alpha", focus = "keep the focus",
    source = { harness = "opencode", session = "session-b", project = "/tmp", slot_id = 2 } }
local function open_models()
    win, buf = ui.open(request, topic_source.list())
    return ui._dialog()
end
local old_select = vim.ui.select
local selected_items, select_options
local function pick(key, predicate, value)
    vim.ui.select = function(items, options, callback)
        selected_items, select_options = items, options
        local choice
        for _, item in ipairs(items) do if predicate(item) then choice = item; break end end
        callback(choice)
    end
    vim.ui.input = function(options, callback) input_options = options; callback(value) end
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(key, true, false, true), "xt", false)
    vim.ui.select, vim.ui.input = old_select, old_input
end
local function custom(item) return item.custom end
local active = open_models()
pick("m", function() return false end)
assert(selected_items[1].model == "openai/note-default" and selected_items[1].label:find("selected", 1, true))
assert(select_options.prompt:find("Notes capture model", 1, true))
assert(active.models.note == "openai/note-default", "cancelling the picker leaves selection unchanged")
pick("m", custom, nil)
assert(active.models.note == "openai/note-default" and active.error == nil)
pick("m", custom, "missing-provider")
assert(text():find("provider/model format", 1, true) and active.models.note == "openai/note-default")
pick("m", custom, " openai/new-note ")
assert(input_options.default == "openai/note-default" and active.models.note == "openai/new-note")
assert(active.models.brief == "openai/brief-default" and active.focus == "keep the focus" and active.error == nil)
assert(model_history.get("opencode", "note") == "openai/note-default", "editing alone is not last-used")
pick("M", custom, "openai/new-brief")
assert(select_options.prompt:find("Brief capture model", 1, true))
assert(active.models.note == "openai/new-note" and active.models.brief == "openai/new-brief")
vim.api.nvim_feedkeys("b", "xt", false)
assert(started.kind == "brief" and started.model == "openai/new-brief")
active = open_models()
assert(active.models.note == "openai/note-default" and active.models.brief == "openai/new-brief")
pick("m", custom, "openai/new-note")
vim.api.nvim_feedkeys("s", "xt", false)
model_history.setup(topic_dir .. "/model-history.json") -- Simulate reloading persistent preferences.
active = open_models()
assert(active.models.note == "openai/new-note" and active.models.brief == "openai/new-brief")
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Tab><Tab>", true, false, true), "xt", false)
assert(vim.api.nvim_win_get_cursor(win)[1] == 5)
pick("<CR>", function(item) return item.label:find("Use configured default", 1, true) end)
assert(active.models.note == "openai/note-default" and active.models.brief == "openai/new-brief")
vim.api.nvim_feedkeys("s", "xt", false)
assert(started.model == "openai/note-default")
active = open_models()
local stale_input
vim.ui.select = function(items, _, callback) callback(items[#items]) end
vim.ui.input = function(_, callback) stale_input = callback end
vim.api.nvim_feedkeys("m", "xt", false)
vim.ui.select, vim.ui.input = old_select, old_input
assert(type(stale_input) == "function")
vim.api.nvim_feedkeys("q", "xt", false)
active = open_models()
stale_input("openai/stale-model")
assert(active.models.note == "openai/note-default" and model_history.get("opencode", "note") == "openai/note-default")
vim.api.nvim_feedkeys("q", "xt", false)
print("capture UI tests passed")
vim.cmd("qa!")
