local M = {}

local option = "@nvim_agent_status"
local owner_option = "@nvim_agent_owner"
local suffix = "#{?#{" .. option .. "}, #{" .. option .. "},}"
local pane, window, owner, last_badge, desired_badge
local generation = 0
local setup_generation = 0

local function tmux(args, callback)
    local command = { "tmux" }
    vim.list_extend(command, args)
    vim.system(command, { text = true }, function(result)
        vim.schedule(function()
            callback(result.code == 0, (result.stdout or ""):gsub("%s+$", ""))
        end)
    end)
end

local function tmux_sync(args)
    local command = { "tmux" }
    vim.list_extend(command, args)
    local output = vim.fn.system(command)
    return vim.v.shell_error == 0, (output or ""):gsub("%s+$", "")
end

local function set_badge(target, badge, callback)
    if badge == "" then
        tmux({ "set-option", "-wu", "-t", target, option }, callback)
    else
        tmux({ "set-option", "-w", "-t", target, option, badge }, callback)
    end
end

local function install_formats(target, callback)
    local formats = { "window-status-format", "window-status-current-format" }
    local function install(index)
        local name = formats[index]
        if not name then callback(); return end
        tmux({ "show-options", "-gwv", name }, function(ok, format)
            if not ok or format:find(option, 1, true) then install(index + 1); return end
            tmux({ "set-option", "-gw", name, format .. suffix }, function()
                install(index + 1)
            end)
        end)
    end
    install(1)
end

local function current_window(callback)
    if not pane then callback(false); return end
    tmux({ "display-message", "-p", "-t", pane, "#{window_id}" }, function(ok, target)
        callback(ok and target:match("^@%d+$") and target or false)
    end)
end

local function publish_current(badge, request)
    current_window(function(target)
        if request ~= generation or not target then return end
        local previous = window
        local function publish_owned()
            tmux({ "show-options", "-wqv", "-t", target, owner_option }, function(ok, value)
                if not ok or value ~= owner or request ~= generation then return end
                set_badge(target, badge, function(success)
                    if success and request == generation then
                        window, last_badge = target, badge
                    end
                end)
            end)
        end
        if previous and previous ~= target then
            tmux({ "show-options", "-wqv", "-t", previous, owner_option }, function(ok, value)
                if ok and value == owner and request == generation then
                    set_badge(previous, "", function()
                        tmux({ "set-option", "-wu", "-t", previous, owner_option }, function()
                            if request ~= generation then return end
                            tmux({ "set-option", "-w", "-t", target, owner_option, owner }, function(success)
                                if success and request == generation then
                                    window = target
                                    set_badge(target, badge, function(published)
                                        if published and request == generation then last_badge = badge end
                                    end)
                                end
                            end)
                        end)
                    end)
                end
            end)
        else
            publish_owned()
        end
    end)
end

function M.setup(id)
    setup_generation = setup_generation + 1
    local setup_request = setup_generation
    pane = vim.env.TMUX_PANE
    owner = id
    desired_badge = ""
    last_badge = nil
    if not vim.env.TMUX or not pane or vim.fn.executable("tmux") == 0 then
        pane = nil
        return
    end
    generation = generation + 1
    current_window(function(target)
        if not target or setup_request ~= setup_generation then return end
        window = target
        install_formats(target, function()
            if setup_request ~= setup_generation then return end
            tmux({ "set-option", "-w", "-t", target, owner_option, owner }, function()
                if setup_request ~= setup_generation then return end
                set_badge(target, "", function()
                    if setup_request ~= setup_generation then return end
                    last_badge = ""
                    publish_current(desired_badge, generation)
                end)
            end)
        end)
    end)
end

function M.publish(badge)
    if not pane then return end
    desired_badge = badge
    if last_badge == badge then return end
    generation = generation + 1
    publish_current(badge, generation)
end

function M.teardown()
    setup_generation = setup_generation + 1
    generation = generation + 1
    local current_pane, current_window_id, current_owner = pane, window, owner
    pane, window, owner, last_badge = nil, nil, nil, nil
    if not current_pane then return end
    local targets, seen = {}, {}
    local ok, target = tmux_sync({ "display-message", "-p", "-t", current_pane, "#{window_id}" })
    if ok and target:match("^@%d+$") then
        targets[#targets + 1] = target
        seen[target] = true
    end
    if current_window_id and not seen[current_window_id] then
        targets[#targets + 1] = current_window_id
    end
    for _, window_id in ipairs(targets) do
        local found, value = tmux_sync({ "show-options", "-wqv", "-t", window_id, owner_option })
        if found and value == current_owner then
            tmux_sync({ "set-option", "-wu", "-t", window_id, option })
            tmux_sync({ "set-option", "-wu", "-t", window_id, owner_option })
        end
    end
end

return M
