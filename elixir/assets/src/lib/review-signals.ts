import { formatStatus } from "@/lib/status-labels";
import type { WorkPackageCard } from "@/types/dashboard";

type PackageMetadata = NonNullable<WorkPackageCard["metadata"]>;
type PackagePlan = WorkPackageCard["plan"];
type ReviewPayload = PackageMetadata["review_suite_result"];

export function packageReviewLabel(pkg: WorkPackageCard): string | null {
  const progress = reviewPayloadLabel(pkg.metadata?.review_progress);
  const result = reviewPayloadLabel(pkg.metadata?.review_suite_result);

  return pkg.status === "reviewing" ? progress || result : result || progress;
}

export function reviewLaneLabel(lane: string) {
  switch (normalizeReviewLane(lane)) {
    case "brief":
      return "Brief";
    case "fast":
      return "Fast";
    case "normal":
      return "Normal";
    case "deep":
      return "Deep";
    case "review_deslop":
      return "Review-Deslop";
    case "review_github":
      return "Review-GitHub";
    default:
      return formatStatus(lane);
  }
}

export function planProgressLabel(plan?: PackagePlan | null) {
  const total = plan?.total_count || 0;
  if (total <= 0) return null;

  const done = plan?.completed_count || 0;
  const open = plan?.open_count || 0;

  return open > 0 ? `${open} open / ${total} total` : `${done}/${total} done`;
}

function reviewPayloadLabel(payload?: ReviewPayload | null): string | null {
  if (!payload) return null;

  const lane = payload.profile || payload.mode || payload.lane || payload.review_lane || payload.suite;
  const stage = reviewStageLabel(payload);
  if (!lane && !stage) return null;

  const label = lane ? reviewLaneLabel(lane) : "Review";
  return stage ? `${label} ${stage}` : `${label} ${reviewStatusSuffix(payload.verdict || payload.status)}`;
}

function reviewStatusSuffix(value?: string) {
  const normalized = value?.trim().toLowerCase();
  if (["green", "clean", "passed", "pass"].includes(normalized || "")) return "Green";
  if (["red", "failed", "fail", "findings"].includes(normalized || "")) return "Failed";
  return "Pending";
}

function normalizeReviewLane(lane: string) {
  const normalized = normalizedReviewMode(lane).trim().toLowerCase().replace(/-/g, "_");

  switch (normalized) {
    case "review_brief":
      return "brief";
    case "review_normal":
      return "normal";
    case "review_deep":
      return "deep";
    case "emergency":
    case "review_emergency":
      return "fast";
    case "review_fast":
      return "fast";
    default:
      return normalized;
  }
}

function normalizedReviewMode(lane: string) {
  const modeMatch = lane.match(/(?:^|\s)--mode(?:=|\s+)([a-z0-9_-]+)/i);
  if (modeMatch?.[1]) return modeMatch[1];

  return lane;
}

function reviewStageLabel(payload: ReviewPayload) {
  const current = numericPayloadValue(payload?.step_current);
  const total = numericPayloadValue(payload?.step_total);

  if (current && total) return `${current}/${total}`;
  if (payload?.step_name) return formatStatus(payload.step_name);
  return null;
}

function numericPayloadValue(value: unknown) {
  if (typeof value === "number" && Number.isFinite(value) && value > 0) return value;

  if (typeof value === "string") {
    const parsed = Number.parseInt(value, 10);
    return Number.isFinite(parsed) && parsed > 0 ? parsed : null;
  }

  return null;
}
