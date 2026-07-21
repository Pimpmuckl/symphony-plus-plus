import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";

import { activeBlockerItems, allPackages, FINISHED_HIGHLIGHT_LIMIT, recentFinishedHighlights, repoSummaries } from "./dashboard-data";
import { RepoSummaryStrip } from "./repo-workstream";
import type { ActiveBlockingEdge, WorkPackageCard, WorkRequestCard, WorkRequestDetail } from "@/types/dashboard";
import type { RepoSummary } from "./dashboard-data";

describe("dashboard data helpers", () => {
  it("caps finished highlights to the most recent records", () => {
    const packages = Array.from({ length: FINISHED_HIGHLIGHT_LIMIT + 4 }, (_, index) =>
      finishedPackage(`pkg-${index}`, new Date(Date.UTC(2026, 5, 4, 12, 0, index)).toISOString()),
    );

    const highlights = recentFinishedHighlights(packages, [], [], new Map(), 3);

    expect(highlights.map((highlight) => highlight.id)).toEqual([
      `pkg-${FINISHED_HIGHLIGHT_LIMIT + 3}`,
      `pkg-${FINISHED_HIGHLIGHT_LIMIT + 2}`,
      `pkg-${FINISHED_HIGHLIGHT_LIMIT + 1}`,
    ]);
  });

  it("preserves finished package highlights when the server limit is null", () => {
    const packages = Array.from({ length: FINISHED_HIGHLIGHT_LIMIT + 4 }, (_, index) =>
      finishedPackage(`pkg-${index}`, new Date(Date.UTC(2026, 5, 4, 12, 0, index)).toISOString()),
    );

    const highlights = recentFinishedHighlights(packages, [], [], new Map(), null);

    expect(highlights).toHaveLength(FINISHED_HIGHLIGHT_LIMIT + 4);
    expect(highlights[0]?.id).toBe(`pkg-${FINISHED_HIGHLIGHT_LIMIT + 3}`);
  });

  it("uses the newest package timestamp when progress predates an update", () => {
    const oldProgressNewUpdate = finishedPackage("pkg-updated", new Date(Date.UTC(2026, 5, 4, 10)).toISOString());
    oldProgressNewUpdate.updated_at = new Date(Date.UTC(2026, 5, 4, 13)).toISOString();
    const progressOnly = finishedPackage("pkg-progress", new Date(Date.UTC(2026, 5, 4, 12)).toISOString());

    const highlights = recentFinishedHighlights([oldProgressNewUpdate, progressOnly], [], [], new Map(), null);

    expect(highlights.map((highlight) => highlight.id)).toEqual(["pkg-updated", "pkg-progress"]);
  });

  it("does not apply the finished package cap to request highlights", () => {
    const request = finishedRequest("wr-finished", new Date(Date.UTC(2026, 5, 4, 13)).toISOString());
    const packages = [
      finishedPackage("pkg-old", new Date(Date.UTC(2026, 5, 4, 11)).toISOString()),
      finishedPackage("pkg-new", new Date(Date.UTC(2026, 5, 4, 12)).toISOString()),
    ];
    const detail = { work_request: request, work_packages: [] } satisfies WorkRequestDetail;

    const highlights = recentFinishedHighlights(packages, [request], [detail], new Map(), 1);

    expect(highlights.map((highlight) => highlight.id)).toEqual(["wr-finished", "pkg-new"]);
  });

  it("builds blocker list items from package-card active blocker details", () => {
    const pkg: WorkPackageCard = {
      id: "pkg-blocked",
      title: "Blocked package",
      status: "blocked",
      active_blocker_count: 1,
      active_blockers: [{ id: "blocker-1", active: true, summary: "Needs scope approval", body: "Review asked for one more file." }],
    };

    const items = activeBlockerItems([pkg]);

    expect(items).toEqual([
      expect.objectContaining({
        id: "active_blocking_edge:pkg-blocked:blocker-1",
        title: "Needs scope approval",
        detail: "Review asked for one more file.",
        selection: expect.objectContaining({
          kind: "blocker",
          blocker: expect.objectContaining({ blocker_id: "blocker-1", work_package_id: "pkg-blocked" }),
          pkg,
        }),
      }),
    ]);
  });

  it("does not create active blocker items from stale blocked package status alone", () => {
    const pkg: WorkPackageCard = {
      id: "pkg-resolved-blocker",
      title: "Resolved blocker package",
      status: "blocked",
      active_blocker_count: 0,
      active_blockers: [{ id: "blocker-1", active: false, summary: "Already resolved" }],
    };

    expect(activeBlockerItems([pkg])).toEqual([]);
  });

  it("keeps blocker list item ids unique across packages", () => {
    const packages: WorkPackageCard[] = [
      {
        id: "pkg-a",
        title: "Package A",
        status: "blocked",
        active_blocker_count: 1,
        active_blockers: [{ id: "blocker-1", active: true, summary: "Shared blocker id" }],
      },
      {
        id: "pkg-b",
        title: "Package B",
        status: "blocked",
        active_blocker_count: 1,
        active_blockers: [{ id: "blocker-1", active: true, summary: "Shared blocker id" }],
      },
    ];

    const ids = activeBlockerItems(packages).map((item) => item.id);

    expect(ids).toEqual(["active_blocking_edge:pkg-a:blocker-1", "active_blocking_edge:pkg-b:blocker-1"]);
  });

  it("keeps package-only blockers when edge-backed blockers exist", () => {
    const pkg: WorkPackageCard = {
      id: "pkg-mixed",
      title: "Mixed blockers",
      status: "blocked",
      active_blocker_count: 2,
      active_blockers: [
        { id: "edge-backed", active: true, summary: "Shown through edge" },
        { id: "package-only", active: true, summary: "Shown from package" },
      ],
    };
    const edge: ActiveBlockingEdge = {
      id: "edge-card",
      blocker_id: "edge-backed",
      from: { kind: "work_package", id: "pkg-source" },
      to: { kind: "work_package", id: pkg.id },
      summary: "Edge blocker",
    };

    const items = activeBlockerItems([pkg], new Map(), [edge]);

    expect(items.map((item) => item.id)).toEqual(["edge-card", "active_blocking_edge:pkg-mixed:package-only"]);
  });

  it("gives anonymous package blockers unique card ids without fake clear ids", () => {
    const pkg: WorkPackageCard = {
      id: "pkg-anonymous",
      title: "Anonymous blockers",
      status: "blocked",
      active_blocker_count: 2,
      active_blockers: [
        { active: true, summary: "First anonymous blocker" },
        { active: true, summary: "Second anonymous blocker" },
      ],
    };

    const items = activeBlockerItems([pkg]);

    expect(items.map((item) => item.id)).toEqual(["active_blocking_edge:pkg-anonymous:0", "active_blocking_edge:pkg-anonymous:1"]);
    expect(items.map((item) => item.selection.kind === "blocker" ? item.selection.blocker.blocker_id : null)).toEqual(["", ""]);
  });

  it("indexes blocker edge cards by the blocked package, not the blocker source", () => {
    const source: WorkPackageCard = { id: "pkg-source", status: "blocked", active_blocker_count: 1 };
    const blocked: WorkPackageCard = { id: "pkg-blocked", status: "blocked", active_blocker_count: 1 };
    const edge: ActiveBlockingEdge = {
      id: "edge-blocked",
      blocker_id: "blocker-blocked",
      from: { kind: "work_package", id: source.id },
      to: { kind: "work_package", id: blocked.id },
      summary: "Blocked package waits on source",
    };

    const items = activeBlockerItems([source, blocked], new Map(), [edge]);

    expect(items.find((item) => item.selection.kind === "package" && item.selection.pkg.id === source.id)?.id).toBe(source.id);
    expect(items.find((item) => item.selection.kind === "blocker" && item.selection.pkg?.id === blocked.id)?.id).toBe(edge.id);
  });

  it("orders specific blocker edges before package-only blocker cards", () => {
    const source: WorkPackageCard = { id: "pkg-source", title: "Source", status: "blocked", active_blocker_count: 1 };
    const blocked: WorkPackageCard = { id: "pkg-blocked", title: "Blocked", status: "blocked", active_blocker_count: 1 };
    const edge: ActiveBlockingEdge = {
      id: "edge-blocked",
      blocker_id: "blocker-blocked",
      from: { kind: "work_package", id: source.id },
      to: { kind: "work_package", id: blocked.id },
      summary: "Blocked waits on source",
    };

    const items = activeBlockerItems([source, blocked], new Map(), [edge]);

    expect(items.map((item) => item.id)).toEqual([edge.id, source.id]);
  });

  it("shows edge-backed blockers even when package status has not caught up", () => {
    const blocked: WorkPackageCard = { id: "pkg-edge-only", title: "Edge-only package", status: "active", active_blocker_count: 0 };
    const edge: ActiveBlockingEdge = {
      id: "edge-only-blocker",
      blocker_id: "blocker-edge-only",
      from: { kind: "work_package", id: "pkg-source" },
      to: { kind: "work_package", id: blocked.id },
      summary: "Edge-only blocker",
    };

    const items = activeBlockerItems([blocked], new Map(), [edge]);

    expect(items).toHaveLength(1);
    expect(items[0]?.id).toBe(edge.id);
  });

  it("keeps linked cross-repo packages with their owning WorkRequest", () => {
    const request: WorkRequestCard = { id: "wr-primary", repo: "primary-repo", base_branch: "main" };
    const linkedPackage: WorkPackageCard = { id: "pkg-child", repo: "child-repo", base_branch: "release" };
    const standalonePackage: WorkPackageCard = { id: "pkg-standalone", repo: "orphan-repo", base_branch: "main" };
    const detail: WorkRequestDetail = {
      work_request: request,
      work_packages: [{ id: "slice-child", work_request_id: request.id, work_package_id: linkedPackage.id, base_branch: "release" }],
    };

    const repos = repoSummaries([linkedPackage, standalonePackage], [request], [], [], [detail]);

    expect(repos).toHaveLength(1);
    expect(repos[0]).toMatchObject({ repo: "primary-repo", baseBranches: ["main"], packages: [linkedPackage] });
  });

  it("counts canonical packages once when board and WorkRequest detail overlap", () => {
    const request: WorkRequestCard = { id: "wr-canonical", repo: "canonical-repo", base_branch: "main" };
    const pkg: WorkPackageCard = { id: "pkg-canonical", title: "Canonical package", status: "implementing" };
    const detail: WorkRequestDetail = {
      work_request: request,
      work_packages: [{ id: pkg.id, work_request_id: request.id, work_package_id: pkg.id, status: pkg.status }],
    };

    const [repo] = repoSummaries([pkg], [request], [], [], [detail]);

    expect(repo?.implementing).toBe(1);
  });

  it("projects compact active WorkRequest slices into package cards without duplicating board cards", () => {
    const request: WorkRequestCard = {
      id: "wr-priority",
      repo: "symphony-plus-plus",
      repo_key: "symphony-plus-plus",
      base_branch: "main",
    };
    const detail: WorkRequestDetail = {
      work_request: request,
      work_packages: [
        {
          id: "slice-priority",
          work_request_id: request.id,
          work_package_id: "pkg-priority",
          title: "Priority package",
          status: "approved",
          work_package_status: "implementing",
          operational_state: { key: "active", label: "Active" },
        },
      ],
    };

    const packages = allPackages({
      board: { groups: { implementing: [{ id: "pkg-existing", title: "Existing package", status: "implementing" }] } },
      work_request_details: [detail],
    });

    expect(packages).toEqual([
      expect.objectContaining({ id: "pkg-existing" }),
      expect.objectContaining({
        id: "pkg-priority",
        repo: "symphony-plus-plus",
        base_branch: "main",
        status: "implementing",
        operational_state: { key: "active", label: "Active" },
      }),
    ]);
  });

  it("hides zero plan and attention plates from repo summaries", () => {
    const repo = repoSummary({ guidanceCount: 0, blockerCount: 0 });
    const html = renderToStaticMarkup(<RepoSummaryStrip repo={repo} categoryCounts={{ requests: 1, planNodes: 0, slices: 2 }} />);

    expect(html).toContain("Requests");
    expect(html).toContain("WorkPackages");
    expect(html).not.toContain("Plan Nodes");
    expect(html).not.toContain("Guidance Needed");
    expect(html).not.toContain("Active Blockers");
  });

  it("shows non-zero plan and attention plates in repo summaries", () => {
    const repo = repoSummary({ guidanceCount: 1, blockerCount: 2 });
    const html = renderToStaticMarkup(<RepoSummaryStrip repo={repo} categoryCounts={{ requests: 1, planNodes: 3, slices: 2 }} />);

    expect(html).toContain("Plan Nodes");
    expect(html).toContain("Guidance Needed");
    expect(html).toContain("Active Blockers");
  });
});

function finishedPackage(id: string, updatedAt: string): WorkPackageCard {
  return {
    id,
    title: id,
    repo: "symphony-plus-plus",
    repo_display: "symphony-plus-plus",
    status: "merged",
    latest_progress_at: updatedAt,
    updated_at: updatedAt,
  };
}

function finishedRequest(id: string, updatedAt: string): WorkRequestCard {
  return {
    id,
    title: id,
    repo: "symphony-plus-plus",
    repo_display: "symphony-plus-plus",
    status: "completed",
    updated_at: updatedAt,
  };
}

function repoSummary(overrides: Partial<RepoSummary>): RepoSummary {
  return {
    active: 0,
    baseBranches: ["main"],
    blockerCount: 0,
    finished: 0,
    guidanceCount: 0,
    implementing: 0,
    packages: [],
    repo: "symphony-plus-plus",
    repoKey: "symphony-plus-plus",
    requested: 0,
    requests: [],
    ...overrides,
  };
}
