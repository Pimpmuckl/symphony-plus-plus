import { AlertTriangle, MessageCircleQuestion } from "lucide-react";

import type { UpdateMotion } from "@/components/dashboard/motion";
import { updateMotionAttributes } from "@/components/dashboard/motion-utils";
import { StateCard } from "@/components/dashboard/state-card";
import { cn } from "@/lib/utils";
import type { ActiveBlockingEdgeEndpoint } from "@/types/dashboard";
import { AttentionLocationBar } from "./attention-location";
import { detailDate } from "./detail-utils";
import { stripMarkdown } from "./dashboard-text";
import { elapsedLabel } from "./workstream-row-age";
import {
  attentionItemDetail,
  attentionItemSince,
  attentionItemTitle,
  type AttentionItem,
  type AttentionJumpDestination,
  type AttentionLocation,
} from "./workstream-attention";

export function AttentionPreviewCard({
  item,
  index,
  location,
  now,
  onJump,
  onSelect,
  motion,
}: {
  item: AttentionItem;
  index: number;
  location: AttentionLocation;
  now?: string;
  onJump?: (destination: AttentionJumpDestination) => void;
  onSelect?: () => void;
  motion?: UpdateMotion;
}) {
  const title = stripMarkdown(attentionItemTitle(item));
  const detail = previewDetail(attentionItemDetail(item));
  const since = attentionItemSince(item);
  const blocker = item.kind === "blocker" ? item.selection.blocker : null;
  const blockedBy = blocker ? blockedByText(blocker.from, blocker.to) : "";

  return (
    <StateCard
      tone={item.tone === "blocked" ? "blocked" : "guidance"}
      className={cn("attention-preview-card stagger-item grid gap-3 p-4 text-left", onSelect && "card-detail-trigger")}
      style={{ animationDelay: `${index * 45}ms` }}
      data-flip-id={item.key}
      data-attention-kind={item.kind}
      {...updateMotionAttributes(motion)}
    >
      {onSelect ? (
        <button
          type="button"
          className="attention-preview-card__open"
          aria-label={`Open ${item.label} for ${title}`}
          onClick={onSelect}
        />
      ) : null}
      <AttentionLocationBar location={location} onJump={onJump} />
      <div className="flex min-w-0 items-start justify-between gap-3">
        <p className="line-clamp-2 min-w-0 text-sm font-semibold">{title}</p>
        {item.tone === "blocked" ? (
          <AlertTriangle className="mt-0.5 size-4 shrink-0 text-rose-600 dark:text-rose-300" aria-hidden="true" />
        ) : (
          <MessageCircleQuestion className="mt-0.5 size-4 shrink-0 text-violet-600 dark:text-violet-300" aria-hidden="true" />
        )}
      </div>
      {blockedBy ? <p className="truncate text-xs font-medium text-muted-foreground">{blockedBy}</p> : null}
      {item.tone === "blocked" && since ? <AttentionAge since={since} now={now} /> : null}
      {detail ? <p className="line-clamp-2 text-sm text-muted-foreground">{detail}</p> : null}
    </StateCard>
  );
}

function AttentionAge({ since, now }: { since: string; now?: string }) {
  const elapsed = elapsedLabel(since, now);
  if (!elapsed) return null;
  return (
    <p className="text-xs font-medium text-rose-700 dark:text-rose-200">
      <time dateTime={since} title={detailDate(since)}>Blocked for {elapsed}</time>
    </p>
  );
}

function previewDetail(value: string) {
  const text = stripMarkdown(value).trim();
  if (!text || /^raw lifecycle status is /i.test(text) || /^this work package has active blockers?/i.test(text)) return "";
  return text;
}

function blockedByText(from?: ActiveBlockingEdgeEndpoint, to?: ActiveBlockingEdgeEndpoint) {
  if (!from || (to && from.kind === to.kind && from.id === to.id)) return "";
  return `Blocked by ${from.id}`;
}
