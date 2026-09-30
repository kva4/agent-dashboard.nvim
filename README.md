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
    recent_limit = 10,
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
| Agent terminal | `<M-j>` / `<M-k>` | Next / previous slot (wraps) |
| Agent terminal | `<C-q>` | Hide dashboard without stopping agents |
| Sidebar | `j` / `k`, `<CR>` | Select and open a slot or recent session |
| Sidebar | `1`–`9` | Open a slot (or create the next one) |
| Sidebar | `a`, `x`, `y`, `D`, `C`, `t`, `n`, `?` | Add / remove slot / copy session id / `D` deletes a session or distills a topic / consolidate topic / attach or detach topic / browse topic notes / show help |
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

## Topics

Topics keep reviewed knowledge across agent sessions and projects as editable
Markdown files. They are stored under
`stdpath("data") .. "/agent-dashboard/topics"` by default. Create and attach one
to the selected slot with:

```vim
:AgentDashboard topic new billing-migration
:AgentDashboard topic attach billing-migration
```

The sidebar shows topics and their unreviewed note counts. Press `t` on a slot to
attach or detach a topic, `Enter` on a topic to edit its brief, `n` to browse its
notes, `D` to paste a distillation prompt into the selected agent terminal, and
`C` to paste a consolidation prompt. Press Enter to submit either prompt. Review proposals with
`:AgentDashboard consolidate review billing-migration`, then accept or reject
them explicitly. `:AgentDashboard note [topic]` saves the current selection or
range with its project and session source.

To draft or improve a brief from a session that contains your feature description,
select that agent slot and run `:AgentDashboard brief billing-migration`. Submit
the pasted prompt, then use `:AgentDashboard brief review billing-migration`
and `:AgentDashboard brief accept billing-migration` (or `reject`). This updates
the feature overview from session context without marking investigation notes
consolidated. Use `consolidate` later to fold those notes into the brief.

Both commands accept optional focus text after the topic ID. This lets you
capture several targeted notes from one long conversation:

```vim
:AgentDashboard distill bank-ownership-transfer user state API responses and permissions
:AgentDashboard distill bank-ownership-transfer access token creation and expiration
:AgentDashboard brief bank-ownership-transfer clarify scope and acceptance criteria
```

Use `distill -- <focus text>` or `brief -- <focus text>` to use the selected
slot's attached topic (or choose one if no topic is attached). Focused brief
updates preserve accurate existing context outside the requested focus. Review
and submit each pasted prompt with Enter before starting the next request.

Claude Code receives the brief from the configured `SessionStart` reporter.
OpenCode receives a brief-reading prompt only when the dashboard resumes a
session in an attached slot, after the reporter identifies that session as idle.
The prompt is pasted once without submitting it; press Enter to send it. Manual
OpenCode starts do not receive this prompt. Claude's next SessionStart reads the
current attachment from a per-slot file, so attaching or detaching takes effect
without restarting the shell. Topic attachments last for the current Neovim process; the files
remain on disk and can be placed in a Git repository if you want to share them.
See [`docs/design/topics.md`](docs/design/topics.md) for the storage format,
configuration, Lua API, and workflow details.

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
nvim --headless -u NONE -i NONE -l tests/topics.lua
nvim --headless -u NONE -i NONE -l tests/topics_dashboard.lua
nvim --headless -u NONE -i NONE -l tests/topics_delivery.lua
node --check extras/opencode/agent-dashboard-tui.js
bash -n extras/claude/agent-dashboard-report.sh
```

To re-record the demo GIF, install [VHS](https://github.com/charmbracelet/vhs)
and run `vhs assets/demo/demo.tape` from the repo root in a regular terminal.

Run `:checkhealth agent_dashboard` to verify `jq`, the agent CLIs, and reporter
configuration. See `doc/agent-dashboard.txt` for the full command and Lua API
reference.
