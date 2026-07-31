import type { ActiveBlockingEdge, GuidanceItem, WorkPackageCard, WorkRequestDetail } from "@/types/dashboard";
import { Activity, ArrowRight, CheckCircle2, ChevronRight, CircleAlert, Clock3, GitBranch } from "lucide-react";
import type { ReactNode } from "react";
import { useCallback, useEffect, useEffectEvent, useLayoutEffect, useMemo, useRef, useState } from "react";

import { dashboardPrefersReducedMotion } from "@/components/dashboard/motion-utils";
import type { CardDetailSelect, DashboardUpdateAnimations } from "./runtime";
import { ProductRequestRow } from "./workstream-board";
import { activeBlockerEntityCounts } from "./workstream-progress";
import { readStoredFocusBoardSectionOpen, repoIdentityKey, writeStoredFocusBoardSectionOpen } from "./dashboard-persistence";
import { buildFocusBoardItems, groupFocusItemsByRepo, preserveFocusedItem, requestHasExecutionBoard, type FocusBoardItem, type FocusBoardLane } from "./focus-board-data";
import { focusAttachOffset, focusCameraTop, focusSectionOffset, focusSpaceOffsets, focusTravelScale, type FocusEjectOffset, type FocusEjectRect } from "./focus-board-motion";
import type { AttentionJumpTarget, AttentionSelect } from "./workstream-attention";
const FOCUS_BOARD_COLUMNS = ["pr", "state"] as const;
const FOCUS_BOARD_COLUMN_CAPS_REM = { pr: Number.POSITIVE_INFINITY, state: Number.POSITIVE_INFINITY };
const FOCUS_SPACE_MS = 660;
const FOCUS_GROUP_MS = 330;
const FOCUS_EXPANSE_MS = 780;
const FOCUS_RETURN_MS = 720;
const FOCUS_CAMERA_TOP = 88;

type FocusPhase = "measuring" | "spacing" | "grouping" | "expanse-ready" | "expanding" | "focused" | "unexpanding" | "ungrouping" | "returning";
type FocusState = { item: FocusBoardItem; phase: FocusPhase };
type EjectedContent = { lanes: Set<FocusBoardLane>; repoGroups: Set<string>; requests: Set<string> };
const FOCUS_EJECTED_PHASES = new Set<FocusPhase>(["grouping", "expanse-ready", "expanding", "focused", "unexpanding", "ungrouping", "returning"]);
const NO_EJECTED_CONTENT: EjectedContent = { lanes: new Set(), repoGroups: new Set(), requests: new Set() };

function visibleEjectedContent(phase: FocusPhase | undefined, content: EjectedContent) {
  return phase && FOCUS_EJECTED_PHASES.has(phase) ? content : NO_EJECTED_CONTENT;
}

function measureFocusRows(rows: HTMLElement[]) {
  const rects: FocusEjectRect[] = [];
  for (const row of rows) {
    const rect = row.getBoundingClientRect();
    const id = row.dataset.requestId;
    if (id) rects.push({ id, left: rect.left, top: rect.top, width: rect.width, height: rect.height });
  }
  return rects;
}

function applyFocusOffsets(rows: HTMLElement[], offsets: Map<string, FocusEjectOffset>) {
  for (const row of rows) {
    const offset = offsets.get(row.dataset.requestId ?? "");
    if (!offset) continue;
    row.style.setProperty("--focus-eject-x", `${offset.x}px`);
    row.style.setProperty("--focus-eject-y", `${offset.y}px`);
    row.style.setProperty("--focus-space-opacity", String(offset.opacity));
  }
}

function ejectedRequestIds(offsets: Map<string, FocusEjectOffset>) {
  const ids = new Set<string>();
  for (const [requestId, offset] of offsets) {
    if (offset.opacity === 0) ids.add(requestId);
  }
  return ids;
}

function applyFollowingSectionOffsets(selectedGrid: HTMLElement, travelScale: number) {
  const ejectedLanes = new Set<FocusBoardLane>();
  const selectedSection = selectedGrid.closest<HTMLElement>(".focus-board__section");
  if (!selectedSection) return ejectedLanes;
  for (let section = selectedSection.nextElementSibling; section instanceof HTMLElement; section = section.nextElementSibling) {
    const y = focusSectionOffset(section.getBoundingClientRect().top, window.innerHeight, travelScale);
    if (y === 0) continue;
    section.dataset.focusEjected = "true";
    section.style.setProperty("--focus-section-eject-y", `${y}px`);
    if (section.dataset.focusLane) ejectedLanes.add(section.dataset.focusLane as FocusBoardLane);
  }
  return ejectedLanes;
}

function applyFollowingRepoGroupOffsets(selectedGrid: HTMLElement, travelScale: number) {
  const ejectedRepoGroups = new Set<string>();
  const selectedGroup = selectedGrid.closest<HTMLElement>(".focus-board__repo-group");
  if (!selectedGroup) return ejectedRepoGroups;
  for (let group = selectedGroup.nextElementSibling; group instanceof HTMLElement; group = group.nextElementSibling) {
    const y = focusSectionOffset(group.getBoundingClientRect().top, window.innerHeight, travelScale);
    if (y === 0) continue;
    group.dataset.focusEjected = "true";
    group.style.setProperty("--focus-section-eject-y", `${y}px`);
    if (group.dataset.focusRepoKey) ejectedRepoGroups.add(group.dataset.focusRepoKey);
  }
  return ejectedRepoGroups;
}

function focusMotionScale() {
  if (!import.meta.env.DEV || typeof document === "undefined") return 1;
  const value = Number(document.documentElement.dataset.focusMotionScale);
  return [1, 5, 10].includes(value) ? value : 1;
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
  const blockerCounts = useMemo(() => activeBlockerEntityCounts(activeBlockingEdges, details), [activeBlockingEdges, details]);
  const classifiedItems = useMemo(() => buildFocusBoardItems(details, now, packageById, blockerCounts.requests), [blockerCounts.requests, details, now, packageById]);
  const [focus, setFocus] = useState<FocusState | null>(null);
  const [inlineExpandedRequestId, setInlineExpandedRequestId] = useState<string>();
  const items = useMemo(() => preserveFocusedItem(classifiedItems, focus?.item), [classifiedItems, focus?.item]);
  const boardRef = useRef<HTMLElement | null>(null);
  const [ejectedContent, setEjectedContent] = useState<EjectedContent>(NO_EJECTED_CONTENT);
  const cameraFrameRef = useRef<number | null>(null);
  const phaseFrameRef = useRef<number | null>(null);
  const timersRef = useRef<number[]>([]);
  const handledJumpTokenRef = useRef(0);

  const clearTimers = useCallback(() => {
    for (const timer of timersRef.current) window.clearTimeout(timer);
    timersRef.current = [];
    if (cameraFrameRef.current !== null) window.cancelAnimationFrame(cameraFrameRef.current);
    cameraFrameRef.current = null;
    if (phaseFrameRef.current !== null) window.cancelAnimationFrame(phaseFrameRef.current);
    phaseFrameRef.current = null;
  }, []);
  const schedule = useCallback((callback: () => void, delay: number) => {
    timersRef.current.push(window.setTimeout(callback, delay));
  }, []);
  const scheduleAfterPaint = useCallback((callback: () => void) => {
    phaseFrameRef.current = window.requestAnimationFrame(() => {
      phaseFrameRef.current = window.requestAnimationFrame(() => {
        phaseFrameRef.current = null;
        callback();
      });
    });
  }, []);
  const requestRows = useCallback(() => [...(boardRef.current?.querySelectorAll<HTMLElement>(".v3-request-row") ?? [])], []);
  const clearEjectOffsets = useCallback(() => {
    boardRef.current?.style.removeProperty("--focus-attach-offset");
    for (const row of requestRows()) {
      row.style.removeProperty("--focus-eject-x");
      row.style.removeProperty("--focus-eject-y");
      row.style.removeProperty("--focus-space-opacity");
    }
    for (const group of boardRef.current?.querySelectorAll<HTMLElement>(".focus-board__section[data-focus-ejected], .focus-board__repo-group[data-focus-ejected]") ?? []) {
      delete group.dataset.focusEjected;
      group.style.removeProperty("--focus-section-eject-y");
    }
    setEjectedContent(NO_EJECTED_CONTENT);
  }, [requestRows]);
  const animateCamera = useCallback((top: number, duration: number) => {
    if (cameraFrameRef.current !== null) window.cancelAnimationFrame(cameraFrameRef.current);
    const start = window.scrollY;
    const distance = top - start;
    const startedAt = performance.now();
    const step = (now: number) => {
      const progress = Math.min(1, (now - startedAt) / duration);
      window.scrollTo({ top: start + distance * (1 - ((1 - progress) ** 3)), behavior: "auto" });
      cameraFrameRef.current = progress < 1 ? window.requestAnimationFrame(step) : null;
    };
    cameraFrameRef.current = window.requestAnimationFrame(step);
  }, []);
  useEffect(() => () => {
    clearTimers();
    clearEjectOffsets();
  }, [clearEjectOffsets, clearTimers]);

  const beginFocus = useCallback((id: string) => {
    if (focus) return;
    const item = items.find((candidate) => candidate.id === id)!;
    clearTimers();
    setInlineExpandedRequestId(undefined);
    setFocus({ item, phase: "measuring" });
  }, [clearTimers, focus, items]);

  useLayoutEffect(() => {
    if (focus?.phase !== "measuring") return;
    const id = focus.item.id;
    const selectedRow = requestRows().find((row) => row.dataset.requestId === id);
    const selectedGrid = selectedRow?.closest<HTMLElement>(".v3-workstream-board");
    if (!selectedRow || !selectedGrid) return;
    const rows = requestRows().filter((row) => row.closest(".v3-workstream-board") === selectedGrid);
    const rects = measureFocusRows(rows);
    const frontierHeight = selectedRow.querySelector<HTMLElement>(".v3-request-frontier")?.getBoundingClientRect().height ?? 0;
    const groupedRects = rects.map((rect) => rect.id === id ? { ...rect, height: Math.max(0, rect.height - frontierHeight) } : rect);
    const attachOffset = focusAttachOffset(groupedRects, id);
    boardRef.current?.style.setProperty("--focus-attach-offset", `${attachOffset}px`);
    const expandedHeight = selectedGrid.querySelector<HTMLElement>(".focus-board__expanded-request")?.getBoundingClientRect().height ?? 0;
    const travelScale = focusTravelScale(expandedHeight, window.innerHeight);
    const offsets = focusSpaceOffsets(
      rects,
      id,
      { width: window.innerWidth, height: window.innerHeight },
      selectedGrid.getBoundingClientRect().left,
      travelScale,
    );
    applyFocusOffsets(rows, offsets);
    const nextEjectedContent = {
      requests: ejectedRequestIds(offsets),
      repoGroups: applyFollowingRepoGroupOffsets(selectedGrid, travelScale),
      lanes: applyFollowingSectionOffsets(selectedGrid, travelScale),
    };
    const selectedRect = selectedRow.getBoundingClientRect();
    const focusedHeight = selectedRect.height - frontierHeight + expandedHeight - attachOffset;
    const cameraTop = focusCameraTop(window.scrollY, selectedRect.top, focusedHeight, window.innerHeight, FOCUS_CAMERA_TOP);

    const motionScale = focusMotionScale();
    schedule(() => {
      setEjectedContent(nextEjectedContent);
      if (dashboardPrefersReducedMotion()) {
        setFocus((current) => current ? { ...current, phase: "focused" } : null);
        window.scrollTo({ top: cameraTop, behavior: "auto" });
        return;
      }
      setFocus((current) => current ? { ...current, phase: "spacing" } : null);
      schedule(() => {
        setFocus((current) => current ? { ...current, phase: "grouping" } : null);
        schedule(() => {
          setFocus((current) => current ? { ...current, phase: "expanse-ready" } : null);
          scheduleAfterPaint(() => {
            setFocus((current) => current ? { ...current, phase: "expanding" } : null);
            animateCamera(cameraTop, FOCUS_EXPANSE_MS * motionScale);
            schedule(() => setFocus((current) => current ? { ...current, phase: "focused" } : null), FOCUS_EXPANSE_MS * motionScale);
          });
        }, FOCUS_GROUP_MS * motionScale);
      }, FOCUS_SPACE_MS * motionScale);
    }, 0);
  }, [animateCamera, focus, requestRows, schedule, scheduleAfterPaint]);

  const endFocus = useCallback(() => {
    if (!focus) return;
    clearTimers();
    if (dashboardPrefersReducedMotion()) {
      setFocus(null);
      clearEjectOffsets();
      return;
    }
    const motionScale = focusMotionScale();
    setFocus({ ...focus, phase: "unexpanding" });
    schedule(() => {
      setFocus((current) => current ? { ...current, phase: "ungrouping" } : null);
      schedule(() => {
        setFocus((current) => current ? { ...current, phase: "returning" } : null);
        schedule(() => {
          setFocus(null);
          clearEjectOffsets();
        }, FOCUS_RETURN_MS * motionScale);
      }, FOCUS_GROUP_MS * motionScale);
    }, FOCUS_EXPANSE_MS * motionScale);
  }, [clearEjectOffsets, clearTimers, focus, schedule]);

  useEffect(() => {
    if (!jumpTarget || handledJumpTokenRef.current >= jumpTarget.token) return;
    const jumpItem = items.find((item) => item.id === jumpTarget.requestId);
    if (!jumpItem) return;

    if (focus && focus.item.id !== jumpTarget.requestId) {
      clearTimers();
      schedule(() => {
        setFocus(null);
        clearEjectOffsets();
      }, 0);
      return;
    }
    if (!requestHasExecutionBoard(jumpItem.detail)) {
      handledJumpTokenRef.current = jumpTarget.token;
      schedule(() => {
        setInlineExpandedRequestId(jumpTarget.requestId);
        window.requestAnimationFrame(() => requestRows().find((row) => row.dataset.requestId === jumpTarget.requestId)?.scrollIntoView({
          block: "center",
          behavior: dashboardPrefersReducedMotion() ? "auto" : "smooth",
        }));
      }, 0);
      return;
    }
    if (!focus) {
      schedule(() => beginFocus(jumpTarget.requestId), 0);
      return;
    }
    if (focus.phase !== "focused") return;

    const root = boardRef.current;
    if (!root) return;
    let frame = 0;
    const revealTarget = () => {
      const row = requestRows().find((candidate) => candidate.dataset.requestId === jumpTarget.requestId);
      if (!row) return;
      let target: HTMLElement = row;
      const viewport = visibleGraphViewport(row);

      if (jumpTarget.groupIds.length || jumpTarget.workPackageId) {
        if (!viewport) return;
        for (const groupId of jumpTarget.groupIds) {
          const group = elementWithData(viewport, "groupId", groupId);
          if (!group) return;
          const toggle = group.querySelector<HTMLButtonElement>(":scope > .execution-graph__group-header");
          if (toggle?.getAttribute("aria-expanded") === "false") {
            toggle.click();
            return;
          }
          target = group;
        }
        if (jumpTarget.workPackageId) {
          const workPackage = elementWithData(viewport, "workPackageId", jumpTarget.workPackageId);
          if (!workPackage) return;
          target = workPackage;
        }
      }

      handledJumpTokenRef.current = jumpTarget.token;
      target.dataset.attentionJump = "true";
      target.scrollIntoView({
        block: "center",
        inline: "center",
        behavior: dashboardPrefersReducedMotion() ? "auto" : "smooth",
      });
      window.setTimeout(() => delete target.dataset.attentionJump, 1_800);
      observer.disconnect();
    };
    const observer = new MutationObserver(revealTarget);
    observer.observe(root, { attributes: true, childList: true, subtree: true });
    frame = window.requestAnimationFrame(revealTarget);
    return () => {
      observer.disconnect();
      window.cancelAnimationFrame(frame);
    };
  }, [beginFocus, clearEjectOffsets, clearTimers, focus, items, jumpTarget, requestRows, schedule]);

  const endFocusEvent = useEffectEvent(endFocus);
  useEffect(() => {
    if (!focus) return;
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === "Escape") endFocusEvent();
    };
    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  }, [focus]);

  useLayoutEffect(() => {
    const root = boardRef.current;
    if (!root) return;

    let frame: number | null = null;
    const measure = () => {
      const rootFontSize = Number.parseFloat(getComputedStyle(root).fontSize);

      for (const column of FOCUS_BOARD_COLUMNS) {
        const elements = [...root.querySelectorAll<HTMLElement>(`[data-frontier-measure="${column}"]`)]
          .filter((element) => element.getClientRects().length > 0);
        const previousStyles = elements.map((element) => ({ whiteSpace: element.style.whiteSpace, width: element.style.width }));
        for (const element of elements) {
          element.style.whiteSpace = "nowrap";
          element.style.width = "max-content";
        }
        const width = elements.reduce((maximum, element) => Math.max(maximum, element.scrollWidth), 0);
        elements.forEach((element, index) => {
          element.style.whiteSpace = previousStyles[index].whiteSpace;
          element.style.width = previousStyles[index].width;
        });
        const property = `--focus-frontier-${column}-width`;
        const value = `${Math.ceil(Math.min(width, FOCUS_BOARD_COLUMN_CAPS_REM[column] * rootFontSize))}px`;
        if (root.style.getPropertyValue(property) !== value) root.style.setProperty(property, value);
      }
    };
    const scheduleMeasure = () => {
      if (frame !== null) window.cancelAnimationFrame(frame);
      frame = window.requestAnimationFrame(() => {
        measure();
        frame = null;
      });
    };

    measure();
    if (typeof ResizeObserver === "undefined") return;

    const observer = new ResizeObserver(scheduleMeasure);
    observer.observe(root);

    return () => {
      observer.disconnect();
      if (frame !== null) window.cancelAnimationFrame(frame);
    };
  }, [items]);
  const itemIndexById = useMemo(() => new Map(items.map((item, index) => [item.id, index])), [items]);
  const focusedId = focus?.item.id;
  const focusPhase = focus?.phase;
  const hiddenContent = visibleEjectedContent(focusPhase, ejectedContent);
  const renderItem = (item: FocusBoardItem) => {
    const inlineExpanded = inlineExpandedRequestId === item.id;
    const focusExpanded = focusedId === item.id && ["grouping", "expanse-ready", "expanding", "focused", "unexpanding"].includes(focusPhase ?? "");
    const focusBodyVisible = focusedId === item.id && ["measuring", "spacing", "grouping", "expanse-ready", "expanding", "focused", "unexpanding"].includes(focusPhase ?? "");
    return (
      <ProductRequestRow
        key={item.id}
        detail={item.detail}
        now={now}
        activeBlockingEdges={activeBlockingEdges}
        guidanceItems={guidanceItems}
        packageById={packageById}
        activeBlockerCount={blockerCounts.requests.get(item.id) ?? 0}
        activeBlockerCountBySliceId={blockerCounts.slices}
        expanded={inlineExpanded || focusExpanded}
        expandedBodyVisible={inlineExpanded || focusBodyVisible}
        detachedExpandedBody={!inlineExpanded}
        focusEjected={hiddenContent.requests.has(item.id)}
        focusSelected={focusedId === item.id}
        index={itemIndexById.get(item.id) ?? 0}
        onSetOpen={() => {
          if (focusedId === item.id) endFocus();
          else if (inlineExpanded) setInlineExpandedRequestId(undefined);
          else if (requestHasExecutionBoard(item.detail)) beginFocus(item.id);
          else setInlineExpandedRequestId(item.id);
        }}
        onSelectAttention={onSelectAttention}
        onSelectGuidance={onSelectGuidance}
        onSelectCard={onSelectCard}
        primaryBranch={primaryBranchByRepo.get(repoIdentityKey(item.detail.work_request))}
        frontierMode={item.lane}
        autoCollapseWhenDone={false}
        updateAnimations={updateAnimations}
      />
    );
  };
  const previewQuery = import.meta.env.DEV && typeof window !== "undefined"
    ? new URLSearchParams(window.location.search).get("focus-card-preview")?.trim().toLowerCase()
    : undefined;
  const previewItem = previewQuery
    ? items.find((item) => (item.detail.work_request.title || item.id).toLowerCase().includes(previewQuery))
    : undefined;

  if (previewItem) {
    return (
      <section ref={boardRef} className="focus-card-preview" aria-label="WorkRequest card preview">
        <div className="workstream-board-shell"><div className="v3-workstream-board">{renderItem(previewItem)}</div></div>
      </section>
    );
  }

  const waiting = items.filter((item) => item.lane === "waiting");
  const openCount = items.filter((item) => item.lane !== "recent").length;

  return (
    <section
      ref={boardRef}
      className="focus-board grid gap-4 rounded-lg border bg-card p-4 text-card-foreground shadow-sm"
      aria-labelledby="focus-board-title"
      data-focus-phase={focusPhase}
      data-focus-request-id={focusedId}
    >
      <header className="focus-board__header flex items-center gap-2">
        <h2 id="focus-board-title" className="text-base font-semibold">Focus Board</h2>
        <span className="text-xs font-semibold text-muted-foreground">– {openCount} open</span>
      </header>
      <div className="focus-board__lanes grid gap-12">
        <FocusSection key="attention" lane="attention" label="Needs Attention" icon={<CircleAlert className="size-4" />} items={items} renderItem={renderItem} focusedRequestId={focusedId} focusEjected={hiddenContent.lanes.has("attention")} focusEjectedRepos={hiddenContent.repoGroups} />
        <FocusSection key="active" lane="active" label="In Progress" icon={<Activity className="size-4" />} items={items} renderItem={renderItem} focusedRequestId={focusedId} focusEjected={hiddenContent.lanes.has("active")} focusEjectedRepos={hiddenContent.repoGroups} />
        <FocusSection key="next" lane="next" label="Up Next" icon={<ArrowRight className="size-4" />} items={items} renderItem={renderItem} focusedRequestId={focusedId} focusEjected={hiddenContent.lanes.has("next")} focusEjectedRepos={hiddenContent.repoGroups} />
        {items.some((item) => item.lane === "recent") ? (
          <FocusSection key="recent" lane="recent" label="Recently Finished" icon={<CheckCircle2 className="size-4" />} items={items} renderItem={renderItem} focusedRequestId={focusedId} focusEjected={hiddenContent.lanes.has("recent")} focusEjectedRepos={hiddenContent.repoGroups} />
        ) : null}
        {waiting.length > 0 ? (
          <FocusSection key="waiting" lane="waiting" label="Waiting" icon={<Clock3 className="size-4" />} items={items} renderItem={renderItem} focusedRequestId={focusedId} focusEjected={hiddenContent.lanes.has("waiting")} focusEjectedRepos={hiddenContent.repoGroups} />
        ) : null}
      </div>
    </section>
  );
}

function visibleGraphViewport(row: HTMLElement) {
  return [...row.parentElement?.querySelectorAll<HTMLElement>(".execution-graph__viewport") ?? []]
    .find((viewport) => viewport.getClientRects().length > 0);
}

function elementWithData(root: HTMLElement, key: "groupId" | "workPackageId", value: string) {
  return [...root.querySelectorAll<HTMLElement>(`[data-${key === "groupId" ? "group-id" : "work-package-id"}]`)]
    .find((element) => element.dataset[key] === value);
}

function FocusSection({
  lane,
  label,
  icon,
  items,
  renderItem,
  focusedRequestId,
  focusEjected,
  focusEjectedRepos,
}: {
  lane: FocusBoardLane;
  label: string;
  icon: ReactNode;
  items: FocusBoardItem[];
  renderItem: (item: FocusBoardItem) => ReactNode;
  focusedRequestId?: string;
  focusEjected: boolean;
  focusEjectedRepos: Set<string>;
}) {
  const laneItems = items.filter((item) => item.lane === lane).toSorted(compareFocusItems);
  const repoGroups = groupFocusItemsByRepo(laneItems);
  const focusSelected = laneItems.some((item) => item.id === focusedRequestId);
  const [manuallyOpen, setManuallyOpen] = useState(() => readStoredFocusBoardSectionOpen(lane, lane === "attention" || lane === "active"));
  const sectionOpen = focusSelected || manuallyOpen;

  return (
    <section
      className="focus-board__section grid"
      aria-labelledby={`focus-board-${lane}`}
      aria-hidden={focusEjected || undefined}
      inert={focusEjected}
      data-focus-lane={lane}
      data-focus-selected={focusSelected ? "true" : undefined}
      data-section-open={sectionOpen}
    >
      <h3 id={`focus-board-${lane}`} className="w-fit">
        <button
          type="button"
          className="focus-board__section-toggle flex w-fit cursor-pointer items-center gap-2 text-sm font-semibold"
          aria-expanded={sectionOpen}
          aria-controls={`focus-board-${lane}-content`}
          onClick={() => {
            if (!focusSelected) setManuallyOpen((open) => {
              writeStoredFocusBoardSectionOpen(lane, !open);
              return !open;
            });
          }}
        >
          <ChevronRight className="focus-board__section-chevron size-4" aria-hidden="true" />
          <span className={lane === "recent" ? "text-emerald-600 dark:text-emerald-400" : "text-muted-foreground"} aria-hidden="true">{icon}</span>
          <span>{label}</span>
          <span className="text-xs text-muted-foreground">– {laneItems.length}</span>
        </button>
      </h3>
      <div
        id={`focus-board-${lane}-content`}
        className="focus-board__section-reveal"
        aria-hidden={!sectionOpen}
        inert={!sectionOpen}
      >
        <div className="focus-board__section-reveal-inner">
          {laneItems.length > 0
            ? (
              <div className="focus-board__section-body workstream-board-shell">
                <div className="focus-board__repo-groups">
                  {repoGroups.map((group, index) => {
                    const headingId = `focus-board-${lane}-repo-${index}`;
                    const groupEjected = focusSelected && focusEjectedRepos.has(group.key);
                    return (
                      <section
                        key={group.key}
                        className="focus-board__repo-group"
                        aria-labelledby={headingId}
                        aria-hidden={groupEjected || undefined}
                        inert={groupEjected}
                        data-focus-repo-key={group.key}
                      >
                        <h4 id={headingId} className="focus-board__repo-heading">
                          <GitBranch className="size-4" aria-hidden="true" />
                          <span className="focus-board__repo-name">{group.label}</span>
                        </h4>
                        <div className="v3-workstream-board">{group.items.map(renderItem)}</div>
                      </section>
                    );
                  })}
                </div>
              </div>
            )
            : <p className="rounded-md border border-dashed px-3 py-2 text-xs text-muted-foreground">Clear</p>}
        </div>
      </div>
    </section>
  );
}

function compareFocusItems(left: FocusBoardItem, right: FocusBoardItem) {
  if (left.lane === "recent" && right.lane === "recent") return Date.parse(right.finishedAt || "") - Date.parse(left.finishedAt || "");
  const leftTitle = left.detail.work_request.title || left.id;
  const rightTitle = right.detail.work_request.title || right.id;
  return leftTitle.localeCompare(rightTitle);
}
