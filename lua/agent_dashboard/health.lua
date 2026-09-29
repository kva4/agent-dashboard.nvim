local M = {}

local function executable(name)
    if vim.fn.executable(name) == 1 then
        vim.health.ok(name .. " is on PATH")
    else
        vim.health.warn(name .. " is not on PATH")
    end
end

local function read(path)
    if vim.fn.filereadable(path) ~= 1 then return nil end
    return table.concat(vim.fn.readfile(path), "\n")
end

function M.check()
    vim.health.start("agent-dashboard.nvim")
    executable("jq")
    executable("claude")
    executable("opencode")

    local settings_path = vim.fn.expand("~/.claude/settings.json")
    local settings_text = read(settings_path)
    if not settings_text then
        vim.health.info("Claude Code settings not found at " .. settings_path)
    else
        local ok, settings = pcall(vim.json.decode, settings_text)
        if not ok or type(settings) ~= "table" then
            vim.health.warn("Could not parse " .. settings_path)
        else
            local hooks = settings.hooks or {}
            local reporter_found, notification_found, matcher_missing = false, false, false
            for name, entries in pairs(hooks) do
                if type(entries) == "table" then
                    for _, entry in ipairs(entries) do
                        if type(entry) == "table" then
                            for _, hook in ipairs(type(entry.hooks) == "table" and entry.hooks or {}) do
                                if type(hook) == "table" and type(hook.command) == "string"
                                    and hook.command:find("agent-dashboard-report.sh", 1, true) then
                                    reporter_found = true
                                    if name == "Notification" then
                                        notification_found = true
                                        if entry.matcher ~= "permission_prompt" then matcher_missing = true end
                                    end
                                end
                            end
                        end
                    end
                end
            end
            if reporter_found then
                vim.health.ok("Claude hooks reference agent-dashboard-report.sh")
            else
                vim.health.warn("Claude hooks do not reference agent-dashboard-report.sh; run :AgentDashboard hooks")
            end
            if notification_found and matcher_missing then
                vim.health.warn("Claude Notification hook needs matcher=permission_prompt to avoid false blocked status")
            elseif notification_found then
                vim.health.ok("Claude Notification hook is limited to permission_prompt")
            end
        end
    end

    local config_dir = vim.fn.expand("~/.config/opencode")
    local plugin_path = config_dir .. "/agent-dashboard-tui.js"
    local tui_config = read(config_dir .. "/tui.jsonc") or read(config_dir .. "/tui.json")
    if not tui_config then
        vim.health.warn("OpenCode TUI config not found under " .. config_dir)
    elseif not tui_config:find("agent-dashboard-tui.js", 1, true) then
        vim.health.warn("OpenCode TUI plugin is not configured in " .. config_dir)
    elseif vim.fn.filereadable(plugin_path) ~= 1 then
        vim.health.warn("OpenCode config references the reporter, but " .. plugin_path .. " is missing")
    else
        vim.health.ok("OpenCode TUI reporter is configured")
    end
end

return M
