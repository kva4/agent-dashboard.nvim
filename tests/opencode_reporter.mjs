import assert from "node:assert/strict";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { setTimeout as delay } from "node:timers/promises";
import { test } from "node:test";

test("v2 plugin directory provides the local tui entrypoint", async () => {
  const directory = new URL("../extras/opencode/", import.meta.url);
  const manifest = JSON.parse(await readFile(new URL("package.json", directory), "utf8"));
  assert.equal(manifest.exports["./tui"], "./tui.js");
  const entrypoint = await readFile(new URL("tui.js", directory), "utf8");
  assert.match(entrypoint, /export \{ default \} from "\.\/agent-dashboard-tui\.js"/);
});

test("sub-agent requests block the owning session until all are resolved", async () => {
  const directory = await mkdtemp(path.join(os.tmpdir(), "agent-dashboard-"));
  process.env.NVIM_AGENT_SLOT = "101";
  process.env.NVIM_AGENT_DASHBOARD_DIR = directory;
  const source = (await readFile(new URL("../extras/opencode/agent-dashboard-tui.js", import.meta.url), "utf8"))
    .replace('import { Plugin } from "@opencode/plugin/tui";', 'const Plugin = { define: (plugin) => plugin };');
  const { default: plugin } = await import(`data:text/javascript;base64,${Buffer.from(source).toString("base64")}`);
  const sessions = new Map([
    ["main", { id: "main", directory }],
    ["child", { id: "child", parentID: "main" }],
    ["nested", { id: "nested", parentID: "child" }],
    ["other", { id: "other" }],
  ]);
  const permissions = new Map();
  const questions = new Map();
  const statuses = new Map([["main", { type: "busy" }]]);
  let onEvent, dispose;
  let unsubscribed = false;
  const api = {
    ui: { router: { current: () => ({ type: "session", sessionID: selected }) } },
    data: { session: {
      get: (id) => sessions.get(id),
      permission: { list: (id) => permissions.get(id) ?? [] },
      form: { list: (id) => questions.get(id) ?? [] },
      status: (id) => statuses.get(id)?.type === "busy" ? "running" : "idle",
      family: (id) => [...sessions.keys()].filter((child) => {
        if (child === id) return false;
        let parent = sessions.get(child)?.parentID;
        while (parent) {
          if (parent === id) return true;
          parent = sessions.get(parent)?.parentID;
        }
        return false;
      }),
    }, listen: (callback) => {
      onEvent = callback;
      return () => { unsubscribed = true; };
    } },
  };
  let selected = "main";
  const emit = (type, data) => onEvent({ details: { type, data } });
  async function expect(state, session = "main", turn = 0) {
    // Let at least one polling cycle observe the latest state, including cases
    // where the expected report should remain unchanged.
    await delay(350);
    for (let attempt = 0; attempt < 100; attempt++) {
      try {
        const report = JSON.parse(await readFile(path.join(directory, "101.json"), "utf8"));
        if (report.state === state && report.session === session && report.turn === turn) return;
      } catch {}
      await delay(20);
    }
    assert.fail(`Expected ${session} to report ${state}, turn ${turn}`);
  }
  try {
    // Already-pending nested requests must be discovered when the plugin starts.
    permissions.set("nested", [{ id: "access" }]);
    dispose = plugin.setup(api);
    await expect("blocked");
    permissions.clear();
    await expect("working");
    permissions.set("child", [{ id: "access-2" }]);
    questions.set("nested", [{ id: "question" }]);
    await expect("blocked");
    permissions.clear();
    await expect("blocked");
    questions.clear();
    await expect("working");

    // New children can request access before their session enters the state cache.
    permissions.set("new-child", [{ id: "access-3" }]);
    emit("session.created", { sessionID: "new-child", parentID: "main" });
    emit("permission.asked", { sessionID: "new-child", id: "access-3" });
    await expect("blocked");
    permissions.clear();
    emit("permission.replied", { sessionID: "new-child", requestID: "access-3" });
    sessions.set("new-child", { id: "new-child", parentID: "main" });
    await expect("working");
    permissions.set("other", [{ id: "unrelated" }]);
    selected = "nested";
    await expect("working");
    statuses.set("main", { type: "idle" });
    emit("session.execution.succeeded", { sessionID: "main" });
    await expect("idle", "main", 1);
    selected = "other";
    await expect("blocked", "other");
  } finally {
    dispose?.();
    assert.equal(unsubscribed, true);
    await delay(50);
    await rm(directory, { recursive: true, force: true });
  }
});
