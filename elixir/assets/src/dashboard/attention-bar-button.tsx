import { NumberWheel, useCountMotion } from "@/components/dashboard/motion";
import { Tooltip, TooltipContent, TooltipTrigger } from "@/components/ui/tooltip";
import type { TopPanelKey } from "./runtime";
import type { AttentionButtonConfig } from "./status-rail-types";

export function AttentionBarButton({
  panel,
  title,
  value,
  icon,
  tone,
  open,
  onToggle,
}: AttentionButtonConfig & {
  open: boolean;
  onToggle: (panel: TopPanelKey | null) => void;
}) {
  const countMotion = useCountMotion(value);

  return (
    <Tooltip>
      <TooltipTrigger asChild>
        <button
          type="button"
          className="dashboard-attention-button"
          data-count-motion={countMotion.direction}
          data-state={open ? "open" : "closed"}
          data-tone={tone}
          onClick={() => onToggle(open ? null : panel)}
          aria-label={`${title}: ${value}`}
          aria-expanded={open}
        >
          {icon}
          <span className="dashboard-attention-count" aria-hidden="true">
            <NumberWheel value={value} motion={countMotion} compact />
          </span>
        </button>
      </TooltipTrigger>
      <TooltipContent>{title}</TooltipContent>
    </Tooltip>
  );
}
