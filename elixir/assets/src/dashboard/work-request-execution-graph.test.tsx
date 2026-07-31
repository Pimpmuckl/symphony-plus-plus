import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";

import { workRequestExecutionGraphModel } from "@/dashboard/execution-graph/adapter";
import { buildExecutionGraphLayout, defaultExpandedGroupIds } from "@/dashboard/execution-graph/model";
import type { WorkRequestExecutionGraphModel } from "@/dashboard/execution-graph/model";
import { graphWireRoutes } from "@/dashboard/execution-graph/router";
import type { WirePath } from "@/dashboard/execution-graph/router";
import { wireMorphs } from "@/dashboard/execution-graph/wire-morphs";
import { WorkRequestExecutionGraph } from "@/dashboard/work-request-execution-graph";
import type { WorkRequestDetail } from "@/types/dashboard";

describe("WorkRequestExecutionGraph", () => {
  it("maps original dependency intent and package lifecycle signals without replacing it with effective edges", () => {
    const detail: WorkRequestDetail = {
      work_request: { id: "wr-adapter", title: "Adapter fixture" },
      work_packages: [
        {
          id: "wp-active",
          work_request_id: "wr-adapter",
          product_tree_node_id: "group-a",
          title: "Active projection",
          status: "implementing",
          operational_state: { key: "implementing", label: "Implementing", tone: "info" },
          worker_signal: { status: "active", run_label: "fixture-worker" },
        },
        { id: "wp-old", work_request_id: "wr-adapter", product_tree_node_id: "group-a", title: "Old", status: "merged", delivery: { outcome: "superseded" } },
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

  it("stacks roots by dependency rank instead of filling an unrelated grid row", () => {
    const roots = buildExecutionGraphLayout(affinityGridFixture, "desktop").rects.filter((item) => !item.parent_group_id);

    expect(roots.map((item) => item.key)).toEqual(["group:a", "group:b", "group:c", "group:d"]);
    expect(roots.map(({ row, column }) => [row, column])).toEqual([[0, 0], [0, 0], [0, 1], [0, 1]]);
    expect(rect(buildExecutionGraphLayout(graphFixture, "desktop"), "work_package:playtest").column).toBe(1);
  });

  it("keeps the same dependency order as a single top-to-bottom mobile flow", () => {
    const model = buildExecutionGraphLayout(graphFixture, "mobile");
    const roots = model.rects.filter((item) => !item.parent_group_id);
    const route = graphWireRoutes(model, "mobile").paths[0];

    expect(roots.map((item) => item.key)).toEqual(["group:source", "group:workers", "work_package:playtest", "group:output"]);
    expect(roots.map((item) => item.y)).toEqual([...roots.map((item) => item.y)].sort((left, right) => left - right));
    expect(route.path).toMatch(/^M [\d.]+ [\d.]+ V [\d.]+ H [\d.]+ V [\d.]+$/);
  });

  it("sizes a dependency-free desktop board with one consistent outer margin", () => {
    const model = buildExecutionGraphLayout({ work_packages: [{ id: "only", title: "Only package" }] }, "desktop");
    const only = rect(model, "work_package:only");

    expect(only).toMatchObject({ x: 28, y: 28 });
    expect(model.width).toBe(only.x + only.width + 28);
    expect(model.height).toBe(only.y + only.height + 28);
  });

  it("expands every non-complete Group by default and keeps only finished Groups compact", () => {
    expect([...defaultExpandedGroupIds(graphFixture)]).toEqual(["workers", "output"]);
    const model = buildExecutionGraphLayout(graphFixture, "desktop");
    const collapsed = buildExecutionGraphLayout(graphFixture, "desktop", new Set());
    const exiting = buildExecutionGraphLayout(graphFixture, "desktop", new Set(), new Set(["workers"]));

    expect(rect(model, "group:source")).toMatchObject({ expanded: false, height: 62 });
    expect(rect(model, "group:workers")).toMatchObject({ expanded: true });
    expect(rect(model, "group:workers").height).toBeGreaterThan(62);
    expect(rect(model, "group:output")).toMatchObject({ expanded: true });
    expect(rect(model, "group:output").height).toBeGreaterThan(62);
    expect(exiting.rects.some((item) => item.key === "work_package:parse")).toBe(true);
    expect(exiting.height).toBe(collapsed.height);
  });

  it("keeps group-intent edges on the shell and proxies hidden WP endpoints to their collapsed Group", () => {
    const model = buildExecutionGraphLayout(graphFixture, "desktop", new Set(["workers"]));
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

  it("keeps hidden child prerequisites independent when their Group is collapsed", () => {
    const model = buildExecutionGraphLayout({
      groups: [{ id: "target", title: "Backup and host migration", work_package_ids: ["backup", "migration"] }],
      work_packages: [
        { id: "contract", title: "Contract", status: "merged" },
        { id: "restore", title: "Restore verification", status: "merged" },
        { id: "backup", group_id: "target", title: "Back up host state", status: "closed" },
        { id: "migration", group_id: "target", title: "Execute host migration", status: "planned" },
      ],
      dependency_intents: [
        { id: "contract-backup", prerequisite: { kind: "work_package", id: "contract" }, dependent: { kind: "work_package", id: "backup" } },
        { id: "restore-migration", prerequisite: { kind: "work_package", id: "restore" }, dependent: { kind: "work_package", id: "migration" } },
      ],
    }, "desktop", new Set());
    const routes = graphWireRoutes(model, "desktop");
    const targetEntries = routes.paths.map(({ path }) => routeSegments(path).at(-1)?.y2);

    expect(model.dependencies.every(({ target_is_collapsed_proxy }) => target_is_collapsed_proxy)).toBe(true);
    expect(routes.gates.some(({ targetKey }) => targetKey === "group:target")).toBe(false);
    expect(new Set(targetEntries).size).toBe(2);
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

  it("widens Groups around horizontal intra-Group dependency flows on desktop", () => {
    const desktop = buildExecutionGraphLayout(graphFixture, "desktop");
    const output = rect(desktop, "group:output");
    const join = rect(desktop, "work_package:join");
    const publish = rect(desktop, "work_package:publish");
    const route = graphWireRoutes(desktop, "desktop").paths.find((path) => path.edge === "work_package:join:work_package:publish");
    const mobile = buildExecutionGraphLayout(graphFixture, "mobile");
    const chainIds = ["one", "two", "three", "four"];
    const chainFixture: WorkRequestExecutionGraphModel = {
      groups: [{ id: "chain", title: "Chain", work_package_ids: chainIds }],
      work_packages: chainIds.map((id) => ({ id, group_id: "chain", title: id, status: "planned" })),
      dependency_intents: chainIds.slice(1).map((id, index) => ({
        id: `${chainIds[index]}-${id}`,
        prerequisite: { kind: "work_package", id: chainIds[index] },
        dependent: { kind: "work_package", id },
      })),
    };
    const chain = buildExecutionGraphLayout(chainFixture, "desktop");
    const chainGroup = rect(chain, "group:chain");
    const third = rect(chain, "work_package:three");
    const fourth = rect(chain, "work_package:four");
    const wrappedRoute = graphWireRoutes(chain, "desktop").paths.find((path) => path.edge === "work_package:three:work_package:four");

    expect(output.width).toBeGreaterThan(268);
    expect(join.y).toBe(publish.y);
    expect(join.x).toBeLessThan(publish.x);
    expect(route?.path).toBe(`M ${join.x + join.width} ${join.y + join.height / 2} H ${publish.x}`);
    expect(rect(desktop, "work_package:parse").x).toBe(rect(desktop, "work_package:index").x);
    expect(rect(mobile, "work_package:join").x).toBe(rect(mobile, "work_package:publish").x);
    expect(rect(mobile, "work_package:join").y).toBeLessThan(rect(mobile, "work_package:publish").y);
    expect(chainGroup.width).toBe(860);
    expect(third.x).toBeGreaterThan(fourth.x);
    expect(chainGroup.height).toBeGreaterThan(output.height);
    expect(routeSegments(wrappedRoute?.path ?? "")).toHaveLength(5);
    expect(routeSegments(wrappedRoute?.path ?? "").every((segment) => (
      Math.min(segment.x1, segment.x2) >= chainGroup.x
      && Math.max(segment.x1, segment.x2) <= chainGroup.x + chainGroup.width
      && Math.min(segment.y1, segment.y2) >= chainGroup.y
      && Math.max(segment.y1, segment.y2) <= chainGroup.y + chainGroup.height
    ))).toBe(true);
  });

  it("routes cross-Group dependencies around horizontal sibling cards", () => {
    const fixture: WorkRequestExecutionGraphModel = {
      groups: [
        { id: "source", title: "Source", work_package_ids: ["one", "two"] },
        { id: "target", title: "Target", work_package_ids: ["three", "four"] },
      ],
      work_packages: [
        { id: "one", group_id: "source", title: "One" },
        { id: "two", group_id: "source", title: "Two" },
        { id: "three", group_id: "target", title: "Three" },
        { id: "four", group_id: "target", title: "Four" },
      ],
      dependency_intents: [
        { id: "one-two", prerequisite: { kind: "work_package", id: "one" }, dependent: { kind: "work_package", id: "two" } },
        { id: "three-four", prerequisite: { kind: "work_package", id: "three" }, dependent: { kind: "work_package", id: "four" } },
        { id: "one-four", prerequisite: { kind: "work_package", id: "one" }, dependent: { kind: "work_package", id: "four" } },
      ],
    };
    const model = buildExecutionGraphLayout(fixture, "desktop");
    const route = graphWireRoutes(model, "desktop").paths.find((path) => path.edge === "work_package:one:work_package:four");
    const source = rect(model, "group:source");
    const siblings = [rect(model, "work_package:two"), rect(model, "work_package:three")];
    const segments = routeSegments(route?.path ?? "");

    expect(rect(model, "work_package:one").x).toBeLessThan(rect(model, "work_package:two").x);
    expect(rect(model, "work_package:three").x).toBeLessThan(rect(model, "work_package:four").x);
    expect(segments.some((segment) => siblings.some((item) => segmentIntersectsInterior(segment, item)))).toBe(false);
    expect(segments.some((segment) => segment.y1 === segment.y2 && segment.x1 < source.x + source.width && segment.x2 > source.x + source.width)).toBe(true);
  });

  it("renders one static N/M gate for fan-in and leaves only active paths dashed by state", () => {
    const html = render();

    expect(html.match(/data-join-for="work_package:join"/g)).toHaveLength(2);
    expect(html.match(/data-progress="0\/2"/g)).toHaveLength(2);
    expect(html).toContain('data-edge="work_package:parse:work_package:join" data-state="active"');
    expect(html).toContain('data-edge="work_package:index:work_package:join" data-state="active"');
    expect(html).toContain('class="execution-graph__join-trunk" data-state="waiting"');
    expect(html).not.toContain("execution-graph__group-label");
  });

  it("orders fan-out lanes toward their destinations and routes mixed fan-in around the target", () => {
    const fanoutModel = buildExecutionGraphLayout(graphFixture, "desktop");
    const fanout = graphWireRoutes(fanoutModel, "desktop").paths;
    const sourcePaths = fanoutModel.dependencies
      .filter((dependency) => dependency.source_key === "group:source")
      .sort((left, right) => rect(fanoutModel, left.target_key).y - rect(fanoutModel, right.target_key).y)
      .map((dependency) => fanout.find((route) => route.edge === dependency.key) as WirePath);
    const sourceTracks = sourcePaths.map((path) => firstHorizontalTrack(path.path));

    expect(sourcePaths.map((path) => path.source?.y)).toEqual([...sourcePaths.map((path) => path.source?.y)].sort((left, right) => (left ?? 0) - (right ?? 0)));
    expect(sourceTracks).toEqual([...sourceTracks].sort((left, right) => right - left));
    expect(sourceTracks.slice(1).every((track, index) => sourceTracks[index] - track >= 6)).toBe(true);
    expect(sourcePaths.every((path) => routeSegments(path.path).length <= 3)).toBe(true);
    expect(routeConflicts(sourcePaths)).toEqual([]);

    const recovery = buildExecutionGraphLayout(recoveryGraphFixture, "desktop");
    const routes = graphWireRoutes(recovery, "desktop");
    const retry = rect(recovery, "group:retry");
    const validate = rect(recovery, "work_package:validate");
    const successor = rect(recovery, "work_package:successor");
    const gateX = validate.x - 22;
    const successorPath = routes.paths.find((route) => route.edge === "work_package:successor:work_package:validate")?.path;
    const historyPath = routes.paths.find((route) => route.edge === "group:history:work_package:validate")?.path;

    expect(routes.gates.find((gate) => gate.targetKey === "work_package:validate")?.path).toContain(`M ${gateX}`);
    expect(historyPath).toMatch(new RegExp(`H ${gateX}$`));
    expect(successorPath).toMatch(new RegExp(`^M ${successor.x + successor.width} `));
    expect(firstHorizontalTrack(successorPath)).toBeGreaterThan(successor.x + successor.width);
    expect(routeSegments(successorPath ?? "").every((segment) => (
      Math.min(segment.x1, segment.x2) >= retry.x
      && Math.max(segment.x1, segment.x2) <= retry.x + retry.width
      && Math.min(segment.y1, segment.y2) >= retry.y
      && Math.max(segment.y1, segment.y2) <= retry.y + retry.height
    ))).toBe(true);
    expect(routeSegments(historyPath ?? "").at(-1)?.y2).toBeLessThan(routeSegments(successorPath ?? "").at(-1)?.y2 ?? 0);
    expect(successorPath).not.toMatch(/ V -/);
    expect(routes.paths.find((route) => route.edge === "work_package:successor:work_package:validate")?.state).toBe("waiting");
  });

  it("keeps a blocker local while its dependent package remains waiting", () => {
    const html = renderToStaticMarkup(<WorkRequestExecutionGraph model={recoveryGraphFixture} />);

    expect(firstCard(html, "successor")).toContain('data-state="blocked"');
    expect(firstCard(html, "validate")).toContain('data-state="waiting"');
    expect(firstCard(html, "validate")).toContain("Waiting 1/2");
  });

  it("keeps dense fan-in lanes monotonic and physically separate", () => {
    const model = buildExecutionGraphLayout(denseFanInGraphFixture, "desktop");
    const paths = graphWireRoutes(model, "desktop").paths;
    const tracks = model.dependencies
      .filter((dependency) => dependency.target_key === "group:target")
      .sort((left, right) => rect(model, left.source_key).y - rect(model, right.source_key).y)
      .map((dependency) => firstHorizontalTrack(paths.find((route) => route.edge === dependency.key)?.path));

    expect(tracks).toEqual([...tracks].sort((left, right) => left - right));
    expect(routeConflicts(paths)).toEqual([]);
  });

  it("wraps huge desktop graphs into ranked bands without routing through cards or sharing lanes", () => {
    const model = buildExecutionGraphLayout(wrappedGraphFixture, "desktop");
    const routes = graphWireRoutes(model, "desktop");
    const source = rect(model, "work_package:wp-0");
    const target = rect(model, "work_package:wp-7");
    const route = routes.paths.find((path) => path.intentIds.includes("0-7"));
    const roof = routeSegments(route?.path ?? "").find((segment) => segment.y1 === segment.y2 && segment.y1 < source.y);
    expect(model.routing?.wrapped).toBe(true);
    expect(model.width).toBeLessThan(1_200);
    expect([...new Set(model.rects.map((item) => item.column))]).toEqual([0, 1, 2]);
    expect(target.row).toBe(2);
    expect(route?.path).toMatch(new RegExp(`^M ${source.x + source.width} [\\d.]+ H [\\d.]+ V [\\d.]+ H [\\d.]+ V [\\d.]+ H [\\d.]+ V [\\d.]+ H ${target.x - 22}$`));
    expect(source.y - (roof?.y1 ?? source.y)).toBeGreaterThanOrEqual(16);
    expect(source.y - (roof?.y1 ?? source.y)).toBeLessThanOrEqual(44);
    expect(routes.paths.flatMap((path) => unrelatedCardIntersections(path, model))).toEqual([]);
    expect(routeConflicts(routes.paths)).toEqual([]);
  });

  it("routes a deep expanded-child dependency below the current roots through sibling-free gutters", () => {
    const model = buildExecutionGraphLayout(nestedCorridorFixture, "desktop", new Set(["source", "target"]));
    const child = rect(model, "work_package:bottom");
    const source = rect(model, "group:source");
    const middle = rect(model, "group:middle");
    const route = graphWireRoutes(model, "desktop").paths.find((path) => path.intentIds.includes("bottom-target"));
    const target = rect(model, "work_package:target-e");
    const segments = routeSegments(route?.path ?? "");
    const currentRootsBottom = Math.max(source.y + source.height, middle.y + middle.height);
    const targetApproach = segments.at(-2);

    expect(route?.path).toMatch(new RegExp(`^M ${child.x + child.width} [\\d.]+ H .* H ${target.x}$`));
    expect(route?.path).not.toContain(`M ${child.x + child.width / 2} ${child.y} V`);
    expect(segments.some((segment) => segment.y1 === segment.y2 && segment.y1 - currentRootsBottom >= 16)).toBe(true);
    expect(targetApproach?.x1).toBe(target.x - 8);
    expect(targetApproach?.x2).toBe(targetApproach?.x1);
    expect(unrelatedCardIntersections(route!, model)).toEqual([]);
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

  it("renders Group and WorkPackage attention badges as direct actions", () => {
    const attention = new Map([
      ["group:workers", { label: "Guidance Needed", tone: "guidance" as const }],
      ["work_package:parse", { label: "Blocked", tone: "blocked" as const }],
    ]);
    const html = renderToStaticMarkup(<WorkRequestExecutionGraph model={graphFixture} attentionByEntity={attention} onSelectAttention={() => {}} />);

    expect(html).toContain('aria-label="Open attention for Group Parallel workers"');
    expect(html).toContain('aria-label="Open attention for WorkPackage Parse records"');
    expect(html).toContain('data-group-id="workers" data-state="guidance"');
    expect(firstCard(html, "parse")).toContain('data-state="blocked"');
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
    const html = renderToStaticMarkup(<WorkRequestExecutionGraph model={{ work_packages: [{ id: "long", title: longTitle, status: "planned" }] }} />);
    const interactive = renderToStaticMarkup(<WorkRequestExecutionGraph model={{ work_packages: [{ id: "long" }] }} onSelectWorkPackage={() => {}} />);

    expect(html).toContain(`title="${longTitle}"`);
    expect(firstCard(html, "long")).not.toContain('tabindex="0"');
    expect(interactive).toContain('<button class="execution-graph__card-action" type="button" aria-label=');
    expect(firstCard(interactive, "long")).not.toContain('role="button"');
    expect(html).toContain("No prerequisites");
    expect(html).not.toContain("execution-graph__signals");
    expect(html).toContain('role="region" tabindex="0"');
  });

  it("treats unmet dependencies as waiting rather than a true blocker", () => {
    const waitingGraph: WorkRequestExecutionGraphModel = {
      groups: [{ id: "waiting", title: "Waiting group", work_package_ids: ["wp"] }],
      work_packages: [
        { id: "input", title: "Upstream input", status: "blocked" },
        {
          id: "wp",
          group_id: "waiting",
          status: "ready_for_worker",
          operational_state: { key: "blocked_by_dependencies", label: "Waiting", tone: "warning" },
          dependency_signal: { satisfied: 0, required: 1, active: 0, blocked: 1, unmet_work_package_ids: ["input"], inputs: [{ work_package_id: "input", status: "blocked" }] },
        },
      ],
      dependency_intents: [{ id: "input-waiting", prerequisite: { kind: "work_package", id: "input" }, dependent: { kind: "group", id: "waiting" } }],
    };
    const html = renderToStaticMarkup(<WorkRequestExecutionGraph model={waitingGraph} />);

    expect(html).toContain('data-group-id="waiting" data-state="neutral"');
    expect(firstCard(html, "wp")).toContain('data-state="waiting"');
    expect(html).toContain("Planned · 0/1");
    expect(firstCard(html, "wp")).toContain("Dependencies 0 of 1 satisfied: Upstream input");
    expect(html).not.toContain('data-group-id="waiting" data-state="blocked"');
  });

  it("prefers an active operational blocker over raw planned status", () => {
    const html = renderToStaticMarkup(<WorkRequestExecutionGraph model={{
      groups: [{ id: "blocked-group", title: "Blocked group", work_package_ids: ["blocked"] }],
      work_packages: [{
        id: "blocked",
        group_id: "blocked-group",
        title: "Blocked package",
        status: "planned",
        operational_state: { key: "blocked", label: "Blocked", tone: "danger" },
        worker_signal: { status: "active", active_since: "2026-07-18T09:00:00Z" },
        dependency_signal: { satisfied: 0, required: 1, active: 1, blocked: 0, unmet_work_package_ids: ["input"], inputs: [{ work_package_id: "input", status: "active" }] },
      }],
    }} />);

    expect(firstCard(html, "blocked")).toContain('data-state="blocked"');
    expect(firstCard(html, "blocked")).toContain(">Blocked<");
    expect(html).toContain('data-group-id="blocked-group" data-state="blocked"');
  });

  it("renders unavailable and cyclic projections as explicit non-order states", () => {
    const unavailable = renderToStaticMarkup(<WorkRequestExecutionGraph model={{ available: false, work_packages: [{ id: "wp" }] }} />);
    const cyclic = renderToStaticMarkup(<WorkRequestExecutionGraph model={{ available: true, work_packages: [{ id: "wp" }], cycles: [["wp"]] }} />);

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
};

const affinityGridFixture: WorkRequestExecutionGraphModel = {
  groups: ["a", "b", "c", "d"].map((id, index) => ({ id, title: id.toUpperCase(), position: index + 1, work_package_ids: [`wp-${id}`] })),
  work_packages: ["a", "b", "c", "d"].map((id) => ({ id: `wp-${id}`, group_id: id, title: id.toUpperCase(), status: "planned" })),
  dependency_intents: [
    { id: "a-c", prerequisite: { kind: "group", id: "a" }, dependent: { kind: "group", id: "c" } },
    { id: "b-d", prerequisite: { kind: "group", id: "b" }, dependent: { kind: "group", id: "d" } },
  ],
};

const nestedCorridorFixture: WorkRequestExecutionGraphModel = {
  groups: [
    { id: "source", title: "Source", position: 1, work_package_ids: ["top", "bottom"] },
    { id: "middle", title: "Middle", position: 2, work_package_ids: ["middle-wp"] },
    { id: "target", title: "Target", position: 3, work_package_ids: ["target-a", "target-b", "target-c", "target-d", "target-e"] },
  ],
  work_packages: [
    { id: "top", group_id: "source", title: "Top", status: "merged" },
    { id: "bottom", group_id: "source", title: "Bottom", status: "merged" },
    { id: "middle-wp", group_id: "middle", title: "Middle", status: "planned" },
    ...["a", "b", "c", "d", "e"].map((id) => ({ id: `target-${id}`, group_id: "target", title: `Target ${id.toUpperCase()}`, status: "planned" })),
  ],
  dependency_intents: [
    { id: "source-middle", prerequisite: { kind: "group", id: "source" }, dependent: { kind: "group", id: "middle" } },
    { id: "middle-target", prerequisite: { kind: "group", id: "middle" }, dependent: { kind: "work_package", id: "target-a" } },
    { id: "bottom-target", prerequisite: { kind: "work_package", id: "bottom" }, dependent: { kind: "work_package", id: "target-e" } },
  ],
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

type Segment = { x1: number; y1: number; x2: number; y2: number };

function routeSegments(path: string) {
  const tokens = [...path.matchAll(/([MHV])\s*(-?[\d.]+)(?:\s+(-?[\d.]+))?/g)];
  const segments: Segment[] = [];
  let x = 0;
  let y = 0;
  for (const [, command, first, second] of tokens) {
    const previous = { x, y };
    if (command === "M") [x, y] = [Number(first), Number(second)];
    if (command === "H") x = Number(first);
    if (command === "V") y = Number(first);
    if (command !== "M") segments.push({ x1: previous.x, y1: previous.y, x2: x, y2: y });
  }
  return segments;
}

function unrelatedCardIntersections(path: WirePath, model: ReturnType<typeof buildExecutionGraphLayout>) {
  const dependency = model.dependencies.find(({ key }) => key === path.edge);
  if (!dependency) return [];
  const endpoints = [rootKeyFor(dependency.source_key, model), rootKeyFor(dependency.target_key, model)];
  return model.rects
    .filter((item) => !item.parent_group_id && !endpoints.includes(item.key))
    .filter((item) => routeSegments(path.path).some((segment) => segmentIntersectsInterior(segment, item)))
    .map((item) => `${path.edge}->${item.key}`);
}

function rootKeyFor(key: string, model: ReturnType<typeof buildExecutionGraphLayout>) {
  let item = model.rects.find((candidate) => candidate.key === key);
  while (item?.parent_group_id) item = model.rects.find((candidate) => candidate.key === `group:${item?.parent_group_id}`);
  return item?.key ?? key;
}

function segmentIntersectsInterior(segment: Segment, item: ReturnType<typeof rect>) {
  if (segment.x1 === segment.x2) {
    return segment.x1 > item.x + 2
      && segment.x1 < item.x + item.width - 2
      && Math.max(Math.min(segment.y1, segment.y2), item.y + 2) < Math.min(Math.max(segment.y1, segment.y2), item.y + item.height - 2);
  }
  return segment.y1 > item.y + 2
    && segment.y1 < item.y + item.height - 2
    && Math.max(Math.min(segment.x1, segment.x2), item.x + 2) < Math.min(Math.max(segment.x1, segment.x2), item.x + item.width - 2);
}

function routeConflicts(paths: WirePath[]) {
  const conflicts: string[] = [];
  for (let left = 0; left < paths.length; left += 1) {
    for (let right = left + 1; right < paths.length; right += 1) {
      const conflict = routeSegments(paths[left].path).some((a) => routeSegments(paths[right].path).some((b) => segmentsConflict(a, b)));
      if (conflict) conflicts.push(`${paths[left].edge}<->${paths[right].edge}`);
    }
  }
  return conflicts;
}

function segmentsConflict(left: Segment, right: Segment) {
  const leftHorizontal = left.y1 === left.y2;
  const rightHorizontal = right.y1 === right.y2;
  if (leftHorizontal === rightHorizontal) {
    const distance = Math.abs((leftHorizontal ? left.y1 : left.x1) - (leftHorizontal ? right.y1 : right.x1));
    const overlap = intervalOverlap(
      leftHorizontal ? left.x1 : left.y1,
      leftHorizontal ? left.x2 : left.y2,
      leftHorizontal ? right.x1 : right.y1,
      leftHorizontal ? right.x2 : right.y2,
    );
    return overlap > 2 && distance < 6;
  }
  const horizontal = leftHorizontal ? left : right;
  const vertical = leftHorizontal ? right : left;
  const insideX = within(vertical.x1, horizontal.x1, horizontal.x2);
  const insideY = within(horizontal.y1, vertical.y1, vertical.y2);
  const nearX = Math.min(Math.abs(vertical.x1 - horizontal.x1), Math.abs(vertical.x1 - horizontal.x2));
  const nearY = Math.min(Math.abs(horizontal.y1 - vertical.y1), Math.abs(horizontal.y1 - vertical.y2));
  return (insideX && insideY) || (insideX && nearY < 6) || (insideY && nearX < 6);
}

function intervalOverlap(a1: number, a2: number, b1: number, b2: number) {
  return Math.min(Math.max(a1, a2), Math.max(b1, b2)) - Math.max(Math.min(a1, a2), Math.min(b1, b2));
}

function within(value: number, start: number, end: number) {
  return value > Math.min(start, end) && value < Math.max(start, end);
}
