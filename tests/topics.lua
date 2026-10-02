vim.opt.runtimepath:prepend(vim.fn.getcwd())
package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path

local topics = require("agent_dashboard.topics")
local root = vim.fn.tempname()
local project = root .. "/project"
vim.fn.mkdir(project .. "/nested", "p")
topics.setup({ dir = root .. "/topics" })

local created, err = topics.create("billing-migration", {
    title = "Billing migration",
    projects = { project },
    description = "Move invoices to the new service.",
})
assert(created and created.title == "Billing migration", err)
assert(topics.create("../escape") == nil)
assert(topics.create("billing-migration") == nil)
local metadata_path = root .. "/topics/billing-migration/topic.md"
local metadata = table.concat(vim.fn.readfile(metadata_path), "\n")
metadata = metadata:gsub('status: "active"', "status: active            # active | paused | done")
metadata = metadata:gsub('title: "Billing migration"', 'title: "Billing # migration" # topic title')
metadata = metadata:gsub('  %- "' .. vim.pesc(project) .. '"', "  - '" .. project .. "' # project root")
vim.fn.writefile(vim.split(metadata, "\n", { plain = true }), metadata_path)
assert(topics.get("billing-migration").status == "active")
assert(topics.get("billing-migration").title == "Billing # migration")
assert(#topics.for_cwd(project .. "/nested") == 1)
assert(#topics.for_cwd(root .. "/project-other") == 0)
vim.fn.mkdir(root .. "/topics/broken", "p")
vim.fn.writefile({ "---", "source: not-a-map", "source:", "  url: broken", "---" },
    root .. "/topics/broken/topic.md")
assert(#topics.list() == 1) -- A malformed hand-edited file does not break the list.

local note_path = topics.note("billing-migration", "# Retry policy.\n\nRetries cap at 15 minutes.", {
    harness = "claude", session = "session-123", project = project,
})
assert(note_path and vim.fn.filereadable(note_path) == 1)
local notes = topics.notes("billing-migration")
assert(#notes == 1 and notes[1].title == "Retry policy.")
assert(notes[1].source.harness == "claude")
assert(notes[1].source.session == "session-123")
assert(notes[1].source.project == project)
assert(not notes[1].consolidated)
assert(topics.list()[1].new_notes == 1)

local capture_snapshot = assert(topics.capture_snapshot("billing-migration"))
local capture_path = assert(topics.capture_save("billing-migration", "brief", "# Captured brief", {
    harness = "claude", session = "original-session", project = project,
}, capture_snapshot))
assert(capture_path)
local proposal_text = table.concat(vim.fn.readfile(capture_path), "\n")
assert(proposal_text:find('session: "original%-session"'))
assert(vim.fn.filereadable(root .. "/topics/billing-migration/brief.proposed.notes.json") == 1)
assert(vim.json.decode(table.concat(vim.fn.readfile(root .. "/topics/billing-migration/brief.proposed.notes.json"), "\n"))[1] == nil)
assert(topics.reject_proposal("billing-migration"))
assert(vim.fn.filereadable(root .. "/topics/billing-migration/brief.proposed.base.sha256") == 0)

local brief = topics.brief_path("billing-migration")
local original_brief = table.concat(vim.fn.readfile(brief), "\n")
vim.fn.writefile({ "# Rejected proposal" }, root .. "/topics/billing-migration/brief.proposed.md")
assert(topics.reject_proposal("billing-migration"))
assert(table.concat(vim.fn.readfile(brief), "\n") == original_brief)
assert(not topics.notes("billing-migration")[1].consolidated)

topics.begin_consolidation("billing-migration", { notes = false })
vim.fn.writefile({ "# Session-based feature brief" }, root .. "/topics/billing-migration/brief.proposed.md")
assert(topics.accept_proposal("billing-migration"))
assert(not topics.notes("billing-migration")[1].consolidated)
assert(topics.list()[1].new_notes == 1)

topics.begin_consolidation("billing-migration")
local original_note = table.concat(vim.fn.readfile(note_path), "\n")
original_note = original_note:gsub("consolidated: false", "tags:\n  - hand-edited\ncustom: keep me\nconsolidated: false")
original_note = original_note:gsub("source:\n", "source:\n  url: https://example.test/finding\n")
vim.fn.writefile(vim.split(original_note, "\n", { plain = true }), note_path)
assert(vim.fn.filereadable(root .. "/topics/billing-migration/brief.proposed.notes.json") == 1)
local later_note = topics.note("billing-migration", "# Later finding.\n\nFound after the proposal started.", {})
vim.fn.writefile({ "# Accepted proposal" }, root .. "/topics/billing-migration/brief.proposed.md")
assert(topics.accept_proposal("billing-migration"))
assert(vim.fn.filereadable(root .. "/topics/billing-migration/brief.proposed.notes.json") == 0)
assert(table.concat(vim.fn.readfile(brief), "\n") == "# Accepted proposal")
local consolidated = {}
for _, note in ipairs(topics.notes("billing-migration")) do consolidated[note.path] = note.consolidated end
assert(consolidated[note_path] and not consolidated[later_note])
assert(table.concat(vim.fn.readfile(note_path), "\n") == original_note:gsub("consolidated: false", "consolidated: true"))
assert(topics.list()[1].new_notes == 1)

topics.begin_consolidation("billing-migration")
vim.fn.writefile({ "# Final proposal" }, root .. "/topics/billing-migration/brief.proposed.md")
assert(topics.accept_proposal("billing-migration"))
assert(topics.list()[1].new_notes == 0)

local previous_home = vim.env.HOME
vim.env.HOME = root .. "/home"
local skill = topics.export_skill("billing-migration")
assert(skill and vim.fn.filereadable(skill) == 1)
assert(table.concat(vim.fn.readfile(skill), "\n"):find("brief.md", 1, true))
vim.env.HOME = previous_home

if vim.fn.executable("jq") == 1 then
    local report_dir = root .. "/reporter"
    local report_topic = root .. "/topics/billing-migration"
    vim.fn.mkdir(report_dir, "p")
    local env_names = { "NVIM_AGENT_DASHBOARD_DIR", "NVIM_AGENT_SLOT", "NVIM_AGENT_TOPIC",
        "NVIM_AGENT_TOPIC_DIR" }
    local previous = {}
    for _, name in ipairs(env_names) do previous[name] = vim.env[name] end
    vim.env.NVIM_AGENT_DASHBOARD_DIR, vim.env.NVIM_AGENT_SLOT = report_dir, "777"
    vim.env.NVIM_AGENT_TOPIC, vim.env.NVIM_AGENT_TOPIC_DIR = "billing-migration", report_topic
    local reporter = vim.fn.getcwd() .. "/extras/claude/agent-dashboard-report.sh"
    local output = vim.fn.system({ "bash", reporter, "start" }, vim.json.encode({
        session_id = "topic-session", source = "startup",
    }))
    assert(vim.v.shell_error == 0)
    assert(output:find("Final proposal", 1, true))
    assert(output:find("billing-migration/notes", 1, true))
    vim.fn.writefile({ "billing-migration", report_topic, "1" }, report_dir .. "/777.topic")
    output = vim.fn.system({ "bash", reporter, "start" }, '{}')
    assert(output:find("Final proposal", 1, true))
    vim.fn.writefile({}, report_dir .. "/777.topic")
    output = vim.fn.system({ "bash", reporter, "start" }, '{}')
    assert(vim.v.shell_error == 0 and output == "") -- File detach overrides inherited env.
    vim.fn.delete(report_dir .. "/777.topic")
    vim.env.NVIM_AGENT_TOPIC_DIR = report_dir .. "/missing-topic"
    output = vim.fn.system({ "bash", reporter, "start" }, vim.json.encode({
        session_id = "topic-session", source = "startup",
    }))
    assert(vim.v.shell_error == 0 and output == "")
    for _, name in ipairs(env_names) do vim.env[name] = previous[name] end
end

vim.fn.delete(root, "rf")
