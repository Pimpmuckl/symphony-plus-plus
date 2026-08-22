export function formatStatus(status?: string | null) {
  return status ? status.replaceAll("_", " ").replace(/\b\w/g, (letter) => letter.toUpperCase()) : "Unknown";
}

const STATUS_LABELS: Record<string, string> = {
  active: "Active",
  merge_ready: "Ready For Merge",
  ready_to_finish: "Ready To Finish",
  in_progress: "Active",
  needs_attention: "Needs Attention",
  started_paused: "Started / Paused",
  completed: "Completed",
  merging: "Merging",
  ready_for_merge: "Merge Ready",
  ci_waiting: "CI Waiting",
};

export function statusLabel(status?: string | null) {
  return status ? STATUS_LABELS[status] ?? formatStatus(status) : formatStatus(status);
}
