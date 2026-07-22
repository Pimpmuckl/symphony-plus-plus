import type { ExecutionGraphWorkPackageSignals } from "./model";

export function PullRequestBadge({
  signal,
  label = prBadgeLabel(signal),
  layout = "default",
}: {
  signal: ExecutionGraphWorkPackageSignals["pr_signal"];
  label?: string;
  layout?: "default" | "frontier";
}) {
  if (!label) return null;
  if (layout === "frontier") return <FrontierPullRequestBadge signal={signal} label={label} />;
  if (!signal?.url) return <span className="execution-graph__pr-badge">{label}</span>;
  return (
    <a className="execution-graph__pr-badge" href={signal.url} target="_blank" rel="noreferrer" title={`Open ${label}`}>
      {label}
    </a>
  );
}

function FrontierPullRequestBadge({ signal, label }: { signal: ExecutionGraphWorkPackageSignals["pr_signal"]; label: string }) {
  const content = <>
    <span className="v3-request-frontier-pr-label" aria-hidden="true">PR</span>
    {signal?.number == null ? null : <span className="v3-request-frontier-pr-number" aria-hidden="true">#{signal.number}</span>}
  </>;
  if (!signal?.url) return <span className="execution-graph__pr-badge v3-request-frontier-pr" aria-label={label} data-frontier-measure="pr">{content}</span>;
  return (
    <a className="execution-graph__pr-badge v3-request-frontier-pr" href={signal.url} target="_blank" rel="noreferrer" title={`Open ${label}`} aria-label={label} data-frontier-measure="pr">
      {content}
    </a>
  );
}

export function prBadgeLabel(signal?: ExecutionGraphWorkPackageSignals["pr_signal"]) {
  if (!signal || ["none", "unavailable"].includes(signal.status)) return undefined;
  return signal.number == null ? "PR" : `PR #${signal.number}`;
}
