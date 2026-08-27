import fs from "node:fs";
import os from "node:os";
import path from "node:path";

import { describe, expect, it } from "vitest";

import { quarantineControllerLock, reconcileClosedPane, windowsDrivePath } from "./controller";

describe("execution inspector dismissal", () => {
  it("suppresses only the binding whose companion the user closed", () => {
    const state = {
      tabs: {
        "tab-a": { inspectorPaneId: "inspector-a", bindingKey: "session-a:wr-a" },
      },
    };
    reconcileClosedPane(state, { event: "pane_closed", data: { pane_id: "inspector-a" } });
    expect(state.tabs["tab-a"]).toEqual({
      inspectorPaneId: undefined,
      bindingKey: "session-a:wr-a",
      suppressedBindingKey: "session-a:wr-a",
    });
  });

  it("does not suppress a companion removed after its binding disappeared", () => {
    const state = {
      tabs: {
        "tab-a": { inspectorPaneId: "inspector-a", bindingKey: "session-a:wr-a", ownerPaneId: "pane-a" },
      },
    };
    reconcileClosedPane(
      state,
      { event: "pane_closed", data: { pane_id: "inspector-a" } },
      { panes: [{ pane_id: "pane-a", tab_id: "tab-a", workspace_id: "workspace-a" }] },
    );
    expect(state.tabs["tab-a"]).toEqual({
      inspectorPaneId: undefined,
      bindingKey: "session-a:wr-a",
      ownerPaneId: "pane-a",
    });
  });

  it("reopens an inspector that exited instead of treating it as dismissed", () => {
    const state = {
      tabs: {
        "tab-a": { inspectorPaneId: "inspector-a", bindingKey: "session-a:wr-a" },
      },
    };
    reconcileClosedPane(state, { event: "pane_exited", data: { pane_id: "inspector-a" } });
    reconcileClosedPane(state, { event: "pane_closed", data: { pane_id: "inspector-a" } });
    expect(state.tabs["tab-a"]).toEqual({
      inspectorPaneId: undefined,
      failedInspectorPaneId: undefined,
      bindingKey: "session-a:wr-a",
    });
  });
});

describe("controller lock recovery", () => {
  it("does not remove a replacement after another controller fences the stale owner", () => {
    const directory = fs.mkdtempSync(path.join(os.tmpdir(), "sympp-herdr-lock-"));
    const lockPath = path.join(directory, "controller.lock");
    try {
      fs.writeFileSync(lockPath, "stale-owner");
      quarantineControllerLock(lockPath, "stale-owner");
      fs.writeFileSync(lockPath, "replacement-owner");
      quarantineControllerLock(lockPath, "stale-owner");
      expect(fs.readFileSync(lockPath, "utf8")).toBe("replacement-owner");
    } finally {
      fs.rmSync(directory, { recursive: true, force: true });
    }
  });

  it("does not remove a replacement through a stale owner observation", () => {
    const directory = fs.mkdtempSync(path.join(os.tmpdir(), "sympp-herdr-lock-"));
    const lockPath = path.join(directory, "controller.lock");
    try {
      fs.writeFileSync(lockPath, "replacement-owner");
      quarantineControllerLock(lockPath, "stale-owner");
      expect(fs.readFileSync(lockPath, "utf8")).toBe("replacement-owner");
    } finally {
      fs.rmSync(directory, { recursive: true, force: true });
    }
  });
});

describe("plugin pane path", () => {
  it("gives the Windows pane launcher a drive path", () => {
    expect(windowsDrivePath("\\\\?\\C:\\Code\\symphony-plus-plus")).toBe("C:\\Code\\symphony-plus-plus");
    expect(windowsDrivePath("/code/symphony-plus-plus")).toBe("/code/symphony-plus-plus");
  });
});
