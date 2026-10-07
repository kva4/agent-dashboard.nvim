vim.opt.runtimepath:prepend(vim.fn.getcwd())
package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path
local history = require("agent_dashboard.capture_model_history")
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
vim.api.nvim_create_autocmd("VimLeavePre", {
    once = true, callback = function() vim.fn.delete(root, "rf") end,
})
local path = root .. "/model-history.json"
history.setup(path)
assert(history.get("claude", "note") == nil and #history.choices("opencode") == 0)
assert(history.remember("claude", "note", "sonnet"))
assert(history.remember("claude", "brief", "opus"))
assert(history.remember("opencode", "note", "openai/note-model"))
assert(history.remember("opencode", "brief", "anthropic/brief-model"))
history.setup(path)
assert(history.get("claude", "note") == "sonnet" and history.get("claude", "brief") == "opus")
assert(history.get("opencode", "note") == "openai/note-model" and history.get("opencode", "brief") == "anthropic/brief-model")
local choices = history.choices("claude")
choices[1] = "mutated"
assert(history.choices("claude")[1] == "opus", "returned history is a copy")
assert(history.remember("claude", "note", "opus"))
assert(vim.deep_equal(history.choices("claude"), { "opus", "sonnet" }))
for index = 1, 10 do assert(history.remember("opencode", "note", "openai/model-" .. index)) end
assert(#history.choices("opencode") == 8 and history.choices("opencode")[1] == "openai/model-10")
assert(history.remember("opencode", "note", nil))
history.setup(path)
assert(history.get("opencode", "note") == nil and history.get("opencode", "brief") == "anthropic/brief-model")
assert(not history.remember("opencode", "note", "missing-provider"))
assert(not history.remember("claude", "brief", ""))
assert(not history.remember("unknown", "note", "opus"))

-- A failed atomic save does not replace the previous on-disk preferences.
local previous = table.concat(vim.fn.readfile(path), "\n")
local write = vim.uv.fs_write
vim.uv.fs_write = function() return nil, "deliberate write failure" end
local ok, err = history.remember("claude", "note", "another-model")
vim.uv.fs_write = write
assert(not ok and err == "deliberate write failure")
assert(table.concat(vim.fn.readfile(path), "\n") == previous)
assert(vim.fn.filereadable(path .. ".tmp." .. vim.fn.getpid()) == 0)
history.setup(path)
assert(history.get("claude", "note") == "opus")

-- Invalid/corrupt preferences are ignored rather than breaking capture startup.
vim.fn.writefile({ "not json" }, path)
history.setup(path)
assert(history.get("claude", "note") == nil and #history.choices("claude") == 0)
vim.fn.writefile({ vim.json.encode({ schema = 1, last = {
    claude = { note = "sonnet", brief = 42 }, opencode = { note = "unqualified", brief = "openai/valid" },
}, recent = { claude = { "opus", "opus", 42, "" }, opencode = { "unqualified", "openai/valid" } } }) }, path)
history.setup(path)
assert(history.get("claude", "note") == "sonnet" and history.get("claude", "brief") == nil)
assert(history.get("opencode", "note") == nil and history.get("opencode", "brief") == "openai/valid")
assert(vim.deep_equal(history.choices("claude"), { "opus" }))
assert(vim.deep_equal(history.choices("opencode"), { "openai/valid" }))
print("capture model history tests passed")
vim.cmd("qa!")
