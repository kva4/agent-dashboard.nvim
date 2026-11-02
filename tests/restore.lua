vim.opt.runtimepath:prepend(vim.fn.getcwd())
package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path

local store = require("agent_dashboard.slots")
local slots_dir = vim.fn.tempname()
local cwd = vim.fn.getcwd()
local uuid = "12345678-1234-1234-1234-123456789abc"
local next_uuid = "12345678-1234-1234-1234-123456789abd"
local session_uuid = "12345678-1234-1234-1234-123456789abe"

-- Invalid entries and files saved for another cwd are ignored.
store.setup(slots_dir)
store.save(cwd, {
    { agent = "claude", session = uuid, cwd = cwd, title = "Saved chat" },
    { agent = "claude", session = "not-a-uuid" },
    { agent = "bash", session = uuid },
    { agent = "opencode", session = "ses_abc" },
})
local loaded = store.load(cwd)
assert(#loaded == 2 and loaded[1].session == uuid and loaded[2].session == "ses_abc")
assert(#store.load("/elsewhere") == 0)
store.save(cwd, {})
assert(#vim.fn.glob(slots_dir .. "/*.json", false, true) == 0) -- An empty list removes the file.
store.save(cwd, { { agent = "claude", session = uuid, cwd = cwd, title = "Saved chat" } })

local executable, chan_send = vim.fn.executable, vim.api.nvim_chan_send
vim.fn.executable = function(name)
    if name == "claude" then return 1 end
    return executable(name)
end
local sent
vim.api.nvim_chan_send = function(job, text)
    if text:find("claude --resume", 1, true) then sent = text; return end
    return chan_send(job, text)
end

vim.o.columns, vim.o.lines = 160, 40
local dashboard = require("agent_dashboard")
dashboard.setup({ tmux = false, slots_dir = slots_dir })

-- Loading an nvim session recreates the slot without starting the agent yet.
vim.api.nvim_exec_autocmds("SessionLoadPost", {})
assert(dashboard.status() == "", "restored slots don't count towards the tmux badge")
assert(sent == nil)
assert(dashboard.restore() == 0) -- Already restored sessions aren't duplicated.

-- Opening the slot resumes the saved session.
dashboard.toggle_slot(1)
assert(sent == "claude --resume '" .. uuid .. "'\n", tostring(sent))

-- A slot reporting a new session updates the saved file.
local state_dir = vim.fn.glob(vim.fn.stdpath("state") .. "/agent-dashboard/" .. vim.fn.getpid() .. "-*", false, true)[1]
vim.fn.writefile({ vim.json.encode({
    slot = 101, time = os.time(), session = next_uuid, turn = 0, state = "idle", agent = "claude",
}) }, state_dir .. "/101.json")
assert(vim.wait(3000, function()
    local entries = store.load(cwd)
    return #entries == 1 and entries[1].session == next_uuid
end))

-- With an nvim session loaded, slots are saved under the session file.
local session_file = vim.fn.tempname() .. "/Session.vim"
vim.v.this_session = session_file
vim.fn.writefile({ vim.json.encode({
    slot = 101, time = os.time(), session = session_uuid, turn = 0, state = "idle", agent = "claude",
}) }, state_dir .. "/101.json")
assert(vim.wait(3000, function()
    local entries = store.load(session_file)
    return #entries == 1 and entries[1].session == session_uuid
end))
assert(store.load(cwd)[1].session == next_uuid) -- The cwd list is left alone.

vim.fn.executable, vim.api.nvim_chan_send = executable, chan_send
vim.fn.delete(slots_dir, "rf")
vim.cmd("qa!")
