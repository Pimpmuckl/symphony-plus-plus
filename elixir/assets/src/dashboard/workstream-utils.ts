import type { WorkRequestDetail } from "@/types/dashboard";

export function mergeRequestDetailsWithExiting(currentDetails: WorkRequestDetail[], exitingDetails: WorkRequestDetail[]) {
  const currentIds = new Set(currentDetails.map((detail) => detail.work_request.id));
  return [...currentDetails, ...exitingDetails.filter((detail) => !currentIds.has(detail.work_request.id))];
}

export function visibleRequestBranch(branch?: string | null, primaryBranch?: string | null) {
  const value = branch?.trim();
  if (!value || ["main", "master", primaryBranch?.trim().toLowerCase()].includes(value.toLowerCase())) return undefined;
  return value;
}

export function architectStartPrompt(workRequestId: string) {
  return `Take a look at WorkRequest ${workRequestId} using $symphony-plus-plus-mcp:symphony-architect. Check it out, bring me any questions if there are any, then let's go.`;
}

export function requestIdentityCopyText(detail: WorkRequestDetail) {
  const request = detail.work_request;
  return `${request.title?.trim() || request.id} - WR ID: ${request.id}`;
}
