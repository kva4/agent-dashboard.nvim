local M = {}

local option = "@nvim_agent_status"
local owner_option = "@nvim_agent_owner"
local suffix = "#{?#{" .. option .. "}, #{" .. option .. "},}"
local window, owner, last_badge

local function tmux(args)
    local command = { "tmux" }
    vim.list_extend(command, args)
    local output = vim.fn.system(command)
    return vim.v.shell_error == 0, (output:gsub("%s+$", ""))
end

local function owned()
    local ok, value = tmux({ "show-options", "-wqv", "-t", window, owner_option })
    return ok and value == owner
end

function M.setup(id)
    local pane = vim.env.TMUX_PANE
    if not vim.env.TMUX or not pane or vim.fn.executable("tmux") == 0 then return end
    local ok, target = tmux({ "display-message", "-p", "-t", pane, "#{window_id}" })
    if not ok or not target:match("^@%d+$") then return end
    window, owner = target, id

    -- Preserve the user's existing tmux formats and add one conditional badge.
    for _, name in ipairs({ "window-status-format", "window-status-current-format" }) do
        local found, format = tmux({ "show-options", "-gwv", name })
        if found and not format:find(option, 1, true) then
            tmux({ "set-option", "-gw", name, format .. suffix })
        end
    end

    tmux({ "set-option", "-w", "-t", window, owner_option, owner })
    tmux({ "set-option", "-wu", "-t", window, option })
    last_badge = ""
end

function M.publish(badge)
    if not window or last_badge == badge or not owned() then return end
    local ok
    if badge == "" then
        ok = tmux({ "set-option", "-wu", "-t", window, option })
    else
        ok = tmux({ "set-option", "-w", "-t", window, option, badge })
    end
    if ok then last_badge = badge end
end

function M.teardown()
    if window and owned() then
        tmux({ "set-option", "-wu", "-t", window, option })
        tmux({ "set-option", "-wu", "-t", window, owner_option })
    end
    window = nil
end

return M
