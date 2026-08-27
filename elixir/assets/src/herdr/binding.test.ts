import { describe, expect, it } from "vitest";

import { bindingFromPane, exactWorkerPaneId } from "./binding";
import { socketEndpoint } from "./herdr-client";
import type { HerdrPane, HerdrSnapshot } from "./types";

describe("Herdr Symphony++ binding", () => {
  it("accepts only exact architect or coordinator bindings", () => {
    expect(bindingFromPane(pane("architect"))?.workRequestId).toBe("wr-1");
    expect(bindingFromPane(pane("worker"))).toBeUndefined();
    expect(bindingFromPane({ ...pane("architect"), agent_session: undefined })).toBeUndefined();
  });

  it("focuses a worker only when its exact Codex session has one live pane", () => {
    const snapshot = { panes: [pane("worker", "pane-a", "session-a")] } as HerdrSnapshot;
    const sessions = [{ work_package_id: "wp-a", agent_session_id: "session-a" }];
    expect(exactWorkerPaneId(snapshot, sessions, "wp-a")).toBe("pane-a");
    snapshot.panes.push(pane("worker", "pane-b", "session-a"));
    expect(exactWorkerPaneId(snapshot, sessions, "wp-a")).toBeUndefined();
  });

  it("maps the Windows marker path to Herdr's named pipe endpoint", () => {
    expect(socketEndpoint("C:\\herdr\\session.sock", "win32")).toBe("\\\\.\\pipe\\C:\\herdr\\session.sock");
  });
});

function pane(role: string, paneId = "pane-a", session = "session-a"): HerdrPane {
  return {
    pane_id: paneId,
    tab_id: "tab-a",
    workspace_id: "workspace-a",
    agent_session: { agent: "codex", value: session },
    tokens: {
      sympp_role: role,
      sympp_show_inspector: "true",
      sympp_work_request_id: "wr-1",
      sympp_endpoint: "http://127.0.0.1:19998",
    },
  };
}
