import type { CSSProperties, KeyboardEvent } from "react";

import {
  buildExecutionGraphLayout,
  dependencyProgress,
  dependencyState,
  graphCardSize,
} from "@/dashboard/execution-graph/model";
import type {
  ExecutionGraphLayoutModel,
  ExecutionGraphWorkPackageRef,
  ExecutionGraphWorkPackageSignals,
  GraphOrientation,
  GraphPoint,
  WorkRequestExecutionGraphModel,
} from "@/dashboard/execution-graph/model";
import { contextPathValue, type ContextPathPart } from "./workstream-context-path";

export type WorkRequestExecutionGraphProps = {
  model: WorkRequestExecutionGraphModel;
  now?: string | number | Date;
  ariaLabel?: string;
  onSelectWorkPackage?: (workPackageId: string) => void;
  contextPath?: ContextPathPart[];
};

export function WorkRequestExecutionGraph({
  model: graph,
  now,
  ariaLabel = "WorkRequest execution graph",
  onSelectWorkPackage,
  contextPath,
}: WorkRequestExecutionGraphProps) {
  const notice = executionGraphNotice(graph);
  if (notice) return <GraphNotice ariaLabel={ariaLabel} title={notice.title} detail={notice.detail} />;

  const desktop = buildExecutionGraphLayout(graph, "desktop");
  const mobile = buildExecutionGraphLayout(graph, "mobile");

  if (!desktop.ids.length) {
    return (
      <section className="execution-graph execution-graph--empty" aria-label={ariaLabel}>
        <p>No execution packages to show.</p>
      </section>
    );
  }

  return (
    <section className="execution-graph" aria-label={ariaLabel}>
      <GraphSurface model={desktop} orientation="desktop" now={now} onSelectWorkPackage={onSelectWorkPackage} contextPath={contextPath} />
      <GraphSurface model={mobile} orientation="mobile" now={now} onSelectWorkPackage={onSelectWorkPackage} contextPath={contextPath} />
    </section>
  );
}

function GraphNotice({ ariaLabel, title, detail }: { ariaLabel: string; title: string; detail: string }) {
  return (
    <section className="execution-graph execution-graph--empty" aria-label={ariaLabel} role="status">
      <div className="grid max-w-md gap-1 px-4 text-center">
        <p className="font-semibold text-foreground">{title}</p>
        <p>{detail}</p>
      </div>
    </section>
  );
}

function executionGraphNotice(graph: WorkRequestExecutionGraphModel) {
  if (graph.available === false) {
    return { title: "Execution order unavailable", detail: "Dependency information could not be loaded for this WorkRequest." };
  }
  const cycleCount = graph.cycles?.length ?? 0;
  if (cycleCount) {
    const noun = cycleCount === 1 ? "cycle" : "cycles";
    return { title: "Execution order blocked", detail: `${cycleCount} dependency ${noun} must be resolved before this WorkRequest can run.` };
  }
  return undefined;
}

function GraphSurface({
  model,
  orientation,
  now,
  onSelectWorkPackage,
  contextPath,
}: {
  model: ExecutionGraphLayoutModel;
  orientation: GraphOrientation;
  now?: string | number | Date;
  onSelectWorkPackage?: (workPackageId: string) => void;
  contextPath?: ContextPathPart[];
}) {
  const size = graphCardSize(orientation);

  return (
    <div
      className={`execution-graph__viewport execution-graph__viewport--${orientation}`}
      data-orientation={orientation}
      role="region"
      tabIndex={0}
      aria-label={`${orientation === "desktop" ? "Left-to-right" : "Top-to-bottom"} execution order; scroll to inspect`}
    >
      <div
        className="execution-graph__canvas"
        style={{ width: model.width, height: model.height } as CSSProperties}
      >
        <GroupRegions model={model} />
        <GraphWires model={model} orientation={orientation} />
        {model.positions.map((point) => (
          <WorkPackageCard
            key={point.id}
            point={point}
            width={size.width}
            height={size.height}
            model={model}
            now={now}
            onSelectWorkPackage={onSelectWorkPackage}
            contextPath={contextPath}
          />
        ))}
      </div>
    </div>
  );
}

function GroupRegions({ model }: { model: ExecutionGraphLayoutModel }) {
  return model.groupBounds.map((group) => (
    <div
      key={group.key}
      className="execution-graph__group"
      data-group-id={group.id}
      data-nesting-depth={group.nestingDepth}
      style={{
        left: group.x,
        top: group.y,
        width: group.width,
        height: group.height,
        "--execution-graph-group-offset": `${Math.min(group.nestingDepth, 6) * 0.75}rem`,
      } as CSSProperties}
      aria-hidden="true"
      title={group.description || undefined}
    >
      <span className="execution-graph__group-label">{group.title}</span>
    </div>
  ));
}

function GraphWires({ model, orientation }: { model: ExecutionGraphLayoutModel; orientation: GraphOrientation }) {
  const pointById = new Map(model.positions.map((point) => [point.id, point]));

  return (
    <svg className="execution-graph__wires" width={model.width} height={model.height} aria-hidden="true" role="presentation" focusable="false">
      {model.ids.flatMap((dependentId) => {
        const target = pointById.get(dependentId);
        const incoming = model.incoming.get(dependentId) ?? [];
        if (!target) return [];

        return [
          ...incoming.flatMap((edge, index) => {
            const source = pointById.get(edge.prerequisite_work_package_id);
            if (!source) return [];
            const state = dependencyState(model, dependentId, edge.prerequisite_work_package_id);
            const targetPoint = wireTarget(target, index, incoming.length, orientation);
            const route = edgeRoute(source, targetPoint, orientation);
            return [
              <path
                key={`${edge.prerequisite_work_package_id}-${dependentId}`}
                className="execution-graph__edge"
                data-edge={`${edge.prerequisite_work_package_id}:${dependentId}`}
                data-state={state}
                data-route={route}
                d={edgePath(source, targetPoint, orientation, route)}
              />,
            ];
          }),
          incoming.length > 1 ? <JoinRail key={`join-${dependentId}`} model={model} target={target} orientation={orientation} /> : null,
        ];
      })}
    </svg>
  );
}

function JoinRail({
  model,
  target,
  orientation,
}: {
  model: ExecutionGraphLayoutModel;
  target: GraphPoint;
  orientation: GraphOrientation;
}) {
  const incoming = model.incoming.get(target.id) ?? [];
  const progress = dependencyProgress(model, target.id);
  const points = incoming.map((_, index) => wireTarget(target, index, incoming.length, orientation));
  const rail = joinRail(points, target, orientation);

  return (
    <g className="execution-graph__join" data-join-for={target.id} data-progress={`${progress.satisfied}/${progress.required}`}>
      <path className="execution-graph__join-trunk" d={rail.trunk} />
      {incoming.map((edge, index) => {
        const point = points[index];
        const state = dependencyState(model, target.id, edge.prerequisite_work_package_id);
        return (
          <line
            key={edge.prerequisite_work_package_id}
            className="execution-graph__join-segment"
            data-input={edge.prerequisite_work_package_id}
            data-state={state}
            x1={point.x - rail.segmentX}
            x2={point.x + rail.segmentX}
            y1={point.y - rail.segmentY}
            y2={point.y + rail.segmentY}
          />
        );
      })}
      <text className="execution-graph__join-label" x={rail.label.x} y={rail.label.y} textAnchor={rail.label.anchor}>
        {progress.satisfied}/{progress.required}
      </text>
    </g>
  );
}

function WorkPackageCard({
  point,
  width,
  height,
  model,
  now,
  onSelectWorkPackage,
  contextPath,
}: {
  point: GraphPoint;
  width: number;
  height: number;
  model: ExecutionGraphLayoutModel;
  now?: string | number | Date;
  onSelectWorkPackage?: (workPackageId: string) => void;
  contextPath?: ContextPathPart[];
}) {
  const ref = model.refs.get(point.id) ?? { id: point.id };
  const signal = model.signals.get(point.id);
  const state = cardState(ref, signal);
  const title = ref.title?.trim() || ref.id;
  const progress = dependencyProgress(model, point.id);
  const reason = priorityReason(signal, ref);
  const worker = workerLabel(signal, now);
  const secondarySignals = cardSignals(signal);
  const dependencyLabel = accessibleDependencyLabel(model, point.id, progress.satisfied, progress.required);
  const groupLabel = groupAncestryLabel(model, ref.group_id);
  const cardContextPath = contextPath ? contextPathValue([...contextPath, ...groupAncestryPath(model, ref.group_id)]) : undefined;
  const interaction = cardInteraction(point.id, onSelectWorkPackage);

  return (
    <article
      className="execution-graph__card"
      style={{ left: point.x, top: point.y, width, height } as CSSProperties}
      data-work-package-id={point.id}
      data-depth={point.depth}
      data-layout-order={point.order}
      data-state={state.tone}
      data-has-reason={reason ? "true" : undefined}
      data-v3-context-path={cardContextPath}
      aria-label={sentenceLabel([title, groupLabel, state.label, reason, worker, ...secondarySignals.map((item) => item.label), dependencyLabel])}
      {...interaction}
    >
      <header className="execution-graph__card-header">
        <span className="execution-graph__sequence">{sequenceLabel(ref)}</span>
        <span className="execution-graph__status">{state.label}</span>
      </header>
      <h3 className="execution-graph__card-title" title={title}>{title}</h3>
      <CardPriority reason={reason} worker={worker} blocked={state.blocked} />
      <CardSignalList items={secondarySignals} />
      <span className="sr-only">{groupLabel}</span>
      <span className="sr-only">{dependencyLabel}</span>
    </article>
  );
}

type CardSignalItem = { kind: string; label: string; tone: string };

function CardPriority({ reason, worker, blocked }: { reason?: string; worker?: string; blocked: boolean }) {
  return (
    <div className="execution-graph__card-priority">
      {reason ? (
        <p className="execution-graph__reason" data-priority="reason">
          <span>{blocked ? "Blocked" : "Waiting"}</span>
          <span className="execution-graph__reason-copy" title={reason}>{reason}</span>
        </p>
      ) : null}
      {worker ? (
        <p className="execution-graph__worker" data-priority="worker">
          <span className="execution-graph__activity-dot" aria-hidden="true" />
          {worker}
        </p>
      ) : null}
    </div>
  );
}

function CardSignalList({ items }: { items: CardSignalItem[] }) {
  if (!items.length) return null;
  return (
    <ul className="execution-graph__signals" aria-label="Delivery signals">
      {items.map((item) => (
        <li key={item.kind} data-signal={item.kind} data-tone={item.tone}>
          {item.label}
        </li>
      ))}
    </ul>
  );
}

function accessibleDependencyLabel(model: ExecutionGraphLayoutModel, dependentId: string, satisfied: number, required: number) {
  const incoming = model.incoming.get(dependentId) ?? [];
  if (!incoming.length) return "No prerequisites.";
  const inputs = incoming
    .map((edge) => `${edge.prerequisite_work_package_id} ${dependencyState(model, dependentId, edge.prerequisite_work_package_id)}`)
    .join(", ");
  return `Dependencies ${satisfied} of ${required} satisfied. ${inputs}.`;
}

function groupAncestryLabel(model: ExecutionGraphLayoutModel, groupId?: string | null) {
  const names = groupAncestryPath(model, groupId).map((part) => part.label);
  return names.length ? `Group path ${names.join(" › ")}` : "Ungrouped";
}

function groupAncestryPath(model: ExecutionGraphLayoutModel, groupId?: string | null): ContextPathPart[] {
  const groups = new Map(model.groups.map((group) => [group.id, group]));
  const path: ContextPathPart[] = [];
  const seen = new Set<string>();
  let currentId = groupId;
  while (currentId && !seen.has(currentId)) {
    seen.add(currentId);
    const group = groups.get(currentId);
    if (!group) break;
    path.unshift({ id: group.id, label: group.title?.trim() || "Untitled group" });
    currentId = group.parent_group_id;
  }
  return path;
}

function cardInteraction(id: string, onSelect?: (id: string) => void) {
  if (!onSelect) return {};
  return {
    role: "button" as const,
    tabIndex: 0,
    onClick: () => onSelect(id),
    onKeyDown: (event: KeyboardEvent<HTMLElement>) => activateCard(event, id, onSelect),
  };
}

function cardState(ref: ExecutionGraphWorkPackageRef, signal?: ExecutionGraphWorkPackageSignals) {
  const operational = signal?.operational_state ?? ref.operational_state;
  const status = firstText([signal?.raw_status, ref.raw_status, ref.status]) ?? "planned";
  const label = firstText([operational?.label]) ?? humanize(status);
  const source = [operational?.tone, operational?.key, status].filter(Boolean).join(" ").toLowerCase();
  const blocked = isBlocked(signal, source);
  const tone = cardTone(source, blocked);
  return { blocked, label, tone };
}

function priorityReason(signal: ExecutionGraphWorkPackageSignals | undefined, ref: ExecutionGraphWorkPackageRef) {
  const operational = signal?.operational_state ?? ref.operational_state;
  const reason = firstText([operational?.reason]);
  if (!reason) return undefined;
  if (dependencyNeedsAttention(signal?.dependency_signal)) return reason;
  return /block|wait|pending|ready/i.test(`${operational?.tone ?? ""} ${operational?.key ?? ""}`) ? reason : undefined;
}

function dependencyNeedsAttention(dependency?: ExecutionGraphWorkPackageSignals["dependency_signal"]) {
  if (!dependency) return false;
  return dependency.required > dependency.satisfied || dependency.blocked > 0;
}

function workerLabel(signal: ExecutionGraphWorkPackageSignals | undefined, now?: string | number | Date) {
  const worker = signal?.worker_signal;
  if (!worker) return undefined;
  const label = firstText([worker.run_label]);
  if (worker.status === "active") {
    const elapsed = elapsedLabel(worker.active_since, now);
    return [label ?? "Active worker", elapsed].filter(Boolean).join(" · ");
  }
  if (worker.status === "stale") return [label, "Worker stale"].filter(Boolean).join(" · ");
  if (worker.status === "paused") return [label, "Worker paused"].filter(Boolean).join(" · ");
  return undefined;
}

function cardSignals(signal?: ExecutionGraphWorkPackageSignals) {
  if (!signal) return [];
  return [prSignalItem(signal), reviewSignalItem(signal), checkSignalItem(signal)].filter(isSignalItem);
}

function prSignalItem(signal: ExecutionGraphWorkPackageSignals): CardSignalItem | undefined {
  const pr = signal.pr_signal;
  if (!pr || ["none", "unavailable"].includes(pr.status)) return undefined;
  const number = pr.number == null ? "" : ` #${pr.number}`;
  return { kind: "pr", label: `PR${number} ${humanize(pr.status)}`, tone: pr.status === "merged" ? "success" : "info" };
}

function reviewSignalItem(signal: ExecutionGraphWorkPackageSignals): CardSignalItem | undefined {
  const review = signal.review_signal;
  if (!review || review.status === "unavailable") return undefined;
  return {
    kind: "review",
    label: `${humanize(review.type || "review")}${progressText(review.current, review.total)} · ${humanize(review.status)}`,
    tone: signalTone(review.status),
  };
}

function checkSignalItem(signal: ExecutionGraphWorkPackageSignals): CardSignalItem | undefined {
  const checks = signal.pr_signal?.checks;
  if (!checks || checks.status === "unavailable") return undefined;
  return {
    kind: "checks",
    label: `Checks${progressText(checks.current, checks.total)} · ${humanize(checks.status)}`,
    tone: signalTone(checks.status),
  };
}

function progressText(current?: number | null, total?: number | null) {
  return current == null || total == null ? "" : ` ${current}/${total}`;
}

function signalTone(status: string) {
  if (["passed", "passing", "merged"].includes(status)) return "success";
  if (["failed", "failing"].includes(status)) return "danger";
  return "info";
}

function isSignalItem(item: CardSignalItem | undefined): item is CardSignalItem {
  return Boolean(item);
}

function isBlocked(signal: ExecutionGraphWorkPackageSignals | undefined, source: string) {
  if ((signal?.dependency_signal?.blocked ?? 0) > 0) return true;
  return /block|danger|error|fail/.test(source);
}

function cardTone(source: string, blocked: boolean) {
  if (blocked) return "blocked";
  if (/wait|ready|pending|queued|planned/.test(source)) return "waiting";
  if (/pass|merge|finish|done|success|complete/.test(source)) return "complete";
  if (/active|implement|reviewing|in progress/.test(source)) return "active";
  return "neutral";
}

function firstText(values: Array<string | null | undefined>) {
  return values.map((value) => value?.trim()).find(Boolean);
}

function sentenceLabel(values: Array<string | null | undefined>) {
  const text = values.map((value) => value?.trim().replace(/[.]+$/, "")).filter(Boolean).join(". ");
  return text ? `${text}.` : undefined;
}

function wireTarget(target: GraphPoint, index: number, count: number, orientation: GraphOrientation) {
  const size = graphCardSize(orientation);
  if (count <= 1) return orientation === "desktop" ? { x: target.x, y: target.y + size.height / 2 } : { x: target.x + size.width / 2, y: target.y };
  if (orientation === "desktop") {
    const span = Math.min((count - 1) * 14, size.height - 72);
    return { x: target.x - 28, y: target.y + (size.height - span) / 2 + (index * span) / (count - 1) };
  }
  return { x: target.x + 36 + (index * (size.width - 72)) / (count - 1), y: target.y - 28 };
}

function edgeRoute(source: GraphPoint, target: { x: number; y: number }, orientation: GraphOrientation) {
  if (orientation === "desktop") return "direct" as const;
  const size = graphCardSize(orientation);
  return target.y - (source.y + size.height) > size.yGap + 1 ? "gutter" as const : "direct" as const;
}

function edgePath(
  source: GraphPoint,
  target: { x: number; y: number },
  orientation: GraphOrientation,
  route: "direct" | "gutter",
) {
  const size = graphCardSize(orientation);
  if (orientation === "desktop") {
    const start = { x: source.x + size.width, y: source.y + size.height / 2 };
    const bend = Math.max(32, (target.x - start.x) / 2);
    return `M ${start.x} ${start.y} C ${start.x + bend} ${start.y}, ${target.x - bend} ${target.y}, ${target.x} ${target.y}`;
  }
  const start = { x: source.x + size.width / 2, y: source.y + size.height };
  if (route === "gutter") {
    const gutterX = 16 + (source.order % 3) * 5;
    return `M ${start.x} ${start.y} C ${start.x} ${start.y + 24}, ${gutterX} ${start.y + 24}, ${gutterX} ${start.y + 48} L ${gutterX} ${target.y - 48} C ${gutterX} ${target.y - 24}, ${target.x} ${target.y - 24}, ${target.x} ${target.y}`;
  }
  const bend = Math.max(32, (target.y - start.y) / 2);
  return `M ${start.x} ${start.y} C ${start.x} ${start.y + bend}, ${target.x} ${target.y - bend}, ${target.x} ${target.y}`;
}

function joinRail(points: Array<{ x: number; y: number }>, target: GraphPoint, orientation: GraphOrientation) {
  const size = graphCardSize(orientation);
  if (orientation === "desktop") {
    const top = points[0];
    const bottom = points.at(-1) ?? top;
    const center = target.y + size.height / 2;
    return {
      trunk: `M ${top.x} ${top.y - 6} L ${bottom.x} ${bottom.y + 6} M ${top.x} ${center} L ${target.x} ${center}`,
      segmentX: 0,
      segmentY: 5,
      label: { x: top.x - 4, y: top.y - 12, anchor: "end" as const },
    };
  }
  const left = points[0];
  const right = points.at(-1) ?? left;
  const center = target.x + size.width / 2;
  return {
    trunk: `M ${left.x - 6} ${left.y} L ${right.x + 6} ${right.y} M ${center} ${left.y} L ${center} ${target.y}`,
    segmentX: 5,
    segmentY: 0,
    label: { x: center, y: right.y - 11, anchor: "middle" as const },
  };
}

function activateCard(event: KeyboardEvent<HTMLElement>, id: string, onSelect: (id: string) => void) {
  if (event.key !== "Enter" && event.key !== " ") return;
  event.preventDefault();
  onSelect(id);
}

function elapsedLabel(activeSince: string | null | undefined, now?: string | number | Date) {
  if (!activeSince || now == null) return undefined;
  const elapsed = new Date(now).getTime() - Date.parse(activeSince);
  if (!Number.isFinite(elapsed) || elapsed < 0) return undefined;
  const minutes = Math.floor(elapsed / 60_000);
  if (minutes < 1) return "<1m";
  if (minutes < 60) return `${minutes}m`;
  const hours = Math.floor(minutes / 60);
  if (hours < 24) return `${hours}h ${minutes % 60}m`;
  return `${Math.floor(hours / 24)}d ${hours % 24}h`;
}

function sequenceLabel(ref: ExecutionGraphWorkPackageRef) {
  return ref.sequence == null ? "WorkPackage" : `WP ${ref.sequence}`;
}

function humanize(value: string) {
  const normalized = value.replaceAll(/[_-]+/g, " ").trim();
  return normalized ? normalized.charAt(0).toUpperCase() + normalized.slice(1) : "Unknown";
}

export type {
  DependencyPathState,
  ExecutionGraphWorkPackageRef,
  ExecutionGraphWorkPackageSignals,
  WorkRequestExecutionGraphModel,
} from "@/dashboard/execution-graph/model";
