import type { ArchitectHandoff, ArchitectHandoffCopyResult, DashboardPayload, WorkRequestDetail } from "@/types/dashboard";
import type { UpdateMotion } from "@/components/dashboard/motion";
import { useCallback, useRef, useState } from "react";
import { CardDetailSelection, DashboardTheme, PackageDetailUiAction, PackageDetailUiState, RequestDetailUiAction, RequestDetailUiState, ScopedHandoffCopy, UpdateMotionsAction, WorkspaceTab } from "./runtime";
import { readStoredHideEmptyWorkstreams, readStoredShowWelcomeToast, readStoredShowWorkstreamContextBar, readStoredTheme, readStoredWorkspaceTab } from "./dashboard-persistence";
import type { AttentionTarget } from "./workstream-attention";

export function useScopedHandoffCopy(identity: string) {
  const [copy, setCopy] = useState<ScopedHandoffCopy>({ error: null, identity, state: "idle" });
  const handoffRef = useRef<{ handoff: ArchitectHandoff | null; identity: string }>({ handoff: null, identity: "" });

  const current = copy.identity === identity ? copy : { error: null, identity, state: "idle" as const };
  const cachedHandoff = useCallback(() => (handoffRef.current.identity === identity ? handoffRef.current.handoff : null), [identity]);
  const startCopy = useCallback(() => setCopy({ error: null, identity, state: "copying" }), [identity]);
  const recordCopyResult = useCallback(
    (result: ArchitectHandoffCopyResult) => {
      handoffRef.current = { handoff: result.handoff, identity };
      setCopy({
        error: result.copyError ? `Handoff is ready, but clipboard copy failed: ${result.copyError}` : null,
        identity,
        state: result.copied ? "copied" : "error",
      });
    },
    [identity],
  );
  const recordCopyError = useCallback((error: string) => setCopy({ error, identity, state: "error" }), [identity]);

  return {
    cachedHandoff,
    error: current.error,
    recordCopyError,
    recordCopyResult,
    startCopy,
    state: current.state,
  };
}

export type BlockerItem = {
  id: string;
  title: string;
  repo: string;
  since?: string | null;
  status?: string | null;
  blockerCount: number;
  detail: string;
  selection: CardDetailSelection;
};

export type FinishedHighlight = {
  id: string;
  title: string;
  repo: string;
  kind: FinishedHighlightKind;
  state?: string | null;
  at?: string | null;
  selection: CardDetailSelection;
};

export type FinishedHighlightKind = "Request" | "WorkPackage";

export type WorkstreamCategoryCounts = {
  requests: number;
  planNodes: number;
  slices: number;
};

export const EMPTY_WORK_REQUEST_DETAILS: WorkRequestDetail[] = [];

export type AppState = {
  dashboard: DashboardPayload | null;
  loading: boolean;
  refreshing: boolean;
  error: string | null;
  workspaceTab: WorkspaceTab;
  hideEmptyWorkstreams: boolean;
  showWorkstreamContextBar: boolean;
  showWelcomeToast: boolean;
  theme: DashboardTheme;
};

export type AppStateAction = {
  type: "patch";
  state: Partial<AppState>;
};

export function createInitialAppState(): AppState {
  return {
    dashboard: null,
    loading: true,
    refreshing: false,
    error: null,
    workspaceTab: readStoredWorkspaceTab(),
    hideEmptyWorkstreams: readStoredHideEmptyWorkstreams(),
    showWorkstreamContextBar: readStoredShowWorkstreamContextBar(),
    showWelcomeToast: readStoredShowWelcomeToast(),
    theme: readStoredTheme(),
  };
}

export function appStateReducer(state: AppState, action: AppStateAction): AppState {
  const entries = Object.entries(action.state) as Array<[keyof AppState, AppState[keyof AppState]]>;
  const changed = entries.some(([key, value]) => !Object.is(state[key], value));
  return changed ? { ...state, ...action.state } : state;
}

export type AppDialogState = {
  selectedAttention: AttentionTarget | null;
  selectedCardDetail: CardDetailSelection | null;
  newRequestOpen: boolean;
};

export type AppDialogAction =
  | { type: "attention"; selectedAttention: AttentionTarget | null }
  | { type: "cardDetail"; selectedCardDetail: CardDetailSelection | null }
  | { type: "newRequest"; open: boolean };

export const initialAppDialogState: AppDialogState = {
  selectedAttention: null,
  selectedCardDetail: null,
  newRequestOpen: false,
};

export function appDialogReducer(state: AppDialogState, action: AppDialogAction): AppDialogState {
  switch (action.type) {
    case "attention":
      return { ...state, selectedAttention: action.selectedAttention, selectedCardDetail: action.selectedAttention ? null : state.selectedCardDetail };
    case "cardDetail":
      return { ...state, selectedAttention: action.selectedCardDetail ? null : state.selectedAttention, selectedCardDetail: action.selectedCardDetail };
    case "newRequest":
      return { ...state, newRequestOpen: action.open };
  }
}

export const initialRequestDetailUiState: RequestDetailUiState = {
  archiveError: null,
  archivePending: false,
  commentsOpen: false,
  deleteError: null,
  deletePending: false,
  deliverConfirmOpen: false,
  stateError: null,
  statePending: false,
};

export function requestDetailUiReducer(state: RequestDetailUiState, action: RequestDetailUiAction): RequestDetailUiState {
  switch (action.type) {
    case "archiveError":
      return state.archiveError === action.error ? state : { ...state, archiveError: action.error };
    case "archivePending":
      return state.archivePending === action.pending ? state : { ...state, archivePending: action.pending };
    case "commentsOpen":
      return state.commentsOpen === action.open ? state : { ...state, commentsOpen: action.open };
    case "deleteError":
      return state.deleteError === action.error ? state : { ...state, deleteError: action.error };
    case "deletePending":
      return state.deletePending === action.pending ? state : { ...state, deletePending: action.pending };
    case "deliverConfirmOpen":
      return state.deliverConfirmOpen === action.open ? state : { ...state, deliverConfirmOpen: action.open };
    case "stateError":
      return state.stateError === action.error ? state : { ...state, stateError: action.error };
    case "statePending":
      return state.statePending === action.pending ? state : { ...state, statePending: action.pending };
  }
}

export const initialPackageDetailUiState: PackageDetailUiState = {
  archiveConfirmOpen: false,
  archiveError: null,
  archivePending: false,
  evidenceDialogOpen: false,
  noPrEvidence: "",
  pendingStateAction: null,
  stateConfirmOpen: false,
  stateError: null,
  statePending: false,
};

export function packageDetailUiReducer(state: PackageDetailUiState, action: PackageDetailUiAction): PackageDetailUiState {
  switch (action.type) {
    case "archiveConfirmOpen":
      return state.archiveConfirmOpen === action.open ? state : { ...state, archiveConfirmOpen: action.open };
    case "archiveError":
      return state.archiveError === action.error ? state : { ...state, archiveError: action.error };
    case "archivePending":
      return state.archivePending === action.pending ? state : { ...state, archivePending: action.pending };
    case "evidenceDialogOpen":
      return state.evidenceDialogOpen === action.open ? state : { ...state, evidenceDialogOpen: action.open };
    case "noPrEvidence":
      return state.noPrEvidence === action.value ? state : { ...state, noPrEvidence: action.value };
    case "pendingStateAction":
      return state.pendingStateAction === action.action ? state : { ...state, pendingStateAction: action.action };
    case "stateClosed":
      return { ...state, evidenceDialogOpen: false, noPrEvidence: "", pendingStateAction: null, stateConfirmOpen: false };
    case "stateConfirmOpen":
      return state.stateConfirmOpen === action.open ? state : { ...state, stateConfirmOpen: action.open };
    case "stateError":
      return state.stateError === action.error ? state : { ...state, stateError: action.error };
    case "statePending":
      return state.statePending === action.pending ? state : { ...state, statePending: action.pending };
  }
}

export function updateMotionsReducer(current: Record<string, UpdateMotion>, action: UpdateMotionsAction): Record<string, UpdateMotion> {
  switch (action.type) {
    case "clear":
      return Object.keys(current).length === 0 ? current : {};
    case "merge":
      return { ...current, ...action.motions };
    case "settle": {
      let changed = false;
      const next = { ...current };

      action.entries.forEach(([key, motion]) => {
        if (next[key]?.token === motion.token) {
          next[key] = { kind: "settled", token: motion.token };
          changed = true;
        }
      });

      return changed ? next : current;
    }
  }
}
