local M = {}

local function first_prompt(path)
    local fd = vim.uv.fs_open(path, "r", 0)
    if not fd then return nil end
    local data = vim.uv.fs_read(fd, 32768, 0)
    vim.uv.fs_close(fd)
    for line in (data or ""):gmatch("([^\n]+)\n") do
        local ok, record = pcall(vim.json.decode, line)
        if ok and type(record) == "table" and record.type == "user"
            and type(record.message) == "table" then
            local content = record.message.content
            if type(content) == "table" then
                for _, part in ipairs(content) do
                    if type(part) == "table" and part.type == "text" then content = part.text; break end
                end
            end
            if type(content) == "string" and content:match("%S") then return content end
        end
    end
end

local function read_index(path)
    if vim.fn.filereadable(path) ~= 1 then return nil end
    local ok, index = pcall(function()
        return vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
    end)
    return ok and type(index) == "table" and index or nil
end

local function claude_sessions(cwd, limit, projects_dir)
    local root = projects_dir or vim.fn.expand("~/.claude/projects")
    local dir = root .. "/" .. cwd:gsub("[^%w%-]", "-")
    local stat = vim.uv.fs_stat(dir)
    local index = stat and stat.type == "directory" and read_index(dir .. "/sessions-index.json")
    if not stat or stat.type ~= "directory" or (index and index.originalPath and index.originalPath ~= cwd) then
        -- Older/newer Claude versions can encode project paths differently.
        local scan = vim.uv.fs_scandir(root)
        if not scan then return {} end
        dir = nil
        while true do
            local name, kind = vim.uv.fs_scandir_next(scan)
            if not name then break end
            if kind == "directory" then
                local candidate = root .. "/" .. name
                local candidate_index = read_index(candidate .. "/sessions-index.json")
                if candidate_index and candidate_index.originalPath == cwd then
                    dir, index = candidate, candidate_index
                    break
                end
            end
        end
    end
    if not dir then return {} end

    local titles = {}
    for _, entry in ipairs(index and type(index.entries) == "table" and index.entries or {}) do
        if type(entry) == "table" and (not entry.projectPath or entry.projectPath == cwd)
            and type(entry.sessionId) == "string" then
            titles[entry.sessionId] = entry.firstPrompt
        end
    end
    local sessions = {}
    local files = vim.uv.fs_scandir(dir)
    if not files then return sessions end
    while true do
        local file, kind = vim.uv.fs_scandir_next(files)
        if not file then break end
        local id = file:match("^([%x%-]+)%.jsonl$")
        if id and kind == "file" and id:match("^[%x]+%-%x+%-%x+%-%x+%-%x+$") then
            local path = dir .. "/" .. file
            local info = vim.uv.fs_stat(path)
            if info then
                sessions[#sessions + 1] = {
                    harness = "claude", id = id, title = titles[id],
                    updated = info.mtime.sec * 1000, path = path,
                }
            end
        end
    end
    table.sort(sessions, function(a, b) return a.updated > b.updated end)
    while #sessions > limit do table.remove(sessions) end
    for _, session in ipairs(sessions) do
        if type(session.title) ~= "string" or session.title == "" then
            session.title = first_prompt(session.path)
        end
        session.path = nil
    end
    return sessions
end

local function merge(opencode, claude, limit)
    vim.list_extend(opencode, claude)
    table.sort(opencode, function(a, b) return a.updated > b.updated end)
    while #opencode > limit do table.remove(opencode) end
    return opencode
end

function M.refresh(cwd, callback, opts)
    opts = opts or {}
    local limit = opts.recent_limit or 5
    local claude = claude_sessions(cwd, limit, opts.claude_projects)
    if vim.fn.executable("opencode") == 0 then callback(merge({}, claude, limit)); return end

    local stdout = {}
    local job = vim.fn.jobstart({ "opencode", "session", "list", "--format", "json", "--max-count",
        tostring(math.max(10, limit * 2)) }, {
        cwd = cwd,
        stdout_buffered = true,
        on_stdout = function(_, data) stdout = data end,
        on_exit = function(_, code)
            local sessions = {}
            if code == 0 then
                local ok, parsed = pcall(vim.json.decode, table.concat(stdout, "\n"))
                if ok and type(parsed) == "table" then
                    for _, entry in ipairs(parsed) do
                        if type(entry) == "table" and entry.directory == cwd
                            and type(entry.id) == "string" and entry.id:match("^ses_[%w]+$")
                            and type(entry.updated) == "number" then
                            sessions[#sessions + 1] = {
                                harness = "opencode", id = entry.id, title = entry.title,
                                updated = entry.updated,
                            }
                        end
                    end
                end
            end
            callback(merge(sessions, claude, limit))
        end,
    })
    if job <= 0 then callback(merge({}, claude, limit)) end
end

return M
