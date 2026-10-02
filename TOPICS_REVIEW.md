# Topics implementation review.

This reviews the uncommitted topics work on the `new-features` branch against
`docs/design/topics.md`.

## Verdict.

It's a solid first pass. Storage, capture, the reviewed-proposal flow, and the
Claude delivery path all follow the design, and the scope is right. The tests
pass on Neovim 0.11.4 and 0.10.4. I downloaded 0.10.4 and ran all three scripts
myself, so that gap in the implementer's report is closed.

I wouldn't merge it yet, though. There's one crash you can hit by editing a
file by hand, two OpenCode delivery bugs, and one slot cwd bug. The rest are
cleanup items.

## Must fix before merging.

### 1. A single-quoted project path crashes the sidebar.

`scalar()` in `lua/agent_dashboard/topics.lua:50` returns `gsub`'s two values.
In a list item, that becomes `table.insert(t, str, count)`, which throws. I
reproduced it:

```yaml
projects:
  - '/tmp/x'
```

```
topics.lua:86: bad argument #2 to 'insert' (number expected, got string)
```

`render()` calls `topic_source.list()`, so one hand-edited `topic.md` breaks
the whole sidebar on every redraw. The design invites hand-editing these files.

**Fix:** wrap the result, `return (value:sub(2, -2):gsub("''", "'"))`. Also
wrap each topic's parse in `pcall` inside `list()` so one bad file can't take
down the dashboard. Add a test with single-quoted values.

### 2. OpenCode gets the brief prompt every time you open its session.

In `open_session()` at about `init.lua:487`, the "already running in a slot"
branch calls `deliver_opencode_topic()`. Pressing `Enter` on a running
OpenCode session in RECENT just switches to it, but it also pastes the brief
prompt and sends `\n`. Each switch submits another "Before we start, read…"
message, even while the agent is working.

**Fix:** deliver only when the plugin starts OpenCode (the resume path). Track
it per terminal, for example `term.topic_delivered = topic_id`.

### 3. The OpenCode prompt can land in the shell instead of OpenCode.

`deliver_opencode_topic()` waits a fixed 1.5 seconds, checks that the *shell*
job is alive, then sends the text plus Enter. If OpenCode starts slowly, or
exits right away (for example, the session isn't found), the shell gets the
line and runs it. The prompt contains backticks, so bash treats them as
command substitution.

It also sends Enter, which goes against the plugin's own rule that context is
"inserted… without submitting."

**Fix:** wait for OpenCode's first status report for that slot (agent
`opencode`, a matching session) before sending, and give up after a timeout.
Leave the Enter off, like `send_context` does. You already have the reporter
data in `states[id]`, so this doesn't need a new mechanism.

### 4. A slot keeps another project's cwd after you resume a note's session.

`open_slot()` sets `term.cwd = requested_cwd or old_cwd`. Resuming a session
from a note's `source.project` moves the slot to that project, which is
correct. But regular RECENT sessions don't carry `project`, so later resumes in
that slot keep running in the other project. `claude --resume <id>` then fails,
because Claude looks up sessions by project directory.

**Fix:** when `session.project` is missing, fall back to `vim.fn.getcwd()`,
not the slot's last cwd.

## Should fix.

### 5. Slot status colors land on the wrong row.

Topic sub-lines (`↳ topic`) now sit between slots, but the status highlight
loop at `init.lua:262-270` still uses `lines[index + 2]` and
`highlight(index + 1, …)`. With a topic on slot 1, slot 2's color lands on the
`↳` line. Use `slot_lines[id]`, which the same change already added.

### 6. Detaching doesn't reach a shell that's already running.

The topic reaches Claude through `NVIM_AGENT_TOPIC_DIR`, which is fixed when
the shell starts. The attach callback restarts the shell only if it has no
child processes. If Claude is running, the env keeps the old value, so:

- Detach, exit Claude, and run `claude` again by hand: it still gets the old
  brief while the sidebar shows no topic.
- Attach while Claude is running: nothing tells you it takes effect only on the
  next start.

Restarting an "idle" shell also silently drops anything you did in it, like a
`cd` or an exported variable.

**Suggestion:** have the plugin write the attachment to
`$NVIM_AGENT_DASHBOARD_DIR/<slot>.topic` and have the reporter read that file
at `SessionStart`. Then attach and detach take effect right away, the shell
never needs a restart, and `idle_shell()` plus the `started_topic_id` respawn
logic can go. It also fits the plugin's "small file contract" style.

### 7. Accepting a proposal rewrites note frontmatter and drops unknown keys.

`accept_proposal()` parses each note and rewrites it with `with_frontmatter()`,
which only writes a fixed list of keys. Anything else the user or agent added,
like `tags:` or a `source.url`, is silently lost. Agents write these notes
freely, so this will happen.

**Fix:** change only the `consolidated:` line in place, or add it if it's
missing. Leave the rest of the file untouched.

Also, if the snapshot file is missing (for example, the proposal was written by
hand), accept marks *every* note consolidated, including ones written after the
proposal. That's probably fine, but show a message when it happens.

### 8. The sidebar reads every topic and note file on each render.

`render()` calls `topic_source.list()` and then `for_cwd()`, which calls
`list()` again. Each call globs every topic and reads every note to count the
unreviewed ones. `render()` runs on state changes from a 1-second poll. That's
fine with a few notes, but it grows with every note you save.

**Fix:** cache the list and refresh it when the dashboard opens, on the
existing 30-second session refresh, and after the plugin writes a note or
accepts a proposal. `for_cwd()` should take the list it already has.

### 9. Two sources of truth for attachments.

`topics.lua` stores attachments by slot *index* and shifts them when a slot is
removed. `init.lua` stores `term.topic_id` by slot *id*. `start_terminal()`
merges the two. It works today, but the two will drift. Keep the attachment
only on the terminal in `init.lua`, and make `topics.lua` pure storage
(files in, files out). That also makes item 6 simpler.

## Minor.

- **The `D` key does different things by row type.** On a topic it pastes a
  prompt. On a recent session it deletes. One wrong cursor row turns a
  harmless action into a destructive one. Check that delete always asks for
  confirmation, or move distill to another key.
- **`D` and `C` on a topic row send to the selected slot**, not a slot that has
  that topic. If the selected slot is a plain shell, the prompt lands in bash.
  Warn when the selected slot has no running agent, or when it has a different
  topic attached.
- **`:AgentDashboard note` with no range** falls back to the last visual
  selection marks, which can be old. Using the current line, or refusing, would
  be less surprising. `send` has the same behavior, so at least they're
  consistent.
- **Editor notes are attributed to the selected slot's session**, even when that
  session had nothing to do with the note. Record only `project` for notes
  saved from a normal buffer.
- **Topic IDs can collide with subcommands.** A topic named `review`, `accept`,
  or `reject` can't be used with `:AgentDashboard consolidate <id>`.
- **`export-skill` overwrites silently.** It writes to `~/.claude/skills` every
  time. Ask before replacing a skill that already exists.
- **The Claude hook output size is unchecked.** The reporter prints the whole
  brief at `SessionStart`. The health check warns past 150 lines, but the
  reporter doesn't enforce it. Check whether Claude Code truncates long hook
  output, and cap it in the reporter with `head -n`.
- **`auto_distill` accepts `"remind"`** while the default is `false`, and the
  reminder fires after every turn. Document the accepted values in the help
  file. Consider reminding once per session instead of every turn.

## Tests.

The tests cover storage, path escapes, project matching, the proposal accept
and reject flow, env delivery, the sidebar rows, and the reporter output. They
isolate `HOME` for the skill export, which is good. I'd add tests for:

- single-quoted and commented frontmatter values (item 1)
- switching to a running OpenCode session doesn't send a prompt (item 2)
- slot cwd after resuming a note's session and then a regular one (item 4)
- status highlight rows with a topic attached (item 5)
- accepting a proposal keeps unknown frontmatter keys (item 7)

## Docs.

The README, help file, and design doc match the behavior. Two things are
missing: the README should say that OpenCode gets the brief only when the
dashboard resumes a session, not when you start `opencode` yourself, and that
attaching a topic to a running agent takes effect on its next start (unless you
adopt item 6).

## Suggested order.

1. Fix items 1–4 and add their tests.
2. Fix item 5, since it's one line.
3. Decide on item 6. If you take the file-based approach, it removes item 9
   and simplifies item 3.
4. Do items 7 and 8, then the minor list.
