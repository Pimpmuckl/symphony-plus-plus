import type { PackageOperationalAttention, WorkPackageCard, WorkRequestDetail } from "@/types/dashboard";
import { DetailDisclosure } from "@/components/dashboard/detail-layout";
import { MarkdownBlock } from "@/components/dashboard/markdown-block";
import { cn } from "@/lib/utils";
import { formatStatus } from "@/lib/status-labels";
import {
  attentionBorderClassName,
  detailActivityRows,
  detailDate,
  latestDecisionLogs,
  lineageDetailRows,
  lineageSummary,
} from "./detail-utils";

export function RecentDecisionsDisclosure({ detail }: { detail: WorkRequestDetail }) {
  const decisions = latestDecisionLogs(detail);

  return (
    <DetailDisclosure title="Recent Decisions" meta={decisions.length > 0 ? `${decisions.length} recorded` : "None recorded"}>
      {decisions.length > 0 ? (
        <DetailActivityList
          items={decisions.slice(0, 3).map((decision) => ({
            title: decision.decision || decision.scope_impact || "Decision",
            body: decision.rationale,
            at: decision.created_at || decision.inserted_at,
          }))}
        />
      ) : (
        <p className="text-sm text-muted-foreground">No decisions recorded for this request yet.</p>
      )}
    </DetailDisclosure>
  );
}

export function DetailActivityList({ items }: { items: Array<{ title?: string | null; body?: string | null; at?: string | null }> }) {
  const rows = detailActivityRows(items);

  return (
    <div className="grid gap-2">
      {rows.map(({ item, key }) => (
        <div key={key} className="detail-list-item">
          <div className="flex min-w-0 items-start justify-between gap-3">
            <span className="min-w-0 text-sm font-medium">{item.title || "Update"}</span>
            {item.at ? <span className="shrink-0 text-xs text-muted-foreground">{detailDate(item.at)}</span> : null}
          </div>
          {item.body ? <MarkdownBlock className="detail-markdown-compact mt-1 text-xs" value={item.body} /> : null}
        </div>
      ))}
    </div>
  );
}

export function DetailAttentionList({ items }: { items: PackageOperationalAttention[] }) {
  const visibleItems = items.slice(0, 3);

  return (
    <div className="grid gap-2">
      {visibleItems.map((item) => (
        <div key={item.key || item.label || item.reason} className={cn("detail-list-item border-l-4", attentionBorderClassName(item))}>
          <div className="flex min-w-0 items-center justify-between gap-3">
            <span className="min-w-0 text-sm font-medium">{item.label || formatStatus(item.key)}</span>
            {item.missing?.length ? <span className="shrink-0 text-xs text-muted-foreground">{item.missing.length} missing</span> : null}
          </div>
          {item.reason ? <p className="mt-1 text-xs text-muted-foreground">{item.reason}</p> : null}
        </div>
      ))}
      {items.length > visibleItems.length ? <p className="text-xs text-muted-foreground">+{items.length - visibleItems.length} more attention item{items.length - visibleItems.length === 1 ? "" : "s"}</p> : null}
    </div>
  );
}

export function LineageDisclosure({ lineage }: { lineage: WorkPackageCard["lineage"] }) {
  const entries = lineageDetailRows(lineage);
  const attentionItems = lineage?.cleanup_attention || [];

  return (
    <DetailDisclosure title="Operational Lineage" meta={lineageSummary(lineage)} defaultOpen={Boolean(lineage?.unavailable || attentionItems.length)}>
      <div className="grid gap-3">
        {lineage?.unavailable ? <p className="text-sm text-muted-foreground">Lineage could not be read{lineage.error ? `: ${lineage.error}` : "."}</p> : null}
        {entries.length > 0 ? (
          <DetailActivityList
            items={entries.map((entry) => ({
              title: entry.title,
              body: entry.body,
              at: entry.at,
            }))}
          />
        ) : lineage?.unavailable ? null : (
          <p className="text-sm text-muted-foreground">No lineage relationships recorded.</p>
        )}
        {attentionItems.length > 0 ? <DetailAttentionList items={attentionItems} /> : null}
      </div>
    </DetailDisclosure>
  );
}
