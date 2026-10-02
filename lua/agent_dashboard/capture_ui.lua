-- Capture request editor and compact job controls. Execution and persistence belong
-- to capture.lua; this module deliberately never sends data to an agent terminal.
local M = {}
local backend, dialog, review_brief, open_result, validate_retry
local opening = false
local diagnostic_windows = {}

local function current() return backend and backend.current() end
local function close(restore)
    if not dialog then return end
    local d = dialog
    dialog = nil
    if vim.api.nvim_win_is_valid(d.win) then vim.api.nvim_win_close(d.win, true) end
    if vim.api.nvim_buf_is_valid(d.buf) then vim.api.nvim_buf_delete(d.buf, { force = true }) end
    if restore and d.restore then d.restore() end
end
local function redraw()
    if not dialog or not vim.api.nvim_win_is_valid(dialog.win) then return end
    local d, topic = dialog, dialog.topics[dialog.topic_index]
    local focus = dialog.focus
    local lines = {
        " Source: " .. tostring(d.request.source.harness) .. " / " .. tostring(d.request.source.session),
        " Project: " .. tostring(d.request.source.project),
        " Topic:   " .. (topic and ((topic.title or topic.id) .. " [" .. topic.id .. "]") or "<choose topic>"),
        " Focus:   " .. (focus ~= "" and focus or "<optional; press Enter to edit>"),
        "", " [s] Save findings", " [b] Propose brief",
    }
    if dialog.error then lines[#lines + 1] = " Error: " .. dialog.error end
    lines[#lines + 1] = ""
    lines[#lines + 1] = " Tab/Shift-Tab or j/k navigate · Enter activate · Esc close"
    vim.bo[d.buf].modifiable = true
    vim.api.nvim_buf_set_lines(d.buf, 0, -1, false, lines)
    vim.bo[d.buf].modifiable = false
    vim.api.nvim_win_set_cursor(d.win, { d.row, 0 })
end
local function fail(message)
    dialog.error = tostring(message or "Capture failed")
    redraw()
end
local function submit(kind)
    local d = dialog
    local topic = d.topics[d.topic_index]
    if not topic then return fail("Choose a topic first") end
    local request = vim.deepcopy(d.request)
    request.kind, request.topic_id = kind, topic.id
    request.focus = d.focus ~= "" and d.focus or nil
    if d.validate then
        local valid, validation_error = d.validate(request)
        if not valid then return fail(validation_error or "Source is no longer eligible for capture") end
    end
    local job, err = backend.start(request)
    if not job then return fail(err) end
    close(true)
    if d.on_change then d.on_change() end
end
function M.setup(api, options)
    backend = api
    options = options or {}
    review_brief, open_result = options.review_brief, options.open_result
    validate_retry = options.validate_retry
end
function M.open(request, topics, on_change, restore, validate)
    close(false)
    vim.cmd("stopinsert")
    if vim.o.columns < 50 or vim.o.lines < 15 then return nil, "Capture window requires at least 50 columns and 15 lines" end
    local buf = vim.api.nvim_create_buf(false, true)
    local width, height = math.min(72, vim.o.columns - 6), 11
    opening = true
    local win = vim.api.nvim_open_win(buf, true, { relative = "editor", style = "minimal", border = "rounded",
        title = " Capture from selected agent ", title_pos = "center", width = width, height = height,
        row = math.max(0, math.floor((vim.o.lines - height) / 2)), col = math.max(0, math.floor((vim.o.columns - width) / 2)) })
    opening = false
    vim.bo[buf].buftype, vim.bo[buf].bufhidden, vim.bo[buf].swapfile = "nofile", "wipe", false
    vim.wo[win].cursorline, vim.wo[win].wrap = true, true
    local choices = vim.deepcopy(topics or {})
    local index = 1
    if request.topic_id then for i, t in ipairs(choices) do if t.id == request.topic_id then index = i end end end
    dialog = { buf = buf, win = win, request = vim.deepcopy(request), topics = choices,
        topic_index = #choices > 0 and index or 0, focus = request.focus or "", row = 3,
        restore = restore, on_change = on_change, validate = validate }
    if validate and choices[index] then
        local initial = vim.deepcopy(request)
        initial.topic_id = choices[index].id
        local valid, err = validate(initial)
        if not valid then dialog.error = err end
    end
    local function map(key, fn) vim.keymap.set("n", key, fn, { buffer = buf, nowait = true, silent = true }) end
    local navigable = { 3, 4, 6, 7 }
    local function move(delta)
        local index = 1
        for i, row in ipairs(navigable) do if row == dialog.row then index = i end end
        dialog.row = navigable[(index - 1 + delta) % #navigable + 1]
        redraw()
    end
    local function activate()
        if dialog.row == 3 then
            if #dialog.topics == 0 then return fail("No topics available") end
            vim.ui.select(dialog.topics, { prompt = "Capture destination topic", format_item = function(t) return t.title .. " (" .. t.id .. ")" end }, function(t)
                if t and dialog then for i, item in ipairs(dialog.topics) do if item.id == t.id then dialog.topic_index = i end end; dialog.error = nil; redraw() end
            end)
        elseif dialog.row == 4 then
            vim.ui.input({ prompt = "Capture focus (optional): ", default = dialog.focus }, function(value)
                if value ~= nil and dialog then dialog.focus = value; redraw() end
            end)
        elseif dialog.row == 6 then submit("note")
        elseif dialog.row == 7 then submit("brief") end
    end
    map("<Tab>", function() move(1) end); map("<S-Tab>", function() move(-1) end)
    map("j", function() move(1) end); map("k", function() move(-1) end)
    map("<CR>", activate); map("<Space>", activate)
    map("s", function() submit("note") end); map("b", function() submit("brief") end)
    map("<Esc>", function() close(true) end); map("q", function() close(true) end)
    redraw()
    return win, buf
end
function M.action(action, on_change)
    local job = current()
    if not job then return false, "No capture result" end
    if action == "error" then
        local buf = vim.api.nvim_create_buf(false, true)
        local source = job.request and job.request.source or {}
        local lines = { "Capture diagnostics", "", "State: " .. tostring(job.state),
            "Source: " .. tostring(source.harness) .. " / " .. tostring(source.session),
            "Save error: " .. tostring(job.error or "none"),
            "Helper cleanup error: " .. tostring(job.cleanup_error or "none"),
            "Saved path: " .. tostring(job.path or "none"),
            "Recovery path: " .. tostring(job.recovery_path or "none"), "", "Press q or Esc to close" }
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines); vim.bo[buf].modifiable = false
        local width, height = math.min(70, vim.o.columns - 6), math.min(#lines, vim.o.lines - 4)
        opening = true
        local win = vim.api.nvim_open_win(buf, true, { relative = "editor", style = "minimal", border = "rounded",
            title = " Capture diagnostics ", width = width, height = height,
            row = math.max(0, math.floor((vim.o.lines - height) / 2)), col = math.max(0, math.floor((vim.o.columns - width) / 2)) })
        diagnostic_windows[win] = true
        opening = false
        local function quit()
            diagnostic_windows[win] = nil
            if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
        end
        vim.keymap.set("n", "q", quit, { buffer = buf, nowait = true }); vim.keymap.set("n", "<Esc>", quit, { buffer = buf, nowait = true })
        return true
    elseif action == "open" or action == "review" then
        if action == "review" and job.request and job.request.kind == "brief" and review_brief then
            review_brief(job.request.topic_id); return true
        end
        local path = job.path or job.recovery_path
        if path then
            if action == "review" and job.request and job.request.kind == "brief" and review_brief then
                review_brief(job.request.topic_id)
            elseif open_result then open_result(path)
            else vim.cmd("edit " .. vim.fn.fnameescape(path)) end
            return true
        end
        return false, "Capture has no saved output yet"
    end
    local method = ({ cancel = "cancel", retry = "retry", dismiss = "dismiss" })[action]
    if not method then return false, "Unknown capture action" end
    if action == "retry" and validate_retry then
        local valid, err = validate_retry(job.request)
        if not valid then return false, err end
    end
    local ok, err = backend[method]()
    if ok and on_change then on_change() end
    return ok, err
end
function M.summary(slot_id, source_open)
    local job = current()
    if not job then return nil end
    local req = job.request or {}; local src = req.source or {}
    local labels = { starting = "Starting capture…", capturing = "Capturing findings…", saving = "Saving result…",
        cleaning = "Cleaning up…", complete = req.kind == "brief" and "Brief proposed" or "Note saved",
        failed = "Capture failed", cancelled = "Capture cancelled" }
    local text = " ↳ " .. (labels[job.state] or tostring(job.state))
    if req.focus and req.focus ~= "" then text = text .. " · " .. req.focus end
    if job.cleanup_error then text = text .. " · cleanup pending" end
    if src.slot_id == slot_id then return text end
    if slot_id == nil and not source_open then return " Orphan capture: " .. text .. " · source " .. tostring(src.session) end
end
function M.source_slot() local job = current(); return job and job.request and job.request.source and job.request.source.slot_id end
function M.row_items()
    local job = current(); if not job then return {} end
    if job.state == "capturing" or job.state == "starting" or job.state == "saving" or job.state == "cleaning" then
        return { "cancel" }
    elseif job.state == "failed" then return { "error", "open", "retry", "dismiss" }
    elseif job.state == "complete" then
        local result = { job.request.kind == "brief" and "review" or "open" }
        if job.cleanup_error then result[#result + 1] = "error" end
        result[#result + 1] = "dismiss"
        return result
    elseif job.state == "cancelled" then
        return job.cleanup_error and { "error", "retry", "dismiss" } or { "retry", "dismiss" }
    end
    return {}
end
function M._dialog() return dialog end
function M.owns_window(win)
    return opening or (dialog and dialog.win == win) or diagnostic_windows[win] == true
end
return M
