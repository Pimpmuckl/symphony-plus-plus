import type { ActiveBlockingEdge, GuidanceItem, WorkPackageCard, WorkRequestDetail } from "@/types/dashboard";
import { Info } from "lucide-react";
import type { ComponentProps } from "react";

import { AnimatedBadge } from "@/components/dashboard/motion";
import { DetailCopyButton } from "@/components/dashboard/detail-copy-button";
import { Button } from "@/components/ui/button";
import type { CardDetailSelect } from "./runtime";
import { requestIdentityCopyText } from "./workstream-utils";
import type { BoardRowState } from "./workstream-row-state";
import { requestAttentionTarget, type AttentionSelect } from "./workstream-attention";

export function RequestInfoButton({ detail, onSelectCard }: { detail: WorkRequestDetail; onSelectCard: CardDetailSelect }) {
  return (
    <Button
      type="button"
      variant="secondary"
      size="icon"
      className="v3-request-action-button v3-request-info-button"
      aria-label="Open request details"
      title="Request details"
      onClick={() => onSelectCard({ kind: "request", detail })}
    >
      <Info className="size-4" />
    </Button>
  );
}

export function RequestIdentityCopyButton({ detail }: { detail: WorkRequestDetail }) {
  return (
    <DetailCopyButton
      variant="secondary"
      className="v3-request-action-button v3-request-copy-button"
      label="Copy WorkRequest identity"
      text={requestIdentityCopyText(detail)}
    />
  );
}

export function RequestAttentionBadge({
  activeBlockingEdges,
  detail,
  guidanceItems,
  label,
  onSelectAttention,
  packageById,
  state,
}: {
  activeBlockingEdges: ActiveBlockingEdge[];
  detail: WorkRequestDetail;
  guidanceItems: GuidanceItem[];
  label: string;
  onSelectAttention: AttentionSelect;
  packageById: Map<string, WorkPackageCard>;
  state: BoardRowState;
}) {
  const target = requestAttentionTarget(detail, packageById, activeBlockingEdges, state.kind, guidanceItems);
  const openAttention = target ? () => onSelectAttention(target) : undefined;

  return (
    <RowBadgeSlot
      active={state.kind === "active"}
      actionLabel={openAttention ? `Open attention details for ${detail.work_request.title || detail.work_request.id}` : undefined}
      label={label}
      onClick={openAttention}
      variant={state.badgeVariant}
    />
  );
}

export function RowBadgeSlot({
  active = false,
  actionLabel,
  label,
  onClick,
  variant,
}: {
  active?: boolean;
  actionLabel?: string;
  label: string;
  onClick?: () => void;
  variant?: ComponentProps<typeof AnimatedBadge>["variant"];
}) {
  return (
    <span className="v3-row-badge-slot" data-interactive={onClick ? "true" : undefined}>
      {onClick ? (
        <button type="button" className="v3-row-badge-button" aria-label={actionLabel} onClick={onClick}>
          <AnimatedBadge active={active} label={label} variant={variant} className="v3-row-status-badge" />
        </button>
      ) : (
        <AnimatedBadge active={active} label={label} variant={variant} className="v3-row-status-badge" />
      )}
    </span>
  );
}

export function RequestProgressBar({ progress }: { progress: number }) {
  const value = Math.max(0, Math.min(100, Math.round(progress)));

  return (
    <span className="v3-request-progress" role="progressbar" aria-label="WorkRequest progress" aria-valuemin={0} aria-valuemax={100} aria-valuenow={value}>
      <span className="v3-progress-bar" aria-hidden="true"><span style={{ width: `${value}%` }} /></span>
      <span className="v3-progress-value" aria-hidden="true">{value}%</span>
    </span>
  );
}
