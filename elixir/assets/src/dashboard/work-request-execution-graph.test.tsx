import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";

import { auditWireGeometry, routeConflicts, routeSegments, segmentIntersectsInterior } from "@/dashboard/execution-graph/geometry-audit";
import { buildExecutionGraphLayout, defaultExpandedGroupIds } from "@/dashboard/execution-graph/model";
import type { WorkRequestExecutionGraphModel } from "@/dashboard/execution-graph/model";
import { graphWireRoutes } from "@/dashboard/execution-graph/router";
import type { WirePath } from "@/dashboard/execution-graph/router";
import { wireMorphs, wireTransitionLayers } from "@/dashboard/execution-graph/wire-morphs";
import { GraphWires } from "@/dashboard/execution-graph/wires";
import { WorkRequestExecutionGraph } from "@/dashboard/work-request-execution-graph";

describe("WorkRequestExecutionGraph", () => {
  it("uses Groups as the root graph entities and gives dependent roots greater desktop depth", () => {
    const model = buildExecutionGraphLayout(graphFixture, "desktop", new Set(["workers", "output"]));
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

  it("keeps Frontier dependency ranks in one left-to-right cadence", () => {
    const roots = buildExecutionGraphLayout(foldedFanInFixture, "desktop", new Set(), new Set(), false).rects.filter((item) => !item.parent_group_id);
    expect(new Set(roots.map((item) => item.row))).toEqual(new Set([0]));
    expect(roots.map(({ depth, column }) => [depth, column])).toEqual(roots.map(({ depth }) => [depth, depth]));
  });

  it("keeps later root columns stable when a vertically separate Group expands", () => {
    const collapsed = buildExecutionGraphLayout(foldedFanInFixture, "desktop");
    const expanded = buildExecutionGraphLayout(foldedFanInFixture, "desktop", new Set(["online"]));

    expect(rect(expanded, "group:online").width).toBeGreaterThan(rect(collapsed, "group:online").width);
    expect(rect(expanded, "group:rise").x).toBe(rect(collapsed, "group:rise").x);
    expect(rect(expanded, "group:maintenance").x).toBe(rect(collapsed, "group:maintenance").x);
  });

  it("keeps the same dependency order as a single top-to-bottom mobile flow", () => {
    const model = buildExecutionGraphLayout(graphFixture, "mobile");
    const roots = model.rects.filter((item) => !item.parent_group_id);
    const route = graphWireRoutes(model, "mobile").paths[0];

    expect(roots.map((item) => item.key)).toEqual(["group:source", "group:workers", "work_package:playtest", "group:output"]);
    expect(roots.map((item) => item.y)).toEqual([...roots.map((item) => item.y)].sort((left, right) => left - right));
    expect(route.path).toMatch(/^M [\d.]+ [\d.]+ V [\d.]+ H [\d.]+ V [\d.]+$/);
  });

  it("uses the same outer margin on every side of a simple desktop graph", () => {
    const model = buildExecutionGraphLayout({ work_packages: [{ id: "only", title: "Only package" }] }, "desktop");
    const only = rect(model, "work_package:only");

    expect(only).toMatchObject({ x: 48, y: 48 });
    expect(model.width).toBe(only.x + only.width + 48);
    expect(model.height).toBe(only.y + only.height + 48);
  });

  it("keeps low-level Group layout collapsed while opening blocked Groups in the rendered graph", () => {
    expect([...defaultExpandedGroupIds()]).toEqual([]);
    const model = buildExecutionGraphLayout(graphFixture, "desktop");
    const expanded = buildExecutionGraphLayout(graphFixture, "desktop", new Set(["workers", "output"]));
    const collapsed = buildExecutionGraphLayout(graphFixture, "desktop", new Set());
    const exiting = buildExecutionGraphLayout(graphFixture, "desktop", new Set(), new Set(["workers"]));
    const blocked = renderToStaticMarkup(<WorkRequestExecutionGraph model={{
      groups: [{ id: "blocked", title: "Blocked Group", work_package_ids: ["blocked-package"] }],
      work_packages: [{ id: "blocked-package", group_id: "blocked", status: "blocked" }],
    }} />);

    expect(rect(model, "group:source")).toMatchObject({ expanded: false, height: 62 });
    expect(rect(model, "group:workers")).toMatchObject({ expanded: false, height: 62 });
    expect(rect(model, "group:output")).toMatchObject({ expanded: false, height: 62 });
    expect(rect(expanded, "group:workers").height).toBeGreaterThan(62);
    expect(rect(expanded, "group:output").height).toBeGreaterThan(62);
    expect(exiting.rects.some((item) => item.key === "work_package:parse")).toBe(true);
    expect(exiting.height).toBe(collapsed.height);
    expect(blocked).toContain('data-group-id="blocked" data-state="blocked" data-expanded="true"');
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

  it("ignores mounted hidden children when routing collapsed Groups", () => {
    const mounted = buildExecutionGraphLayout(graphFixture, "desktop", new Set(), new Set(["source", "workers", "output"]));
    const unmounted = buildExecutionGraphLayout(graphFixture, "desktop", new Set(), new Set());

    expect(mounted.rects.length).toBeGreaterThan(mounted.visibleRects.length);
    expect(graphWireRoutes(mounted, "desktop")).toEqual(graphWireRoutes(unmounted, "desktop"));
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
    const desktop = buildExecutionGraphLayout(graphFixture, "desktop", new Set(["workers", "output"]));
    const output = rect(desktop, "group:output");
    const join = rect(desktop, "work_package:join");
    const publish = rect(desktop, "work_package:publish");
    const route = graphWireRoutes(desktop, "desktop").paths.find((path) => path.edge === "work_package:join:work_package:publish");
    const mobile = buildExecutionGraphLayout(graphFixture, "mobile", new Set(["workers", "output"]));
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
    const chain = buildExecutionGraphLayout(chainFixture, "desktop", new Set(["chain"]));
    const chainGroup = rect(chain, "group:chain");
    const third = rect(chain, "work_package:three");
    const fourth = rect(chain, "work_package:four");
    const wrappedRoute = graphWireRoutes(chain, "desktop").paths.find((path) => path.edge === "work_package:three:work_package:four");
    const largeIds = Array.from({ length: 10 }, (_value, index) => `large-${index}`); const largeEdges = [...largeIds.slice(1, 7).map((id) => [id, "large-7"]), ["large-7", "large-8"], ["large-8", "large-9"]];
    const largeFixture: WorkRequestExecutionGraphModel = {
      groups: [{ id: "large", title: "Large group", work_package_ids: largeIds }],
      work_packages: [{ id: "outside", title: "Outside" }, ...largeIds.map((id) => ({ id, group_id: "large", title: id, status: "planned" }))],
      dependency_intents: [{ id: "outside-large-7", prerequisite: { kind: "work_package" as const, id: "outside" }, dependent: { kind: "work_package" as const, id: "large-7" } }, ...largeEdges.map(([prerequisite, dependent]) => ({
        id: `${prerequisite}-${dependent}`,
        prerequisite: { kind: "work_package" as const, id: prerequisite },
        dependent: { kind: "work_package" as const, id: dependent },
      }))],
    };
    const large = buildExecutionGraphLayout(largeFixture, "desktop", new Set(["large"]));
    const largeRoutes = graphWireRoutes(large, "desktop").paths;
    const largeGroup = rect(large, "group:large");
    expect(output.width).toBeGreaterThan(268);
    expect(join.y).toBe(publish.y);
    expect(join.x).toBeLessThan(publish.x);
    expect(route?.path).toBe(`M ${join.x + join.width} ${join.y + join.height / 2} H ${publish.x}`);
    expect(rect(desktop, "work_package:parse").x).toBe(rect(desktop, "work_package:index").x);
    expect(rect(mobile, "work_package:join").x).toBe(rect(mobile, "work_package:publish").x);
    expect(rect(mobile, "work_package:join").y).toBeLessThan(rect(mobile, "work_package:publish").y);
    expect(chainGroup.width).toBeLessThan(860);
    expect(third.x).toBeLessThan(fourth.x);
    expect(chainGroup.height).toBeGreaterThan(output.height);
    expect(routeSegments(wrappedRoute?.path ?? "")).toHaveLength(1);
    expect(routeSegments(wrappedRoute?.path ?? "").every((segment) => (
      Math.min(segment.x1, segment.x2) >= chainGroup.x
      && Math.max(segment.x1, segment.x2) <= chainGroup.x + chainGroup.width
      && Math.min(segment.y1, segment.y2) >= chainGroup.y
      && Math.max(segment.y1, segment.y2) <= chainGroup.y + chainGroup.height
    ))).toBe(true);
    expect(largeGroup.width).toBeGreaterThan(500); expect(largeGroup.width).toBeLessThan(1_000);
    expect(new Set(large.rects.filter(({ parent_group_id }) => parent_group_id === "large").map(({ x }) => x)).size).toBeGreaterThan(1); expect(rect(large, "work_package:large-1").y).toBe(rect(large, "work_package:large-7").y);
    expect(Math.max(...largeRoutes.flatMap(({ path }) => routeSegments(path).flatMap(({ y1, y2 }) => [y1, y2])))).toBeLessThanOrEqual(largeGroup.y + largeGroup.height - 12);
    expect(auditWireGeometry(large, largeRoutes).fatal).toEqual([]);
  });

  it("uses the nearest clear child-band corridor for a skipped-column intra-Group dependency", () => {
    const model = buildExecutionGraphLayout(localBandCorridorFixture, "desktop", new Set(["group"]));
    const source = rect(model, "work_package:source");
    const laterBand = rect(model, "work_package:later-one");
    const route = graphWireRoutes(model, "desktop").paths.find((path) => path.intentIds.includes("source-target"));
    const detour = routeSegments(route?.path ?? "").find((segment) => segment.y1 === segment.y2
      && Math.abs(segment.x2 - segment.x1) > source.width);

    expect(detour?.y1).toBeGreaterThan(source.y + source.height);
    expect(detour?.y1).toBeLessThan(laterBand.y);
    expect(auditWireGeometry(model, [route!])).toEqual({ fatal: [], soft: [] });
  });

  it("projects nested dependencies and reserves shell lanes inside expanded Groups", () => {
    const nested: WorkRequestExecutionGraphModel = {
      groups: [
        { id: "parent", title: "Parent", work_package_ids: ["target"] },
        { id: "nested", parent_group_id: "parent", title: "Nested", work_package_ids: ["source"] },
      ],
      work_packages: [
        { id: "source", group_id: "nested", title: "Source" },
        { id: "target", group_id: "parent", title: "Target" },
      ],
      dependency_intents: [
        { id: "nested-target", prerequisite: { kind: "work_package", id: "source" }, dependent: { kind: "work_package", id: "target" } },
      ],
    };
    const shellChildren = ["a", "b", "c", "d"];
    const shell: WorkRequestExecutionGraphModel = {
      groups: [{ id: "shell", title: "Shell", work_package_ids: shellChildren }],
      work_packages: shellChildren.map((id) => ({ id, group_id: "shell", title: id.toUpperCase() })),
      dependency_intents: shellChildren.map((id) => ({
        id: `shell-${id}`,
        prerequisite: { kind: "group" as const, id: "shell" },
        dependent: { kind: "work_package" as const, id },
      })),
    };
    const projected = buildExecutionGraphLayout(nested, "desktop", new Set(["parent"]));
    const model = buildExecutionGraphLayout(shell, "desktop", new Set(["shell"]));
    const group = rect(model, "group:shell");
    const routes = graphWireRoutes(model, "desktop").paths;

    expect(rect(projected, "group:nested").y).toBe(rect(projected, "work_package:target").y);
    expect(rect(projected, "group:nested").x).toBeLessThan(rect(projected, "work_package:target").x);
    expect(routes.flatMap((route) => routeSegments(route.path)).every((segment) => (
      Math.min(segment.x1, segment.x2) >= group.x
      && Math.max(segment.x1, segment.x2) <= group.x + group.width
      && Math.min(segment.y1, segment.y2) >= group.y
      && Math.max(segment.y1, segment.y2) <= group.y + group.height
    ))).toBe(true);
    expect(routes.flatMap((route) => model.visibleRects
      .filter((item) => item.parent_group_id === "shell" && item.key !== model.dependencies.find(({ key }) => key === route.edge)?.target_key)
      .filter((item) => routeSegments(route.path).some((segment) => segmentIntersectsInterior(segment, item))))).toEqual([]); expect(auditWireGeometry(model, routes).fatal.filter((issue) => issue.startsWith("header:"))).toEqual([]);
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
    const model = buildExecutionGraphLayout(fixture, "desktop", new Set(["source", "target"]));
    const route = graphWireRoutes(model, "desktop").paths.find((path) => path.edge === "work_package:one:work_package:four");
    const source = rect(model, "group:source");
    const siblings = [rect(model, "work_package:two"), rect(model, "work_package:three")];
    const segments = routeSegments(route?.path ?? "");

    expect(rect(model, "work_package:one").x).toBeLessThan(rect(model, "work_package:two").x);
    expect(rect(model, "work_package:three").x).toBeLessThan(rect(model, "work_package:four").x);
    expect(segments.some((segment) => siblings.some((item) => segmentIntersectsInterior(segment, item)))).toBe(false);
    expect(segments.some((segment) => segment.y1 === segment.y2 && Math.min(segment.x1, segment.x2) === source.x + source.width)).toBe(true);
  });

  it("renders one static N/M gate for fan-in and leaves only active paths dashed by state", () => {
    const desktop = buildExecutionGraphLayout(graphFixture, "desktop", new Set(["workers", "output"]));
    const mobile = buildExecutionGraphLayout(graphFixture, "mobile", new Set(["workers", "output"]));
    const html = renderToStaticMarkup(<><GraphWires model={desktop} orientation="desktop" /><GraphWires model={mobile} orientation="mobile" /></>);

    expect(html.match(/data-join-for="work_package:join"/g)).toHaveLength(2);
    expect(html.match(/data-progress="0\/2"/g)).toHaveLength(2);
    expect(html).toContain('data-edge="work_package:parse:work_package:join" data-state="active"');
    expect(html).toContain('data-edge="work_package:index:work_package:join" data-state="active"');
    expect(html).toContain('class="execution-graph__join-trunk" data-state="waiting"');
    expect(html).not.toContain("execution-graph__group-label");
  });

  it("orders fan-out lanes toward their destinations and routes mixed fan-in around the target", () => {
    const fanoutModel = buildExecutionGraphLayout(graphFixture, "desktop", new Set(["workers", "output"]));
    const fanout = graphWireRoutes(fanoutModel, "desktop").paths;
    const sourcePaths = fanoutModel.dependencies
      .filter((dependency) => dependency.source_key === "group:source")
      .sort((left, right) => rect(fanoutModel, left.target_key).y - rect(fanoutModel, right.target_key).y)
      .map((dependency) => fanout.find((route) => route.edge === dependency.key) as WirePath);
    const sourceTracks = sourcePaths.map((path) => firstHorizontalTrack(path.path));
    expect(new Set(sourceTracks).size).toBe(sourceTracks.length);
    expect(sourcePaths.every((path) => routeSegments(path.path).length <= 8)).toBe(true);
    expect(routeConflicts(sourcePaths)).toEqual([]);
    const aligned = buildExecutionGraphLayout({ groups: [{ id: "far", work_package_ids: ["far-child"] }], work_packages: [{ id: "source" }, { id: "near" }, { id: "far-child", group_id: "far" }], dependency_intents: [{ id: "source-near", prerequisite: { kind: "work_package", id: "source" }, dependent: { kind: "work_package", id: "near" } }, { id: "near-far", prerequisite: { kind: "work_package", id: "near" }, dependent: { kind: "group", id: "far" } }, { id: "source-far", prerequisite: { kind: "work_package", id: "source" }, dependent: { kind: "group", id: "far" } }] }, "desktop");
    const alignedRoutes = graphWireRoutes({ ...aligned, dependencies: aligned.dependencies.filter(({ key }) => key !== "work_package:near:group:far") }, "desktop").paths;
    expect(routeSegments(alignedRoutes.find(({ edge }) => edge === "work_package:source:work_package:near")?.path ?? "")[0].y1).toBeLessThan(routeSegments(alignedRoutes.find(({ edge }) => edge === "work_package:source:group:far")?.path ?? "")[0].y1);
    const recovery = buildExecutionGraphLayout(recoveryGraphFixture, "desktop", new Set(["retry"]));
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
    const model = buildExecutionGraphLayout(denseFanInGraphFixture, "desktop", new Set(["sources"]));
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
    expect(source.y - (roof?.y1 ?? source.y)).toBeGreaterThanOrEqual(16);
    expect(source.y - (roof?.y1 ?? source.y)).toBeLessThanOrEqual(44);
    expect(routes.paths.flatMap((path) => unrelatedCardIntersections(path, model))).toEqual([]);
    expect(routeConflicts(routes.paths)).toEqual([]);
  });
  it("keeps wrapped left-gate fan-in separate and avoids the outer bus when the target side is clear", () => {
    const stageOneTarget = { id: "stage-one-target", prerequisite: { kind: "work_package" as const, id: "stage-one" }, dependent: { kind: "work_package" as const, id: "target" } };
    const model = buildExecutionGraphLayout({ ...wrappedLeftGateFixture, dependency_intents: [...(wrappedLeftGateFixture.dependency_intents ?? []), stageOneTarget] }, "desktop");
    const inputs = graphWireRoutes(model, "desktop").paths.filter(({ edge }) => edge.endsWith(":work_package:target"));
    const middleColumn = inputs.find(({ intentIds }) => intentIds.includes("stage-one-target"));
    expect(inputs).toHaveLength(3);
    expect(new Set(inputs.map((route) => routeSegments(route.path).at(-2)?.x1)).size).toBe(inputs.length);
    expect(Math.max(...routeSegments(middleColumn?.path ?? "").flatMap(({ x1, x2 }) => [x1, x2]))).toBeLessThanOrEqual(model.routing?.contentRight ?? model.width);
    expect(auditWireGeometry(model, inputs).fatal).toEqual([]);
  });
  it("prefers the inter-band gap for a safe downward dependency from a tall column", () => {
    const layout = buildExecutionGraphLayout(tallCrossBandFixture, "desktop", new Set(["tall-source"]));
    const model = { ...layout, dependencies: layout.dependencies.filter((dependency) => dependency.intent_ids.includes("bottom-target")) };
    const sourceRoot = rect(model, "group:tall-source");
    const target = rect(model, "work_package:target");
    const route = graphWireRoutes(model, "desktop").paths.find((path) => path.intentIds.includes("bottom-target"));
    const segments = routeSegments(route?.path ?? "");
    const bandBottom = model.routing?.bandBottoms.get(sourceRoot.row) ?? sourceRoot.y + sourceRoot.height;

    expect(target.row).toBeGreaterThan(sourceRoot.row);
    expect(segments.some((segment) => segment.y1 === segment.y2 && segment.y1 > bandBottom && segment.y1 < target.y)).toBe(true);
    expect(Math.min(...segments.flatMap((segment) => [segment.y1, segment.y2]))).toBeGreaterThanOrEqual(sourceRoot.y);
    expect(Math.max(...segments.flatMap((segment) => [segment.x1, segment.x2]))).toBeLessThanOrEqual(model.routing?.contentRight ?? model.width);
    expect(unrelatedCardIntersections(route!, model)).toEqual([]);
    expect(auditWireGeometry(model, [route!])).toEqual({ fatal: [], soft: [] });
  });
  it("audits representative desktop routes for unsafe geometry and routing debt", () => {
    const probeModel = buildExecutionGraphLayout({ work_packages: [{ id: "source" }, { id: "target" }], dependency_intents: [{ id: "source-target", prerequisite: { kind: "work_package", id: "source" }, dependent: { kind: "work_package", id: "target" } }] }, "desktop");
    const probePath = (edge: string, path: string): WirePath => ({ key: edge, edge, path, state: "waiting", intentIds: [edge], intentCount: 1 });
    const probeSource = rect(probeModel, "work_package:source");
    const probe = auditWireGeometry(probeModel, [
      probePath("a", "M 4 10 H 24"),
      probePath("b", "M 12 10 H 32"),
      probePath("c", "M 20 4 V 16"),
      probePath("work_package:source:work_package:target", `M ${probeSource.x + probeSource.width} ${probeSource.y + probeSource.height / 2} H ${probeSource.x}`),
    ]);
    const fixtures = [
      ["simple-collapsed", graphFixture, new Set<string>()],
      ["simple-expanded", graphFixture, new Set(["workers", "output"])],
      ["dense-fan-in", denseFanInGraphFixture, new Set(["sources"])],
      ["wrapped", wrappedGraphFixture, new Set<string>()],
      ["wrapped-left-gate", wrappedLeftGateFixture, new Set<string>()],
      ["beauharnois-collapsed", foldedFanInFixture, new Set<string>()],
      ["beauharnois-online-expanded", foldedFanInFixture, new Set(["online"])],
      ["nested-corridor", nestedCorridorFixture, new Set(["source", "target"])],
    ] as const;
    const reports = fixtures.map(([name, fixture, expanded]) => {
      const model = buildExecutionGraphLayout(fixture, "desktop", expanded);
      return [name, auditWireGeometry(model, graphWireRoutes(model, "desktop").paths)] as const;
    });
    const soft = reports.flatMap(([name, report]) => report.soft.map((issue) => `${name}:${issue}`));
    const acceptedSoftPrefixes = [
      "beauharnois-online-expanded:detour:work_package:preseed:group:rise:",
      "nested-corridor:bends:work_package:bottom:work_package:target-e:",
    ];
    expect(probe.fatal).toContain("overlap:a<->b");
    expect(probe.fatal).toContain("source-reentry:work_package:source:work_package:target");
    expect(probe.soft).toContain("crossing:a<->c");
    expect(reports.flatMap(([name, report]) => report.fatal.map((issue) => `${name}:${issue}`))).toEqual([]);
    expect(soft.filter((issue) => !acceptedSoftPrefixes.some((prefix) => issue.startsWith(prefix)))).toEqual([]);
  });

  it("provides one outer bus lane per overlapping cross-band cable", () => {
    const chainCount = 8;
    const stages = Array.from({ length: 4 }, (_value, stage) => Array.from({ length: chainCount }, (_unused, chain) => `chain-${chain}-${stage}`));
    const graph: WorkRequestExecutionGraphModel = {
      work_packages: stages.flat().map((id) => ({ id, title: id })),
      dependency_intents: stages.slice(1).flatMap((stage, stageIndex) => stage.map((id, chain) => ({
        id: `${stages[stageIndex][chain]}-${id}`,
        prerequisite: { kind: "work_package" as const, id: stages[stageIndex][chain] },
        dependent: { kind: "work_package" as const, id },
      }))),
    };
    const model = buildExecutionGraphLayout(graph, "desktop");
    const crossBand = graphWireRoutes(model, "desktop").paths.filter((route) => route.intentIds.some((id) => id.endsWith("-3")));
    const busTracks = crossBand.map((route) => routeSegments(route.path)
      .find((segment) => segment.x1 === segment.x2 && segment.x1 > (model.routing?.contentRight ?? 0))?.x1);
    const distinctTracks = [...new Set(busTracks)].filter((track): track is number => track != null).sort((left, right) => left - right);

    expect(crossBand).toHaveLength(chainCount);
    expect(distinctTracks).toHaveLength(chainCount);
    expect(distinctTracks.slice(1).every((track, index) => track - distinctTracks[index] >= 8)).toBe(true);
  });

  it("right-aligns a lone terminal rank and reserves outer space only for its cable", () => {
    const model = buildExecutionGraphLayout(foldedFanInFixture, "desktop");
    const maintenance = rect(model, "group:maintenance");
    const observation = rect(model, "group:observation");

    expect(observation).toMatchObject({ row: 1, column: 2, x: maintenance.x });
    expect(model.width).toBe((model.routing?.contentRight ?? 0) + 84);
  });

  it("does not reserve an outer cable bus for same-band dependencies", () => {
    const model = buildExecutionGraphLayout(graphFixture, "desktop", new Set(["workers", "output"]));

    expect(new Set(model.visibleRects.filter((item) => !item.parent_group_id).map((item) => item.row))).toEqual(new Set([0]));
    expect(model.width).toBe((model.routing?.contentRight ?? 0) + 48);
  });

  it("keeps lower skipped-root fan-in below the intervening root", () => {
    const model = buildExecutionGraphLayout(foldedFanInFixture, "desktop", new Set(["online"]));
    const paths = graphWireRoutes(model, "desktop").paths;
    const online = paths.find(({ edge }) => edge === "work_package:preseed:group:maintenance");
    const onlineToRise = paths.find(({ edge }) => edge === "work_package:preseed:group:rise");
    const rise = paths.find(({ edge }) => edge === "group:rise:group:maintenance");
    const riseRect = rect(model, "group:rise");
    const onlineRect = rect(model, "group:online");
    const crossing = routeSegments(online?.path ?? "").find((segment) => segment.y1 === segment.y2
      && Math.min(segment.x1, segment.x2) < riseRect.x
      && Math.max(segment.x1, segment.x2) > riseRect.x);

    expect(crossing?.y1).toBeGreaterThan(riseRect.y + riseRect.height);
    expect(crossing?.y1).toBeLessThan(onlineRect.y + onlineRect.height);
    expect(unrelatedCardIntersections(online!, model)).toEqual([]);
    expect(routeSegments(onlineToRise?.path ?? "").some((segment) => segmentIntersectsInterior(segment, riseRect))).toBe(false);
    expect(routeSegments(rise?.path ?? "").at(-1)?.y2).toBeLessThan(routeSegments(online?.path ?? "").at(-1)?.y2 ?? 0);
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
    const targetEntryY = segments.at(-1)?.y2;

    expect(route?.path).toMatch(new RegExp(`^M ${child.x + child.width} [\\d.]+ H .* H ${target.x}$`));
    expect(route?.path).not.toContain(`M ${child.x + child.width / 2} ${child.y} V`);
    expect(segments.some((segment) => segment.y1 === segment.y2 && segment.y1 - currentRootsBottom >= 16)).toBe(true);
    expect(segments.slice(-3).every((segment) => segment.y1 === targetEntryY && segment.y2 === targetEntryY)).toBe(true);
    expect(segments.slice(-3).some((segment) => Math.min(segment.x1, segment.x2) <= rect(model, "group:target").x)).toBe(true);
    expect(unrelatedCardIntersections(route!, model)).toEqual([]);
  });

  it("duplicates an existing collapsed wire when child routes expand", () => {
    const route = (key: string, intentIds: string[]): WirePath => ({ key, edge: key, state: "waiting", path: `M ${key.length} 0 H 10 V 10 H 20`, intentIds, intentCount: intentIds.length });
    const collapsed = [route("group", ["parse", "index"])];
    const expanded = [route("parse", ["parse"]), route("index", ["index"])];

    expect(wireMorphs(collapsed, expanded).map(({ from, to }) => `${from.key}:${to.key}`)).toEqual(["group:parse", "group:index"]);
    expect(wireMorphs(expanded, collapsed).map(({ from, to }) => `${from.key}:${to.key}`)).toEqual(["parse:group", "index:group"]);
    expect(wireTransitionLayers(collapsed, expanded)).toMatchObject({ entering: [], leaving: [] });
    expect(wireTransitionLayers(expanded, collapsed)).toMatchObject({ entering: [], leaving: [] });
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
    const expanded = buildExecutionGraphLayout(graphFixture, "desktop", new Set(["workers"]));

    expect(html).toContain('data-group-id="source" data-state="complete" data-expanded="false"');
    expect(html).toContain("Complete · 1/1");
    expect(html).toContain('data-group-id="workers" data-state="active"');
    expect(html).toContain('data-group-id="output" data-state="neutral"');
    expect(html).toContain("ingestion-workers · release");
    expect(html).toContain('aria-expanded="false"');
    expect(html).not.toContain("WorkPackage complete");
    expect(firstCard(html, "playtest")).toContain('data-state="ready"');
    expect(rect(model, "work_package:playtest").width).toBe(rect(model, "group:workers").width);
    expect(rect(expanded, "work_package:parse").width).toBeLessThan(rect(expanded, "group:workers").width);
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

const wrappedLeftGateFixture: WorkRequestExecutionGraphModel = {
  work_packages: ["root", "stage-one", "stage-two", "alt-root", "alt-one", "alternate", "target", "after", "finish"].map((id) => ({ id, title: id })),
  dependency_intents: [
    ["root", "stage-one"],
    ["stage-one", "stage-two"],
    ["alt-root", "alt-one"],
    ["alt-one", "alternate"],
    ["stage-two", "target"],
    ["alternate", "target"],
    ["target", "after"],
    ["after", "finish"],
  ].map(([prerequisite, dependent]) => ({
    id: `${prerequisite}-${dependent}`,
    prerequisite: { kind: "work_package" as const, id: prerequisite },
    dependent: { kind: "work_package" as const, id: dependent },
  })),
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

const localBandCorridorFixture: WorkRequestExecutionGraphModel = {
  groups: [{ id: "group", title: "Group" }],
  work_packages: [
    ["root", 0], ["second-root", 1], ["source", 2],
    ["bridge", 3], ["second-middle", 4], ["source-middle", 5],
    ["target", 6], ["second-end", 7], ["source-end", 8],
    ["later-one", 9], ["later-two", 10], ["later-three", 11],
  ].map(([id, sequence]) => ({ id: String(id), group_id: "group", sequence: Number(sequence), title: String(id) })),
  dependency_intents: [
    ["root", "bridge", "root-bridge"], ["bridge", "target", "bridge-target"],
    ["second-root", "second-middle", "second-middle"], ["second-middle", "second-end", "second-end"],
    ["source", "source-middle", "source-middle"], ["source-middle", "source-end", "source-end"],
    ["source", "target", "source-target"],
    ["target", "later-one", "target-later"], ["later-one", "later-two", "later-two"], ["later-two", "later-three", "later-three"],
  ].map(([prerequisite, dependent, id]) => ({
    id,
    prerequisite: { kind: "work_package" as const, id: prerequisite },
    dependent: { kind: "work_package" as const, id: dependent },
  })),
};

const tallCrossBandFixture: WorkRequestExecutionGraphModel = {
  groups: [{ id: "tall-source", title: "Tall source", position: 99, work_package_ids: [
    ...Array.from({ length: 18 }, (_value, index) => `independent-${index}`), "bottom-source",
  ] }],
  work_packages: [
    ...Array.from({ length: 18 }, (_value, index) => ({ id: `independent-${index}`, group_id: "tall-source", title: `Independent ${index}` })),
    { id: "bottom-source", group_id: "tall-source", title: "Bottom source" },
    ...["chain-root", "stage-one", "stage-two", "target"].map((id) => ({ id, title: id })),
  ],
  dependency_intents: [
    { id: "root-one", prerequisite: { kind: "work_package", id: "chain-root" }, dependent: { kind: "work_package", id: "stage-one" } },
    { id: "one-two", prerequisite: { kind: "work_package", id: "stage-one" }, dependent: { kind: "work_package", id: "stage-two" } },
    { id: "two-target", prerequisite: { kind: "work_package", id: "stage-two" }, dependent: { kind: "work_package", id: "target" } },
    { id: "bottom-target", prerequisite: { kind: "work_package", id: "bottom-source" }, dependent: { kind: "work_package", id: "target" } },
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

const foldedFanInFixture: WorkRequestExecutionGraphModel = {
  groups: [
    { id: "readiness", title: "Readiness", position: 1, work_package_ids: ["ready"] },
    { id: "online", title: "Online preseed", position: 2, work_package_ids: ["preseed", "verify"] },
    { id: "rise", title: "Rise shadow", position: 3, work_package_ids: ["shadow"] },
    { id: "maintenance", title: "Maintenance", position: 4, work_package_ids: ["cutover"] },
    { id: "observation", title: "Observation", position: 5, work_package_ids: ["observe"] },
  ],
  work_packages: [
    { id: "ready", group_id: "readiness", title: "Ready", status: "planned" },
    { id: "preseed", group_id: "online", title: "Preseed", status: "planned" },
    { id: "verify", group_id: "online", title: "Verify", status: "planned" },
    { id: "shadow", group_id: "rise", title: "Shadow", status: "planned" },
    { id: "cutover", group_id: "maintenance", title: "Cutover", status: "planned" },
    { id: "observe", group_id: "observation", title: "Observe", status: "planned" },
  ],
  dependency_intents: [
    { id: "preseed-verify", prerequisite: { kind: "work_package", id: "preseed" }, dependent: { kind: "work_package", id: "verify" } },
    { id: "readiness-rise", prerequisite: { kind: "group", id: "readiness" }, dependent: { kind: "group", id: "rise" } },
    { id: "online-rise", prerequisite: { kind: "work_package", id: "preseed" }, dependent: { kind: "group", id: "rise" } },
    { id: "online-maintenance", prerequisite: { kind: "work_package", id: "preseed" }, dependent: { kind: "group", id: "maintenance" } },
    { id: "rise-maintenance", prerequisite: { kind: "group", id: "rise" }, dependent: { kind: "group", id: "maintenance" } },
    { id: "maintenance-observation", prerequisite: { kind: "group", id: "maintenance" }, dependent: { kind: "group", id: "observation" } },
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
