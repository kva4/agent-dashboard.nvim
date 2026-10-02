# agent-dashboard.nvim

A floating Neovim dashboard for multiple agent terminals. The sidebar shows live
agent states and recent sessions for the current directory, merging OpenCode and
Claude Code by last activity. Resume a session in an unused terminal (or a new
slot if all are occupied), switch slots without stopping their jobs, and see an
optional status badge in tmux.

![agent-dashboard.nvim demo](assets/demo.gif)

*The agents in this recording are simulated. The dashboard, status reporting,
and session resume are the real plugin. See `assets/demo/`.*

## Why it exists

When several AI agents run at once, it's hard to tell which one needs you. One
is waiting for permission, one has finished, and one is still working.

This plugin was inspired by herdr. It brings a similar overview into Neovim, so
it fits workflows where tmux already manages windows and panes.

## Philosophy

- **Stay inside Neovim.** Agents run in Neovim terminals. Hiding the dashboard
  never stops a job.
- **Work alongside tmux.** tmux keeps managing windows and panes. The plugin
  only adds an optional status badge to your existing window format.
- **Use the agents' own tools.** Sessions come from what OpenCode and Claude
  Code already store, and resume with their own commands.
- **Keep the status contract small.** Any agent that writes one JSON file per
  terminal can report live status.
- **Make everything optional.** Reporters, tmux, and notifications are all
  optional. The plugin has no dependencies.
- **Stay out of your config.** The plugin creates no global shortcuts. Its
  terminal keys apply only inside agent terminals.
- **Focus on the current project.** Recent sessions come only from Neovim's
  current working directory.

## Requirements

- Neovim 0.10+
- `opencode` and/or `claude` on `PATH` to resume sessions
- `jq` for the bundled Claude Code reporter
- `tmux` for the optional badge

## Install with lazy.nvim

The repository is private, so ensure GitHub SSH access works first. A minimal
setup that keeps shortcuts under your control:

```lua
{
    "kva4/agent-dashboard.nvim",
    url = "git@github.com:kva4/agent-dashboard.nvim.git",
    lazy = false,
    config = function()
        local dashboard = require("agent_dashboard")
        dashboard.setup()
        vim.keymap.set("n", "<leader>ca", dashboard.toggle, { desc = "Agent dashboard" })
        for index = 1, 3 do
            vim.keymap.set("n", "<leader>c" .. index, function()
                dashboard.toggle_slot(index)
            end, { desc = "Agent terminal " .. index })
        end
    end,
}
```

`setup()` accepts optional values:

```lua
dashboard.setup({
    recent_limit = 5,
    height = 0.78, -- fraction of the available editor height
    tmux = true,
    notifications = { enabled = true, macos = false },
    -- claude_projects = vim.fn.expand("~/.claude/projects"),
    keys = {
        list = "<C-h>", next = "<M-j>", previous = "<M-k>",
        hide = "<C-q>", escape = "jk",
    },
})
```

The `keys` options are buffer-local in agent terminals. The plugin does not
create global shortcuts; configure those in your Neovim setup. It does not
depend on ToggleTerm.

## Dashboard controls

| Where | Keys | Action |
| --- | --- | --- |
| Agent terminal | `<C-h>` | Focus the sidebar |
| Agent terminal (normal mode) | `<Tab>` / `<C-w>h` | Focus the sidebar |
| Agent terminal | `<M-j>` / `<M-k>` | Next / previous slot (wraps) |
| Agent terminal | `<C-q>` | Hide dashboard without stopping agents |
| Sidebar | `j` / `k`, `<CR>` | Select and open a slot or recent session |
| Sidebar | `1`–`9` | Open a slot (or create the next one) |
| Sidebar | `<Tab>`, `<C-l>`, `l`, `<Right>`, `<C-w>l` | Return to the active terminal and enter terminal mode |
| Sidebar | `a`, `?` | Add a slot / show key help |
| Sidebar | `x` | Remove a terminal slot or delete a recent session (asks for confirmation) |
| Sidebar | `D` | Delete a recent session (asks for confirmation) |
| Sidebar | `y` | Copy the session ID of the row |
| Sidebar | `q` / `<Esc>` | Hide dashboard |

The dashboard starts with an unused shell. You can launch any agent yourself;
recent sessions appear in the sidebar and can be resumed with the matching CLI.
Slot names show session titles once known. A running session is opened in its
existing slot, rather than resumed a second time. Only sessions belonging to
Neovim's current working directory are shown. Recent sessions refresh when the
dashboard opens and every 30 seconds while visible.

The status symbols are `!` blocked, `●` working, `○` idle, `✓` unseen completed
turn, and `?` unknown. Status reports are optional; without one, the terminal
still works and shows `shell`.

Hidden slots notify with `vim.notify` when they become blocked or finish a turn.
Set `notifications = false` to disable notifications, or use
`notifications = { enabled = true, macos = true }` to also show a macOS banner.
`require("agent_dashboard").status()` returns the same badge used by tmux and can
be included in a statusline.

## Commands and editor context

`:AgentDashboard` toggles the dashboard. Subcommands include `open N`, `add`,
`send [selection|file|location]`, and `hooks`. The hooks command prints a
ready-to-paste Claude Code hooks object using the installed reporter path.

Send the last visual selection with `:AgentDashboard send` (or
`:AgentDashboard send selection`), the current file with `:AgentDashboard send file`,
or the current `@path:line` with `:AgentDashboard send location`. Visual-mode Lua
mappings can call `dashboard.send_context()` directly to send the active selection.
Prefix a range, such as `:10,20AgentDashboard send`, to send those lines. Context is
inserted into the selected running terminal using bracketed paste, preserving
multiline selections without submitting them automatically.

## Agent status reporting

Each dashboard terminal has `NVIM_AGENT_DASHBOARD_DIR` and `NVIM_AGENT_SLOT` in
its environment. A reporter writes JSON to
`$NVIM_AGENT_DASHBOARD_DIR/$NVIM_AGENT_SLOT.json` with
`{slot, time, session, turn, state, agent, pid?, heartbeat?}`. `state` is one of
`idle`, `working`, `blocked`, or `unknown`. Use `session: "none"` when the agent
is running with no session selected; the slot then shows as idle. The bundled integrations below are
optional for resuming sessions, but required for accurate live status and for
recognizing sessions started manually in an existing terminal.

### OpenCode

The TUI-specific reporter is in `extras/opencode/agent-dashboard-tui.js`.
Copy it to `~/.config/opencode/agent-dashboard-tui.js`, then add it to your
`~/.config/opencode/tui.jsonc` plugin array (preserving other plugins):

```jsonc
{
  "plugin": ["./agent-dashboard-tui.js"]
}
```

This is a TUI plugin: the selected session belongs to the terminal that owns
it. A server-wide plugin cannot reliably identify that terminal. Restart
OpenCode after changing its TUI plugin configuration.

### Claude Code

The hook reporter is in `extras/claude/agent-dashboard-report.sh`. Wire it into
`~/.claude/settings.json`; for example, if lazy.nvim installs the plugin under
`~/.local/share/nvim/lazy/agent-dashboard.nvim`:

```json
{
  "hooks": {
    "SessionStart": [{"hooks": [{"type": "command", "command": "bash $HOME/.local/share/nvim/lazy/agent-dashboard.nvim/extras/claude/agent-dashboard-report.sh start"}]}],
    "UserPromptSubmit": [{"hooks": [{"type": "command", "command": "bash $HOME/.local/share/nvim/lazy/agent-dashboard.nvim/extras/claude/agent-dashboard-report.sh working"}]}],
    "Stop": [{"hooks": [{"type": "command", "command": "bash $HOME/.local/share/nvim/lazy/agent-dashboard.nvim/extras/claude/agent-dashboard-report.sh idle"}]}],
    "Notification": [{"matcher": "permission_prompt", "hooks": [{"type": "command", "command": "bash $HOME/.local/share/nvim/lazy/agent-dashboard.nvim/extras/claude/agent-dashboard-report.sh blocked"}]}],
    "SessionEnd": [{"hooks": [{"type": "command", "command": "bash $HOME/.local/share/nvim/lazy/agent-dashboard.nvim/extras/claude/agent-dashboard-report.sh end"}]}]
  }
}
```

Add `PreToolUse` / `PostToolUse` with `working` if you want more precise live
status. Keep the `Notification` matcher set to `permission_prompt` so idle
notifications do not mark Claude as blocked. Preserve your existing
hooks and adjust the path when installing elsewhere. The script does nothing
outside a dashboard terminal. Restart Claude Code after changing its hooks.

## Check

```sh
nvim --headless -u NONE -i NONE -l tests/agent_dashboard.lua
node --check extras/opencode/agent-dashboard-tui.js
bash -n extras/claude/agent-dashboard-report.sh
```

Run `:checkhealth agent_dashboard` to verify `jq`, the agent CLIs, and reporter
configuration. See `doc/agent-dashboard.txt` for the full command and Lua API
reference.
