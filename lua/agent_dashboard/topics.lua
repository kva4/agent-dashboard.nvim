local M = {}
local directory = vim.fn.stdpath("data") .. "/agent-dashboard/topics"
local brief_limit = 150
local consolidation_notes = {}
local with_frontmatter

local function join(...)
    return (table.concat({ ... }, "/"):gsub("/+$", ""))
end

local function valid_id(id)
    return type(id) == "string" and id:match("^[a-z0-9][a-z0-9%-]*$") ~= nil
end

local function topic_dir(id)
    if not valid_id(id) then return nil, "Topic IDs may contain lowercase letters, numbers, and hyphens" end
    return join(directory, id)
end

local function read(path)
    if vim.fn.filereadable(path) ~= 1 then return nil end
    return table.concat(vim.fn.readfile(path), "\n")
end

-- Exclusive creation prevents a concurrent capture (or a pre-existing file) from
-- being silently overwritten. Writes are flushed before the descriptor is closed.
local function write_new(path, text)
    local fd, err = vim.uv.fs_open(path, "wx", 384)
    if not fd then return nil, err or "File already exists" end
    local offset = 0
    local failure
    while offset < #text do
        local written, write_err = vim.uv.fs_write(fd, text:sub(offset + 1), offset)
        if not written or written <= 0 then failure = write_err or "Write failed"; break end
        offset = offset + written
    end
    if not failure then local ok, sync_err = vim.uv.fs_fsync(fd); if not ok then failure = sync_err or "Fsync failed" end end
    local close_ok, close_err = vim.uv.fs_close(fd)
    if not close_ok and not failure then failure = close_err or "Close failed" end
    if failure then vim.uv.fs_unlink(path); return nil, failure end
    return true
end

function M.write_new(path, text)
    if type(path) ~= "string" or type(text) ~= "string" then return nil, "Invalid write" end
    return write_new(path, text)
end

function M.capture_snapshot(id)
    local path, err = M.brief_path(id)
    if not path then return nil, err end
    local text = read(path) or ""
    if vim.fn.filereadable(join(topic_dir(id), "brief.proposed.md")) == 1 then
        return nil, "A brief proposal is already pending"
    end
    return { path = path, text = text, hash = vim.fn.sha256(text) }
end

function M.capture_save(id, kind, text, source, snapshot)
    if kind == "note" then return M.note(id, text, source) end
    if kind ~= "brief" or type(snapshot) ~= "table" then return nil, "Invalid brief snapshot" end
    if vim.fn.sha256(read(snapshot.path) or "") ~= snapshot.hash then
        return nil, "brief.md changed while capture was running"
    end
    source = type(source) == "table" and source or {}
    local content = with_frontmatter({ source = source }, text)
    return M.propose_brief(id, content, snapshot.hash, {})
end

local function strip_comment(value)
    local quote, escaped
    for index = 1, #value do
        local char = value:sub(index, index)
        if escaped then
            escaped = false
        elseif quote == '"' and char == "\\" then
            escaped = true
        elseif quote and char == quote then
            quote = nil
        elseif not quote and (char == '"' or char == "'") then
            quote = char
        elseif not quote and char == "#" and (index == 1 or value:sub(index - 1, index - 1):match("%s")) then
            return vim.trim(value:sub(1, index - 1))
        end
    end
    return value
end

local function scalar(value)
    value = strip_comment(vim.trim(value or ""))
    if value:sub(1, 1) == '"' then
        local ok, parsed = pcall(vim.json.decode, value)
        if ok and type(parsed) == "string" then return parsed end
    elseif value:sub(1, 1) == "'" and value:sub(-1) == "'" then
        return (value:sub(2, -2):gsub("''", "'"))
    end
    return value
end

-- Parse the intentionally small frontmatter format used by topics: scalar fields,
-- simple lists, and one-level maps (used by note source metadata).
local function parse_frontmatter(text)
    if type(text) ~= "string" or not text:match("^%-%-%-%s*\n") then return {}, text or "" end
    local lines = vim.split(text, "\n", { plain = true })
    local metadata, section, list_key = {}, nil, nil
    local closing
    for index = 2, #lines do
        local line = lines[index]
        if line:match("^%-%-%-%s*$") then closing = index; break end
        local key, value = line:match("^([%w_%-]+):%s*(.-)%s*$")
        if key then
            section, list_key = nil, nil
            if value == "" then
                metadata[key] = metadata[key] or {}
                section = key
                if key == "projects" then list_key = key end
            elseif value == "[]" then
                metadata[key] = {}
            elseif value == "true" then
                metadata[key] = true
            elseif value == "false" then
                metadata[key] = false
            else
                metadata[key] = scalar(value)
            end
        else
            local item = line:match("^%s+%-%s+(.+)%s*$")
            local nested_key, nested_value = line:match("^%s+([%w_%-]+):%s*(.-)%s*$")
            if item and list_key then
                metadata[list_key] = metadata[list_key] or {}
                table.insert(metadata[list_key], scalar(item))
            elseif nested_key and section then
                metadata[section][nested_key] = scalar(nested_value)
            end
        end
    end
    if not closing then return {}, text end
    return metadata, table.concat(lines, "\n", closing + 1)
end

local function yaml_scalar(value)
    return vim.json.encode(tostring(value or ""))
end

with_frontmatter = function(metadata, body)
    local lines = { "---" }
    for _, key in ipairs({ "title", "status", "created", "date", "consolidated" }) do
        local value = metadata[key]
        if value ~= nil then
            if type(value) == "boolean" then
                lines[#lines + 1] = key .. ": " .. tostring(value)
            else
                lines[#lines + 1] = key .. ": " .. yaml_scalar(value)
            end
        end
    end
    if type(metadata.projects) == "table" then
        lines[#lines + 1] = "projects:"
        for _, project in ipairs(metadata.projects) do lines[#lines + 1] = "  - " .. yaml_scalar(project) end
    end
    if type(metadata.source) == "table" then
        lines[#lines + 1] = "source:"
        for _, key in ipairs({ "harness", "session", "project" }) do
            if metadata.source[key] ~= nil then
                lines[#lines + 1] = "  " .. key .. ": " .. yaml_scalar(metadata.source[key])
            end
        end
    end
    lines[#lines + 1] = "---"
    lines[#lines + 1] = ""
    lines[#lines + 1] = body or ""
    return table.concat(lines, "\n")
end

local function topic_metadata(id)
    local path = topic_dir(id)
    if not path then return nil end
    local text = read(join(path, "topic.md"))
    if not text then return nil end
    local metadata, body = parse_frontmatter(text)
    metadata.id, metadata.description, metadata.dir = id, vim.trim(body), path
    metadata.projects = type(metadata.projects) == "table" and metadata.projects or {}
    metadata.title = type(metadata.title) == "string" and metadata.title ~= "" and metadata.title or id
    metadata.status = type(metadata.status) == "string" and metadata.status or "active"
    return metadata
end

local function project_matches(project, cwd)
    project = vim.fn.fnamemodify(vim.fn.expand(project), ":p"):gsub("/+$", "")
    cwd = vim.fn.fnamemodify(cwd, ":p"):gsub("/+$", "")
    return cwd == project or cwd:sub(1, #project + 1) == project .. "/"
end

local function note_files(id)
    local path = topic_dir(id)
    if not path then return {} end
    local files = vim.fn.globpath(join(path, "notes"), "*.md", false, true)
    table.sort(files)
    return files
end

local function pending_notes_path(id)
    local path = topic_dir(id)
    return path and join(path, "brief.proposed.notes.json") or nil
end

local function notes_for(id)
    local notes = {}
    for _, path in ipairs(note_files(id)) do
        local text = read(path) or ""
        local metadata, body = parse_frontmatter(text)
        local filename = vim.fn.fnamemodify(path, ":t:r")
        notes[#notes + 1] = {
            path = path,
            title = body:match("^%s*#%s+([^\n]+)") or text:match("\n#%s+([^\n]+)") or filename,
            date = metadata.date or filename:match("^(%d%d%d%d%-%d%d%-%d%d)") or "undated",
            source = metadata.source or {},
            consolidated = metadata.consolidated == true,
        }
    end
    return notes
end

local function slug(text)
    local title = (text or ""):match("^%s*#%s+([^\n]+)") or (text or ""):match("^([^\n]+)") or "note"
    title = title:lower():gsub("[^%w]+", "-"):gsub("^-+", ""):gsub("-+$", "")
    return title ~= "" and title:sub(1, 64) or "note"
end

function M.setup(opts)
    opts = opts or {}
    if type(opts.dir) == "string" and opts.dir ~= "" then
        directory = vim.fn.fnamemodify(vim.fn.expand(opts.dir), ":p"):gsub("/+$", "")
    end
    if type(opts.brief_max_lines) == "number" and opts.brief_max_lines > 0 then
        brief_limit = math.floor(opts.brief_max_lines)
    end
end

function M.directory()
    return directory
end

function M.brief_max_lines()
    return brief_limit
end

function M.list()
    local topics = {}
    local dirs = vim.fn.globpath(directory, "*", false, true)
    for _, path in ipairs(dirs) do
        local id = vim.fn.fnamemodify(path, ":t")
        local ok, metadata = pcall(function()
            local topic = topic_metadata(id)
            if not topic then return nil end
            local new_notes = 0
            for _, note in ipairs(notes_for(id)) do
                if not note.consolidated then new_notes = new_notes + 1 end
            end
            topic.new_notes = new_notes
            return topic
        end)
        if ok and metadata then
            topics[#topics + 1] = metadata
        end
    end
    table.sort(topics, function(a, b) return a.id < b.id end)
    return topics
end

function M.for_cwd(cwd, topics)
    local matching = {}
    for _, topic in ipairs(topics or M.list()) do
        for _, project in ipairs(topic.projects) do
            if project_matches(project, cwd) then
                topic.project_match = true
                matching[#matching + 1] = topic
                break
            end
        end
    end
    return matching
end

function M.get(id)
    return topic_metadata(id)
end

function M.create(id, opts)
    opts = opts or {}
    local path, err = topic_dir(id)
    if not path then return nil, err end
    if vim.fn.isdirectory(path) == 1 then return nil, "Topic already exists: " .. id end
    vim.fn.mkdir(join(path, "notes"), "p", 448)
    local title = opts.title or id:gsub("%-", " "):gsub("^%l", string.upper)
    local projects = opts.projects or { vim.fn.getcwd() }
    local frontmatter = with_frontmatter({
        title = title, status = opts.status or "active", created = os.date("%Y-%m-%d"), projects = projects,
    }, opts.description or "")
    vim.fn.writefile(vim.split(frontmatter, "\n", { plain = true }), join(path, "topic.md"))
    local brief = opts.brief or "# " .. title .. ": brief.\n\nUpdated " .. os.date("%B %d, %Y") .. ".\n\n"
        .. "## Goal and desired outcome.\n\n## Scope and non-goals.\n\n## Requirements and acceptance criteria.\n\n"
        .. "## Systems and responsibilities.\n\n## Current understanding.\n\n## Decisions made.\n\n"
        .. "## Open questions.\n\n## Where to look next.\n"
    vim.fn.writefile(vim.split(brief, "\n", { plain = true }), join(path, "brief.md"))
    return topic_metadata(id)
end

function M.attach(slot_index, id)
    return require("agent_dashboard").attach_topic(slot_index, id)
end

function M.attached(slot_index)
    return require("agent_dashboard").attached_topic(slot_index)
end

function M.brief_path(id)
    local path, err = topic_dir(id)
    if not path then return nil, err end
    if not topic_metadata(id) then return nil, "Topic not found: " .. id end
    return join(path, "brief.md")
end

function M.notes(id)
    if not topic_metadata(id) then return nil, "Topic not found: " .. tostring(id) end
    return notes_for(id)
end

function M.note(id, text, source)
    local path, err = topic_dir(id)
    if not path then return nil, err end
    if not topic_metadata(id) then return nil, "Topic not found: " .. id end
    if type(text) ~= "string" or vim.trim(text) == "" then return nil, "Note text is empty" end
    local date = os.date("%Y-%m-%d")
    local stem = date .. "-" .. slug(text)
    local candidate, suffix = join(path, "notes", stem .. ".md"), 1
    source = type(source) == "table" and source or {}
    local body = vim.trim(text)
    if not body:match("^#%s") then body = "# " .. slug(text):gsub("%-", " ") .. ".\n\n" .. body end
    local content = with_frontmatter({
        date = date, source = source, consolidated = false,
    }, body)
    local ok, write_err = write_new(candidate, content)
    while not ok and tostring(write_err):find("EEXIST", 1, true) do
        suffix = suffix + 1
        candidate = join(path, "notes", stem .. "-" .. suffix .. ".md")
        ok, write_err = write_new(candidate, content)
    end
    if not ok then return nil, write_err end
    return candidate
end

function M.accept_proposal(id)
    local path, err = topic_dir(id)
    if not path then return nil, err end
    if not topic_metadata(id) then return nil, "Topic not found: " .. id end
    local proposal, brief = join(path, "brief.proposed.md"), join(path, "brief.md")
    if vim.fn.filereadable(proposal) ~= 1 then return nil, "No brief.proposed.md exists for " .. id end
    -- Acceptance is explicit, but never replace a brief changed since proposal.
    local snapshot_path = join(path, "brief.proposed.base.sha256")
    local expected = read(snapshot_path)
    if expected and vim.fn.sha256(read(brief) or "") ~= expected then
        return nil, "brief.md changed since proposal; refusing to overwrite"
    end
    if vim.fn.filereadable(brief) == 1 then
        local original = read(brief)
        local suffix, saved, save_err = 0, nil, nil
        repeat
            suffix = suffix + 1
            local backup = join(path, "brief.capture-backup." .. tostring(os.time()) .. "-" .. suffix .. ".md")
            saved, save_err = write_new(backup, original)
        until saved or not tostring(save_err):find("EEXIST", 1, true)
        if not saved then return nil, "Could not preserve current brief: " .. tostring(save_err) end
    end
    if vim.fn.rename(proposal, brief) ~= 0 then return nil, "Could not replace brief.md" end
    vim.fn.delete(snapshot_path)
    local selected_notes = consolidation_notes[id]
    local snapshot = pending_notes_path(id)
    if not selected_notes and snapshot and vim.fn.filereadable(snapshot) == 1 then
        local ok, names = pcall(vim.json.decode, read(snapshot) or "")
        if ok and type(names) == "table" then
            selected_notes = {}
            for _, name in ipairs(names) do
                if type(name) == "string" then selected_notes[name] = true end
            end
        end
    end
    for _, note in ipairs(note_files(id)) do
        local basename = vim.fn.fnamemodify(note, ":t")
        local content = read(note)
        local metadata = parse_frontmatter(content)
        if metadata.consolidated ~= true and (not selected_notes or selected_notes[basename]) then
            local lines = vim.split(content, "\n", { plain = true })
            local closing, found
            if lines[1] == "---" then
                for index = 2, #lines do
                    if lines[index]:match("^%-%-%-%s*$") then closing = index; break end
                end
            end
            if closing then
                for index = 2, closing - 1 do
                    if lines[index]:match("^consolidated:") then
                        lines[index] = "consolidated: true"
                        found = true
                    end
                end
                if not found then table.insert(lines, closing, "consolidated: true") end
            else
                table.insert(lines, 1, "---")
                table.insert(lines, 1, "consolidated: true")
                table.insert(lines, 1, "---")
            end
            vim.fn.writefile(lines, note)
        end
    end
    consolidation_notes[id] = nil
    if snapshot then vim.fn.delete(snapshot) end
    return true, not selected_notes and "No proposal snapshot; all current notes were marked consolidated" or nil
end

function M.reject_proposal(id)
    local path, err = topic_dir(id)
    if not path then return nil, err end
    if not topic_metadata(id) then return nil, "Topic not found: " .. id end
    local proposal = join(path, "brief.proposed.md")
    if vim.fn.filereadable(proposal) ~= 1 then return nil, "No brief.proposed.md exists for " .. id end
    vim.fn.delete(proposal)
    vim.fn.delete(join(path, "brief.proposed.base.sha256"))
    consolidation_notes[id] = nil
    vim.fn.delete(pending_notes_path(id))
    return true
end

function M.propose_brief(id, text, base_hash, selected_notes)
    local path, err = topic_dir(id)
    if not path then return nil, err end
    if not topic_metadata(id) then return nil, "Topic not found: " .. tostring(id) end
    if type(text) ~= "string" or vim.trim(text) == "" then return nil, "Brief text is empty" end
    local proposal = join(path, "brief.proposed.md")
    if vim.fn.filereadable(proposal) == 1 then return nil, "A brief proposal is already pending" end
    local ok, write_err = write_new(proposal, text)
    if not ok then return nil, write_err end
    local snapshot = join(path, "brief.proposed.base.sha256")
    local snap_ok, snap_err = write_new(snapshot, base_hash or vim.fn.sha256(read(join(path, "brief.md")) or ""))
    if not snap_ok then vim.fn.delete(proposal); return nil, snap_err end
    local notes_path = pending_notes_path(id)
    local names = {}
    for name in pairs(selected_notes or {}) do names[#names + 1] = name end
    table.sort(names)
    local notes_ok, notes_err = write_new(notes_path, vim.json.encode(names))
    if not notes_ok then vim.fn.delete(proposal); vim.fn.delete(snapshot); return nil, notes_err end
    consolidation_notes[id] = selected_notes or {}
    return proposal
end

function M.begin_consolidation(id, opts)
    if not topic_metadata(id) then return nil, "Topic not found: " .. tostring(id) end
    local pending = {}
    if not opts or opts.notes ~= false then
        for _, note in ipairs(note_files(id)) do
            local metadata = parse_frontmatter(read(note) or "")
            if metadata.consolidated ~= true then pending[vim.fn.fnamemodify(note, ":t")] = true end
        end
    end
    consolidation_notes[id] = pending
    local names = vim.tbl_keys(pending)
    local path = pending_notes_path(id)
    if path then vim.fn.writefile({ vim.json.encode(names) }, path) end
    return names
end

function M.export_skill(id)
    local topic = topic_metadata(id)
    if not topic then return nil, "Topic not found: " .. tostring(id) end
    local path = vim.fn.expand("~/.claude/skills/topic-" .. id)
    local file = join(path, "SKILL.md")
    if vim.fn.filereadable(file) == 1
        and vim.fn.confirm("Replace existing topic skill " .. file .. "?", "&Yes\n&No", 2) ~= 1 then
        return nil, "Skill export cancelled"
    end
    vim.fn.mkdir(path, "p", 448)
    local description = topic.description:gsub("\n", " ")
    if description == "" then description = "Reference knowledge for " .. topic.title end
    local content = "---\nname: topic-" .. id .. "\ndescription: " .. yaml_scalar(description)
        .. "\n---\n\n# " .. topic.title .. "\n\nRead " .. join(topic.dir, "brief.md")
        .. " before working on this topic. Detailed notes are in " .. join(topic.dir, "notes") .. ".\n"
    vim.fn.writefile(vim.split(content, "\n", { plain = true }), file)
    return file
end

return M
