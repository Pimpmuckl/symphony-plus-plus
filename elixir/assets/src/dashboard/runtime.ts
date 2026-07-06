import type { ActiveBlockingEdge, ContextComment, DashboardPayload, HandoffCopyState, PlannedSlice, SoloSession, WorkPackageCard, WorkRequestCard, WorkRequestDetail } from "@/types/dashboard";
import type { UpdateMotion, UpdateMotionKind } from "@/components/dashboard/motion";

declare global {
  interface Window {
    SYMPP_DASHBOARD_CONFIG?: {
      apiBase?: string;
      basePath?: string;
      csrfToken?: string;
      logoUrl?: string;
      operatorMode?: boolean;
    };
  }
}

export const DASHBOARD_UI_STATE_KEY = "symphony-plus-plus.dashboard.ui-state.v1";

export const DASHBOARD_THEME_KEY = "symphony-plus-plus.dashboard.theme.v1";

export const DASHBOARD_DEBUG_ANIMATIONS_KEY = "symphony-plus-plus.dashboard.debug-animations";

export const REPO_WORKSTREAM_MOTION_MS = 360;

export const DASHBOARD_RECONNECT_GRACE_MS = 5 * 60 * 1000;

export const CARD_DETAIL_LOADING_HOLD_MS = 220;

export const CARD_DETAIL_WIDTH_MS = 340;

export const CARD_DETAIL_HEIGHT_MS = 620;

export const LOCAL_DATE_FORMATTER = new Intl.DateTimeFormat(undefined, { month: "short", day: "numeric", hour: "2-digit", minute: "2-digit" });

export const TOP_PANEL_ORDER: TopPanelKey[] = ["guidance", "blockers"];

const DEFAULT_DASHBOARD_API_BASE = "/api/v1/sympp/operator";

const OPERATOR_BOOTSTRAP_PARAM = "operator_bootstrap";

export const LOCAL_OPERATOR_AUTH_REQUIRED_MESSAGE = "Local operator session needs reconnect. Use Reconnect after Symphony++ is reachable.";

export const COMMENT_BODY_MAX_LENGTH = 4000;

export const MAX_UPDATE_MOTION_ENTRIES = 120;

export type DashboardRuntimeConfig = {
  apiBase?: string;
  basePath?: string;
  csrfToken?: string;
  logoUrl?: string;
  operatorMode?: boolean;
};

export type DashboardApiResponse = unknown;

export type DashboardResponseSelector = (payload: DashboardApiResponse) => DashboardPayload | null | undefined;

class DashboardApiError extends Error {
  readonly reconnectableLocalSession: boolean;

  constructor(message: string, reconnectableLocalSession = false) {
    super(message);
    this.name = "DashboardApiError";
    this.reconnectableLocalSession = reconnectableLocalSession;
  }
}

export let dashboardRuntimeConfig: DashboardRuntimeConfig | undefined = typeof window === "undefined" ? undefined : window.SYMPP_DASHBOARD_CONFIG;

let dashboardRuntimeConfigPromise: Promise<DashboardRuntimeConfig | undefined> | null = null;

let dashboardRuntimeConfigGeneration = 0;

export const DASHBOARD_LOGO_URL = dashboardRuntimeConfig?.logoUrl || "/splusplus-logo.png";

export type TopPanelKey = "guidance" | "blockers";

export type TopPanelDirection = "forward" | "backward";

export type TopPanelPhase = "idle" | "opening" | "closing" | "pre-resize" | "swapping" | "post-resize";

export type PackageLineageProjection = NonNullable<WorkPackageCard["lineage"]>;

export type WorkspaceTab = "workstreams" | "solo";

export type WorkspaceTabPhase = "idle" | "swapping";

export type CardDetailStage = "loading" | "width" | "height" | "ready";

export type DashboardTheme = "light" | "dark";

export type CommentCardSignal = { open: number; total: number };

export type RepoSummaryPlateTone = "requested" | "active" | "implementing" | "finished" | "guidance" | "blocker";

export type UpdateMotionsAction =
  | { type: "clear" }
  | { type: "merge"; motions: Record<string, UpdateMotion> }
  | { type: "settle"; entries: [string, UpdateMotion][] };

export type UpdateAnimationEntity = {
  signature: string;
  status?: string | null;
  guidanceCount: number;
  blockerCount: number;
  finished: boolean;
};

export type DashboardUpdateAnimations = {
  countPulseFor: (panel: TopPanelKey) => number;
  motionFor: (key?: string | null) => UpdateMotion | undefined;
  simulate: (kind: UpdateMotionKind) => void;
};

export type DashboardConnectionIssue = {
  firstFailedAt: number;
  lastFailedAt: number;
  message: string;
  reconnectableLocalSession: boolean;
};

export const REPO_SUMMARY_PLATE_TONES: Record<RepoSummaryPlateTone, string> = {
  requested: "border-slate-200 bg-slate-50 text-slate-700 dark:border-slate-700/70 dark:bg-slate-900/70 dark:text-slate-200",
  active: "border-cyan-200 bg-cyan-50 text-cyan-800 dark:border-cyan-700/70 dark:bg-cyan-950/50 dark:text-cyan-200",
  implementing: "border-sky-200 bg-sky-50 text-sky-700 dark:border-sky-700/70 dark:bg-sky-950/50 dark:text-sky-200",
  finished: "border-emerald-200 bg-emerald-50 text-emerald-700 dark:border-emerald-700/70 dark:bg-emerald-950/50 dark:text-emerald-200",
  guidance: "border-violet-200 bg-violet-50 text-violet-700 dark:border-violet-700/70 dark:bg-violet-950/50 dark:text-violet-200",
  blocker: "border-red-200 bg-red-50 text-red-700 dark:border-red-700/70 dark:bg-red-950/50 dark:text-red-200",
};

export type CardDetailSelection =
  | { kind: "request"; detail: WorkRequestDetail }
  | { kind: "slice"; detail: WorkRequestDetail; slice: PlannedSlice; pkg?: WorkPackageCard }
  | { kind: "package"; pkg: WorkPackageCard; detail?: WorkRequestDetail; slice?: PlannedSlice }
  | { kind: "blocker"; blocker: ActiveBlockingEdge; pkg?: WorkPackageCard; detail?: WorkRequestDetail; slice?: PlannedSlice }
  | { kind: "solo"; session: SoloSession };

export type CardDetailSelect = (selection: CardDetailSelection) => void;

export type CommentTargetKind = "work_request" | "planned_slice" | "work_package";

export type CommentTarget = { target_kind: CommentTargetKind; target_id: string };

export type SubmitContextComment = (target: CommentTarget, body: string) => Promise<ContextComment>;

export type ResolveContextComment = (commentId: string, resolutionNote?: string) => Promise<ContextComment>;

export type CommentStats = { comment_count: number; open_comment_count: number };

export type WorkRequestMutation = (workRequestId: string) => Promise<void>;

export type WorkRequestStateMutation = (workRequestId: string, nextState: "completed") => Promise<void>;

export type WorkPackageStateAction = "merged" | "merged_and_archive" | "closed_and_archive" | "completed_no_pr";

export type WorkPackageStateMutation = (workPackageId: string, action: WorkPackageStateAction, options?: { noPrEvidence?: string }) => Promise<void>;

export type WorkPackageArchiveMutation = (workPackageId: string) => Promise<void>;

export type WorkPackageBlockerClearMutation = (workPackageId: string, blockerId: string) => Promise<void>;

export type RequestDetailUiState = {
  archiveError: string | null;
  archivePending: boolean;
  commentsOpen: boolean;
  deleteError: string | null;
  deletePending: boolean;
  deliverConfirmOpen: boolean;
  stateError: string | null;
  statePending: boolean;
};

export type RequestDetailUiAction =
  | { type: "archiveError"; error: string | null }
  | { type: "archivePending"; pending: boolean }
  | { type: "commentsOpen"; open: boolean }
  | { type: "deleteError"; error: string | null }
  | { type: "deletePending"; pending: boolean }
  | { type: "deliverConfirmOpen"; open: boolean }
  | { type: "stateError"; error: string | null }
  | { type: "statePending"; pending: boolean };

export type PackageDetailUiState = {
  archiveConfirmOpen: boolean;
  archiveError: string | null;
  archivePending: boolean;
  evidenceDialogOpen: boolean;
  noPrEvidence: string;
  pendingStateAction: WorkPackageStateAction | null;
  stateConfirmOpen: boolean;
  stateError: string | null;
  statePending: boolean;
};

export type PackageDetailUiAction =
  | { type: "archiveConfirmOpen"; open: boolean }
  | { type: "archiveError"; error: string | null }
  | { type: "archivePending"; pending: boolean }
  | { type: "evidenceDialogOpen"; open: boolean }
  | { type: "noPrEvidence"; value: string }
  | { type: "pendingStateAction"; action: WorkPackageStateAction | null }
  | { type: "stateClosed" }
  | { type: "stateConfirmOpen"; open: boolean }
  | { type: "stateError"; error: string | null }
  | { type: "statePending"; pending: boolean };

export type ScopedHandoffCopy = {
  error: string | null;
  identity: string;
  state: HandoffCopyState;
};

export type DashboardUiState = {
  workspaceTab?: WorkspaceTab;
  topPanel?: TopPanelKey | null;
  repoWorkstreams?: Record<string, boolean>;
  finishedRequestChildren?: Record<string, boolean>;
  hideEmptyWorkstreams?: boolean;
  showWorkstreamContextBar?: boolean;
  theme?: DashboardTheme;
};

export function isRecord(value: unknown): value is Record<string, unknown> {
  return Boolean(value) && typeof value === "object" && !Array.isArray(value);
}

function normalizeRuntimeBase(value: string | undefined, fallback: string) {
  const base = value?.trim() || fallback;
  return base.replace(/\/+$/, "");
}

export function operatorApiUrl(path: string) {
  const base = normalizeRuntimeBase(dashboardRuntimeConfig?.apiBase, DEFAULT_DASHBOARD_API_BASE);
  const suffix = path.startsWith("/") ? path : `/${path}`;
  return `${base}${suffix}`;
}

export function dashboardEventsUrl() {
  return operatorApiUrl("/dashboard/events");
}

function operatorConfigUrl() {
  const url = operatorApiUrl("/config");
  const token = currentOperatorBootstrapToken();

  if (!token) return url;

  const separator = url.includes("?") ? "&" : "?";
  return `${url}${separator}${encodeURIComponent(OPERATOR_BOOTSTRAP_PARAM)}=${encodeURIComponent(token)}`;
}

function currentOperatorBootstrapToken() {
  if (typeof window === "undefined") return null;

  try {
    const value = new URLSearchParams(window.location.search).get(OPERATOR_BOOTSTRAP_PARAM);
    return value?.trim() || null;
  } catch {
    return null;
  }
}

function scrubOperatorBootstrapFromUrl() {
  if (typeof window === "undefined") return;

  try {
    const url = new URL(window.location.href);
    if (!url.searchParams.has(OPERATOR_BOOTSTRAP_PARAM)) return;

    url.searchParams.delete(OPERATOR_BOOTSTRAP_PARAM);
    const nextUrl = `${url.pathname}${url.search}${url.hash}`;
    window.history.replaceState(window.history.state, document.title, nextUrl);
  } catch {
    // URL cleanup is best-effort; auth state must not depend on browser history mutation.
  }
}

export function jsonHeaders({ csrf = false, content = false }: { csrf?: boolean; content?: boolean } = {}) {
  const headers: Record<string, string> = { accept: "application/json" };

  if (content) {
    headers["content-type"] = "application/json";
  }

  if (csrf && dashboardRuntimeConfig?.csrfToken) {
    headers["x-csrf-token"] = dashboardRuntimeConfig.csrfToken;
  }

  return headers;
}

export function operatorFetch(input: RequestInfo | URL, init: RequestInit = {}) {
  return fetch(input, { ...init, credentials: "include" });
}

export async function readDashboardApiResponse(response: Response, fallbackMessage: string): Promise<DashboardApiResponse> {
  const payload = await readDashboardJson(response);

  if (!response.ok) {
    throw dashboardResponseError(response, payload, fallbackMessage);
  }

  return payload;
}

async function readDashboardJson(response: Response): Promise<DashboardApiResponse> {
  try {
    return await response.json();
  } catch {
    return null;
  }
}

function dashboardErrorMessage(payload: DashboardApiResponse) {
  if (!isRecord(payload) || !isRecord(payload.error)) return null;
  const message = typeof payload.error.message === "string" ? payload.error.message : "";
  if (message && message !== "Dashboard API unavailable") return message;

  const code = typeof payload.error.code === "string" ? payload.error.code : "";
  return code ? code.replaceAll("_", " ").replace(/\b\w/g, (letter) => letter.toUpperCase()) : null;
}

function dashboardResponseError(response: Response, payload: DashboardApiResponse, fallbackMessage: string) {
  return new DashboardApiError(
    dashboardResponseErrorMessage(response, payload, fallbackMessage),
    isLocalOperatorAuthResponse(response, payload),
  );
}

function dashboardResponseErrorMessage(response: Response, payload: DashboardApiResponse, fallbackMessage: string) {
  if (isLocalOperatorAuthResponse(response, payload)) return LOCAL_OPERATOR_AUTH_REQUIRED_MESSAGE;
  return dashboardErrorMessage(payload) || fallbackMessage;
}

function isLocalOperatorAuthResponse(response: Response, payload: DashboardApiResponse) {
  if (response.status === 401) return true;
  if (response.status === 403 && !isRecord(payload)) return true;

  if (!isRecord(payload) || !isRecord(payload.error)) return false;
  const code = typeof payload.error.code === "string" ? payload.error.code : "";
  return code === "unauthorized" || code === "forbidden" || code.toLowerCase().includes("csrf");
}

export function isLocalOperatorAuthRequiredMessage(message?: string | null) {
  return message === LOCAL_OPERATOR_AUTH_REQUIRED_MESSAGE;
}

export function dashboardCaughtMessage(caught: unknown, fallbackMessage: string) {
  return caught instanceof Error ? caught.message : fallbackMessage;
}

export function isReconnectableLocalOperatorError(caught: unknown) {
  return (
    (caught instanceof DashboardApiError && caught.reconnectableLocalSession) ||
    (caught instanceof Error && isLocalOperatorAuthRequiredMessage(caught.message))
  );
}

export function dashboardFromEnvelope(payload: DashboardApiResponse) {
  if (!isRecord(payload) || !isRecord(payload.dashboard)) return null;
  return payload.dashboard as DashboardPayload;
}

export function mutationShouldRefreshDashboard(payload: DashboardApiResponse) {
  if (!isRecord(payload) || !isRecord(payload.refresh)) return true;
  return payload.refresh.dashboard !== false;
}

export function shouldSkipDashboardLoad(inFlight: boolean, mode: string, force: boolean) {
  return inFlight && mode === "silent" && !force;
}

export type WorkRequestMutationPatch = Partial<WorkRequestCard> & { id: string };

export function dashboardMutationWorkRequest(payload: DashboardApiResponse): WorkRequestMutationPatch | null {
  if (!isRecord(payload) || !isRecord(payload.work_request)) return null;
  return typeof payload.work_request.id === "string" ? (payload.work_request as WorkRequestMutationPatch) : null;
}

export function patchDashboardWorkRequest(
  dashboard: DashboardPayload | null,
  workRequest: WorkRequestMutationPatch | null | undefined,
  options: { archive?: boolean } = {},
): DashboardPayload | null {
  if (!dashboard || !workRequest?.id) return dashboard;

  const archive = options.archive || Boolean(workRequest.archived_at);
  const nextCards = patchWorkRequestCards(dashboard.work_requests?.work_requests ?? [], workRequest, archive);
  const nextDetails = patchWorkRequestDetails(dashboard.work_request_details ?? [], workRequest, archive);
  const nextArchivedCards = patchArchivedWorkRequestCards(dashboard, workRequest, archive);

  return {
    ...dashboard,
    archived_work_requests: dashboard.archived_work_requests
      ? { ...dashboard.archived_work_requests, work_requests: nextArchivedCards, total_count: nextArchivedCards.length }
      : dashboard.archived_work_requests,
    work_request_details: nextDetails,
    work_requests: dashboard.work_requests ? { ...dashboard.work_requests, work_requests: nextCards, total_count: nextCards.length } : dashboard.work_requests,
  };
}

export function removeDashboardWorkRequest(dashboard: DashboardPayload | null, workRequestId: string): DashboardPayload | null {
  if (!dashboard) return dashboard;

  return {
    ...dashboard,
    archived_work_requests: removeWorkRequestSection(dashboard.archived_work_requests, workRequestId),
    work_request_details: removeWorkRequestDetails(dashboard.work_request_details, workRequestId),
    work_requests: removeWorkRequestSection(dashboard.work_requests, workRequestId),
  };
}

function removeWorkRequestSection(section: DashboardPayload["work_requests"], workRequestId: string) {
  if (!section) return section;

  const workRequests = (section.work_requests ?? []).filter((card) => card.id !== workRequestId);
  return { ...section, work_requests: workRequests, total_count: workRequests.length };
}

function removeWorkRequestDetails(details: WorkRequestDetail[] | undefined, workRequestId: string) {
  return details?.filter((detail) => detail.work_request.id !== workRequestId) ?? details;
}

export function mergeDashboardPayload(dashboard: DashboardPayload | null, patch: DashboardPayload | null | undefined): DashboardPayload | null {
  if (!dashboard || !patch) return patch ?? dashboard;
  return { ...dashboard, ...patch };
}

function patchWorkRequestCards(cards: WorkRequestCard[], workRequest: WorkRequestMutationPatch, archive: boolean) {
  return archive ? cards.filter((card) => card.id !== workRequest.id) : cards.map((card) => patchWorkRequestCard(card, workRequest));
}

function patchWorkRequestDetails(details: WorkRequestDetail[], workRequest: WorkRequestMutationPatch, archive: boolean) {
  return archive
    ? details.filter((detail) => detail.work_request.id !== workRequest.id)
    : details.map((detail) => (detail.work_request.id === workRequest.id ? { ...detail, work_request: patchWorkRequestCard(detail.work_request, workRequest) } : detail));
}

function patchArchivedWorkRequestCards(dashboard: DashboardPayload, workRequest: WorkRequestMutationPatch, archive: boolean) {
  const cards = dashboard.archived_work_requests?.work_requests ?? [];
  if (!archive) return cards.map((card) => patchWorkRequestCard(card, workRequest));

  return upsertWorkRequestCard(cards, patchWorkRequestCard(workRequestSourceCard(dashboard, workRequest.id) ?? workRequest, workRequest));
}

function workRequestSourceCard(dashboard: DashboardPayload, workRequestId: string) {
  return (
    dashboard.work_requests?.work_requests?.find((card) => card.id === workRequestId) ||
    dashboard.archived_work_requests?.work_requests?.find((card) => card.id === workRequestId) ||
    dashboard.work_request_details?.find((detail) => detail.work_request.id === workRequestId)?.work_request
  );
}

function patchWorkRequestCard(card: WorkRequestCard, workRequest: WorkRequestMutationPatch) {
  return card.id === workRequest.id ? { ...card, ...workRequest } : card;
}

function upsertWorkRequestCard(cards: WorkRequestCard[], card: WorkRequestCard) {
  return cards.some((current) => current.id === card.id) ? cards.map((current) => (current.id === card.id ? { ...current, ...card } : current)) : [card, ...cards];
}

function invalidateDashboardRuntimeAuth() {
  dashboardRuntimeConfigGeneration += 1;
  dashboardRuntimeConfigPromise = null;
  const currentConfig = dashboardRuntimeConfig ?? (typeof window === "undefined" ? undefined : window.SYMPP_DASHBOARD_CONFIG);
  dashboardRuntimeConfig = currentConfig ? { ...currentConfig, csrfToken: undefined } : undefined;

  if (typeof window !== "undefined" && window.SYMPP_DASHBOARD_CONFIG) {
    window.SYMPP_DASHBOARD_CONFIG = { ...window.SYMPP_DASHBOARD_CONFIG, csrfToken: undefined };
  }
}

export async function reconnectLocalOperatorSession() {
  invalidateDashboardRuntimeAuth();
  return ensureDashboardRuntimeConfig();
}

export async function withLocalOperatorReconnect<T>(operation: () => Promise<T>): Promise<T> {
  try {
    return await operation();
  } catch (caught) {
    if (!isReconnectableLocalOperatorError(caught)) {
      throw caught;
    }

    await reconnectLocalOperatorSession();
    return operation();
  }
}

export async function ensureDashboardRuntimeConfig() {
  if (dashboardRuntimeConfig?.csrfToken) {
    scrubOperatorBootstrapFromUrl();
    return dashboardRuntimeConfig;
  }

  if (!dashboardRuntimeConfigPromise) {
    const loadGeneration = dashboardRuntimeConfigGeneration;
    const configPromise: Promise<DashboardRuntimeConfig | undefined> = operatorFetch(operatorConfigUrl(), { headers: jsonHeaders() })
      .then(async (response) => {
        const payload = await readDashboardApiResponse(response, "Dashboard runtime config unavailable");
        const nextConfig = payload as DashboardRuntimeConfig;

        if (dashboardRuntimeConfigPromise !== configPromise || loadGeneration !== dashboardRuntimeConfigGeneration) {
          return dashboardRuntimeConfig ?? { ...nextConfig, csrfToken: undefined };
        }

        dashboardRuntimeConfig = nextConfig;
        scrubOperatorBootstrapFromUrl();
        return dashboardRuntimeConfig;
      })
      .finally(() => {
        if (dashboardRuntimeConfigPromise === configPromise) {
          dashboardRuntimeConfigPromise = null;
        }
      });

    dashboardRuntimeConfigPromise = configPromise;
  }

  return dashboardRuntimeConfigPromise;
}

export async function mutationHeaders() {
  await ensureDashboardRuntimeConfig();
  return jsonHeaders({ csrf: true, content: true });
}

export async function copyTextToClipboard(value: string) {
  if (navigator.clipboard?.writeText) {
    await navigator.clipboard.writeText(value);
    return;
  }

  const textArea = document.createElement("textarea");
  textArea.value = value;
  textArea.setAttribute("readonly", "");
  textArea.style.cssText = "position: fixed; left: -9999px; top: 0;";
  document.body.appendChild(textArea);
  textArea.select();

  try {
    const copied = document.execCommand("copy");
    if (!copied) throw new Error("Clipboard copy unavailable");
  } finally {
    document.body.removeChild(textArea);
  }
}
