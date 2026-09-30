vim.opt.runtimepath:prepend(vim.fn.getcwd())
package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path

local source = require("agent_dashboard.sessions")
local cwd = vim.fn.tempname()
local root = cwd .. "/.claude/projects"
local dir = root .. "/" .. cwd:gsub("[^%w%-]", "-")
local uuid = "12345678-1234-1234-1234-123456789abc"
local other_uuid = "12345678-1234-1234-1234-123456789abd"
vim.fn.mkdir(dir, "p")
vim.fn.writefile({ "{}" }, dir .. "/" .. uuid .. ".jsonl")
vim.fn.writefile({ vim.json.encode({ type = "user", message = { content = "Recovered first prompt" } }) },
    dir .. "/" .. other_uuid .. ".jsonl")
vim.fn.writefile({ vim.json.encode({ originalPath = cwd, entries = {
    { sessionId = uuid, firstPrompt = "Claude conversation", projectPath = cwd },
} }) }, dir .. "/sessions-index.json")

local expand, executable, jobstart = vim.fn.expand, vim.fn.executable, vim.fn.jobstart
vim.fn.expand = function(path)
    if path == "~/.claude/projects" then return root end
    return expand(path)
end
vim.fn.executable = function(name)
    if name == "opencode" then return 1 end
    return executable(name)
end
vim.fn.jobstart = function(args, opts)
    assert(vim.deep_equal(vim.list_slice(args, 1, 6), { "opencode", "session", "list", "--format", "json", "--max-count" }))
    assert(args[7] == "10" or args[7] == "20")
    local request_cwd = opts.cwd
    vim.schedule(function()
        local entries = request_cwd == cwd and {
            { id = "ses_recent", title = "OpenCode conversation", updated = os.time() * 1000 + 1000, directory = cwd },
            { id = "ses_elsewhere", updated = os.time() * 1000 + 2000, directory = "/elsewhere" },
        } or {}
        opts.on_stdout(1, { vim.json.encode(entries) })
        opts.on_exit(1, 0)
    end)
    return 1
end

local result
source.refresh(cwd, function(sessions) result = sessions end)
assert(vim.wait(1000, function() return result ~= nil end))
assert(#result == 3)
assert(result[1].harness == "opencode" and result[1].id == "ses_recent")
local claude = {}
for _, session in ipairs(result) do if session.harness == "claude" then claude[session.id] = session end end
assert(claude[uuid].title == "Claude conversation")
assert(claude[other_uuid].title == "Recovered first prompt")

local titled_uuid = "22345678-1234-1234-1234-123456789abc"
vim.fn.writefile({
    vim.json.encode({ type = "user", message = { content = "<command-name>/model</command-name>" } }),
    vim.json.encode({ type = "custom-title", customTitle = "Earlier custom title" }),
    vim.json.encode({ type = "assistant", filler = string.rep("x", 33000) }),
    vim.json.encode({ type = "ai-title", aiTitle = "Later AI title" }),
    vim.json.encode({ type = "custom-title", customTitle = "Latest custom title" }),
}, dir .. "/" .. titled_uuid .. ".jsonl")
local titled
source.refresh(cwd, function(sessions) titled = sessions end)
assert(vim.wait(1000, function() return titled ~= nil end))
local title_by_id = {}
for _, session in ipairs(titled) do title_by_id[session.id] = session.title end
assert(title_by_id[titled_uuid] == "Latest custom title")

local fallback_cwd = cwd .. "/alternate"
local fallback_dir = root .. "/noncanonical-project-name"
local fallback_uuid = "32345678-1234-1234-1234-123456789abc"
vim.fn.mkdir(root .. "/" .. fallback_cwd:gsub("[^%w%-]", "-"), "p")
vim.fn.mkdir(fallback_dir, "p")
vim.fn.writefile({ vim.json.encode({ cwd = fallback_cwd, type = "user",
    message = { content = "Found via the session cwd" } }) }, fallback_dir .. "/" .. fallback_uuid .. ".jsonl")
local fallback
source.refresh(fallback_cwd, function(sessions) fallback = sessions end)
assert(vim.wait(1000, function() return fallback ~= nil end))
local found_fallback = false
for _, session in ipairs(fallback) do
    if session.id == fallback_uuid then
        found_fallback = session.title == "Found via the session cwd"
    end
end
assert(found_fallback)

local no_sessions_cwd = cwd .. "/no-claude-sessions"
local no_sessions_dir = root .. "/" .. no_sessions_cwd:gsub("[^%w%-]", "-")
vim.fn.mkdir(no_sessions_dir, "p")
local fs_scandir, scan_count = vim.uv.fs_scandir, 0
vim.uv.fs_scandir = function(...)
    scan_count = scan_count + 1
    return fs_scandir(...)
end
local no_sessions
source.refresh(no_sessions_cwd, function(sessions) no_sessions = sessions end, { claude_projects = root })
assert(vim.wait(1000, function() return no_sessions ~= nil end))
local scans_after_miss = scan_count
assert(scans_after_miss > 0)
no_sessions = nil
source.refresh(no_sessions_cwd, function(sessions) no_sessions = sessions end, { claude_projects = root })
assert(vim.wait(1000, function() return no_sessions ~= nil end))
assert(scan_count == scans_after_miss) -- Negative directory lookups are cached.
local newly_created_uuid = "42345678-1234-1234-1234-123456789abc"
vim.fn.writefile({ vim.json.encode({ cwd = no_sessions_cwd, type = "user",
    message = { content = "Session appeared after a cached miss" } }) }, no_sessions_dir .. "/" .. newly_created_uuid .. ".jsonl")
no_sessions = nil
source.refresh(no_sessions_cwd, function(sessions) no_sessions = sessions end, { claude_projects = root })
assert(vim.wait(1000, function() return no_sessions ~= nil end))
local invalidated_cache = false
for _, session in ipairs(no_sessions) do
    if session.id == newly_created_uuid then invalidated_cache = true end
end
assert(invalidated_cache) -- A project-directory mtime change invalidates a cached miss.
vim.uv.fs_scandir = fs_scandir

local limited
source.refresh(cwd, function(sessions) limited = sessions end, { recent_limit = 1, claude_projects = root })
assert(vim.wait(1000, function() return limited ~= nil end))
assert(#limited == 1 and limited[1].id == "ses_recent")

-- Deleting a Claude session removes its transcript and companion folder, and rejects bad ids.
vim.fn.mkdir(dir .. "/" .. other_uuid, "p")
vim.fn.writefile({ "{}" }, dir .. "/" .. other_uuid .. "/tool-result.txt")
local deleted, delete_error
source.delete({ harness = "claude", id = other_uuid }, cwd, function(ok, err) deleted, delete_error = ok, err end,
    { claude_projects = root })
assert(deleted == true and delete_error == nil)
assert(vim.fn.filereadable(dir .. "/" .. other_uuid .. ".jsonl") == 0)
assert(vim.fn.isdirectory(dir .. "/" .. other_uuid) == 0)
assert(vim.fn.filereadable(dir .. "/" .. uuid .. ".jsonl") == 1)
source.delete({ harness = "claude", id = "../evil" }, cwd, function(ok) deleted = ok end, { claude_projects = root })
assert(deleted == false)

-- Deleting an OpenCode session shells out to the CLI and reports its failure.
local outer_jobstart = vim.fn.jobstart
local delete_args
vim.fn.jobstart = function(args, opts)
    delete_args = args
    vim.schedule(function() opts.on_stderr(1, { "boom" }); opts.on_exit(1, 1) end)
    return 1
end
deleted = nil
source.delete({ harness = "opencode", id = "ses_recent" }, cwd, function(ok, err) deleted, delete_error = ok, err end)
assert(vim.wait(1000, function() return deleted ~= nil end))
assert(vim.deep_equal(delete_args, { "opencode", "session", "delete", "ses_recent" }))
assert(deleted == false and delete_error == "boom")
vim.fn.jobstart = outer_jobstart

if vim.fn.executable("jq") == 1 then
    local report_dir = cwd .. "/reporter"
    vim.fn.mkdir(report_dir, "p")
    local previous_dir, previous_slot = vim.env.NVIM_AGENT_DASHBOARD_DIR, vim.env.NVIM_AGENT_SLOT
    vim.env.NVIM_AGENT_DASHBOARD_DIR, vim.env.NVIM_AGENT_SLOT = report_dir, "777"
    local reporter = vim.fn.getcwd() .. "/extras/claude/agent-dashboard-report.sh"
    local payload = vim.json.encode({ session_id = "report-session", source = "startup" })
    vim.fn.system({ "bash", reporter, "start" }, payload)
    assert(vim.v.shell_error == 0)
    local report_path = report_dir .. "/777.json"
    local report = vim.json.decode(table.concat(vim.fn.readfile(report_path), "\n"))
    assert(report.state == "idle" and report.turn == 0 and report.session == "report-session")
    vim.fn.writefile({ "4" }, report_dir .. "/777.turn")
    vim.fn.system({ "bash", reporter, "start" }, vim.json.encode({
        session_id = "report-session", source = "compact",
    }))
    assert(vim.v.shell_error == 0)
    report = vim.json.decode(table.concat(vim.fn.readfile(report_path), "\n"))
    assert(report.turn == 4)
    vim.fn.system({ "bash", reporter, "unknown" }, payload)
    assert(vim.v.shell_error ~= 0)
    vim.env.NVIM_AGENT_DASHBOARD_DIR, vim.env.NVIM_AGENT_SLOT = previous_dir, previous_slot
end
vim.fn.expand, vim.fn.executable, vim.fn.jobstart = expand, executable, jobstart
vim.fn.delete(cwd, "rf")

local health_root = vim.fn.tempname()
local claude_config_dir, opencode_config_dir = health_root .. "/claude", health_root .. "/opencode"
vim.fn.mkdir(claude_config_dir, "p")
vim.fn.mkdir(opencode_config_dir, "p")
vim.fn.writefile({ vim.json.encode({ hooks = { Notification = { { hooks = {
    { type = "command", command = "bash /plugin/agent-dashboard-report.sh blocked" },
} } } } }) }, claude_config_dir .. "/settings.json")
vim.fn.writefile({ '{ "plugin": ["./agent-dashboard-tui.js"] }' }, opencode_config_dir .. "/tui.json")
vim.fn.writefile({ "export default {};" }, opencode_config_dir .. "/agent-dashboard-tui.js")
local expand = vim.fn.expand
vim.fn.expand = function(path)
    if path == "~/.claude/settings.json" then return claude_config_dir .. "/settings.json" end
    if path == "~/.config/opencode" then return opencode_config_dir end
    return expand(path)
end
local health_win, original_buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
vim.cmd("checkhealth agent_dashboard")
local function health_output()
    return table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
end
local report = ""
assert(vim.wait(5000, function()
    report = health_output()
    return report:find("permission_prompt", 1, true)
        and report:find("OpenCode TUI reporter is configured", 1, true)
end), report)
assert(not report:find('No healthcheck found for "agent_dashboard"', 1, true))
for _, win in ipairs(vim.api.nvim_list_wins()) do
    if win ~= health_win then vim.api.nvim_win_close(win, true) end
end
vim.api.nvim_set_current_win(health_win)
vim.api.nvim_set_current_buf(original_buf)
vim.fn.expand = expand
vim.fn.delete(health_root, "rf")

local recent_sessions = {
    { harness = "opencode", id = "ses_recent", title = "OpenCode conversation" },
    { harness = "claude", id = uuid, title = "Claude conversation" },
    { harness = "opencode", id = "ses_another", title = "Another conversation" },
}
package.loaded["agent_dashboard.sessions"] = {
    refresh = function(_, callback) callback(recent_sessions) end,
}
local dashboard = require("agent_dashboard")
dashboard.setup({ tmux = false, topics = false, keys = { next = "<M-n>" } })
local original_executable = vim.fn.executable
vim.fn.executable = function(name)
    if name == "claude" or name == "opencode" then return 1 end
    return original_executable(name)
end
local has_version, termopen = vim.fn.has, vim.fn.termopen
local fallback_terminal_called = false
vim.fn.has = function(feature)
    if feature == "nvim-0.11" then return 0 end
    return has_version(feature)
end
vim.fn.termopen = function(...)
    fallback_terminal_called = true
    return termopen(...)
end
dashboard.toggle()
assert(fallback_terminal_called) -- Exercise the Neovim 0.10 terminal shim on every CI version.
vim.fn.has, vim.fn.termopen = has_version, termopen
assert(vim.fn.exists(":AgentDashboard") == 2)
assert(type(dashboard.status()) == "string")
local hook_config = vim.json.decode(dashboard.hooks())
assert(hook_config.hooks.Notification[1].matcher == "permission_prompt")
assert(hook_config.hooks.SessionStart[1].hooks[1].command:find("agent-dashboard-report.sh", 1, true))
local first_buf = vim.api.nvim_get_current_buf()
local state_dirs = vim.fn.glob(vim.fn.stdpath("state") .. "/agent-dashboard/" .. vim.fn.getpid() .. "-*", false, true)
assert(#state_dirs > 0)
local report_path = state_dirs[1] .. "/101.json"
local get_proc, jobpid = vim.api.nvim_get_proc, vim.fn.jobpid
local report_pid = vim.fn.getpid()
local shim_pid, shell_pid, owns_shell = 888801, 888802, true
vim.fn.jobpid = function() return shell_pid end
vim.api.nvim_get_proc = function(pid)
    if pid == report_pid then return { pid = pid, ppid = owns_shell and shim_pid or 888800 } end
    if pid == shim_pid then return { pid = pid, ppid = shell_pid } end
    return { pid = pid, ppid = 1 }
end
local function write_status(state, pid, turn, session, expected, heartbeat)
    vim.fn.writefile({ vim.json.encode({
        slot = 101, time = os.time() - 11, session = session or "stale-claude", turn = turn or 0,
        state = state, agent = "claude", pid = pid, heartbeat = heartbeat,
    }) }, report_path)
    local symbols = { idle = "○", blocked = "!", unknown = "?" }
    assert(vim.wait(1600, function() return dashboard.status() == (expected or symbols[state]) end))
end
write_status("idle", nil) -- Hook reporters stay valid after Stop, regardless of report age.
dashboard.focus_list()
write_status("idle", nil, 1, nil, "✓") -- A newly completed, unseen turn gets the done badge.
assert(dashboard.status() == "✓")
dashboard.toggle_slot(1)
assert(dashboard.status() == "○") -- Opening the slot marks that completion as seen.
write_status("idle", 99999999, 1, nil, "") -- A dead reporter returns the terminal to shell.
assert(vim.fn.filereadable(report_path) == 0)
owns_shell = false
vim.fn.writefile({ vim.json.encode({
    slot = 101, time = os.time(), session = "unowned", turn = 0,
    state = "blocked", agent = "claude", pid = report_pid,
}) }, report_path)
assert(not vim.wait(1300, function() return dashboard.status() == "!" end))
vim.fn.delete(report_path)
owns_shell = true
write_status("blocked", report_pid)
write_status("unknown", report_pid, 0, "none", "○") -- An agent with no session selected is idle.
write_status("working", report_pid, 1, "heartbeat-session", "?", true)
write_status("idle", vim.fn.getpid(), 0, "new-session") -- New sessions reset their turn state.
assert(dashboard.status() == "○")
vim.fn.delete(report_path)
assert(vim.wait(1600, function() return dashboard.status() == "" end))
vim.api.nvim_get_proc, vim.fn.jobpid = get_proc, jobpid
dashboard.focus_list()
local buf = vim.api.nvim_get_current_buf()
local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
assert(lines[6]:find("OC OpenCode", 1, true))
assert(lines[7]:find("CC Claude", 1, true))

local sent
local sent_context
local chan_send = vim.api.nvim_chan_send
vim.api.nvim_chan_send = function(job, text)
    if text:find("opencode --session", 1, true) or text:find("claude --resume", 1, true) then
        sent = text
        return
    end
    if text:find("\27[200~", 1, true) then
        sent_context = text
        return
    end
    return chan_send(job, text)
end
vim.api.nvim_win_set_cursor(0, { 6, 0 })
vim.api.nvim_feedkeys("x", "xt", false)
assert(vim.api.nvim_buf_get_lines(buf, 2, 3, false)[1]:find("1 terminal", 1, true))
vim.api.nvim_feedkeys("y", "xt", false)
assert(vim.fn.getreg('"') == "ses_recent")
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "xt", false)
assert(vim.wait(1000, function() return sent ~= nil end))
assert(sent == "opencode --session 'ses_recent'\n")
assert(vim.api.nvim_get_current_buf() == first_buf)
dashboard.focus_list()
assert(vim.api.nvim_buf_get_lines(buf, 2, 3, false)[1]:find("1 OpenCode", 1, true))
dashboard.toggle_slot(2)
local second_buf = vim.api.nvim_get_current_buf()
dashboard.focus_list()
assert(vim.api.nvim_buf_get_lines(buf, 3, 4, false)[1]:find("2 terminal", 1, true))
vim.api.nvim_feedkeys("jj", "xt", false)
assert(vim.api.nvim_win_get_cursor(0)[1] == 8)
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "xt", false)
assert(sent == "claude --resume '" .. uuid .. "'\n")
assert(vim.api.nvim_get_current_buf() == second_buf)
dashboard.focus_list()
assert(vim.api.nvim_buf_get_lines(buf, 3, 4, false)[1]:find("2 Claude", 1, true))
vim.api.nvim_win_set_cursor(0, { 9, 0 })
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "xt", false)
assert(sent == "opencode --session 'ses_another'\n")
local third_buf = vim.api.nvim_get_current_buf()
assert(third_buf ~= first_buf and third_buf ~= second_buf)
assert(vim.inspect(vim.api.nvim_win_get_config(0).title):find("Another conversation", 1, true))
recent_sessions = {}
dashboard.toggle()
dashboard.toggle()
dashboard.focus_list()
local active_lines = vim.api.nvim_buf_get_lines(buf, 2, 5, false)
assert(active_lines[1]:find("1 OpenCode", 1, true))
assert(active_lines[2]:find("2 Claude", 1, true))
assert(active_lines[3]:find("3 Another", 1, true))
dashboard.toggle_slot(3)
local mappings = vim.api.nvim_buf_get_keymap(third_buf, "t")
local has_cycle_mapping, has_default_list, has_default_escape = false, false, false
for _, map in ipairs(mappings) do
    if map.lhs == "<M-n>" then has_cycle_mapping = true end
    if map.lhs == "<C-H>" then has_default_list = true end
    if map.lhs == "jk" then has_default_escape = true end
end
assert(has_cycle_mapping and has_default_list and has_default_escape,
    vim.inspect(vim.tbl_map(function(map) return map.lhs end, mappings)))
dashboard.cycle_slot(-1)
assert(vim.api.nvim_get_current_buf() == second_buf)
dashboard.cycle_slot(1)
assert(vim.api.nvim_get_current_buf() == third_buf)
dashboard.cycle_slot(1)
assert(vim.api.nvim_get_current_buf() == first_buf)
local context_notify, context_notifications = vim.notify, {}
vim.notify = function(message) context_notifications[#context_notifications + 1] = message end
vim.api.nvim_buf_set_name(first_buf, "/tmp/agent-dashboard-context.lua")
assert(dashboard.send_context("file"))
assert(sent_context == "\27[200~@" .. vim.fn.fnamemodify(vim.api.nvim_buf_get_name(first_buf), ":.")
    .. " \27[201~")
dashboard.toggle()
vim.cmd("enew")
vim.cmd("stopinsert")
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "hello world", "second line" })
vim.api.nvim_buf_set_name(0, "/tmp/agent-dashboard-selection.lua")
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("0v4l", true, false, true), "xt", false)
assert(dashboard.send_context("selection"))
assert(sent_context == "\27[200~hello\27[201~")
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "xt", false)
vim.cmd("2,2AgentDashboard send selection")
assert(sent_context == "\27[200~second line\27[201~")
vim.api.nvim_win_set_cursor(0, { 2, 0 })
assert(dashboard.send_context("location"))
assert(sent_context == "\27[200~@" .. vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":.")
    .. ":2 \27[201~")
assert(context_notifications[1] == "Sent context to agent slot 1")
vim.notify = context_notify
local notify, notifications = vim.notify, {}
vim.notify = function(message)
    notifications[#notifications + 1] = message
end
local hidden_get_proc, hidden_jobpid = vim.api.nvim_get_proc, vim.fn.jobpid
vim.fn.jobpid = function() return shell_pid end
vim.api.nvim_get_proc = function(pid)
    if pid == report_pid then return { pid = pid, ppid = shim_pid } end
    if pid == shim_pid then return { pid = pid, ppid = shell_pid } end
    return { pid = pid, ppid = 1 }
end
local hidden_report = state_dirs[1] .. "/102.json"
vim.fn.writefile({ vim.json.encode({
    slot = 102, time = os.time(), session = "hidden-session", turn = 0,
    state = "blocked", agent = "claude", pid = vim.fn.getpid(),
}) }, hidden_report)
assert(vim.wait(1600, function() return #notifications > 0 end))
assert(notifications[1] == "Claude is waiting for permission")
vim.fn.delete(hidden_report)
assert(vim.wait(1600, function() return dashboard.status() == "" end))
vim.notify = notify
vim.api.nvim_get_proc, vim.fn.jobpid = hidden_get_proc, hidden_jobpid
vim.fn.executable = original_executable
vim.api.nvim_chan_send = chan_send

local tmux_root = vim.fn.tempname()
local tmux_bin = tmux_root .. "/bin"
vim.fn.mkdir(tmux_bin, "p")
local fake_tmux = tmux_bin .. "/tmux"
local tmux_log = tmux_root .. "/calls.log"
local owner_file, badge_file = tmux_root .. "/owner", tmux_root .. "/badge"
vim.fn.writefile({
    "#!/bin/sh",
    'printf "%s\\n" "$*" >> "$TMUX_TEST_LOG"',
    'if [ "$1" = "display-message" ]; then printf "@42\\n"; exit 0; fi',
    'if [ "$1" = "show-options" ]; then',
    '  case " $* " in',
    '    *" window-status-format "*|*" window-status-current-format "*) printf "#I #W\\n" ;;',
    '    *" @nvim_agent_owner "*) [ -f "$TMUX_TEST_OWNER" ] && cat "$TMUX_TEST_OWNER" ;;',
    '    *" @nvim_agent_status "*) [ -f "$TMUX_TEST_BADGE" ] && cat "$TMUX_TEST_BADGE" ;;',
    "  esac",
    "  exit 0",
    "fi",
    'if [ "$1" = "set-option" ]; then',
    '  option=""; value=""; waiting=0',
    '  for arg in "$@"; do',
    '    if [ "$arg" = "@nvim_agent_owner" ] || [ "$arg" = "@nvim_agent_status" ]; then option="$arg"; waiting=1; continue; fi',
    '    if [ "$waiting" = "1" ]; then value="$arg"; waiting=2; fi',
    "  done",
    '  if [ "$option" = "@nvim_agent_owner" ]; then file="$TMUX_TEST_OWNER"; else file="$TMUX_TEST_BADGE"; fi',
    '  if [ -n "$value" ]; then printf "%s\\n" "$value" > "$file"; else rm -f "$file"; fi',
    "fi",
}, fake_tmux)
vim.fn.system({ "chmod", "+x", fake_tmux })
local tmux_env, pane_env, path_env = vim.env.TMUX, vim.env.TMUX_PANE, vim.env.PATH
vim.env.TMUX, vim.env.TMUX_PANE = "fake-tmux", "%1"
vim.env.PATH = tmux_bin .. ":" .. path_env
vim.env.TMUX_TEST_LOG, vim.env.TMUX_TEST_OWNER, vim.env.TMUX_TEST_BADGE = tmux_log, owner_file, badge_file
local first_tmux = assert(loadfile(vim.fn.getcwd() .. "/lua/agent_dashboard/tmux.lua"))()
local second_tmux = assert(loadfile(vim.fn.getcwd() .. "/lua/agent_dashboard/tmux.lua"))()
first_tmux.setup("owner-one")
first_tmux.publish("!")
assert(vim.wait(3000, function()
    return vim.fn.filereadable(badge_file) == 1
        and table.concat(vim.fn.readfile(badge_file), "") == "!"
end))
second_tmux.setup("owner-two")
assert(vim.wait(3000, function()
    return vim.fn.filereadable(owner_file) == 1
        and table.concat(vim.fn.readfile(owner_file), "") == "owner-two"
        and vim.fn.filereadable(badge_file) == 0
end))
first_tmux.publish("!")
vim.wait(200)
assert(table.concat(vim.fn.readfile(owner_file), "") == "owner-two")
assert(vim.fn.filereadable(badge_file) == 0) -- A non-owner cannot publish.
second_tmux.publish("○")
assert(vim.wait(2000, function()
    return vim.fn.filereadable(badge_file) == 1
        and table.concat(vim.fn.readfile(badge_file), "") == "○"
end))
first_tmux.teardown()
assert(table.concat(vim.fn.readfile(owner_file), "") == "owner-two") -- Non-owner cleanup is ignored.
second_tmux.teardown()
assert(vim.fn.filereadable(owner_file) == 0 and vim.fn.filereadable(badge_file) == 0)
local tmux_calls = table.concat(vim.fn.readfile(tmux_log), "\n")
assert(tmux_calls:find("set%-option %-wu %-t @42 @nvim_agent_status"))
assert(tmux_calls:find("set%-option %-wu %-t @42 @nvim_agent_owner"))
vim.env.TMUX, vim.env.TMUX_PANE, vim.env.PATH = tmux_env, pane_env, path_env
vim.env.TMUX_TEST_LOG, vim.env.TMUX_TEST_OWNER, vim.env.TMUX_TEST_BADGE = nil, nil, nil
vim.fn.delete(tmux_root, "rf")
vim.cmd("qa!")
