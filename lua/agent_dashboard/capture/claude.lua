local M = {}
local prepared = setmetatable({}, { __mode = "k" })

local function valid_uuid(id)
    return type(id) == "string" and id:match("^[%x]+%-%x+%-%x+%-%x+%-%x+$") ~= nil
end

local function helper_uuid(capture_id)
    if type(capture_id) ~= "string" or not capture_id:match("^%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x$") then
        return nil, "Invalid capture id"
    end
    local hex = capture_id:lower()
    -- Set UUID version 4 and RFC 4122 variant bits deterministically.
    hex = hex:sub(1, 12) .. "4" .. hex:sub(14)
    local variant = tonumber(hex:sub(17, 17), 16)
    hex = hex:sub(1, 16) .. string.format("%x", (variant % 4) + 8) .. hex:sub(18)
    return table.concat({ hex:sub(1, 8), hex:sub(9, 12), hex:sub(13, 16), hex:sub(17, 20), hex:sub(21, 32) }, "-")
end

function M.prepare(request, capture_id)
    if type(request) ~= "table" or type(request.source) ~= "table"
        or type(request.source.session) ~= "string" or not valid_uuid(request.source.session) then
        return nil, "Invalid Claude source session"
    end
    local helper, err = helper_uuid(capture_id)
    if not helper then return nil, err end
    if helper == request.source.session then return nil, "Capture id collides with source session" end
    if M.helper_path and M.helper_path(request, helper) then
        return nil, "Capture helper ID already exists; refusing to reuse it"
    end
    prepared[request] = { id = capture_id, helper = helper }
    return helper
end

local function environment()
    local env = {}
    for key, value in pairs(vim.fn.environ()) do
        if key ~= "NVIM" and not key:match("^NVIM_AGENT_") then env[key] = value end
    end
    return env
end

function M.command(request, prompt, capture_id)
    local helper, err = M.prepare(request, capture_id)
    if not helper then return nil, err end
    return { "claude", "-p", prompt, "--resume", request.source.session, "--fork-session",
        "--session-id", helper, "--name", "capture:" .. capture_id, "--output-format", "json",
        "--permission-prompts", "none", "--tools", "", "--safe-mode", "--settings",
        vim.json.encode({ disableAllHooks = true }) }, environment(), helper
end

function M.start(request, prompt, ownership_callback, done)
    if type(ownership_callback) ~= "function" or type(done) ~= "function" then
        return nil, "Ownership and completion callbacks are required"
    end
    local assignment = prepared[request]
    if not assignment then return nil, "Claude capture was not prepared" end
    local command, env, helper = M.command(request, prompt, assignment.id)
    if not command then return nil, env end
    local ok, owned = pcall(ownership_callback, helper)
    if not ok or owned == false then return nil, "Could not persist Claude helper ownership" end
    local stdout, stderr, finished = {}, {}, false
    local process = vim.fn.jobstart(command, { cwd = request.source.project, env = env,
        clear_env = true, stdout_buffered = true, stderr_buffered = true,
        on_stdout = function(_, data) stdout = data or {} end,
        on_stderr = function(_, data) stderr = data or {} end,
        on_exit = function(_, code)
            if finished then return end
            finished = true
            if code ~= 0 then done(nil, vim.trim(table.concat(stderr, "\n")))
            else
                local result, err = M.parse(table.concat(stdout, "\n"), helper)
                done(result, err)
            end
        end })
    if process <= 0 then return nil, "Could not start Claude capture process" end
    return { pid = vim.fn.jobpid(process), helper_id = helper, process = process }
end

function M.cancel(handle, callback)
    if type(handle) ~= "table" or not handle.process then callback(false, "Invalid process handle"); return end
    vim.fn.jobstop(handle.process)
    -- jobstop is asynchronous: callback only after on_exit confirms termination.
    local function wait()
        if vim.fn.jobwait({ handle.process }, 0)[1] ~= -1 then callback(true)
        else vim.defer_fn(wait, 10) end
    end
    wait()
end

function M.parse(stdout, expected_id)
    local ok, obj = pcall(vim.json.decode, stdout)
    if not ok or type(obj) ~= "table" then return nil, "Claude returned invalid capture JSON" end
    if obj.session_id ~= expected_id then return nil, "Claude helper session id did not match its assigned id" end
    if obj.is_error == true or (obj.subtype ~= nil and obj.subtype ~= "success") then
        return nil, "Claude reported capture failure: " .. tostring(obj.subtype or "is_error")
    end
    if type(obj.result) ~= "string" or not obj.result:match("%S") then return nil, "Claude returned an empty capture" end
    return { helper_id = obj.session_id, text = obj.result }
end

local function helper_path(request, helper_id)
    if not valid_uuid(helper_id) or helper_id == request.source.session then return nil, "Refusing invalid Claude helper id" end
    local root = vim.fn.expand("~/.claude/projects")
    local cwd = vim.uv.fs_realpath(request.source.project) or request.source.project
    local dirs = { cwd, request.source.project }
    local seen = {}
    for _, project in ipairs(dirs) do
        local dir = root .. "/" .. project:gsub("[^%w%-]", "-")
        if not seen[dir] then
            seen[dir] = true
            local path = dir .. "/" .. helper_id .. ".jsonl"
            local stat, stat_err = vim.uv.fs_lstat(path)
            if stat then
                -- The assigned UUID is the identity; do not rely on transcript
                -- metadata at the beginning (large sessions may be compacted).
                return path
            elseif stat_err and not tostring(stat_err):match("ENOENT") then
                return nil, "Cannot inspect expected helper transcript: " .. tostring(stat_err)
            end
            -- A previous deletion can have removed the transcript but failed to
            -- remove its helper-only tool-result directory.
            if vim.uv.fs_lstat(dir .. "/" .. helper_id) then return path end
        end
    end
    return nil, "Claude helper transcript not found"
end
M.helper_path = helper_path

function M.cleanup(request, helper_id, callback)
    if not valid_uuid(helper_id) or not request or not request.source or helper_id == request.source.session then
        callback(false, "Refusing invalid Claude helper id"); return
    end
    local path, path_err = helper_path(request, helper_id)
    if not path then
        -- Only a positively confirmed absence at the canonical expected path is idempotent.
        if path_err == "Claude helper transcript not found" then callback(true)
        else callback(false, path_err) end
        return
    end
    if vim.uv.fs_lstat(path) and vim.fn.delete(path) ~= 0 then
        callback(false, "Could not delete Claude helper transcript"); return
    end
    local companion = path:gsub("%.jsonl$", "")
    if vim.uv.fs_stat(companion) and vim.fn.delete(companion, "rf") ~= 0 then
        callback(false, "Could not delete Claude helper companion directory")
        return
    end
    callback(true)
end

function M.cleanup_record(record, callback)
    if type(record) ~= "table" or not valid_uuid(record.source_id) or not valid_uuid(record.helper_id)
        or record.source_id == record.helper_id then callback(false, "Invalid Claude cleanup record"); return end
    if helper_uuid(record.id) ~= record.helper_id then
        callback(false, "Claude helper ID does not match its capture ownership record"); return
    end
    M.cleanup({ source = { session = record.source_id, project = record.project } }, record.helper_id, callback)
end

return M
