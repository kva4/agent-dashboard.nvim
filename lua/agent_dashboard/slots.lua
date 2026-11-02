-- Remembers which agent sessions were open so they can be resumed after nvim
-- restarts. One JSON file per key (an nvim session file or a cwd).
local M = {}
local dir
local written = {}

local id_patterns = {
    claude = "^[%x]+%-%x+%-%x+%-%x+%-%x+$",
    opencode = "^ses_[%w]+$",
}

local function file_for(key)
    return dir .. "/" .. vim.fn.sha256(key) .. ".json"
end

function M.valid(entry)
    local pattern = type(entry) == "table" and id_patterns[entry.agent]
    return pattern and type(entry.session) == "string" and entry.session:match(pattern) ~= nil or false
end

function M.setup(path)
    dir = path
    written = {}
end

-- Replaces the saved slots for `key`. An empty list removes the file.
function M.save(key, entries)
    if not dir then return end
    local encoded = vim.json.encode({ key = key, slots = entries })
    if written[key] == encoded then return end
    local path = file_for(key)
    if #entries == 0 then
        vim.fn.delete(path)
    else
        vim.fn.mkdir(dir, "p", 448)
        local temporary = path .. ".tmp"
        vim.fn.writefile({ encoded }, temporary)
        if vim.fn.rename(temporary, path) ~= 0 then return end
    end
    written[key] = encoded
end

function M.load(key)
    if not dir then return {} end
    local path = file_for(key)
    if vim.fn.filereadable(path) ~= 1 then return {} end
    local ok, data = pcall(function()
        return vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
    end)
    if not ok or type(data) ~= "table" or data.key ~= key or type(data.slots) ~= "table" then return {} end
    local entries = {}
    for _, entry in ipairs(data.slots) do
        if M.valid(entry) then entries[#entries + 1] = entry end
    end
    return entries
end

return M
