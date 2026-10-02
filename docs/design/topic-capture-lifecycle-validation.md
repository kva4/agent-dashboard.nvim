# Topic capture: execution contract and validation

Date: 2026-10-01. This records the implemented adapter/coordinator contract and
the supervisor's disposable end-to-end checks. It is not a claim of exhaustive
interactive UI testing.

## User-visible contract

Capture is available for an idle, reported Claude Code or OpenCode session with
a known project and session ID. In an agent terminal, `keys.capture` (default
`<M-c>`) opens capture for that session. In the dashboard, `c` on a slot row
captures that slot; `c` on a topic row uses the selected topic and slot as
source. Choose a topic, optional focus, and either **Save findings** or
**Propose brief**. Each makes an extra model request in a separate helper; it
does not paste or submit a prompt in the source terminal. There is no automatic
after-turn capture.

Saved notes retain the original source project/session provenance. A proposed
brief is a session-based proposal, distinct from consolidating notes, and must
be reviewed and explicitly accepted or rejected. The sidebar provides cancel
while active; `o` open, `e` diagnostics, `R` retry, `d` dismiss on failure; and
`o` open, `r` review, `d` dismiss on completion. Cancelled results can be
dismissed. Results whose source slot is gone appear in an orphan section.

Capture journals ownership before worker launch and records helper identity
when reported. Known helpers are suppressed from recent sessions; startup
reconciliation retries cleanup only from journaled ownership. Before signalling
a recorded PID, the coordinator verifies a capture-specific process marker.
It does not select helpers by recency. If topic save fails, generated output is
preserved at a recovery path; the helper is retained only if output cannot be
recovered anywhere.

## Adapter contract

The coordinator calls the adapter methods:

```text
prepare(request, capture_id) -> helper_id | nil, error
start(request, prompt, ownership_callback, done_callback) -> handle | nil, error
cancel(handle, callback(stopped, error))
cleanup(request, helper_id, callback(ok, error), handle)
cleanup_record(record, callback(ok, error))
```

`start` must report helper ownership as soon as it is known, and completion
returns the helper ID and generated text. The coordinator rejects a result with
missing/mismatched identity, source identity, or empty text. Successful output
is saved by the coordinator, then helper cleanup runs. A failure to prove
worker stop or cleanup is journaled for reconciliation. A safely saved file stays
successful, with cleanup failure shown separately. This implementation does not
enforce source-export hashes at runtime.

### Claude Code 2.1.286

The helper UUID is derived from the capture ID and persisted before launch.
The worker runs in the source project directory with `--resume`, `--fork-session`,
`--session-id <helper UUID>`, `--output-format json`, `--tools ""`,
`--permission-prompts none`, `--safe-mode`, and `disableAllHooks` settings.
Unlike `--bare`, safe mode preserves the existing OAuth authentication.
Custom hooks and tools are disabled; dashboard and topic-delivery variables and
`NVIM` are removed from the explicit worker environment. Compaction does not
require inspecting the start of the helper transcript to establish identity.
Cancellation waits for the process exit callback. Cleanup removes only the
preassigned helper's JSONL and companion directory under the expected project
paths, including the canonical realpath. This is validated exact-path storage
cleanup, not Claude's unrelated background-session `rm` command.

### OpenCode 1.18.30

The adapter launches `opencode serve --hostname 127.0.0.1 --port 0 --pure` in the
source project directory. It calls `POST /session/<source>/fork`, tags the
returned helper via `PATCH /session/<helper>`, and journals that ID before
`POST /session/<helper>/message`. The returned assistant text is saved before
`DELETE /session/<helper>` and private-server shutdown. Existing authentication
is reused; an explicit model override is optional. The capture config denies
permissions, disables plugins, and disables tools for the message. The explicit
environment clears reporting/topic-delivery variables and `NVIM`.
Cancellation calls `/abort` and checks `/session/status`; this endpoint omits
idle sessions. If idle cannot be confirmed, the private server is stopped and
its exit awaited before the CLI deletion fallback. `curl` and `ps` are used for
local API requests and crash-time process ownership checks. Known helpers appear
in harness discovery until deletion and are filtered by the dashboard meanwhile.

OpenCode has an unavoidable first-release crash window: its fork can be created
before the server returns an event containing the helper ID. The journal marks
`fork_pending`, but a crash in that interval leaves no safely attributable ID.
The implementation does not guess or delete by recency; automatic cleanup of
that unidentified helper cannot be guaranteed.

## Disposable execution checks

The supervisor ran `nvim` with a temporary `full-capture-check.lua` through the
full coordinator for both harnesses. It created disposable sources containing
a unique marker, forked each source, checked that output inherited the marker,
saved durable output, deleted the helper, and verified the source SHA-256 was
unchanged. Cancellation was also exercised. These were disposable sources;
both were removed after verification. These hash comparisons are test evidence,
not a runtime source-hash guard.

| Harness | Capture helper | Cancel helper | Source SHA-256 |
| --- | --- | --- | --- |
| Claude Code | `6b44b6db-d9dd-4478-84a1-c36c496c6597` | `a0b1cd37-817b-428e-a931-0a5f29a16c1f` | `d75d9ade6e717f90a07c1654f8b55a0358fda710abfe99f1a03a400116909cae` |
| OpenCode | `ses_f0952ce6affewPF4F888MO9Z8V` | `ses_f0952b24effeNPPar9cAlgdL4q` | `b31fb58d22b912040644564b6a72ffbbfe11ff030dd21579f59f0c08f83be81b` |

The Claude compacted-context follow-up separately verified marker inheritance
through a fork after a compact operation in a disposable synthetic chain. It
did not establish a source-byte invariant for that compaction test. OpenCode
was then tested through `/summarize` on another disposable synthetic source.
Its export contained a persisted compaction part. Capture inherited the source's
ownership-version fact `7419`, saved the note, and deleted helper
`ses_f094270f3ffeAO2WtC0SWfM5EV`. The post-compaction source export stayed
byte-identical with SHA-256
`d8e95805c733736dea0ce16cb6646e316bc57ba85525d05bfa7c0abdd0450494`.
The disposable source was removed afterward. The initial Claude fork check also
verified a predetermined helper/session ID. No existing user session was used
in these checks.

An additional interrupted-worker check created an empty disposable OpenCode
source and a tagged helper, wrote a real capture journal, and left the private
server running. Startup reconciliation verified its capture-specific process
marker, terminated and awaited the owned PID, verified the helper's ownership
tag through export, and deleted only that helper. The source export remained
unchanged with SHA-256
`c0c549361e64716b915d966bf77a428ea51ede85c888edad3c0969fbf55ddec4`.
The disposable source was then deleted. Tests separately verify that an
unresolved fork response remains pending and never calls a deletion adapter.

The headless dashboard tests exercise slot `c`, the buffer-local terminal
capture mapping, popover keyboard navigation, inline errors, and restoration of
the original terminal buffer after submission. They caught and verified a fix
for the dashboard's WinEnter handler incorrectly hiding the source terminal
when capture opened.

A rendered Neovim TUI smoke check was also run in an isolated tmux session.
Actual `Alt-C` input from terminal mode opened the popover while retaining both
dashboard windows. Tab/Enter edited optional focus; `s` submitted and returned
to the original terminal in terminal-input mode. `Ctrl-H`, then the result-row
`o` action, opened the saved note in the editor. This UI check used a simulated
worker and reporter, while the real harness/coordinator lifecycles were checked
separately above. The temporary tmux session was closed afterward.

## Remaining limit

Do not claim guaranteed cleanup of an OpenCode helper when a crash occurs after
fork creation but before helper identity reaches the journal. Recovery must
remain ownership-based; unresolved helpers are not guessed from session order.
