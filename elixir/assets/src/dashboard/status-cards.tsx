import { Badge } from "@/components/ui/badge";
import { Tooltip, TooltipContent, TooltipTrigger } from "@/components/ui/tooltip";
import { DashboardConnectionIssue } from "./runtime";

export function LiveLedgerBadge({
  error,
  connectionIssue,
  databasePath,
}: {
  error: string | null;
  connectionIssue: DashboardConnectionIssue | null;
  databasePath?: string | null;
}) {
  const reconnecting = Boolean(connectionIssue && !error);
  const label = error ? "API unavailable" : reconnecting ? "Reconnecting..." : "Ledger connected";
  const variant = error ? "danger" : reconnecting ? "warning" : "success";
  const heading = error || reconnecting ? "Status" : "Database";
  const tooltip = error
    ? error
    : reconnecting
      ? `Last update failed. Retrying for up to 5 minutes before surfacing an error. ${connectionIssue?.message || ""}`.trim()
      : databasePath || "Database path unavailable.";

  return (
    <Tooltip>
      <TooltipTrigger asChild>
        <Badge variant={variant} className="cursor-help">
          {label}
        </Badge>
      </TooltipTrigger>
      <TooltipContent className="max-w-[min(34rem,calc(100vw-2rem))]">
        <div className="grid gap-1">
          <span className="text-xs font-medium">{heading}</span>
          <span className="break-all font-mono text-[11px] leading-relaxed text-muted-foreground">{tooltip}</span>
        </div>
      </TooltipContent>
    </Tooltip>
  );
}
