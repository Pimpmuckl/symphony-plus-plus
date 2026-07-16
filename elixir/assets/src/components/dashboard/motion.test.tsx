import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";

import { AnimatedBadge, scrambleStatusText } from "./motion";

describe("status badge motion", () => {
  it("scrambles toward the next label and always settles exactly", () => {
    expect(scrambleStatusText("Ready", "Active", 0, () => 0)).toBe("Ready");
    expect(scrambleStatusText("Ready", "Active", 0.5, () => 0)).toBe("AcAAAA");
    expect(scrambleStatusText("Ready", "Active", 1, () => 0)).toBe("Active");
  });

  it("marks only running labels for continuous shimmer", () => {
    const active = renderToStaticMarkup(<AnimatedBadge active label="Active" variant="info" />);
    const ready = renderToStaticMarkup(<AnimatedBadge label="Ready for worker" variant="ready" />);

    expect(active).toContain('<span class="sr-only">Active</span>');
    expect(active).toContain('<span class="status-badge-text-layout">Active</span>');
    expect(active).toContain('data-running="true"');
    expect(active).toContain("status-badge-text-running");
    expect(ready).not.toContain("status-badge-text-running");
  });
});
