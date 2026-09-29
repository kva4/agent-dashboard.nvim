local M = {}
local title_cache = {}
local project_cache = {}

local function read_range(path, offset, length)
    local fd = vim.uv.fs_open(path, "r", 0)
    if not fd then return nil end
    local data = vim.uv.fs_read(fd, length, offset)
    vim.uv.fs_close(fd)
    return data
end

local function title_for(path, info)
    local key = table.concat({ info.size or 0, info.mtime.sec or 0, info.mtime.nsec or 0 }, ":")
    local cached = title_cache[path]
    if cached and cached.key == key then return cached.title end

    local size = info.size or 0
    local first = read_range(path, 0, math.min(size, 32768)) or ""
    local last = size > 32768 and (read_range(path, math.max(0, size - 32768), 32768) or "") or ""
    local custom_title, ai_title, prompt
    local function inspect(data)
        for line in data:gmatch("([^\n]+)") do
            local ok, record = pcall(vim.json.decode, line)
            if ok and type(record) == "table" then
                if record.type == "custom-title" then
                    custom_title = record.customTitle or record.title or record.name
                elseif record.type == "ai-title" then
                    ai_title = record.aiTitle or record.title
                elseif not prompt and record.type == "user" and type(record.message) == "table" then
                    local content = record.message.content
                    if type(content) == "table" then
                        for _, part in ipairs(content) do
                            if type(part) == "table" and part.type == "text" then
                                content = part.text
                                break
                            end
                        end
                    end
                    if type(content) == "string" then
                        content = content:gsub("^%s+", "")
                        if content:match("%S") and content:sub(1, 1) ~= "<" then prompt = content end
                    end
                end
            end
        end
    end
    inspect(first)
    if last ~= "" and last ~= first then inspect(last) end
    local title = type(custom_title) == "string" and custom_title ~= "" and custom_title
        or type(ai_title) == "string" and ai_title ~= "" and ai_title
        or prompt
    title_cache[path] = { key = key, title = title }
    return title
end

local function read_index(path)
    if vim.fn.filereadable(path) ~= 1 then return nil end
    local ok, index = pcall(function()
        return vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
    end)
    return ok and type(index) == "table" and index or nil
end

local function directory_matches_cwd(dir, cwd)
    local files = vim.uv.fs_scandir(dir)
    if not files then return false end
    local checked = 0
    while true do
        local file, kind = vim.uv.fs_scandir_next(files)
        if not file then break end
        if kind == "file" and file:match("%.jsonl$") then
            checked = checked + 1
            local data = read_range(dir .. "/" .. file, 0, 32768) or ""
            for line in data:gmatch("([^\n]+)") do
                local ok, record = pcall(vim.json.decode, line)
                if ok and type(record) == "table" and record.cwd == cwd then return true end
            end
            if checked >= 8 then break end
        end
    end
    return false
end

local function path_stamp(path)
    local stat = path and vim.uv.fs_stat(path)
    if not stat then return "missing" end
    return table.concat({ stat.mtime.sec or 0, stat.mtime.nsec or 0 }, ":")
end

local function project_stamp(root, cwd, cached_dir)
    local expected = root .. "/" .. cwd:gsub("[^%w%-]", "-")
    return table.concat({ path_stamp(root), path_stamp(expected), path_stamp(cached_dir) }, "|")
end

local function find_project_dir(root, cwd)
    local root_cache = project_cache[root]
    local cached = root_cache and root_cache[cwd]
    local stamp = project_stamp(root, cwd, cached and cached.dir or nil)
    if cached and cached.stamp == stamp then
        local dir = cached.dir or nil
        return dir, dir and read_index(dir .. "/sessions-index.json") or nil
    end

    local expected = root .. "/" .. cwd:gsub("[^%w%-]", "-")
    local stat = vim.uv.fs_stat(expected)
    local dir, index
    if stat and stat.type == "directory" then
        index = read_index(expected .. "/sessions-index.json")
        if index and (not index.originalPath or index.originalPath == cwd) then
            dir = expected
        elseif not index and directory_matches_cwd(expected, cwd) then
            dir = expected
        end
    end

    if not dir then
        local scan = vim.uv.fs_scandir(root)
        if scan then
            while true do
                local name, kind = vim.uv.fs_scandir_next(scan)
                if not name then break end
                if kind == "directory" then
                    local candidate = root .. "/" .. name
                    local candidate_index = read_index(candidate .. "/sessions-index.json")
                    if (candidate_index and candidate_index.originalPath == cwd)
                        or directory_matches_cwd(candidate, cwd) then
                        dir, index = candidate, candidate_index
                        break
                    end
                end
            end
        end
    end

    root_cache = root_cache or {}
    project_cache[root] = root_cache
    root_cache[cwd] = { stamp = project_stamp(root, cwd, dir), dir = dir or false }
    return dir, index
end

local function claude_sessions(cwd, limit, projects_dir)
    local root = projects_dir or vim.fn.expand("~/.claude/projects")
    local dir, index = find_project_dir(root, cwd)
    if not dir then return {} end

    local titles = {}
    for _, entry in ipairs(index and type(index.entries) == "table" and index.entries or {}) do
        if type(entry) == "table" and (not entry.projectPath or entry.projectPath == cwd)
            and type(entry.sessionId) == "string" then
            local title = entry.customTitle or entry.aiTitle or entry.title
            if not title and type(entry.firstPrompt) == "string" then
                local prompt = entry.firstPrompt:gsub("^%s+", "")
                if prompt:sub(1, 1) ~= "<" then title = prompt end
            end
            titles[entry.sessionId] = title
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
                    updated = info.mtime.sec * 1000, path = path, info = info,
                }
            end
        end
    end
    table.sort(sessions, function(a, b) return a.updated > b.updated end)
    while #sessions > limit do table.remove(sessions) end
    for _, session in ipairs(sessions) do
        session.title = title_for(session.path, session.info) or session.title
        session.path, session.info = nil, nil
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
    local limit = opts.recent_limit or 10
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
