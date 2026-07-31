import { afterEach, describe, expect, it, vi } from "vitest";

import { DASHBOARD_UI_STATE_KEY } from "./runtime";
import { readStoredFocusBoardSectionOpen, readStoredUseFocusBoard, writeStoredFocusBoardSectionOpen, writeStoredUseFocusBoard } from "./dashboard-persistence";

describe("Focus Board disclosure persistence", () => {
  afterEach(() => vi.unstubAllGlobals());

  it("stores each lane without replacing unrelated dashboard preferences", () => {
    let stored = JSON.stringify({ workspaceTab: "solo" });
    vi.stubGlobal("window", {
      localStorage: {
        getItem: (key: string) => key === DASHBOARD_UI_STATE_KEY ? stored : null,
        setItem: (key: string, value: string) => {
          if (key === DASHBOARD_UI_STATE_KEY) stored = value;
        },
      },
    });

    expect(readStoredFocusBoardSectionOpen("next", false)).toBe(false);
    writeStoredFocusBoardSectionOpen("next", true);

    expect(readStoredFocusBoardSectionOpen("next", false)).toBe(true);
    expect(JSON.parse(stored)).toEqual({ workspaceTab: "solo", focusBoardSections: { next: true } });
  });
});

describe("Focus Board setting persistence", () => {
  afterEach(() => vi.unstubAllGlobals());

  it("defaults off and preserves unrelated dashboard preferences when enabled", () => {
    let stored = JSON.stringify({ workspaceTab: "workstreams" });
    vi.stubGlobal("window", {
      localStorage: {
        getItem: (key: string) => key === DASHBOARD_UI_STATE_KEY ? stored : null,
        setItem: (key: string, value: string) => {
          if (key === DASHBOARD_UI_STATE_KEY) stored = value;
        },
      },
    });

    expect(readStoredUseFocusBoard()).toBe(false);
    writeStoredUseFocusBoard(true);

    expect(readStoredUseFocusBoard()).toBe(true);
    expect(JSON.parse(stored)).toEqual({ workspaceTab: "workstreams", useFocusBoard: true });
  });
});
