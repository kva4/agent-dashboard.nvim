vim.opt.runtimepath:prepend(vim.fn.getcwd())
package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path
local ui = require("agent_dashboard.capture_ui")
local started, allow, restored = nil, false, 0
local job = { state = "failed", request = { kind = "note", topic_id = "alpha", source = { session = "session-a", slot_id = 1 } }, error = "deliberate" }
ui.setup({
    start = function(request)
        if not allow then return nil, "topic validation failed" end
        started = request; job.state = "capturing"; job.request = request; return job
    end,
    current = function() return job end,
    retry = function() return true end, cancel = function() return true end,
    dismiss = function() return true end,
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
vim.api.nvim_win_set_cursor(win, { 6, 0 })
vim.api.nvim_feedkeys("s", "xt", false)
assert(text():find("topic validation failed", 1, true) and vim.api.nvim_win_is_valid(win))
allow = true
vim.api.nvim_feedkeys("s", "xt", false)
assert(started and started.kind == "note" and started.topic_id == "alpha")
assert(not vim.api.nvim_win_is_valid(win) and restored == 1)
assert(vim.deep_equal(ui.row_items(), { "cancel" }))
assert(ui.action("cancel"))
assert(ui.summary(1):find("Capturing findings", 1, true))
job.state = "failed"
assert(vim.deep_equal(ui.row_items(), { "error", "open", "retry", "dismiss" }))
assert(ui.action("retry"))
job.state = "complete"
assert(vim.deep_equal(ui.row_items(), { "open", "dismiss" }))
win = ui.open({ kind = "brief", source = { harness = "opencode", session = "orphan-source", project = "/tmp" } }, {}, nil,
    function() restored = restored + 1 end)
assert(ui.summary():find("Orphan capture", 1, true))
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "xt", false)
assert(restored == 2)
print("capture UI tests passed")
vim.cmd("qa!")
