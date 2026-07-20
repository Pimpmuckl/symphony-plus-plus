import { ChevronRight } from "lucide-react";
import type { ReactNode } from "react";

import { Collapsible, CollapsibleContent, CollapsibleTrigger } from "@/components/ui/collapsible";
import { DialogDescription, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { DetailCopyButton } from "./detail-copy-button";

export function DetailHeader({
  title,
  eyebrow,
  identifier,
  identifierLabel = "ID",
  badge,
  action,
}: {
  title: string;
  eyebrow: string;
  identifier?: string;
  identifierLabel?: string;
  badge?: ReactNode;
  action?: ReactNode;
}) {
  return (
    <DialogHeader className="detail-header" data-guidance-section style={{ animationDelay: "35ms" }}>
      <div className="flex min-w-0 flex-col gap-2 sm:flex-row sm:items-start sm:justify-between">
        <div className="min-w-0">
          <DialogTitle className="pr-6">{title}</DialogTitle>
          <div className="detail-header-context">
            {identifier ? (
              <div className="detail-header-identifier">
                <span>{identifierLabel}</span>
                <code title={identifier}>{identifier}</code>
                <DetailCopyButton label={`Copy ${identifierLabel}`} text={identifier} />
              </div>
            ) : null}
            <DialogDescription className="detail-header-eyebrow">{eyebrow}</DialogDescription>
          </div>
        </div>
        {badge || action ? (
          <div className="flex shrink-0 items-center gap-2 sm:pr-6">
            {badge}
            {action}
          </div>
        ) : null}
      </div>
    </DialogHeader>
  );
}

export function DetailSummaryBar({ items }: { items: Array<{ label: string; value: string }> }) {
  return (
    <dl className="detail-summary-bar" data-guidance-section style={{ animationDelay: "70ms" }}>
      {items.map((item) => (
        <div key={item.label}>
          <dt>{item.label}</dt>
          <dd>{item.value}</dd>
        </div>
      ))}
    </dl>
  );
}

export function DetailLoadError({ error }: { error?: string | null }) {
  if (!error) return null;

  return (
    <p role="alert" className="rounded-md border border-destructive/35 bg-destructive/5 px-3 py-2 text-sm text-destructive">
      Some details could not be loaded. {error}
    </p>
  );
}

export function DetailStatGrid({ stats }: { stats: Array<{ label: string; value: string }> }) {
  return (
    <div className="detail-stat-grid" data-guidance-section style={{ animationDelay: "70ms" }}>
      {stats.map((stat) => (
        <div key={stat.label} className="detail-stat">
          <span>{stat.label}</span>
          <strong>{stat.value}</strong>
        </div>
      ))}
    </div>
  );
}

export function DetailSection({ title, children }: { title: string; children: ReactNode }) {
  return (
    <section className="detail-section" data-guidance-section style={{ animationDelay: "95ms" }}>
      <h3>{title}</h3>
      <div className="detail-section-body">{children}</div>
    </section>
  );
}

export function DetailDisclosure({
  title,
  meta,
  children,
  defaultOpen = false,
  open,
  onOpenChange,
}: {
  title: string;
  meta?: string;
  children: ReactNode;
  defaultOpen?: boolean;
  open?: boolean;
  onOpenChange?: (open: boolean) => void;
}) {
  return (
    <Collapsible
      defaultOpen={open === undefined ? defaultOpen : undefined}
      open={open}
      onOpenChange={onOpenChange}
      className="detail-disclosure"
      data-guidance-section
      style={{ animationDelay: "120ms" }}
    >
      <CollapsibleTrigger className="detail-disclosure-trigger">
        <span className="flex min-w-0 items-center gap-2">
          <ChevronRight className="detail-disclosure-chevron size-4 shrink-0 transition-transform duration-150" />
          <span className="truncate">{title}</span>
        </span>
        {meta ? <span className="truncate text-xs text-muted-foreground">{meta}</span> : null}
      </CollapsibleTrigger>
      <CollapsibleContent className="collapsible-content">
        <div className="detail-disclosure-body">{children}</div>
      </CollapsibleContent>
    </Collapsible>
  );
}

export function DetailFacts({ facts }: { facts: Array<[string, string | null | undefined]> }) {
  return (
    <dl className="detail-facts">
      {facts.map(([label, value]) => (
        <div key={label}>
          <dt>{label}</dt>
          <dd>{value || "Not recorded"}</dd>
        </div>
      ))}
    </dl>
  );
}

export function DetailList({ title, items, empty }: { title: string; items: string[]; empty: string }) {
  const visibleItems = items.filter(Boolean).slice(0, 4);

  return (
    <div className="grid gap-2">
      <p className="text-xs font-semibold text-muted-foreground">{title}</p>
      {visibleItems.length > 0 ? (
        <ul className="grid gap-1.5 text-sm text-muted-foreground">
          {visibleItems.map((item, index) => (
            <li key={`${index}:${item}`} className="detail-bullet">
              {item}
            </li>
          ))}
        </ul>
      ) : (
        <p className="text-sm text-muted-foreground">{empty}</p>
      )}
      {items.length > visibleItems.length ? <p className="text-xs text-muted-foreground">+{items.length - visibleItems.length} more</p> : null}
    </div>
  );
}

export function JsonDetail({ label, value }: { label: string; value?: Record<string, unknown> }) {
  if (!value || Object.keys(value).length === 0) return null;

  return (
    <div className="grid gap-2">
      <p className="text-xs font-semibold text-muted-foreground">{label}</p>
      <pre className="detail-json">{JSON.stringify(value, null, 2)}</pre>
    </div>
  );
}
