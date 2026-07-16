import type { CopyArchitectHandoff, PlannedSlice, WorkPackageCard, WorkRequestDetail } from "@/types/dashboard";
import type { ProductTreeNode } from "@/types/product-tree";
import { AlertTriangle, CheckCircle2, ChevronRight, CircleAlert, CircleDashed, CircleHelp, Circle, ClipboardCopy, Info, Layers3, MessageSquareText, Package, Split } from "lucide-react";
import type { ComponentProps, CSSProperties, ReactNode } from "react";
import { useCallback, useEffect, useRef, useState } from "react";

import { AnimatedBadge } from "@/components/dashboard/motion";
import { Button } from "@/components/ui/button";
import { architectHandoffEligibleRequest } from "@/lib/operational-state";
import { cn } from "@/lib/utils";
import type { CardDetailSelect } from "./runtime";
import { rowProgressAttentionState, rowProgressIconState, type RowProgressAttentionState, type RowProgressIconState } from "./workstream-row-state";

type EntityCountChip = {
  key: string;
  icon: ReactNode;
  count: number;
  label: string;
  onClick?: () => void;
  tone?: "guidance" | "blocker";
  showZero?: boolean;
};

const PROGRESS_STATE_ICON: Record<RowProgressIconState, ReactNode> = {
  active: <span className="v3-progress-state-ring" />,
  blocked: <CircleAlert className="size-4" />,
  done: <CheckCircle2 className="size-4" />,
  guidance: <CircleHelp className="size-4" />,
  muted: <CircleDashed className="size-4" />,
  ready: <Circle className="size-4" />,
};

const PROGRESS_ATTENTION_OVERLAY: Record<NonNullable<RowProgressAttentionState>, { className: string; label: string; text: string }> = {
  blocked: { className: "v3-progress-state-overlay-blocked", label: "active blocker", text: "!" },
  guidance: { className: "v3-progress-state-overlay-guidance", label: "guidance needed", text: "?" },
};

export function EntityCountChips({
  items,
  reserveEmpty = false,
  className,
}: {
  items: EntityCountChip[];
  reserveEmpty?: boolean;
  className?: string;
}) {
  return (
    <span className={cn("v3-row-signals", className)}>
      {items.map((item) => (
        <EntityCountChipView key={item.key} item={item} reserveEmpty={reserveEmpty} />
      ))}
    </span>
  );
}

function EntityCountChipView({ item, reserveEmpty }: { item: EntityCountChip; reserveEmpty: boolean }) {
  const visible = item.count > 0 || item.showZero;
  if (!visible && !reserveEmpty) return null;

  const className = entityCountChipClassName(item, Boolean(visible));
  const ariaLabel = visible ? `${item.count} ${item.label}${item.onClick ? "; open details" : ""}` : undefined;

  if (item.onClick && visible) {
    return <EntityCountChipButton item={item} className={className} ariaLabel={ariaLabel} />;
  }

  return (
    <span
      className={className}
      aria-hidden={visible ? undefined : "true"}
      aria-label={ariaLabel}
      title={visible ? item.label : undefined}
    >
      {visible ? item.icon : null}
      {visible ? item.count : null}
    </span>
  );
}

function EntityCountChipButton({
  item,
  className,
  ariaLabel,
}: {
  item: EntityCountChip;
  className: string;
  ariaLabel?: string;
}) {
  return (
    <button
      type="button"
      className={className}
      aria-label={ariaLabel}
      title={item.label}
      onClick={(event) => {
        event.stopPropagation();
        item.onClick?.();
      }}
    >
      {item.icon}
      {item.count}
    </button>
  );
}

function entityCountChipClassName(item: EntityCountChip, visible: boolean) {
  return cn(
    "v3-signal-chip",
    item.tone === "guidance" && "v3-guidance-chip",
    item.tone === "blocker" && "v3-blocker-chip",
    item.onClick && visible && "v3-signal-chip-button",
    !visible && "v3-signal-chip-empty",
  );
}

export function EntityKindSlot({
  icon,
  value,
  title,
  muted = false,
}: {
  icon: ReactNode;
  value?: ReactNode;
  title: string;
  muted?: boolean;
}) {
  return (
    <span className={cn("v3-entity-kind-slot", muted && "v3-entity-kind-slot-muted")} title={title} aria-label={title}>
      {icon}
      {value !== undefined ? <span className="v3-entity-kind-value">{value}</span> : null}
    </span>
  );
}

export function RequestHeaderActions({
  detail,
  progress,
  progressAttentionState,
  progressIconState,
  progressLabel,
  onSelectCard,
  onCopyArchitectHandoff,
  canMutateOperatorActions,
}: {
  detail: WorkRequestDetail;
  progress: number;
  progressAttentionState: RowProgressAttentionState;
  progressIconState: RowProgressIconState;
  progressLabel: string;
  onSelectCard: CardDetailSelect;
  onCopyArchitectHandoff: CopyArchitectHandoff;
  canMutateOperatorActions: boolean;
}) {
  const [copying, setCopying] = useState(false);
  const [copyToastVisible, setCopyToastVisible] = useState(false);
  const copyToastTimerRef = useRef<number | null>(null);
  const request = detail.work_request;
  const canCopyHandoff = canMutateOperatorActions && architectHandoffEligibleRequest(request);
  const showCopyToast = useCallback(() => {
    if (copyToastTimerRef.current !== null) {
      window.clearTimeout(copyToastTimerRef.current);
    }
    setCopyToastVisible(true);
    copyToastTimerRef.current = window.setTimeout(() => {
      setCopyToastVisible(false);
      copyToastTimerRef.current = null;
    }, 3000);
  }, []);

  useEffect(
    () => () => {
      if (copyToastTimerRef.current !== null) {
        window.clearTimeout(copyToastTimerRef.current);
      }
    },
    [],
  );

  const copyHandoff = useCallback(async () => {
    setCopying(true);
    try {
      const result = await onCopyArchitectHandoff(request.id);
      if (result.copied) {
        showCopyToast();
      }
    } catch {
      setCopyToastVisible(false);
    } finally {
      setCopying(false);
    }
  }, [onCopyArchitectHandoff, request.id, showCopyToast]);

  return (
    <div className="v3-request-header-actions v3-row-actions">
      <ProgressStateIcon state={progressIconState} attentionState={progressAttentionState} progress={progress} label={progressLabel} />
      <Button
        type="button"
        variant="secondary"
        size="icon"
        className="v3-request-action-button"
        aria-label="Open request details"
        title="Request details"
        onClick={() => onSelectCard({ kind: "request", detail })}
      >
        <Info className="size-4" />
      </Button>
      {canCopyHandoff ? (
        <Button
          type="button"
          variant="outline"
          size="icon"
          className="v3-request-action-button"
          aria-label={copying ? "Copying architect handoff" : "Copy architect handoff"}
          title={copying ? "Copying architect handoff" : "Architect handoff"}
          onClick={copyHandoff}
          disabled={copying}
        >
          <ClipboardCopy className="size-4" />
        </Button>
      ) : null}
      {copyToastVisible ? (
        <output className="v3-handoff-copy-toast" aria-live="polite">
          Handoff copied to Clipboard
        </output>
      ) : null}
    </div>
  );
}

export function ProgressStateIcon({
  attentionState,
  label,
  progress = 0,
  state,
}: {
  attentionState?: RowProgressAttentionState;
  label: string;
  progress?: number;
  state: RowProgressIconState;
}) {
  const clampedProgress = Math.max(0, Math.min(100, Math.round(progress)));
  const showAttentionOverlay = Boolean(attentionState && attentionState !== state);
  const attentionOverlay = showAttentionOverlay && attentionState ? PROGRESS_ATTENTION_OVERLAY[attentionState] : null;
  const accessibleLabel = [
    state === "active" ? `${label}, ${clampedProgress}% progress` : label,
    attentionOverlay?.label,
  ].filter(Boolean).join(", ");
  const style = { "--v3-progress-state-value": `${clampedProgress}%` } as CSSProperties;

  return (
    <span className={cn("v3-progress-state-icon", `v3-progress-state-${state}`)} title={accessibleLabel} aria-label={accessibleLabel} style={style}>
      {PROGRESS_STATE_ICON[state]}
      {attentionOverlay ? (
        <span className={cn("v3-progress-state-overlay", attentionOverlay.className)} aria-hidden="true">
          {attentionOverlay.text}
        </span>
      ) : null}
    </span>
  );
}

export function SliceKindSlot({
  detail,
  slice,
  pkg,
  onSelectCard,
}: {
  detail: WorkRequestDetail;
  slice: PlannedSlice;
  pkg?: WorkPackageCard;
  onSelectCard: CardDetailSelect;
}) {
  if (pkg) {
    return (
      <Button
        type="button"
        size="icon"
        variant="ghost"
        className="v3-entity-kind-button v3-slice-package-button"
        title={pkg.title || pkg.id}
        aria-label={`Open execution details for ${pkg.title || pkg.id}`}
        onClick={() => onSelectCard({ kind: "package", pkg, detail, slice })}
      >
        <Package className="size-4" />
      </Button>
    );
  }

  return (
    <EntityKindSlot
      icon={<Split className="size-3.5" />}
      title="Subwork placeholder"
      muted
    />
  );
}

export function ProductNodeHeader({
  node,
  nodeSliceCount,
  visibleNodeKind,
  progress,
  statusBadgeVariant,
  statusActive,
  tone,
  statusLabel,
  guidanceCount,
  blockerCount,
  collapsible,
  expanded,
  contentId,
  onOpenGuidance,
  onOpenBlockers,
  onToggle,
}: {
  node: ProductTreeNode;
  nodeSliceCount: number;
  visibleNodeKind?: string | null;
  progress: number;
  statusBadgeVariant?: ComponentProps<typeof AnimatedBadge>["variant"];
  statusActive: boolean;
  tone: string;
  statusLabel: string;
  guidanceCount: number;
  blockerCount: number;
  collapsible: boolean;
  expanded: boolean;
  contentId?: string;
  onOpenGuidance?: () => void;
  onOpenBlockers?: () => void;
  onToggle: () => void;
}) {
  const progressIconState = rowProgressIconState({ blockerCount, guidanceCount, progress, tone });
  const progressAttentionState = rowProgressAttentionState({ blockerCount, guidanceCount, tone });
  const nodeTitle = node.title || node.id;

  return (
    <div className="v3-product-node-header v3-entity-row" data-tone={tone}>
      {collapsible ? (
        <button
          type="button"
          className="v3-product-node-chevron-button"
          aria-controls={contentId}
          aria-expanded={expanded}
          aria-label={`${expanded ? "Collapse" : "Expand"} ${nodeTitle}`}
          data-expanded={expanded ? "true" : "false"}
          onClick={onToggle}
        >
          <ChevronRight className="size-4" />
        </button>
      ) : (
        <span className="v3-product-node-chevron-placeholder" aria-hidden="true" />
      )}
      <ProgressStateIcon state={progressIconState} attentionState={progressAttentionState} progress={progress} label={statusLabel} />
      <span className="v3-product-node-title-group">
        <span className="v3-product-node-title" title={nodeTitle}>
          {nodeTitle}
        </span>
        <span className="v3-product-node-meta">
          {visibleNodeKind ? <span>{visibleNodeKind}</span> : null}
          <span>{nodeSliceCount} slices</span>
        </span>
      </span>
      <EntityCountChips
        reserveEmpty
        items={[
          { key: "guidance", icon: <MessageSquareText className="size-3.5" />, count: guidanceCount, label: "guidance needed", onClick: guidanceCount > 0 ? onOpenGuidance : undefined, tone: "guidance" },
          { key: "blockers", icon: <AlertTriangle className="size-3.5" />, count: blockerCount, label: "active blockers", onClick: blockerCount > 0 ? onOpenBlockers : undefined, tone: "blocker" },
        ]}
      />
      <span className="v3-row-status">
        <ProgressPill progress={progress} />
        <RowBadgeSlot active={statusActive} label={statusLabel} variant={statusBadgeVariant} />
      </span>
      <EntityKindSlot icon={<Layers3 className="size-3.5" />} title="Product plan node" />
    </div>
  );
}

export function RowBadgeSlot({
  active = false,
  label,
  variant,
}: {
  active?: boolean;
  label: string;
  variant?: ComponentProps<typeof AnimatedBadge>["variant"];
}) {
  return (
    <span className="v3-row-badge-slot">
      <AnimatedBadge active={active} label={label} variant={variant} className="v3-row-status-badge" />
    </span>
  );
}

export function ProgressPill({ progress }: { progress: number }) {
  return (
    <span className="v3-progress-pill">
      <span className="v3-progress-bar"><span style={{ width: `${progress}%` }} /></span>
      <span>{progress}%</span>
    </span>
  );
}
