-- OpenCode capture uses a private, short-lived server so the helper identity is
-- known and journalled before any model request can execute.
local M = {}
local json = vim.json

local function safe_env(request, v2)
    local env = {}
    for k, v in pairs(vim.fn.environ()) do
        if k ~= "NVIM" and not k:match("^NVIM_AGENT_") then env[k] = v end
    end
    local old = {}
    if env.OPENCODE_CONFIG_CONTENT then
        local ok, parsed = pcall(json.decode, env.OPENCODE_CONFIG_CONTENT)
        if ok and type(parsed) == "table" then old = parsed end
    end
    -- Preserve provider configuration and credentials without the terminal's
    -- reporter identity. V2 capture uses transient generation, not an agent loop.
    if v2 then
        old.plugin, old.permission, old.tools = nil, nil, nil
        old.plugins = {}
        old.permissions = { { action = "*", resource = "*", effect = "deny" } }
        old.warming = false
    else
        old.plugin = {}
        old.permission = "deny"
        old.tools = vim.empty_dict()
    end
    if request.model then old.model = request.model end
    old.share = "disabled"
    env.OPENCODE_CONFIG_CONTENT = json.encode(old)
    if request.capture_id then env.AGENT_DASHBOARD_CAPTURE_ID = request.capture_id end
    return env
end

local function api_version()
    local ok, result = pcall(function()
        return vim.system({ "opencode", "--version" }, { text = true, timeout = 5000 }):wait()
    end)
    if not ok then return nil, "Cannot determine OpenCode API version: " .. tostring(result) end
    local major = result.code == 0 and tonumber((result.stdout or ""):match("v?(%d+)%.") or "")
    if major ~= 1 and major ~= 2 then return nil, "Cannot determine a supported OpenCode API version" end
    return major
end

local function redact(h, text)
    if h.v2 and h.env.OPENCODE_PASSWORD then return (text:gsub(h.env.OPENCODE_PASSWORD, "[redacted]")) end
    return text
end

local function valid_id(id)
    return type(id) == "string" and id:match("^ses_[%w]+$") ~= nil
end

function M.command(request, prompt)
    -- Retained for legacy callers; the safe, version-aware workflow is M.start.
    local env = safe_env(request)
    return { "opencode", "run", "--dir", request.source.project, "--session", request.source.session,
        "--fork", "--format", "json", prompt }, env
end

local function http(h, method, path, body, callback)
    local generating = method == "POST" and (path:match("/message$") or path:match("/generate$"))
    local timeout = generating and 600 or 60
    local argv = h.v2 and { "opencode", "api", method, "/api" .. path, "--server", h.base }
        or { "curl", "--silent", "--show-error", "--fail-with-body", "--max-time", tostring(timeout),
            "-X", method, h.base .. path }
    if body then
        if not h.v2 then argv[#argv + 1] = "-H"; argv[#argv + 1] = "Content-Type: application/json" end
        argv[#argv + 1] = h.v2 and "--data" or "--data-binary"; argv[#argv + 1] = json.encode(body)
    end
    vim.system(argv, { text = true, timeout = timeout * 1000,
        cwd = h.request.source.project, env = h.env, clear_env = true }, function(r)
        vim.schedule(function()
            if r.code ~= 0 then callback(nil, redact(h, vim.trim((r.stderr or "") .. "\n" .. (r.stdout or ""))))
            elseif r.stdout == "" then callback(true)
            else
                local ok, value = pcall(json.decode, r.stdout)
                if not ok then callback(nil, redact(h, "Invalid OpenCode API JSON: " .. r.stdout))
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

local function acknowledge_cancel(h)
    if not h.cancel_requested or h.cancel_finished or not h.server_stopped then return end
    -- Give in-flight fork/tag responses a chance to journal a known identity
    -- before the coordinator decides whether cleanup is possible.
    if h.v2 and (h.fork_pending or h.tag_pending) then return end
    h.cancel_finished = true
    if h.pending_cancel_done then h.pending_cancel_done(true, "Private server exited") end
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
    h.done(result, err and redact(h, err))
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
    local version, version_err = api_version()
    if not version then return nil, version_err end
    local h = { request = request, done = done, env = safe_env(request, version == 2), base = nil, v2 = version == 2 }
    if h.v2 then
        local entropy, entropy_err = vim.uv.random(32)
        if not entropy then return nil, "Cannot secure private OpenCode server: " .. tostring(entropy_err) end
        h.env.OPENCODE_PASSWORD = (entropy:gsub(".", function(byte) return string.format("%02x", byte:byte()) end))
    end
    local stdout = ""
    local out, errpipe = vim.uv.new_pipe(false), vim.uv.new_pipe(false)
    local env = {}
    for key, value in pairs(h.env) do env[#env + 1] = key .. "=" .. value end
    local executable = vim.fn.exepath("opencode")
    local server_args = { "serve", "--hostname", "127.0.0.1", "--port", "0" }
    if not h.v2 then server_args[#server_args + 1] = "--pure" end
    h.server, h.pid = vim.uv.spawn(executable, {
        args = server_args,
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
                acknowledge_cancel(h)
            end)
        end)
    if not h.server then
        out:close(); errpipe:close()
        return nil, "Could not start OpenCode server"
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
                http(h, "POST", "/session/" .. request.source.session .. "/fork", h.v2 and vim.empty_dict() or nil, function(response, err)
                        local fork = response
                        if h.v2 then fork = type(response) == "table" and response.data or nil end
                        if type(fork) ~= "table" or type(fork.id) ~= "string" or not valid_id(fork.id)
                            or fork.id == request.source.session then
                            h.fork_pending = false
                            acknowledge_cancel(h)
                            finish(h, nil, err or "OpenCode returned invalid fork identity"); return
                        end
                        h.helper_id = fork.id
                        h.fork_pending = false
                        if h.finished or h.server_stopped or h.stopping then
                            local called, accepted = pcall(ownership_callback, fork.id)
                            h.ownership_journaled = called and accepted ~= false
                            acknowledge_cancel(h)
                            return
                        end
                        h.owned_title = "agent-dashboard-capture:" .. (request.capture_id or "capture")
                        local tag_payload = { title = h.owned_title }
                        if h.v2 then tag_payload.permissions = { { action = "*", resource = "*", effect = "deny" } } end
                        h.tag_pending = true
                        http(h, "PATCH", "/session/" .. fork.id, tag_payload, function(tag, tag_err)
                        h.tag_pending = false
                        if h.cancel_requested then
                            local called, accepted = pcall(ownership_callback, fork.id)
                            if h.v2 then
                                h.ownership_journaled = called and accepted ~= false
                                stop_server(h, function() acknowledge_cancel(h) end)
                                return
                            end
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
                        if h.finished or h.server_stopped then return end
                        if h.cancel_requested then
                            if h.v2 then stop_server(h, function() acknowledge_cancel(h) end)
                            else abort_owned(h, h.pending_cancel_done or function() end) end
                            return
                        end
                        local payload = h.v2 and { prompt = prompt }
                            or { tools = { ["*"] = false }, parts = { { type = "text", text = prompt } } }
                        local model
                        if request.model then
                            local provider, name = request.model:match("^([^/]+)/(.+)$")
                            if not provider then finish(h, nil, "Invalid model identifier"); return end
                            if h.v2 then
                                local id, variant = name:match("^([^#]+)#(.+)$")
                                model = { providerID = provider, id = id or name, variant = variant }
                            else payload.model = { providerID = provider, modelID = name } end
                        end
                        local function generate()
                            if h.cancel_requested or h.stopping or h.finished or h.server_stopped then return end
                            http(h, "POST", "/session/" .. fork.id .. (h.v2 and "/generate" or "/message"), payload, function(message, message_err)
                                if h.cancel_requested then return end
                                if message_err or type(message) ~= "table" then
                                    finish(h, nil, message_err or "Invalid OpenCode response")
                                    return
                                end
                                local text = ""
                                if h.v2 then
                                    text = type(message.data) == "table" and message.data.text or nil
                                else
                                    for _, part in ipairs(message.parts or {}) do
                                        if part.type == "text" then text = text .. (part.text or "") end
                                    end
                                end
                                if type(text) ~= "string" or vim.trim(text) == "" then finish(h, nil, "OpenCode returned no text"); return end
                                -- The coordinator must persist this output before calling cleanup.
                                h.result = { helper_id = fork.id, text = text }
                                deliver(h, h.result)
                            end)
                        end
                        if model then
                            http(h, "POST", "/session/" .. fork.id .. "/model", { model = model }, function(_, model_err)
                                if model_err then finish(h, nil, "Could not select capture model: " .. model_err)
                                else generate() end
                            end)
                        else generate() end
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
    -- Transient generation is not a session drain, so /interrupt is not its stop
    -- handshake. Stop this owned private process before allowing helper cleanup.
    if h.v2 then stop_server(h, function() acknowledge_cancel(h) end); return end
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
    local function delete_stopped()
        local args = h.v2 and { "opencode", "api", "DELETE", "/api/session/" .. helper_id }
            or { "opencode", "session", "delete", helper_id }
        vim.system(args, {
            cwd = request.source.project, text = true, timeout = 60000,
            env = h.v2 and safe_env(request, true) or h.env, clear_env = true,
        }, function(result)
            vim.schedule(function()
                if result.code == 0 then callback(true)
                else callback(false, vim.trim(result.stderr)) end
            end)
        end)
    end
    if h.server_stopped then delete_stopped()
    elseif h.stopping then stop_server(h, delete_stopped)
    else delete() end
end
function M.cleanup_record(record, callback)
    if not valid_id(record.helper_id) or record.helper_id == record.source_id then
        callback(false, "Refusing invalid OpenCode helper ID"); return
    end
    -- Reconciliation is safe only once the recorded capture process is gone.
    if record.pid and vim.uv.kill(tonumber(record.pid), 0) == 0 then
        callback(false, "Recorded capture process is still alive"); return
    end
    local version, version_err = api_version()
    if not version then callback(false, version_err); return end
    if version == 2 then
        local options = { cwd = record.project, text = true, timeout = 60000, env = safe_env({}, true), clear_env = true }
        vim.system({ "opencode", "api", "GET", "/api/session/" .. record.helper_id }, options, function(result)
            vim.schedule(function()
                if result.code ~= 0 then
                    local decoded, missing = pcall(json.decode, result.stdout or "")
                    if decoded and type(missing) == "table" and missing._tag == "SessionNotFoundError"
                        and missing.sessionID == record.helper_id then callback(true)
                    else callback(false, "Could not verify journaled OpenCode helper: "
                        .. vim.trim((result.stderr or "") .. "\n" .. (result.stdout or ""))) end
                    return
                end
                local ok, value = pcall(json.decode, result.stdout)
                local info = ok and type(value) == "table" and value.data
                if type(info) ~= "table" or info.id ~= record.helper_id
                    or info.title ~= "agent-dashboard-capture:" .. record.id then
                    callback(false, "OpenCode helper ownership tag does not match its cleanup journal"); return
                end
                vim.system({ "opencode", "api", "DELETE", "/api/session/" .. record.helper_id }, options, function(deleted)
                    vim.schedule(function()
                        if deleted.code == 0 then callback(true)
                        else callback(false, vim.trim(deleted.stderr or "")) end
                    end)
                end)
            end)
        end)
        return
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
