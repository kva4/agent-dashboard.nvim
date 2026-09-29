// TUI-scoped reporter: attributes the selected OpenCode session to its Neovim slot.
// Add this file to OpenCode's tui.jsonc "plugin" list (see README.md).
import { readFile, writeFile, rename, unlink } from "node:fs/promises";
import path from "node:path";

const slot = Number(process.env.NVIM_AGENT_SLOT);
const directory = process.env.NVIM_AGENT_DASHBOARD_DIR;
const enabled = Number.isInteger(slot) && slot >= 101 && slot <= 9999
  && directory && path.isAbsolute(directory);
const file = enabled ? path.join(directory, `${slot}.json`) : undefined;
const owner = `${process.pid}-${Math.random().toString(36).slice(2)}`;

function reporter() {
  let active = true;
  let chain = Promise.resolve();
  let current;
  let heartbeat;

  function write(state, session, turn, force = false) {
    if (!active) return;
    if (!force && current?.state === state && current.session === session && current.turn === turn) return;
    current = { slot, state, session, turn, time: Math.floor(Date.now() / 1000), owner };
    chain = chain.then(async () => {
      if (!current) return;
      const data = { ...current, time: Math.floor(Date.now() / 1000) };
      const temp = `${file}.${owner}.tmp`;
      await writeFile(temp, JSON.stringify(data), { mode: 0o600 });
      await rename(temp, file);
    }).catch(() => {});
  }

  function clear() {
    if (!current) return;
    current = undefined;
    chain = chain.then(async () => {
      if (current) return;
      try {
        const data = JSON.parse(await readFile(file, "utf8"));
        if (data.owner === owner) await unlink(file);
      } catch {
        // Neovim may already have exited and removed its runtime directory.
      }
    }).catch(() => {});
  }

  heartbeat = setInterval(() => {
    if (current) write(current.state, current.session, current.turn, true);
  }, 2000);
  heartbeat.unref?.();

  return {
    write,
    clear,
    dispose: () => {
      active = false;
      clearInterval(heartbeat);
      clear();
    },
  };
}

// OpenCode v1 TUI hooks. `setup` runs in the TUI, not the shared server,
// so the selected conversation can be attributed to this terminal slot.
function setup(api) {
  if (!enabled || !api?.data?.listen || !api?.ui?.router) return;
  const output = reporter();
  let selected;
  let state = "idle";
  const turns = new Map();
  let blockers = new Map();
  const changes = new Map();
  const parents = new Map();

  function root(id) {
    const seen = new Set();
    while (typeof id === "string" && !seen.has(id)) {
      seen.add(id);
      const session = api.data.session.get(id);
      if (!session) return parents.get(id) ? root(parents.get(id)) : id;
      if (!session.parentID) return id;
      id = session.parentID;
    }
  }

  function selection() {
    const route = api.ui.router.current();
    return route.type === "session" ? root(route.sessionID) : undefined;
  }

  function publish() {
    if (selected) output.write(blockers.size ? "blocked" : state, selected, turns.get(selected) ?? 0);
    else output.write("unknown", "none", 0);
  }

  function reconcile() {
    if (!selected) return;
    const next = new Map();
    for (const id of [selected, ...(api.data.session.family(selected) ?? [])]) {
      for (const kind of ["permission", "form"]) {
        const items = api.data.session[kind].list(id);
        if (!items) {
          for (const [key, owner] of blockers) if (owner === id && key.startsWith(`${kind}:`)) next.set(key, id);
          continue;
        }
        for (const item of items) next.set(`${kind}:${item.id}`, id);
        for (const [key, change] of changes) {
          if (change.id !== id || change.kind !== kind) continue;
          if (next.has(key) === change.present) changes.delete(key);
          else if (change.present) next.set(key, id);
          else next.delete(key);
        }
      }
    }
    blockers = next;
  }

  function sync() {
    const id = selection();
    if (id !== selected) {
      selected = id;
      blockers.clear();
      changes.clear();
      state = id && api.data.session.status(id) === "running" ? "working" : "idle";
    }
    if (!selected) { publish(); return; }
    reconcile();
    publish();
  }

  const unsubscribe = api.data.listen(({ details: event }) => {
    const data = event?.data;
    if (!data) return;
    if (event.type === "session.created" && data.sessionID && data.parentID) {
      parents.set(data.sessionID, data.parentID);
    }
    sync();
    if (!selected || root(data.sessionID ?? data.form?.sessionID) !== selected) return;
    let kind, requestID, present;
    switch (event.type) {
      case "permission.asked": kind = "permission"; requestID = data.id; present = true; break;
      case "permission.replied": kind = "permission"; requestID = data.requestID; present = false; break;
      case "form.created": kind = "form"; requestID = data.form?.id; present = true; break;
      case "form.replied":
      case "form.cancelled": kind = "form"; requestID = data.id; present = false; break;
      case "session.execution.started": if (data.sessionID === selected) state = "working"; break;
      case "session.execution.succeeded":
      case "session.execution.interrupted":
      case "session.execution.failed":
        if (data.sessionID === selected) {
          state = "idle";
          turns.set(selected, (turns.get(selected) ?? 0) + 1);
        }
        break;
      default: return;
    }
    if (kind && typeof requestID === "string") {
      const key = `${kind}:${requestID}`;
      changes.set(key, { id: data.sessionID ?? data.form?.sessionID, kind, present });
      if (present) blockers.set(key, data.sessionID);
      else blockers.delete(key);
    }
    publish();
  });
  sync();
  const timer = setInterval(sync, 250);
  timer.unref?.();
  return () => {
    clearInterval(timer);
    unsubscribe();
    output.dispose();
  };
}

// OpenCode v2 uses a TUI plugin entrypoint. Keep the same per-TUI ownership.
async function tui(api) {
  if (!enabled) return;
  const output = reporter();
  const route = () => api.route.current;
  const turns = new Map();
  const active = new Map();
  function sync() {
    const current = route();
    const id = current?.name === "session" ? current.params?.sessionID : undefined;
    const session = id && api.state.session.get(id);
    if (!session || session.parentID) {
      output.write("unknown", "none", 0);
      return;
    }
    const blocked = api.state.session.permission(id).length || api.state.session.question(id).length;
    const status = api.state.session.status(id);
    const state = blocked ? "blocked" : status?.type === "busy" || status?.type === "retry" ? "working" : "idle";
    if (state === "working") active.set(id, true);
    if (state === "idle" && active.get(id)) {
      turns.set(id, (turns.get(id) ?? 0) + 1);
      active.delete(id);
    }
    output.write(state, id, turns.get(id) ?? 0);
  }
  const timer = setInterval(sync, 300);
  timer.unref?.();
  sync();
  api.lifecycle.onDispose(() => {
    clearInterval(timer);
    output.dispose();
  });
}

export default { id: "nvim.agent-dashboard", setup, tui };
