# Design: topics.

| | |
| --- | --- |
| **Status** | Implemented (v1) |
| **Date** | September 30, 2026 |
| **Scope** | New `agent_dashboard.topics` module, sidebar UI, and reporter hook changes |

## Summary.

A **topic** is a named, file-based body of knowledge about an investigation, initiative, or system.
It lives outside any single project or agent session. The dashboard helps you **store** what you
learn, **capture** it from agent sessions and the editor, and **deliver** it to attached sessions in
Claude Code and OpenCode.

The plugin doesn't summarize anything itself. Agents write summaries through ordinary prompts,
you review them in Neovim, and harnesses receive them through their own mechanisms. Topic storage
and slot attachments are local to the Neovim process unless the topic folder itself is shared.

## Problem.

Long investigations span many sessions, many repos, and sometimes more than one agent. Each session
starts from zero:

- **Knowledge disappears.** When a session ends or its context gets compacted, what it learned is
  gone unless you copy it somewhere by hand.
- **Harness memory is siloed.** Claude Code's `CLAUDE.md`, memory, and skills don't reach
  OpenCode, and the reverse is also true. Most of it is also scoped to one project.
- **Context is costly to rebuild.** Re-explaining an initiative to every new session wastes time and
  tokens, and the explanations drift apart.
- **Provenance is lost.** Even when a finding is written down, it's hard to get back to the
  conversation that produced it.

The dashboard already knows your projects, slots, sessions, and harnesses, so it's the natural
place to connect them.

## Goals.

1. Store knowledge per topic, across projects and harnesses, as plain files you can read and edit.
2. Make capturing a finding cheap: one command from the editor or an agent terminal.
3. Deliver a short, current summary to new agent sessions without manual copying.
4. Keep a link from every note back to the session that produced it.
5. Keep humans in charge of what counts as "known." Review happens before anything reaches the
   shared summary.

## Non-goals.

- **A memory engine.** No embeddings, vector search, or automatic retrieval. Agents can search
  the notes with their normal file tools.
- **Automatic summaries by default.** Automatic capture costs tokens and adds noise. It's opt-in.
- **Syncing or sharing.** The plugin writes files. If you want a topic shared, put its folder in a
  Git repo yourself.
- **Replacing harness memory.** Topics sit next to `CLAUDE.md`, memory, and skills, and don't
  take them over.

## Concepts.

| Term | Meaning |
| --- | --- |
| **Topic** | A folder that holds knowledge about one initiative, investigation, or system. |
| **Brief** | `brief.md`: the short, curated summary delivered to agents. It has a size limit. |
| **Note** | One dated finding in `notes/`, with a link to the session that produced it. |
| **Attach** | Link a topic to a dashboard slot, so agents started in that slot receive it. |
| **Distill** | Ask the agent in a slot to write what it learned into a new note. |
| **Consolidate** | Ask an agent to fold new notes into the brief, then review the diff before accepting. |

## Storage.

### Layout.

```text
<topics_dir>/                          default: stdpath("data") .. "/agent-dashboard/topics"
└── billing-migration/
    ├── topic.md                        metadata and links
    ├── brief.md                        curated summary (delivered to agents)
    └── notes/
        ├── 2026-09-29-auth-service.md
        └── 2026-09-30-invoice-queue.md
```

A topic's folder name is its ID: lowercase letters, numbers, and hyphens.

### `topic.md`

```markdown
---
title: Billing migration
status: active            # active | paused | done
projects:
  - ~/projects/billing-api
  - ~/projects/invoice-worker
created: 2026-09-29
---

Free-form description: why this topic exists and what "done" looks like.
```

`projects` lets the dashboard suggest the topic when Neovim's working directory is inside one of
those paths. `topic new` links the topic to the current working directory by default; edit the list
to add or remove project roots.

### `brief.md`

The brief is what agents read first, so it stays short. The default limit is 150 lines, and the
health check warns when a brief goes over it. The recommended sections are:

```markdown
# Billing migration: brief.

Updated September 30, 2026.

## Goal and desired outcome.
## Scope and non-goals.
## Requirements and acceptance criteria.
## Systems and responsibilities.
## Current understanding.
## Decisions made.
## Open questions.
## Where to look next.
```

### Notes.

```markdown
---
date: 2026-09-30
source:
  harness: claude
  session: 5b7e2c1a-9d3f-4e8a-b6c2-1f0a9e8d7c6b
  project: ~/projects/invoice-worker
consolidated: false
---

# Invoice queue retries.

- Retries use exponential backoff capped at 15 minutes (`src/queue/retry.ts:42`).
- Open question: do failed invoices ever reach the dead-letter queue?
```

- `source` records where the note came from. The dashboard uses it to resume that session.
- `consolidated` marks whether the note has been folded into the brief yet.
- Notes are append-only by convention. You correct them by editing, not by deleting history.

## Capture.

### Note from the editor.

`:AgentDashboard note [topic]` saves the current selection, or the given range, as a new note.
It reuses the selection logic from `send_context`.

- In a code buffer, the note includes the file path and line numbers.
- In an agent terminal buffer, the note records the slot's harness and session as its `source`.
- With no topic given, the note goes to the current slot's attached topic. If none is attached, a
  picker opens.

### Distill from an agent.

`:AgentDashboard distill` pastes a standard prompt into the selected slot through bracketed paste,
like `send_context` does. Review it and press Enter to submit:

Topic commands also insert a short explicit request outside the bracketed-paste block, so harnesses
that treat pasted text as quoted context can distinguish the request from the supporting instructions.
Neither the request nor the block is submitted automatically. Without focus text, distill captures
the session's overall investigation findings; with focus text it creates a targeted note.

```text
This is my explicit request through the dashboard: capture this session's investigation findings
in the topic "<topic title>" at <topics_dir>/<id>/notes/<date>-<slug>.md. The topic is a destination
for a broader initiative; this session need not have discussed that initiative. Record factual
subsystem findings without inventing their connection to the planned feature. Put the supplied
frontmatter first, then an investigation-specific heading, confirmed findings, and open questions.
```

- It works with any harness, because it's only a prompt and a file path.
- The topic is the collection destination, not a requirement that the session already discussed
  the initiative. Investigations across different projects can contribute to the same topic.
- The default prompt captures only this session's findings and evidence. It explicitly avoids reading
  the brief or other notes to expand the capture; deduplication and cross-project synthesis happen
  during consolidation. This keeps each note grounded in its source session and project.
- The prompt includes `date`, `source` (`harness`, `session`, and `project` when available), and
  `consolidated: false` frontmatter for the note.
- You can override the prompt template in config.

Optional focus text narrows capture to a particular part of a long session:
`:AgentDashboard distill <topic> <focus text>`. Run it repeatedly with different focuses to create
separate notes. Use `distill -- <focus text>` for the attached topic or a picker. Focus instructions
are appended even to custom prompt templates and ask for one targeted note without unrelated
conversation material. The Lua API is `dashboard.distill(id, focus)`.

### Draft or improve the brief from a session.

Select the agent slot containing the feature description and run
`:AgentDashboard brief [topic]`. The prompt asks the agent to use this conversation's requirements,
decisions, and feature context together with the existing brief to write `brief.proposed.md`.
It distinguishes planned behavior from current behavior and records unknowns instead of inventing
details about other systems. Review and submit the pasted prompt with Enter.

Use `:AgentDashboard brief review [topic]` to review the diff, then `brief accept [topic]` or
`brief reject [topic]`. These share the consolidation review workflow, but accepting a session-based
brief proposal does not mark any investigation notes consolidated. Use one proposal-producing
session per topic at a time. `topics.prompts.brief` can override the prompt with placeholders
`{{title}}`, `{{brief_path}}`, `{{proposal_path}}`, `{{notes_path}}`, and `{{brief_max_lines}}`.

`:AgentDashboard brief <topic> <focus text>` narrows the proposed update while preserving accurate
existing sections outside that focus. `brief -- <focus text>` uses the attached topic or picker;
the Lua API is `dashboard.brief(id, focus)`. For IDs matching a review subcommand, use
`brief topic <id> <focus text>`.

### Consolidate.

`:AgentDashboard consolidate [topic]` pastes a prompt asking the selected agent to merge
unconsolidated notes into `brief.proposed.md`. Review it and press Enter to submit.

1. The agent writes its proposal to `brief.proposed.md`, not to `brief.md`.
2. Run `:AgentDashboard consolidate review [topic]` to open a diff between `brief.md` and the proposal.
3. Edit the proposal, then accept (`brief.proposed.md` replaces `brief.md`, and the notes present when
   consolidation began are marked
   `consolidated: true`) or reject (the proposal is deleted).

The dashboard snapshots the note filenames in `brief.proposed.notes.json` while a proposal is
pending, so notes added afterward remain unconsolidated, including if Neovim is restarted before
the proposal is accepted.

This is the main protection against a confident but wrong summary spreading to every future session.

### Automatic capture (opt-in).

With `topics.auto_distill = "remind"`, the dashboard reminds you to run `:AgentDashboard distill`
once per session when an attached agent completes a turn. It's off by default. The plugin never writes a note or
generates a summary automatically.

## Delivery.

When a topic is attached to a slot, the dashboard atomically writes
`$NVIM_AGENT_DASHBOARD_DIR/<slot>.topic`. Its three lines contain the topic ID, absolute topic folder,
and brief line limit. Detaching writes an empty file. The reporter reads this file on each
SessionStart, so existing shells see attachment changes without restarting or losing shell state.
The terminal's `topic_id` is the only in-memory attachment state, indexed by stable slot ID.

Each harness then receives the brief through its own mechanism. Agents get **the brief plus paths**:
the short summary, and where the notes are, so they can read more when they need to. Attaching a topic
does not interrupt a running agent; Claude receives the current attachment on its next SessionStart.

### Claude Code: the `SessionStart` hook.

The reporter already runs on `SessionStart` (`extras/claude/agent-dashboard-report.sh`). Claude
Code adds a `SessionStart` hook's standard output to the session's context. With a topic attached,
the `start` action prints:

```text
You are working on the topic "billing-migration". Read its notes when useful: <topics_dir>/billing-migration/notes
Topic brief (<topics_dir>/billing-migration/brief.md):
---
<contents of brief.md>
---
```

It requires no new hooks, because users who report status already have this one installed.

### Claude Code: export as a skill (optional).

`:AgentDashboard topic export-skill <id>` creates `~/.claude/skills/topic-<id>/SKILL.md`. Its
frontmatter `description` says when the topic applies, and its body points to the brief and notes.
Claude loads skills on demand when a conversation matches, so the topic becomes available in every
project without being attached to a slot.

### Other harnesses.

- **OpenCode:** only when the dashboard resumes a session in an attached slot, it waits for a matching
  idle OpenCode status report, then pastes a brief-reading prompt once, without Enter. Switching to
  an already running session does not repeat it. Without a matching report before
  `topics.opencode_prompt_timeout_ms` (default 15000 ms), delivery is abandoned. Manual OpenCode
  starts do not receive the prompt. Press Enter to submit the pasted prompt.
- Other harnesses can use the same first-prompt fallback until a native per-session mechanism is
  implemented.

## Dashboard UI.

### Sidebar.

```text
 AGENTS
 1 Add rate limiting ●
 2 claude            ○

 TOPICS
 * billing-migration   3 new
   search-reindex

 RECENT
 CC Add rate limiting to …
```

- `*` marks topics linked to the current project.
- "3 new" counts unconsolidated notes.
- The slot rows show which topic each slot has attached, as part of their titles or on a second
  line if space is tight.

### Keys.

| Where | Key | Action |
| --- | --- | --- |
| Sidebar, slot row | `t` | Attach a topic to the slot, or detach it |
| Sidebar, topic row | `Enter` | Open `brief.md` in the editor |
| Sidebar, topic row | `n` | List the topic's notes in a picker |
| Sidebar, topic row | `D` | Distill from the selected slot into this topic |
| Sidebar, topic row | `C` | Consolidate this topic |
| Sidebar, recent session row | `D` | Delete the selected recent session |
| Note picker | Select a note | Choose to open it or resume its source session |

### Commands.

```text
:AgentDashboard topic new <id>
:AgentDashboard topic open [id]
:AgentDashboard topic list
:AgentDashboard topic attach <id>          (current slot)
:AgentDashboard topic detach
:AgentDashboard topic export-skill <id>
:AgentDashboard note [id]
:AgentDashboard distill [id] [focus...]
:AgentDashboard brief [id] [focus...]
:AgentDashboard brief review [id]
:AgentDashboard brief accept [id]
:AgentDashboard brief reject [id]
:AgentDashboard consolidate [id]
:AgentDashboard consolidate topic <id>      (also accepts IDs named review, accept, or reject)
:AgentDashboard consolidate review [id]
:AgentDashboard consolidate accept [id]
:AgentDashboard consolidate reject [id]
:AgentDashboard skills
```

### Lua API.

```lua
local topics = require("agent_dashboard.topics")
topics.list()                        -- { { id, title, status, projects, new_notes }, … }
topics.for_cwd(cwd)                  -- topics whose `projects` contain cwd
topics.create(id, { title = "…" })
topics.attach(slot_index, id)
topics.note(id, text, source)        -- source = { harness, session, project }
topics.brief_path(id)
```

An attachment lasts for the lifetime of the dashboard's current Neovim process and follows the slot
if earlier slots are removed. `topics.attach(slot_index, nil)` detaches it.

## Skills browser.

Skills and topics are related but different. A **skill** is a procedure, how to do something. A
**topic** is knowledge, what we've learned about something. The dashboard keeps their browsers
separate:

- `:AgentDashboard skills` opens a picker with the skills your harnesses can see. For Claude Code,
  that's `~/.claude/skills/` and the current project's `.claude/skills/`. Selecting one opens its
  file.
- `:AgentDashboard topic export-skill <id>` adds a topic skill under `~/.claude/skills/`; it appears
  in this picker afterward.
- It's read and edit only. Creating and managing skills stays with each harness.

## Configuration.

```lua
require("agent_dashboard").setup({
    topics = {
        enabled = true,
        dir = vim.fn.stdpath("data") .. "/agent-dashboard/topics",
        brief_max_lines = 150,
        suggest_for_cwd = true,       -- suggest linked topics when the dashboard opens
        deliver = true,               -- write attachment files and deliver topic context
        auto_distill = false,         -- false | "remind" (reminders only; never writes automatically)
        opencode_prompt_timeout_ms = 15000,
        prompts = {
            distill = nil,            -- placeholders: {{title}}, {{note_path}}, {{brief_path}}, {{notes_path}}, {{source_frontmatter}}
            consolidate = nil,        -- placeholders: {{title}}, {{brief_path}}, {{notes_path}}, {{proposal_path}}
        },
    },
})
```

## Privacy and safety.

- **Local by default.** Topics live under Neovim's data folder. Only a folder you choose, such as a
  Git repo, is shared.
- **Sensitive content.** Investigation notes can include internal system details, customer data,
  or secrets copied from logs. The distill prompt tells agents to leave out secrets and personal
  data, and the docs should say the same. The plugin doesn't scan content.
- **Prompt injection.** A brief is delivered as context, so text in it can steer an agent. Treat a
  topic folder shared by someone else like any other untrusted input.
- **Hook failures.** If the topic folder is missing, the reporter prints nothing and exits `0`. A
  missing topic must never break a Claude session.

## Risks and trade-offs.

| Risk | Mitigation |
| --- | --- |
| Scope creep in a status dashboard | Keep topics in their own module with a small API, so they can become a separate plugin later. |
| Wrong or stale knowledge spreads | Review before consolidating, dated notes, source links, and "Updated" dates in the brief. |
| Context bloat | Deliver the brief plus paths, not every note. Warn when the brief goes over its line limit. |
| Overlap with harness memory | Position topics as explicit, visible, and cross-harness. Don't fight `CLAUDE.md` or skills. |
| Harness mechanisms change | Keep delivery in per-harness adapters, with the first-prompt fallback everywhere. |

## Alternatives considered.

- **Use `CLAUDE.md` or project memory only.** It's scoped to one project and one harness, which is
  exactly the gap.
- **A single global notes file.** It's simple, but it mixes initiatives and grows without limit.
- **Automatic summaries after every turn.** It costs too many tokens, adds noise, and can't be
  reviewed.
- **An MCP server for topics.** It's harness-neutral and could come later, but it's heavier to set
  up than files plus hooks, and not every harness is configured for MCP.

## Delivery status.

| Phase | Scope | Done when |
| --- | --- | --- |
| **1. Topics and attach** | Folder layout, `topic new/open/list/attach/detach`, sidebar section, per-slot attachment files. | Implemented. |
| **2. Capture** | `note` with `source`, `distill` prompt, note picker with resume. | Implemented. |
| **3. Delivery** | Claude `SessionStart` output, OpenCode first-prompt fallback, health check for brief size. | Implemented. |
| **4. Consolidate and skills** | Proposal diff and accept/reject, `export-skill`, skills browser, opt-in `auto_distill` reminders. | Implemented; reminders are manual-only and proposals are reviewed before acceptance. |

Phases one and two are useful on their own: one place to collect findings from every session, with
links back to where each one came from.

## Testing.

- **Unit:** topic parsing (`topic.md` frontmatter), `for_cwd` matching, note creation with `source`,
  new-note counts, attachment mapping, proposal acceptance/rejection, and consolidation snapshots.
- **Reporter:** run the hook script with a per-slot attachment file and check its output. Check that
  a missing folder prints no topic context and does not break the session.
- **UI:** the sidebar renders the TOPICS section, and `topic attach` / `topic detach` update the slot.
- **Consolidate:** accepting a proposal replaces the brief and marks only the notes included when
  consolidation began; rejecting one leaves the brief and notes unchanged.

## Decisions.

1. **Sidebar.** Topics live in the sidebar, with the list clipped to available space and the full
   list available through the topic picker.
2. **Attachments.** One topic per slot keeps session context unambiguous.
3. **Metadata.** Use a dependency-free YAML subset: scalar values, simple lists, and one-level
   nested maps for note sources.
4. **OpenCode delivery.** Use a reporter-gated first-prompt fallback rather than modifying global
   OpenCode configuration. Wait for a matching idle reporter event and paste without submitting.
5. **Naming.** Keep “topics” as the user-facing term.
