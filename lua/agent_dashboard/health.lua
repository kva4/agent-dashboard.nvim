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
    -- V2's global CLI config takes precedence over legacy TUI configuration.
    local cli_config = read(config_dir .. "/cli.json")
    local tui_config = cli_config or read(config_dir .. "/tui.jsonc") or read(config_dir .. "/tui.json")
    local cli_reporter
    if cli_config then
        local ok, decoded = pcall(vim.json.decode, cli_config)
        for _, entry in ipairs(ok and type(decoded) == "table" and decoded.plugins or {}) do
            local target = type(entry) == "table" and entry.package or entry
            if type(target) == "string" and target:sub(1, 1) ~= "-" then
                target = target:gsub("^file://", "")
                if target:sub(1, 1) ~= "/" then target = config_dir .. "/" .. target end
                local entrypoint = read(target .. "/tui.js")
                if entrypoint and entrypoint:find("agent-dashboard-tui.js", 1, true)
                    and vim.fn.filereadable(target .. "/agent-dashboard-tui.js") == 1 then
                    cli_reporter = true
                end
            end
        end
    end
    if not tui_config then
        vim.health.warn("OpenCode TUI config not found under " .. config_dir)
    elseif cli_config then
        if cli_reporter then
            vim.health.ok("OpenCode TUI reporter is configured")
        else
            vim.health.warn("OpenCode v2 reporter is not configured: cli.json plugins must reference the extras/opencode directory, not agent-dashboard-tui.js")
        end
    elseif not tui_config:find("agent-dashboard-tui.js", 1, true) then
        vim.health.warn("OpenCode TUI plugin is not configured in " .. config_dir .. " (use cli.json plugins for OpenCode v2)")
    elseif vim.fn.filereadable(plugin_path) ~= 1 then
        vim.health.warn("OpenCode config references the reporter, but " .. plugin_path .. " is missing")
    else
        vim.health.ok("OpenCode TUI reporter is configured")
    end
end

return M
