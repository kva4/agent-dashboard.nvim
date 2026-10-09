vim.opt.runtimepath:prepend(vim.fn.getcwd())
package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path
local adapter = require("agent_dashboard.capture.opencode")
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
local request = { model = "openai/gpt-6.1-sol#high", capture_id = string.rep("a", 32),
    source = { harness = "opencode", session = "ses_source", project = root } }
local original = { system = vim.system, spawn = vim.uv.spawn, new_pipe = vim.uv.new_pipe, exepath = vim.fn.exepath }
local inherited = {}
for _, name in ipairs({ "NVIM", "NVIM_AGENT_SLOT", "NVIM_AGENT_DASHBOARD_DIR", "OPENCODE_CONFIG_CONTENT", "OPENCODE_PASSWORD" }) do
    inherited[name] = vim.env[name]
end
vim.env.NVIM, vim.env.NVIM_AGENT_SLOT, vim.env.NVIM_AGENT_DASHBOARD_DIR = "parent", "1", "parent-reporter"
vim.env.OPENCODE_PASSWORD = "parent-password"
vim.env.OPENCODE_CONFIG_CONTENT = vim.json.encode({ providers = { custom = { settings = { baseURL = "https://example.invalid" } } },
    plugins = { "parent-plugin" }, permissions = { { action = "*", resource = "*", effect = "allow" } }, warming = true })

local worker
vim.fn.exepath = function(name) return name == "opencode" and "/mock/opencode" or original.exepath(name) end
vim.uv.new_pipe = function()
    local pipe = {}
    function pipe:read_start(callback) self.read = callback end
    function pipe:is_closing() return self.closed == true end
    function pipe:close() self.closed = true end
    worker.pipes[#worker.pipes + 1] = pipe
    return pipe
end
vim.uv.spawn = function(_, options, on_exit)
    worker.spawn_options, worker.exit = options, on_exit
    if worker.spawn_failed then return nil end
    local w, server = worker, {}
    function server:is_closing() return self.closed == true end
    function server:close() self.closed = true end
    function server:kill(signal)
        assert(signal == "sigterm")
        w.kills = (w.kills or 0) + 1
        vim.schedule(function() on_exit(0) end)
    end
    worker.server = server
    return server, 424242
end
vim.system = function(args, options, callback)
    if args[2] == "--version" then
        return { wait = function() return { code = 0, stdout = worker.version or "opencode v2.0.20\n" } end }
    end
    local v2 = args[2] == "api"
    local method, path, body
    if v2 then
        method, path = args[3], args[4]
        assert(path:match("^/api/session/"), "V2 requests use /api routes")
        if args[5] == "--server" then
            assert(args[6] == "http://127.0.0.1:45678")
            assert(options.env.OPENCODE_PASSWORD == worker.handle.env.OPENCODE_PASSWORD,
                "each private API request authenticates with the worker's password")
        else
            assert(options.env.OPENCODE_PASSWORD == "parent-password", "shared cleanup does not reuse the private password")
        end
    else
        assert(args[1] == "curl")
        method = args[8]
        path = args[9]:gsub("^http://127%.0%.0%.1:45678", "")
    end
    for i, arg in ipairs(args) do
        if arg == "--data" or arg == "--data-binary" then body = vim.json.decode(args[i + 1]) end
    end
    assert(options.clear_env and options.env.NVIM == nil and options.env.NVIM_AGENT_SLOT == nil)
    assert(options.cwd == root)
    local call = { method = method, path = path, body = body, args = args }
    worker.calls[#worker.calls + 1] = call
    local response = { code = 0, stdout = "", stderr = "" }
    if path:match("/fork$") then
        if v2 then assert(args[#args] == "{}", "V2 fork requires an empty JSON object body") end
        local info = { id = worker.fork_id or "ses_helper" }
        response.stdout = vim.json.encode(v2 and { data = info } or info)
    elseif path:match("/generate$") or path:match("/message$") then
        assert(worker.journaled, "no generation before durable ownership")
        assert(options.timeout == 600000)
        response.stdout = vim.json.encode(v2 and { data = { text = worker.text or "# Finding\n\nCaptured safely." } }
            or { parts = { { type = "text", text = "Captured safely." } } })
    elseif method == "GET" then
        if worker.missing then
            response.code, response.stderr = 1, "HTTP 404 Not Found"
            response.stdout = vim.json.encode({ _tag = "SessionNotFoundError", sessionID = worker.missing_id or "ses_helper" })
        else response.stdout = vim.json.encode({ data = { id = "ses_helper",
            title = worker.wrong_tag and "unrelated session" or "agent-dashboard-capture:" .. request.capture_id } }) end
    end
    if worker.fail_path and path:match(worker.fail_path) then
        response.code, response.stderr = 1, "simulated API failure"
    end
    if worker.malformed and path:match("/generate$") then response.stdout = "not JSON" end
    local w = worker
    local function respond() callback(response) end
    if worker.delay_path and path:match(worker.delay_path) then w.delayed = respond
    else vim.schedule(respond) end
    return {}
end

local function begin(options, input)
    worker = vim.tbl_extend("force", { calls = {}, pipes = {}, completions = 0 }, options or {})
    local w = worker
    w.handle = adapter.start(input or request, "Capture this focus", function(id, stage)
        w.ownership = w.ownership or {}
        w.ownership[#w.ownership + 1] = { id = id, stage = stage }
        if stage == "forking" then return not w.reject_intent end
        w.journaled = not w.reject_ownership
        return w.journaled
    end, function(result, err)
        w.completions = w.completions + 1
        w.result, w.error = result, err
    end)
    assert(w.handle)
    w.pipes[1].read(nil, "server listening on http://127.0.0.1:45678\n")
    return w
end
local function wait(predicate) assert(vim.wait(2000, predicate, 5), vim.inspect(worker.calls)) end
local function calls_ending(suffix)
    local found = {}
    for _, call in ipairs(worker.calls) do if call.path:match(suffix .. "$") then found[#found + 1] = call end end
    return found
end

-- V2 authenticates a private server, unwraps response envelopes, sets only the
-- helper's model, and generates transient text without sending an agent prompt.
local w = begin()
wait(function() return w.result ~= nil end)
assert(w.handle.v2 and not vim.tbl_contains(w.spawn_options.args, "--pure"))
assert(#w.handle.env.OPENCODE_PASSWORD == 64 and w.handle.env.OPENCODE_PASSWORD ~= vim.env.OPENCODE_PASSWORD)
local config = vim.json.decode(w.handle.env.OPENCODE_CONFIG_CONTENT)
assert(config.providers.custom.settings.baseURL == "https://example.invalid")
assert(config.permissions[1].effect == "deny" and config.permissions[1].action == "*")
assert(config.warming == false and #config.plugins == 0)
assert(vim.env.NVIM == "parent" and vim.env.OPENCODE_PASSWORD == "parent-password")
assert(w.ownership[1].stage == "forking" and w.ownership[2].id == "ses_helper")
assert(w.result.helper_id == "ses_helper" and w.result.text:find("Captured safely.", 1, true))
local model = calls_ending("/model")[1]
assert(vim.deep_equal(model.body.model, { providerID = "openai", id = "gpt-6.1-sol", variant = "high" }))
local generate = calls_ending("/generate")[1]
assert(vim.deep_equal(generate.body, { prompt = "Capture this focus" }))
assert(#calls_ending("/prompt") == 0 and #calls_ending("/message") == 0)
assert(w.calls[2].body.title == "agent-dashboard-capture:" .. request.capture_id)
assert(w.calls[2].body.permissions[1].effect == "deny")
assert(w.kills == nil, "worker lives until the coordinator has saved its output")
local cleaned
adapter.cleanup(request, "ses_source", function(ok) cleaned = ok end, w.handle)
assert(cleaned == false and #w.calls == 4, "never delete the source")
adapter.cleanup(request, "ses_helper", function(ok) cleaned = ok end, w.handle)
wait(function() return cleaned == true end)
assert(w.calls[5].method == "DELETE" and w.calls[5].path == "/api/session/ses_helper")
assert(w.handle.server_stopped and w.kills == 1 and w.completions == 1)

-- Without an override, inherit the fork's model rather than changing the source.
local input = vim.deepcopy(request); input.model = nil
w = begin({}, input)
wait(function() return w.result ~= nil end)
assert(#calls_ending("/model") == 0)
adapter.cleanup(input, "ses_helper", function(ok) cleaned = ok end, w.handle)
wait(function() return w.handle.server_stopped end)

-- Source aliases, failed journalling, and malformed/empty results fail closed.
for _, options in ipairs({ { fork_id = "ses_source" }, { reject_intent = true }, { reject_ownership = true },
    { malformed = true }, { text = "   " }, { fail_path = "/model$" }, { fail_path = "/fork$" },
    { fail_path = "/session/ses_helper$" } }) do
    w = begin(options)
    wait(function() return w.error ~= nil end)
    assert(w.result == nil and w.completions == 1 and w.handle.server_stopped)
    if options.fork_id or options.reject_intent or options.reject_ownership or options.fail_path then
        assert(#calls_ending("/generate") == 0)
    end
    for _, call in ipairs(w.calls) do assert(call.method ~= "DELETE", "failed ownership never auto-deletes") end
end

-- Cancellation requires process exit; late generation cannot produce a result.
w = begin({ delay_path = "/generate$" })
wait(function() return w.delayed ~= nil end)
local stopped, stop_count = false, 0
adapter.cancel(w.handle, function(ok) stopped = ok; stop_count = stop_count + 1 end)
assert(not stopped, "no stop acknowledgement before server exit")
wait(function() return stopped end)
w.delayed()
vim.wait(30)
assert(w.result == nil and w.completions == 0 and stop_count == 1)
cleaned = nil
adapter.cleanup(request, "ses_helper", function(ok) cleaned = ok end, w.handle)
wait(function() return cleaned ~= nil end)
assert(cleaned and w.calls[#w.calls].args[5] == nil, "stopped workers clean via authenticated service discovery")

-- A racing fork response is journalled before cancellation releases cleanup.
w = begin({ delay_path = "/fork$" })
wait(function() return w.delayed ~= nil end)
stopped, stop_count = false, 0
adapter.cancel(w.handle, function(ok) stopped = ok; stop_count = stop_count + 1 end)
wait(function() return w.handle.server_stopped end)
assert(not stopped)
w.delay_path = nil
w.delayed()
wait(function() return stopped end)
assert(w.journaled and w.handle.helper_id == "ses_helper" and stop_count == 1)
assert(#calls_ending("/generate") == 0 and #calls_ending("/abort") == 0)

w = begin({ delay_path = "/session/ses_helper$" })
wait(function() return w.delayed ~= nil end)
stopped, stop_count = false, 0
adapter.cancel(w.handle, function(ok) stopped = ok; stop_count = stop_count + 1 end)
wait(function() return w.handle.server_stopped end)
assert(not stopped, "in-flight tagging also delays the stop acknowledgement")
w.delayed()
wait(function() return stopped end)
assert(w.journaled and stop_count == 1 and #calls_ending("/generate") == 0)

-- Server diagnostics must never put the private API password in a journal.
w = begin({ delay_path = "/fork$" })
wait(function() return w.delayed ~= nil end)
w.pipes[2].read(nil, "Failure with password " .. w.handle.env.OPENCODE_PASSWORD)
w.exit(1)
wait(function() return w.error ~= nil end)
assert(not w.error:find(w.handle.env.OPENCODE_PASSWORD, 1, true) and w.error:find("[redacted]", 1, true))
w.delayed()
vim.wait(30)

-- Crash reconciliation checks the ownership tag before deleting a helper.
local record = { id = request.capture_id, helper_id = "ses_helper", source_id = "ses_source", project = root }
for _, options in ipairs({ {}, { wrong_tag = true }, { missing = true }, { missing = true, missing_id = "ses_another" } }) do
    worker = vim.tbl_extend("force", { calls = {}, pipes = {} }, options)
    local reconciled
    adapter.cleanup_record(record, function(ok) reconciled = ok end)
    wait(function() return reconciled ~= nil end)
    assert(reconciled == not (options.wrong_tag or options.missing_id))
    assert(#worker.calls == (next(options) == nil and 2 or 1))
end

-- Legacy OpenCode retains --pure and its V1 HTTP/message contract.
w = begin({ version = "1.18.30\n" })
wait(function() return w.result ~= nil end)
assert(not w.handle.v2 and vim.tbl_contains(w.spawn_options.args, "--pure"))
assert(calls_ending("/message")[1].body.tools["*"] == false)
assert(calls_ending("/message")[1].body.model.modelID == request.model:match("^[^/]+/(.+)$"))
assert(w.result.text == "Captured safely.")
adapter.cleanup(request, "ses_helper", function(ok) cleaned = ok end, w.handle)
wait(function() return w.handle.server_stopped end)

-- Launch errors return a useful failure instead of leaving a busy capture.
for _, options in ipairs({ { version = "unknown\n" }, { spawn_failed = true } }) do
    worker = vim.tbl_extend("force", { calls = {}, pipes = {} }, options)
    local handle, err = adapter.start(request, "unused", function() error("must not fork") end,
        function() error("launch failures are returned to the coordinator") end)
    assert(handle == nil and type(err) == "string" and #worker.calls == 0)
    for _, pipe in ipairs(worker.pipes) do assert(pipe.closed) end
end

vim.system, vim.uv.spawn, vim.uv.new_pipe, vim.fn.exepath = original.system, original.spawn, original.new_pipe, original.exepath
for name, value in pairs(inherited) do vim.env[name] = value end
for _, name in ipairs({ "NVIM", "NVIM_AGENT_SLOT", "NVIM_AGENT_DASHBOARD_DIR", "OPENCODE_CONFIG_CONTENT", "OPENCODE_PASSWORD" }) do
    if inherited[name] == nil then vim.env[name] = nil end
end
vim.fn.delete(root, "rf")
print("OpenCode capture adapter tests passed")
