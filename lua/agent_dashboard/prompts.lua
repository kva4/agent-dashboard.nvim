-- Topic knowledge prompts live here so capture, consolidation, and delivery agree.
local M = {}

local preamble = [[You are recording topic knowledge from the conversation above. The plugin saves your reply as a file.
Return only Markdown, without frontmatter or a surrounding code fence. Do not use tools, read files,
or modify anything.

Reader: a future agent, or the user, starting a new session on this topic without access to this
conversation. They might go deeper, search for something, start a related investigation, or plan a
large change. Write what saves them time and keeps them from repeating mistakes.

Evidence rules:
- Use only what this conversation established. The destination topic is a storage label, not
  evidence. Don't invent links to it or bring in claims from other projects.
- Say how solid a claim is when it matters: verified (seen in code, output, docs, or tests),
  inferred, or unconfirmed. Keep the qualifications the conversation expressed.
- Record the final state. If something was changed, reverted, or disproven later in the
  conversation, keep the outcome. Mention the discarded path only when knowing it prevents a repeat.
- Be specific: exact file paths, symbols, commands, config keys, URLs, error messages, versions, and
  IDs, as the conversation established them. Point to code rather than pasting large blocks. A short
  snippet is fine when it's the clearest explanation.
- Leave out the conversation's process (who asked what, tool calls, retries) and anything that only
  mattered within this session.

Destination topic: ]]

local note_guidance = [[Write one self-contained note about what this session established.

Start with a # Title naming the subject (not the session). Follow it with a two- to four-sentence
lead giving the main takeaway: the answer, outcome, or current state a reader needs most.

Then shape the body to fit the session, with descriptive headings. Common shapes:
- Explanation or Q&A: organize by subject or question. Explain how things work and why, including
  mechanisms, dependencies, data flow, and examples from follow-ups. Merge related questions and
  follow-ups into coherent explanations instead of replaying the conversation turn by turn.
- Investigation or debugging: the symptom, the cause found (or the leading candidates), the
  evidence, what was ruled out and why, and the fix or workaround.
- Implementation: what was built or changed and where, the design and why it beat the alternatives,
  conventions and constraints that matter, how to verify it, and what remains.
- Search or exploration: where things live (paths, entry points, owners, config), how the pieces
  connect, and the queries or commands that found them.
Sessions often mix shapes, so combine them as needed. These aren't required sections. Include an item
only if the conversation covered it.

Always worth keeping when present: gotchas and non-obvious constraints, dead ends with the reason
they failed, decisions with their rationale, commands or steps that worked, and questions left open.
Don't invent decisions, open questions, or next steps to fill a shape.

Make it as long as the content needs and no longer. Prefer dense, skimmable paragraphs and bullets.
The topic brief and other notes are not evidence for this note.]]

function M.updated_date()
    return (os.date("%B %d, %Y"):gsub(" 0(%d),", " %1,"))
end

function M.brief_guidance()
    local limit = require("agent_dashboard.topics").brief_max_lines()
    local date = M.updated_date()
    return string.format([[The brief is the first thing an agent reads when it starts a session on this topic, and only its
first %d lines are delivered. It's an orientation page, not a log. A new agent should quickly learn
what the topic is, what's known, what's settled, and where to look, so it can start any kind of
work: a question, an investigation, a search, or a large implementation. Detailed explanations
belong in notes. The brief summarizes and points.

- Keep durable knowledge only: facts, decisions, constraints, locations, and status that will still
  matter in a later session. Leave out session narrative.
- Keep the current structure when it fits. If the brief is empty, still the default template, or
  its sections don't fit this topic, use sections that fit. A good general shape is:
    # <Topic>: brief.
    Updated %s.
    ## Purpose and scope.         what the topic covers and its boundaries
    ## Key facts.                 the most important knowledge, with how solid it is
    ## Where things live.         code paths, services, docs, commands, key notes
    ## Decisions and constraints. settled choices with reasons, rules, gotchas
    ## Current state.             done, in progress, blocked, or pending
    ## Open questions.            unresolved items worth investigating next
  Leave out a section that has nothing real to say rather than padding it.
- Put the most important orientation first. Readers may stop early, and delivery truncates.
- Separate goals and desired outcomes from current behavior, and confirmed facts from assumptions.
- Flag anything likely to go stale (versions, in-progress branches, temporary workarounds).
- Set the Updated line to %s. Stay within %d lines, and prefer short bullets.]], limit, date, date, limit)
end

function M.capture(job)
    local req = job.request
    local focus = req.focus and vim.trim(req.focus)
    local text = preamble .. job.topic_title .. "\n\n"
    if req.kind == "brief" then
        text = text .. M.brief_guidance() .. "\n\n" .. [[Propose a complete revised brief. The user reviews it before it replaces brief.md.
Start from the current brief below. Keep accurate content, update what this conversation changed, and
remove claims it disproved or made obsolete. Don't drop existing knowledge just because this session
didn't touch it. This is a session-based update, not note consolidation.]]
        if focus and focus ~= "" then
            text = text .. "\nRequested focus: " .. focus .. "\nUpdate only the parts of the brief this focus touches. "
                .. "Leave other sections as they are unless the conversation shows they're wrong. "
                .. "If the conversation has nothing on this focus, return the current brief unchanged "
                .. "except for a one-line note saying so."
        end
        text = text .. "\nCurrent brief supplied explicitly:\n<current-brief>\n"
            .. job.snapshot.text .. "\n</current-brief>"
    else
        text = text .. note_guidance
        if focus and focus ~= "" then
            text = text .. "\n\nThe title and lead must describe the focused subject, not the whole session."
            text = text .. "\n\nScope for this note: the requested focus below is the selection boundary, "
                .. "not merely an emphasis within a summary of the whole session. "
                .. "If the focus lists several questions or subjects, cover only those items and their relevant "
                .. "answers and follow-up elaborations. Do not cover other questions from the session. "
                .. "Include additional context only when it is necessary to explain a selected item, and keep "
                .. "that context minimal. Sharing a project, service, or broad topic is not sufficient reason "
                .. "to include another finding. Apply this boundary to the title, every heading, paragraph, "
                .. "bullet, and example. Before returning the note, remove anything outside it. "
                .. "If a selected item was not answered, say that briefly instead of substituting unrelated material.\n"
                .. "Requested focus for this note:\n" .. focus
        end
    end
    return text
end

function M.consolidate_default()
    return [[Consolidate the unconsolidated notes in {{notes_path}} into a proposed brief at {{proposal_path}}.
Read the current brief at {{brief_path}} first, then each note whose frontmatter has
consolidated: false. Don't edit brief.md or the notes. The user reviews the proposal first.

{{brief_guidance}}

Consolidation rules:
- Merge overlapping findings across notes into single statements. Don't summarize notes one by one.
- When notes conflict, prefer the newer note (frontmatter date) unless the older one has stronger
  evidence. If the conflict is unresolved, say so.
- Notes from different projects (frontmatter source.project) may describe different systems. Don't
  merge their claims as one, and name the project when it matters.
- Keep accurate existing knowledge and remove stale or contradicted claims.
- Point to note file names for details the brief can't hold.]]
end

function M.opencode_delivery(brief_path, notes_dir)
    return 'Before we start, read the topic brief at "' .. brief_path
        .. '". It summarizes earlier sessions and may be stale, so verify claims before relying on them. '
        .. 'Detailed notes are in "' .. notes_dir .. '"; read the ones relevant to the task.'
end

function M.skill_body(brief_path, notes_dir)
    return 'Read "' .. brief_path .. '" before working on this topic. The brief summarizes earlier sessions '
        .. 'and may be stale, so verify claims against the code or sources before relying on them, '
        .. 'and tell the user when a claim looks outdated. Detailed notes are in "' .. notes_dir
        .. '"; read the ones relevant to the task instead of all of them up front.\n'
end

return M
