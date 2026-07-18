import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";

import { workRequestExecutionGraphModel } from "@/dashboard/execution-graph/adapter";
import { buildExecutionGraphLayout } from "@/dashboard/execution-graph/model";
import type { WorkRequestExecutionGraphModel } from "@/dashboard/execution-graph/model";
import { WorkRequestExecutionGraph } from "@/dashboard/work-request-execution-graph";
import type { WorkRequestDetail } from "@/types/dashboard";

describe("WorkRequestExecutionGraph", () => {
  it("maps backend graph and DeliveryBoard fields without recomputing graph semantics", () => {
    const detail: WorkRequestDetail = {
      work_request: { id: "wr-adapter", title: "Adapter fixture" },
      work_packages: [
        { id: "wp-active", work_request_id: "wr-adapter", product_tree_node_id: "group-a", sequence: 1, title: "Active", status: "implementing" },
        { id: "wp-old", work_request_id: "wr-adapter", product_tree_node_id: "group-a", sequence: 2, title: "Old", status: "implementing" },
      ],
      product_tree: {
        available: true,
        nodes: [{ id: "group-a", title: "Group A", work_package_ids: ["wp-active", "wp-old"] }],
        execution_graph: {
          available: true,
          work_package_ids: ["wp-active", "wp-old"],
          effective_edges: [{ prerequisite_work_package_id: "wp-active", dependent_work_package_id: "wp-old", dependency_ids: ["edge-a"] }],
          topological_order: ["wp-active", "wp-old"],
          cycles: [["wp-old"], ["wp-active", "wp-old"]],
        },
      },
      delivery_board: {
        work_packages: [
          {
            id: "wp-active",
            operational_state: { key: "implementing", label: "Implementing", tone: "info" },
            work_package: {
              id: "wp-active",
              title: "Active projection",
              raw_status: "implementing",
              worker_signal: { status: "active", run_label: "fixture-worker" },
              dependency_signal: { satisfied: 0, required: 0, active: 0, blocked: 0, unmet_work_package_ids: [], inputs: [] },
            },
          },
          { id: "wp-old", delivery_outcome: "superseded", work_package: { id: "wp-old", raw_status: "implementing" } },
        ],
      },
    };

    const active = workRequestExecutionGraphModel(detail);
    const all = workRequestExecutionGraphModel(detail, { includeHistorical: true });

    expect(active.groups).toEqual([{ id: "group-a", title: "Group A", work_package_ids: ["wp-active", "wp-old"] }]);
    expect(active.work_packages).toEqual([
      expect.objectContaining({ id: "wp-active", group_id: "group-a", title: "Active projection", worker_signal: { status: "active", run_label: "fixture-worker" } }),
    ]);
    expect(active.effective_edges).toEqual(detail.product_tree?.execution_graph?.effective_edges);
    expect(active.topological_order).toEqual(["wp-active", "wp-old"]);
    expect(active.cycles).toEqual([["wp-active", "wp-old"]]);
    expect(all.work_packages.map((item) => item.id)).toEqual(["wp-active", "wp-old"]);
    expect(all.cycles).toEqual([["wp-old"], ["wp-active", "wp-old"]]);
  });

  it("lays out the backend topological order left-to-right on desktop and top-to-bottom on mobile", () => {
    const desktop = buildExecutionGraphLayout(graphFixture, "desktop");
    const mobile = buildExecutionGraphLayout(graphFixture, "mobile");
    const desktopPoints = points(desktop.positions);

    expect(desktop.ids).toEqual(["wp-a", "wp-b", "wp-c", "wp-d", "wp-e"]);
    expect(desktopPoints["wp-a"].x).toBeLessThan(desktopPoints["wp-b"].x);
    expect(desktopPoints["wp-b"].x).toBe(desktopPoints["wp-c"].x);
    expect(desktopPoints["wp-b"].x).toBeLessThan(desktopPoints["wp-d"].x);
    expect(mobile.positions.map((point) => point.id)).toEqual(desktop.ids);
    expect(mobile.positions.map((point) => point.y)).toEqual([...mobile.positions.map((point) => point.y)].sort((a, b) => a - b));
  });

  it("bounds nested Groups around their descendants without absorbing ungrouped packages", () => {
    const model = buildExecutionGraphLayout(graphFixture, "desktop");
    const parent = model.groupBounds.find((group) => group.id === "group-parent");
    const child = model.groupBounds.find((group) => group.id === "group-child");
    const ungrouped = model.positions.find((point) => point.id === "wp-d");

    expect(parent).toMatchObject({ title: "Build", nestingDepth: 0 });
    expect(child).toMatchObject({ title: "Verification", nestingDepth: 1 });
    expect(parent && child && parent.x <= child.x && parent.x + parent.width >= child.x + child.width).toBe(true);
    expect(parent && ungrouped && ungrouped.x >= parent.x + parent.width).toBe(true);
  });

  it("splits a Group region rather than enclosing an unrelated package between its members", () => {
    const graph: WorkRequestExecutionGraphModel = {
      groups: [{ id: "split", title: "Split", work_package_ids: ["first", "last"] }],
      work_packages: [{ id: "first" }, { id: "outside" }, { id: "last" }],
      topological_order: ["first", "outside", "last"],
      effective_edges: [
        { prerequisite_work_package_id: "first", dependent_work_package_id: "outside" },
        { prerequisite_work_package_id: "outside", dependent_work_package_id: "last" },
      ],
    };
    const model = buildExecutionGraphLayout(graph, "desktop");
    const outside = model.positions.find((point) => point.id === "outside")!;

    expect(model.groupBounds.filter((bound) => bound.id === "split")).toHaveLength(2);
    expect(model.groupBounds.some((bound) => cardOverlaps(bound, outside))).toBe(false);
  });

  it("reserves visible padding between a parent Group and its child-only region", () => {
    const graph: WorkRequestExecutionGraphModel = {
      groups: [
        { id: "parent", title: "Parent" },
        { id: "child", parent_group_id: "parent", title: "Child", work_package_ids: ["wp"] },
      ],
      work_packages: [{ id: "wp" }],
      topological_order: ["wp"],
    };
    const bounds = buildExecutionGraphLayout(graph, "desktop").groupBounds;
    const parent = bounds.find((bound) => bound.id === "parent")!;
    const child = bounds.find((bound) => bound.id === "child")!;

    expect(parent.x).toBeLessThan(child.x);
    expect(parent.width).toBeGreaterThan(child.width);
  });

  it("keeps deeply nested Group padding inside the fixed card gaps", () => {
    const graph: WorkRequestExecutionGraphModel = {
      groups: [
        { id: "g0", title: "G0" },
        { id: "g1", parent_group_id: "g0", title: "G1" },
        { id: "g2", parent_group_id: "g1", title: "G2" },
        { id: "g3", parent_group_id: "g2", title: "G3", work_package_ids: ["member"] },
      ],
      work_packages: [{ id: "member", group_id: "g3" }, { id: "outside" }],
      topological_order: ["member", "outside"],
    };
    const model = buildExecutionGraphLayout(graph, "desktop");
    const outside = model.positions.find((point) => point.id === "outside")!;

    expect(model.groupBounds.every((bound) => bound.x >= 0 && bound.y >= 0)).toBe(true);
    expect(model.groupBounds.some((bound) => cardOverlaps(bound, outside))).toBe(false);
  });

  it("renders fan-out and one segmented N/M join rail for a multi-input target", () => {
    const html = render();
    const mobile = html.slice(html.indexOf('data-orientation="mobile"'));

    expect(html.match(/data-edge="wp-a:wp-b"/g)).toHaveLength(2);
    expect(html.match(/data-edge="wp-a:wp-c"/g)).toHaveLength(2);
    expect(html.match(/data-join-for="wp-d"/g)).toHaveLength(2);
    expect(html.match(/data-progress="1\/2"/g)).toHaveLength(2);
    expect(html).toContain('data-input="wp-b" data-state="active"');
    expect(html).toContain('data-input="wp-c" data-state="blocked"');
    expect(edgeTag(html, "wp-a:wp-b")).toContain('data-state="waiting"');
    expect(edgeTag(mobile, "wp-b:wp-d")).toContain('data-route="gutter"');
    expect(edgeTag(mobile, "wp-c:wp-d")).toContain('data-route="direct"');
    expect(html).not.toContain("execution-graph__column-header");
  });

  it("keeps high-fan-in desktop joins within the target card edge", () => {
    const prerequisiteIds = Array.from({ length: 20 }, (_, index) => `input-${index}`);
    const graph: WorkRequestExecutionGraphModel = {
      work_packages: [...prerequisiteIds.map((id) => ({ id })), { id: "target" }],
      topological_order: [...prerequisiteIds, "target"],
      effective_edges: prerequisiteIds.map((id) => ({ prerequisite_work_package_id: id, dependent_work_package_id: "target" })),
    };
    const model = buildExecutionGraphLayout(graph, "desktop");
    const target = model.positions.find((point) => point.id === "target")!;
    const html = renderToStaticMarkup(<WorkRequestExecutionGraph model={graph} />).split('data-orientation="mobile"')[0];
    const targetYs = prerequisiteIds.map((id) => pathEnd(edgeTag(html, `${id}:target`)).y);

    expect(Math.min(...targetYs)).toBeGreaterThan(target.y);
    expect(Math.max(...targetYs)).toBeLessThan(target.y + 240);
  });

  it("prioritizes an exact wait reason, active worker elapsed time, then optional delivery signals", () => {
    const html = render();
    const card = firstCard(html, "wp-d");
    const reason = card.indexOf('data-priority="reason"');
    const worker = card.indexOf('data-priority="worker"');
    const pr = card.indexOf('data-signal="pr"');
    const review = card.indexOf('data-signal="review"');
    const checks = card.indexOf('data-signal="checks"');

    expect(card).toContain("Waiting for the fixture review to pass.");
    expect(card).toContain("worker-7 · 1h 30m");
    expect(card).toContain("PR #514 Open");
    expect(card).toContain("Review github 4/4 · In progress");
    expect(card).toContain("Checks 3/4 · Failing");
    expect([reason, worker, pr, review, checks]).toEqual([...new Set([reason, worker, pr, review, checks])].sort((a, b) => a - b));
  });

  it("keeps long titles, dependency states, Groups, and cards accessible without dead tab stops or empty signal chrome", () => {
    const simpleGraph: WorkRequestExecutionGraphModel = {
      work_packages: [{ id: "long", title: longTitle, status: "planned" }],
      topological_order: ["long"],
      effective_edges: [],
    };
    const html = renderToStaticMarkup(<WorkRequestExecutionGraph model={simpleGraph} />);

    expect(html).toContain(`title="${longTitle}"`);
    expect(html).toContain('<article class="execution-graph__card"');
    expect(firstCard(html, "long")).not.toContain('tabindex="0"');
    expect(renderToStaticMarkup(<WorkRequestExecutionGraph model={simpleGraph} onSelectWorkPackage={() => {}} />)).toContain('role="button" tabindex="0"');
    expect(html).toContain("No prerequisites.");
    expect(html).not.toContain("execution-graph__signals");
    expect(render()).toContain('data-group-id="group-parent"');
    expect(firstCard(render(), "wp-b")).toContain("Group path Build › Verification");
    const interactive = renderToStaticMarkup(
      <WorkRequestExecutionGraph model={graphFixture} onSelectWorkPackage={() => {}} />,
    );
    expect(firstCard(interactive, "wp-d")).toContain("PR #514 Open. Review github 4/4 · In progress. Checks 3/4 · Failing.");
  });

  it("gives blocked and completed states precedence over active or waiting status words", () => {
    const graph: WorkRequestExecutionGraphModel = {
      work_packages: [
        { id: "passed", title: "Passed review", status: "review_passed" },
        { id: "ready", title: "Ready merge", status: "ready_for_architect_merge" },
      ],
      topological_order: ["passed", "ready"],
    };
    const html = renderToStaticMarkup(<WorkRequestExecutionGraph model={graph} />);

    expect(firstCard(html, "passed")).toContain('data-state="complete"');
    expect(firstCard(html, "ready")).toContain('data-state="waiting"');
    expect(firstCard(render(), "wp-d")).toContain('data-state="blocked"');
  });

  it("shows stale worker evidence and exposes the scrollable graph to keyboards", () => {
    const graph: WorkRequestExecutionGraphModel = {
      work_packages: [{ id: "stale", worker_signal: { status: "stale", run_label: "worker-9" } }],
      topological_order: ["stale"],
    };
    const html = renderToStaticMarkup(<WorkRequestExecutionGraph model={graph} />);

    expect(firstCard(html, "stale")).toContain("worker-9 · Worker stale");
    expect(html).toContain('role="region" tabindex="0"');
  });

  it("renders unavailable and cyclic projections as explicit non-order states", () => {
    const unavailable = renderToStaticMarkup(
      <WorkRequestExecutionGraph model={{ available: false, work_packages: [{ id: "wp" }], topological_order: ["wp"] }} />,
    );
    const cyclic = renderToStaticMarkup(
      <WorkRequestExecutionGraph model={{ available: true, work_packages: [{ id: "wp" }], topological_order: ["wp"], cycles: [["wp"]] }} />,
    );

    expect(unavailable).toContain("Execution order unavailable");
    expect(unavailable).not.toContain('data-work-package-id="wp"');
    expect(cyclic).toContain("1 dependency cycle must be resolved");
    expect(cyclic).not.toContain("No prerequisites");
  });
});

const longTitle = "Coordinate the exceptionally long renderer package title across narrow viewports without losing its accessible name";

const graphFixture: WorkRequestExecutionGraphModel = {
  available: true,
  groups: [
    { id: "group-parent", title: "Build", position: 0, work_package_ids: ["wp-a"] },
    { id: "group-child", parent_group_id: "group-parent", title: "Verification", position: 0, work_package_ids: ["wp-b", "wp-c"] },
  ],
  work_packages: [
    { id: "wp-a", group_id: "group-parent", sequence: 1, title: "Define contract", status: "merged" },
    { id: "wp-b", group_id: "group-child", sequence: 2, title: "Render cards", status: "implementing" },
    { id: "wp-c", group_id: "group-child", sequence: 3, title: "Project signals", status: "blocked" },
    {
      id: "wp-d",
      sequence: 4,
      title: longTitle,
      status: "reviewing",
      operational_state: { key: "blocked", label: "Review blocked", tone: "danger", reason: "Waiting for the fixture review to pass." },
      worker_signal: { status: "active", active_since: "2026-07-18T08:00:00Z", run_label: "worker-7" },
      pr_signal: {
        status: "open",
        number: 514,
        checks: { status: "failing", current: 3, total: 4 },
      },
      review_signal: { type: "review-github", status: "in_progress", current: 4, total: 4 },
      dependency_signal: {
        satisfied: 1,
        required: 2,
        active: 1,
        blocked: 1,
        unmet_work_package_ids: ["wp-b", "wp-c"],
        inputs: [
          { work_package_id: "wp-b", status: "active" },
          { work_package_id: "wp-c", status: "blocked" },
        ],
      },
    },
    { id: "wp-e", sequence: 5, title: "Publish fixture", status: "planned" },
  ],
  topological_order: ["wp-a", "wp-b", "wp-c", "wp-d", "wp-e"],
  effective_edges: [
    { prerequisite_work_package_id: "wp-a", dependent_work_package_id: "wp-b" },
    { prerequisite_work_package_id: "wp-a", dependent_work_package_id: "wp-c" },
    { prerequisite_work_package_id: "wp-b", dependent_work_package_id: "wp-d" },
    { prerequisite_work_package_id: "wp-c", dependent_work_package_id: "wp-d" },
    { prerequisite_work_package_id: "wp-d", dependent_work_package_id: "wp-e" },
  ],
};

function render() {
  return renderToStaticMarkup(
    <WorkRequestExecutionGraph model={graphFixture} now="2026-07-18T09:30:00Z" />,
  );
}

function points(items: Array<{ id: string; x: number; y: number }>) {
  return Object.fromEntries(items.map((item) => [item.id, item]));
}

function firstCard(html: string, id: string) {
  const start = html.indexOf(`data-work-package-id="${id}"`);
  const end = html.indexOf("</article>", start);
  return html.slice(start, end);
}

function edgeTag(html: string, edge: string) {
  const start = html.indexOf(`data-edge="${edge}"`);
  return html.slice(start, html.indexOf("></path>", start));
}

function pathEnd(path: string) {
  const values = path.match(/-?\d+(?:\.\d+)?/g)?.map(Number) ?? [];
  return { x: values.at(-2)!, y: values.at(-1)! };
}

function cardOverlaps(bound: { x: number; y: number; width: number; height: number }, point: { x: number; y: number }) {
  return point.x < bound.x + bound.width && point.x + 264 > bound.x && point.y < bound.y + bound.height && point.y + 240 > bound.y;
}
