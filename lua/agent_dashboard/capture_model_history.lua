-- Model preferences are independent of helper ownership and capture output.
local M = {}
local path, last, recent
local harnesses, kinds = { "claude", "opencode" }, { "note", "brief" }

function M.validate(harness, model)
    if model == nil then return true end
    if type(model) ~= "string" or vim.trim(model) == "" then
        return nil, "Capture model must be a non-empty string"
    end
    if harness == "opencode" and not model:match("^[^/]+/.+$") then
        return nil, "OpenCode capture model must use provider/model format"
    end
    return true
end

function M.setup(filename)
    path, last, recent = filename, {}, {}
    if vim.fn.filereadable(path) ~= 1 then return end
    local ok, data = pcall(function() return vim.json.decode(table.concat(vim.fn.readfile(path), "\n")) end)
    if not ok or type(data) ~= "table" or data.schema ~= 1 then return end
    for _, harness in ipairs(harnesses) do
        last[harness], recent[harness] = {}, {}
        local saved = type(data.last) == "table" and data.last[harness]
        for _, kind in ipairs(kinds) do
            local model = type(saved) == "table" and saved[kind]
            if type(model) == "string" and M.validate(harness, model) then last[harness][kind] = model end
        end
        local models = type(data.recent) == "table" and data.recent[harness]
        if type(models) == "table" then
            for _, model in ipairs(models) do
                if #recent[harness] >= 8 then break end
                if type(model) == "string" and M.validate(harness, model) and not vim.tbl_contains(recent[harness], model) then
                    recent[harness][#recent[harness] + 1] = model
                end
            end
        end
    end
end

function M.get(harness, kind) return last and last[harness] and last[harness][kind] end
function M.choices(harness) return vim.deepcopy(recent and recent[harness] or {}) end

function M.remember(harness, kind, model)
    if not path then return true end
    if not vim.tbl_contains(harnesses, harness) or not vim.tbl_contains(kinds, kind) then return nil, "Invalid capture model preference" end
    local valid, err = M.validate(harness, model)
    if not valid then return nil, err end
    last[harness] = last[harness] or {}
    last[harness][kind] = model
    recent[harness] = recent[harness] or {}
    if model then
        local models = { model }
        for _, previous in ipairs(recent[harness]) do
            if previous ~= model and #models < 8 then models[#models + 1] = previous end
        end
        recent[harness] = models
    end
    local text = vim.json.encode({ schema = 1, last = last, recent = recent })
    local temporary = path .. ".tmp." .. vim.fn.getpid()
    local fd, open_err = vim.uv.fs_open(temporary, "w", 384)
    if not fd then return nil, open_err end
    local written, write_err = vim.uv.fs_write(fd, text, 0)
    local synced, sync_err
    if written == #text then synced, sync_err = vim.uv.fs_fsync(fd) end
    local closed, close_err = vim.uv.fs_close(fd)
    if written ~= #text or not synced or not closed then
        vim.uv.fs_unlink(temporary)
        return nil, write_err or sync_err or close_err or "Incomplete model preference write"
    end
    local renamed, rename_err = vim.uv.fs_rename(temporary, path)
    if not renamed then vim.uv.fs_unlink(temporary); return nil, rename_err end
    return true
end

return M
