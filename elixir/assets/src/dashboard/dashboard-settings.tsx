import { Archive, CheckCircle2, Loader2, Moon, RotateCcw, Settings2, Sun } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Dialog, DialogContent, DialogDescription, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { NumberWheel, useCountMotion } from "@/components/dashboard/motion";
import type * as React from "react";
import { ScrollArea } from "@/components/ui/scroll-area";
import { Tooltip, TooltipContent, TooltipTrigger } from "@/components/ui/tooltip";
import type { WorkRequestCard } from "@/types/dashboard";
import { cn } from "@/lib/utils";
import { sortedCopy } from "@/lib/collections";
import { useMemo, useRef, useState } from "react";
import { DashboardTheme, REPO_SUMMARY_PLATE_TONES, RepoSummaryPlateTone, WorkRequestMutation } from "./runtime";
import { detailDate } from "./detail-utils";
import { repoDisplayName } from "./dashboard-persistence";
import { sortableTime } from "./workstream-data";

export function ThemeToggle({ theme, onToggle }: { theme: DashboardTheme; onToggle: () => void }) {
  const dark = theme === "dark";
  const label = dark ? "Switch to light mode" : "Switch to dark mode";

  return (
    <Tooltip>
      <TooltipTrigger asChild>
        <Button
          type="button"
          variant="outline"
          size="icon"
          className="button-lift relative overflow-hidden"
          aria-label={label}
          onClick={onToggle}
        >
          <Sun
            className={cn(
              "absolute size-4 transition-all duration-200",
              dark ? "rotate-45 scale-0 opacity-0" : "rotate-0 scale-100 opacity-100",
            )}
          />
          <Moon
            className={cn(
              "absolute size-4 transition-all duration-200",
              dark ? "rotate-0 scale-100 opacity-100" : "-rotate-45 scale-0 opacity-0",
            )}
          />
        </Button>
      </TooltipTrigger>
      <TooltipContent>{label}</TooltipContent>
    </Tooltip>
  );
}

function SettingsSwitch({
  ariaLabel,
  checked,
  description,
  label,
  onChange,
}: {
  ariaLabel: string;
  checked: boolean;
  description: string;
  label: string;
  onChange: (value: boolean) => Promise<void> | void;
}) {
  const [pending, setPending] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function toggle() {
    setPending(true);
    setError(null);

    try {
      await onChange(!checked);
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : "Setting was not saved");
    } finally {
      setPending(false);
    }
  }

  return (
    <div className="grid gap-2 rounded-md border bg-card/60 p-3">
      <div className="flex items-center justify-between gap-4">
        <div className="min-w-0">
          <span className="block text-sm font-medium">{label}</span>
          <span className="mt-1 block text-xs text-muted-foreground">{description}</span>
        </div>
        <button
          type="button"
          role="switch"
          aria-checked={checked}
          aria-busy={pending}
          aria-label={ariaLabel}
          disabled={pending}
          className={cn(
            "relative h-6 w-11 shrink-0 rounded-full bg-muted transition-colors focus:outline-none focus-visible:ring-2 focus-visible:ring-ring disabled:opacity-70",
            checked && "bg-primary",
          )}
          onClick={() => void toggle()}
        >
          <span
            className={cn(
              "absolute left-1 top-1 size-4 rounded-full bg-background shadow transition-transform",
              checked && "translate-x-5",
            )}
          />
          {pending ? <Loader2 className="absolute left-3.5 top-1 size-4 animate-spin text-background" /> : null}
        </button>
      </div>
      {error ? <p className="text-xs text-destructive">{error}</p> : null}
    </div>
  );
}

function RetentionCutoffSetting({
  description,
  inputLabel,
  label,
  onSave,
  value,
}: {
  description: string;
  inputLabel: string;
  label: string;
  onSave: (value: number) => Promise<void>;
  value: number;
}) {
  const [draftState, setDraftState] = useState({
    source: value,
    value: String(value),
  });
  const [pending, setPending] = useState(false);
  const [errorState, setErrorState] = useState<{ source: number; message: string | null }>({
    source: value,
    message: null,
  });
  const draft = draftState.source === value ? draftState.value : String(value);
  const error = errorState.source === value ? errorState.message : null;
  const draftValue = draft.trim();
  const cutoffValue = Number(draftValue);
  const valid = /^\d+$/.test(draftValue) && Number.isInteger(cutoffValue) && cutoffValue >= 1 && cutoffValue <= 3650;
  const changed = valid && cutoffValue !== value;

  function setDraft(nextValue: string) {
    setDraftState({ source: value, value: nextValue });
  }

  function setError(message: string | null) {
    setErrorState({ source: value, message });
  }

  async function save(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!valid) {
      setError("Use a whole number from 1 to 3650.");
      return;
    }

    setPending(true);
    setError(null);

    try {
      await onSave(cutoffValue);
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : "Setting was not saved");
    } finally {
      setPending(false);
    }
  }

  return (
    <div className="grid gap-3 rounded-md border bg-card/60 p-3">
      <div>
        <span className="block text-sm font-medium">{label}</span>
        <span className="mt-1 block text-xs text-muted-foreground">{description}</span>
      </div>
      <form className="flex items-start gap-2" onSubmit={(event) => void save(event)}>
        <Input
          aria-label={inputLabel}
          min={1}
          max={3650}
          step={1}
          type="number"
          value={draft}
          onChange={(event) => setDraft(event.target.value)}
        />
        <Button type="submit" size="sm" disabled={pending || !changed}>
          {pending ? <Loader2 className="size-4 animate-spin" /> : <CheckCircle2 className="size-4" />}
          Save
        </Button>
      </form>
      {error ? <p className="text-xs text-destructive">{error}</p> : null}
    </div>
  );
}

export function DashboardSettingsDialog({
  archiveAfterDays,
  canUpdateRetentionSettings,
  hideEmptyWorkstreams,
  hiddenWorkstreamCount,
  openDashboardOnBoot,
  showWorkstreamContextBar,
  showWelcomeToast,
  soloSessionDeleteAfterDays,
  onArchiveAfterDaysChange,
  onHideEmptyWorkstreamsChange,
  onOpenDashboardOnBootChange,
  onSoloSessionDeleteAfterDaysChange,
  onShowWorkstreamContextBarChange,
  onShowWelcomeToastChange,
}: {
  archiveAfterDays: number;
  canUpdateRetentionSettings: boolean;
  hideEmptyWorkstreams: boolean;
  hiddenWorkstreamCount: number;
  openDashboardOnBoot: boolean;
  showWorkstreamContextBar: boolean;
  showWelcomeToast: boolean;
  soloSessionDeleteAfterDays: number;
  onArchiveAfterDaysChange: (value: number) => Promise<void>;
  onHideEmptyWorkstreamsChange: (value: boolean) => void;
  onOpenDashboardOnBootChange: (value: boolean) => Promise<void>;
  onSoloSessionDeleteAfterDaysChange: (value: number) => Promise<void>;
  onShowWorkstreamContextBarChange: (value: boolean) => void;
  onShowWelcomeToastChange: (value: boolean) => void;
}) {
  const [open, setOpen] = useState(false);
  const initialFocusRef = useRef<HTMLDivElement | null>(null);
  const visibilityLabel = hideEmptyWorkstreams
    ? workstreamHiddenSummary(hiddenWorkstreamCount)
    : "Showing repos even when they have no requests, plan nodes, or slices.";
  const contextBarLabel = showWorkstreamContextBar
    ? "Shows the sticky repo, WR, and plan-node path while scrolling."
    : "Board rows scroll without the sticky context path.";
  const welcomeLabel = showWelcomeToast ? "Shows the welcome modal on dashboard load." : "Welcome modal is hidden.";
  const openOnBootLabel = openDashboardOnBoot
    ? "Opens once when Codex connects and no dashboard is already open."
    : "Codex connects without opening a browser.";

  return (
    <>
      <Tooltip>
        <TooltipTrigger asChild>
          <Button
            type="button"
            variant="outline"
            size="icon"
            className="button-lift"
            aria-label="Dashboard settings"
            onClick={() => {
              setOpen(true);
            }}
          >
            <Settings2 className="size-4" />
          </Button>
        </TooltipTrigger>
        <TooltipContent>Settings</TooltipContent>
      </Tooltip>

      <Dialog open={open} onOpenChange={setOpen}>
        <DialogContent
          className="dashboard-dialog-content max-w-md"
          onOpenAutoFocus={(event) => {
            event.preventDefault();
            initialFocusRef.current?.focus();
          }}
        >
          <DialogHeader>
            <DialogTitle>Settings</DialogTitle>
            <DialogDescription>Dashboard display preferences</DialogDescription>
          </DialogHeader>

          <div ref={initialFocusRef} tabIndex={-1} className="grid gap-3 outline-none">
            {canUpdateRetentionSettings ? (
              <>
                <RetentionCutoffSetting
                  description={`Delivered WorkRequests and inactive Solo Sessions archive after ${archiveAfterDays} days.`}
                  inputLabel="Archive cutoff days"
                  label="Archive cutoff"
                  value={archiveAfterDays}
                  onSave={onArchiveAfterDaysChange}
                />
                <RetentionCutoffSetting
                  description={`Archived WorkRequests and Solo Sessions delete after ${soloSessionDeleteAfterDays} days.`}
                  inputLabel="Deletion cutoff days"
                  label="Deletion cutoff"
                  value={soloSessionDeleteAfterDays}
                  onSave={onSoloSessionDeleteAfterDaysChange}
                />
                <SettingsSwitch
                  ariaLabel="Open dashboard with Codex"
                  checked={openDashboardOnBoot}
                  description={openOnBootLabel}
                  label="Open dashboard with Codex"
                  onChange={onOpenDashboardOnBootChange}
                />
              </>
            ) : null}

            <SettingsSwitch
              ariaLabel="Show welcome toast"
              checked={showWelcomeToast}
              description={welcomeLabel}
              label="Welcome toast"
              onChange={onShowWelcomeToastChange}
            />

            <SettingsSwitch
              ariaLabel="Hide empty repositories"
              checked={hideEmptyWorkstreams}
              description={visibilityLabel}
              label="Hide empty repositories"
              onChange={onHideEmptyWorkstreamsChange}
            />

            <SettingsSwitch
              ariaLabel="Show board context bar"
              checked={showWorkstreamContextBar}
              description={contextBarLabel}
              label="Board context bar"
              onChange={onShowWorkstreamContextBarChange}
            />
          </div>
        </DialogContent>
      </Dialog>
    </>
  );
}

function workstreamHiddenSummary(hiddenWorkstreamCount: number) {
  if (hiddenWorkstreamCount <= 0) return "Only repos with requests, plan nodes, or slices appear.";
  return hiddenWorkstreamCount === 1 ? "1 empty repo hidden" : `${hiddenWorkstreamCount} empty repos hidden`;
}

export function ArchivedRequestsDialog({
  canRestoreWorkRequest,
  requests,
  onRestoreWorkRequest,
}: {
  canRestoreWorkRequest: boolean;
  requests: WorkRequestCard[];
  onRestoreWorkRequest: WorkRequestMutation;
}) {
  const [open, setOpen] = useState(false);
  const [pendingId, setPendingId] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const sortedRequests = useMemo(() => sortedCopy(requests, (left, right) => sortableTime(right.archived_at) - sortableTime(left.archived_at)), [requests]);

  async function restoreRequest(workRequestId: string) {
    setPendingId(workRequestId);
    setError(null);

    try {
      await onRestoreWorkRequest(workRequestId);
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : "WorkRequest was not restored");
    } finally {
      setPendingId(null);
    }
  }

  return (
    <>
      <Tooltip>
        <TooltipTrigger asChild>
          <Button
            type="button"
            variant="outline"
            size="icon"
            className="button-lift relative"
            aria-label="Archived requests"
            onClick={() => {
              setError(null);
              setOpen(true);
            }}
          >
            <Archive className="size-4" />
            {requests.length > 0 ? (
              <span className="absolute -right-1 -top-1 min-w-4 rounded-full bg-primary px-1 text-[10px] font-semibold leading-4 text-primary-foreground">
                {requests.length}
              </span>
            ) : null}
          </Button>
        </TooltipTrigger>
        <TooltipContent>Archived requests</TooltipContent>
      </Tooltip>

      <Dialog
        open={open}
        onOpenChange={(nextOpen) => {
          if (nextOpen) setError(null);
          setOpen(nextOpen);
        }}
      >
        <DialogContent className="dashboard-dialog-content max-w-lg">
          <DialogHeader>
            <DialogTitle>Archived Requests</DialogTitle>
            <DialogDescription>Delivered WorkRequests hidden from the active cockpit</DialogDescription>
          </DialogHeader>

          {error ? <p className="rounded-md border border-destructive/30 bg-destructive/10 px-3 py-2 text-sm text-destructive">{error}</p> : null}

          {sortedRequests.length > 0 ? (
            <ScrollArea className="max-h-[55vh] pr-3">
              <div className="grid gap-2">
                {sortedRequests.map((request) => (
                  <div key={request.id} className="detail-list-item flex items-start justify-between gap-3">
                    <div className="min-w-0">
                      <span className="block truncate text-sm font-medium">{request.title || request.id}</span>
                      <span className="mt-1 block text-xs text-muted-foreground">
                        {repoDisplayName(request)} / {request.base_branch || "main"} / archived {detailDate(request.archived_at)}
                      </span>
                    </div>
                    {canRestoreWorkRequest ? (
                      <Button
                        type="button"
                        size="sm"
                        variant="outline"
                        disabled={pendingId === request.id}
                        onClick={() => void restoreRequest(request.id)}
                      >
                        {pendingId === request.id ? <Loader2 className="size-4 animate-spin" /> : <RotateCcw className="size-4" />}
                        Restore
                      </Button>
                    ) : null}
                  </div>
                ))}
              </div>
            </ScrollArea>
          ) : (
            <p className="rounded-md border bg-card/60 px-3 py-6 text-center text-sm text-muted-foreground">No archived requests.</p>
          )}
        </DialogContent>
      </Dialog>
    </>
  );
}

export function RepoSummaryPlate({
  icon,
  label,
  summaryKey,
  value,
  tone,
  className,
}: {
  icon?: React.ReactNode;
  label: string;
  summaryKey?: string;
  value: number;
  tone: RepoSummaryPlateTone;
  className?: string;
}) {
  const countMotion = useCountMotion(value);

  return (
    <div
      className={cn("inline-flex items-center gap-0.5 rounded-md border px-1 py-1 text-xs font-medium", REPO_SUMMARY_PLATE_TONES[tone], className)}
      data-summary-key={summaryKey}
    >
      {icon ? <span className="repo-summary-plate-icon">{icon}</span> : null}
      <span className="repo-summary-plate-value font-semibold tabular-nums">
        <NumberWheel value={value} motion={countMotion} compact />
      </span>
      <span className="repo-summary-plate-label">{label}</span>
    </div>
  );
}
