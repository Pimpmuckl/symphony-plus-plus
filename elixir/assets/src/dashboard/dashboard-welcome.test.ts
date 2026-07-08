import { describe, expect, it } from "vitest";

import { shouldShowWelcomeDialog } from "./dashboard-welcome";

describe("dashboard welcome dialog", () => {
  it("shows only when the dashboard is ready, enabled, and unseen in this page load", () => {
    expect(shouldShowWelcomeDialog({ ready: true, showWelcomeToast: true, shownThisLoad: false })).toBe(true);
    expect(shouldShowWelcomeDialog({ ready: false, showWelcomeToast: true, shownThisLoad: false })).toBe(false);
    expect(shouldShowWelcomeDialog({ ready: true, showWelcomeToast: false, shownThisLoad: false })).toBe(false);
    expect(shouldShowWelcomeDialog({ ready: true, showWelcomeToast: true, shownThisLoad: true })).toBe(false);
  });
});
