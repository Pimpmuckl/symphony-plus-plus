import { describe, expect, it } from "vitest";

import { snapshotFromResponse } from "./herdr-client";

describe("Herdr client responses", () => {
  it("normalizes a missing snapshot result", () => {
    expect(snapshotFromResponse(undefined)).toEqual({ panes: [] });
    expect(snapshotFromResponse({ snapshot: { focused_pane_id: "pane-a" } })).toEqual({
      focused_pane_id: "pane-a",
      panes: [],
    });
  });
});
