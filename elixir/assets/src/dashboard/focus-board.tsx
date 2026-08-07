import type { ActiveBlockingEdge, GuidanceItem, WorkPackageCard, WorkRequestDetail } from "@/types/dashboard";
import { Activity, CircleAlert } from "lucide-react";
import { lazy, Suspense, useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState, type ReactNode } from "react";
import { flushSync } from "react-dom";

import { dashboardPrefersReducedMotion } from "@/components/dashboard/motion-utils";
import { buildFocusBoardItems, requestHasExecutionBoard, scrollFocusLane, type FocusBoardItem } from "./focus-board-data";
import type { FocusFrontierVariant } from "./execution-graph/adapter";
import { repoDisplayName, repoIdentityKey } from "./dashboard-persistence";
import type { CardDetailSelect, DashboardUpdateAnimations } from "./runtime";
import { requestActionableAttentionCounts, type AttentionJumpTarget, type AttentionSelect } from "./workstream-attention";
import { ProductRequestRow } from "./workstream-board";
import { sortWorkRequestDetails } from "./workstream-data";

const WorkRequestExecutionGraph = lazy(() => import("./work-request-execution-graph-loading"));
const FOCUS_BOARD_COLUMNS = ["pr", "state"] as const;
const FRONTIER_VARIANTS = [
  ["horizon-1", "A Horizon 1"],
  ["forward-2", "B 1 back · 2 ahead"],
] as const satisfies ReadonlyArray<readonly [FocusFrontierVariant, string]>;

type WorkbenchMode = "frontier" | "full";
type FocusBoardTransition = "close" | "open" | "swap";
let activeFocusBoardTransition: ViewTransition | null = null;

export function FocusBoardLoading({ openCount }: { openCount: number }) {
  return (
    <section className="focus-board rounded-lg border bg-card text-card-foreground shadow-sm" aria-busy="true" aria-labelledby="focus-board-loading-title">
      <FocusBoardHeader id="focus-board-loading-title" openCount={openCount} />
    </section>
  );
}

export function FocusBoard({
  details,
  now,
  packages,
  activeBlockingEdges,
  guidanceItems = [],
  jumpTarget,
  onSelectAttention,
  onSelectGuidance,
  onSelectCard,
  primaryBranchByRepo,
  updateAnimations,
}: {
  details: WorkRequestDetail[];
  now?: string;
  packages: WorkPackageCard[];
  activeBlockingEdges: ActiveBlockingEdge[];
  guidanceItems?: GuidanceItem[];
  jumpTarget?: AttentionJumpTarget | null;
  onSelectAttention: AttentionSelect;
  onSelectGuidance: (item: GuidanceItem) => void;
  onSelectCard: CardDetailSelect;
  primaryBranchByRepo: Map<string, string | undefined>;
  updateAnimations: DashboardUpdateAnimations;
}) {
  const packageById = useMemo(() => new Map(packages.map((pkg) => [pkg.id, pkg])), [packages]);
  const attentionCounts = useMemo(
    () => new Map(details.map((detail) => [
      detail.work_request.id,
      requestActionableAttentionCounts(detail, packageById, activeBlockingEdges, guidanceItems),
    ])),
    [activeBlockingEdges, details, guidanceItems, packageById],
  );
  const items = useMemo(() => buildFocusBoardItems(sortWorkRequestDetails(details), now, packageById, attentionCounts), [attentionCounts, details, now, packageById]);
  const needsAttention = items.filter((item) => item.lane === "attention");
  const moving = items.filter((item) => item.lane === "active" || item.lane === "next");
  const shelfItems = [...needsAttention, ...moving];
  const defaultItem = shelfItems.find((item) => requestHasExecutionBoard(item.detail)) ?? shelfItems[0] ?? items.find((item) => requestHasExecutionBoard(item.detail)) ?? items[0];
  const [selectedRequestId, setSelectedRequestId] = useState<string | null>();
  const [renderedRequestId, setRenderedRequestId] = useState<string>();
  const [workbenchOpen, setWorkbenchOpen] = useState(true);
  const [mode, setMode] = useState<WorkbenchMode>("frontier");
  const [frontierVariant, setFrontierVariant] = useState<FocusFrontierVariant>("horizon-1");
  const { renderedItem, selectedItem, workbenchVisible } = focusBoardSelection(items, defaultItem, selectedRequestId, renderedRequestId, workbenchOpen);
  const boardRef = useRef<HTMLElement | null>(null);
  const handledJumpTokenRef = useRef(0);
  const itemIndexById = useMemo(() => new Map(items.map((item, index) => [item.id, index])), [items]);
  const updateView = useCallback((requestId: string | null, nextMode: WorkbenchMode) => {
    const transition = requestId === null ? "close" : selectedRequestId === null ? "open" : "swap";
    animateFocusBoardUpdate(transition, () => setSelectedRequestId(requestId), () => {
      if (requestId) setRenderedRequestId(requestId);
      setWorkbenchOpen(requestId !== null);
      setMode(nextMode);
    });
  }, [selectedRequestId]);
  const jumpToView = useCallback((requestId: string, nextMode: WorkbenchMode) => {
    setSelectedRequestId(requestId);
    setRenderedRequestId(requestId);
    setWorkbenchOpen(true);
    setMode(nextMode);
  }, []);

  useFocusBoardColumnWidths(boardRef, items);
  useAttentionJump(boardRef, items, jumpTarget, selectedItem, mode, handledJumpTokenRef, jumpToView);

  const selectItem = (item: FocusBoardItem, open: boolean) => updateView(open ? item.id : null, "frontier");
  const renderItem = (item: FocusBoardItem) => (
    <ProductRequestRow
      key={item.id}
      detail={item.detail}
      now={now}
      activeBlockingEdges={activeBlockingEdges}
      guidanceItems={guidanceItems}
      packageById={packageById}
      expanded={false}
      focusSelected={selectedItem?.id === item.id}
      index={itemIndexById.get(item.id) ?? 0}
      onSetOpen={(open) => selectItem(item, open)}
      onSelectAttention={onSelectAttention}
      onSelectGuidance={onSelectGuidance}
      onSelectCard={onSelectCard}
      primaryBranch={primaryBranchByRepo.get(repoIdentityKey(item.detail.work_request))}
      frontierMode={item.lane}
      selectionMode
      autoCollapseWhenDone={false}
      updateAnimations={updateAnimations}
    />
  );
  const previewItem = focusCardPreviewQuery()
    ? items.find((item) => (item.detail.work_request.title || item.id).toLowerCase().includes(focusCardPreviewQuery()!))
    : undefined;

  if (previewItem) {
    return <section ref={boardRef} className="focus-card-preview" aria-label="WorkRequest card preview"><div className="workstream-board-shell"><div className="v3-workstream-board">{renderItem(previewItem)}</div></div></section>;
  }

  const openCount = items.filter((item) => item.lane !== "recent").length;
  return (
    <section
      ref={boardRef}
      className="focus-board rounded-lg border bg-card text-card-foreground shadow-sm"
      aria-labelledby="focus-board-title"
      data-focus-request-id={selectedItem?.id}
    >
      <FocusBoardHeader id="focus-board-title" openCount={openCount} />
      <div className="focus-board__shelf">
        <FocusShelf label="Needs you" description="Human attention" icon={<CircleAlert className="size-4" />} items={needsAttention} renderItem={renderItem} />
        <FocusShelf label="Moving now" description="Active or ready" icon={<Activity className="size-4" />} items={moving} renderItem={renderItem} />
      </div>
      <div className="focus-board__workbench-reveal v3-disclosure-reveal" data-open={workbenchVisible ? "true" : "false"} aria-hidden={!workbenchVisible} inert={!workbenchVisible}>
        <FocusWorkbench
          activeBlockingEdges={activeBlockingEdges}
          guidanceItems={guidanceItems}
          item={renderedItem}
          frontierVariant={frontierVariant}
          mode={mode}
          now={now}
          onModeChange={setMode}
          onFrontierVariantChange={setFrontierVariant}
          onSelectAttention={onSelectAttention}
          onSelectCard={onSelectCard}
          packageById={packageById}
        />
      </div>
    </section>
  );
}

function FocusBoardHeader({ id, openCount }: { id: string; openCount: number }) {
  return (
    <header className="focus-board__header">
      <div><h2 id={id}>Focus Board</h2><span>{openCount} open across repositories</span></div>
      <strong>Experimental</strong>
    </header>
  );
}

function FocusShelf({ label, description, icon, items, renderItem }: { label: string; description: string; icon: ReactNode; items: FocusBoardItem[]; renderItem: (item: FocusBoardItem) => ReactNode }) {
  const laneRef = useRef<HTMLDivElement | null>(null);
  useEffect(() => {
    const lane = laneRef.current;
    if (!lane) return;
    const onWheel = (event: WheelEvent) => {
      if (event.ctrlKey || !scrollFocusLane(lane, event.deltaX, event.deltaY)) return;
      event.preventDefault();
    };
    lane.addEventListener("wheel", onWheel, { passive: false });
    return () => lane.removeEventListener("wheel", onWheel);
  }, []);
  return (
    <section className="focus-board__signal" aria-label={`${label}, ${items.length}`}>
      <div className="focus-board__signal-label"><span>{icon}<strong>{label}</strong></span><small>{description} · {items.length}</small></div>
      {items.length ? (
        <div className="focus-board__shelf-row workstream-board-shell"><div ref={laneRef} className="v3-workstream-board" role="region" tabIndex={0} aria-label={`${label} WorkRequests`}>{items.map(renderItem)}</div></div>
      ) : <p className="focus-board__clear">Clear</p>}
    </section>
  );
}

function FocusWorkbench({ activeBlockingEdges, frontierVariant, guidanceItems, item, mode, now, onFrontierVariantChange, onModeChange, onSelectAttention, onSelectCard, packageById }: {
  activeBlockingEdges: ActiveBlockingEdge[];
  frontierVariant: FocusFrontierVariant;
  guidanceItems: GuidanceItem[];
  item?: FocusBoardItem;
  mode: WorkbenchMode;
  now?: string;
  onFrontierVariantChange: (variant: FocusFrontierVariant) => void;
  onModeChange: (mode: WorkbenchMode) => void;
  onSelectAttention: AttentionSelect;
  onSelectCard: CardDetailSelect;
  packageById: Map<string, WorkPackageCard>;
}) {
  if (!item) return <div className="focus-board__workbench focus-board__workbench--empty">No active WorkRequests.</div>;
  const detail = item.detail;
  const request = detail.work_request;
  const title = request.title || request.id;
  const hasGraph = requestHasExecutionBoard(detail);
  const requestPath = [{ id: request.id, label: title }];
  return (
    <section className="focus-board__workbench" aria-labelledby="focus-workbench-title" data-mode={mode}>
      <header className="focus-board__workbench-header">
        <div><h3 id="focus-workbench-title">{title}</h3><p>{repoDisplayName(request)} · {request.id}</p></div>
        <div className="focus-board__workbench-controls">
          {mode === "frontier" ? <div className="focus-board__concept-switch" aria-label="Frontier concept">
            {FRONTIER_VARIANTS.map(([variant, label]) => (
              <button key={variant} type="button" aria-pressed={frontierVariant === variant} onClick={() => onFrontierVariantChange(variant)}>{label}</button>
            ))}
          </div> : null}
          <div className="focus-board__mode-switch" aria-label="Dependency board view">
            <button type="button" aria-pressed={mode === "frontier"} onClick={() => onModeChange("frontier")}>Frontier</button>
            <button type="button" aria-pressed={mode === "full"} disabled={!hasGraph} onClick={() => onModeChange("full")}>Full map</button>
          </div>
        </div>
      </header>
      <div className="focus-board__workbench-body">
        {hasGraph ? (
          <div className="v3-execution-graph">
            <Suspense fallback={<div className="v3-execution-graph-loading" role="status" aria-label="Loading execution graph" />}>
              <WorkRequestExecutionGraph key={request.id} activeBlockingEdges={activeBlockingEdges} detail={detail} frontierVariant={frontierVariant} guidanceItems={guidanceItems} now={now} packageById={packageById} onSelectAttention={onSelectAttention} onSelectCard={onSelectCard} requestPath={requestPath} viewMode={mode} />
            </Suspense>
          </div>
        ) : <p className="focus-board__workbench-note">No work has been created yet.</p>}
      </div>
    </section>
  );
}

function useFocusBoardColumnWidths(boardRef: React.RefObject<HTMLElement | null>, items: FocusBoardItem[]) {
  useLayoutEffect(() => {
    const root = boardRef.current;
    if (!root) return;
    let frame: number | null = null;
    const measure = () => {
      for (const column of FOCUS_BOARD_COLUMNS) {
        const elements = [...root.querySelectorAll<HTMLElement>(`[data-frontier-measure="${column}"]`)].filter((element) => element.getClientRects().length > 0);
        const width = elements.reduce((maximum, element) => Math.max(maximum, element.scrollWidth), 0);
        root.style.setProperty(`--focus-frontier-${column}-width`, `${Math.ceil(width)}px`);
      }
    };
    const observer = typeof ResizeObserver === "undefined" ? undefined : new ResizeObserver(() => {
      if (frame !== null) cancelAnimationFrame(frame);
      frame = requestAnimationFrame(measure);
    });
    measure();
    observer?.observe(root);
    return () => { observer?.disconnect(); if (frame !== null) cancelAnimationFrame(frame); };
  }, [boardRef, items]);
}

function useAttentionJump(
  boardRef: React.RefObject<HTMLElement | null>,
  items: FocusBoardItem[],
  jumpTarget: AttentionJumpTarget | null | undefined,
  selectedItem: FocusBoardItem | undefined,
  mode: WorkbenchMode,
  handledToken: React.MutableRefObject<number>,
  updateView: (id: string, mode: WorkbenchMode) => void,
) {
  useEffect(() => {
    if (!jumpTarget || handledToken.current >= jumpTarget.token || !items.some((item) => item.id === jumpTarget.requestId)) return;
    updateView(jumpTarget.requestId, "full");
  }, [handledToken, items, jumpTarget, updateView]);
  useEffect(() => {
    if (!jumpTarget || handledToken.current >= jumpTarget.token || selectedItem?.id !== jumpTarget.requestId || mode !== "full") return;
    const root = boardRef.current;
    if (!root) return;
    const reveal = () => {
      let target: HTMLElement | null = root.querySelector(".focus-board__workbench");
      const viewport = visibleGraphViewport(root);
      if ((jumpTarget.groupIds.length || jumpTarget.workPackageId) && !viewport) return;
      for (const groupId of jumpTarget.groupIds) {
        const group = elementWithData(viewport!, "groupId", groupId);
        if (!group) return;
        const toggle = group.querySelector<HTMLButtonElement>(":scope > .execution-graph__group-header");
        if (toggle?.getAttribute("aria-expanded") === "false") { toggle.click(); return; }
        target = group;
      }
      if (jumpTarget.workPackageId) {
        const workPackage = elementWithData(viewport!, "workPackageId", jumpTarget.workPackageId);
        if (!workPackage) return;
        target = workPackage;
      }
      if (!target) return;
      handledToken.current = jumpTarget.token;
      target.dataset.attentionJump = "true";
      target.scrollIntoView({ block: "center", inline: "center", behavior: dashboardPrefersReducedMotion() ? "auto" : "smooth" });
      window.setTimeout(() => delete target!.dataset.attentionJump, 1_800);
      observer.disconnect();
    };
    const observer = new MutationObserver(reveal);
    observer.observe(root, { attributes: true, childList: true, subtree: true });
    const frame = requestAnimationFrame(reveal);
    return () => { observer.disconnect(); cancelAnimationFrame(frame); };
  }, [boardRef, handledToken, jumpTarget, mode, selectedItem]);
}

function animateFocusBoardUpdate(kind: FocusBoardTransition, prepare: () => void, update: () => void) {
  if (typeof document === "undefined" || dashboardPrefersReducedMotion() || !document.startViewTransition) {
    flushSync(() => { prepare(); update(); });
    return;
  }
  flushSync(prepare);
  document.documentElement.dataset.focusBoardTransition = kind;
  const transition = document.startViewTransition(() => flushSync(update));
  activeFocusBoardTransition = transition;
  void transition.finished.finally(() => {
    if (activeFocusBoardTransition !== transition) return;
    delete document.documentElement.dataset.focusBoardTransition;
    activeFocusBoardTransition = null;
  });
}

function focusBoardSelection(items: FocusBoardItem[], defaultItem: FocusBoardItem | undefined, selectedId: string | null | undefined, renderedId: string | undefined, open: boolean) {
  const selectedItem = selectedId === null ? undefined : items.find((item) => item.id === selectedId) ?? defaultItem;
  return {
    renderedItem: items.find((item) => item.id === renderedId) ?? selectedItem ?? defaultItem,
    selectedItem,
    workbenchVisible: items.length === 0 || open,
  };
}

function visibleGraphViewport(root: HTMLElement) {
  return [...root.querySelectorAll<HTMLElement>(".execution-graph__viewport")].find((viewport) => viewport.getClientRects().length > 0);
}

function elementWithData(root: HTMLElement, key: "groupId" | "workPackageId", value: string) {
  const attribute = key === "groupId" ? "group-id" : "work-package-id";
  return [...root.querySelectorAll<HTMLElement>(`[data-${attribute}]`)].find((element) => element.dataset[key] === value);
}

function focusCardPreviewQuery() {
  return import.meta.env.DEV && typeof window !== "undefined" ? new URLSearchParams(window.location.search).get("focus-card-preview")?.trim().toLowerCase() : undefined;
}
