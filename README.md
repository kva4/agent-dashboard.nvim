# agent-dashboard.nvim

A floating Neovim dashboard for multiple agent terminals. The sidebar shows live
agent states and recent sessions for the current directory, merging OpenCode and
Claude Code by last activity. Resume a session in an unused terminal (or a new
slot if all are occupied), switch slots without stopping their jobs, and see an
optional status badge in tmux.

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
| Sidebar | `a`, `x` | Add a slot / stop and remove a selected slot |
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

## Agent status reporting

Each dashboard terminal has `NVIM_AGENT_DASHBOARD_DIR` and `NVIM_AGENT_SLOT` in
its environment. A reporter writes JSON to
`$NVIM_AGENT_DASHBOARD_DIR/$NVIM_AGENT_SLOT.json` with
`{slot, time, session, turn, state, agent}`. `state` is one of
`idle`, `working`, `blocked`, or `unknown`. The bundled integrations below are
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
    "SessionEnd": [{"hooks": [{"type": "command", "command": "bash $HOME/.local/share/nvim/lazy/agent-dashboard.nvim/extras/claude/agent-dashboard-report.sh end"}]}]
  }
}
```

Add `PreToolUse` / `PostToolUse` with `working`, and permission notifications
with `blocked`, if you want more precise live status. Preserve your existing
hooks and adjust the path when installing elsewhere. The script does nothing
outside a dashboard terminal. Restart Claude Code after changing its hooks.

## Check

```sh
nvim --headless -u NONE -i NONE -l tests/agent_dashboard.lua
node --check extras/opencode/agent-dashboard-tui.js
bash -n extras/claude/agent-dashboard-report.sh
```
