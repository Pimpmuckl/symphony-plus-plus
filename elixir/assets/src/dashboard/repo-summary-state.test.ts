import { describe, expect, it } from "vitest";

import type { RepoSummary } from "./dashboard-data";
import type { WorkstreamCategoryCounts } from "./dashboard-state";
import { REPO_SUMMARY_PLATE_WIDTH_VAR_BY_KEY, repoSummaryMetrics, repoSummaryPlateWidthForMetrics } from "./repo-summary-state";

describe("repo summary state", () => {
  it("builds the rendered repo summary labels that drive shared plate sizing", () => {
    const repo: RepoSummary = {
      repoKey: "repo-summary",
      repo: "repo-summary",
      baseBranches: ["main"],
      requested: 0,
      active: 0,
      implementing: 0,
      finished: 0,
      guidanceCount: 2,
      blockerCount: 1,
      packages: [],
      requests: [],
    };
    const categoryCounts: WorkstreamCategoryCounts = {
      requests: 3,
      planNodes: 12,
      slices: 46,
    };

    expect(repoSummaryMetrics(repo, categoryCounts).map((metric) => `${metric.value} ${metric.label}`)).toEqual([
      "3 Requests",
      "12 Plan Nodes",
      "46 WorkPackages",
      "2 Guidance Needed",
      "1 Active Blockers",
    ]);
    expect(repoSummaryMetrics(repo, categoryCounts).map((item) => [item.key, item.group, item.tone])).toEqual([
      ["requests", "progress", "requested"],
      ["planNodes", "progress", "implementing"],
      ["slices", "progress", "active"],
      ["guidance", "attention", "guidance"],
      ["blockers", "attention", "blocker"],
    ]);
    expect(REPO_SUMMARY_PLATE_WIDTH_VAR_BY_KEY).toEqual({
      requests: "--v3-repo-plate-requests-width",
      planNodes: "--v3-repo-plate-plan-nodes-width",
      slices: "--v3-repo-plate-slices-width",
      guidance: "--v3-repo-plate-guidance-width",
      blockers: "--v3-repo-plate-blockers-width",
    });
  });

  it("sizes repo plates per metric key and only widens the affected count category", () => {
    const baseRepo = repoSummary({ blockerCount: 3, guidanceCount: 0 });
    const busyRepo = repoSummary({ blockerCount: 120, guidanceCount: 0 });
    const baseCounts: WorkstreamCategoryCounts = { requests: 6, planNodes: 0, slices: 64 };

    const metrics = [...repoSummaryMetrics(baseRepo, baseCounts), ...repoSummaryMetrics(busyRepo, baseCounts)];

    expect(widthFor(metrics, "requests")).toBe("6.03rem");
    expect(widthFor(metrics, "planNodes")).toBe("6.72rem");
    expect(widthFor(metrics, "slices")).toBe("5.01rem");
    expect(widthFor(metrics, "guidance")).toBe("8.93rem");
    expect(widthFor(metrics, "blockers")).toBe("8.79rem");
  });
});

function widthFor(metrics: ReturnType<typeof repoSummaryMetrics>, key: "requests" | "planNodes" | "slices" | "guidance" | "blockers") {
  return repoSummaryPlateWidthForMetrics(
    key,
    metrics.filter((metric) => metric.key === key),
  );
}

function repoSummary({ blockerCount, guidanceCount }: { blockerCount: number; guidanceCount: number }): RepoSummary {
  return {
    repoKey: `repo-summary-${blockerCount}-${guidanceCount}`,
    repo: "repo-summary",
    baseBranches: ["main"],
    requested: 0,
    active: 0,
    implementing: 0,
    finished: 0,
    guidanceCount,
    blockerCount,
    packages: [],
    requests: [],
  };
}
