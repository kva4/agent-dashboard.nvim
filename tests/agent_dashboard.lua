package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path

local source = require("agent_dashboard.sessions")
local cwd = vim.fn.tempname()
local root = cwd .. "/.claude/projects"
local dir = root .. "/" .. cwd:gsub("[^%w%-]", "-")
local uuid = "12345678-1234-1234-1234-123456789abc"
local other_uuid = "12345678-1234-1234-1234-123456789abd"
vim.fn.mkdir(dir, "p")
vim.fn.writefile({ "{}" }, dir .. "/" .. uuid .. ".jsonl")
vim.fn.writefile({ vim.json.encode({ type = "user", message = { content = "Recovered first prompt" } }) },
    dir .. "/" .. other_uuid .. ".jsonl")
vim.fn.writefile({ vim.json.encode({ originalPath = cwd, entries = {
    { sessionId = uuid, firstPrompt = "Claude conversation", projectPath = cwd },
} }) }, dir .. "/sessions-index.json")

local expand, executable, jobstart = vim.fn.expand, vim.fn.executable, vim.fn.jobstart
vim.fn.expand = function(path)
    if path == "~/.claude/projects" then return root end
    return expand(path)
end
vim.fn.executable = function(name)
    if name == "opencode" then return 1 end
    return executable(name)
end
vim.fn.jobstart = function(args, opts)
    assert(vim.deep_equal(args, { "opencode", "session", "list", "--format", "json", "--max-count", "10" }))
    assert(opts.cwd == cwd)
    vim.schedule(function()
        opts.on_stdout(1, { vim.json.encode({
            { id = "ses_recent", title = "OpenCode conversation", updated = os.time() * 1000 + 1000, directory = cwd },
            { id = "ses_elsewhere", updated = os.time() * 1000 + 2000, directory = "/elsewhere" },
        }) })
        opts.on_exit(1, 0)
    end)
    return 1
end

local result
source.refresh(cwd, function(sessions) result = sessions end)
assert(vim.wait(1000, function() return result ~= nil end))
assert(#result == 3)
assert(result[1].harness == "opencode" and result[1].id == "ses_recent")
local claude = {}
for _, session in ipairs(result) do if session.harness == "claude" then claude[session.id] = session end end
assert(claude[uuid].title == "Claude conversation")
assert(claude[other_uuid].title == "Recovered first prompt")
local limited
source.refresh(cwd, function(sessions) limited = sessions end, { recent_limit = 1, claude_projects = root })
assert(vim.wait(1000, function() return limited ~= nil end))
assert(#limited == 1 and limited[1].id == "ses_recent")
vim.fn.expand, vim.fn.executable, vim.fn.jobstart = expand, executable, jobstart
vim.fn.delete(cwd, "rf")

local recent_sessions = {
    { harness = "opencode", id = "ses_recent", title = "OpenCode conversation" },
    { harness = "claude", id = uuid, title = "Claude conversation" },
    { harness = "opencode", id = "ses_another", title = "Another conversation" },
}
package.loaded["agent_dashboard.sessions"] = {
    refresh = function(_, callback) callback(recent_sessions) end,
}
local dashboard = require("agent_dashboard")
dashboard.setup({ tmux = false, keys = { next = "<M-n>" } })
dashboard.toggle()
local first_buf = vim.api.nvim_get_current_buf()
dashboard.focus_list()
local buf = vim.api.nvim_get_current_buf()
local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
assert(lines[6]:find("OC OpenCode", 1, true))
assert(lines[7]:find("CC Claude", 1, true))

local sent
local chan_send = vim.api.nvim_chan_send
vim.api.nvim_chan_send = function(job, text)
    if text:find("opencode --session", 1, true) or text:find("claude --resume", 1, true) then
        sent = text
        return
    end
    return chan_send(job, text)
end
vim.api.nvim_win_set_cursor(0, { 6, 0 })
vim.api.nvim_feedkeys("x", "xt", false)
assert(vim.api.nvim_buf_get_lines(buf, 2, 3, false)[1]:find("1 terminal", 1, true))
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "xt", false)
assert(vim.wait(1000, function() return sent ~= nil end))
assert(sent == "opencode --session 'ses_recent'\n")
assert(vim.api.nvim_get_current_buf() == first_buf)
dashboard.focus_list()
assert(vim.api.nvim_buf_get_lines(buf, 2, 3, false)[1]:find("1 OpenCode", 1, true))
dashboard.toggle_slot(2)
local second_buf = vim.api.nvim_get_current_buf()
dashboard.focus_list()
assert(vim.api.nvim_buf_get_lines(buf, 3, 4, false)[1]:find("2 terminal", 1, true))
vim.api.nvim_feedkeys("jj", "xt", false)
assert(vim.api.nvim_win_get_cursor(0)[1] == 8)
local original_executable = vim.fn.executable
vim.fn.executable = function(name)
    if name == "claude" then return 1 end
    return original_executable(name)
end
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "xt", false)
assert(sent == "claude --resume '" .. uuid .. "'\n")
assert(vim.api.nvim_get_current_buf() == second_buf)
dashboard.focus_list()
assert(vim.api.nvim_buf_get_lines(buf, 3, 4, false)[1]:find("2 Claude", 1, true))
vim.api.nvim_win_set_cursor(0, { 9, 0 })
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "xt", false)
assert(sent == "opencode --session 'ses_another'\n")
local third_buf = vim.api.nvim_get_current_buf()
assert(third_buf ~= first_buf and third_buf ~= second_buf)
assert(vim.inspect(vim.api.nvim_win_get_config(0).title):find("Another conversation", 1, true))
recent_sessions = {}
dashboard.toggle()
dashboard.toggle()
dashboard.focus_list()
local active_lines = vim.api.nvim_buf_get_lines(buf, 2, 5, false)
assert(active_lines[1]:find("1 OpenCode", 1, true))
assert(active_lines[2]:find("2 Claude", 1, true))
assert(active_lines[3]:find("3 Another", 1, true))
dashboard.toggle_slot(3)
local mappings = vim.api.nvim_buf_get_keymap(third_buf, "t")
local has_cycle_mapping = false
for _, map in ipairs(mappings) do
    if map.lhs == "<M-n>" then has_cycle_mapping = true end
end
assert(has_cycle_mapping)
dashboard.cycle_slot(-1)
assert(vim.api.nvim_get_current_buf() == second_buf)
dashboard.cycle_slot(1)
assert(vim.api.nvim_get_current_buf() == third_buf)
dashboard.cycle_slot(1)
assert(vim.api.nvim_get_current_buf() == first_buf)
vim.fn.executable = original_executable
vim.api.nvim_chan_send = chan_send
vim.cmd("qa!")
