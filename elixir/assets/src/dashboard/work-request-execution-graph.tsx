import { memo, useMemo, useState } from "react";
import type { CSSProperties, ReactNode } from "react";

import {
  buildExecutionGraphLayout,
  defaultExpandedGroupIds,
  dependencyProgress,
  graphGroupHeaderSize,
  operationalStateIsBlocked,
  workPackageIsFinished,
} from "@/dashboard/execution-graph/model";
import type {
  ExecutionGraphLayoutModel,
  ExecutionGraphWorkPackageRef,
  ExecutionGraphWorkPackageSignals,
  GraphEntityRect,
  GraphOrientation,
  WorkRequestExecutionGraphModel,
} from "@/dashboard/execution-graph/model";
import { GraphWires } from "@/dashboard/execution-graph/wires";
import { contextPathValue, type ContextPathPart } from "./workstream-context-path";
import { elapsedLabel } from "./workstream-row-age";
import { prBadgeLabel, PullRequestBadge } from "./execution-graph/pull-request-badge";
import type { DirectAttention } from "./workstream-attention";

export type WorkRequestExecutionGraphProps = {
  model: WorkRequestExecutionGraphModel;
  attentionByEntity?: ReadonlyMap<string, Pick<DirectAttention, "label" | "tone">>;
  now?: string | number | Date;
  ariaLabel?: string;
  onSelectAttention?: (entityKey: string) => void;
  onSelectWorkPackage?: (workPackageId: string) => void;
  contextPath?: ContextPathPart[];
};
export const WorkRequestExecutionGraph = memo(function WorkRequestExecutionGraph({
  model: graph,
  attentionByEntity = new Map(),
  now,
  ariaLabel = "WorkRequest execution graph",
  onSelectAttention,
  onSelectWorkPackage,
  contextPath,
}: WorkRequestExecutionGraphProps) {
  const [groupOverrides, setGroupOverrides] = useState<Record<string, boolean>>({});
  const notice = executionGraphNotice(graph);
  const expandedGroupIds = useMemo(() => {
    const expanded = defaultExpandedGroupIds(graph);
    Object.entries(groupOverrides).forEach(([id, value]) => value ? expanded.add(id) : expanded.delete(id));
    return expanded;
  }, [graph, groupOverrides]);
  const renderedGroupIds = useMemo(() => new Set((graph.groups ?? []).map((group) => group.id)), [graph.groups]);
  const layouts = useMemo(() => notice ? undefined : {
    desktop: buildExecutionGraphLayout(graph, "desktop", expandedGroupIds, renderedGroupIds),
    mobile: buildExecutionGraphLayout(graph, "mobile", expandedGroupIds, renderedGroupIds),
  }, [expandedGroupIds, graph, notice, renderedGroupIds]);

  if (notice) return <GraphNotice ariaLabel={ariaLabel} title={notice.title} detail={notice.detail} />;

  const { desktop, mobile } = layouts!;
  const toggleGroup = (id: string) => {
    const current = expandedGroupIds.has(id);
    setGroupOverrides((values) => ({ ...values, [id]: !current }));
  };

  if (!desktop.rects.length) {
    return (
      <section className="execution-graph execution-graph--empty" aria-label={ariaLabel}>
        <p>No execution packages to show.</p>
      </section>
    );
  }

  return (
    <section className="execution-graph" aria-label={ariaLabel}>
      <GraphSurface attentionByEntity={attentionByEntity} model={desktop} orientation="desktop" now={now} onSelectAttention={onSelectAttention} onSelectWorkPackage={onSelectWorkPackage} onToggleGroup={toggleGroup} contextPath={contextPath} />
      <GraphSurface attentionByEntity={attentionByEntity} model={mobile} orientation="mobile" now={now} onSelectAttention={onSelectAttention} onSelectWorkPackage={onSelectWorkPackage} onToggleGroup={toggleGroup} contextPath={contextPath} />
    </section>
  );
});
function GraphNotice({ ariaLabel, title, detail }: { ariaLabel: string; title: string; detail: string }) {
  return (
    <section className="execution-graph execution-graph--empty" aria-label={ariaLabel} role="status">
      <div className="grid max-w-md gap-1">
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
  attentionByEntity,
  model,
  orientation,
  now,
  onSelectAttention,
  onSelectWorkPackage,
  onToggleGroup,
  contextPath,
}: {
  attentionByEntity: ReadonlyMap<string, Pick<DirectAttention, "label" | "tone">>;
  model: ExecutionGraphLayoutModel;
  orientation: GraphOrientation;
  now?: string | number | Date;
  onSelectAttention?: (entityKey: string) => void;
  onSelectWorkPackage?: (workPackageId: string) => void;
  onToggleGroup: (groupId: string) => void;
  contextPath?: ContextPathPart[];
}) {
  const children = new Map<string, GraphEntityRect[]>();
  model.rects.forEach((rect) => {
    if (!rect.parent_group_id) return;
    children.set(rect.parent_group_id, [...(children.get(rect.parent_group_id) ?? []), rect]);
  });
  const renderNode = (rect: GraphEntityRect, parent?: GraphEntityRect): ReactNode => {
    const localRect = parent ? { ...rect, x: rect.x - parent.x, y: rect.y - parent.y - graphGroupHeaderSize(orientation) } : rect;
    if (rect.kind === "group") {
      return (
        <GroupCard attention={attentionByEntity.get(rect.key)} key={rect.key} rect={localRect} model={model} onSelectAttention={onSelectAttention ? () => onSelectAttention(rect.key) : undefined} onToggle={onToggleGroup}>
          {(children.get(rect.id) ?? []).map((child) => renderNode(child, rect))}
        </GroupCard>
      );
    }
    return <WorkPackageCard attention={attentionByEntity.get(rect.key)} key={rect.key} rect={localRect} model={model} now={now} onSelectAttention={onSelectAttention ? () => onSelectAttention(rect.key) : undefined} onSelectWorkPackage={onSelectWorkPackage} contextPath={contextPath} />;
  };
  const roots = model.rects.filter((rect) => !rect.parent_group_id);

  return (
    <div
      className={`execution-graph__viewport execution-graph__viewport--${orientation}`}
      data-orientation={orientation}
      role="region"
      tabIndex={0}
      aria-label={`${orientation === "desktop" ? (model.routing?.wrapped ? "Wrapped left-to-right" : "Left-to-right") : "Top-to-bottom"} execution order; scroll to inspect`}
    >
      <div className="execution-graph__canvas" style={{ width: model.width, height: model.height } as CSSProperties}>
        {roots.map((rect) => renderNode(rect))}
        <GraphWires model={model} orientation={orientation} />
      </div>
    </div>
  );
}
function GroupCard({
  attention,
  rect,
  model,
  onSelectAttention,
  onToggle,
  children,
}: {
  attention?: Pick<DirectAttention, "label" | "tone">;
  rect: GraphEntityRect;
  model: ExecutionGraphLayoutModel;
  onSelectAttention?: () => void;
  onToggle: (id: string) => void;
  children?: ReactNode;
}) {
  const view = groupCardView(model, rect, attention);
  const style = { left: rect.x, top: rect.y, width: rect.width, height: rect.height } as CSSProperties;

  return (
    <section
      className="execution-graph__group-card"
      style={style}
      data-group-id={rect.id}
      data-state={view.tone}
      data-expanded={rect.expanded ? "true" : "false"}
      data-parent-group-id={rect.parent_group_id}
      title={view.description}
    >
      <button className="execution-graph__group-header" type="button" aria-expanded={rect.expanded} onClick={() => onToggle(rect.id)}>
        <span className="execution-graph__card-title" title={view.title}>{view.title}</span>
        {view.scope ? <span className="execution-graph__scope execution-graph__group-scope" title={view.scope}>{view.scope}</span> : null}
      </button>
      <GraphStatus label={view.status} actionLabel={`Open attention for Group ${view.title}`} onClick={attentionAction(attention, onSelectAttention)} />
      <div className="execution-graph__group-contents" aria-hidden={rect.expanded ? undefined : true} inert={rect.expanded ? undefined : true}>
        <div className="execution-graph__group-stack">{children}</div>
      </div>
    </section>
  );
}
function WorkPackageCard({
  attention,
  rect,
  model,
  now,
  onSelectAttention,
  onSelectWorkPackage,
  contextPath,
}: {
  attention?: Pick<DirectAttention, "label" | "tone">;
  rect: GraphEntityRect;
  model: ExecutionGraphLayoutModel;
  now?: string | number | Date;
  onSelectAttention?: () => void;
  onSelectWorkPackage?: (workPackageId: string) => void;
  contextPath?: ContextPathPart[];
}) {
  const view = workPackageCardView(model, rect, now, attention, contextPath);

  return (
    <article
      className="execution-graph__card"
      style={{ left: rect.x, top: rect.y, width: rect.width, height: rect.height } as CSSProperties}
      data-work-package-id={rect.id}
      data-depth={rect.depth}
      data-layout-row={rect.row}
      data-layout-order={rect.order}
      data-state={view.state.tone}
      data-parent-group-id={rect.parent_group_id}
      data-v3-context-path={view.contextPath}
    >
      <span className="execution-graph__title-stack">
        <h3 className="execution-graph__card-title" title={view.title}>{view.title}</h3>
        {view.scope ? <span className="execution-graph__scope" title={view.scope}>{view.scope}</span> : null}
      </span>
      <GraphStatus label={view.state.label} actionLabel={`Open attention for WorkPackage ${view.title}`} onClick={attentionAction(attention, onSelectAttention)} />
      {onSelectWorkPackage ? (
        <button className="execution-graph__card-action" type="button" aria-label={view.accessibleLabel} onClick={() => onSelectWorkPackage(rect.id)} />
      ) : null}
      {view.prLabel ? <PullRequestBadge signal={view.pr} label={view.prLabel} /> : null}
      <span className="sr-only">{view.groupLabel}</span>
      <span className="sr-only">{view.dependencyLabel}</span>
    </article>
  );
}

function groupCardView(model: ExecutionGraphLayoutModel, rect: GraphEntityRect, attention?: Pick<DirectAttention, "label" | "tone">) {
  const group = model.groups.get(rect.id);
  const state = model.groupStates.get(rect.id) ?? { label: "Planned", tone: "neutral", completed: 0, total: 0 };
  const statusLabel = attention?.label ?? state.label;
  return {
    description: group?.description || undefined,
    scope: scopeLabel(model.groupScopes.get(rect.id)),
    status: state.total ? `${statusLabel} \u00b7 ${state.completed}/${state.total}` : statusLabel,
    title: group?.title?.trim() || "Untitled group",
    tone: attention?.tone ?? state.tone,
  };
}

function workPackageCardView(
  model: ExecutionGraphLayoutModel,
  rect: GraphEntityRect,
  now: string | number | Date | undefined,
  attention: Pick<DirectAttention, "label" | "tone"> | undefined,
  contextPath: ContextPathPart[] | undefined,
) {
  const ref = model.refs.get(rect.id) ?? { id: rect.id };
  const signal = model.signals.get(rect.id);
  const state = attentionState(attention, cardState(ref, signal, now));
  const title = workPackageTitle(ref);
  const progress = dependencyProgress(model, rect.key);
  const dependencyLabel = accessibleDependencyLabel(model, rect.key, signal, progress.satisfied, progress.required);
  const groupLabel = groupAncestryLabel(model, ref.group_id);
  const scope = scopeLabel(model.packageScopes.get(ref.id));
  const pr = signal?.pr_signal;
  const prLabel = prBadgeLabel(pr);
  const reason = workPackageReason(ref, signal);
  return {
    accessibleLabel: sentenceLabel([title, groupLabel, scope, state.label, reason, prLabel, dependencyLabel]),
    contextPath: workPackageContextPath(model, ref, contextPath),
    dependencyLabel,
    groupLabel,
    pr,
    prLabel,
    scope,
    state,
    title,
  };
}

function attentionAction(attention: Pick<DirectAttention, "label" | "tone"> | undefined, onClick?: () => void) {
  return attention ? onClick : undefined;
}

function attentionState<T extends { label: string; tone: string }>(attention: Pick<DirectAttention, "label" | "tone"> | undefined, state: T) {
  return attention ?? state;
}

function workPackageTitle(ref: ExecutionGraphWorkPackageRef) {
  return ref.title?.trim() || ref.id;
}

function workPackageReason(ref: ExecutionGraphWorkPackageRef, signal?: ExecutionGraphWorkPackageSignals) {
  return firstText([(signal?.operational_state ?? ref.operational_state)?.reason]);
}

function workPackageContextPath(model: ExecutionGraphLayoutModel, ref: ExecutionGraphWorkPackageRef, contextPath?: ContextPathPart[]) {
  return contextPath ? contextPathValue([...contextPath, ...groupAncestryPath(model, ref.group_id)]) : undefined;
}

function GraphStatus({ label, actionLabel, onClick }: { label: string; actionLabel: string; onClick?: () => void }) {
  return onClick ? (
    <button type="button" className="execution-graph__status execution-graph__status--action" aria-label={actionLabel} onClick={onClick}>{label}</button>
  ) : (
    <span className="execution-graph__status">{label}</span>
  );
}

function scopeLabel(scope?: { repo: string; branch?: string | null }) {
  return scope ? [compactRepoLabel(scope.repo), scope.branch].filter(Boolean).join(" · ") : undefined;
}

function compactRepoLabel(repo: string) {
  return repo.trim().replaceAll("\\", "/").replace(/\/$/, "").split("/").at(-1) || repo;
}

function accessibleDependencyLabel(
  model: ExecutionGraphLayoutModel,
  targetKey: string,
  signal: ExecutionGraphWorkPackageSignals | undefined,
  satisfied: number,
  required: number,
) {
  const dependency = signal?.dependency_signal;
  if (dependency?.inputs.length) {
    const names = dependency.inputs.map(({ work_package_id: id }) => model.refs.get(id)?.title?.trim() || id).join(", ");
    return `Dependencies ${dependency.satisfied} of ${dependency.required} satisfied: ${names}`;
  }
  const incoming = model.incoming.get(targetKey) ?? [];
  if (!incoming.length) return "No prerequisites";
  const names = incoming.map((dependency) => entityTitle(model, dependency.source_key)).join(", ");
  return `Dependencies ${satisfied} of ${required} satisfied: ${names}`;
}

function entityTitle(model: ExecutionGraphLayoutModel, key: string) {
  const [kind, id] = key.split(":", 2);
  return kind === "group" ? model.groups.get(id)?.title?.trim() || id : model.refs.get(id)?.title?.trim() || id;
}

function groupAncestryLabel(model: ExecutionGraphLayoutModel, groupId?: string | null) {
  const names = groupAncestryPath(model, groupId).map((part) => part.label);
  return names.length ? `Group path ${names.join(" › ")}` : "Ungrouped";
}

function groupAncestryPath(model: ExecutionGraphLayoutModel, groupId?: string | null): ContextPathPart[] {
  const path: ContextPathPart[] = [];
  const seen = new Set<string>();
  let currentId = groupId;
  while (currentId && !seen.has(currentId)) {
    seen.add(currentId);
    const group = model.groups.get(currentId);
    if (!group) break;
    path.unshift({ id: group.id, label: group.title?.trim() || "Untitled group" });
    currentId = group.parent_group_id;
  }
  return path;
}

function cardState(ref: ExecutionGraphWorkPackageRef, signal?: ExecutionGraphWorkPackageSignals, now?: string | number | Date) {
  const operational = signal?.operational_state ?? ref.operational_state;
  const status = firstText([signal?.raw_status, ref.raw_status, ref.status]) ?? "planned";
  return terminalCardState(ref, signal, status)
    ?? failedCardState(status, signal)
    ?? operationalBlockerCardState(operational)
    ?? activeCardState(signal, now)
    ?? dependencyCardState(signal)
    ?? fallbackCardState(status, operational);
}

type CardState = {
  label: string;
  tone: "active" | "ready" | "waiting" | "blocked" | "complete" | "neutral";
};

function terminalCardState(ref: ExecutionGraphWorkPackageRef, signal: ExecutionGraphWorkPackageSignals | undefined, status: string): CardState | undefined {
  if (!workPackageIsFinished(ref, signal)) return undefined;
  return { label: /merge/i.test(status) ? "Merged" : "Complete", tone: "complete" };
}

function failedCardState(status: string, signal?: ExecutionGraphWorkPackageSignals): CardState | undefined {
  if (/block|error|fail/.test(status.toLowerCase())) return { label: humanize(status), tone: "blocked" };
  if (signal?.review_signal?.status === "failed") return { label: "Review failed", tone: "blocked" };
  const checks = signal?.pr_signal?.checks;
  if (checks?.status === "failing") return { label: `CI${progressText(checks.current, checks.total)} failed`, tone: "blocked" };
  return undefined;
}

function operationalBlockerCardState(operational?: ExecutionGraphWorkPackageRef["operational_state"]): CardState | undefined {
  if (!operationalStateIsBlocked(operational)) return undefined;
  return { label: firstText([operational?.label]) ?? "Blocked", tone: "blocked" };
}

function activeCardState(signal?: ExecutionGraphWorkPackageSignals, now?: string | number | Date): CardState | undefined {
  const review = signal?.review_signal;
  if (review?.status === "in_progress") return { label: `Review${progressText(review.current, review.total)}`, tone: "active" };
  const checks = signal?.pr_signal?.checks;
  if (checks?.status === "pending") return { label: `CI${progressText(checks.current, checks.total)}`, tone: "active" };
  const worker = signal?.worker_signal;
  if (worker?.status !== "active") return undefined;
  return { label: ["Active", elapsedLabel(worker.active_since, now)].filter(Boolean).join(" · "), tone: "active" };
}

function dependencyCardState(signal?: ExecutionGraphWorkPackageSignals): CardState | undefined {
  const dependency = signal?.dependency_signal;
  if (!dependency || (dependency.required <= dependency.satisfied && dependency.blocked <= 0)) return undefined;
  return { label: `Waiting ${dependency.satisfied}/${dependency.required}`, tone: "waiting" };
}

function fallbackCardState(status: string, operational?: ExecutionGraphWorkPackageRef["operational_state"]): CardState {
  const source = firstText([operational?.key, operational?.label, status]) ?? status;
  return { label: firstText([operational?.label]) ?? humanize(source), tone: cardTone(source.toLowerCase()) };
}

function progressText(current?: number | null, total?: number | null) {
  return current == null || total == null ? "" : ` ${current}/${total}`;
}

function cardTone(source: string) {
  if (/ready/.test(source)) return "ready" as const;
  if (/planned/.test(source)) return "neutral" as const;
  if (/wait|pending|queued/.test(source)) return "waiting" as const;
  if (/pass|merge|finish|done|success|complete/.test(source)) return "complete" as const;
  if (/active|implement|reviewing|in progress/.test(source)) return "active" as const;
  if (/block|error|fail/.test(source)) return "blocked" as const;
  return "neutral" as const;
}

function firstText(values: Array<string | null | undefined>) {
  return values.map((value) => value?.trim()).find(Boolean);
}

function sentenceLabel(values: Array<string | null | undefined>) {
  const text = values.map((value) => value?.trim().replace(/[.]+$/, "")).filter(Boolean).join(". ");
  return text ? `${text}.` : undefined;
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
