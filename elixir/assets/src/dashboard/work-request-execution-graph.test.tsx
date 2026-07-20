import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";

import { workRequestExecutionGraphModel } from "@/dashboard/execution-graph/adapter";
import { buildExecutionGraphLayout, defaultExpandedGroupIds } from "@/dashboard/execution-graph/model";
import type { WorkRequestExecutionGraphModel } from "@/dashboard/execution-graph/model";
import { graphWireRoutes } from "@/dashboard/execution-graph/router";
import type { WirePath } from "@/dashboard/execution-graph/router";
import { wireMorphs } from "@/dashboard/execution-graph/wires";
import { WorkRequestExecutionGraph } from "@/dashboard/work-request-execution-graph";
import type { WorkRequestDetail } from "@/types/dashboard";

describe("WorkRequestExecutionGraph", () => {
  it("maps original dependency intent and DeliveryBoard state without replacing it with effective edges", () => {
    const detail: WorkRequestDetail = {
      work_request: { id: "wr-adapter", title: "Adapter fixture" },
      work_packages: [
        { id: "wp-active", work_request_id: "wr-adapter", product_tree_node_id: "group-a", title: "Active", status: "implementing" },
        { id: "wp-old", work_request_id: "wr-adapter", product_tree_node_id: "group-a", title: "Old", status: "merged" },
      ],
      product_tree: {
        available: true,
        nodes: [{ id: "group-a", title: "Group A", work_package_ids: ["wp-active", "wp-old"] }],
        dependency_edges: [
          { id: "depends", kind: "depends_on", source: { kind: "work_package", id: "wp-active" }, target: { kind: "product_node", id: "group-a" } },
          { id: "blocks", kind: "blocks", source: { kind: "product_node", id: "group-a" }, target: { kind: "work_package", id: "wp-old" } },
        ],
        execution_graph: {
          available: true,
          work_package_ids: ["wp-active", "wp-old"],
          effective_edges: [{ prerequisite_work_package_id: "wp-old", dependent_work_package_id: "wp-active", dependency_ids: ["expanded"] }],
          topological_order: ["wp-old", "wp-active"],
        },
      },
      delivery_board: {
        work_packages: [
          {
            id: "wp-active",
            operational_state: { key: "implementing", label: "Implementing", tone: "info" },
            work_package: { id: "wp-active", title: "Active projection", raw_status: "implementing", worker_signal: { status: "active", run_label: "fixture-worker" } },
          },
          { id: "wp-old", delivery_outcome: "superseded", work_package: { id: "wp-old", raw_status: "merged" } },
        ],
      },
    };

    const active = workRequestExecutionGraphModel(detail);
    const all = workRequestExecutionGraphModel(detail, { includeHistorical: true });

    expect(active.work_packages).toEqual([
      expect.objectContaining({ id: "wp-active", group_id: "group-a", title: "Active projection", worker_signal: { status: "active", run_label: "fixture-worker" } }),
    ]);
    expect(active.dependency_intents).toEqual([
      { id: "depends", prerequisite: { kind: "group", id: "group-a" }, dependent: { kind: "work_package", id: "wp-active" } },
      { id: "blocks", prerequisite: { kind: "group", id: "group-a" }, dependent: { kind: "work_package", id: "wp-old" } },
    ]);
    expect(active.effective_edges).toEqual(detail.product_tree?.execution_graph?.effective_edges);
    expect(all.work_packages.map((item) => item.id)).toEqual(["wp-active", "wp-old"]);
  });

  it("uses Groups as the root graph entities and gives dependent roots greater desktop depth", () => {
    const model = buildExecutionGraphLayout(graphFixture, "desktop");
    const source = rect(model, "group:source");
    const workers = rect(model, "group:workers");
    const output = rect(model, "group:output");

    expect(source.x).toBeLessThan(workers.x);
    expect(workers.x).toBeLessThan(output.x);
    expect(rect(model, "work_package:parse").parent_group_id).toBe("workers");
    expect(model.rects.some((item) => item.key === "work_package:snapshot")).toBe(false);
  });

  it("packs roots row-major while keeping newly unlocked work beside its prerequisite", () => {
    const roots = buildExecutionGraphLayout(affinityGridFixture, "desktop").rects.filter((item) => !item.parent_group_id);

    expect(roots.map((item) => item.key)).toEqual(["group:a", "group:c", "group:b", "group:d"]);
    expect(roots.map(({ row, column }) => [row, column])).toEqual([[0, 0], [0, 1], [0, 2], [1, 0]]);
  });

  it("expands active Groups by default and keeps finished or planned Groups compact", () => {
    expect([...defaultExpandedGroupIds(graphFixture)]).toEqual(["workers"]);
    const model = buildExecutionGraphLayout(graphFixture, "desktop");
    const collapsed = buildExecutionGraphLayout(graphFixture, "desktop", new Set());
    const exiting = buildExecutionGraphLayout(graphFixture, "desktop", new Set(), new Set(["workers"]));

    expect(rect(model, "group:source")).toMatchObject({ expanded: false, height: 62 });
    expect(rect(model, "group:workers")).toMatchObject({ expanded: true });
    expect(rect(model, "group:workers").height).toBeGreaterThan(62);
    expect(rect(model, "group:output")).toMatchObject({ expanded: false, height: 62 });
    expect(exiting.rects.some((item) => item.key === "work_package:parse")).toBe(true);
    expect(exiting.height).toBe(collapsed.height);
  });

  it("keeps group-intent edges on the shell and proxies hidden WP endpoints to their collapsed Group", () => {
    const model = buildExecutionGraphLayout(graphFixture, "desktop");
    const edges = model.dependencies.map((edge) => [edge.source_key, edge.target_key]);
    const collapsedEdges = buildExecutionGraphLayout(graphFixture, "desktop", new Set()).dependencies.map((edge) => [edge.source_key, edge.target_key]);

    expect(edges).toContainEqual(["group:source", "work_package:parse"]);
    expect(edges).toContainEqual(["group:source", "work_package:index"]);
    expect(edges).toContainEqual(["work_package:parse", "group:output"]);
    expect(edges).toContainEqual(["work_package:index", "group:output"]);
    expect(edges).toContainEqual(["group:source", "work_package:playtest"]);
    expect(collapsedEdges).toContainEqual(["group:source", "group:workers"]);
    expect(collapsedEdges).toContainEqual(["group:workers", "group:output"]);
    expect(collapsedEdges.some(([source, target]) => source.includes("work_package:parse") || target.includes("work_package:parse"))).toBe(false);
  });

  it("reveals WP-specific endpoints when a Group expands without moving Group-intent edges off its shell", () => {
    const expanded = new Set(["workers", "output"]);
    const model = buildExecutionGraphLayout(graphFixture, "desktop", expanded);
    const edges = model.dependencies.map((edge) => [edge.source_key, edge.target_key]);

    expect(edges).toContainEqual(["work_package:parse", "work_package:join"]);
    expect(edges).toContainEqual(["work_package:index", "work_package:join"]);
    expect(edges).toContainEqual(["work_package:join", "work_package:publish"]);
    expect(edges).toContainEqual(["group:source", "work_package:playtest"]);
    expect(rect(model, "work_package:join").parent_group_id).toBe("output");
  });

  it("renders one static N/M gate for fan-in and leaves only active paths dashed by state", () => {
    const html = render();

    expect(html.match(/data-join-for="group:output"/g)).toHaveLength(2);
    expect(html.match(/data-progress="0\/2"/g)).toHaveLength(2);
    expect(html).toContain('data-edge="work_package:parse:group:output" data-state="active"');
    expect(html).toContain('data-edge="work_package:index:group:output" data-state="active"');
    expect(html).toContain('class="execution-graph__join-trunk" data-state="waiting"');
    expect(html).not.toContain("execution-graph__group-label");
  });

  it("orders fan-out lanes toward their destinations and routes mixed fan-in around the target", () => {
    const fanoutModel = buildExecutionGraphLayout(graphFixture, "desktop");
    const fanout = graphWireRoutes(fanoutModel, "desktop").paths;
    const tracks = fanoutModel.dependencies
      .filter((dependency) => dependency.source_key === "group:source")
      .sort((left, right) => rect(fanoutModel, left.target_key).y - rect(fanoutModel, right.target_key).y)
      .map((dependency) => firstHorizontalTrack(fanout.find((route) => route.edge === dependency.key)?.path));

    expect(tracks[0]).toBeGreaterThan(tracks[1] as number);
    expect(tracks[1]).toBeGreaterThan(tracks[2] as number);

    const recovery = buildExecutionGraphLayout(recoveryGraphFixture, "desktop");
    const routes = graphWireRoutes(recovery, "desktop");
    const validate = rect(recovery, "work_package:validate");
    const successor = rect(recovery, "work_package:successor");
    const gateX = validate.x - 22;
    const successorPath = routes.paths.find((route) => route.edge === "work_package:successor:work_package:validate")?.path;

    expect(routes.gates.find((gate) => gate.targetKey === "work_package:validate")?.path).toContain(`M ${gateX}`);
    expect(routes.paths.find((route) => route.edge === "group:history:work_package:validate")?.path).toMatch(new RegExp(`H ${gateX}$`));
    expect(successorPath).toMatch(new RegExp(`^M ${successor.x + successor.width} `));
    expect(firstHorizontalTrack(successorPath)).toBeGreaterThan(successor.x + successor.width);
    expect(successorPath).not.toMatch(/ V -/);
    expect(routes.paths.find((route) => route.edge === "work_package:successor:work_package:validate")?.state).toBe("waiting");
  });

  it("keeps a blocker local while its dependent package remains waiting", () => {
    const html = renderToStaticMarkup(<WorkRequestExecutionGraph model={recoveryGraphFixture} />);

    expect(firstCard(html, "successor")).toContain('data-state="blocked"');
    expect(firstCard(html, "validate")).toContain('data-state="waiting"');
    expect(firstCard(html, "validate")).toContain("Waiting 1/2");
  });

  it("keeps dense fan-in lanes monotonic by source order", () => {
    const model = buildExecutionGraphLayout(denseFanInGraphFixture, "desktop");
    const paths = graphWireRoutes(model, "desktop").paths;
    const tracks = model.dependencies
      .filter((dependency) => dependency.target_key === "group:target")
      .sort((left, right) => rect(model, left.source_key).y - rect(model, right.source_key).y)
      .map((dependency) => firstHorizontalTrack(paths.find((route) => route.edge === dependency.key)?.path));

    expect(tracks).toEqual([...tracks].sort((left, right) => left - right));
  });

  it("wraps huge desktop graphs and gives overlapping corridor routes distinct right-to-left lanes", () => {
    const model = buildExecutionGraphLayout(wrappedGraphFixture, "desktop");
    const routes = graphWireRoutes(model, "desktop");
    const source = rect(model, "work_package:wp-0");
    const target = rect(model, "work_package:wp-7");
    const route = routes.paths.find((path) => path.intentIds.includes("0-7"));
    const skippedTierRoute = routes.paths.find((path) => path.intentIds.includes("0-2"));
    const adjacentTierRoute = routes.paths.find((path) => path.intentIds.includes("1-2"));
    const routing = model.routing!;
    const sourceGutter = routing.columnGutters.get(source.column)!;
    const sourceCorridor = routing.rowCorridors.get(source.row)! + 12;
    const targetCorridor = routing.rowCorridors.get(target.row)! + 12;
    const targetGateX = target.x - 22;
    const skippedTarget = rect(model, "work_package:wp-2");
    const skippedGateX = skippedTarget.x - 22;

    expect(model.routing?.wrapped).toBe(true);
    expect(model.width).toBeLessThan(1_200);
    expect([...new Set(model.rects.map((item) => item.column))]).toEqual([0, 1, 2]);
    expect(target.row).toBe(2);
    expect(sourceGutter).toBeGreaterThan(source.x + source.width);
    expect(sourceCorridor).toBeLessThan(source.y);
    expect(targetCorridor).toBeLessThan(target.y);
    expect(route?.path).toMatch(new RegExp(`^M ${source.x + source.width} ${source.y + source.height / 2} H [\\d.]+ V ${targetCorridor}`));
    expect(route?.path).toMatch(new RegExp(`H [\\d.]+ V [\\d.]+ H ${targetGateX}$`));
    expect(skippedTierRoute?.path).toMatch(new RegExp(`^M ${source.x + source.width} ${source.y + source.height / 2} H [\\d.]+ V ${sourceCorridor}`));
    expect(skippedTierRoute?.path).toMatch(new RegExp(`H [\\d.]+ V [\\d.]+ H ${skippedGateX}$`));
    expect(firstHorizontalTrack(route?.path)).not.toBe(firstHorizontalTrack(skippedTierRoute?.path));
    expect(Math.abs(firstHorizontalTrack(route?.path) - sourceGutter)).toBeLessThanOrEqual(9);
    expect(Math.abs(firstHorizontalTrack(skippedTierRoute?.path) - sourceGutter)).toBeLessThanOrEqual(9);
    expect(targetSlotY(skippedTierRoute?.path)).toBeLessThan(targetSlotY(adjacentTierRoute?.path));
  });

  it("routes an expanded child through its parent column gutter before entering a row corridor", () => {
    const model = buildExecutionGraphLayout(nestedCorridorFixture, "desktop", new Set(["source"]));
    const child = rect(model, "work_package:bottom");
    const route = graphWireRoutes(model, "desktop").paths.find((path) => path.intentIds.includes("bottom-target"));
    const gutter = model.routing?.columnGutters.get(child.column);
    const corridor = (model.routing?.rowCorridors.get(child.row) ?? 0) + 12;

    expect(route?.path).toContain(`M ${child.x + child.width} ${child.y + child.height / 2} H ${gutter} V ${corridor}`);
    expect(route?.path).not.toContain(`M ${child.x + child.width / 2} ${child.y} V`);
  });

  it("duplicates an existing collapsed wire when child routes expand", () => {
    const route = (key: string, intentIds: string[]): WirePath => ({ key, edge: key, state: "waiting", path: `M ${key.length} 0 H 10 V 10 H 20`, intentIds, intentCount: intentIds.length });
    const collapsed = [route("group", ["parse", "index"])];
    const expanded = [route("parse", ["parse"]), route("index", ["index"])];

    expect(wireMorphs(collapsed, expanded).map(({ from, to }) => `${from.key}:${to.key}`)).toEqual(["group:parse", "group:index"]);
    expect(wireMorphs(expanded, collapsed).map(({ from, to }) => `${from.key}:${to.key}`)).toEqual(["parse:group", "index:group"]);
  });

  it("renders line-only connectors and a green-check state for a satisfied gate", () => {
    const html = renderToStaticMarkup(<WorkRequestExecutionGraph model={satisfiedGateGraphFixture} />);

    expect(html).not.toContain("<marker");
    expect(html).toContain('class="execution-graph__join" data-join-for="work_package:target" data-progress="2/2" data-state="satisfied"');
    expect(html).toContain(">✓</text>");
  });

  it("renders Groups with the same compact status contract and no redundant completion sentence", () => {
    const html = render();
    const model = buildExecutionGraphLayout(graphFixture, "desktop");

    expect(html).toContain('data-group-id="source" data-state="complete" data-expanded="false"');
    expect(html).toContain("Complete · 1/1");
    expect(html).toContain('data-group-id="workers" data-state="active"');
    expect(html).toContain('data-group-id="output" data-state="neutral"');
    expect(html).toContain("ingestion-workers · release");
    expect(html).toContain('aria-expanded="true"');
    expect(html).not.toContain("WorkPackage complete");
    expect(firstCard(html, "playtest")).toContain('data-state="ready"');
    expect(rect(model, "work_package:playtest").width).toBe(rect(model, "group:workers").width);
    expect(rect(model, "work_package:parse").width).toBeLessThan(rect(model, "group:workers").width);
  });

  it("shows compact clickable PR badges and only exceptional repo context", () => {
    const html = render();
    const parse = firstCard(html, "parse");
    const playtest = firstCard(html, "playtest");

    expect(parse).toContain('class="execution-graph__pr-badge" href="https://github.com/example/ingestion-workers/pull/101"');
    expect(parse).toContain("PR #101");
    expect(parse).not.toContain("ingestion-workers · release");
    expect(playtest).toContain("playtest-runner · main");
    expect(html).not.toContain("execution-graph__signals");
  });

  it("keeps cards accessible and avoids empty signal chrome", () => {
    const html = renderToStaticMarkup(<WorkRequestExecutionGraph model={{ work_packages: [{ id: "long", title: longTitle, status: "planned" }], topological_order: ["long"] }} />);

    expect(html).toContain(`title="${longTitle}"`);
    expect(firstCard(html, "long")).not.toContain('tabindex="0"');
    expect(renderToStaticMarkup(<WorkRequestExecutionGraph model={{ work_packages: [{ id: "long" }], topological_order: ["long"] }} onSelectWorkPackage={() => {}} />)).toContain('role="button" tabindex="0"');
    expect(html).toContain("No prerequisites");
    expect(html).not.toContain("execution-graph__signals");
    expect(html).toContain('role="region" tabindex="0"');
  });

  it("treats unmet dependencies as waiting rather than a true blocker", () => {
    const waitingGraph: WorkRequestExecutionGraphModel = {
      groups: [{ id: "waiting", title: "Waiting group", work_package_ids: ["wp"] }],
      work_packages: [{
        id: "wp",
        group_id: "waiting",
        status: "ready_for_worker",
        operational_state: { key: "blocked_by_dependencies", label: "Waiting", tone: "warning" },
        dependency_signal: { satisfied: 0, required: 1, active: 0, blocked: 1, unmet_work_package_ids: ["input"], inputs: [{ work_package_id: "input", status: "blocked" }] },
      }],
      topological_order: ["wp"],
    };
    const html = renderToStaticMarkup(<WorkRequestExecutionGraph model={waitingGraph} />);

    expect(html).toContain('data-group-id="waiting" data-state="neutral"');
    expect(firstCard(html, "wp")).toContain('data-state="waiting"');
    expect(html).toContain("Planned · 0/1");
    expect(html).not.toContain('data-group-id="waiting" data-state="blocked"');
  });

  it("renders unavailable and cyclic projections as explicit non-order states", () => {
    const unavailable = renderToStaticMarkup(<WorkRequestExecutionGraph model={{ available: false, work_packages: [{ id: "wp" }], topological_order: ["wp"] }} />);
    const cyclic = renderToStaticMarkup(<WorkRequestExecutionGraph model={{ available: true, work_packages: [{ id: "wp" }], topological_order: ["wp"], cycles: [["wp"]] }} />);

    expect(unavailable).toContain("Execution order unavailable");
    expect(unavailable).not.toContain('data-work-package-id="wp"');
    expect(cyclic).toContain("1 dependency cycle must be resolved");
    expect(cyclic).not.toContain("No prerequisites");
  });
});

const longTitle = "Coordinate the exceptionally long renderer package title across narrow viewports without losing its accessible name";

const graphFixture: WorkRequestExecutionGraphModel = {
  available: true,
  base_repo: "example/symphony-graph-fixtures",
  base_branch: "main",
  groups: [
    { id: "source", title: "Inputs", position: 1, work_package_ids: ["snapshot"] },
    { id: "workers", title: "Parallel workers", position: 2, work_package_ids: ["parse", "index"] },
    { id: "output", title: "Output", position: 3, work_package_ids: ["join", "publish"] },
  ],
  work_packages: [
    { id: "snapshot", group_id: "source", title: "Source snapshot", status: "merged" },
    {
      id: "parse",
      group_id: "workers",
      title: "Parse records",
      repo: "example/ingestion-workers",
      base_branch: "release",
      status: "implementing",
      worker_signal: { status: "active" },
      pr_signal: { status: "open", number: 101, url: "https://github.com/example/ingestion-workers/pull/101" },
    },
    { id: "index", group_id: "workers", title: "Build index", repo: "example/ingestion-workers", base_branch: "release", status: "ready_for_merge", review_signal: { status: "in_progress", type: "human" } },
    {
      id: "join",
      group_id: "output",
      title: "Join records",
      status: "ready_for_worker",
      dependency_signal: { satisfied: 0, required: 2, active: 2, blocked: 0, unmet_work_package_ids: ["parse", "index"], inputs: [{ work_package_id: "parse", status: "active" }, { work_package_id: "index", status: "active" }] },
    },
    { id: "publish", group_id: "output", title: "Publish result", status: "planned" },
    { id: "playtest", title: "Claim-ready playtest", repo: "example/playtest-runner", base_branch: "main", status: "ready_for_worker" },
  ],
  dependency_intents: [
    { id: "source-parse", prerequisite: { kind: "group", id: "source" }, dependent: { kind: "work_package", id: "parse" } },
    { id: "source-index", prerequisite: { kind: "work_package", id: "snapshot" }, dependent: { kind: "work_package", id: "index" } },
    { id: "parse-join", prerequisite: { kind: "work_package", id: "parse" }, dependent: { kind: "work_package", id: "join" } },
    { id: "index-join", prerequisite: { kind: "work_package", id: "index" }, dependent: { kind: "work_package", id: "join" } },
    { id: "join-publish", prerequisite: { kind: "work_package", id: "join" }, dependent: { kind: "work_package", id: "publish" } },
    { id: "source-playtest", prerequisite: { kind: "group", id: "source" }, dependent: { kind: "work_package", id: "playtest" } },
  ],
  topological_order: ["snapshot", "parse", "index", "join", "publish", "playtest"],
};

const recoveryGraphFixture: WorkRequestExecutionGraphModel = {
  groups: [
    { id: "history", title: "History", position: 1, work_package_ids: ["old"] },
    { id: "retry", title: "Retry", position: 2, work_package_ids: ["successor", "validate"] },
  ],
  work_packages: [
    { id: "old", group_id: "history", title: "Old attempt", status: "merged" },
    { id: "successor", group_id: "retry", title: "Narrow successor", status: "blocked" },
    {
      id: "validate",
      group_id: "retry",
      title: "Validate recovery",
      status: "ready_for_worker",
      dependency_signal: { satisfied: 1, required: 2, active: 0, blocked: 1, unmet_work_package_ids: ["successor"], inputs: [{ work_package_id: "successor", status: "blocked" }] },
    },
  ],
  dependency_intents: [
    { id: "history-validate", prerequisite: { kind: "group", id: "history" }, dependent: { kind: "work_package", id: "validate" } },
    { id: "successor-validate", prerequisite: { kind: "work_package", id: "successor" }, dependent: { kind: "work_package", id: "validate" } },
  ],
  topological_order: ["old", "successor", "validate"],
};

const denseFanInGraphFixture: WorkRequestExecutionGraphModel = {
  groups: [
    { id: "sources", title: "Sources", position: 1, work_package_ids: ["one", "two", "three", "four"] },
    { id: "target", title: "Target", position: 2, work_package_ids: ["target-wp"] },
  ],
  work_packages: [
    ...["one", "two", "three", "four"].map((id, index) => ({
      id,
      group_id: "sources",
      title: id,
      sequence: index,
      status: index === 2 ? "implementing" : "ready_for_worker",
    })),
    { id: "target-wp", group_id: "target", title: "Target work", status: "planned" },
  ],
  dependency_intents: ["one", "two", "three", "four"].map((id) => ({
    id: `${id}-target`,
    prerequisite: { kind: "work_package" as const, id },
    dependent: { kind: "group" as const, id: "target" },
  })),
  topological_order: ["one", "two", "three", "four", "target-wp"],
};

const satisfiedGateGraphFixture: WorkRequestExecutionGraphModel = {
  work_packages: [
    { id: "source-a", title: "Source A", status: "merged" },
    { id: "source-b", title: "Source B", status: "merged" },
    { id: "target", title: "Target", status: "planned" },
  ],
  dependency_intents: [
    { id: "a-target", prerequisite: { kind: "work_package", id: "source-a" }, dependent: { kind: "work_package", id: "target" } },
    { id: "b-target", prerequisite: { kind: "work_package", id: "source-b" }, dependent: { kind: "work_package", id: "target" } },
  ],
  topological_order: ["source-a", "source-b", "target"],
};

const wrappedGraphFixture: WorkRequestExecutionGraphModel = {
  work_packages: Array.from({ length: 8 }, (_value, index) => ({ id: `wp-${index}`, title: `Stage ${index + 1}`, status: index === 0 ? "merged" : "planned" })),
  dependency_intents: [
    ...Array.from({ length: 7 }, (_value, index) => ({
      id: `${index}-${index + 1}`,
      prerequisite: { kind: "work_package" as const, id: `wp-${index}` },
      dependent: { kind: "work_package" as const, id: `wp-${index + 1}` },
    })),
    { id: "0-2", prerequisite: { kind: "work_package", id: "wp-0" }, dependent: { kind: "work_package", id: "wp-2" } },
    { id: "0-7", prerequisite: { kind: "work_package", id: "wp-0" }, dependent: { kind: "work_package", id: "wp-7" } },
  ],
  topological_order: Array.from({ length: 8 }, (_value, index) => `wp-${index}`),
};

const affinityGridFixture: WorkRequestExecutionGraphModel = {
  groups: ["a", "b", "c", "d"].map((id, index) => ({ id, title: id.toUpperCase(), position: index + 1, work_package_ids: [`wp-${id}`] })),
  work_packages: ["a", "b", "c", "d"].map((id) => ({ id: `wp-${id}`, group_id: id, title: id.toUpperCase(), status: "planned" })),
  dependency_intents: [
    { id: "a-c", prerequisite: { kind: "group", id: "a" }, dependent: { kind: "group", id: "c" } },
    { id: "b-d", prerequisite: { kind: "group", id: "b" }, dependent: { kind: "group", id: "d" } },
  ],
  topological_order: ["wp-a", "wp-b", "wp-c", "wp-d"],
};

const nestedCorridorFixture: WorkRequestExecutionGraphModel = {
  groups: [
    { id: "source", title: "Source", position: 1, work_package_ids: ["top", "bottom"] },
    { id: "middle", title: "Middle", position: 2, work_package_ids: ["middle-wp"] },
    { id: "target", title: "Target", position: 3, work_package_ids: ["target-wp"] },
  ],
  work_packages: [
    { id: "top", group_id: "source", title: "Top", status: "merged" },
    { id: "bottom", group_id: "source", title: "Bottom", status: "merged" },
    { id: "middle-wp", group_id: "middle", title: "Middle", status: "planned" },
    { id: "target-wp", group_id: "target", title: "Target", status: "planned" },
  ],
  dependency_intents: [
    { id: "source-middle", prerequisite: { kind: "group", id: "source" }, dependent: { kind: "group", id: "middle" } },
    { id: "bottom-target", prerequisite: { kind: "work_package", id: "bottom" }, dependent: { kind: "group", id: "target" } },
  ],
  topological_order: ["top", "bottom", "middle-wp", "target-wp"],
};

function render() {
  return renderToStaticMarkup(<WorkRequestExecutionGraph model={graphFixture} now="2026-07-18T09:30:00Z" />);
}

function rect(model: ReturnType<typeof buildExecutionGraphLayout>, key: string) {
  const value = model.rects.find((item) => item.key === key);
  expect(value).toBeDefined();
  return value!;
}

function firstCard(html: string, id: string) {
  const start = html.indexOf(`data-work-package-id="${id}"`);
  const end = html.indexOf("</article>", start);
  return html.slice(start, end);
}

function firstHorizontalTrack(path?: string) {
  const value = path?.match(/ H ([\d.]+) V /)?.[1];
  expect(value).toBeDefined();
  return Number(value);
}

function targetSlotY(path?: string) {
  const value = [...(path?.matchAll(/ V (-?[\d.]+) H /g) ?? [])].at(-1)?.[1];
  expect(value).toBeDefined();
  return Number(value);
}
