vim.opt.runtimepath:prepend(vim.fn.getcwd())
package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path

local root = vim.fn.tempname()
local project = root .. "/project"
vim.fn.mkdir(project, "p")
local topics = require("agent_dashboard.topics")
topics.setup({ dir = root .. "/topics" })
assert(topics.create("capture-test", { title = "Capture test" }))
local capture = require("agent_dashboard.capture")

local original_chansend = vim.fn.chansend
local original_nvim_chan_send = vim.api.nvim_chan_send
vim.fn.chansend = function() error("capture must never send to a terminal") end
vim.api.nvim_chan_send = function() error("capture must never send to a terminal") end

local request = {
    kind = "note", topic_id = "capture-test", focus = "retry behavior",
    source = { harness = "opencode", session = "ses_source", project = project,
        slot_id = 1, status = "idle", reported = true },
}
assert(capture.validate(request))
local invalid = vim.deepcopy(request)
invalid.source.status = "busy"
assert(not capture.validate(invalid))

local claude = require("agent_dashboard.capture.claude")
local claude_request = vim.deepcopy(request)
claude_request.source.harness = "claude"
claude_request.source.session = "12345678-1234-1234-1234-123456789012"
local capture_id = string.rep("a", 32)
local inherited = {}
for _, name in ipairs({ "NVIM_AGENT_SLOT", "NVIM_AGENT_DASHBOARD_DIR", "NVIM_AGENT_TOPIC_DIR", "NVIM" }) do
    inherited[name] = vim.env[name]
    vim.env[name] = "source-terminal-identity"
end
local command, env, helper = claude.command(claude_request, "safe prompt", capture_id)
assert(command[3] == "safe prompt")
local tools_index
for index, value in ipairs(command) do if value == "--tools" then tools_index = index end end
assert(tools_index and command[tools_index + 1] == "")
assert(helper == claude.parse(vim.json.encode({
    session_id = helper, result = "A note",
}), helper).helper_id)
assert(env.NVIM_AGENT_TOPIC == nil)
assert(env.NVIM_AGENT_SLOT == nil and env.NVIM_AGENT_DASHBOARD_DIR == nil and env.NVIM == nil)
assert(not claude.command(claude_request, "safe", "bad-id"))
assert(not claude.parse(vim.json.encode({ session_id = "wrong", result = "A note" }), helper))
local parsed = assert(claude.parse(vim.json.encode({ session_id = helper, result = "A note" }), helper))
assert(parsed.text == "A note")

local oc = require("agent_dashboard.capture.opencode")
local _, oc_env = oc.command(request, "safe prompt")
assert(oc_env.NVIM_AGENT_SLOT == nil and oc_env.NVIM_AGENT_TOPIC_DIR == nil and oc_env.NVIM == nil)
for _, name in ipairs({ "NVIM_AGENT_SLOT", "NVIM_AGENT_DASHBOARD_DIR", "NVIM_AGENT_TOPIC_DIR", "NVIM" }) do
    assert(vim.env[name] == "source-terminal-identity", "worker isolation must not mutate the parent environment")
    vim.env[name] = inherited[name]
end
local event = vim.json.encode({ type = "step_start", sessionID = "ses_helper" }) .. "\n"
    .. vim.json.encode({ type = "text", part = { text = "captured" } }) .. "\n"
    .. vim.json.encode({ type = "step_finish" })
assert(oc.parse(event, "ses_source").text == "captured")
assert(not oc.parse(vim.json.encode({ type = "step_finish", sessionID = "ses_source" }), "ses_source"))

local serial = 0
local function adapter(options)
    options = options or {}
    serial = serial + 1
    local a = { calls = {}, id = options.id or ("ses_helper" .. serial) }
    function a.prepare(req, id)
        a.prepared_id = id
        if options.prepare_error then return nil, "prepare rejected" end
        return options.prepare_id or a.id
    end
    function a.start(req, prompt, ownership, done)
        a.request, a.prompt, a.done = req, prompt, done
        a.handle = { pid = 30000 + serial }
        a.owned = ownership
        if options.own_on_start then assert(ownership(a.id)) end
        return a.handle
    end
    function a.cancel(handle, cb)
        a.calls.cancel = true
        if options.cancel_result ~= nil then cb(options.cancel_result, "stop refused")
        else a.cancel_done = cb end
    end
    function a.cleanup(req, id, cb, handle)
        a.calls.cleanup = true
        a.cleanup_count = (a.cleanup_count or 0) + 1
        a.cleanup_saw_saved = options.saved_probe and options.saved_probe()
        a.cleanup_args = { req, id, handle }
        if options.cleanup_result ~= nil then cb(options.cleanup_result, "cleanup refused")
        else cb(true) end
    end
    function a.cleanup_record(record, cb)
        a.record = record
        a.record_cleanup_count = (a.record_cleanup_count or 0) + 1
        cb(options.record_result ~= false, options.record_result == false and "record cleanup failed" or nil)
    end
    return a
end
local function setup(a, dirname)
    if capture.current() then capture.dismiss() end
    capture.setup({ dir = root .. "/" .. dirname, adapters = { opencode = a, claude = a } })
end
local function finish(a, text, id)
    a.done({ helper_id = id or a.id, text = text or "# Finding\n\nA verified result." })
    vim.wait(100, function() return capture.current().state ~= "capturing" end, 5)
end
local function latest() return assert(capture.current()) end

-- Isolate the worker environment and test the real adapter's jobstart contract.
do
    local previous = vim.fn.jobstart
    local previous_jobpid = vim.fn.jobpid
    local args, opts
    local unprepared = vim.deepcopy(claude_request)
    vim.fn.jobstart = function(argv, jobopts) args, opts = argv, jobopts; return 41 end
    local ok, result = pcall(claude.start, unprepared, "safe", function() return true end, function() end)
    vim.fn.jobstart = previous
    vim.fn.jobpid = function() return 4242 end
    assert(ok and result == nil) -- start refuses an unprepared request before jobstart.
    assert(args == nil and opts == nil)
    local id = assert(claude.prepare(claude_request, capture_id))
    vim.fn.jobstart = function(argv, jobopts) args, opts = argv, jobopts; return 41 end
    local handle = assert(claude.start(claude_request, "safe", function(got) return got == id end, function() end))
    vim.fn.jobstart = previous
    vim.fn.jobpid = previous_jobpid
    assert(handle.process == 41 and opts.clear_env == true)
    assert(opts.env.NVIM_AGENT_TOPIC == nil and opts.env.NVIM_AGENT_DASHBOARD_DIR == nil)
end

-- Frozen request and topic metadata must not follow caller-side mutation.
do
    local a = adapter({ saved_probe = function()
        for _, note in ipairs(topics.notes("capture-test")) do
            if note.source.session == request.source.session then return vim.fn.filereadable(note.path) == 1 end
        end
        return false
    end })
    setup(a, "journal-immutable")
    local input = vim.deepcopy(request)
    capture.start(input)
    input.focus, input.topic_id, input.source.session = "mutated", "missing", "ses_other"
    assert(a.request.focus == "retry behavior" and a.request.topic_id == "capture-test")
    assert(a.request.source.session == "ses_source" and a.prompt:find("retry behavior", 1, true))
    finish(a)
    assert(latest().state == "complete")
    assert(vim.fn.filereadable(latest().path) == 1 and a.calls.cleanup)
    assert(a.cleanup_saw_saved == true, "note must be durable before helper deletion")
end

-- Save failure still preserves generated output before attempting helper cleanup.
do
    local a = adapter()
    setup(a, "journal-save-fail")
    local original = topics.capture_save
    topics.capture_save = function() return nil, "simulated destination failure" end
    capture.start(request)
    finish(a)
    topics.capture_save = original
    assert(latest().state == "failed" and vim.fn.filereadable(latest().recovery_path) == 1)
    assert(a.calls.cleanup and latest().error:find("Save failed", 1, true))
end

-- Completion is idempotent, and cleanup failure retains a durable helper record.
do
    local a = adapter({ cleanup_result = false })
    setup(a, "journal-cleanup-fail")
    capture.start(request)
    finish(a)
    assert(latest().state == "complete" and latest().cleanup_done == false)
    assert(#capture.cleanup_pending() == 1 and capture.is_helper("opencode", a.id))
    local notes_before = #topics.notes("capture-test")
    a.done({ helper_id = a.id, text = "duplicate" })
    vim.wait(25)
    assert(#topics.notes("capture-test") == notes_before)
    local saved_path = latest().path
    assert(capture.dismiss())
    assert(capture.is_helper("opencode", a.id))
    assert(vim.fn.filereadable(saved_path) == 1, "saved result remains accessible after dismiss")
end

-- Cancellation waits for a confirmed stop before deleting the helper; late result
-- callbacks cannot save, and duplicate completion cannot race cleanup.
do
    local a = adapter()
    setup(a, "journal-cancel")
    capture.start(request)
    assert(capture.cancel())
    a.done({ helper_id = a.id, text = "must not be saved" })
    vim.wait(20)
    assert(not a.calls.cleanup)
    a.cancel_done(true)
    vim.wait(50)
    assert(a.calls.cleanup and latest().state == "cancelled" and a.cleanup_count == 1)
    a.cancel_done(true)
    assert(a.cleanup_count == 1, "duplicate stop acknowledgement must not repeat deletion")
    a.done({ helper_id = a.id, text = "duplicate" })
    vim.wait(20)
    assert(not latest().path)
end

-- An empty note snapshot remains empty when an unrelated note arrives while the
-- brief worker runs; accepting that proposal must not consolidate the new note.
do
    assert(topics.create("empty-snapshot", { title = "Empty snapshot" }))
    local a = adapter()
    setup(a, "journal-empty-snapshot")
    local brief = vim.deepcopy(request)
    brief.kind, brief.topic_id = "brief", "empty-snapshot"
    capture.start(brief)
    local new_note = assert(topics.note("empty-snapshot", "# Arrived later\n\nNot in snapshot.", {}))
    finish(a, "# Updated empty topic\n\nSession findings.")
    assert(latest().state == "complete")
    local manifest = vim.json.decode(table.concat(vim.fn.readfile(root .. "/topics/empty-snapshot/brief.proposed.notes.json"), "\n"))
    assert(next(manifest) == nil)
    assert(topics.accept_proposal("empty-snapshot"))
    local notes = topics.notes("empty-snapshot")
    assert(#notes == 1 and notes[1].path == new_note and not notes[1].consolidated)
end

-- The coordinator refuses ownership of source IDs and journals ownership before
-- work; failed journal creation must prevent worker startup.
do
    local a = adapter({ own_on_start = true, id = "ses_source" })
    setup(a, "journal-source-guard")
    local started, source_err = capture.start(request)
    assert(not started and source_err:find("source session", 1, true))
    assert(not a.request, "source ownership must be rejected before worker startup")
    local dir = root .. "/journal-unwritable"
    vim.fn.mkdir(dir, "p")
    local b = adapter()
    setup(b, "journal-unwritable")
    local fs_open = vim.uv.fs_open
    vim.uv.fs_open = function(path, ...)
        if path:find("journal%-unwritable", 1) then return nil, "simulated disk failure" end
        return fs_open(path, ...)
    end
    local refused, journal_err = capture.start(request)
    vim.uv.fs_open = fs_open
    assert(not refused and journal_err:find("journal", 1, true))
    assert(not b.request, "worker must not start before ownership journal is durable")
end

-- Journal recovery accepts only a valid, filename-matched record and refuses a
-- record whose helper aliases its original source. Valid records are cleaned.
do
    local dir = root .. "/journal-reconcile"
    vim.fn.mkdir(dir, "p")
    local id = string.rep("b", 32)
    local helper = "ses_recover"
    local valid = { schema = 1, workflow = "agent-dashboard-capture-v1", id = id,
        harness = "opencode", source_id = "ses_original", project = project,
        topic_id = "capture-test", kind = "note", state = "capturing", helper_id = helper }
    vim.fn.writefile({ vim.json.encode(valid) }, dir .. "/" .. id .. ".json")
    local wrong_id = vim.deepcopy(valid); wrong_id.id = string.rep("c", 32); wrong_id.helper_id = "ses_bad"
    vim.fn.writefile({ vim.json.encode(wrong_id) }, dir .. "/" .. string.rep("d", 32) .. ".json")
    local source_alias = vim.deepcopy(valid); source_alias.id = string.rep("e", 32); source_alias.helper_id = source_alias.source_id
    vim.fn.writefile({ vim.json.encode(source_alias) }, dir .. "/" .. source_alias.id .. ".json")
    local recovery_adapter = adapter({ record_result = true })
    if capture.current() then capture.dismiss() end
    capture.setup({ dir = dir, adapters = { opencode = recovery_adapter } })
    vim.wait(100, function() return recovery_adapter.record ~= nil end, 5)
    assert(recovery_adapter.record and recovery_adapter.record.id == id)
    assert(recovery_adapter.record.helper_id == helper)
    assert(capture.is_helper("opencode", helper))
    assert(not capture.is_helper("opencode", "ses_bad"))
    assert(recovery_adapter.record_cleanup_count == 1, "invalid records must never reach cleanup")
    assert(capture.dismiss())
    assert(not capture.is_helper("opencode", helper), "cleaned helper is no longer pending after dismiss")
end

-- A lost OpenCode fork response has no verifiable identity: retain the durable
-- journal and expose the orphan as pending without calling cleanup_record.
do
    local dir = root .. "/journal-fork-pending"
    vim.fn.mkdir(dir, "p")
    local id = string.rep("f", 32)
    local record = { schema = 1, workflow = "agent-dashboard-capture-v1", id = id,
        harness = "opencode", source_id = "ses_original", project = project,
        topic_id = "capture-test", kind = "note", state = "capturing", fork_pending = true }
    vim.fn.writefile({ vim.json.encode(record) }, dir .. "/" .. id .. ".json")
    local lost = adapter()
    if capture.current() then capture.dismiss() end
    capture.setup({ dir = dir, adapters = { opencode = lost } })
    vim.wait(100, function()
        return capture.current() and capture.current().id == id and capture.current().cleanup_error ~= nil
    end, 5)
    local pending = capture.cleanup_pending()
    assert(#pending == 1 and pending[1].id == id and pending[1].fork_pending)
    assert(lost.record_cleanup_count == nil, "must not delete when fork identity is unknown")
    assert(capture.current().cleanup_error
        and capture.current().cleanup_error:find("identity cannot be verified", 1, true),
        vim.inspect(capture.current()))
end

-- Journal output write failure falls back to a durable data-directory recovery
-- file; the saved result remains usable and cleanup still completes.
do
    local recovery_was_durable = false
    local a = adapter({ saved_probe = function()
        local files = vim.fn.glob(root .. "/fallback-data/agent-dashboard/capture-results/*.md", false, true)
        recovery_was_durable = #files == 1 and vim.fn.filereadable(files[1]) == 1
        return recovery_was_durable
    end })
    setup(a, "journal-fallback")
    local stdpath = vim.fn.stdpath
    vim.fn.stdpath = function(kind)
        if kind == "data" then return root .. "/fallback-data" end
        return stdpath(kind)
    end
    local fs_open = vim.uv.fs_open
    vim.uv.fs_open = function(path, ...)
        if path:find("journal%-fallback") and path:find("%.output%.md") then
            return nil, "injected journal output failure"
        end
        return fs_open(path, ...)
    end
    capture.start(request)
    finish(a)
    vim.uv.fs_open = fs_open
    vim.fn.stdpath = stdpath
    assert(latest().state == "complete" and latest().path)
    assert(recovery_was_durable, "fallback output must be durable before cleanup")
    assert(not latest().recovery_path and #vim.fn.glob(root .. "/fallback-data/agent-dashboard/capture-results/*.md", false, true) == 0)
    assert(a.calls.cleanup)
end

-- Proposal/capture validation, no-note brief mode, concurrent work, and note name
-- collisions exercise storage protections through the actual coordinator.
do
    assert(topics.propose_brief("capture-test", "# Pending proposal", "base"))
    local a = adapter()
    setup(a, "journal-proposal")
    local started = capture.start({ kind = "brief", topic_id = "capture-test", source = request.source })
    assert(not started)
    assert(not a.request)
    assert(topics.reject_proposal("capture-test"))

    local brief_adapter = adapter()
    setup(brief_adapter, "journal-brief")
    local brief_request = vim.deepcopy(request); brief_request.kind = "brief"
    capture.start(brief_request)
    assert(brief_adapter.prompt:find("not note consolidation", 1, true))
    assert(not brief_adapter.prompt:find("Current brief supplied explicitly", 1, true) == false)
    local _, busy_err = capture.start(request)
    assert(not _ and busy_err:find("already active", 1, true))
    local brief_path = topics.brief_path("capture-test")
    local base = vim.fn.sha256(table.concat(vim.fn.readfile(brief_path), "\n"))
    assert(topics.propose_brief("capture-test", "# Concurrent proposal", base))
    finish(brief_adapter, "# Revised brief\n\nSession based.")
    assert(latest().state == "failed" and latest().recovery_path)
    assert(vim.fn.filereadable(latest().recovery_path) == 1)
    assert(topics.reject_proposal("capture-test"))

    local collision = adapter()
    setup(collision, "journal-collision")
    local existing = assert(topics.note("capture-test", "# Collision\n\nExisting", {}))
    capture.start(request)
    finish(collision, "# Collision\n\nGenerated")
    assert(latest().state == "complete" and latest().path ~= existing)
    assert(vim.fn.filereadable(existing) == 1)
    assert(vim.fn.filereadable(latest().path) == 1)
end

-- A destination permission/storage error must fail immediately, not keep
-- trying ever-increasing note suffixes as though every error were a collision.
do
    local fs_open, attempts = vim.uv.fs_open, 0
    vim.uv.fs_open = function(path, ...)
        if path:find("/notes/", 1, true) then
            attempts = attempts + 1
            return nil, "EACCES: permission denied"
        end
        return fs_open(path, ...)
    end
    local note, err = topics.note("capture-test", "# Permission failure", {})
    vim.uv.fs_open = fs_open
    assert(not note and err:find("EACCES", 1, true) and attempts == 1)
end

vim.fn.chansend = original_chansend
vim.api.nvim_chan_send = original_nvim_chan_send
vim.fn.delete(root, "rf")
print("capture tests passed")
