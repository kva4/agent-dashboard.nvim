-- Isolated topic capture. Only this coordinator writes results and owns helpers.
local M = {}
local latest, config, sequence = nil, {}, 0
local pending = {}
local active_states = { starting = true, capturing = true, saving = true, cleaning = true }
local workflow = "agent-dashboard-capture-v1"

local function read(path)
    if vim.fn.filereadable(path) ~= 1 then return nil end
    return table.concat(vim.fn.readfile(path, "b"), "\n")
end

local function changed()
    if config.on_change then vim.schedule(function() config.on_change(latest) end) end
end

local function persist(record)
    local path = config.dir .. "/" .. record.id .. ".json"
    local tmp = path .. ".tmp"
    local fd, err = vim.uv.fs_open(tmp, "w", 384)
    if not fd then return nil, err end
    local text = vim.json.encode(record)
    local written, write_err = vim.uv.fs_write(fd, text, 0)
    local synced, sync_err
    if written == #text then synced, sync_err = vim.uv.fs_fsync(fd) end
    vim.uv.fs_close(fd)
    if written ~= #text or not synced then
        vim.uv.fs_unlink(tmp)
        return nil, write_err or sync_err or "Incomplete journal write"
    end
    local renamed, rename_err = vim.uv.fs_rename(tmp, path)
    if not renamed then vim.uv.fs_unlink(tmp); return nil, rename_err end
    return true
end

local function record_for(job)
    local source = job.request.source
    -- Never put prompts, focus, brief text, or model output in the cleanup journal.
    return {
        schema = 1, workflow = workflow, id = job.id, harness = source.harness,
        source_id = source.session, project = source.project, slot_id = source.slot_id,
        topic_id = job.request.topic_id, kind = job.request.kind, state = job.state,
        helper_id = job.helper_id, pid = job.pid, path = job.path,
        recovery_path = job.recovery_path, error = job.error, cleanup_error = job.cleanup_error,
        cleanup_done = job.cleanup_done, cancelled = job.cancelled,
        fork_pending = job.fork_pending,
    }
end

local function save_job(job)
    local record = record_for(job)
    local ok, err = persist(record)
    if ok then
        if job.cleanup_done then pending[job.id] = nil else pending[job.id] = record end
    end
    return ok, err
end

local function transition(job, state)
    job.state = state
    local ok, err = save_job(job)
    if not ok then job.cleanup_error = "Could not update cleanup journal: " .. tostring(err) end
    changed()
    return ok
end

local function adapter_for(harness)
    return config.adapters and config.adapters[harness] or require("agent_dashboard.capture." .. harness)
end

local function prompt(job)
    local req = job.request
    local text = "Return only Markdown content, without frontmatter or a surrounding code fence. "
        .. "Do not use tools, read files, or modify anything. The plugin saves your returned text.\n"
        .. "Base findings only on the conversation inherited from the source investigation. "
        .. "Separate confirmed behavior, hypotheses, proposed changes, and open questions. "
        .. "Include supporting file paths and contracts where the source established them. "
        .. "Do not invent connections to the destination topic or import other projects' claims.\n"
        .. "Destination topic (a storage label, not additional evidence): " .. job.topic_title .. "\n"
    if req.focus and vim.trim(req.focus) ~= "" then
        text = text .. "Requested focus: " .. req.focus .. "\n"
            .. "Exclude unrelated findings; retain caveats needed to understand this focus. "
            .. "If there are no findings on this subject, say so.\n"
    end
    if req.kind == "brief" then
        text = text .. "Propose a complete revised topic brief. Preserve accurate existing sections outside "
            .. "the focus. Distinguish desired outcomes from current behavior and assumptions. "
            .. "This is a session-based update, not note consolidation. Keep within "
            .. require("agent_dashboard.topics").brief_max_lines() .. " lines.\n"
            .. "Current brief supplied explicitly:\n<current-brief>\n" .. job.snapshot.text .. "\n</current-brief>"
    else
        text = text .. "Distill one self-contained note with a # Title and concise findings, decisions, "
            .. "and open questions. The topic brief and other notes are not evidence for this note."
    end
    return text
end

local function finish_cleanup(job, ok, err)
    job.cleanup_done = ok == true
    job.cleanup_error = nil
    if not ok then job.cleanup_error = err or "Helper cleanup failed; retry on next dashboard startup" end
    job.state = job.cancelled and "cancelled" or (job.error and "failed" or "complete")
    if job.path and job.recovery_path then
        vim.fn.delete(job.recovery_path)
        job.recovery_path = nil
    end
    save_job(job)
    changed()
end

local function cleanup(job, adapter)
    if job.cleanup_started then return end
    job.cleanup_started = true
    transition(job, "cleaning")
    if not job.helper_id then
        if job.fork_pending then
            finish_cleanup(job, false, "OpenCode fork response was lost; helper identity cannot be verified. No session was deleted.")
        else finish_cleanup(job, true) end
        return
    end
    if job.helper_id == job.request.source.session then
        finish_cleanup(job, false, "Refusing to delete the original investigation session")
        return
    end
    local called = false
    adapter.cleanup(job.request, job.helper_id, function(ok, err)
        if called then return end
        called = true
        finish_cleanup(job, ok, err)
    end, job.handle)
end

local function complete(job, adapter, result, err)
    if job.completion_received then return end
    job.completion_received = true
    -- Cancellation owns the stop handshake; a racing completion alone does not
    -- prove that a server-backed worker has stopped.
    if job.cancelled then return end
    if not result then
        job.error = tostring(err or "Capture worker failed"):sub(1, 2000)
        cleanup(job, adapter)
        return
    end
    if result.helper_id ~= job.helper_id or result.helper_id == job.request.source.session
        or type(result.text) ~= "string" or vim.trim(result.text) == "" then
        job.error = "Capture returned invalid content or an unowned session identity"
        cleanup(job, adapter)
        return
    end
    local topics = require("agent_dashboard.topics")
    job.recovery_path = config.dir .. "/" .. job.id .. ".output.md"
    local recovered, recovery_err = topics.write_new(job.recovery_path, result.text)
    if not recovered then
        local recovery_dir = vim.fn.stdpath("data") .. "/agent-dashboard/capture-results"
        pcall(vim.fn.mkdir, recovery_dir, "p", 448)
        local fallback = recovery_dir .. "/" .. job.id .. ".md"
        recovered, recovery_err = topics.write_new(fallback, result.text)
        if recovered then job.recovery_path = fallback end
    end
    if not recovered then
        job.result_text = result.text
        job.error = "Could not preserve generated output: " .. tostring(recovery_err)
        job.cleanup_error = "Helper retained until output can be recovered"
        job.state = "failed"
        save_job(job); changed()
        return
    end
    transition(job, "saving")
    local source = job.request.source
    local ok, saved, save_err = pcall(topics.capture_save, job.request.topic_id, job.request.kind, result.text,
        { harness = source.harness, session = source.session, project = source.project }, job.snapshot)
    if not ok then save_err, saved = saved, nil end
    if saved then job.path = saved
    else job.error = "Save failed; output recovered at " .. job.recovery_path .. ": " .. tostring(save_err) end
    cleanup(job, adapter)
end

function M.validate(request)
    if type(request) ~= "table" or (request.kind ~= "note" and request.kind ~= "brief")
        or type(request.topic_id) ~= "string" or type(request.source) ~= "table" then
        return nil, "Choose a topic and capture type"
    end
    local source = request.source
    if (source.harness ~= "claude" and source.harness ~= "opencode")
        or type(source.session) ~= "string" or source.session == "" or source.session == "none"
        or source.session == "unknown" or type(source.project) ~= "string" or source.project == ""
        or source.status ~= "idle" or source.reported ~= true then
        return nil, "Capture requires an idle, reported Claude or OpenCode session"
    end
    if vim.fn.isdirectory(source.project) ~= 1 then return nil, "Source project directory no longer exists" end
    local topics = require("agent_dashboard.topics")
    if not topics.get(request.topic_id) then return nil, "Topic not found: " .. request.topic_id end
    if request.kind == "brief" then
        local snapshot, err = topics.capture_snapshot(request.topic_id)
        if not snapshot then return nil, err end
    end
    return true
end

local function busy() return latest and active_states[latest.state] end

function M.start(request)
    if not config.dir then M.setup() end
    if busy() then return nil, "A capture is already active; wait or cancel it" end
    local valid, err = M.validate(request)
    if not valid then return nil, err end
    sequence = sequence + 1
    local frozen = vim.deepcopy(request)
    local topics = require("agent_dashboard.topics")
    local snapshot
    if frozen.kind == "brief" then
        snapshot, err = topics.capture_snapshot(frozen.topic_id)
        if not snapshot then return nil, err end
    end
    local job = {
        id = vim.fn.sha256(os.time() .. ":" .. sequence .. ":" .. tostring({})):sub(1, 32),
        request = frozen, snapshot = snapshot, topic_title = topics.get(frozen.topic_id).title, state = "starting",
    }
    frozen.capture_id = job.id
    latest = job
    local adapter = adapter_for(frozen.source.harness)
    if adapter.prepare then
        job.helper_id, err = adapter.prepare(frozen, job.id)
        if not job.helper_id then job.error = err; job.state = "failed"; changed(); return nil, err end
        if job.helper_id == frozen.source.session then
            job.helper_id = nil
            job.error = "Refusing to treat the source session as a helper"
            job.state = "failed"
            changed()
            return nil, job.error
        end
    end
    local journaled, journal_err = save_job(job)
    if not journaled then job.state = "failed"; job.error = "Cannot journal helper ownership: " .. tostring(journal_err); changed(); return nil, job.error end
    local function owned(helper_id, stage)
        if stage == "forking" then job.fork_pending = true; return save_job(job) == true end
        if helper_id == frozen.source.session or (job.helper_id and job.helper_id ~= helper_id) then return false end
        job.helper_id = helper_id
        job.fork_pending = false
        local saved = save_job(job)
        changed()
        return saved == true
    end
    local callback = function(result, worker_err)
        vim.schedule(function() complete(job, adapter, result, worker_err) end)
    end
    local handle, start_err = adapter.start(frozen, prompt(job), owned, callback)
    job.handle = handle
    if not handle then
        job.error = start_err or "Could not start capture worker"
        cleanup(job, adapter)
        return nil, job.error
    end
    job.pid = handle.pid
    transition(job, "capturing")
    return job
end

function M.current() return latest end
function M.cancel()
    if not latest or (latest.state ~= "starting" and latest.state ~= "capturing") then return false, "No active capture to cancel" end
    local job, adapter = latest, adapter_for(latest.request.source.harness)
    job.cancelled = true
    transition(job, "cleaning")
    adapter.cancel(job.handle, function(stopped, err)
        if stopped then cleanup(job, adapter)
        else
            job.cleanup_error = err or "Worker stop could not be confirmed"
            job.state = "cancelled"
            save_job(job); changed()
        end
    end)
    return true
end
function M.retry()
    if busy() then return nil, "Cannot retry while capture is active" end
    if not latest or (latest.state ~= "failed" and latest.state ~= "cancelled") then return nil, "No failed capture to retry" end
    return M.start(latest.request)
end
function M.dismiss()
    if busy() then return false, "Cannot dismiss an active capture" end
    latest = nil
    changed()
    return true
end
function M.is_helper(harness, id)
    if latest and latest.request.source.harness == harness and latest.helper_id == id then return true end
    for _, record in pairs(pending) do
        if record.harness == harness and record.helper_id == id and id ~= record.source_id then return true end
    end
    return false
end
function M.cleanup_pending()
    local result = {}
    for _, record in pairs(pending) do result[#result + 1] = vim.deepcopy(record) end
    return result
end

local function valid_record(record, filename)
    return type(record) == "table" and record.schema == 1 and record.workflow == workflow
        and type(record.id) == "string" and record.id:match("^%x+$") and #record.id == 32
        and filename == config.dir .. "/" .. record.id .. ".json"
        and (record.harness == "claude" or record.harness == "opencode")
        and type(record.source_id) == "string" and type(record.project) == "string"
        and (not record.helper_id or record.helper_id ~= record.source_id)
end

-- PIDs can be reused. Verify the capture-specific marker before signalling one.
local function stop_record(record, callback)
    if not record.pid then
        if record.harness ~= "claude" or not record.helper_id then callback(true); return end
        -- The host may have crashed between spawn and persisting the PID. A
        -- preassigned Claude UUID also identifies that short launch window.
        vim.system({ "ps", "ax", "-o", "pid=", "-o", "command=" }, { text = true }, function(result)
            vim.schedule(function()
                if result.code ~= 0 then callback(false, "Cannot confirm the capture worker stopped"); return end
                for line in result.stdout:gmatch("[^\n]+") do
                    if line:find("--session-id " .. record.helper_id, 1, true)
                        and line:find("--fork-session", 1, true) then
                        record.pid = tonumber(line:match("^%s*(%d+)"))
                        stop_record(record, callback)
                        return
                    end
                end
                callback(true)
            end)
        end)
        return
    end
    vim.system({ "ps", "eww", "-p", tostring(record.pid), "-o", "command=" }, { text = true }, function(result)
        vim.schedule(function()
            if result.code ~= 0 or vim.trim(result.stdout) == "" then callback(true); return end
            local marker = record.harness == "claude" and record.helper_id or ("AGENT_DASHBOARD_CAPTURE_ID=" .. record.id)
            if not marker or not result.stdout:find(marker, 1, true) then
                callback(false, "Recorded PID cannot be verified as this capture worker")
                return
            end
            vim.uv.kill(record.pid, "sigterm")
            local attempts = 0
            local function wait()
                vim.system({ "ps", "-p", tostring(record.pid), "-o", "pid=" }, { text = true }, function(status)
                    vim.schedule(function()
                        if status.code ~= 0 then callback(true)
                        elseif attempts >= 50 then callback(false, "Capture worker has not stopped")
                        else attempts = attempts + 1; vim.defer_fn(wait, 100) end
                    end)
                end)
            end
            wait()
        end)
    end)
end

function M._reconcile()
    for _, filename in ipairs(vim.fn.globpath(config.dir, "*.json", false, true)) do
        local decoded, record = pcall(vim.json.decode, read(filename) or "")
        if decoded and valid_record(record, filename) and not record.cleanup_done then
            if not record.recovery_path and vim.fn.filereadable(config.dir .. "/" .. record.id .. ".output.md") == 1 then
                record.recovery_path = config.dir .. "/" .. record.id .. ".output.md"
            end
            pending[record.id] = record
            stop_record(record, function(stopped, stop_err)
                local function done(clean, cleanup_err)
                    record.cleanup_done = clean == true
                    record.state = record.path and "complete" or (record.cancelled and "cancelled" or "failed")
                    record.error = record.error or (not record.path and "Capture interrupted; retry from an idle session" or nil)
                    record.cleanup_error = nil
                    if not clean then record.cleanup_error = cleanup_err end
                    persist(record)
                    if clean then pending[record.id] = nil end
                    if clean and record.path and record.recovery_path then
                        vim.fn.delete(record.recovery_path)
                        record.recovery_path = nil
                        persist(record)
                    end
                    if not latest then
                        latest = { id = record.id, state = record.state, path = record.path,
                            error = record.error, cleanup_error = record.cleanup_error, recovery_path = record.recovery_path,
                            request = { kind = record.kind, topic_id = record.topic_id, source = {
                                harness = record.harness, session = record.source_id, project = record.project,
                                slot_id = record.slot_id, reported = true, status = "idle",
                            } }, helper_id = record.helper_id, cleanup_done = record.cleanup_done }
                    end
                    changed()
                end
                if not stopped then done(false, stop_err)
                elseif not record.helper_id and record.fork_pending then
                    done(false, "OpenCode fork response was lost; helper identity cannot be verified. No session was deleted.")
                elseif not record.helper_id then done(true)
                else adapter_for(record.harness).cleanup_record(record, done) end
            end)
        end
    end
end

function M.setup(options)
    if busy() then return M end
    config = options or {}
    config.dir = vim.fn.fnamemodify(config.dir or (vim.fn.stdpath("state") .. "/agent-dashboard/capture"), ":p"):gsub("/$", "")
    vim.fn.mkdir(config.dir, "p", 448)
    pending = {}
    M._reconcile()
    local group = vim.api.nvim_create_augroup("AgentDashboardCapture", { clear = true })
    vim.api.nvim_create_autocmd("VimLeavePre", { group = group, callback = function()
        if busy() and latest.handle then M.cancel() end
    end })
    return M
end

return M
