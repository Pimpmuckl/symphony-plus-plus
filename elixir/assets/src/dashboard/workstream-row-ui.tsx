import type { WorkRequestDetail } from "@/types/dashboard";
import { Info } from "lucide-react";
import type { ComponentProps } from "react";

import { AnimatedBadge } from "@/components/dashboard/motion";
import { Button } from "@/components/ui/button";
import type { CardDetailSelect } from "./runtime";

export function RequestInfoButton({ detail, onSelectCard }: { detail: WorkRequestDetail; onSelectCard: CardDetailSelect }) {
  return (
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

export function RequestProgressBar({ progress }: { progress: number }) {
  const value = Math.max(0, Math.min(100, Math.round(progress)));

  return (
    <span className="v3-request-progress" role="progressbar" aria-label="WorkRequest progress" aria-valuemin={0} aria-valuemax={100} aria-valuenow={value}>
      <span className="v3-progress-bar" aria-hidden="true"><span style={{ width: `${value}%` }} /></span>
      <span className="v3-progress-value" aria-hidden="true">{value}%</span>
    </span>
  );
}
