import { describe, expect, it } from "vitest";

import { shouldAutoCloseTopPanel } from "./dashboard-shell";

describe("dashboard shell", () => {
  it("auto-closes an open attention tray only when loaded counts drop to zero", () => {
    const loaded = (guidance: number, blockers: number) => ({ blockers, guidance, ready: true });
    const loading = { blockers: 0, guidance: 0, ready: false };

    expect(shouldAutoCloseTopPanel("guidance", loaded(1, 1), loaded(0, 1))).toBe(true);
    expect(shouldAutoCloseTopPanel("blockers", loaded(1, 1), loaded(1, 0))).toBe(true);
    expect(shouldAutoCloseTopPanel("guidance", loaded(0, 1), loaded(0, 1))).toBe(false);
    expect(shouldAutoCloseTopPanel("guidance", loading, loaded(0, 1))).toBe(false);
    expect(shouldAutoCloseTopPanel(null, loaded(1, 1), loaded(0, 0))).toBe(false);
  });
});
