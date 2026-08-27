import { executionFrontierProjection } from "@/dashboard/execution-graph/frontier";
import { workPackageIsFinished, type ExecutionGraphWorkPackageRef } from "@/dashboard/execution-graph/model";

import { exactWorkerPaneId } from "./binding";
import type { InspectorState } from "./types";

const ansi = {
  reset: "\u001b[0m",
  bold: "\u001b[1m",
  dim: "\u001b[2m",
  cyan: "\u001b[96m",
  green: "\u001b[92m",
  red: "\u001b[91m",
  yellow: "\u001b[93m",
};
const graphemes = new Intl.Segmenter("en", { granularity: "grapheme" });
const pictograph = /\p{Extended_Pictographic}|\p{Regional_Indicator}|\uFE0F|\u20E3/u;
const fullWidthSingles = new Set([0x2329, 0x232a]);
const fullWidthRanges: Array<[number, number]> = [
  [0x1100, 0x115f], [0x2e80, 0x303e], [0x3040, 0xa4cf], [0xac00, 0xd7a3],
  [0xf900, 0xfaff], [0xfe10, 0xfe19], [0xfe30, 0xfe6f], [0xff00, 0xff60],
  [0xffe0, 0xffe6], [0x1b000, 0x1b001], [0x1f200, 0x1f251], [0x20000, 0x3fffd],
];

type GraphRow = { ids: string[]; continues: boolean };

export function renderInspector(state: InspectorState, columns = 80, rows = 24) {
  const width = Math.max(1, columns);
  const detail = state.detail;
  if (!detail) return frame([state.error ? `Symphony++ · ${state.error}` : "Symphony++ · Loading"], width);

  const projection = executionFrontierProjection(
    detail.execution_graph,
    new Set(detail.attention_keys ?? []),
    "forward-2",
  );
  const header = [
    paint(trim(`${state.pinned ? "Pinned · " : ""}${detail.work_request.title || detail.work_request.id}`, width), ansi.bold),
    paint(trim([detail.work_request.repo, detail.work_request.status].filter(Boolean).join(" · "), width), ansi.dim),
  ];
  const body = projection.presentation === "graph" && width >= 24
    ? renderGraph(state, projection, width, rows)
    : renderMetadata(state, projection.model.work_packages, width);
  const pin = state.pinned ? "p unpin" : "p pin";
  const footer = paint(trim(`↑↓ select  enter focus  ${pin}  q close`, width), ansi.dim);
  return frame([...header, "", ...body, "", footer], width);
}

function renderMetadata(state: InspectorState, packages: ExecutionGraphWorkPackageRef[], width: number) {
  const pkg = packages.find((candidate) => candidate.id === state.selectedId) ?? packages[0];
  if (!pkg) return [paint("No WorkPackages", ansi.dim)];
  const metrics = packageMetrics(pkg);
  const focusable = Boolean(exactWorkerPaneId(state.snapshot, state.detail?.worker_sessions, pkg.id));
  return [
    paint(trim(pkg.title || pkg.id, width), ansi.bold),
    trimAnsi([stateLabel(pkg), ...metrics, focusable ? "worker available" : undefined].filter(Boolean).join(" · "), width),
  ];
}

function renderGraph(
  state: InspectorState,
  projection: ReturnType<typeof executionFrontierProjection>,
  width: number,
  height: number,
) {
  const graph = projection.model;
  const byId = new Map(graph.work_packages.map((pkg) => [pkg.id, pkg]));
  const parents = parentPackages(graph.effective_edges ?? []);
  const ranks = packageRanks(graph.work_packages.map((pkg) => pkg.id), graph.effective_edges ?? [], graph.topological_order ?? []);
  const groups = new Map((graph.groups ?? []).map((group) => [group.id, group.title || group.id]));
  const maxAcross = cardsAcross(width);
  const rankedRows = ranks.flatMap((rank) => {
    const parts = chunk(rank, maxAcross);
    return parts.map((ids, index) => ({ ids, continues: index < parts.length - 1 }));
  });
  const selectedRow = Math.max(0, rankedRows.findIndex((row) => row.ids.includes(state.selectedId ?? "")));
  const folds = foldedCounts(projection);
  const window = rowWindow(rankedRows.length, selectedRow, Math.max(7, height - 5 - (folds.length ? 1 : 0)));
  const lines = renderGraphRows(rankedRows.slice(window.start, window.end), byId, parents, groups, state, width);
  const hidden = graphHiddenCounts(rankedRows.length, window, folds);
  if (hidden.length) lines.push(paint(trim(hidden.join("  ·  "), width), ansi.dim));
  return lines;
}

function renderGraphRows(
  rows: GraphRow[],
  byId: Map<string, ExecutionGraphWorkPackageRef>,
  parents: Map<string, string[]>,
  groups: Map<string, string>,
  state: InspectorState,
  width: number,
) {
  const lines: string[] = [];
  let lastGroup: string | null | undefined;
  for (const row of rows) {
    const rank = row.ids;
    const rankGroups = [...new Set(rank.map((id) => byId.get(id)?.group_id).filter(Boolean))];
    const group = rankGroups.length === 1 ? rankGroups[0] : undefined;
    if (group && group !== lastGroup) lines.push(paint(trim(groups.get(group) ?? group, width), ansi.cyan));
    lines.push(...renderRank(rank, byId, parents, state, width, row.continues));
    lastGroup = group;
  }
  return lines;
}

function graphHiddenCounts(total: number, window: { start: number; end: number }, folds: string[]) {
  return [
    window.start ? `Earlier ${window.start}` : "",
    window.end < total ? `Later ${total - window.end}` : "",
    ...folds,
  ].filter(Boolean);
}

function rowWindow(total: number, selected: number, budget: number) {
  if (!total) return { start: 0, end: 0 };
  const capacity = Math.max(1, Math.floor(budget / 7));
  let start = selected;
  let end = selected + 1;
  while (end - start < capacity && (start > 0 || end < total)) {
    if (end < total) end += 1;
    if (end - start < capacity && start > 0) start -= 1;
  }
  return { start, end };
}

function parentPackages(edges: Array<{ prerequisite_work_package_id: string; dependent_work_package_id: string }>) {
  const parents = new Map<string, string[]>();
  for (const edge of edges) {
    parents.set(edge.dependent_work_package_id, [...(parents.get(edge.dependent_work_package_id) ?? []), edge.prerequisite_work_package_id]);
  }
  return parents;
}

function foldedCounts(projection: ReturnType<typeof executionFrontierProjection>) {
  return [
    projection.previousIds.length ? `Previous ${projection.previousIds.length}` : "",
    projection.laterIds.length ? `Later ${projection.laterIds.length}` : "",
    projection.otherIds.length ? `Other ${projection.otherIds.length}` : "",
  ].filter(Boolean);
}

function renderRank(
  ids: string[],
  byId: Map<string, ExecutionGraphWorkPackageRef>,
  parents: Map<string, string[]>,
  state: InspectorState,
  width: number,
  continues: boolean,
) {
  const gap = 2;
  const cardWidth = Math.max(20, Math.floor((width - gap * (ids.length - 1)) / ids.length));
  const cards = ids.map((id) => packageCard(byId.get(id)!, parents.get(id) ?? [], state, cardWidth));
  const rows = cards[0].map((_, row) => trimAnsi(cards.map((card) => card[row]).join(" ".repeat(gap)), width));
  rows.push(continues ? paint(trim("↓", width), ansi.dim) : "");
  return rows;
}

function cardsAcross(width: number) {
  return Math.max(1, Math.floor((width + 2) / 28));
}

function packageCard(pkg: ExecutionGraphWorkPackageRef, parentIds: string[], state: InspectorState, width: number) {
  const inner = width - 2;
  const selected = pkg.id === state.selectedId;
  const title = `${selected ? "› " : "  "}${pkg.title || pkg.id}`;
  const parentText = parentIds.length ? `← ${parentIds.map(shortId).join(", ")}` : "start";
  const focusable = Boolean(exactWorkerPaneId(state.snapshot, state.detail?.worker_sessions, pkg.id));
  const status = `${stateLabel(pkg)}${focusable ? " · worker" : ""}`;
  const border = "─".repeat(inner);
  return [
    `┌${border}┐`,
    `│${pad(trim(title, inner), inner)}│`,
    `│${pad(trim(parentText, inner), inner)}│`,
    `│${pad(trimAnsi(status, inner), inner)}│`,
    `└${border}┘`,
  ];
}

function packageRanks(ids: string[], edges: Array<{ prerequisite_work_package_id: string; dependent_work_package_id: string }>, order: string[]) {
  const present = new Set(ids);
  const depth = new Map(ids.map((id) => [id, 0]));
  const ordered = [...ids].sort((left, right) => order.indexOf(left) - order.indexOf(right));
  for (const id of ordered) {
    const incoming = edges.filter((edge) => edge.dependent_work_package_id === id && present.has(edge.prerequisite_work_package_id));
    if (incoming.length) depth.set(id, Math.max(...incoming.map((edge) => depth.get(edge.prerequisite_work_package_id) ?? 0)) + 1);
  }
  const ranks = new Map<number, string[]>();
  for (const id of ordered) ranks.set(depth.get(id) ?? 0, [...(ranks.get(depth.get(id) ?? 0) ?? []), id]);
  return [...ranks.entries()].sort(([left], [right]) => left - right).map(([, rank]) => rank);
}

function packageMetrics(pkg: ExecutionGraphWorkPackageRef) {
  const signal = pkg as ExecutionGraphWorkPackageRef & {
    pr_signal?: { number?: number | null; checks?: { current?: number | null; total?: number | null } | null } | null;
    review_signal?: { current?: number | null; total?: number | null } | null;
  };
  return [
    signal.review_signal?.total ? `Review ${signal.review_signal.current ?? 0}/${signal.review_signal.total}` : undefined,
    signal.pr_signal?.checks?.total ? `CI ${signal.pr_signal.checks.current ?? 0}/${signal.pr_signal.checks.total}` : undefined,
    signal.pr_signal?.number ? `PR #${signal.pr_signal.number}` : undefined,
  ].filter((value): value is string => Boolean(value));
}

function stateLabel(pkg: ExecutionGraphWorkPackageRef) {
  if (workPackageIsFinished(pkg, pkg)) return paint("Complete", ansi.green);
  const status = [pkg.operational_state?.key, pkg.operational_state?.label, pkg.raw_status, pkg.status].filter(Boolean).join(" ").toLowerCase();
  if (/block|fail|error/.test(status)) return paint("Blocked", ansi.red);
  if (/active|implement|review|progress/.test(status)) return paint("Active", ansi.cyan);
  return paint(pkg.operational_state?.label || pkg.status || "Waiting", ansi.yellow);
}

function frame(lines: string[], width: number) {
  return lines.map((line) => trimAnsi(line, width)).join("\n");
}

function paint(value: string, color: string) {
  return `${color}${safeText(value)}${ansi.reset}`;
}

function shortId(id: string) {
  return id.length > 13 ? `${id.slice(0, 10)}…` : id;
}

function trim(value: string, width: number) {
  const safe = safeText(value);
  if (terminalCellWidth(safe) <= width) return safe;
  const limit = Math.max(0, width - 1);
  let output = "";
  let used = 0;
  for (const { segment } of graphemes.segment(safe)) {
    const cells = graphemeCellWidth(segment);
    if (used + cells > limit) break;
    output += segment;
    used += cells;
  }
  return `${output}…`;
}

function trimAnsi(value: string, width: number) {
  const plain = stripAnsi(value);
  if (terminalCellWidth(plain) <= width) return value;
  return trim(plain, width);
}

function pad(value: string, width: number) {
  return value + " ".repeat(Math.max(0, width - terminalCellWidth(stripAnsi(value))));
}

function chunk<T>(items: T[], size: number) {
  const result: T[][] = [];
  for (let index = 0; index < items.length; index += size) result.push(items.slice(index, index + size));
  return result;
}

export function stripAnsi(value: string) {
  return Object.values(ansi).reduce((output, code) => output.replaceAll(code, ""), value);
}

export function terminalCellWidth(value: string) {
  let width = 0;
  for (const { segment } of graphemes.segment(safeText(value))) width += graphemeCellWidth(segment);
  return width;
}

function graphemeCellWidth(value: string) {
  if (pictograph.test(value)) return 2;
  let width = 0;
  for (const character of value) {
    const codePoint = character.codePointAt(0) ?? 0;
    if (/\p{Mark}/u.test(character) || codePoint === 0x200d) continue;
    width = Math.max(width, fullWidthCodePoint(codePoint) ? 2 : 1);
  }
  return width;
}

function fullWidthCodePoint(codePoint: number) {
  return fullWidthSingles.has(codePoint) || fullWidthRanges.some(([start, end]) => codePoint >= start && codePoint <= end);
}

function safeText(value: string) {
  return Array.from(value, (character) => {
    const codePoint = character.codePointAt(0) ?? 0;
    return codePoint <= 0x1f || (codePoint >= 0x7f && codePoint <= 0x9f) ? " " : character;
  }).join("");
}
