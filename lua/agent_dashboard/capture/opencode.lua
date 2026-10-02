-- OpenCode capture uses a private, short-lived server so the helper identity is
-- known and journalled before any model request can execute.
local M = {}
local json = vim.json

local function safe_env(request)
    local env = {}
    for k, v in pairs(vim.fn.environ()) do
        if k ~= "NVIM" and not k:match("^NVIM_AGENT_") then env[k] = v end
    end
    local old = {}
    if env.OPENCODE_CONFIG_CONTENT then
        local ok, parsed = pcall(json.decode, env.OPENCODE_CONFIG_CONTENT)
        if ok and type(parsed) == "table" then old = parsed end
    end
    -- Preserve provider configuration (including credentials) while forcibly
    -- removing project extensions and denying every tool/permission.
    old.plugin = {}
    old.permission = "deny"
    old.tools = vim.empty_dict()
    if request.model then old.model = request.model end
    old.share = "disabled"
    env.OPENCODE_CONFIG_CONTENT = json.encode(old)
    if request.capture_id then env.AGENT_DASHBOARD_CAPTURE_ID = request.capture_id end
    return env
end

local function valid_id(id)
    return type(id) == "string" and id:match("^ses_[%w]+$") ~= nil
end

function M.command(request, prompt)
    -- Retained for older callers; the safe workflow is M.start below.
    local env = safe_env(request)
    return { "opencode", "run", "--dir", request.source.project, "--session", request.source.session,
        "--fork", "--format", "json", prompt }, env
end

local function http(h, method, path, body, callback)
    local timeout = method == "POST" and path:match("/message$") and "600" or "60"
    local argv = { "curl", "--silent", "--show-error", "--fail-with-body", "--max-time", timeout,
        "-X", method, h.base .. path }
    if body then
        argv[#argv + 1] = "-H"; argv[#argv + 1] = "Content-Type: application/json"
        argv[#argv + 1] = "--data-binary"; argv[#argv + 1] = json.encode(body)
    end
    vim.system(argv, { text = true, cwd = h.request.source.project, env = h.env, clear_env = true }, function(r)
        vim.schedule(function()
            if r.code ~= 0 then callback(nil, vim.trim(r.stderr .. "\n" .. r.stdout))
            elseif r.stdout == "" then callback(true)
            else
                local ok, value = pcall(json.decode, r.stdout)
                if not ok then callback(nil, "Invalid OpenCode API JSON: " .. r.stdout)
                else callback(value) end
            end
        end)
    end)
end

local function stop_server(h, callback)
    if h.server_stopped then callback(); return end
    h.stop_waiters = h.stop_waiters or {}
    h.stop_waiters[#h.stop_waiters + 1] = callback
    if h.stopping then return end
    h.stopping = true
    if h.server then h.server:kill("sigterm")
    else
        h.server_stopped = true
        local waiters = h.stop_waiters; h.stop_waiters = {}
        for _, cb in ipairs(waiters) do cb() end
    end
end

local function remove_helper(h, callback)
    if not valid_id(h.helper_id) or h.helper_id == h.request.source.session then
        callback(false, "Refusing invalid OpenCode helper ID"); return
    end
    http(h, "DELETE", "/session/" .. h.helper_id, nil, function(result, err)
        if err then callback(false, err)
        elseif result ~= nil then callback(true)
        else callback(false, "OpenCode helper deletion failed") end
    end)
end

local function deliver(h, result, err)
    if h.completion_delivered then return end
    h.completion_delivered = true
    h.done(result, err)
end

local function finish(h, result, err)
    if h.finished then return end
    h.finished = true
    stop_server(h, function() deliver(h, result, err) end)
end

local function abort_owned(h, callback)
    http(h, "POST", "/session/" .. h.helper_id .. "/abort", nil, function(_, err)
        if err then
            stop_server(h, function() callback(true, "Private server stopped after abort error: " .. err) end)
            return
        end
        local deadline = vim.uv.now() + 60000
        local function check()
            if vim.uv.now() >= deadline then
                stop_server(h, function() callback(true, "Idle check timed out; private server stopped") end)
                return
            end
            http(h, "GET", "/session/status", nil, function(status, status_err)
                if status_err then
                    stop_server(h, function() callback(true, "Status check failed; private server stopped: " .. status_err) end)
                    return
                end
                -- OpenCode's status endpoint enumerates non-idle sessions only;
                -- absence from its successful response is the idle state.
                local state = type(status) == "table" and status[h.helper_id]
                if not state or state.type == "idle" then callback(true)
                else vim.defer_fn(check, 150) end
            end)
        end
        check()
    end)
end

function M.start(request, prompt, ownership_callback, done)
    local h = { request = request, done = done, env = safe_env(request), base = nil }
    local stdout = ""
    local out, errpipe = vim.uv.new_pipe(false), vim.uv.new_pipe(false)
    local env = {}
    for key, value in pairs(h.env) do env[#env + 1] = key .. "=" .. value end
    local executable = vim.fn.exepath("opencode")
    h.server, h.pid = vim.uv.spawn(executable, {
        args = { "serve", "--hostname", "127.0.0.1", "--port", "0", "--pure" },
        cwd = request.source.project, env = env, stdio = { nil, out, errpipe },
    }, function(code)
            h.server_stopped = true
            if not out:is_closing() then out:close() end
            if not errpipe:is_closing() then errpipe:close() end
            if h.server and not h.server:is_closing() then h.server:close() end
            local waiters = h.stop_waiters or {}; h.stop_waiters = {}
            vim.schedule(function()
                for _, cb in ipairs(waiters) do cb() end
                if not h.finished and not h.stopping then
                    h.finished = true
                    deliver(h, nil, "OpenCode server exited (" .. code .. "): " .. stdout .. (h.stderr or ""))
                end
                if h.cancel_requested and h.pending_cancel_done and not h.cancel_finished then
                    h.cancel_finished = true
                    h.pending_cancel_done(true, "Private server exited")
                end
            end)
        end)
    if not h.server then
        out:close(); errpipe:close()
        done(nil, "Could not start OpenCode server"); return nil
    end
    out:read_start(function(read_err, chunk)
        if read_err then finish(h, nil, "OpenCode server stdout error: " .. read_err); return end
        if chunk then
            stdout = stdout .. chunk
            local port = stdout:match("https?://127%.0%.0%.1:(%d+)") or stdout:match("127%.0%.0%.1:(%d+)")
            if port and not h.base then
                h.base = "http://127.0.0.1:" .. port
                vim.schedule(function()
                if h.finished or h.stopping then return end
                -- OpenCode generates fork IDs server-side. Journal the unresolved
                -- fork intent too, so a lost response is surfaced rather than
                -- incorrectly reported as successful cleanup.
                local intent_ok, intent_saved = pcall(ownership_callback, nil, "forking")
                if not intent_ok or intent_saved == false then
                    finish(h, nil, "Cannot journal OpenCode fork intent"); return
                end
                h.fork_pending = true
                http(h, "POST", "/session/" .. request.source.session .. "/fork", nil, function(fork, err)
                        if not fork or type(fork.id) ~= "string" or not valid_id(fork.id)
                            or fork.id == request.source.session then
                            finish(h, nil, err or "OpenCode returned invalid fork identity"); return
                        end
                        h.helper_id = fork.id
                        h.fork_pending = false
                        h.owned_title = "agent-dashboard-capture:" .. (request.capture_id or "capture")
                        http(h, "PATCH", "/session/" .. fork.id, { title = h.owned_title }, function(tag, tag_err)
                        if h.cancel_requested then
                            local called, accepted = pcall(ownership_callback, fork.id)
                            if not called or accepted == false then
                                stop_server(h, function()
                                    deliver(h, nil, "Could not journal helper during cancellation")
                                    if h.pending_cancel_done then h.pending_cancel_done(true, "Private server stopped") end
                                end)
                            else
                                h.ownership_journaled = true
                                abort_owned(h, h.pending_cancel_done or function() end)
                            end
                            return
                        end
                        if tag_err then
                            pcall(ownership_callback, fork.id)
                            finish(h, nil, "Could not tag helper before prompt: " .. tag_err)
                            return
                        end
                        local ok, accepted = pcall(ownership_callback, fork.id)
                        if not ok or accepted == false then
                            -- No prompt was sent. Keep the tagged helper for safe
                            -- reconciliation rather than deleting before a durable journal.
                            finish(h, nil, "Could not journal OpenCode helper ownership")
                            return
                        end
                        h.ownership_journaled = true
                        if h.cancel_requested then abort_owned(h, h.pending_cancel_done or function() end); return end
                        local payload = { tools = { ["*"] = false }, parts = { { type = "text", text = prompt } } }
                        if request.model then
                            local provider, name = request.model:match("^([^/]+)/(.+)$")
                            if not provider then finish(h, nil, "Invalid model identifier"); return end
                            payload.model = { providerID = provider, modelID = name }
                        end
                        http(h, "POST", "/session/" .. fork.id .. "/message", payload, function(message, message_err)
                            if h.cancel_requested then return end
                            if message_err or type(message) ~= "table" then
                                finish(h, nil, message_err or "Invalid OpenCode response")
                                return
                            end
                            local text = ""
                            for _, part in ipairs(message.parts or {}) do
                                if part.type == "text" then text = text .. (part.text or "") end
                            end
                            if text == "" then finish(h, nil, "OpenCode returned no text"); return end
                            -- The coordinator must persist this output before calling cleanup.
                            h.result = { helper_id = fork.id, text = text }
                            deliver(h, h.result)
                        end)
                        end)
                    end)
                end)
            end
        end
    end)
    errpipe:read_start(function(_, chunk) if chunk then h.stderr = (h.stderr or "") .. chunk end end)
    return h
end

function M.cancel(h, done)
    if not h then done(false, "Capture server is not active"); return end
    if h.server_stopped then done(true); return end
    h.cancel_requested = true
    h.pending_cancel_done = done
    if h.helper_id and h.ownership_journaled then abort_owned(h, done) end
    if not h.helper_id and not h.fork_pending then
        stop_server(h, function() done(true) end)
    end
end

function M.cleanup(request, helper_id, callback, h)
    if not valid_id(helper_id) or helper_id == request.source.session then callback(false, "Refusing invalid OpenCode helper ID"); return end
    local function delete()
        http(h, "DELETE", "/session/" .. helper_id, nil, function(result, err)
            stop_server(h, function()
                h.finished = true
                if err or result == nil or result == false then callback(false, err or "OpenCode helper deletion failed")
                else callback(true) end
            end)
        end)
    end
    if not h or h.request.source.session ~= request.source.session or h.helper_id ~= helper_id then
        callback(false, "Cleanup requires matching owned private server"); return
    end
    if h.server_stopped then
        vim.system({ "opencode", "session", "delete", helper_id }, {
            cwd = request.source.project, text = true, env = h.env, clear_env = true,
        }, function(result)
            vim.schedule(function()
                if result.code == 0 then callback(true)
                else callback(false, vim.trim(result.stderr)) end
            end)
        end)
        return
    end
    if h.stopping then
        stop_server(h, function()
            vim.system({ "opencode", "session", "delete", helper_id }, {
                cwd = request.source.project, text = true, env = h.env, clear_env = true,
            }, function(result)
                vim.schedule(function()
                    if result.code == 0 then callback(true) else callback(false, vim.trim(result.stderr)) end
                end)
            end)
        end)
        return
    end
    delete()
end
function M.cleanup_record(record, callback)
    if not valid_id(record.helper_id) or record.helper_id == record.source_id then
        callback(false, "Refusing invalid OpenCode helper ID"); return
    end
    -- Reconciliation is safe only once the recorded capture process is gone.
    if record.pid and vim.uv.kill(tonumber(record.pid), 0) == 0 then
        callback(false, "Recorded capture process is still alive"); return
    end
    local options = { cwd = record.project, text = true, env = safe_env({}), clear_env = true }
    vim.system({ "opencode", "export", record.helper_id }, options, function(exported)
        vim.schedule(function()
            if exported.code ~= 0 then
                if exported.stderr:find("Session not found: " .. record.helper_id, 1, true) then
                    callback(true)
                    return
                end
                callback(false, "Could not verify journaled OpenCode helper: " .. vim.trim(exported.stderr))
                return
            end
            local ok, value = pcall(json.decode, exported.stdout)
            local info = ok and type(value) == "table" and value.info
            if type(info) ~= "table" or info.id ~= record.helper_id
                or info.title ~= "agent-dashboard-capture:" .. record.id then
                callback(false, "OpenCode helper ownership tag does not match its cleanup journal")
                return
            end
            vim.system({ "opencode", "session", "delete", record.helper_id }, options, function(result)
                vim.schedule(function()
                    if result.code == 0 then callback(true)
                    else callback(false, vim.trim(result.stderr)) end
                end)
            end)
        end)
    end)
end
function M.parse(stdout, source_id)
    local helper, text, finished
    for line in stdout:gmatch("[^\n]+") do
        local ok, event = pcall(json.decode, line)
        if not ok or type(event) ~= "table" then return nil, "OpenCode emitted malformed JSONL" end
        local id = event.sessionID or event.sessionId
        if id then
            if id == source_id then return nil, "OpenCode event identified source, not helper" end
            if helper and helper ~= id then return nil, "OpenCode reported multiple helper IDs" end
            helper = id
        end
        if event.type == "text" and type(event.part) == "table" then text = (text or "") .. (event.part.text or "") end
        if event.type == "step_finish" then finished = event.part == nil or event.part.reason == nil or event.part.reason == "stop" end
    end
    if not helper or not text or not finished then return nil, "OpenCode output lacks helper identity or completion event" end
    return { helper_id = helper, text = text }
end
return M
