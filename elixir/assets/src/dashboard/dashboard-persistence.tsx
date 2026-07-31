import { uniqueNonEmpty } from "@/lib/collections";
import { useSyncExternalStore } from "react";
import { DASHBOARD_DEBUG_ANIMATIONS_KEY, DASHBOARD_THEME_KEY, DASHBOARD_UI_STATE_KEY, DashboardTheme, DashboardUiState, LOCAL_DATE_FORMATTER, TOP_PANEL_ORDER, TopPanelDirection, TopPanelKey, WorkspaceTab, isRecord } from "./runtime";

const focusBoardSettingListeners = new Set<() => void>();

type RepoActivitySummary = {
  requested: number;
  active: number;
  implementing: number;
  finished: number;
  guidanceCount: number;
  blockerCount: number;
};

type RepoStateKeySummary = RepoActivitySummary & {
  repoKey: string;
  baseBranches: string[];
};

type RepoWorkItemsSummary = Pick<RepoActivitySummary, "requested" | "active" | "implementing" | "finished"> & {
  packages: unknown[];
  requests: unknown[];
};

export function formatDate(value: string) {
  const timestamp = Date.parse(value);

  if (Number.isNaN(timestamp)) {
    return "recent";
  }

  return LOCAL_DATE_FORMATTER.format(timestamp);
}

function repoName(value?: string | null) {
  const trimmed = value?.trim();
  return trimmed || "Unscoped";
}

export type RepoIdentitySource = {
  repo?: string | null;
  repo_key?: string | null;
  repo_display?: string | null;
  repo_remote?: string | null;
  repo_aliases?: string[];
};

export function repoIdentityKey(item?: RepoIdentitySource | null) {
  return item?.repo_key?.trim() || item?.repo?.trim() || "Unscoped";
}

export function repoDisplayName(item?: RepoIdentitySource | null) {
  return repoName(item?.repo_display || item?.repo);
}

export function repoRemoteName(item?: RepoIdentitySource | null) {
  return item?.repo_remote?.trim() || null;
}

export function addBranch(summary: { baseBranches: string[] }, branch?: string | null) {
  const value = branch?.trim();
  if (value && !summary.baseBranches.includes(value)) {
    summary.baseBranches.push(value);
  }
}

export function readStoredWorkspaceTab(): WorkspaceTab {
  const storedTab = readDashboardUiState().workspaceTab;
  return isWorkspaceTab(storedTab) ? storedTab : "workstreams";
}

export function readStoredTopPanel(): TopPanelKey | null {
  const state = readDashboardUiState();
  if (!("topPanel" in state)) return null;
  if (state.topPanel === null) return null;
  return isTopPanelKey(state.topPanel) ? state.topPanel : null;
}

export function readStoredHideEmptyWorkstreams() {
  const storedValue = readDashboardUiState().hideEmptyWorkstreams;
  return typeof storedValue === "boolean" ? storedValue : true;
}

export function readStoredShowWorkstreamContextBar() {
  const storedValue = readDashboardUiState().showWorkstreamContextBar;
  return typeof storedValue === "boolean" ? storedValue : true;
}

export function readStoredShowWelcomeToast() {
  const storedValue = readDashboardUiState().showWelcomeToast;
  return typeof storedValue === "boolean" ? storedValue : true;
}

export function readStoredUseFocusBoard() {
  return readDashboardUiState().useFocusBoard === true;
}

export function useStoredUseFocusBoard() {
  return useSyncExternalStore(subscribeToFocusBoardSetting, readStoredUseFocusBoard, () => false);
}

export function writeStoredUseFocusBoard(useFocusBoard: boolean) {
  updateDashboardUiState((state) => ({ ...state, useFocusBoard }));
  focusBoardSettingListeners.forEach((listener) => listener());
}

function subscribeToFocusBoardSetting(listener: () => void) {
  focusBoardSettingListeners.add(listener);
  return () => focusBoardSettingListeners.delete(listener);
}

export function readStoredRepoWorkstreamOpen(stateKey: string, fallback: boolean) {
  const repoWorkstreams = readDashboardUiState().repoWorkstreams;
  const storedOpen = repoWorkstreams?.[stateKey];
  return typeof storedOpen === "boolean" ? storedOpen : fallback;
}

export function writeStoredRepoWorkstreamOpen(stateKey: string, open: boolean) {
  updateDashboardUiState((state) => ({
    ...state,
    repoWorkstreams: {
      ...(state.repoWorkstreams || {}),
      [stateKey]: open,
    },
  }));
}

export function readStoredFocusBoardSectionOpen(lane: string, fallback: boolean) {
  const storedOpen = readDashboardUiState().focusBoardSections?.[lane];
  return typeof storedOpen === "boolean" ? storedOpen : fallback;
}

export function writeStoredFocusBoardSectionOpen(lane: string, open: boolean) {
  updateDashboardUiState((state) => ({
    ...state,
    focusBoardSections: {
      ...(state.focusBoardSections || {}),
      [lane]: open,
    },
  }));
}

export function readStoredFinishedRequestChildren() {
  const stored = readDashboardUiState().finishedRequestChildren;
  return isRecord(stored) ? Object.fromEntries(Object.entries(stored).filter(([, open]) => typeof open === "boolean")) as Record<string, boolean> : {};
}

export function writeStoredFinishedRequestChildren(finishedRequestChildren: Record<string, boolean>) {
  updateDashboardUiState((state) => ({ ...state, finishedRequestChildren }));
}

export function writeDashboardUiStateValue<Key extends keyof DashboardUiState>(key: Key, value: DashboardUiState[Key]) {
  updateDashboardUiState((state) => ({ ...state, [key]: value }));
}

function readDashboardUiState(): DashboardUiState {
  if (typeof window === "undefined") return {};

  try {
    const rawState = window.localStorage.getItem(DASHBOARD_UI_STATE_KEY);
    if (!rawState) return {};

    const parsed = JSON.parse(rawState);
    return isRecord(parsed) ? (parsed as DashboardUiState) : {};
  } catch {
    return {};
  }
}

function updateDashboardUiState(updater: (state: DashboardUiState) => DashboardUiState) {
  if (typeof window === "undefined") return;

  try {
    const nextState = updater(readDashboardUiState());
    window.localStorage.setItem(DASHBOARD_UI_STATE_KEY, JSON.stringify(nextState));
  } catch {
    // Storage can be unavailable in locked-down browser contexts; UI state should stay non-critical.
  }
}

export function readStoredTheme(): DashboardTheme {
  if (typeof window === "undefined") return "light";

  const storedUiTheme = readDashboardUiState().theme;
  if (isDashboardTheme(storedUiTheme)) return storedUiTheme;

  try {
    const storedTheme = window.localStorage.getItem(DASHBOARD_THEME_KEY);
    if (isDashboardTheme(storedTheme)) return storedTheme;
  } catch {
    // Storage can be unavailable in locked-down browser contexts; fall back to the OS preference.
  }

  return window.matchMedia?.("(prefers-color-scheme: dark)").matches ? "dark" : "light";
}

export function writeStoredTheme(theme: DashboardTheme) {
  if (typeof window === "undefined") return;

  updateDashboardUiState((state) => ({ ...state, theme }));

  try {
    window.localStorage.setItem(DASHBOARD_THEME_KEY, theme);
  } catch {
    // Theme persistence is best-effort; the class toggle still applies for the active session.
  }

  applyDashboardTheme(theme);
}

export function applyDashboardTheme(theme: DashboardTheme) {
  if (typeof document === "undefined") return;
  document.documentElement.classList.toggle("dark", theme === "dark");
}

export function shouldShowUpdateSimulationControls() {
  if (typeof window === "undefined") return false;

  try {
    const params = new URLSearchParams(window.location.search);
    return params.get("debugAnimations") === "1" || window.localStorage.getItem(DASHBOARD_DEBUG_ANIMATIONS_KEY) === "true";
  } catch {
    return false;
  }
}

export function defaultRepoWorkstreamOpen(repo: RepoActivitySummary) {
  if (!repoWorkstreamHasActivity(repo)) return false;
  return typeof window === "undefined" ? true : window.innerWidth >= 900;
}

export function repoWorkstreamStateKey(repo: RepoStateKeySummary) {
  const branchKey = uniqueNonEmpty(repo.baseBranches).sort().join("|") || "main";
  const activityKey = repoWorkstreamHasActivity(repo) ? "active" : "empty";
  return `${repo.repoKey}::${branchKey}::${activityKey}`;
}

function repoWorkstreamHasActivity(repo: RepoActivitySummary) {
  return repo.requested + repo.active + repo.implementing + repo.finished + repo.guidanceCount + repo.blockerCount > 0;
}

export function repoWorkstreamHasWorkItems(repo: RepoWorkItemsSummary) {
  return repo.requests.length + repo.packages.length + repo.requested + repo.active + repo.implementing + repo.finished > 0;
}

function isWorkspaceTab(value: unknown): value is WorkspaceTab {
  return value === "workstreams" || value === "solo";
}

function isTopPanelKey(value: unknown): value is TopPanelKey {
  return typeof value === "string" && (TOP_PANEL_ORDER as readonly string[]).includes(value);
}

function isDashboardTheme(value: unknown): value is DashboardTheme {
  return value === "light" || value === "dark";
}

export function topPanelDirection(from: TopPanelKey | null, to: TopPanelKey | null): TopPanelDirection {
  if (!from || !to) return "forward";
  return TOP_PANEL_ORDER.indexOf(to) > TOP_PANEL_ORDER.indexOf(from) ? "forward" : "backward";
}

export function workspaceTabDirection(from: WorkspaceTab, to: WorkspaceTab): TopPanelDirection {
  return to === "solo" && from === "workstreams" ? "forward" : "backward";
}
