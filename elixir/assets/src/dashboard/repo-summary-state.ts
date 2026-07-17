import type { RepoSummary } from "./dashboard-data";
import type { WorkstreamCategoryCounts } from "./dashboard-state";
import type { RepoSummaryPlateTone } from "./runtime";

export type RepoSummaryMetricKey = "requests" | "planNodes" | "slices" | "guidance" | "blockers";

export const REPO_SUMMARY_METRIC_KEYS: RepoSummaryMetricKey[] = ["requests", "planNodes", "slices", "guidance", "blockers"];

export const REPO_SUMMARY_PLATE_WIDTH_VAR_BY_KEY: Record<RepoSummaryMetricKey, string> = {
  requests: "--v3-repo-plate-requests-width",
  planNodes: "--v3-repo-plate-plan-nodes-width",
  slices: "--v3-repo-plate-slices-width",
  guidance: "--v3-repo-plate-guidance-width",
  blockers: "--v3-repo-plate-blockers-width",
};

const REPO_SUMMARY_LABEL_WIDTH_REM_BY_KEY: Record<RepoSummaryMetricKey, number> = {
  requests: 3.35,
  planNodes: 4.05,
  slices: 2.15,
  guidance: 6.25,
  blockers: 5.5,
};
const REPO_SUMMARY_PLATE_CHROME_WIDTH_REM = 1.625;
const REPO_SUMMARY_PLATE_BREATHING_ROOM_REM = 0.4;
const REPO_SUMMARY_COUNT_DIGIT_WIDTH_REM = 0.42;
const REPO_SUMMARY_MIN_COUNT_WIDTH_REM = 0.65;

export type RepoSummaryMetric = {
  key: RepoSummaryMetricKey;
  label: string;
  value: number;
  tone: RepoSummaryPlateTone;
  group: "progress" | "attention";
};

export function repoSummaryMetrics(repo: RepoSummary, categoryCounts: WorkstreamCategoryCounts): RepoSummaryMetric[] {
  return [
    { key: "requests", label: "Requests", value: categoryCounts.requests, tone: "requested", group: "progress" },
    { key: "planNodes", label: "Plan Nodes", value: categoryCounts.planNodes, tone: "implementing", group: "progress" },
    { key: "slices", label: "WorkPackages", value: categoryCounts.slices, tone: "active", group: "progress" },
    { key: "guidance", label: "Guidance Needed", value: repo.guidanceCount, tone: "guidance", group: "attention" },
    { key: "blockers", label: "Active Blockers", value: repo.blockerCount, tone: "blocker", group: "attention" },
  ];
}

export function repoSummaryPlateWidthForMetrics(key: RepoSummaryMetricKey, metrics: RepoSummaryMetric[]) {
  const maxDigits = Math.max(1, ...metrics.map((metric) => countDigits(metric.value)));
  const countWidth = Math.max(REPO_SUMMARY_MIN_COUNT_WIDTH_REM, maxDigits * REPO_SUMMARY_COUNT_DIGIT_WIDTH_REM);
  const width =
    REPO_SUMMARY_PLATE_CHROME_WIDTH_REM +
    REPO_SUMMARY_PLATE_BREATHING_ROOM_REM +
    countWidth +
    REPO_SUMMARY_LABEL_WIDTH_REM_BY_KEY[key];

  return `${Number(width.toFixed(2))}rem`;
}

function countDigits(value: number) {
  return Math.max(1, String(Math.max(0, Math.trunc(Math.abs(value)))).length);
}
